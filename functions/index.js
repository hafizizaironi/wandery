const functions = require("firebase-functions");
const admin = require("firebase-admin");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const { logger } = require("firebase-functions/v2");
const geofire = require("geofire-common");

admin.initializeApp();

// Replicate API token — injected at runtime from Firebase Secret Manager.
// Set via:  firebase functions:secrets:set REPLICATE_API_TOKEN --project look-cafe
const REPLICATE_API_TOKEN = defineSecret("REPLICATE_API_TOKEN");

async function sendToUser(uid, title, body, data = {}) {
  const snap = await admin
    .firestore()
    .collection("users")
    .doc(uid)
    .collection("fcmTokens")
    .get();
  const tokens = snap.docs.map((d) => d.data().token).filter(Boolean);
  if (tokens.length === 0) return;
  const dataPayload = Object.fromEntries(
    Object.entries(data).map(([k, v]) => [k, String(v)]),
  );
  for (const token of tokens) {
    try {
      await admin.messaging().send({
        token,
        notification: { title, body },
        data: dataPayload,
      });
    } catch (e) {
      console.error("FCM send failed", e);
    }
  }
}

exports.onFriendRequestCreate = functions.firestore
  .document("friendRequests/{requestId}")
  .onCreate(async (snap, context) => {
    const d = snap.data();
    if (!d || d.status !== "pending") return;
    const fromName = d.fromUsername || "Someone";
    await sendToUser(d.toUid, "Friend request", `${fromName} wants to be friends`, {
      type: "friendRequest",
      requestId: context.params.requestId,
    });
  });

exports.onFriendRequestAccepted = functions.firestore
  .document("friendRequests/{requestId}")
  .onUpdate(async (change, context) => {
    const before = change.before.data();
    const after = change.after.data();
    if (!before || !after) return;
    if (before.status !== "pending" || after.status !== "accepted") return;
    await sendToUser(after.fromUid, "Request accepted", "You are now friends!", {
      type: "friendAccepted",
      requestId: context.params.requestId,
    });
  });

exports.onNewPost = functions.firestore
  .document("posts/{postId}")
  .onCreate(async (snap, context) => {
    const d = snap.data();
    if (!d) return;
    const author = d.authorId;
    const authorName = d.authorUsername || "Friend";
    const friendsSnap = await admin
      .firestore()
      .collection("users")
      .doc(author)
      .collection("friends")
      .get();
    const friendUids = friendsSnap.docs.map((x) => x.id);
    for (const uid of friendUids) {
      await sendToUser(uid, "New post", `${authorName} shared a moment`, {
        type: "newPost",
        postId: context.params.postId,
      });
    }
  });

// Delete a Firestore collection in batches (Firestore has no cascade, so a
// deleted post leaves its `reactions` subcollection orphaned). Paginated so
// it stays under the 500-write batch limit on busy posts.
async function deleteCollection(ref) {
  let snap = await ref.limit(400).get();
  while (!snap.empty) {
    const batch = admin.firestore().batch();
    snap.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
    if (snap.size < 400) return;
    snap = await ref.limit(400).get();
  }
}

// Tidy up after a post is deleted. The client `deletePost` removes the post
// doc + its first media object, but it can't reach:
//   1. the `reactions` subcollection (Firestore doesn't cascade-delete),
//   2. extra Storage objects on multi-media posts ({postId}_1, _2, … and the
//      *_thumb.jpg variants), and
//   3. the chat mirror messages (reply/reaction) that snapshotted the post's
//      thumbnail — we strip the dead image so DMs don't show a now-deleted
//      post. The reply TEXT is left intact (it's the sender's own message);
//      only `postMediaURL` is removed and `postDeleted: true` is stamped so
//      the bubble renders "post no longer available".
// Still NOT touched: aggregate place counters (a past visit/engagement
// genuinely happened).
exports.onPostDelete = functions.firestore
  .document("posts/{postId}")
  .onDelete(async (snap, context) => {
    const postId = context.params.postId;
    const d = snap.data() || {};
    const authorId = d.authorId;

    try {
      await deleteCollection(
        admin.firestore().collection("posts").doc(postId).collection("reactions"),
      );
    } catch (e) {
      logger.warn("[POST DELETE] reactions cleanup failed", {
        postId,
        error: String(e),
      });
    }

    // Wipe every Storage object for this post. Post ids are fixed-length
    // Firestore auto-ids, so `{postId}` can't be a prefix of another post's
    // id — the prefix match is safe and catches all media + thumbnails.
    if (authorId) {
      try {
        await admin.storage().bucket().deleteFiles({
          prefix: `social/${authorId}/${postId}`,
        });
      } catch (e) {
        logger.warn("[POST DELETE] storage cleanup failed", {
          postId,
          error: String(e),
        });
      }
    }

    // Scrub the post's image from every chat mirror that referenced it (a
    // collection-group query over all conversations' messages). Single-field
    // equality on `postId` uses the automatic index — no custom index needed.
    try {
      const mirrors = await admin.firestore()
        .collectionGroup("messages")
        .where("postId", "==", postId)
        .get();
      const docs = mirrors.docs;
      for (let i = 0; i < docs.length; i += 400) {
        const batch = admin.firestore().batch();
        for (const doc of docs.slice(i, i + 400)) {
          batch.update(doc.ref, {
            postDeleted: true,
            postMediaURL: admin.firestore.FieldValue.delete(),
          });
        }
        await batch.commit();
      }
    } catch (e) {
      logger.warn("[POST DELETE] chat mirror scrub failed", {
        postId,
        error: String(e),
      });
    }
  });

// Phase 3 — Session-aware visit counting. Every tagged post might be a
// fresh visit OR a continuation of one already in progress (5 photos at
// the same cafe in one sitting = 1 visit, not 5). We track per-user-per-
// place "visit sessions" at users/{uid}/visits/{placeId}:
//   - openedAt        : when the session started (server stamp)
//   - firstPostLat/Lng: place coords at session-open time, used by the
//                       client tracker to decide when the user has
//                       physically moved far enough to "close" the
//                       session.
//   - closed          : false while still on-site, true after the client
//                       observes the user > ~3 km away.
//   - visitCount      : per-user count of *closed* sessions (i.e. real
//                       returns), excluding the still-open one.
//
// We only bump the place's `globalVisitCount` when this post opens a NEW
// session. Same-session subsequent posts just refresh `openedAt`.
exports.onPostCreatePlaceVisit = functions.firestore
  .document("posts/{postId}")
  .onCreate(async (snap, context) => {
    const postId = context.params.postId;
    const d = snap.data();
    logger.info("[VISIT] trigger fired", {
      postId,
      hasData: !!d,
      placeId: d && d.placeId,
      authorId: d && d.authorId,
    });
    if (!d || !d.authorId) {
      logger.warn("[VISIT] aborted — missing authorId", { postId });
      return;
    }
    const uid = d.authorId;
    // A post can tag several photos at different places; open/refresh a visit
    // for EACH distinct place. Legacy single-place posts fall back to d.placeId.
    const placeIds = Array.isArray(d.media)
      ? [...new Set(d.media.map((m) => m && m.placeId).filter(Boolean))]
      : (d.placeId ? [d.placeId] : []);
    if (placeIds.length === 0) {
      logger.warn("[VISIT] aborted — no placeId(s)", { postId });
      return;
    }
    const db = admin.firestore();
    const userRef = db.collection("users").doc(uid);

    for (const placeId of placeIds) {
      const placeRef = db.collection("places").doc(placeId);
      const visitRef = db.collection("users").doc(uid)
        .collection("visits").doc(placeId);
      try {
      // Wrap in a transaction so two posts firing back-to-back can't both
      // observe "no visit doc yet" and double-bump the global counter.
      // Firestore retries the txn on conflict, so the second invocation
      // re-reads the visit doc the first one just wrote.
      let txnAttempt = 0;
      const result = await db.runTransaction(async (tx) => {
        txnAttempt += 1;
        const [placeSnap, visitSnap, userSnap] = await Promise.all([
          tx.get(placeRef),
          tx.get(visitRef),
          tx.get(userRef),
        ]);
        if (!placeSnap.exists) {
          logger.warn("[VISIT] place doc missing", { placeId, postId });
          return { skipped: "no-place" };
        }
        const place = placeSnap.data() || {};
        const visit = visitSnap.exists ? (visitSnap.data() || {}) : null;
        const user = userSnap.exists ? (userSnap.data() || {}) : {};

        const isNewSession = !visit || visit.closed === true;
        // "Truly new" = the user has never had a visit doc for this place.
        // Used to bump unique-place counters that drive Wanderer / Local
        // Guide achievements.
        const isFirstEverVisit = !visit;
        logger.info("[VISIT] decision", {
          postId,
          placeId,
          uid,
          attempt: txnAttempt,
          visitExists: visitSnap.exists,
          visitClosed: visit ? visit.closed : null,
          visitOpenedAt: visit && visit.openedAt
            ? visit.openedAt.toDate().toISOString() : null,
          currentGlobalVisitCount: place.globalVisitCount || 0,
          isNewSession,
          isFirstEverVisit,
        });

        if (isNewSession) {
          tx.update(placeRef, {
            globalVisitCount: admin.firestore.FieldValue.increment(1),
            lastVisitedAt: admin.firestore.FieldValue.serverTimestamp(),
          });
          tx.set(visitRef, {
            openedAt: admin.firestore.FieldValue.serverTimestamp(),
            firstPostLat: place.lat,
            firstPostLng: place.lng,
            closed: false,
            // Per-user count of completed (closed) sessions. Bumped by the
            // client tracker when it flips `closed: true`, not here.
            visitCount: visit ? (visit.visitCount || 0) : 0,
          }, { merge: true });

          // Phase 5 — Wanderer + Local Guide stats fire on first-ever
          // visit only. Subsequent re-opens (after a >3 km decay) shouldn't
          // re-count the same place toward "unique places visited".
          if (isFirstEverVisit) {
            const updates = {
              uniquePlacesVisited: admin.firestore.FieldValue.increment(1),
            };
            // Type-specific counters that power the profile page's
            // "Cafés N / Stalls N" stats row and the Coffee Crawler /
            // Stall Stalker achievements. Restaurants don't have a
            // dedicated tile in the UI — they only roll up into
            // uniquePlacesVisited above.
            if (place.type === "cafe") {
              updates.cafesVisited = admin.firestore.FieldValue.increment(1);
            } else if (place.type === "stall") {
              updates.stallsVisited = admin.firestore.FieldValue.increment(1);
            }
            if (typeof place.lat === "number" && typeof place.lng === "number") {
              const area = geofire.geohashForLocation([place.lat, place.lng], 5);
              const counts = (user.areaPlaceCounts && typeof user.areaPlaceCounts === "object")
                ? { ...user.areaPlaceCounts } : {};
              counts[area] = (counts[area] || 0) + 1;
              updates.areaPlaceCounts = counts;
              const newTop = Math.max(...Object.values(counts), 0);
              if (newTop > (user.topAreaPlaceCount || 0)) {
                updates.topAreaPlaceCount = newTop;
              }
            }
            tx.set(userRef, updates, { merge: true });
          }
          return { action: "opened-new-session", isFirstEverVisit };
        }
        // Same-session repost — refresh openedAt only. Place counter
        // stays put.
        tx.set(visitRef, {
          openedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        return { action: "refreshed-session" };
      });
      logger.info("[VISIT] committed", {
        postId,
        placeId,
        uid,
        attempts: txnAttempt,
        result,
      });
      } catch (err) {
        logger.error("[VISIT] failed", {
          postId,
          placeId,
          uid,
          message: err && err.message,
          stack: err && err.stack,
        });
      }
    }
  });

// Phase 3 — Engagement counter for the upcoming Discover surface.
// Reactions and replies on a tagged post count as "engagement" for the
// underlying place. We aggregate to `places/{placeId}.globalEngagementCount`
// so the recommender can rank by place-level activity without scanning
// every post / message at query time.
exports.onReactionEngagement = functions.firestore
  .document("posts/{postId}/reactions/{reactorUid}")
  .onCreate(async (_snap, context) => {
    const postSnap = await admin.firestore()
      .doc(`posts/${context.params.postId}`).get();
    const post = postSnap.data();
    if (!post) return;
    const updates = [];
    // Place-level engagement counter (Discover ranking input).
    if (post.placeId) {
      updates.push(
        admin.firestore().collection("places").doc(post.placeId).update({
          globalEngagementCount: admin.firestore.FieldValue.increment(1),
        }).catch((err) => {
          logger.warn("onReactionEngagement place update failed", {
            placeId: post.placeId, message: err && err.message,
          });
        }),
      );
    }
    // Phase 5 — Tastemaker counter on the post author. Track total
    // reactions received so the achievement can fire at 50.
    if (post.authorId && post.authorId !== context.params.reactorUid) {
      updates.push(
        admin.firestore().collection("users").doc(post.authorId).set(
          { reactionsReceived: admin.firestore.FieldValue.increment(1) },
          { merge: true },
        ).catch((err) => {
          logger.warn("onReactionEngagement reactionsReceived update failed", {
            uid: post.authorId, message: err && err.message,
          });
        }),
      );
    }
    await Promise.all(updates);
  });

// Phase 5 — Loyal achievement counter. Watches per-user-per-place visit
// docs; when one transitions from open → closed (the client tracker writes
// `closed: true` and increments `visitCount` once the user has moved >3 km
// away), update the user's `topPlaceVisitCount` if this place's running
// total is now their highest.
exports.onVisitClose = functions.firestore
  .document("users/{uid}/visits/{placeId}")
  .onUpdate(async (change, context) => {
    const before = change.before.data();
    const after = change.after.data();
    if (!before || !after) return;
    if (before.closed === true || after.closed !== true) return;
    const visitCount = after.visitCount || 0;
    const userRef = admin.firestore().collection("users").doc(context.params.uid);
    try {
      const snap = await userRef.get();
      const top = snap.data()?.topPlaceVisitCount || 0;
      if (visitCount > top) {
        await userRef.set(
          { topPlaceVisitCount: visitCount },
          { merge: true },
        );
      }
    } catch (err) {
      logger.warn("onVisitClose failed", {
        uid: context.params.uid,
        placeId: context.params.placeId,
        message: err && err.message,
      });
    }
  });

exports.onReplyEngagement = functions.firestore
  .document("conversations/{convId}/messages/{msgId}")
  .onCreate(async (snap, _context) => {
    const m = snap.data();
    if (!m || m.kind !== "reply" || !m.postId) return;
    const postSnap = await admin.firestore().doc(`posts/${m.postId}`).get();
    const post = postSnap.data();
    if (!post || !post.placeId) return;
    try {
      await admin.firestore().collection("places").doc(post.placeId).update({
        globalEngagementCount: admin.firestore.FieldValue.increment(1),
      });
    } catch (err) {
      logger.warn("onReplyEngagement failed", {
        placeId: post.placeId,
        message: err && err.message,
      });
    }
  });

// Push notification to the *other* participant when a new chat message
// lands. Fans out to all of the recipient's FCM tokens via sendToUser.
// Body is chosen to match what the client renders in the inbox preview
// so the user reads the same string in both places.
//
// NOTE: not deployed yet. Run `firebase deploy --only functions:onNewMessage`
// from the repo root once you're ready to enable chat push.
exports.onNewMessage = functions.firestore
  .document("conversations/{convId}/messages/{msgId}")
  .onCreate(async (snap, context) => {
    const m = snap.data();
    if (!m) return;
    const senderId = m.senderId;
    if (!senderId) return;

    const convSnap = await admin
      .firestore()
      .doc(`conversations/${context.params.convId}`)
      .get();
    const conv = convSnap.data();
    if (!conv || !Array.isArray(conv.participantIds)) return;

    const recipient = conv.participantIds.find((id) => id !== senderId);
    if (!recipient) return;

    // Resolve a friendly sender label from users/{uid}; fall back to
    // "Someone" if the doc is missing or the field is empty.
    let senderName = "Someone";
    try {
      const userSnap = await admin.firestore().doc(`users/${senderId}`).get();
      const u = userSnap.data();
      senderName =
        (u && (u.displayName || u.username)) || senderName;
    } catch (err) {
      logger.warn("onNewMessage sender lookup failed", {
        senderId,
        message: err && err.message,
      });
    }

    // Mirror the inbox preview shape so the push body matches what the
    // user sees in the conversation list when they open the app.
    let body;
    if (m.kind === "reaction") {
      body = `Reacted ${m.emoji || "•"} to your post`;
    } else if (m.kind === "reply") {
      const snippet = (m.text || "").trim().slice(0, 80);
      body = snippet ? `Replied: ${snippet}` : "Replied to your post";
    } else {
      body = (m.text || "").trim().slice(0, 120) || "New message";
    }

    await sendToUser(recipient, senderName, body, {
      type: "message",
      convId: context.params.convId,
      senderId,
    });
  });

exports.onReaction = functions.firestore
  .document("posts/{postId}/reactions/{reactorUid}")
  .onCreate(async (snap, context) => {
    const postSnap = await admin.firestore().doc(`posts/${context.params.postId}`).get();
    const post = postSnap.data();
    if (!post) return;
    const authorId = post.authorId;
    if (authorId === context.params.reactorUid) return;
    const d = snap.data();
    const emoji = d && d.emoji ? d.emoji : "❤️";
    await sendToUser(authorId, "Reaction", `Someone reacted with ${emoji}`, {
      type: "reaction",
      postId: context.params.postId,
    });
  });

// ─── AI character generation ──────────────────────────────────────────────
// Calls Replicate's Flux Schnell model to render a cafe mascot, then mirrors
// the result into Firebase Storage so we own a persistent URL (Replicate's
// delivery URLs expire in ~1 hour).
//
// Client call (iOS):
//   Functions.functions().httpsCallable("generateCharacter")
//     .call(["prompt": "...", "seed": "..."])
// Returns: { imageURL: "https://storage.googleapis.com/..." }
exports.generateCharacter = onCall(
  {
    secrets: [REPLICATE_API_TOKEN],
    timeoutSeconds: 60,
    memory: "512MiB",
  },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in to generate a character.");
    }

    const prompt = request.data?.prompt;
    const seed = request.data?.seed;

    if (typeof prompt !== "string" || prompt.length === 0 || prompt.length > 2000) {
      throw new HttpsError("invalid-argument", "Invalid prompt.");
    }
    if (typeof seed !== "string" || seed.length === 0 || seed.length > 200) {
      throw new HttpsError("invalid-argument", "Invalid seed.");
    }

    logger.info("generateCharacter: start", {
      uid,
      promptLength: prompt.length,
      seedLength: seed.length,
    });

    // 1. Call Replicate synchronously (Flux Schnell ≈ 2-4s end-to-end).
    const predictionResp = await fetch(
      "https://api.replicate.com/v1/models/black-forest-labs/flux-schnell/predictions",
      {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${REPLICATE_API_TOKEN.value()}`,
          "Content-Type": "application/json",
          "Prefer": "wait",
        },
        body: JSON.stringify({
          input: {
            prompt,
            aspect_ratio: "1:1",
            num_outputs: 1,
            output_format: "png",
            output_quality: 90,
            go_fast: true,
          },
        }),
      },
    );

    if (!predictionResp.ok) {
      const body = await predictionResp.text();
      logger.error("Replicate HTTP error", {
        status: predictionResp.status,
        body: body.slice(0, 500),
      });
      throw new HttpsError("internal", "Image generation failed.");
    }

    const prediction = await predictionResp.json();
    if (
      prediction.status !== "succeeded" ||
      !Array.isArray(prediction.output) ||
      prediction.output.length === 0
    ) {
      logger.error("Replicate unexpected response", {
        status: prediction.status,
        error: prediction.error,
      });
      throw new HttpsError("internal", "Generation didn't complete.");
    }

    const generatedURL = prediction.output[0];
    logger.info("Replicate returned image", { predictionId: prediction.id });

    // 2. Download the generated PNG.
    const imgResp = await fetch(generatedURL);
    if (!imgResp.ok) {
      logger.error("Failed to download Replicate image", { status: imgResp.status });
      throw new HttpsError("internal", "Couldn't fetch generated image.");
    }
    const imgBuffer = Buffer.from(await imgResp.arrayBuffer());

    // 3. Mirror it into Firebase Storage. Public URL so the client (and any
    //    shared cafe doc) can load it without extra auth dance.
    const bucket = admin.storage().bucket();
    const safeSeed = seed.replace(/[^a-zA-Z0-9_-]/g, "").slice(0, 80) || "char";
    const filename = `characters/${uid}/${safeSeed}-${Date.now()}.png`;
    const file = bucket.file(filename);
    await file.save(imgBuffer, {
      metadata: {
        contentType: "image/png",
        cacheControl: "public, max-age=31536000, immutable",
      },
    });
    await file.makePublic();
    const publicURL = `https://storage.googleapis.com/${bucket.name}/${filename}`;

    logger.info("generateCharacter: success", { filename });
    return { imageURL: publicURL };
  },
);

// ─── Stats backfill (Phase 5 retroactive) ────────────────────────────────
// One-shot callable that recomputes the Phase 5 counters from existing
// data, so users who had history before the triggers were deployed don't
// stare at 0 unlocked achievements forever. Self-service: each user
// backfills their own stats — no admin needed.
//
// Recomputes:
//   pioneerCount         ← places where createdBy == uid
//   uniquePlacesVisited  ← count of users/{uid}/visits/{placeId} docs
//   topPlaceVisitCount   ← max(visitCount) across those visit docs
//   topAreaPlaceCount    ← max count of distinct places per geohash5 cell
//   areaPlaceCounts      ← { geohash5 → count } map
//   reactionsReceived    ← total reactions across this user's posts
exports.backfillMyStats = onCall(
  { timeoutSeconds: 60, memory: "256MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in.");
    const db = admin.firestore();

    // Run the four queries in parallel — they're independent.
    const [pioneerSnap, visitsSnap, postsSnap] = await Promise.all([
      db.collection("places").where("createdBy", "==", uid).get(),
      db.collection("users").doc(uid).collection("visits").get(),
      db.collection("posts").where("authorId", "==", uid).get(),
    ]);

    const pioneerCount = pioneerSnap.size;

    // Source of truth for "places I've been" is the user's own posts —
    // the visit subcollection is a derived view written by the
    // `onPostCreatePlaceVisit` trigger and can drift out of sync if the
    // trigger ever skipped a post (network blip, race, code regression).
    // Compute from posts so backfill self-heals any historical gap.
    const distinctPlaceIds = [...new Set(
      postsSnap.docs
        .map((p) => (p.data() || {}).placeId)
        .filter((id) => typeof id === "string" && id.length > 0),
    )];

    // Fan-out fetch for each unique place — bounded by the user's
    // distinct-place count, typically tens not thousands.
    const placeDocs = await Promise.all(
      distinctPlaceIds.map((id) => db.collection("places").doc(id).get()),
    );

    const uniquePlacesVisited = placeDocs.filter((p) => p.exists).length;
    let cafesVisited = 0;
    let stallsVisited = 0;
    for (const p of placeDocs) {
      if (!p.exists) continue;
      const t = (p.data() || {}).type;
      if (t === "cafe") cafesVisited += 1;
      else if (t === "stall") stallsVisited += 1;
    }

    // `topPlaceVisitCount` still comes from the visits subcollection — it
    // depends on completed (closed) sessions per place, which is a
    // user-behavior signal we don't try to reconstruct from posts. If the
    // visits are out of sync this'll lag; we'll heal those in a separate
    // pass if it ever matters.
    const visitDocs = visitsSnap.docs;
    let topPlaceVisitCount = 0;
    for (const v of visitDocs) {
      const c = (v.data() && v.data().visitCount) || 0;
      if (c > topPlaceVisitCount) topPlaceVisitCount = c;
    }

    // Build areaPlaceCounts from the canonical place docs (already fetched
    // above for the type tally). Drives Local Guide. Skips places that
    // didn't return a doc — e.g. a place that was deleted after the user
    // posted at it.
    const areaPlaceCounts = {};
    for (const p of placeDocs) {
      if (!p.exists) continue;
      const d = p.data() || {};
      if (typeof d.lat !== "number" || typeof d.lng !== "number") continue;
      const area = geofire.geohashForLocation([d.lat, d.lng], 5);
      areaPlaceCounts[area] = (areaPlaceCounts[area] || 0) + 1;
    }
    const topAreaPlaceCount = Object.values(areaPlaceCounts).reduce(
      (m, n) => Math.max(m, n), 0,
    );

    // reactionsReceived — sum the size of each post's reactions
    // subcollection. Cap to first 200 posts to keep this bounded; for
    // anyone past that this becomes a paid problem and a stretch goal.
    let reactionsReceived = 0;
    const postRefs = postsSnap.docs.slice(0, 200);
    if (postRefs.length > 0) {
      const counts = await Promise.all(postRefs.map(async (p) => {
        try {
          const rxn = await p.ref.collection("reactions").get();
          // Self-reactions are excluded by `onReactionEngagement`, so
          // mirror that here for parity.
          return rxn.docs.filter((r) => r.id !== uid).length;
        } catch (_e) {
          return 0;
        }
      }));
      reactionsReceived = counts.reduce((a, b) => a + b, 0);
    }

    await db.collection("users").doc(uid).set({
      pioneerCount,
      uniquePlacesVisited,
      topPlaceVisitCount,
      topAreaPlaceCount,
      areaPlaceCounts,
      reactionsReceived,
      cafesVisited,
      stallsVisited,
    }, { merge: true });

    logger.info("backfillMyStats committed", {
      uid,
      pioneerCount,
      uniquePlacesVisited,
      topPlaceVisitCount,
      topAreaPlaceCount,
      areaCount: Object.keys(areaPlaceCounts).length,
      reactionsReceived,
      cafesVisited,
      stallsVisited,
    });
    return {
      pioneerCount,
      uniquePlacesVisited,
      topPlaceVisitCount,
      topAreaPlaceCount,
      reactionsReceived,
      cafesVisited,
      stallsVisited,
    };
  },
);

// ─── Friend graph (Phase 4) ──────────────────────────────────────────────
// Server-owned friend acceptance + removal. The corresponding rules deny
// direct client writes to `users/{uid}/friends/{friendUid}`, so all
// friendship mutations must come through these callables. Two reasons:
//   1. The "20 friends max" cap is enforced consistently — every side of
//      a friendship runs through the same gatekeeper.
//   2. Both sides of the relationship are written atomically inside a
//      transaction; a partial commit can't leave one user thinking they
//      have a friend the other doesn't.

const FRIENDS_MAX = 20;

exports.acceptFriendRequest = onCall(
  { timeoutSeconds: 15, memory: "256MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in to accept.");
    const requestId = request.data?.requestId;
    if (typeof requestId !== "string" || requestId.length === 0) {
      throw new HttpsError("invalid-argument", "Missing requestId.");
    }

    const db = admin.firestore();
    const reqRef = db.collection("friendRequests").doc(requestId);
    const meRef = db.collection("users").doc(uid);

    return await db.runTransaction(async (tx) => {
      const reqSnap = await tx.get(reqRef);
      if (!reqSnap.exists) {
        throw new HttpsError("not-found", "Request no longer exists.");
      }
      const r = reqSnap.data();
      if (r.toUid !== uid) {
        throw new HttpsError("permission-denied", "Not your request to accept.");
      }
      if (r.status !== "pending") {
        throw new HttpsError("failed-precondition", "Already handled.");
      }

      const otherRef = db.collection("users").doc(r.fromUid);

      // Run the cap checks inside the same transaction — if a concurrent
      // accept happens while this one is in flight, the second commit
      // fails and Firestore retries with the new size.
      const [mySize, otherSize] = await Promise.all([
        tx.get(meRef.collection("friends")).then((s) => s.size),
        tx.get(otherRef.collection("friends")).then((s) => s.size),
      ]);
      if (mySize >= FRIENDS_MAX) {
        throw new HttpsError(
          "resource-exhausted",
          `You're at the ${FRIENDS_MAX}-friend limit.`,
        );
      }
      if (otherSize >= FRIENDS_MAX) {
        throw new HttpsError(
          "resource-exhausted",
          `${r.fromUsername || "They"} hit the ${FRIENDS_MAX}-friend limit first.`,
        );
      }

      tx.update(reqRef, { status: "accepted" });
      tx.set(meRef.collection("friends").doc(r.fromUid), {
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      tx.set(otherRef.collection("friends").doc(uid), {
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return { ok: true };
    });
  },
);

exports.removeFriend = onCall(
  { timeoutSeconds: 10, memory: "256MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in.");
    const otherUid = request.data?.uid;
    if (typeof otherUid !== "string" || otherUid.length === 0) {
      throw new HttpsError("invalid-argument", "Missing uid.");
    }
    if (otherUid === uid) {
      throw new HttpsError("invalid-argument", "Cannot remove yourself.");
    }

    const db = admin.firestore();
    const batch = db.batch();
    batch.delete(
      db.collection("users").doc(uid).collection("friends").doc(otherUid),
    );
    batch.delete(
      db.collection("users").doc(otherUid).collection("friends").doc(uid),
    );
    await batch.commit();
    return { ok: true };
  },
);

// ─── Place dedup / create ────────────────────────────────────────────────
// Single source-of-truth for inserting into the `places` collection.
// Dedup priority:
//   1. exact match on googlePlaceId (preferred — Google's stable ID)
//   2. fuzzy name match within ~75m radius (handles user-added stalls)
// Returns { placeId, placeName, created } so the client can stamp the post
// with placeId immediately and update its UI.
const PLACE_TYPES = new Set(["cafe", "stall", "restaurant"]);
const PLACE_NEARBY_RADIUS_METERS = 75;

function normalizeName(s) {
  return String(s || "")
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

exports.findOrCreatePlace = onCall(
  { timeoutSeconds: 15, memory: "256MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in to tag a place.");
    }

    const { name, type, lat, lng, googlePlaceId, address } = request.data || {};
    const cleanName = String(name || "").trim();
    // Optional formatted address (from Google Places) — stored so the client
    // can derive a city label without reverse-geocoding.
    const cleanAddress = typeof address === "string"
      ? address.trim().slice(0, 300)
      : null;
    if (cleanName.length < 1 || cleanName.length > 120) {
      throw new HttpsError("invalid-argument", "Place name required (1–120 chars).");
    }
    if (!PLACE_TYPES.has(type)) {
      throw new HttpsError("invalid-argument", "Unknown place type.");
    }
    if (typeof lat !== "number" || typeof lng !== "number" ||
        lat < -90 || lat > 90 || lng < -180 || lng > 180) {
      throw new HttpsError("invalid-argument", "Valid lat/lng required.");
    }

    const db = admin.firestore();
    const placesCol = db.collection("places");

    // 1) Google place_id is the strongest dedup signal.
    if (typeof googlePlaceId === "string" && googlePlaceId.length > 0) {
      const existing = await placesCol
        .where("googlePlaceId", "==", googlePlaceId)
        .limit(1)
        .get();
      if (!existing.empty) {
        const doc = existing.docs[0];
        return { placeId: doc.id, placeName: doc.data().name, created: false };
      }
    }

    // 2) Fuzzy match within radius via geohash bounds.
    const center = [lat, lng];
    const bounds = geofire.geohashQueryBounds(center, PLACE_NEARBY_RADIUS_METERS);
    const normalized = normalizeName(cleanName);
    const matches = [];
    for (const b of bounds) {
      const snap = await placesCol
        .orderBy("geohash")
        .startAt(b[0])
        .endAt(b[1])
        .get();
      for (const d of snap.docs) {
        const data = d.data();
        const dist = geofire.distanceBetween([data.lat, data.lng], center) * 1000;
        if (dist > PLACE_NEARBY_RADIUS_METERS) continue;
        if (normalizeName(data.name) === normalized) {
          matches.push({ id: d.id, data });
        }
      }
    }
    if (matches.length > 0) {
      const m = matches[0];
      return { placeId: m.id, placeName: m.data.name, created: false };
    }

    // 3) Create — transaction re-checks googlePlaceId to close the race.
    // On conflict (RACE_LOST), re-read the winning row outside the txn.
    const RACE_LOST = "race-lost";
    const newRef = placesCol.doc();
    const geohash = geofire.geohashForLocation(center);
    try {
      await db.runTransaction(async (tx) => {
        if (typeof googlePlaceId === "string" && googlePlaceId.length > 0) {
          const recheck = await tx.get(
            placesCol.where("googlePlaceId", "==", googlePlaceId).limit(1),
          );
          if (!recheck.empty) {
            throw new Error(RACE_LOST);
          }
        }
        tx.set(newRef, {
          name: cleanName,
          type,
          lat,
          lng,
          geohash,
          source: googlePlaceId ? "google" : "user",
          googlePlaceId: googlePlaceId || null,
          address: cleanAddress || null,
          createdBy: uid,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          globalVisitCount: 0,
          globalEngagementCount: 0,
          lastVisitedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        // Phase 5 — Pioneer achievement counter. The user that creates a
        // brand-new place gets credit for "found it first".
        tx.set(
          db.collection("users").doc(uid),
          { pioneerCount: admin.firestore.FieldValue.increment(1) },
          { merge: true },
        );
      });
    } catch (err) {
      if (err && err.message === RACE_LOST) {
        const winner = await placesCol
          .where("googlePlaceId", "==", googlePlaceId)
          .limit(1)
          .get();
        if (!winner.empty) {
          const w = winner.docs[0];
          return { placeId: w.id, placeName: w.data().name, created: false };
        }
      }
      throw err;
    }

    return { placeId: newRef.id, placeName: cleanName, created: true };
  },
);

// ─── Account deletion cascade ────────────────────────────────────────────
// Required by App Store Guideline 5.1.1(v): apps that create accounts must
// offer an in-app delete that *actually* removes data. The iOS client calls
// this callable, then `Auth.auth().currentUser.delete()` to nuke the Firebase
// Auth user itself. This function must complete before the auth user is
// deleted because admin SDK calls outlive the user's auth state but the
// client doesn't.
//
// Cascade order (each step idempotent so partial failures are safe to retry):
//   1. Free the username reservation (so it can be re-claimed).
//   2. Delete posts authored by uid + their reactions subcollections.
//   3. Delete conversations the user participated in + every message.
//   4. Delete both sides of every friendship edge.
//   5. Delete FCM tokens subcollection.
//   6. Delete the user doc itself.
//   7. Delete Storage objects under avatars/{uid}/ and social/{uid}/.
//
// Timeout bumped to 540s (max for callable v2) — a heavy user could have
// thousands of messages + posts. The function streams batches of 400 to
// stay under Firestore's 500-op batch limit.
exports.deleteMyAccount = onCall(
  { timeoutSeconds: 540, memory: "512MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in.");

    const db = admin.firestore();
    const storage = admin.storage();

    // 1. Free the username reservation. Reading the user doc first so
    //    we know which `usernames/{lower}` doc to free.
    const userRef = db.collection("users").doc(uid);
    const userSnap = await userRef.get();
    const usernameLower = userSnap.data()?.usernameLower;

    // Helper: chunk delete a list of doc refs using batched commits.
    async function deleteAll(refs) {
      let batch = db.batch();
      let n = 0;
      for (const ref of refs) {
        batch.delete(ref);
        n++;
        if (n >= 400) {
          await batch.commit();
          batch = db.batch();
          n = 0;
        }
      }
      if (n > 0) await batch.commit();
    }

    // 2. Delete posts authored by uid + reactions subcollections.
    const postsSnap = await db.collection("posts")
      .where("authorId", "==", uid)
      .get();
    for (const postDoc of postsSnap.docs) {
      const reactionsSnap = await postDoc.ref.collection("reactions").get();
      await deleteAll(reactionsSnap.docs.map((d) => d.ref));
      await postDoc.ref.delete();
    }
    logger.info(`[deleteMyAccount] ${uid}: deleted ${postsSnap.size} posts`);

    // 3. Conversations + nested messages. participantIds array-contains
    //    is the canonical "I'm in this conversation" query.
    const convsSnap = await db.collection("conversations")
      .where("participantIds", "array-contains", uid)
      .get();
    for (const convDoc of convsSnap.docs) {
      const messagesSnap = await convDoc.ref.collection("messages").get();
      await deleteAll(messagesSnap.docs.map((d) => d.ref));
      await convDoc.ref.delete();
    }
    logger.info(`[deleteMyAccount] ${uid}: deleted ${convsSnap.size} conversations`);

    // 4. Both sides of every friend edge.
    const friendsSnap = await userRef.collection("friends").get();
    const friendUids = friendsSnap.docs.map((d) => d.id);
    const friendRefs = [
      ...friendsSnap.docs.map((d) => d.ref),
      ...friendUids.map((other) =>
        db.collection("users").doc(other).collection("friends").doc(uid)),
    ];
    await deleteAll(friendRefs);
    logger.info(`[deleteMyAccount] ${uid}: removed ${friendUids.length} friend edges`);

    // 5. FCM tokens — also tidied up locally before the call, but cover
    //    the case where the client lost connectivity mid-delete.
    const tokensSnap = await userRef.collection("fcmTokens").get();
    await deleteAll(tokensSnap.docs.map((d) => d.ref));

    // 6. Pending friend requests (both directions).
    const inboundRequests = await db.collection("friendRequests")
      .where("toUid", "==", uid)
      .get();
    const outboundRequests = await db.collection("friendRequests")
      .where("fromUid", "==", uid)
      .get();
    await deleteAll([
      ...inboundRequests.docs.map((d) => d.ref),
      ...outboundRequests.docs.map((d) => d.ref),
    ]);

    // 7. Free the username and then delete the user doc itself.
    if (usernameLower) {
      await db.collection("usernames").doc(usernameLower).delete();
    }
    await userRef.delete();

    // 8. Storage. deleteFiles({ prefix }) handles paginated listing for us.
    //    Errors from missing folders are non-fatal.
    try {
      await storage.bucket().deleteFiles({ prefix: `avatars/${uid}/` });
    } catch (e) {
      logger.warn(`[deleteMyAccount] ${uid}: avatars cleanup: ${e.message}`);
    }
    try {
      await storage.bucket().deleteFiles({ prefix: `social/${uid}/` });
    } catch (e) {
      logger.warn(`[deleteMyAccount] ${uid}: social cleanup: ${e.message}`);
    }

    logger.info(`[deleteMyAccount] ${uid}: cascade complete`);
    return { ok: true };
  },
);

// ─── Block / unblock (App Store Guideline 1.2) ───────────────────────────
// Writes the block record + tears down any existing friendship in one batch.
// Rules + client filters use users/{uid}/blockedUsers/{otherUid} to suppress
// the blocked user's posts in the feed and their messages in the inbox.
exports.blockUser = onCall(
  { timeoutSeconds: 10, memory: "256MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in.");
    const otherUid = request.data?.uid;
    if (typeof otherUid !== "string" || otherUid.length === 0) {
      throw new HttpsError("invalid-argument", "Missing uid.");
    }
    if (otherUid === uid) {
      throw new HttpsError("invalid-argument", "Cannot block yourself.");
    }

    const db = admin.firestore();
    const batch = db.batch();
    batch.set(
      db.collection("users").doc(uid)
        .collection("blockedUsers").doc(otherUid),
      { blockedAt: admin.firestore.FieldValue.serverTimestamp() },
    );
    // Friendship goes away in both directions.
    batch.delete(
      db.collection("users").doc(uid).collection("friends").doc(otherUid),
    );
    batch.delete(
      db.collection("users").doc(otherUid).collection("friends").doc(uid),
    );
    await batch.commit();
    return { ok: true };
  },
);

exports.unblockUser = onCall(
  { timeoutSeconds: 10, memory: "256MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in.");
    const otherUid = request.data?.uid;
    if (typeof otherUid !== "string" || otherUid.length === 0) {
      throw new HttpsError("invalid-argument", "Missing uid.");
    }
    await admin.firestore()
      .collection("users").doc(uid)
      .collection("blockedUsers").doc(otherUid)
      .delete();
    return { ok: true };
  },
);

// ─── Report content (App Store Guideline 1.2) ────────────────────────────
// Writes a flag into `reports/{auto}` for moderation review. Server-side
// enforces shape so clients can't push arbitrary fields. We commit in our
// EULA / App Store Connect notes to act on reports within 24 hours.
const ALLOWED_TARGET_TYPES = new Set(["user", "post", "message"]);
const ALLOWED_REPORT_REASONS = new Set([
  "spam",
  "harassment",
  "inappropriate",
  "other",
]);

exports.reportContent = onCall(
  { timeoutSeconds: 10, memory: "256MiB" },
  async (request) => {
    const reporterUid = request.auth?.uid;
    if (!reporterUid) throw new HttpsError("unauthenticated", "Sign in.");
    const data = request.data || {};
    const targetType = data.targetType;
    const targetId = data.targetId;
    const reason = data.reason;
    const details = typeof data.details === "string" ? data.details : null;

    if (!ALLOWED_TARGET_TYPES.has(targetType)) {
      throw new HttpsError("invalid-argument", "Invalid targetType.");
    }
    if (typeof targetId !== "string" || targetId.length === 0) {
      throw new HttpsError("invalid-argument", "Missing targetId.");
    }
    if (!ALLOWED_REPORT_REASONS.has(reason)) {
      throw new HttpsError("invalid-argument", "Invalid reason.");
    }

    const report = {
      reporterUid,
      targetType,
      targetId,
      reason,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      status: "open",
    };
    if (details && details.trim().length > 0) {
      report.details = details.slice(0, 500);
    }
    await admin.firestore().collection("reports").add(report);
    return { ok: true };
  },
);

// ============================================================================
// discoverFeed — network-aware Discover (friend-of-friend + global trending)
// ----------------------------------------------------------------------------
// Replaces the legacy "Creator's Pick" surface with two channels:
//
//   1. circle    — places visited by 2nd-degree connections (friend of a
//                  friend) that neither the caller nor any of their direct
//                  friends has been to yet. Returned WITHOUT uids/usernames —
//                  just an anonymised viaCount so the client can render
//                  "Visited by N people in your circle". Photos (when any)
//                  come ONLY from posts with `discoverable == true` (the
//                  existing consent gate); pins blur them for UX tease.
//
//   2. trending  — places ordered by `globalVisitCount` globally (ignores
//                  proximity), with up to 3 preview photos from
//                  `discoverable == true` posts at that place.
//
// Friend-of-friend traversal MUST live server-side: Firestore rules block
// reading another user's `friends` subcollection. We use the admin SDK to
// fan out, then cache the privacy-scrubbed payload at
// `users/{uid}/discover/cache` with a 6-hour TTL so we don't re-run the
// expensive fan-out on every map load. Pass `force: true` to bypass the
// cache (used for pull-to-refresh).
// ============================================================================

const DISCOVER = {
  CACHE_TTL_MS: 6 * 60 * 60 * 1000,
  F2_HARD_CAP: 400,
  VISITS_PER_F2: 30,
  TOTAL_VISIT_READ_CAP: 4000,   // safety valve — set `partial: true` if hit
  CIRCLE_TOP_N: 50,
  TRENDING_FETCH: 100,
  TRENDING_RETURN: 20,
  TRENDING_PHOTOS: 3,
  IN_QUERY_CHUNK: 30,           // Firestore `in`/documentId-in cap
};

/** Chunk an array into pieces of at most `n` elements. */
function chunk(arr, n) {
  const out = [];
  for (let i = 0; i < arr.length; i += n) out.push(arr.slice(i, i + n));
  return out;
}

/** Read a flat set of doc ids from a subcollection (returns an array of ids). */
async function listSubcollectionIds(ref) {
  const snap = await ref.get();
  return snap.docs.map((d) => d.id);
}

/** Batched `optedOutOfDiscovery` lookup via admin SDK `getAll`. */
async function loadOptOutFlags(db, uids) {
  if (uids.length === 0) return new Map();
  const refs = uids.map((u) => db.collection("users").doc(u));
  const snaps = await db.getAll(...refs);
  return new Map(
    snaps.map((s) => [s.id, !!(s.data() || {}).optedOutOfDiscovery]),
  );
}

/** Shape a place doc into the response wire format (no internal fields). */
function shapePlace(doc, extras = {}) {
  const d = doc.data() || {};
  return {
    placeId: doc.id,
    name: d.name || "",
    type: d.type || "cafe",
    lat: typeof d.lat === "number" ? d.lat : 0,
    lng: typeof d.lng === "number" ? d.lng : 0,
    globalVisitCount: d.globalVisitCount || 0,
    ...extras,
  };
}

/**
 * Three-way classification for a post's photo in Discover surfaces:
 *
 *   "exclude" — never show, not even blurred. Two cases:
 *     1. Classifier detected a face → privacy.
 *     2. Author tapped "Hide from Discover" → respect their explicit choice.
 *        Detected by: discoverable=false BUT the classifier had said
 *        containsFaces=false AND aestheticScore≥0.6 (i.e. it had previously
 *        passed and was flipped off manually).
 *
 *   "blur"    — show, but blurred client-side. Covers:
 *     - classifier-hidden low-aesthetic (containsFaces=false, score<0.6),
 *     - posts that were never classified (no fields present — common on
 *       older devices / older posts).
 *
 *   "clear"   — show full-resolution. Only `discoverable === true` posts.
 *
 * Author-level `optedOutOfDiscovery` is a separate gate applied on top:
 * an opted-out author's "clear" photo is forced to "blur".
 */
function classifyPhoto(data) {
  if (data.containsFaces === true) return "exclude";
  if (
    data.discoverable === false &&
    data.containsFaces === false &&
    typeof data.aestheticScore === "number" &&
    data.aestheticScore >= 0.6
  ) {
    return "exclude";   // author manually hid
  }
  return data.discoverable === true ? "clear" : "blur";
}

exports.discoverFeed = onCall(
  { timeoutSeconds: 60, memory: "512MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in.");
    const force = request.data?.force === true;

    const db = admin.firestore();
    const cacheRef = db.collection("users").doc(uid).collection("discover").doc("cache");

    // 1. Cache short-circuit
    if (!force) {
      const cacheSnap = await cacheRef.get();
      const cached = cacheSnap.data();
      const exp = cached?.expiresAt?.toMillis ? cached.expiresAt.toMillis() : 0;
      if (cached?.payload && exp > Date.now()) {
        return cached.payload;
      }
    }

    // 2. Resolve caller
    const meRef = db.collection("users").doc(uid);
    const [meSnap, friendsIds, blockedIds, callerVisits] = await Promise.all([
      meRef.get(),
      listSubcollectionIds(meRef.collection("friends")),
      listSubcollectionIds(meRef.collection("blockedUsers")),
      listSubcollectionIds(meRef.collection("visits")),
    ]);
    const me = meSnap.data() || {};
    const blockedSet = new Set(blockedIds);
    const F1 = friendsIds.filter((id) => !blockedSet.has(id));
    const visitedSet = new Set(callerVisits);

    const writeCache = async (payload) => {
      try {
        await cacheRef.set({
          payload,
          cachedAt: admin.firestore.FieldValue.serverTimestamp(),
          expiresAt: admin.firestore.Timestamp.fromMillis(
            Date.now() + DISCOVER.CACHE_TTL_MS,
          ),
        });
      } catch (err) {
        logger.warn("[discoverFeed] cache write failed", { uid, message: err?.message });
      }
      return payload;
    };

    // If the caller opted out of discovery, they still receive trending —
    // they just don't contribute to others. Don't short-circuit entirely.
    const callerOptedOut = !!me.optedOutOfDiscovery;

    // 3. Build F2 = (∪ friends-of-friends) \ {self, F1, blocked, opted-out}
    let f2ToVia = new Map(); // f2 uid → Set<f1 uid that bridged>
    if (!callerOptedOut && F1.length > 0) {
      const f1FriendLists = await Promise.all(
        F1.map((f1) =>
          listSubcollectionIds(db.collection("users").doc(f1).collection("friends"))
            .catch(() => []),
        ),
      );
      const f1Set = new Set(F1);
      f1FriendLists.forEach((ids, idx) => {
        const bridge = F1[idx];
        for (const f2 of ids) {
          if (f2 === uid) continue;
          if (f1Set.has(f2)) continue;
          if (blockedSet.has(f2)) continue;
          if (!f2ToVia.has(f2)) f2ToVia.set(f2, new Set());
          f2ToVia.get(f2).add(bridge);
        }
      });

      // Drop opted-out F2 contributors.
      const optOutFlags = await loadOptOutFlags(db, [...f2ToVia.keys()]);
      for (const [f2, opted] of optOutFlags) {
        if (opted) f2ToVia.delete(f2);
      }

      // Hard cap (sort by bridge-count desc to keep the most "connected" F2 first).
      if (f2ToVia.size > DISCOVER.F2_HARD_CAP) {
        const top = [...f2ToVia.entries()]
          .sort((a, b) => b[1].size - a[1].size)
          .slice(0, DISCOVER.F2_HARD_CAP);
        f2ToVia = new Map(top);
      }
    }

    // 4. Aggregate F2 visits → placeId → Set<f2>
    const placeToF2 = new Map(); // placeId → Set<f2 uid>
    let visitReads = 0;
    let partial = false;
    const f2Ids = [...f2ToVia.keys()];

    for (const batch of chunk(f2Ids, 20)) {
      if (visitReads >= DISCOVER.TOTAL_VISIT_READ_CAP) { partial = true; break; }
      await Promise.all(
        batch.map(async (f2) => {
          if (visitReads >= DISCOVER.TOTAL_VISIT_READ_CAP) return;
          try {
            const snap = await db
              .collection("users").doc(f2).collection("visits")
              .orderBy("openedAt", "desc")
              .limit(DISCOVER.VISITS_PER_F2)
              .get();
            visitReads += snap.size;
            for (const doc of snap.docs) {
              const placeId = doc.id;
              if (visitedSet.has(placeId)) continue;  // caller already been
              if (!placeToF2.has(placeId)) placeToF2.set(placeId, new Set());
              placeToF2.get(placeId).add(f2);
            }
          } catch (err) {
            logger.warn("[discoverFeed] visits read failed", { f2, message: err?.message });
          }
        }),
      );
    }

    // Snapshot ALL F2-visited places before F1-removal. Used later to keep
    // Trending honest — any place an F2 visited is "in your circle", even if
    // it didn't make the top-N circle cut, and shouldn't reappear as a
    // stranger surface.
    const f2VisitedAll = new Set(placeToF2.keys());

    // F1 visit exclusion — read each F1's visit doc ids (unconditionally, so
    // we can reuse the set to filter trending below) and remove from placeToF2.
    let f1Visited = new Set();
    if (F1.length > 0) {
      const f1VisitLists = await Promise.all(
        F1.map((f1) =>
          listSubcollectionIds(db.collection("users").doc(f1).collection("visits"))
            .catch(() => []),
        ),
      );
      f1Visited = new Set(f1VisitLists.flat());
      for (const pid of f1Visited) placeToF2.delete(pid);
    }

    // 5. Rank circle places by |F2 set| desc, take top N.
    const circleRanked = [...placeToF2.entries()]
      .sort((a, b) => b[1].size - a[1].size)
      .slice(0, DISCOVER.CIRCLE_TOP_N);
    const circleSet = new Set(circleRanked.map(([pid]) => pid));

    // 6. Fetch each circle place doc + pick ONE photo from posts authored by
    //    any of its F2 contributors. Uses the same exclude/blur/clear
    //    classifier as trending — but since the circle pin ALWAYS renders
    //    its photo blurred (it's a teaser surface), we don't need to
    //    distinguish clear vs blur in the response. We just need to apply
    //    the hard-hide gates (face / author explicit hide) so face photos
    //    never reach a circle pin even at low blur radius.
    const circle = [];
    if (circleRanked.length > 0) {
      const placeSnaps = await db.getAll(
        ...circleRanked.map(([pid]) => db.collection("places").doc(pid)),
      );
      await Promise.all(
        circleRanked.map(async ([pid, f2Set], i) => {
          const placeSnap = placeSnaps[i];
          if (!placeSnap.exists) return;
          let photoURL = null;
          try {
            // Reuse the `(placeId, createdAt DESC)` index — pull recent posts
            // at the place and filter by F2-authorship in code. Cheaper than
            // adding a separate (placeId, authorId, createdAt) composite.
            const q = await db.collection("posts")
              .where("placeId", "==", pid)
              .orderBy("createdAt", "desc")
              .limit(30)
              .get();
            for (const doc of q.docs) {
              const data = doc.data() || {};
              if (!f2Set.has(data.authorId)) continue;
              if (classifyPhoto(data) === "exclude") continue;
              const url = data.mediaURL || data.thumbnailURL;
              if (url) { photoURL = url; break; }
            }
          } catch (err) {
            // Missing index / transient — pin renders a placeholder.
            logger.warn("[discoverFeed] circle photo lookup failed", {
              placeId: pid, message: err?.message,
            });
          }
          circle.push(shapePlace(placeSnap, {
            photoURL,
            viaCount: f2Set.size,
          }));
        }),
      );
      // Preserve rank order (Promise.all randomises completion).
      circle.sort((a, b) => b.viaCount - a.viaCount);
    }

    // 7. Trending — top by globalVisitCount, restricted to places NOBODY in
    //    the caller's relationship graph (self / friends / friends-of-friends)
    //    has visited. Trending is the "pure strangers" surface; anyone with
    //    even a single-hop connection to a place pushes it into the friend
    //    pin layer or the Circle surface instead.
    let trending = [];
    try {
      const trendSnap = await db.collection("places")
        .orderBy("globalVisitCount", "desc")
        .limit(DISCOVER.TRENDING_FETCH)
        .get();
      const candidates = trendSnap.docs.filter((d) => {
        if (visitedSet.has(d.id)) return false;
        if (f1Visited.has(d.id))  return false;   // friend visited → not stranger
        if (f2VisitedAll.has(d.id)) return false; // friend-of-friend visited → not stranger
        const v = (d.data() || {}).globalVisitCount || 0;
        return v > 0;
      }).slice(0, DISCOVER.TRENDING_RETURN);

      // Fetch up to 3 photos per trending place. See `classifyPhoto` for the
      // three-way decision (exclude / blur / clear). Author-level opt-out
      // forces a clear photo to blur. We prefer clear over blurred when both
      // exist at a place, so the trending row leads with the best signal.
      await Promise.all(
        candidates.map(async (doc) => {
          let clearCandidates = [];
          let blurCandidates = [];
          try {
            const q = await db.collection("posts")
              .where("placeId", "==", doc.id)
              .orderBy("createdAt", "desc")
              .limit(20)
              .get();
            for (const p of q.docs) {
              const data = p.data() || {};
              const verdict = classifyPhoto(data);
              if (verdict === "exclude") continue;
              const url = data.mediaURL || data.thumbnailURL;
              if (!url) continue;
              const entry = { url, authorId: data.authorId, verdict };
              if (verdict === "clear") clearCandidates.push(entry);
              else                     blurCandidates.push(entry);
              if (clearCandidates.length + blurCandidates.length >= 20) break;
            }
          } catch (err) {
            logger.warn("[discoverFeed] trending photo lookup failed", {
              placeId: doc.id, message: err?.message,
            });
          }
          // Clear first, blurred as fallback, take top N.
          const merged = [...clearCandidates, ...blurCandidates]
            .slice(0, DISCOVER.TRENDING_PHOTOS);
          const authorIds = [...new Set(
            merged.map((p) => p.authorId).filter(Boolean)
          )];
          const optOuts = authorIds.length > 0
            ? await loadOptOutFlags(db, authorIds)
            : new Map();
          const photos = merged.map((p) => ({
            url: p.url,
            // Already blurred by classifier verdict, OR forced by author opt-out.
            blur: p.verdict === "blur" || optOuts.get(p.authorId) === true,
          }));
          trending.push(shapePlace(doc, { photos }));
        }),
      );
      // Preserve globalVisitCount order (Promise.all randomises completion).
      trending.sort((a, b) => b.globalVisitCount - a.globalVisitCount);
    } catch (err) {
      logger.warn("[discoverFeed] trending query failed", { uid, message: err?.message });
    }

    // 8. Persist cache + return.
    const payload = {
      circle,
      trending,
      cachedAt: Date.now(),
      expiresAt: Date.now() + DISCOVER.CACHE_TTL_MS,
      partial,
    };
    logger.info("[discoverFeed] done", {
      uid,
      f1: F1.length,
      f2: f2ToVia.size,
      circleN: circle.length,
      trendingN: trending.length,
      visitReads,
      partial,
    });
    return await writeCache(payload);
  },
);

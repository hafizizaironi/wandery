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
    if (!d || !d.placeId || !d.authorId) {
      logger.warn("[VISIT] aborted — missing placeId or authorId", { postId });
      return;
    }
    const placeId = d.placeId;
    const uid = d.authorId;
    const db = admin.firestore();
    const placeRef = db.collection("places").doc(placeId);
    const visitRef = db.collection("users").doc(uid)
      .collection("visits").doc(placeId);

    try {
      // Wrap in a transaction so two posts firing back-to-back can't both
      // observe "no visit doc yet" and double-bump the global counter.
      // Firestore retries the txn on conflict, so the second invocation
      // re-reads the visit doc the first one just wrote.
      const userRef = db.collection("users").doc(uid);
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
    const uniquePlacesVisited = visitsSnap.size;

    // topPlaceVisitCount and area buckets need a per-place lookup —
    // each visit doc carries firstPostLat/Lng, but if we want geohash5
    // accuracy from the canonical place we should fetch the place too.
    // Cheaper: fetch every referenced place doc concurrently, build the
    // geohash map from those.
    const visitDocs = visitsSnap.docs;
    let topPlaceVisitCount = 0;
    for (const v of visitDocs) {
      const c = (v.data() && v.data().visitCount) || 0;
      if (c > topPlaceVisitCount) topPlaceVisitCount = c;
    }

    // Build areaPlaceCounts. Use the visit doc's stored lat/lng so we
    // don't need a place fetch — first-post coords are always set on
    // the visit doc by `onPostCreatePlaceVisit`.
    const areaPlaceCounts = {};
    for (const v of visitDocs) {
      const d = v.data() || {};
      if (typeof d.firstPostLat !== "number" || typeof d.firstPostLng !== "number") continue;
      const area = geofire.geohashForLocation([d.firstPostLat, d.firstPostLng], 5);
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
    }, { merge: true });

    logger.info("backfillMyStats committed", {
      uid,
      pioneerCount,
      uniquePlacesVisited,
      topPlaceVisitCount,
      topAreaPlaceCount,
      areaCount: Object.keys(areaPlaceCounts).length,
      reactionsReceived,
    });
    return {
      pioneerCount,
      uniquePlacesVisited,
      topPlaceVisitCount,
      topAreaPlaceCount,
      reactionsReceived,
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

    const { name, type, lat, lng, googlePlaceId } = request.data || {};
    const cleanName = String(name || "").trim();
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

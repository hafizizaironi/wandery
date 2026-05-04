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
          lastVisitedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
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

const functions = require("firebase-functions");
const admin = require("firebase-admin");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const { logger } = require("firebase-functions/v2");

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
    Object.entries(data).map(([k, v]) => [k, String(v)])
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
          Authorization: `Bearer ${REPLICATE_API_TOKEN.value()}`,
          "Content-Type": "application/json",
          Prefer: "wait",
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
      }
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
  }
);

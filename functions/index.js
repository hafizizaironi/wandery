const functions = require("firebase-functions");
const admin = require("firebase-admin");

admin.initializeApp();

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

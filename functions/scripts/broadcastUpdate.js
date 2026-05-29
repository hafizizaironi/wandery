// One-off broadcast push to ALL users — used to tell everyone (including
// people on OLD builds, whose in-app update banner can't reach them) that a
// new version is available. Fans out over every `users/{uid}/fcmTokens/{id}`
// token via a collection-group query, in multicast batches of 500.
//
// Usage (from the `functions/` directory):
//   1. Authenticate locally (one-time):  gcloud auth application-default login
//   2. Set the project:                  export GOOGLE_CLOUD_PROJECT=look-cafe
//   3. Dry run (default — counts only):   node scripts/broadcastUpdate.js
//   4. Send for real:                     node scripts/broadcastUpdate.js --send
//   Optional custom copy:
//      node scripts/broadcastUpdate.js --send --title="..." --body="..."
//
// Stale/unregistered tokens just fail harmlessly and are tallied (not
// deleted). Reusable for any future announcement by overriding --title/--body.

const admin = require("firebase-admin");

const SEND = process.argv.includes("--send");
function arg(name, def) {
  const p = process.argv.find((a) => a.startsWith(name + "="));
  return p ? p.slice(name.length + 1) : def;
}
const TITLE = arg("--title", "A new version is available 🔥");
const BODY = arg("--body", "Update on TestFlight to keep hunting with everyone.");
const DATA = { type: "appUpdate" };

admin.initializeApp();
const db = admin.firestore();

function chunk(arr, n) {
  const out = [];
  for (let i = 0; i < arr.length; i += n) out.push(arr.slice(i, i + n));
  return out;
}

async function main() {
  console.log(`Broadcast: "${TITLE}" — "${BODY}"`);
  console.log(SEND ? "MODE: SEND (push enabled)" : "MODE: DRY RUN (no push)");

  const snap = await db.collectionGroup("fcmTokens").get();
  const tokens = [...new Set(snap.docs.map((d) => d.data().token).filter(Boolean))];
  console.log(`Found ${snap.size} token docs → ${tokens.length} unique tokens.`);

  if (!SEND) {
    console.log("\nRe-run with --send to push to everyone.");
    return;
  }
  if (tokens.length === 0) {
    console.log("No tokens — nothing to send.");
    return;
  }

  let success = 0;
  let failure = 0;
  for (const batch of chunk(tokens, 500)) {
    const res = await admin.messaging().sendEachForMulticast({
      tokens: batch,
      notification: { title: TITLE, body: BODY },
      data: DATA,
    });
    success += res.successCount;
    failure += res.failureCount;
  }

  console.log("\nDone.");
  console.log(JSON.stringify({ uniqueTokens: tokens.length, success, failure }, null, 2));
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});

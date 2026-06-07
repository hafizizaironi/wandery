// Backfill Wandery Code account ids for existing users.
//
// OPTIONAL: lazy minting (the ensureWanderyCode callable, called when a user
// opens My Code) is self-sufficient — you can't scan a code that was never
// shown. Run this only to pre-provision ids for everyone up front.
//
// Dry-run by default; pass --apply to write. Uses Application Default Creds:
//   gcloud auth application-default login
//   GOOGLE_CLOUD_PROJECT=look-cafe node scripts/backfillWanderyCodes.js          # dry run
//   GOOGLE_CLOUD_PROJECT=look-cafe node scripts/backfillWanderyCodes.js --apply  # write

const admin = require("firebase-admin");

admin.initializeApp();
const db = admin.firestore();

const APPLY = process.argv.includes("--apply");
const PAGE_SIZE = 300;
const ACCOUNT_ID_MAX = 2 ** 44;
const randomAccountId = () => Math.floor(Math.random() * (ACCOUNT_ID_MAX - 1)) + 1;

// Mint a unique id (same logic as the ensureWanderyCode callable).
async function mintFor(uid) {
  for (let i = 0; i < 6; i++) {
    const candidate = randomAccountId();
    const idRef = db.collection("accountIds").doc(String(candidate));
    try {
      await db.runTransaction(async (tx) => {
        const codeSnap = await tx.get(db.collection("userCodes").doc(uid));
        if (codeSnap.exists && typeof codeSnap.data().accountId === "number") {
          throw new Error("already"); // a concurrent run / lazy mint won
        }
        const idSnap = await tx.get(idRef);
        if (idSnap.exists) throw new Error("collision");
        const now = admin.firestore.FieldValue.serverTimestamp();
        tx.set(idRef, { uid, createdAt: now });
        tx.set(db.collection("userCodes").doc(uid),
          { accountId: candidate, createdAt: now }, { merge: true });
      });
      return candidate;
    } catch (e) {
      if (e && (e.message === "collision")) continue;
      if (e && e.message === "already") return null;
      throw e;
    }
  }
  throw new Error(`mint failed for ${uid} after retries`);
}

async function main() {
  const stats = { scanned: 0, alreadyHad: 0, minted: 0, errors: 0 };
  console.log(APPLY ? "MODE: APPLY (writing)" : "MODE: DRY RUN (no writes)");

  let lastDoc = null;
  while (true) {
    let q = db.collection("users").orderBy("__name__").limit(PAGE_SIZE);
    if (lastDoc) q = q.startAfter(lastDoc);
    const snap = await q.get();
    if (snap.empty) break;

    for (const doc of snap.docs) {
      stats.scanned += 1;
      const uid = doc.id;
      const code = await db.collection("userCodes").doc(uid).get();
      if (code.exists && typeof code.data().accountId === "number") {
        stats.alreadyHad += 1;
        continue;
      }
      if (!APPLY) {
        console.log(`  would mint for ${uid}`);
        stats.minted += 1;
        continue;
      }
      try {
        const id = await mintFor(uid);
        if (id) {
          console.log(`  minted ${id} for ${uid}`);
          stats.minted += 1;
        } else {
          stats.alreadyHad += 1;
        }
      } catch (e) {
        console.error(`  error ${uid}: ${e.message}`);
        stats.errors += 1;
      }
    }

    lastDoc = snap.docs[snap.docs.length - 1];
    if (snap.size < PAGE_SIZE) break;
  }

  console.log("\nDone.\n" + JSON.stringify(stats, null, 2));
  if (!APPLY) console.log("\nRe-run with --apply to write the changes.");
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});

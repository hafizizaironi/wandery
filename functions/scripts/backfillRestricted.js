// One-shot backfill: stamp `restricted: false` on every legacy post that
// predates the audience gate. REQUIRED before the new feed query + rules ship:
// the feed's Q1 filters `restricted == false`, and Firestore treats a MISSING
// field as != false, so un-backfilled posts would silently vanish from feeds.
// (The read rules use `restricted != true`, so reads stay safe pre-backfill —
// only the client query needs the field present.)
//
// Usage (from the `functions/` directory):
//   1. Authenticate locally (one-time):  gcloud auth application-default login
//   2. Set the project:                  export GOOGLE_CLOUD_PROJECT=look-cafe
//   3. Dry run (default — no writes):    node scripts/backfillRestricted.js
//   4. Apply for real:                   node scripts/backfillRestricted.js --apply
//
// Idempotent: posts that already carry a boolean `restricted` are skipped, so
// re-running after --apply is a no-op.

const admin = require("firebase-admin");

const PAGE_SIZE = 300;

const apply = process.argv.includes("--apply");

admin.initializeApp();
const db = admin.firestore();

async function main() {
  console.log("Backfilling `restricted: false` on legacy posts");
  console.log(apply ? "MODE: APPLY (writes enabled)" : "MODE: DRY RUN (no writes)");

  const stats = {
    scanned: 0,
    skippedAlreadySet: 0,
    stamped: 0,
    errors: 0,
  };

  let lastDoc = null;
  while (true) {
    let q = db.collection("posts").orderBy("__name__").limit(PAGE_SIZE);
    if (lastDoc) q = q.startAfter(lastDoc);
    const snap = await q.get();
    if (snap.empty) break;

    const batch = db.batch();
    let batchHasWrites = false;

    for (const doc of snap.docs) {
      stats.scanned += 1;
      const d = doc.data() || {};

      if (typeof d.restricted === "boolean") {
        stats.skippedAlreadySet += 1;
        continue;
      }

      stats.stamped += 1;
      if (apply) {
        batch.update(doc.ref, { restricted: false });
        batchHasWrites = true;
      } else {
        console.log(`  would stamp ${doc.id}`);
      }
    }

    if (apply && batchHasWrites) {
      try {
        await batch.commit();
      } catch (err) {
        stats.errors += 1;
        console.error(`Batch commit failed: ${err.message}`);
      }
    }

    lastDoc = snap.docs[snap.docs.length - 1];
    if (snap.size < PAGE_SIZE) break;
  }

  console.log("\nDone.");
  console.log(JSON.stringify(stats, null, 2));
  if (!apply) {
    console.log("\nRe-run with --apply to write the changes.");
  }
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});

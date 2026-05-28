// One-shot backfill: re-evaluate `discoverable` on existing post docs after
// lowering the aesthetic floor from 0.6 → 0.4. Only flips posts that were
// algorithmically rejected under the old floor (score in [0.4, 0.6),
// containsFaces=false, discoverable=false). Posts with score >= 0.6 and
// discoverable=false are preserved as manual hides. Posts with faces and
// posts below the new floor stay as-is.
//
// Usage (from the `functions/` directory):
//   1. Authenticate locally (one-time):  gcloud auth application-default login
//   2. Set the project:                  export GOOGLE_CLOUD_PROJECT=look-cafe
//   3. Dry run (default — no writes):    node scripts/backfillDiscoverable.js
//   4. Apply for real:                   node scripts/backfillDiscoverable.js --apply
//
// Idempotent: re-running after --apply is a no-op since flipped docs
// already match the target value.

const admin = require("firebase-admin");

const OLD_FLOOR = 0.6;
const NEW_FLOOR = 0.4;
const PAGE_SIZE = 300;

const apply = process.argv.includes("--apply");

admin.initializeApp();
const db = admin.firestore();

async function main() {
  console.log(`Backfilling \`discoverable\` against new floor ${NEW_FLOOR} ` +
              `(old floor ${OLD_FLOOR})`);
  console.log(apply ? "MODE: APPLY (writes enabled)" : "MODE: DRY RUN (no writes)");

  const stats = {
    scanned: 0,
    skippedUnclassified: 0,
    skippedFaces: 0,
    skippedManualHide: 0,
    skippedBelowNewFloor: 0,
    skippedAlreadyDiscoverable: 0,
    flipped: 0,
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
      const score = d.aestheticScore;
      const faces = d.containsFaces;
      const discoverable = d.discoverable;

      if (typeof score !== "number" || typeof faces !== "boolean") {
        stats.skippedUnclassified += 1;
        continue;
      }
      if (faces === true) {
        stats.skippedFaces += 1;
        continue;
      }
      if (discoverable === true) {
        stats.skippedAlreadyDiscoverable += 1;
        continue;
      }
      // discoverable === false from here.
      if (score >= OLD_FLOOR) {
        // Would have been auto-true under the old floor → must be manual hide.
        stats.skippedManualHide += 1;
        continue;
      }
      if (score < NEW_FLOOR) {
        // Still below the new floor — correctly blurred.
        stats.skippedBelowNewFloor += 1;
        continue;
      }
      // score in [NEW_FLOOR, OLD_FLOOR), faces=false, discoverable=false
      // → algorithmically rejected by the old floor. Flip to true.
      stats.flipped += 1;
      if (apply) {
        batch.update(doc.ref, { discoverable: true });
        batchHasWrites = true;
      } else {
        console.log(`  would flip ${doc.id}: score=${score.toFixed(3)} ` +
                    `placeId=${d.placeId || "(none)"}`);
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

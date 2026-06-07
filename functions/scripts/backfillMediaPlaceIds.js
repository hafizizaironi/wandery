// One-shot backfill: stamp `mediaPlaceIds` (the DISTINCT list of every place a
// post's photos tag) on every legacy post that predates the field. REQUIRED
// before the place-detail public/Trending fallback can find posts tagged to a
// place only in a SECONDARY photo: `fetchDiscoverablePostsAtPlace` now filters
// `mediaPlaceIds array-contains <placeId>`, and Firestore can't match a missing
// array field, so un-backfilled posts would silently drop out of that fallback.
//
// Same extraction as `onPostCreatePlaceVisit` in index.js and the client's
// `FriendPost.distinctPlaceIds`: distinct, non-empty `media[].placeId`, falling
// back to the top-level `placeId` when the media items carry none. Posts with
// no place tag at all are left untouched (the field stays absent, which is what
// the client write also does).
//
// Usage (from the `functions/` directory):
//   1. Authenticate locally (one-time):  gcloud auth application-default login
//   2. Set the project:                  export GOOGLE_CLOUD_PROJECT=look-cafe
//   3. Dry run (default — no writes):    node scripts/backfillMediaPlaceIds.js
//   4. Apply for real:                   node scripts/backfillMediaPlaceIds.js --apply
//
// Idempotent: posts that already carry an array `mediaPlaceIds` are skipped, so
// re-running after --apply is a no-op.

const admin = require("firebase-admin");

const PAGE_SIZE = 300;

const apply = process.argv.includes("--apply");

admin.initializeApp();
const db = admin.firestore();

// Distinct, non-empty place ids across a post's media, falling back to the
// top-level placeId. Mirrors the Cloud Function + client logic exactly.
function mediaPlaceIdsFor(d) {
  let ids = Array.isArray(d.media) ?
    [...new Set(d.media.map((m) => m && m.placeId).filter(Boolean))] :
    [];
  if (ids.length === 0 && d.placeId) ids = [d.placeId];
  return ids;
}

async function main() {
  console.log("Backfilling `mediaPlaceIds` on legacy posts");
  console.log(apply ? "MODE: APPLY (writes enabled)" : "MODE: DRY RUN (no writes)");

  const stats = {
    scanned: 0,
    skippedAlreadySet: 0,
    skippedNoPlace: 0,
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

      if (Array.isArray(d.mediaPlaceIds)) {
        stats.skippedAlreadySet += 1;
        continue;
      }

      const ids = mediaPlaceIdsFor(d);
      if (ids.length === 0) {
        stats.skippedNoPlace += 1;
        continue;
      }

      stats.stamped += 1;
      if (apply) {
        batch.update(doc.ref, { mediaPlaceIds: ids });
        batchHasWrites = true;
      } else {
        console.log(`  would stamp ${doc.id} → [${ids.join(", ")}]`);
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

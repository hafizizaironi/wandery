// One-off: wipe every user's `users/{uid}/discover/cache` doc so the next
// `discoverFeed` call rebuilds with the latest function logic (e.g. after
// changing the opt-out filter or the aesthetic floor). Cheap to re-run —
// the cache rebuilds lazily on the user's next refresh.
//
// Usage (from `functions/`):
//   node scripts/clearDiscoverCache.js
//
// Auth: same as `backfillDiscoverable.js` — `gcloud auth
// application-default login` once.

const admin = require("firebase-admin");

admin.initializeApp();
const db = admin.firestore();

async function main() {
  const snap = await db.collectionGroup("discover").get();
  const cacheDocs = snap.docs.filter((d) => d.id === "cache");
  console.log(`Found ${cacheDocs.length} cache doc(s) across users.`);

  if (cacheDocs.length === 0) {
    console.log("Nothing to delete.");
    return;
  }

  let deleted = 0;
  // Delete in batches of 400 (safely under Firestore's 500 ops/batch).
  for (let i = 0; i < cacheDocs.length; i += 400) {
    const batch = db.batch();
    const chunk = cacheDocs.slice(i, i + 400);
    for (const doc of chunk) batch.delete(doc.ref);
    await batch.commit();
    deleted += chunk.length;
    console.log(`  deleted ${deleted}/${cacheDocs.length}`);
  }
  console.log("Done.");
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});

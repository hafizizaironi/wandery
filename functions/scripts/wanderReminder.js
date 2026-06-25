// Re-engagement "go wander / ping your friends" reminder push — sent to every
// registered device. There's no separate opt-in: granting notification
// permission IS the consent (the permission-priming copy names reminders).
// NOTE: default-on / no-opt-out — Apple 4.5.4 wants explicit opt-in for
// promotional push; fine for TestFlight, revisit before public App Store submit.
//
// Copy: a curated, on-brand rotating pool (LINES below) — approved by Hafiz.
// With no --title/--body the script round-robins through the pool (tracked via
// `config/wanderReminder.lastLineIndex`) so consecutive sends don't repeat.
// Pass --title/--body to override, or --index=N to force a specific line.
//
// Like `broadcastUpdate.js` it fans out to EVERY registered token, but adds the
// curated copy pool + guards so the autonomous /loop can drive it safely:
//   • kill-switch  — refuses unless `config/wanderReminder.enabled === true`
//   • freq guard   — refuses if the last send was < --minIntervalHours ago
//   • copy guard   — rejects empty / over-long / link-bearing / junk copy
//   • sent-log     — appends every real send to `config/wanderReminder/log/*`
//
// Usage (from the `functions/` directory):
//   1. Authenticate locally (one-time):  gcloud auth application-default login
//   2. Set the project:                  export GOOGLE_CLOUD_PROJECT=look-cafe
//      (or point at the emulator:        export FIRESTORE_EMULATOR_HOST=localhost:8080)
//   3. List the copy pool:               node scripts/wanderReminder.js --list
//   4. Status only (no send):            node scripts/wanderReminder.js --status
//   5. Dry run (picks next line):        node scripts/wanderReminder.js
//   6. Send for real (needs kill-switch on):
//        node scripts/wanderReminder.js --send
//   7. TEST on ONE device — bypasses the audience + kill-switch + freq guard, so
//      you must name the target (use your OWN uid/token); never a broadcast:
//        node scripts/wanderReminder.js --send --uid=<yourUid>
//        node scripts/wanderReminder.js --send --token=<fcmToken>
//   Flags: --title= / --body= (override copy), --index=N (force a pool line),
//          --minIntervalHours=40 (default), --force (skip the freq guard, for tests)
//
// Exit codes: 0 ok/dry-run, 2 bad copy, 3 kill-switch off, 4 too-soon.

const admin = require("firebase-admin");

const SEND = process.argv.includes("--send");
const FORCE = process.argv.includes("--force");
const STATUS = process.argv.includes("--status");
const LIST = process.argv.includes("--list");
function arg(name, def) {
  const p = process.argv.find((a) => a.startsWith(name + "="));
  return p ? p.slice(name.length + 1) : def;
}
const TITLE = arg("--title", "");
const BODY = arg("--body", "");
const TOKEN = arg("--token", "");
const UID = arg("--uid", "");
const INDEX_RAW = arg("--index", "");
const INDEX = INDEX_RAW === "" ? null : Number(INDEX_RAW);
const MIN_INTERVAL_HOURS = Number(arg("--minIntervalHours", "40"));
const DATA = { type: "wanderReminder" };

const CONFIG_PATH = "config/wanderReminder";
const TITLE_MAX = 48;
const BODY_MAX = 150;

// Curated, on-brand reminder pool — soft, gentle, slightly funny, Gen-Z.
// [title, body] pairs. All validated (lengths, no links, no control chars).
const LINES = [
  ["psst 👀", "your friends are lowkey nosy — show 'em where you've been lately ☕️"],
  ["lil reminder 🤍", "no pressure, but your feed's been kinda quiet. go wander a bit?"],
  ["café o'clock ☕️", "somewhere out there is your next favorite spot. just saying ✨"],
  ["the crew misses you 🥹", "drop a moment so they know what you're up to — they're nosy (affectionate)"],
  ["touch grass? 🌿", "counteroffer: touch espresso. go find a cute spot today 🔥"],
  ["tiny nudge 🐾", "the streak's getting a little lonely… one small post?"],
  ["wander check ☕️", "you + a café you haven't tried yet = today's main character moment ✨"],
  ["hey you 🤍", "go somewhere nice today and tell the group chat about it, ok?"],
];

// Lazy init so the pure helpers (validateCopy/hasControlChars/pickLine) can be
// required and unit-tested without Firebase credentials or a running backend.
let _db = null;
function db() {
  if (!_db) {
    admin.initializeApp();
    _db = admin.firestore();
  }
  return _db;
}

function chunk(arr, n) {
  const out = [];
  for (let i = 0; i < arr.length; i += n) out.push(arr.slice(i, i + n));
  return out;
}

// Round-robin: the line after the last one sent (wraps). 0 if none sent yet.
function pickLine(cfg) {
  const last = typeof cfg.lastLineIndex === "number" ? cfg.lastLineIndex : -1;
  return (last + 1 + LINES.length) % LINES.length;
}

// True if the string holds any control character (allowing newline). Scans by
// code point rather than a regex literal so the source stays free of raw
// control bytes. Catches junk / corrupted output before it reaches users.
function hasControlChars(s) {
  for (const ch of s) {
    const c = ch.codePointAt(0);
    if (c === 10) continue;
    if (c < 32 || c === 127) return true;
  }
  return false;
}

// Hard backstop on the copy so nothing malformed or off-brand reaches users.
function validateCopy(title, body) {
  const errs = [];
  const t = (title || "").trim();
  const b = (body || "").trim();
  if (!t) errs.push("title is empty");
  if (!b) errs.push("body is empty");
  if (t.length > TITLE_MAX) errs.push(`title > ${TITLE_MAX} chars (is ${t.length})`);
  if (b.length > BODY_MAX) errs.push(`body > ${BODY_MAX} chars (is ${b.length})`);
  const linkRe = /(https?:\/\/|www\.|\b\S+\.(?:com|net|org|io|app|co|link|me)\b)/i;
  if (linkRe.test(t) || linkRe.test(b)) errs.push("copy contains a URL/link");
  if (hasControlChars(t) || hasControlChars(b)) {
    errs.push("copy contains control characters");
  }
  return errs;
}

// Resolve the title/body for this run: explicit override > --index > round-robin
// pool pick. Returns the chosen copy plus the pool index used (null = override).
function resolveCopy(cfg) {
  if (TITLE && BODY) {
    return { title: TITLE, body: BODY, index: null, source: "override" };
  }
  let idx;
  let source;
  if (INDEX !== null && Number.isInteger(INDEX)) {
    idx = ((INDEX % LINES.length) + LINES.length) % LINES.length;
    source = "pool[--index]";
  } else {
    idx = pickLine(cfg);
    source = "pool[round-robin]";
  }
  return { title: LINES[idx][0], body: LINES[idx][1], index: idx, source };
}

// Audience = every registered device. Notification permission IS the consent
// (no separate opt-in), so we fan out to all `users/{uid}/fcmTokens` via a
// collection-group query, de-duping tokens across devices — same shape as
// broadcastUpdate.js. (iOS suppresses the banner for anyone who later turned
// notifications off, so a stale-permission token just no-ops.)
async function gatherAllTokens() {
  const snap = await db().collectionGroup("fcmTokens").get();
  return [...new Set(snap.docs.map((d) => d.data().token).filter(Boolean))];
}

async function main() {
  if (LIST) {
    LINES.forEach(([t, b], i) => console.log(`[${i}] "${t}" / "${b}"`));
    return;
  }

  const cfgRef = db().doc(CONFIG_PATH);
  const cfgSnap = await cfgRef.get();
  const cfg = cfgSnap.exists ? cfgSnap.data() : {};
  const enabled = cfg.enabled === true;
  const lastSentAt = cfg.lastSentAt && cfg.lastSentAt.toDate ?
    cfg.lastSentAt.toDate() : null;

  if (STATUS) {
    const tokens = await gatherAllTokens();
    console.log(JSON.stringify({
      enabled,
      lastSentAt: lastSentAt ? lastSentAt.toISOString() : null,
      minIntervalHours: MIN_INTERVAL_HOURS,
      poolSize: LINES.length,
      lastLineIndex: typeof cfg.lastLineIndex === "number" ? cfg.lastLineIndex : null,
      nextLineIndex: pickLine(cfg),
      registeredDevices: tokens.length,
    }, null, 2));
    return;
  }

  // Single-device test path: push one line to a specific uid/token, bypassing the
  // opted-in audience, kill-switch, and freq guard. For verifying the pipeline on
  // your own phone — never a broadcast (you must supply the target).
  if (TOKEN || UID) {
    const picked = resolveCopy(cfg);
    console.log(`[TEST] [${picked.source}]: "${picked.title}" / "${picked.body}"`);
    const testErrs = validateCopy(picked.title, picked.body);
    if (testErrs.length) {
      console.error("Copy rejected:\n - " + testErrs.join("\n - "));
      process.exit(2);
    }
    let testTokens;
    if (TOKEN) {
      testTokens = [TOKEN];
    } else {
      const snap = await db()
        .collection("users").doc(UID).collection("fcmTokens").get();
      testTokens = [...new Set(snap.docs.map((d) => d.data().token).filter(Boolean))];
    }
    console.log(`Target (${TOKEN ? "token" : "uid " + UID}): ${testTokens.length} token(s).`);
    if (!SEND) {
      console.log("\nDry run — add --send to push to this device.");
      return;
    }
    if (testTokens.length === 0) {
      console.log("No tokens for this target — is the device registered / signed in?");
      return;
    }
    let ok = 0;
    let bad = 0;
    for (const batch of chunk(testTokens, 500)) {
      const res = await admin.messaging().sendEachForMulticast({
        tokens: batch,
        notification: { title: picked.title, body: picked.body },
        data: DATA,
      });
      ok += res.successCount;
      bad += res.failureCount;
      res.responses.forEach((r) => {
        if (!r.success && r.error) console.error("  token error:", r.error.message);
      });
    }
    console.log(JSON.stringify(
      { test: true, tokens: testTokens.length, success: ok, failure: bad }, null, 2));
    return;
  }

  const { title, body, index, source } = resolveCopy(cfg);
  console.log(`Wander reminder [${source}]: "${title}" / "${body}"`);
  console.log(SEND ? "MODE: SEND (push enabled)" : "MODE: DRY RUN (no push)");

  // Validate copy in every mode so a dry run surfaces problems before --send.
  const copyErrs = validateCopy(title, body);
  if (copyErrs.length) {
    console.error("Copy rejected:\n - " + copyErrs.join("\n - "));
    process.exit(2);
  }

  const tokens = await gatherAllTokens();
  console.log(`Audience: ${tokens.length} registered devices.`);

  if (!SEND) {
    console.log("\nDry run — re-run with --send to push to all registered devices.");
    return;
  }

  if (!enabled) {
    console.error(
      `Refused: ${CONFIG_PATH}.enabled is not true (kill-switch off). ` +
      "Set it to true to arm sends.");
    process.exit(3);
  }

  if (lastSentAt && !FORCE) {
    const hrs = (Date.now() - lastSentAt.getTime()) / 36e5;
    if (hrs < MIN_INTERVAL_HOURS) {
      console.error(
        `Refused: last sent ${hrs.toFixed(1)}h ago < ${MIN_INTERVAL_HOURS}h ` +
        "min interval. Use --force to override.");
      process.exit(4);
    }
  }

  if (tokens.length === 0) {
    console.log("No registered devices — nothing to send.");
    return;
  }

  let success = 0;
  let failure = 0;
  for (const batch of chunk(tokens, 500)) {
    const res = await admin.messaging().sendEachForMulticast({
      tokens: batch,
      notification: { title, body },
      data: DATA,
    });
    success += res.successCount;
    failure += res.failureCount;
  }

  // Record the send: stamp lastSentAt for the freq guard, advance the round-robin
  // cursor (if a pool line was used), and append an audit entry so Hafiz can see
  // exactly what went out (subcollection avoids the serverTimestamp-in-arrayUnion
  // limitation and never needs trimming).
  const update = {
    lastSentAt: admin.firestore.FieldValue.serverTimestamp(),
    lastTitle: title,
    lastBody: body,
  };
  if (index !== null) update.lastLineIndex = index;
  await cfgRef.set(update, { merge: true });
  await cfgRef.collection("log").add({
    at: admin.firestore.FieldValue.serverTimestamp(),
    title,
    body,
    lineIndex: index,
    recipients: tokens.length,
    success,
    failure,
  });

  console.log("\nDone.");
  console.log(JSON.stringify(
    { registeredDevices: tokens.length, success, failure },
    null, 2));
}

if (require.main === module) {
  main().catch((err) => {
    console.error("Fatal:", err);
    process.exit(1);
  });
}

// Exported for unit testing the pure helpers without Firebase.
module.exports = { validateCopy, hasControlChars, pickLine, LINES };

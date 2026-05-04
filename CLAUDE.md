# CafeHunter

SwiftUI iOS app for discovering cafés and street stalls, with social features (friends, posts, reactions), AI-generated mascots, and push notifications. Backed by Firebase.

## Stack

- **Client**: SwiftUI, Swift 5 (project compiles under Swift 6 strict concurrency — see commit `a27753b`), iOS deployment target **26.4**
- **Bundle ID**: `TechVision.CafeHunter`
- **SPM deps**: `firebase-ios-sdk`, `GoogleSignIn-iOS`, `lottie-spm` (airbnb)
- **Backend**: Firebase Auth (Google + Email/Password), Firestore, Storage, Cloud Messaging (APNs), Cloud Functions (Node 22)
- **AI**: Replicate Flux Schnell via the `generateCharacter` callable function (token in Secret Manager as `REPLICATE_API_TOKEN`)
- **Firebase project**: see `.firebaserc` (alias used in Functions logs: `look-cafe`)

## Layout

```
CafeHunter/                    ← Xcode project root + Firebase config
├── CafeHunter.xcodeproj
├── CafeHunter/                ← App source
│   ├── CafeHunterApp.swift    ← @main, FirebaseApp.configure()
│   ├── AppDelegate.swift      ← APNs token plumbing
│   ├── ContentView.swift      ← Top-level auth/routing gate
│   ├── Info.plist             ← Holds ADMIN_UID and Google URL scheme
│   ├── GoogleService-Info.plist
│   ├── Models/                ← Cafe, Achievement, SocialModels
│   ├── Services/              ← Auth, Firestore, Social, Camera, Notifications, UserStats, Audio
│   ├── Views/                 ← Feature-grouped (AddCafe, Auth, Cafes, Camera, Hero, Main, Navigation, Profile, Admin)
│   ├── Shared/                ← FlowLayout, FloatingPanel, NotoEmojiLottieView
│   └── Theme/AppTheme.swift   ← Single source of truth for colours
├── functions/                 ← Cloud Functions (Node 22, CommonJS)
├── firestore.rules
├── firestore.indexes.json
├── storage.rules
└── firebase.json
```

## Architecture conventions

- **State**: `@StateObject` services owned at the `ContentView` level (`AuthService`, `FirestoreService`, `UserStatsService`, `SocialService`) and passed down. Don't create duplicate instances in child views.
- **Auth gating**: `ContentView` is the routing gate — `SplashView` → `LoginView` → `UsernameOnboardingView` → `MainShellView`. Add new gates here, not deeper.
- **Listeners**: services expose `subscribe()` / `unsubscribe()`. They are wired to view lifecycle (`onAppear`/`onDisappear`) or auth state (`onChange(of: user?.uid)`). Always pair them.
- **Concurrency**: callbacks from Firebase SDKs hop to `MainActor` before publishing (`Task { @MainActor in ... }`). Maintain this — Swift 6 strict concurrency was a deliberate cleanup.
- **Theme**: use `AppTheme.*` tokens. Don't hardcode hex colours in views; add a semantic token if one is missing. Legacy aliases (`espresso`, `cream`, `cafeAccent`) exist for migration but new code should use the semantic names (`surfaceCanvas`, `textPrimary`, `accentAction`).
- **Firestore data model**:
  - `places/{id}` — cafés/stalls (read: signed-in; write: signed-in)
  - `users/{uid}` + `users/{uid}/friends/{friendUid}` + `users/{uid}/fcmTokens/{tokenId}`
  - `usernames/{name}` — uniqueness reservation (immutable once created)
  - `friendRequests/{id}` — fromUid/toUid/status; only recipient can update
  - `posts/{id}` + `posts/{id}/reactions/{reactorUid}` — friend-graph-gated reads
- **Storage layout**:
  - `places/**` — café photos
  - `social/{uid}/**` — post media
  - `avatars/{uid}/{uuid}.jpg` — versioned to bust caches (legacy flat `avatars/{uid}.jpg` still allowed for read)
  - `characters/{uid}/{seed}-{ts}.png` — AI-generated mascots (written by `generateCharacter` Cloud Function)
- **Admin**: `AuthService.isAdmin` checks current uid against `ADMIN_UID` from `Info.plist`. Admin-only UI lives in `Views/Admin/`.

## Build & run

```bash
# Open in Xcode (preferred for builds & simulator)
open CafeHunter.xcodeproj

# CLI build for the simulator
xcodebuild -project CafeHunter.xcodeproj -scheme CafeHunter \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build

# List schemes / destinations if needed
xcodebuild -project CafeHunter.xcodeproj -list
xcrun simctl list devices available
```

## Firebase

```bash
# From repo root (where firebase.json lives)
firebase login
firebase projects:list
firebase use <alias-or-project-id>

# Rules (cheap, low blast radius)
firebase deploy --only firestore:rules
firebase deploy --only storage

# Indexes (slow, irreversible to roll back)
firebase deploy --only firestore:indexes

# Functions (production-affecting — confirm with user before deploying)
cd functions && npm install
firebase deploy --only functions

# Secrets for the AI function
firebase functions:secrets:set REPLICATE_API_TOKEN
firebase functions:secrets:access REPLICATE_API_TOKEN

# Local emulator (rules/functions iteration)
firebase emulators:start
```

## Conventions for changes

- **Edit don't recreate**: prefer `Edit` on existing files; new top-level files need an Xcode project entry too (the `.pbxproj` is regenerated only when files are added through Xcode — adding files purely on disk will not include them in the build target).
- **No comments by default**: code is largely uncommented. Only add a comment when the *why* is non-obvious (e.g. the existing comments in `AuthService.updateProfilePhoto` about cache busting).
- **No mocks for Firebase**: services talk to real Firebase. Test against the emulator suite instead of stubbing.
- **Risky actions to confirm before running**:
  - `firebase deploy --only functions` (production push notifications + AI calls)
  - `firebase deploy --only firestore:indexes` (slow rollout)
  - Editing `firestore.rules` or `storage.rules` (security boundary)
  - Adding/removing SPM packages (changes `Package.resolved`)
  - Bumping `IPHONEOS_DEPLOYMENT_TARGET` or `SWIFT_VERSION`
- **Safe to do without asking**: editing Swift views/services, running builds, reading code, running the emulator, formatting.

## Gotchas

- `GoogleService-Info.plist` is committed (intentional — it's a public client config, not a secret). The actual secret is `REPLICATE_API_TOKEN` in Functions secrets.
- `Info.plist` `ADMIN_UID` is hardcoded to a single Firebase UID. To add admins, switch to a Firestore-driven check or custom claims.
- `Package.resolved` and `.swiftpm/` are gitignored — Xcode regenerates them on first open. CI will need to resolve packages.
- `.claude/` is gitignored, so local settings/worktrees don't leak.
- Two large session-export `.txt` files at the repo root (`2026-04-24-*.txt`) are already covered by `*-local-command-caveatcaveat-*.txt` in `.gitignore` but were committed before that rule existed — leaving them alone unless you ask to clean up history.
- iOS deployment target is **26.4** (very recent) — APIs available are post-iOS 18 only.
- Firebase listeners in `FirestoreService` order by `createdAt`, but the `Cafe` model doesn't decode that field. New places get `FieldValue.serverTimestamp()` on write; existing imported docs without `createdAt` may sort unpredictably.

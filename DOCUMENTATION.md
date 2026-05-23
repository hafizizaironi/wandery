# Wandery (CafeHunter) — Software Development Documentation

> **Codename / repo:** `CafeHunter`  &nbsp;·&nbsp;  **Public product name:** **Wandery**
> **Platform:** iOS 26.4+ (SwiftUI)  &nbsp;·&nbsp;  **Backend:** Firebase (Auth, Firestore, Storage, Cloud Messaging, Cloud Functions)
> **Owner:** Hafiz Izaironi (solo developer)  &nbsp;·&nbsp;  **Bundle ID:** `TechVision.CafeHunter`
> **Last updated:** 2026-05-21

---

## 1. Introduction

Wandery is a close-friends, photo-first social map for **food places** — cafés, street stalls, and restaurants. Instead of a public review feed (Yelp/Google) or a generic photo feed (Instagram), Wandery is built around two ideas:

1. **The map is the timeline.** Your friends' food posts are pinned to the exact place they were taken, and the map becomes a personal atlas of "where my people actually eat."
2. **Discovery without surveillance.** A small *Discover* surface lets you see standout food photos from strangers near you — but the post must clear an **on-device** face + aesthetic gate before it ever leaves the friend graph. Faces are filtered out; people are not exposed by default.

The product is intentionally small: a hard cap of **20 friends per user**, a single composer (photo → caption → place tag), and one tab each for *Map*, *Discover*, and *Profile*. It is the opposite of an endless-scroll app — the goal is "open it, see what your people are eating today, close it."

---

## 2. What this app is all about

| Aspect | Description |
|---|---|
| **Category** | Social / Local Discovery / Food |
| **Tagline** | *A close-friends food map.* |
| **Core unit of content** | A **post**: one photo (or short video) + caption, tagged to a Google-Places-resolved location. |
| **Core unit of identity** | A **user** (≤20 friends, mutual). Friendship is symmetric and capped. |
| **Core unit of place** | A **Place** doc (`places/{id}`), deduplicated server-side by `googlePlaceId` and by geohash + fuzzy-name fallback. Distinct from the legacy admin-curated `Cafe` rows. |
| **What you *don't* find here** | Public follower counts, infinite feed, public profiles, ratings, reviews, DMs to strangers, recommendation algorithms tuned for retention. |
| **Monetization** | None at v1. App Store distribution only; no in-app purchase. |

---

## 3. Objectives

### 3.1 Product objective
Build the **smallest social map** that answers the question *"Where have my close friends actually been eating?"* — without forcing the user to consume a feed or perform for an audience.

### 3.2 Engineering objectives
1. **Single solo developer maintainable.** Stack must be boring: SwiftUI + Firebase, no custom backend service, no Kubernetes.
2. **Privacy-first by default.** Anything that crosses the friend graph (Discover) must go through an on-device gate. Faces are excluded.
3. **Server is the source of truth.** Friend cap, place dedup, achievement triggers, push notifications — all live in Cloud Functions or Firestore rules. The client is never trusted to enforce them.
4. **Strict concurrency.** Code compiles under Swift 6 strict concurrency; Firebase callbacks hop to `MainActor` before publishing.
5. **App Store launchable.** Sign in with Apple, account deletion, UGC block + report, privacy manifest, and EULA/Privacy URLs are non-negotiable.

### 3.3 Non-goals
- Becoming an Instagram-style public feed.
- Becoming a review / rating site.
- Supporting Android in v1.
- Supporting an iPad-class layout in v1 (universal binary, but phone-shaped).

---

## 4. Use cases

### 4.1 Primary user stories

| # | As a … | I want to … | So that … |
|---|---|---|---|
| U1 | regular user | tap one button to capture a photo of what I'm eating and post it tagged to this place | my friends see where I am, without me having to write a review |
| U2 | regular user | open the app and see a map of my friends' recent food spots | I can pick where to eat next |
| U3 | regular user | tap a pin and see a card-stack of posts from that exact place | I get a real, unsponsored opinion |
| U4 | regular user | search the map for a place I have in mind | I can pre-load it before a trip |
| U5 | regular user | accept or decline a friend request without leaving the profile screen | adding people is friction-free |
| U6 | explorer | browse a small Discover surface near me | I can find new spots even before any friend has tagged one |
| U7 | privacy-minded user | hide one of my own posts from Discover | I can keep certain posts inside my friend graph |
| U8 | new user | sign in with Apple or Google and pick a username on first launch | I never type a password |
| U9 | new user | see a short value-prop carousel and have location permission asked at the right moment | the prompt makes sense in context |
| U10 | user under harassment | block another user / report a post | I never have to see them again and the team is notified |
| U11 | user leaving the product | delete my account end-to-end | nothing of me remains server-side |

### 4.2 Secondary / admin

| # | As a … | I want to … |
|---|---|---|
| A1 | admin (`ADMIN_UID` in `Info.plist`) | seed curated `Cafe` rows for legacy map content |
| A2 | admin | review reports and act on accounts |

### 4.3 Edge / supporting cases
- **Offline post**: composer captures locally and uploads when network returns.
- **Place not in Google Places**: the picker offers "Add new place" → calls `findOrCreatePlace` callable, which generates a `Place` doc with `source: "user"`.
- **Race on first-ever post at a new place**: `findOrCreatePlace` uses a Firestore transaction to ensure only one place doc is created.
- **Push token rotation**: APNs token is stored per-install under `users/{uid}/fcmTokens/{tokenId}`; stale tokens cleaned up server-side on send-failure.

---

## 5. Features

### 5.1 Shipped (v1.0 — App Store candidate)

#### Authentication & onboarding
- **Sign in with Apple** (Apple-required for App Store).
- **Sign in with Google** via `GoogleSignIn-iOS`.
- **Email/password** fallback.
- **Username onboarding** — uniqueness enforced through immutable `usernames/{lowercase}` docs.
- **Welcome carousel** (`WelcomeView`) gated by `@AppStorage("hasSeenWelcome")` — value prop → social hook → location prime. Location permission is requested on the third card, not at launch.

#### Map (primary surface)
- **Friend-tagged places** — annotation layer derived from the user's feed (self + ≤20 friends), most-recent-first, cached.
- **Legacy curated cafés** — drawn underneath friend pins so they don't compete for attention.
- **"+N" badge** when multiple distinct friends have visited one place.
- **Place detail card stack** — tap a pin → 3-deep card stack, most recent on top, swipe to advance.

#### Composer / posting
- **One-shot capture** via `CameraService` (photo or short video).
- **Place picker sheet** — type chips (☕ Café · 🍜 Stall · 🍽️ Restaurant), nearby search (3000m default), name search across the global `places` collection, autocomplete via Google Places SDK, "Add new place" fallback.
- **Server-side place dedup** — `findOrCreatePlace` callable: `googlePlaceId` first, then geohash + normalized-name fuzzy match within 75m, transaction-guarded.

#### Friend graph
- **Mutual friendship**, capped at **20**.
- **Friend requests** with accept/decline (per-row spinner), errors surfaced inline.
- **Autocomplete add-friend** — 220ms-debounced prefix query against `usernames/{lowercase}`.
- **Profile**: avatar, display name, post grid, friends section with horizontal avatar strip + "See all".

#### Discover (privacy-gated public surface)
- On-device **face detection** (Apple Vision) and **aesthetic score** (iOS 18 `ImageAnalyzer`) classify every post after publish.
- Verdict written to the post doc as `discoverable: Bool`, `aestheticScore: Double`, `containsFaces: Bool`.
- Discoverable posts surface in the map-first Discover view; non-discoverable stay inside the friend graph.
- **"Hide from Discover"** context menu on the author's own posts (one-way).
- Threshold currently `aestheticScore >= 0.6` — un-tuned, pending empirical pass.

#### Chat (lightweight)
- 1:1 conversations with existing friends. Conversation doc is **lazy-created on first send**.
- Push notifications via Cloud Messaging.

#### Notifications
- APNs registration plumbed through `AppDelegate`; tokens stored per install.
- Cloud Functions emit notifications for friend requests, accepts, reactions, and chat messages.

#### Safety / moderation
- **Block** (mutual hide from feed + map + Discover) — `blockedUsers` collection with owner-read / server-write rule.
- **Report** post or user — writes to admin-only `reports/` collection.
- **Account deletion** — `deleteMyAccount` callable wipes Firestore + Storage + Auth.

#### AI character generation
- Replicate **Flux Schnell** via `generateCharacter` callable — produces a personal mascot avatar.
- Token in Cloud Functions Secret Manager (`REPLICATE_API_TOKEN`).

#### Polish
- Emil Kowalski–style motion tokens (`Shared/Motion.swift`) — three cubic-beziers, cozy spring, `ScalePressButtonStyle`.
- Privacy manifest (`PrivacyInfo.xcprivacy`) + `ITSAppUsesNonExemptEncryption=false`.
- EULA and Privacy Policy hosted at `https://hafizizaironi.github.io/wandery/{terms,privacy}`.

### 5.2 Roadmap (post-v1)

See `PHASES.txt` for the canonical roadmap. Highlights:

- **Phase 3 — Trending nearby (crowd signal).** Anonymous place visit counter; dim "trending" pins on the map ranked by `globalVisitCount`. No identity revealed.
- **Phase 4 — Server-side 20-friend cap.** Convert direct client writes on `users/{uid}/friends/*` to a callable that enforces the cap inside a transaction.
- **Phase 5 — Discovery achievements.** Cloud-Function-driven badges (Pioneer, Wanderer, Local Guide, Tastemaker, Loyal) — never client-claimed.

### 5.3 Deferred (v1.1+ architectural)
- `@ObservedObject` services → `@Observable` macro migration (biggest perf win available).
- Split `HeroPageView` (~2,000-line body) into separate `View` structs.
- `print()` → `os.Logger` across 35 sites.
- Audit `MainActor.run` usage in `AuthService` and `EditProfileView`.

---

## 6. Screenshots

> **Drop captures into `screenshots/` at the repo root** (gitignored or committed — your call). The image paths below resolve relative to this file, so once the PNGs land the section renders inline on GitHub.

Recommended shots to capture (one device, one orientation — iPhone 16 Pro portrait is fine):

| # | File | Surface | What it shows |
|---|---|---|---|
| 1 | `screenshots/01-welcome.png` | `WelcomeView` | First-run value-prop carousel (3 cards: value prop → social hook → location prime) |
| 2 | `screenshots/02-login.png` | `LoginView` | Sign in with Apple / Google / Email options |
| 3 | `screenshots/03-username.png` | `UsernameOnboardingView` | One-time username pick with uniqueness check |
| 4 | `screenshots/04-map-friends.png` | `CafeMapView` / `MainMapView` | Map with friend-tagged pins + "+N" badges |
| 5 | `screenshots/05-place-detail.png` | `PlaceDetailSheet` | Card-stack of posts at one place, most recent on top |
| 6 | `screenshots/06-composer.png` | `HeroPageView` | Photo composer with caption pill + 📍 place pill |
| 7 | `screenshots/07-place-picker.png` | `PlacePickerSheet` | Type chips (☕/🍜/🍽️) + nearby/autocomplete + Add new place |
| 8 | `screenshots/08-discover.png` | `DiscoverView` | Map-first Discover surface (post-classifier gated) |
| 9 | `screenshots/09-profile.png` | `ProfileHomeView` | Profile with stats row + friends avatar strip + post grid |
| 10 | `screenshots/10-friends.png` | `FriendListView` | Friend list with add-friend autocomplete |
| 11 | `screenshots/11-chat.png` | `ChatView` | 1:1 conversation (lazy-created on first send) |
| 12 | `screenshots/12-edit-profile.png` | `EditProfileView` | Avatar edit + AI mascot generation entry |

### Gallery

| Welcome | Map | Composer |
|---|---|---|
| ![Welcome carousel](screenshots/01-welcome.png) | ![Friend map](screenshots/04-map-friends.png) | ![Composer](screenshots/06-composer.png) |

| Place picker | Discover | Profile |
|---|---|---|
| ![Place picker](screenshots/07-place-picker.png) | ![Discover](screenshots/08-discover.png) | ![Profile](screenshots/09-profile.png) |

> Until the PNGs exist, GitHub will render broken-image icons here — that's expected and intentional as a placeholder. **Capture tip:** use Xcode's Simulator → `⌘S` to save a clean PNG; for status-bar polish run `xcrun simctl status_bar booted override --time "9:41" --batteryState charged --batteryLevel 100`.

---

## 7. Architecture overview

### 7.1 High-level system diagram

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              iOS Client (SwiftUI)                            │
│                                                                              │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
│   │  AuthService │  │FirestoreSvc  │  │ SocialService│  │UserStatsSvc  │    │
│   │ (@StateObj)  │  │ (@StateObj)  │  │ (@StateObj)  │  │ (@StateObj)  │    │
│   └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘    │
│          │                 │                 │                 │            │
│   ┌──────┴─────────────────┴─────────────────┴─────────────────┴──────┐     │
│   │                    ContentView (auth/routing gate)                │     │
│   │   SplashView → LoginView → UsernameOnboarding → MainShellView     │     │
│   └──────┬─────────────┬─────────────┬─────────────┬──────────────────┘     │
│          │             │             │             │                        │
│      ┌───┴───┐    ┌────┴───┐   ┌─────┴───┐   ┌────┴────┐                   │
│      │  Map  │    │Discover│   │ Profile │   │  Chat   │                   │
│      └───────┘    └────────┘   └─────────┘   └─────────┘                   │
│                                                                              │
│   On-device: PostClassifier (Apple Vision faces + iOS 18 aesthetic score)   │
└─────────────────────────────────┬────────────────────────────────────────────┘
                                  │
                  Firebase iOS SDK + GooglePlacesSwift
                                  │
┌─────────────────────────────────┴────────────────────────────────────────────┐
│                              Firebase (look-cafe)                            │
│                                                                              │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
│   │     Auth     │  │   Firestore  │  │    Storage   │  │   Messaging  │    │
│   │ Apple/Google │  │ rules-gated  │  │ rules-gated  │  │ (APNs proxy) │    │
│   └──────────────┘  └──────┬───────┘  └──────────────┘  └──────────────┘    │
│                            │                                                 │
│   ┌────────────────────────┴─────────────────────────────────────────────┐  │
│   │                     Cloud Functions (Node 22)                        │  │
│   │   findOrCreatePlace · onPostCreatePlaceVisit · onReactionEngagement  │  │
│   │   deleteMyAccount · generateCharacter (Replicate Flux Schnell)       │  │
│   │   onFriendRequest/Accept · onChatMessage (push fanout)               │  │
│   └────────────────────────┬─────────────────────────────────────────────┘  │
│                            │                                                 │
└────────────────────────────┼─────────────────────────────────────────────────┘
                             │
                  ┌──────────┴───────────┐
                  │                      │
            ┌─────┴──────┐        ┌──────┴───────┐
            │  Google    │        │  Replicate   │
            │ Places API │        │ Flux Schnell │
            └────────────┘        └──────────────┘
```

### 7.2 Module / layer map

```
CafeHunter/
├── CafeHunterApp.swift             @main · FirebaseApp.configure() · PlacesClient init
├── AppDelegate.swift               APNs token plumbing
├── ContentView.swift               Auth + routing gate
├── Info.plist                      GMSPlacesAPIKey ($-substituted) · ADMIN_UID · URL schemes
├── PrivacyInfo.xcprivacy           App Store privacy manifest
│
├── Models/
│   ├── Cafe.swift                  PlaceType · legacy Cafe · slim Place
│   ├── SocialModels.swift          UserProfile · FriendPost (discoverable, aestheticScore…)
│   ├── Achievement.swift           Badge model (Phase 5 surface)
│   ├── Moderation.swift            Block + Report payloads
│   └── LegalURLs.swift             Terms + Privacy URLs (GitHub Pages)
│
├── Services/                       (@StateObject at ContentView level)
│   ├── AuthService                 Apple/Google/Email · profile mirrors · cache busting
│   ├── FirestoreService            Cafes feed (legacy curated)
│   ├── SocialService               Posts, feed, reactions, blocking, post upload
│   ├── FriendPlacesService         Derives [FriendPlace] from feedPosts
│   ├── DiscoverService             Map-first Discover query (geohash bounds + score sort)
│   ├── PlacePickerService          GooglePlacesSwift wrapper + global-name search
│   ├── ConversationService         Lazy chat doc creation + listener
│   ├── NotificationService         FCM token registration
│   ├── UserStatsService            cafesVisited/stallsVisited counters
│   ├── VisitTrackerService         First-visit dedup on post create
│   ├── CameraService               One-shot capture · permissions
│   ├── CameraCaptureProcessing     HEIC/JPEG normalization · downsample · thumbnail
│   └── AppAudioSession             Mode juggling for video record/playback
│
├── Views/
│   ├── Auth/                       LoginView · WelcomeView · UsernameOnboardingView
│   ├── Main/                       MainShellView · CafeMapView · MainMapView · DiscoverView
│   ├── Hero/                       Composer (HeroPageView, HeroCameraLayout)
│   ├── Cafes/                      CafeCardView · CafeDetailView
│   ├── Camera/                     Capture chrome
│   ├── PostPlaceTag/               PlacePickerSheet + place rows
│   ├── Profile/                    ProfileHomeView · EditProfileView · FriendListView · Chat
│   ├── Admin/                      Admin-only seeding UI (ADMIN_UID gated)
│   ├── Navigation/                 Tab bar / shell chrome
│   └── Shared/                     FlowLayout · FloatingPanel · NotoEmojiLottieView
│
├── Shared/
│   ├── Motion.swift                Cubic-beziers · cozy spring · ScalePressButtonStyle
│   └── PostClassifier.swift        On-device face + aesthetic gate → discoverable flag
│
└── Theme/AppTheme.swift            Semantic tokens (surfaceCanvas, textPrimary, accentAction…)

functions/                          Node 22 · CommonJS · Firebase Functions v2
├── index.js                        All callables/triggers in one file
└── package.json                    firebase-admin · firebase-functions · geofire-common · replicate
```

### 7.3 Firestore data model

```
places/{placeId}                    name, type, lat, lng, geohash, source, googlePlaceId,
                                    globalVisitCount, globalEngagementCount, lastVisitedAt,
                                    createdAt, createdBy

posts/{postId}                      authorId, authorUsername, caption, mediaType, mediaURL,
                                    thumbnailURL, createdAt, placeId, placeName,
                                    discoverable, aestheticScore, containsFaces
   └── reactions/{reactorUid}       emoji, createdAt

users/{uid}                         displayName, photoURL, username, cafesVisited,
                                    stallsVisited, restaurantsVisited
   ├── friends/{friendUid}          since
   ├── fcmTokens/{tokenId}          token, platform, updatedAt
   ├── blockedUsers/{blockedUid}    createdAt        (owner-read, server-write)
   └── placeStats/{placeId}         visitCount       (Phase 5: drives "Loyal" badge)

usernames/{lowercase}               uid              (immutable once created)

friendRequests/{requestId}          fromUid, toUid, status, createdAt

conversations/{conversationId}      participantIds, lastMessage, lastUpdatedAt
   └── messages/{messageId}         senderId, text, createdAt

reports/{reportId}                  reporterId, targetType, targetId, reason   (admin-only)
```

### 7.4 Cloud Storage layout

```
places/**                           Curated café photos
social/{uid}/**                     Post media (photos + videos)
avatars/{uid}/{uuid}.jpg            Versioned to bust caches
avatars/{uid}.jpg                   Legacy flat path (read still allowed)
characters/{uid}/{seed}-{ts}.png    AI mascot output (written by generateCharacter)
```

### 7.5 Posting flow (end-to-end)

```
 ┌──────────────────────────────────────────────────────────────────────────────┐
 │                            POST CREATION (happy path)                        │
 └──────────────────────────────────────────────────────────────────────────────┘

  User taps capture
       │
       ▼
  CameraService → photo/video file
       │
       ▼
  HeroPageView composer
   ├── caption field
   └── 📍 PlacePickerSheet  ──► PlacePickerService
                                  • Google Places nearby (3000m)
                                  • Autocomplete
                                  • Global places-by-name search
       │
       ▼
  SocialService.uploadAndCreatePost(media:, caption:, place:)
   ├── Storage upload → social/{uid}/{uuid}.{ext}    (spinner released here)
   ├── Firestore write posts/{id} with placeId? placeName?
   └── Trailing housekeeping (backgrounded)
        ├── findOrCreatePlace callable          (server: dedup by googlePlaceId + geohash+name)
        ├── PostClassifier (on-device)          (Apple Vision faces + iOS 18 aesthetic)
        │     └── update posts/{id} { discoverable, aestheticScore, containsFaces }
        ├── onPostCreatePlaceVisit trigger      (server: globalVisitCount++ + lastVisitedAt)
        │     └── increment users/{uid} type-specific counter on first-ever visit
        └── push fanout to friends              (Cloud Messaging)
```

### 7.6 Auth & routing gate

```
                ┌──────────────────────┐
                │   CafeHunterApp      │
                │ FirebaseApp.configure│
                │ PlacesClient.init    │
                └──────────┬───────────┘
                           │
                           ▼
                  ┌────────────────┐
                  │  ContentView   │   ← single auth gate
                  └───────┬────────┘
              ┌───────────┼─────────────┐
              ▼           ▼             ▼
       (no user)     (no username)  (signed-in)
              │           │             │
              ▼           ▼             ▼
       SplashView   Username       MainShellView
              │   OnboardingView    ├── Map
              ▼           │         ├── Discover
       WelcomeView ──► LoginView    └── Profile
       (1st run)        │
                        ▼
                 Sign in with Apple / Google / Email
```

---

## 8. Tech stack & dependencies

| Layer | Choice | Notes |
|---|---|---|
| UI | SwiftUI | iOS 26.4 deployment target — post-iOS 18 APIs only |
| Language | Swift 5 source, Swift 6 strict concurrency | Callbacks hop to `MainActor` before publish |
| State | `@StateObject` services owned at `ContentView` | No DI container, no third-party state lib |
| Maps | MapKit | Friend pins + legacy café pins layered |
| Camera | AVFoundation via `CameraService` | One-shot capture, HEIC/JPEG normalization |
| Animation | Native + Lottie (`lottie-spm`) | Noto Emoji micro-animations |
| Auth | Firebase Auth | Apple + Google + Email/Password |
| DB | Firestore | Rules-gated, composite indexes deployed |
| Storage | Firebase Storage | Per-uid prefixes, rules-gated |
| Push | Firebase Cloud Messaging → APNs | Per-install token rows |
| Server logic | Firebase Cloud Functions (Node 22) | CommonJS, v2 callables/triggers |
| AI | Replicate Flux Schnell | Token in Secret Manager |
| Places | Google Places SDK (`GooglePlacesSwift`) | Nearby + autocomplete |
| Geo dedup | `geofire-common@6.0.0` (server-side) | Geohash bounds for fuzzy match |
| Hosting (legal) | GitHub Pages (`docs/` folder, Cayman theme) | Terms + Privacy |

---

## 9. Build, run, and operate

```bash
# Open in Xcode (preferred)
open CafeHunter.xcodeproj

# CLI build for the simulator
xcodebuild -project CafeHunter.xcodeproj -scheme CafeHunter \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build

# Firebase: rules-only deploy (cheap, low blast radius)
firebase deploy --only firestore:rules
firebase deploy --only storage

# Firebase: indexes (slow, irreversible to roll back)
firebase deploy --only firestore:indexes

# Firebase: functions (production-affecting — confirm before pushing)
cd functions && npm install
firebase deploy --only functions

# Secrets (Cloud Functions)
firebase functions:secrets:set REPLICATE_API_TOKEN
firebase functions:secrets:access REPLICATE_API_TOKEN

# Local emulator
firebase emulators:start
```

### 9.1 Secrets handling
- `GMSPlacesAPIKey` lives in **`Secrets.xcconfig`** (gitignored). `Info.plist` references it as `$(GMS_PLACES_API_KEY)`. The Cloud Console key is restricted to bundle ID `TechVision.CafeHunter` + Places API only.
- `REPLICATE_API_TOKEN` lives in **Cloud Functions Secret Manager**, never in source.
- `GoogleService-Info.plist` is intentionally committed — it's a public client config, not a secret.
- Run the project's secret-scan before any push (see `reference_cafehunter_tools`).

---

## 10. Security & privacy

| Concern | Mitigation |
|---|---|
| Friend cap bypass | Phase 4: callable `acceptFriendRequest` enforces ≤20 inside a transaction; rules deny direct client writes to `users/{uid}/friends/*`. |
| Place spam / duplicates | All place creation goes through `findOrCreatePlace` — googlePlaceId + geohash + fuzzy-name dedup inside a transaction. |
| Discover surfacing strangers' faces | On-device Apple Vision face detection; any face → `discoverable: false`, post never leaves the friend graph. |
| Block listener silently denied | Rules now permit `users/{uid}/blockedUsers` owner-read / server-write (fixed 2026-05-21). |
| Account residue after deletion | `deleteMyAccount` callable wipes Firestore + Storage + Auth atomically. |
| Reports surfaced to admins only | `reports/` collection is admin-only; client can write, only admin can read. |
| API key leak | Rotated key, restricted scope, secrets now in gitignored xcconfig — see `project_cafehunter_secrets`. |
| App Store privacy declaration | `PrivacyInfo.xcprivacy` shipped; `ITSAppUsesNonExemptEncryption=false`. |
| Terms of Service & Privacy Policy | Hosted at `https://hafizizaironi.github.io/wandery/{terms,privacy}` and linked from in-app `LegalURLs`. |

---

## 11. Testing

| Strategy | Status |
|---|---|
| Unit tests on pure Swift models | Not yet — small surface, single dev, prioritized post-launch. |
| Firebase emulator suite | Used for rules + functions iteration. |
| Manual smoke tests on real device | Required for: location auth, picker autocomplete, push notifications, video capture. Simulator fakes location. |
| App Store reviewer-facing demo flow | Captured in App Store Connect reviewer notes (Hafiz manual). |

The `verify` skill is installed and used to confirm fixes by actually running the app, not just typechecking.

---

## 12. Open items before App Store submission

(See `memory/project_cafehunter_resume.md` for the live checklist.)

1. App Store Connect listing — screenshots (6.9"), 1024×1024 icon, age rating questionnaire (expect 17+ for UGC), reviewer demo credentials.
2. Apple Developer Portal — strip unused App ID capabilities; keep Sign in with Apple, Push Notifications, optionally Access Wi-Fi Information.
3. Firebase Console — remove the stale `com.VisionTech.CafeHunter` iOS app entry.
4. TestFlight pass exercising: SIWA, account deletion, block, report, accept/decline friend request.
5. Skim `docs/terms.md` + `docs/privacy.md` against actual service behavior.
6. If the repo or domain ever moves, update both URLs in `Models/LegalURLs.swift`.

---

## 13. References

- `CLAUDE.md` — agent-facing repo guide (stack, conventions, gotchas).
- `PHASES.txt` — canonical product roadmap (Phases 1–5).
- `docs/terms.md`, `docs/privacy.md` — legal drafts (GitHub Pages source).
- `firestore.rules`, `storage.rules` — security boundary; deploy with care.
- `firestore.indexes.json` — composite indexes (deployment is slow).
- `functions/index.js` — all callables/triggers in one file.

---

*This document is the software-development-side overview of Wandery (codename CafeHunter). Marketing copy, screenshots, and reviewer-facing material live in App Store Connect.*

# FriendsFeedWidget — Xcode setup (manual steps)

All the Swift/config code is written. These steps can only be done in the Xcode
UI / Apple Developer portal (target creation + capabilities + signing + SPM
linking). Do them in order.

## 1. Create the widget extension target
- **File → New → Target… → Widget Extension**
- Product Name: **`FriendsFeedWidget`**
- **Uncheck** "Include Live Activity" and "Include Configuration App Intent"
  (we use a `StaticConfiguration`).
- Team: your team. **Embed in Application: CafeHunter.** Activate the new scheme.
- Xcode generates template files in the `FriendsFeedWidget/` folder. **Delete the
  template Swift files it created** (e.g. `FriendsFeedWidget.swift`,
  `AppIntent.swift`) — they contain a second `@main`, which collides with ours.
  Keep our files: `FriendsFeedWidgetBundle.swift`, `FriendsFeedEntry.swift`,
  `FriendsFeedProvider.swift`, `FriendsFeedViews.swift`.
- Folder is a synchronized group, so our 4 files are picked up automatically.
- Ensure the target's **Info.plist** is `FriendsFeedWidget/Info.plist` (ours) and
  **Code Signing Entitlements** = `FriendsFeedWidget/FriendsFeedWidget.entitlements`
  (ours — already has the App Group + keychain group).

## 2. App Group capability (THREE targets)
Add capability **App Groups → `group.TechVision.CafeHunter`** to each of:
- `CafeHunter`
- `WanderyNotificationService`
- `FriendsFeedWidgetExtension`

## 3. Keychain Sharing on the widget target
`FriendsFeedWidgetExtension` → **Keychain Sharing → `TechVision.CafeHunter.shared`**
(app + NSE already have it). Our entitlements file already lists it.

## 4. Link Firebase into the widget target
`FriendsFeedWidgetExtension` → General → **Frameworks and Libraries → +** and add
(from the already-resolved Firebase package):
`FirebaseCore`, `FirebaseAuth`, `FirebaseFirestore`, `FirebaseAppCheck`.
(No FirebaseStorage/Messaging/Functions — media is fetched with `URLSession`.)

## 5. GoogleService-Info.plist → widget target membership
Select `CafeHunter/GoogleService-Info.plist` → File Inspector → **Target
Membership → check `FriendsFeedWidgetExtension`** (needed for
`FirebaseApp.configure()` inside the extension).

## 6. Shared Swift files → widget target membership
For each file below: File Inspector → Target Membership → **check
`FriendsFeedWidgetExtension`** (creates the same kind of membership exception the
NSE uses for `Keychain.swift`):
- `CafeHunter/Models/PostModels.swift`
- `CafeHunter/Shared/SharedFeedStore.swift`
- `CafeHunter/Shared/ImageDecoding.swift`
- `CafeHunter/Services/AppCheckProviderFactory.swift`

## 7. `wandery://` URL scheme (deep link from widget tap)
`CafeHunter` target → Info → **URL Types → +**:
- Identifier (CFBundleURLName): `TechVision.CafeHunter.deeplink`
- URL Schemes (CFBundleURLSchemes): `wandery`

## 8. Build & run, then register the widget's App Check debug token
- Build the `CafeHunter` scheme (it embeds the widget). Add the widget on the
  Home Screen in all three sizes.
- **DEBUG/Simulator:** the widget is a *separate process* with its *own* App
  Check debug token. Watch the widget's console output for the
  `App Check debug token: …` line and register it in **Firebase Console → App
  Check → CafeHunter → Manage debug tokens** (distinct from the app's token).
- Alternatively keep Firestore App Check enforcement in **monitor/unenforced**
  mode during bring-up, then flip to enforced after verifying a device-RELEASE
  build mints App Attest tokens.

## Notes
- The widget's Firestore query is identical to the app's feed query
  (`authorId in … && restricted == false`, ordered by `createdAt`), so it reuses
  the **existing composite index** — no new index needed.
- App Attest is unavailable on the Simulator, so real Firestore reads from the
  widget need either a registered debug token (DEBUG) or a physical device-RELEASE
  build.

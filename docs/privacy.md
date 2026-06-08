---
title: Privacy Policy
---

# Wandery — Privacy Policy

_Last updated: 2026-06-08_

This Privacy Policy explains what data Wandery collects, why, who it's shared with, and what choices you have. It mirrors the App Privacy declarations Wandery ships in its `PrivacyInfo.xcprivacy` manifest.

## What we collect

When you sign up and use Wandery, we collect:

| Category | Examples | Why |
|---|---|---|
| **User ID** | Firebase Auth UID, username | To identify your account and tie posts, friends, and chats to you |
| **Email address** | Sign-up email | To sign you in and recover your account |
| **Name** | Display name (from Apple, Google, or your own input) | So friends can find and recognize you |
| **Photos and videos** | Posts, profile photo | To display them in the feed and on your profile |
| **Audio** | Audio captured as part of recorded videos | Part of the video you post |
| **Precise location** | Latitude / longitude when you tag a place | To dedup places, find nearby cafés, and place friend pins on the map |
| **Other user content** | Chat messages, captions, friend requests, reactions | To deliver them to the right people |
| **Device ID** | Apple Push Notification (APNs) / Firebase Cloud Messaging (FCM) token | To send you push notifications |
| **Product interaction** | Which features you tap and which areas of the app you spend time in | First-party usage analytics, to understand how the app is used and what to improve (see "Usage analytics" below) |

Wandery does **not**:

- Use the IDFA or any cross-app tracking identifier.
- Sell your data.
- Use third-party advertising or analytics SDKs.
- Track you across other apps or websites.

## Who processes your data

- **Firebase / Google Cloud** (data processor): Authentication, Firestore database, Cloud Storage for photos and videos, Cloud Functions, and Cloud Messaging for push. Data is stored in Google Cloud regions configured for our project.
- **Google Sign-In and Sign in with Apple**: When you sign in with these providers, the provider verifies your identity and shares your name and email with us.
- **Google Places API**: When you search for a place to tag, the search query and a coarse location are sent to Google Places to return nearby suggestions.

We do not share your data with any other third party except where required by law.

## Usage analytics

Wandery records first-party product-analytics events — which features you tap and which areas of the app you spend time in — to understand how the app is used and decide what to improve. These events:

- are **first-party**: collected with our own code and Firebase, with **no third-party advertising or analytics SDKs**;
- are tied to your account identifier so we can understand how features are used, but are **not** used to track you across other apps or websites and use **no advertising identifier** (no IDFA);
- are **not** shared with any third party and are **not** used for advertising;
- are kept only briefly — raw event records are automatically deleted after about **30 days**, after which only anonymous, aggregated totals remain.

Deleting your account removes your data as described under "Delete your account" below.

## Push notifications

If you grant notification permission, we register your device's APNs token with Firebase Cloud Messaging so we can send you alerts about friend requests, replies, and reactions. You can turn off notifications at any time in iOS Settings.

## Camera, photo library, microphone, and location permissions

Wandery asks for these permissions only when you use the relevant feature:

- **Camera** + **Microphone** — when you open the Hero camera to capture a photo or video.
- **Photo library (add)** — when you save a captured photo or video to your library.
- **Photo library (read)** — when you pick an existing photo to post.
- **Location (when in use)** — when you open the map or tag a place on a post.

Each permission is optional. Denying one disables only the feature that needs it.

## Your choices

- **Block other users**: from the long-press menu on a friend's row, a post, or a chat header (⋯ → Block user). Blocked users cannot reach you and do not appear in your feed.
- **Report content**: long-press any post or chat message → Report. We review every report within 24 hours.
- **Delete your account**: Profile → Delete Account. This permanently removes your profile, posts, friends, conversations, FCM tokens, uploaded photos and videos, and frees your username. It cannot be undone.
- **Turn off notifications**: iOS Settings → Wandery → Notifications.
- **Turn off location**: iOS Settings → Privacy → Location → Wandery.

## Data retention

We keep your data while your account is active. When you delete your account, your data is removed within 30 days, except for backups that are routinely overwritten and for anonymized aggregates that no longer identify you. Reports made against other users may be retained for moderation review.

## Children

Wandery is not directed to children under 13. If you believe a child under 13 has provided personal information to us, please contact us at [hafizizaironi@gmail.com](mailto:hafizizaironi@gmail.com) and we will delete the data.

## Changes to this Policy

We may revise this Policy from time to time. The "Last updated" date at the top shows the most recent revision.

## Contact

Privacy questions, data access requests, or anything else: [hafizizaironi@gmail.com](mailto:hafizizaironi@gmail.com).

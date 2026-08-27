# Web Messenger

## Introduction

Web Messenger is a real-time, end-to-end chat application with both a Flutter Android client and a Flutter Web client, sharing one codebase. Both connect to the same Node.js, Express, Socket.IO, and PostgreSQL backend, hosted on Railway.

Users can create accounts, verify their email addresses, search for and invite contacts, exchange text/image/video/audio messages, chat 1:1 or in groups, create and vote in polls, reply to and manage their own messages, and get push notifications for new messages and invitations. The backend is authoritative: it persists every message, encrypts sensitive data (including email addresses) at rest, compresses video server-side, and pushes real-time updates to connected clients through Socket.IO.

The web client reuses the Android app's codebase, with `kIsWeb`-gated adjustments for browser constraints: gallery-only media picking (no camera capture), hover-revealed message/chat menus instead of long-press/swipe gestures, downloads via the browser's Save dialog instead of the device photo gallery, and a wide-viewport split-pane layout (chat list beside the open chat). See [Run the Web Client](#run-the-web-client) to try it.

## Main Features

- Email/password registration, verification, password reset, and persisted sessions
- Contact search by username or email, with sendable/acceptable/declinable invitations and a pending-invites view
- Profile page with editable username, About Me, and profile picture
- Text, image, video, and audio (voice note) messaging, with server-side video compression for reliable uploads
- Swipe-to-reply message quoting, real-time typing indicators, and sent/delivered/read status
- Message editing and deletion
- 1:1 and group chats, with group creation and membership management
- In-chat polls, with optional anonymous voting; votes can be changed or retracted at any time
- Chat list sorted by most recent activity, with archive/unarchive and per-user delete (clears history from just your own view, like WhatsApp)
- Push notifications for new messages and invitations, with per-chat mute
- Selectable app themes (Sunset Coral, Calm Forest, Ocean Blue) plus a dedicated dark mode, with an elevated, consistent design (custom typography, cached/fade-in media, gradient avatars, richer empty states) across every screen
- Voice messages show a live recording timer while held and a seek bar with elapsed/total time during playback
- AES-256 encryption of message content, profile fields, media files, and email addresses at rest, with a deterministic hash so encrypted emails can still be looked up for login/search

## Technology Stack

| Area | Technology |
| --- | --- |
| Client (Android & Web) | Flutter / Dart, Provider, `http`, `socket_io_client`, `kIsWeb`-gated platform branching |
| Backend | Node.js, Express, TypeScript, Socket.IO |
| Database | PostgreSQL 15; Docker locally and Railway PostgreSQL in the hosted deployment |
| Authentication | JWT and bcrypt password hashing |
| Data protection | AES-256-CBC encryption of message content, profile fields, media files, and email addresses (with a deterministic hash column for exact-match login/search) at rest |
| Email | Brevo Email API for verification and password-reset messages |
| Push notifications | Firebase Cloud Messaging (FCM) with `flutter_local_notifications` |
| Media | `image_picker`, `record`, `audioplayers`, and server-side `ffmpeg` for photo, video, and voice messages |
| UI | `google_fonts` (Manrope typography), `cached_network_image` + `shimmer` (cached, fade-in media with loading placeholders), Material 3 |
| Deployment | Railway web service, PostgreSQL, and a distributed Android APK. The Flutter web client isn't hosted anywhere yet — see [Run the Web Client](#run-the-web-client) |

## Quick Start Guide for Reviewers

**[📥 Download Latest APK](https://gitea.kood.tech/triinupiliste/mobile-messenger/releases/download/v1.0.0/app-release.apk)**

The supplied `app-release.apk` is built to use the hosted Railway backend:

```text
https://mobile-messenger-production.up.railway.app
```

No Flutter, Node.js, database, Docker, ngrok, or local setup is needed to review the released APK. Download it and choose one of the options below.

> Reviewing the web client instead? It isn't hosted anywhere yet — see [Run the Web Client](#run-the-web-client) for how to run it locally against either the hosted Railway backend or your own.

> The app needs an internet connection. Before testing, the Railway service should respond at `https://mobile-messenger-production.up.railway.app/`.

### Option 1: Sideload on an Android Phone (Simplest)

1. Download `app-release.apk` to a computer or directly to the Android phone.
2. Transfer it to the phone by USB, cloud storage, or email.
3. On the phone, open **Files** and select `app-release.apk`.
4. If Android asks, allow installation from this source.
5. Tap **Install**, then open **Mobile Messenger**.

**Requires:** Android phone and the APK. No development tools are required.

### Option 2: Direct Install with ADB

With Android Platform Tools installed and a device or emulator connected:

```bash
adb install -r app-release.apk
```

**Requires:** Android Platform Tools and a physical Android device or emulator.

### Option 3: Browser-Based Android Emulator

Services such as [Appetize.io](https://appetize.io/) can run an Android APK in a browser:

1. Create a free account with the service.
2. Upload `app-release.apk`.
3. Start the browser-based Android session.
4. Open the installed app and test it normally.

**Requires:** A modern browser and an account with an APK-compatible emulator service. Availability and free-tier limits are controlled by that service.

### Option 4: Lightweight Android Emulator

Use an Android emulator such as [NoxPlayer](https://www.bignox.com/) or another APK-compatible emulator:

1. Install and open the emulator.
2. Drag `app-release.apk` into its window, or use its APK-install action.
3. Accept the installation prompt.
4. Launch **Mobile Messenger** inside the emulator.

**Requires:** A desktop computer, the emulator, and the APK. Flutter and Android Studio are not required.

Push notifications require Google Play Services, so they may not work inside an emulator that lacks them — everything else (auth, chat, media, encryption) works regardless.

Want to run your own backend instead of the hosted one? See [Developer Setup](#developer-setup-optional) below for the full walkthrough.

## How to Use the App

### First Sign-In

1. Register with a unique username, an email address that can receive email, and a password containing at least eight characters with uppercase, lowercase, numeric, and special characters.
2. Open the verification email and verify the account.
3. Sign in. Use **Forgot Password** if needed.

### Add a Contact and Start Chatting

1. Register and verify two accounts (two devices, or a device plus an emulator).
2. From the search screen, look up the other account by username or email and send an invitation.
3. Accept the invitation from the **Incoming** tab on the other account.
4. Open the new chat and send text, image, video, or audio messages. Both devices update in real time via Socket.IO.

### Manage Chats and Notifications

- Archive or unarchive a chat from the chat list.
- Delete a chat from the chat list — it's only removed from your own view; the other participant and their history are unaffected.
- Mute or unmute notifications for an individual chat from its menu.
- Edit or delete your own messages from the chat room, or swipe a message to reply to it.
- Switch the app's theme (Sunset Coral, Calm Forest, or Ocean Blue), or toggle dark mode, from Profile → Settings.

### Reviewer Guide

| Area | Quick check |
| --- | --- |
| Authentication | Register, verify the email, reset password, sign in, and sign out. |
| Profile | Edit username/About Me and upload a profile picture. |
| Contacts & invites | Search for a user, send an invitation, and accept/decline it from the other account. |
| Messaging | Send text, image, video, and audio messages; confirm typing indicators and read receipts. |
| Message management | Reply to a message (swipe it), edit one of your own messages, and delete one. |
| Chat list | Confirm chats sort by most recent message, and archive/unarchive/delete all work. |
| Push notifications | Background the app, receive a message from another account, and confirm a push notification arrives (and is suppressed when the chat is muted). |
| Theming | Open Settings and switch between the three themes and dark mode without leaving the page; confirm the whole app (including other tabs) updates immediately. |

## Developer Setup (Optional)

This section is only for developers who want to run their own backend and database. Reviewers can use the hosted Railway backend and the released APK above.

### Prerequisites

- Git
- Node.js 18+ and npm
- Docker with Docker Compose
- Flutter SDK and Android build tooling
- An ngrok account/client when testing from a physical device outside the local network
- A Brevo account with an API key and verified sender if email verification and password reset should work
- A Firebase project with an Android app configured, if push notifications should work

### Clone and Install

```bash
git clone https://gitea.kood.tech/triinupiliste/mobile-messenger.git
cd mobile-messenger
cd backend && npm install
cd ../frontend && flutter pub get
```

### Configure the Backend

Copy [.env.example](.env.example) to `.env` at the repository root. This local file is ignored by Git and must never be committed.

```env
APP_BASE_URL=http://localhost:5000/api

BREVO_API_KEY=replace_with_your_brevo_api_key
MAIL_FROM=verified-sender@example.com
MAIL_FROM_NAME=Mobile Messenger
```

`docker-compose.yml` supplies the remaining backend configuration (`DB_*`, `JWT_SECRET`, `ENCRYPTION_KEY`) as environment variables for local use. Replace `JWT_SECRET` and `ENCRYPTION_KEY` with your own strong values before any real deployment.

To enable outgoing emails, set a Brevo **API key** and a verified sender address in `.env`. The backend uses Brevo's HTTPS Email API, not SMTP.

To enable push notifications, place a Firebase service account key at `backend/secrets/firebase-service-account.json` and a matching `google-services.json` at `frontend/android/app/google-services.json`. Both are Firebase project downloads and are not committed to the repository.

Keep `ENCRYPTION_KEY` stable after users have registered: changing it makes existing encrypted messages, profile data, and media unreadable. Never commit `BREVO_API_KEY`, database passwords, signing keys, or Firebase credentials.

### Run the Local App

Run these commands in order:

1. Start PostgreSQL and the backend together:

   ```bash
   docker compose up --build
   ```

2. Confirm the backend is up (look for `🚀 Backend server running on port 5000` in the logs, or check that it responds instead of connection-refused):

   ```bash
   curl -i http://localhost:5000/api/auth/login
   ```

3. Point the Flutter client at the backend. `serverBaseUrl` in [frontend/lib/config/server_config.dart](frontend/lib/config/server_config.dart) reads from `--dart-define=SERVER_BASE_URL=...` at build/run time, falling back to the hosted Railway URL when that define isn't passed — so for the Android app specifically, the simplest option is still to edit the fallback value in that file **before** running or building (an APK has no way to change it afterwards without rebuilding):
   - Single USB-tethered device with `adb reverse tcp:5000 tcp:5000`: `http://127.0.0.1:5000`
   - Emulator or phone on the same Wi-Fi network as the backend: `http://<computer-LAN-IP>:5000`
   - Physical device(s) on a separate network (or anyone you're sharing a built APK with), backend exposed via ngrok:

     ```bash
     ngrok http 5000
     ```

     then use the printed HTTPS `ngrok-free.app` address, e.g. `https://abcd1234.ngrok-free.app`.

4. Run the app:

   ```bash
   cd frontend
   flutter run
   ```

Do not use `localhost` when the client runs on a separate device — it would resolve to the device itself, not your computer.

> When developing against your own backend on Android, edit the fallback value locally as above, and avoid committing that change back — restore the Railway URL before pushing. The web client (below) doesn't need this workaround since `--dart-define` can point it anywhere without touching the source.

## Run the Web Client

The web client shares the same codebase and backend as the Android app — start the backend as in step 1-2 above, then point Flutter at it with `--dart-define` instead of editing `server_config.dart`:

```bash
cd frontend
flutter run -d chrome --dart-define=SERVER_BASE_URL=http://localhost:5000
```

Replace the URL with whatever backend you're targeting (a local backend, an ngrok HTTPS URL, or the Railway URL). Omitting `--dart-define=SERVER_BASE_URL=...` falls back to the hosted Railway backend, same as the Android app. The backend's CORS config (`isOriginAllowed` in [env.ts](backend/src/config/env.ts)) already allows any `http://localhost:<port>` origin outside of production, which is what `flutter run -d chrome` uses (it picks a random dev-server port each run).

To produce a static build instead of running the Chrome dev server:

```bash
flutter build web --dart-define=SERVER_BASE_URL=https://your-backend-host
```

The output is written to `frontend/build/web/`. **This build isn't hosted anywhere right now** — there's no Netlify/Vercel/Firebase Hosting config in the repo, and the backend doesn't serve it as static files. To make the web client reachable at a URL instead of only via `flutter run -d chrome`, either deploy `frontend/build/web/` to any static host, or add `express.static('frontend/build/web')` (plus a catch-all route) to [server.ts](backend/src/server.ts) so the existing Railway backend can serve it too.

Known web-specific differences from the Android app: gallery-only media picking (no camera capture), hover-revealed message/chat menus instead of long-press/swipe, saving media downloads it via the browser instead of the device gallery, and a wide-viewport split-pane layout (chat list beside a single open chat, rather than full-screen navigation).

### Build Your Own Release APK

An APK only ever talks to the single `serverBaseUrl` that was set in [server_config.dart](frontend/lib/config/server_config.dart) at the moment it was built — there's no in-app way to switch backends afterwards. To produce an APK that connects to your own backend instead of the hosted Railway one (for example, to share with someone testing against your ngrok tunnel):

1. Start your backend and, if the tester isn't on your network, expose it with `ngrok http 5000` as above.
2. Edit `serverBaseUrl` to that backend's URL (`http://<LAN-IP>:5000` or the `https://<subdomain>.ngrok-free.app` address).
3. Build the APK:

   ```bash
   cd frontend
   flutter build apk --release
   ```

   The generated file is at `frontend/build/app/outputs/flutter-apk/app-release.apk`.
4. Share that APK file directly (e.g. via GitHub Releases, cloud storage, or USB) — anyone installing it will connect to the backend URL baked in at step 2.

Keep in mind free ngrok URLs are reassigned every time the tunnel restarts, so an APK built against one will stop working once that tunnel session ends; the tester would need a freshly built APK with the new URL. This is why the actual released APK on GitHub Releases points at the persistent Railway URL instead of an ngrok tunnel.

## Code Organisation

```text
mobile-messenger/
├── docker-compose.yml    # Postgres + backend, single-command local stack
├── backend/
│   ├── database/         # init.sql (auto-applied) and versioned migrations
│   ├── secrets/          # Firebase service account (not committed)
│   └── src/
│       ├── config/       # Database pool configuration
│       ├── controllers/  # HTTP request handlers
│       ├── middleware/   # Auth, upload, and error-handling middleware
│       ├── models/       # Backend domain models
│       ├── repositories/ # PostgreSQL queries and persistence
│       ├── routes/       # Express route definitions
│       ├── services/     # Email and push-notification services
│       ├── sockets/      # Socket.IO event handlers
│       ├── utils/        # Encryption and validation helpers
│       └── server.ts     # HTTP and Socket.IO server entry point
└── frontend/
    ├── web/              # Flutter web entry point (index.html, manifest, icons)
    └── lib/
        ├── config/       # Backend URL configuration
        ├── constants/    # Shared app constants
        ├── models/       # App data models
        ├── providers/    # Client application state
        ├── screens/      # Auth, profile, chat, and invite UI
        ├── services/     # REST, socket, storage, and push-notification clients
        ├── theme/        # Shared colours and theme setup
        ├── widgets/       # Reusable UI components
        └── main.dart     # Flutter application entry point
```

## Implementation Details

- **Encryption at rest:** message content, profile fields (About Me, avatar URL), media file bytes, and email addresses are AES-256-CBC encrypted before being written to the database or disk, and decrypted on the fly when served. Because AES-CBC uses a random IV per row, encrypted columns can't be matched directly in SQL — so email also gets a deterministic hash column (`email_hash`) used purely for exact-match lookups (login, duplicate checks, invite search), while the actual value stays encrypted. Usernames are not encrypted (they're already user-chosen public handles used for search/mentions, not confidential data), so they're matched and searched directly.
- **Server-side video compression:** uploaded videos are re-encoded through `ffmpeg` (H.264/AAC, capped resolution and bitrate) on the backend rather than on-device, which is more reliable across the wide range of Android camera/codec combinations than client-side compression plugins.
- **Real-time synchronisation:** Socket.IO broadcasts new messages, typing status, read receipts, edits, and deletions to each chat's participants.
- **Push notifications:** Firebase Cloud Messaging delivers background notifications for new messages and invitations; notifications respect a per-chat mute setting.
- **Authoritative uploads:** media uploads are stored server-side with generated filenames and served through an authenticated, path-traversal-guarded endpoint rather than static file serving.
- **Privacy:** passwords are bcrypt hashes; JWTs authenticate both REST and Socket.IO connections.
- **Resilience:** a global Flutter error boundary (`runZonedGuarded`, `FlutterError.onError`, a custom `ErrorWidget.builder`) shows a fallback screen instead of crashing or a raw red error screen.

## Troubleshooting

- **The hosted APK cannot connect:** visit `https://mobile-messenger-production.up.railway.app/`. A non-success response means the Railway service must be redeployed or checked before testing.
- **Local backend cannot connect to PostgreSQL:** run `docker compose up --build`, confirm port `5432` is free, and check the `postgres` service logs.
- **Verification email is missing:** check spam, ensure the sender is verified in Brevo, and confirm `BREVO_API_KEY` and `MAIL_FROM` are set in `.env`.
- **Phone cannot reach the local backend:** keep the backend and ngrok tunnel running, then update `serverBaseUrl` in `server_config.dart` with the current ngrok HTTPS address — free ngrok URLs change between sessions.
- **Push notifications don't arrive:** confirm `backend/secrets/firebase-service-account.json` and `frontend/android/app/google-services.json` are both present and match the same Firebase project. They also require Google Play Services, so some emulators can't receive them.
- **Port 5000 or 5432 is occupied:** stop the process already using it, or change the port mapping in `docker-compose.yml`.
- **Existing data unreadable after a configuration change:** restore the original `ENCRYPTION_KEY`; encrypted messages, profile fields, media, and email addresses all depend on that one stable key.
- **Video upload fails or times out:** confirm the backend container actually has `ffmpeg` installed (`docker exec -it <container> ffmpeg -version`) and that Railway's plan has enough CPU/time budget for compression on larger videos.
- **Previously sent media (images/videos/voice notes) becomes unreachable after a new deploy:** `docker-compose.yml`'s `uploads_data` volume only persists uploads for local `docker compose` runs — it has no effect on Railway, which builds directly from the repo. Without a Railway Volume mounted at `/app/uploads` for the backend service, every redeploy gives the container a fresh, empty filesystem and wipes all previously uploaded files (the database rows/encrypted content are unaffected, only the files on disk are lost). Fix: in the Railway dashboard, open the backend service → Settings → Volumes → add a volume mounted at `/app/uploads`, then redeploy. Files lost from before the volume was attached cannot be recovered.
- **`flutter run -d chrome` can't reach a local backend / CORS error in the browser console:** confirm the backend is actually running (`docker compose up --build`) and that `NODE_ENV` isn't set to `production` locally — `isOriginAllowed` in [env.ts](backend/src/config/env.ts) only auto-allows `http://localhost:<port>` origins outside of production. Also confirm the `--dart-define=SERVER_BASE_URL=...` value matches the backend's actual host/port.

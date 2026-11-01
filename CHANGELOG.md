## 0.1.0

* One-call `PushNotifications.instance.init` for FCM and local notifications
  (permissions, Android channels, iOS foreground presentation, token,
  background handler).
* Unified tap handling through a user-supplied decision maker, with a cold-start
  queue released by `markReady()` and duplicate-message and duplicate-launch-tap
  protection.
* Foreground, background and terminated handling for notification messages and
  data-only messages.
* Android notification channels with routing (FCM channel id, then
  `data[channelKey]`, then the default), plus `createChannel` / `deleteChannel`.
* App icon badge: full on iOS, best effort on Android (vendor broadcasts), with
  opt-in `autoIncrementOnPush` and `autoClearOnForeground`.
* Image notifications: Android big picture, iOS attachments, and a ready-made
  iOS Notification Service Extension class (`PushNotificationsServiceExtension`).
  Downloads are https-only by default, with a 10 s timeout and a 5 MB cap, and
  fall back to text-only.
* Firebase Installation ID (FID): `register()` / `unregister()`,
  `onRegistered` / `onUnregistered` and `installationId`, with
  `init(autoRegister: true)` registering by default (a failing registration does
  not fail `init`). The FCM `token` / `onTokenChanged` API is unchanged.
* `getPlatformToken()` returns the native platform token: the FCM token on
  Android, the APNs token on iOS (polled up to `apnsTimeout`, default 3 s).
  Differs from `token`, which is always the FCM token. Returns `null` instead
  of throwing when unavailable.
* Token, token refresh, topic subscription and foreground/tap streams.
* Android (Kotlin) and iOS (Swift Package Manager only) native code via Pigeon.
* `init` reads the app lifecycle through `WidgetsBinding` (to label tap
  `appState`), so call `WidgetsFlutterBinding.ensureInitialized()` before it
  (already needed for `Firebase.initializeApp()`).

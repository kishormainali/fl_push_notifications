## Unreleased

* iOS: a notification shown by the background handler carries the badge count
  (`content.badge`) when `autoIncrementOnPush` is on; the increment now happens
  before the notification is shown. Android notifications get no number
  (launchers sum `setNumber`); the running total stays in the vendor badge.
* Android: big-picture notifications use a small thumbnail as the large icon
  and clear the expanded large icon, so the picture is not repeated and the
  full bitmap is not sent twice.
* Android: a failing launcher lookup no longer escapes the badge methods; it
  counts as an unrecognized launcher.
* iOS: `getBadgeCount` returns the number shown on the app icon (including an
  APNs-applied `badge`), falling back to the stored counter (also briefly after
  the plugin's own `setBadgeCount`); `incrementBadge` counts from it, so it
  never lowers an APNs-applied badge.
* iOS: image downloads are accepted only when the content is a JPEG, PNG or GIF
  (sniffed, not trusted from MIME or URL), the image types Apple documents for
  `UNNotificationAttachment`; HEIC images are no longer attached. Cache hits are
  re-validated and refreshed, and the cache is pruned (least recently used
  first) to 50 files / 7 days.
* iOS: the temporary attachment copy is deleted when posting a notification
  fails.

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
  not fail `init`). The FCM `token` / `onTokenChanged` API is unchanged, except that
  `onTokenChanged` subscribes to the deprecated `onTokenRefresh` lazily, only
  while it has listeners (`init` no longer subscribes to it).
* `getPlatformToken()` returns the native platform token: the FCM token on
  Android, the APNs token on iOS (polled up to `apnsTimeout`, default 3 s).
  Differs from `token`, which is always the FCM token. Returns `null` instead
  of throwing when unavailable.
* Token, token refresh, topic subscription and foreground/tap streams.
* Android (Kotlin) and iOS (Swift Package Manager only) native code via Pigeon.
* `init` reads the app lifecycle through `WidgetsBinding` (to label tap
  `appState`), so call `WidgetsFlutterBinding.ensureInitialized()` before it
  (already needed for `Firebase.initializeApp()`).
* docs: setup aligned with Firebase docs (FID enable flags, method swizzling, iOS Background fetch and Remote notifications modes, Android 7.0+/Play services, auto-init); example enables FIDs
* The permission result enum is named `PushPermissionStatus` (avoids a clash with
  permission_handler's `PermissionStatus`).

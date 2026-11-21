## Unreleased

* Fix (Android): a foreground notification that used `title_loc_key` /
  `body_loc_key` instead of literal text was never shown. The plugin now
  resolves the keys from the app's string resources (iOS: `Localizable.strings`)
  through a new native `resolveLocalizedString`.
* Taps on localized notifications (launch and live) now carry the resolved
  title and body too.
* Docs: `doc/NOTIFICATION_COVERAGE.md` lists how each payload shape is handled.
* Fix (iOS): a tap that launched the app could be lost when the scene delegate
  did not forward the connection to Flutter plugins (firebase_messaging then
  reports it as `onMessageOpenedApp` before Dart listens). `init` now
  subscribes first and delivers such taps as terminated launch taps (deduped).
  The iOS image URL now also reads `notification.apple.imageUrl`.
* Docs: UIScene guidance (`FlutterSceneDelegate`, call `init` before other
  `FirebaseMessaging` use, keep the notification center delegate line).
* Dependencies: `firebase_messaging` ^17.1.0 (was ^17.0.1) and `firebase_core`
  ^5.2.0 (was ^5.1.0). `flutter_local_notifications` stays at ^23.0.0 and
  `pigeon` stays pinned at 29.1.1 (Pigeon 30 is a later item). The SDK floors
  are unchanged (Dart ^3.13.7, Flutter >=3.47.0).
* Tested with Flutter 3.50.1 (latest stable); Flutter 3.47.x remains the
  supported floor and is checked by a separate CI job.
* CI: primary jobs run on Flutter 3.50.1; a new `compat` job runs analyze and
  tests on the 3.47.8 floor. The publish workflow now checks that CHANGELOG.md
  has an entry for the tag version, skips publishing when the version is
  already on pub.dev (it still creates the GitHub release), and Dependabot is
  configured.
* Docs: setup and troubleshooting text aligned with the Firebase Flutter get-started and
  receive-messages pages (background handler rules, device-state
  preconditions, foreground behavior, permissions, images, a known gap for
  localization keys, and a note on UIScene apps).
* Log messages now use the `fl_push_notifications` prefix (Dart `debugPrint`,
  Android `Log` tags, iOS `NSLog`) instead of the old `push_notifications`.
  Storage, file and intent names are unchanged.

## 0.1.0

Published manually; the v0.1.0 git tag was not created (the first tagged
release is the next version).

* First release, published as `fl_push_notifications` (pub.dev rejected the
  originally planned name `push_notifications` as too similar to the existing
  `push_notification`). Import
  `package:fl_push_notifications/fl_push_notifications.dart`.
* Depends on `flutter_local_notifications` ^23.0.0 (requires Flutter 3.44+, app
  `compileSdk` 37 and AGP 9.1.1+ on Android).
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

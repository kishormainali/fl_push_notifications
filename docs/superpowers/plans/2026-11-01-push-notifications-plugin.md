# push_notifications Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Flutter plugin that sets up FCM + flutter_local_notifications once and correctly handles taps in foreground/background/terminated states, with a user-supplied decision maker for navigation, app badge management, and image notifications.

**Architecture:** Pure-Dart core (tap dispatcher with cold-start queue and de-duplication) sits behind two small "port" interfaces wrapping `firebase_messaging` and `flutter_local_notifications`, so it is unit-testable with fakes. A Pigeon-generated bridge (Dart/Kotlin/Swift) carries badge, image and native-display calls, structured around a per-platform `NotificationBuilder` so custom layouts can be added later.

**Tech Stack:** Flutter plugin (Dart, Kotlin, Swift), `firebase_core`, `firebase_messaging`, `flutter_local_notifications` (latest from pub.dev at scaffold time), `pigeon`.

**Spec:** `docs/superpowers/specs/2026-11-01-push-notifications-wrapper-design.md`

## Global Constraints

- Package name `push_notifications` (free on pub.dev, checked 2026-11-01). Platforms: Android, iOS only.
- Single plugin package with `android/` and `ios/` folders; not federated.
- iOS is **Swift Package Manager only**: the plugin ships `ios/push_notifications/Package.swift` with sources under `ios/push_notifications/Sources/push_notifications/`, and **no `.podspec`**. Pigeon's Swift output goes under that Sources folder. The `PushNotificationService` Notification Service Extension class lives in a separate Flutter-free SwiftPM library target/product (`PushNotificationsServiceExtension`) so an extension target can link it; the README also documents a copy-the-file fallback. Verify the plugin resolves with Flutter's SPM integration enabled (`flutter config --enable-swift-package-manager`). Dependencies that lack SPM support make Flutter fall back to CocoaPods for those dependencies only; record which, do not work around it.
- Native bridge is Pigeon (`pigeons/messages.dart`); generated code is committed.
- No router dependency; navigation happens only in the app's `decisionMaker`.
- Background handler and `onDidReceiveBackgroundNotificationResponse` are top-level functions annotated `@pragma('vm:entry-point')`; background isolate calls `Firebase.initializeApp()` without options.
- `flutter_local_notifications` `initialize` uses the named `settings:` parameter.
- iOS foreground: use `setForegroundNotificationPresentationOptions(alert, badge, sound)`; do **not** also show a local notification. Android foreground: show a local notification when `showForegroundNotifications` is true (default).
- Taps never dropped silently: with no decision maker, log loudly and keep the event queued. Decision-maker exceptions are caught and logged and must not break later taps.
- Channels (Android): `init(channels: List<PushChannel>, defaultChannelId, channelKey = 'channel_id')`. Routing order: FCM `notification.android.channelId` → `data[channelKey]` → `defaultChannelId`; unknown id warns and falls back, never drops. Default channel cannot be deleted. iOS uses the channel id only as `threadIdentifier`.
- Anti-goals (each pinned by a test): never silently drop a tap (corrupt payload still delivered as a minimal `PushMessage`); never display twice (iOS foreground OS-only, `notification` block never re-displayed by the handler, same `messageId` displayed once, local notification id derived from message id); never deliver a launch tap twice (in-memory LRU + last launch id persisted natively, idempotent `init`).
- Image download: native, timeout ≈10 s, size cap, https only by default (configurable), temp-dir cache, always fall back to text-only. Data-only image key `data['image']` (configurable).
- Badge: auto-increment and auto-clear are opt-in, default off. Counter stored natively (UserDefaults / SharedPreferences). `getBadgeCount()` returns `null` on Android.
- Out of scope: scheduling, action buttons, video/audio, web/Linux/Windows, custom layouts (only leave room via `extras` and `NotificationBuilder`).

## Review Focus

- `decisionMaker` throws on one tap → the next tap is still delivered (Task 3).
- `init` called twice → listeners and queue are not duplicated (Task 4).
- FCM message with null `notification` and empty/null `data` → `PushMessage` builds without throwing; title/body are null (Task 3, Task 5).
- Image URL malformed, `http://`, 404, timeout or oversize → text-only notification still shown (Tasks 7, 8).
- `setBadgeCount` with a negative number → clamped to 0; on an unrecognized Android launcher nothing throws and `isBadgeSupported()` is false (Task 6).

---

### Task 1: Scaffold the plugin

**Files:**
- Create: whole plugin skeleton via `flutter create`, `analysis_options.yaml`, `.gitignore`
- Modify: `pubspec.yaml`

**Interfaces:**
- Produces: package `push_notifications` with `lib/push_notifications.dart` as the only public library, `lib/src/` for internals, `test/` for tests.

- [ ] **Step 1: Initialize git in `/Users/mk7/development/oss-projects/fl_notifications`** (the folder is not a repo yet; the spec docs already under `docs/` are committed first).

- [ ] **Step 2: Scaffold.** Run `flutter create --template=plugin --platforms=android,ios -a kotlin -i swift --project-name push_notifications --org <org> .` (org is the builder's call; use the user's reverse-domain if known). Remove the generated method-channel boilerplate, keeping the plugin class files.

- [ ] **Step 3: Set dependencies** with `flutter pub add firebase_core firebase_messaging flutter_local_notifications` and `flutter pub add --dev pigeon`. Record the resolved versions in the README. Set the SDK/Flutter lower bounds to the current stable.

- [ ] **Step 4: Run `flutter analyze` and `flutter test`** — Expected: clean / default test passes (delete the default placeholder test).

- [ ] **Step 5: Commit** `chore: scaffold push_notifications plugin`.

### Task 2: Pigeon schema and generation

**Files:**
- Create: `pigeons/messages.dart`, `lib/src/messages.g.dart`, generated Kotlin and Swift files (paths set in the Pigeon config)

**Interfaces:**
- Produces (Pigeon):
  - `class NotificationContent { int id; String? title; String? body; String channelId; Map<String?, String?> data; String? imageUrl; ImageStyle imageStyle; int? badge; Map<String?, Object?> extras; }`
  - `enum ImageStyle { none, bigPicture }`
  - `class ChannelConfig { String id; String name; String? description; int importance; bool playSound; bool enableVibration; bool showBadge; String? groupId; }`
  - `@HostApi() abstract class PushHostApi { bool isBadgeSupported(); void setBadgeCount(int count); int? getBadgeCount(); void clearBadge(); int incrementBadge(); void createChannel(ChannelConfig c); void deleteChannel(String id); String? getLastLaunchId(); void setLastLaunchId(String id); @async void showNotification(NotificationContent content); @async String? downloadImage(String url, int timeoutMs, int maxBytes, bool httpsOnly); }`
  - `ImageStyle.bigPicture` on iOS means "attach image".

- [ ] **Step 1: Write `pigeons/messages.dart`** with the declarations above and `@ConfigurePigeon` output paths for Dart, Kotlin, Swift.

- [ ] **Step 2: Generate** with `dart run pigeon --input pigeons/messages.dart`. Expected: the three generated files exist and `flutter analyze` is clean once native stubs implement the host API (stubs throw `UnsupportedOperation` for now).

- [ ] **Step 3: Commit** `feat: add pigeon schema`.

### Task 3: PushMessage, config types and TapDispatcher

**Files:**
- Create: `lib/src/push_message.dart`, `lib/src/config.dart`, `lib/src/tap_dispatcher.dart`
- Test: `test/tap_dispatcher_test.dart`, `test/push_message_test.dart`

**Interfaces:**
- Produces:
  - `enum MessageSource { remote, local }`, `enum PushAppState { foreground, background, terminated }`
  - `class PushMessage { final String id; final String? title; final String? body; final Map<String, String> data; final String? imageUrl; final String channelId; final MessageSource source; final PushAppState appState; final Object? raw; }`
  - `factory PushMessage.fromRemote(RemoteMessage m, PushAppState state, {String imageKey = 'image'})`, `factory PushMessage.fromLocalPayload(String payload, PushAppState state)`, `String toLocalPayload()` (JSON of id, title, body, data, imageUrl).
  - `typedef DecisionMaker = FutureOr<void> Function(PushMessage message);`
  - `class PushChannel { String id; String name; String? description; Importance importance; bool playSound; bool enableVibration; bool showBadge; String? groupId; }`, `String resolveChannelId(RemoteMessage m, {required Set<String> known, required String defaultId, required String channelKey})` (order: `notification.android.channelId`, `data[channelKey]`, default; unknown → warn + default), `class BadgeConfig { bool autoIncrementOnPush = false; bool autoClearOnForeground = false; }`
  - `class TapDispatcher { TapDispatcher({DecisionMaker? decisionMaker, int dedupeCapacity = 50}); set decisionMaker(DecisionMaker?); Future<void> handleTap(PushMessage m); Future<void> markReady(); Stream<PushMessage> get onTap; }`

- [ ] **Step 1: Write failing tests** in `tap_dispatcher_test.dart`:
  - `queues taps before markReady and flushes in order`
  - `delivers immediately after markReady`
  - `drops a second tap with an already-delivered id`
  - `keeps queued and does not throw when no decisionMaker is set`; the tap is delivered once one is set and `markReady` runs
  - `decisionMaker exception does not block the next tap` (Review Focus)
  - `LRU evicts oldest id beyond capacity`
  And in `push_message_test.dart`: `fromRemote builds with null notification and empty data` (Review Focus), `local payload round-trips through toLocalPayload/fromLocalPayload`, `imageUrl read from notification.android.imageUrl, then data[imageKey]`, `resolveChannelId prefers android channelId, then data key, then default`, `unknown channel id falls back to default and still builds the message`, `corrupt local payload yields a minimal PushMessage instead of throwing` (anti-goal: no dropped taps), `tap with unknown channel is still delivered`.

- [ ] **Step 2: Run `flutter test test/tap_dispatcher_test.dart test/push_message_test.dart`** — Expected: FAIL (types undefined).

- [ ] **Step 3: Implement** the types above. Dispatcher: queue is a list; de-duplication via an insertion-ordered set of delivered ids; log via `debugPrint`/`dart:developer`.

- [ ] **Step 4: Re-run the tests** — Expected: PASS.

- [ ] **Step 5: Commit** `feat: add PushMessage and tap dispatcher`.

### Task 4: Ports and PushNotifications facade (foreground + tap sources)

**Files:**
- Create: `lib/src/ports.dart` (abstract ports), `lib/src/ports_impl.dart` (real plugin wrappers), `lib/src/push_notifications.dart`
- Modify: `lib/push_notifications.dart` (exports)
- Test: `test/push_notifications_test.dart` with `test/fakes.dart`

**Interfaces:**
- Consumes: Task 3 types.
- Produces:
  - `abstract class MessagingPort { Future<RemoteMessage?> getInitialMessage(); Stream<RemoteMessage> get onMessage; Stream<RemoteMessage> get onMessageOpenedApp; Future<String?> getToken(); Stream<String> get onTokenRefresh; Future<NotificationSettings> requestPermission(); Future<void> setForegroundPresentation({required bool alert, required bool badge, required bool sound}); Future<void> subscribeToTopic(String t); Future<void> unsubscribeFromTopic(String t); }`
  - `abstract class LocalPort { Future<void> initialize({required void Function(String? payload, PushAppState state) onTap, required Future<void> Function(NotificationResponse) onBackgroundTap}); Future<String?> launchPayload(); Future<void> createChannel(PushChannel c); Future<bool> requestAndroidPermission(); }`
  - `class PushNotifications { static final instance; Future<void> init({required DecisionMaker decisionMaker, List<PushChannel> channels, String defaultChannelId = 'default', String channelKey = 'channel_id', bool showForegroundNotifications = true, BackgroundMessageHook? onBackgroundMessage, BadgeConfig badge = const BadgeConfig(), String imageKey = 'image', bool imageHttpsOnly = true}); void markReady(); Future<PermissionStatus> requestPermission(); Future<String?> get token; Stream<String> get onTokenChanged; Stream<PushMessage> get onForegroundMessage; Stream<PushMessage> get onTap; Future<void> subscribeToTopic(String); Future<void> unsubscribeFromTopic(String); @visibleForTesting PushNotifications.withPorts(MessagingPort, LocalPort, PushHostApi) }`
  - `enum PermissionStatus { granted, provisional, denied, notDetermined }`
  - `typedef BackgroundMessageHook = Future<void> Function(RemoteMessage);` (must be a top-level function).

- [ ] **Step 1: Write failing tests** with fake ports:
  - `init reads getInitialMessage and local launch payload once, as terminated taps, queued until markReady`
  - `onMessageOpenedApp becomes a background tap`
  - `local port tap becomes a tap with source local`
  - `same message id from getInitialMessage and local launch is delivered once`
  - `foreground on Android shows a local notification and emits onForegroundMessage`
  - `foreground on iOS sets presentation options and does not show a local notification`
  - `showForegroundNotifications false skips the local display`
  - `init twice does not duplicate listeners` (Review Focus)
  - `onTokenChanged forwards onTokenRefresh`
  - `init creates every configured channel via the host API; default channel must be in the list or init throws ArgumentError`
  - `createChannel adds at runtime; deleteChannel of the default channel throws`
  - `foreground message is displayed on its resolved channel`
  - Anti-goals: `same messageId on onMessage twice displays once`, `persisted last launch id suppresses a stale getInitialMessage after restart` (fake host API returns the id), `launch id is persisted after the first delivery`, `tap with no decisionMaker is retained and logged, not dropped`

- [ ] **Step 2: Run `flutter test test/push_notifications_test.dart`** — Expected: FAIL.

- [ ] **Step 3: Implement** the facade. `init`: set up local plugin (`initialize(settings: ..., onDidReceiveNotificationResponse: ..., onDidReceiveBackgroundNotificationResponse: pushLocalBackgroundTap)`), create the Android channel, set iOS presentation options, register `FirebaseMessaging.onBackgroundMessage(pushBackgroundHandler)` (Task 5), subscribe the listeners, then fetch launch sources once; guard with an `_initialized` flag. Platform choice goes through an injectable `isIOS` so tests can flip it.

- [ ] **Step 4: Re-run the tests** — Expected: PASS.

- [ ] **Step 5: Commit** `feat: add PushNotifications facade and tap sources`.

### Task 5: Background handler and data-only display

**Files:**
- Create: `lib/src/background_handler.dart`
- Test: `test/background_handler_test.dart`

**Interfaces:**
- Consumes: Task 2 `PushHostApi.showNotification`, Task 3 `PushMessage`/`NotificationContent`.
- Produces: top-level `@pragma('vm:entry-point') Future<void> pushBackgroundHandler(RemoteMessage m)` and `@pragma('vm:entry-point') Future<void> pushLocalBackgroundTap(NotificationResponse r)`; `NotificationContent contentFromRemote(RemoteMessage m, {String imageKey, String titleKey = 'title', String bodyKey = 'body', String channelId})`; a static `BackgroundConfig` persisted to native/shared prefs so the isolate knows channel id, imageKey, title/body keys, and the badge config; `Future<void> Function(RemoteMessage)? ` user hook is looked up through that config's stored hook handle (`PluginUtilities.getCallbackHandle`).

- [ ] **Step 1: Write failing tests:**
  - `data-only message is shown via showNotification with title/body from data keys`
  - `notification message (has notification block) is not displayed again by the handler`
  - `null notification and empty data does not throw and shows nothing` (Review Focus)
  - `autoIncrementOnPush increments badge for background data-only messages`
  - `user hook is called after display`
  - `data-only message is shown on the channel from data[channelKey], else the default`
  - `message with a notification block is never displayed by the handler` (anti-goal: no double display)
  - `local notification id is derived deterministically from the message id`

- [ ] **Step 2: Run the tests** — Expected: FAIL.

- [ ] **Step 3: Implement** the handler: `WidgetsFlutterBinding.ensureInitialized()`, `Firebase.initializeApp()`, load `BackgroundConfig`, build content, call `showNotification` only when `m.notification == null`, apply the badge, then the user hook. Keep it free of app state and UI.

- [ ] **Step 4: Re-run the tests** — Expected: PASS.

- [ ] **Step 5: Commit** `feat: add background handler`.

### Task 6: Badge (Dart, Android, iOS)

**Files:**
- Create: `lib/src/badge.dart`; `android/.../BadgeHandler.kt`; `ios/push_notifications/Sources/push_notifications/BadgeHandler.swift`
- Modify: native plugin classes to register `PushHostApi` (also for background engines), `PushNotifications` to expose badge methods and auto-options
- Test: `test/badge_test.dart`, `android/src/test/.../BadgeHandlerTest.kt`, `example/ios` XCTest where practical

**Interfaces:**
- Consumes: Task 2 host API.
- Produces: `PushNotifications.isBadgeSupported()`, `setBadgeCount(int)`, `clearBadge()`, `getBadgeCount()` (all `Future`); native `BadgeHandler` with the same semantics.

- [ ] **Step 1: Write failing Dart tests:**
  - `setBadgeCount clamps negatives to 0` (Review Focus)
  - `clearBadge calls clearBadge on host`
  - `autoIncrementOnPush increments for a push received while not foreground, and not in foreground`
  - `autoClearOnForeground clears on AppLifecycleState.resumed`
  - Kotlin: `unrecognized launcher reports unsupported and set does not throw` (Review Focus), `counter persists in SharedPreferences`.

- [ ] **Step 2: Run the tests** — Expected: FAIL.

- [ ] **Step 3: Implement iOS** `BadgeHandler`: `UNUserNotificationCenter.current().setBadgeCount` (iOS 16+) else `UIApplication.shared.applicationIconBadgeNumber` on the main thread; counter in UserDefaults; `getBadgeCount` returns the stored value.

- [ ] **Step 4: Implement Android** `BadgeHandler`: detect launcher via the home intent; for recognized vendors send the vendor broadcast/content-provider update (Samsung, Xiaomi via notification number, Huawei, Sony, Oppo/Vivo, etc.); persist the count in SharedPreferences; `getBadgeCount` returns `null`; `isBadgeSupported` true only for recognized launchers. If hand-written vendor support proves too fragile in the spike, swap in a maintained dependency (spec: builder's call).

- [ ] **Step 5: Re-run the tests and `flutter analyze`** — Expected: PASS / clean.

- [ ] **Step 6: Commit** `feat: add app badge support`.

### Task 7: Android native notification builder and image download

**Files:**
- Create: `android/.../NotificationBuilder.kt`, `android/.../ImageDownloader.kt`
- Modify: `android/.../PushNotificationsPlugin.kt` (implements `showNotification`, `downloadImage`)
- Test: `android/src/test/.../ImageDownloaderTest.kt`, `NotificationBuilderTest.kt`

**Interfaces:**
- Consumes: Task 2 `NotificationContent`, `ImageStyle`.
- Produces: `NotificationBuilder.build(context, NotificationContent, Bitmap?): Notification` (small icon from app meta-data/launcher icon, channel id, `setNumber(badge)`, `BigPictureStyle` when bitmap present, `PendingIntent` that launches the app with the JSON payload as extra so the local plugin reports taps); `ImageDownloader.download(url, timeoutMs, maxBytes, httpsOnly): File?` returning `null` on any failure.

- [ ] **Step 1: Write failing tests:**
  - `http url rejected when httpsOnly` (null)
  - `oversize body aborts and returns null`
  - `timeout returns null`, `404 returns null`, `malformed url returns null` (Review Focus)
  - `builder uses BigPictureStyle with bitmap and plain style without`
  - `builder sets number from badge`
  - `createChannel is idempotent and applies importance/sound/vibration/showBadge/group`
  - `showNotification with an unknown channelId falls back to the default channel` (Kotlin handler keeps the default id from the last createChannel marked default)
  - `same notification id replaces rather than stacks`

- [ ] **Step 2: Run `./gradlew testDebugUnitTest`** (from `example/android`) — Expected: FAIL.

- [ ] **Step 3: Implement** the downloader using `HttpURLConnection` with connect/read timeouts, a streamed byte cap, and a temp-dir cache keyed by a URL hash; implement the builder and wire `showNotification` to download first, then build, falling back to text-only on `null`.

- [ ] **Step 4: Re-run the tests** — Expected: PASS.

- [ ] **Step 5: Commit** `feat(android): native notification builder and image download`.

### Task 8: iOS native builder, image attachment and Notification Service Extension class

**Files:**
- Create: `ios/push_notifications/Sources/push_notifications/NotificationBuilder.swift`, `ios/push_notifications/Sources/push_notifications/ImageDownloader.swift`, `ios/push_notifications/Sources/push_notifications/PushNotificationService.swift`
- Modify: `ios/push_notifications/Sources/push_notifications/PushNotificationsPlugin.swift` (implements `showNotification`, `downloadImage`)
- Test: XCTest in `example/ios/RunnerTests` for the downloader and builder

**Interfaces:**
- Consumes: Task 2 host API.
- Produces: `NotificationBuilder.build(NotificationContent, URL?) -> UNMutableNotificationContent` (title/body/badge/userInfo with the payload, attachment when a local file URL is given); `ImageDownloader.download(url:timeout:maxBytes:httpsOnly:) async -> URL?` returning `nil` on any failure; `open class PushNotificationService: UNNotificationServiceExtension` that reads `image` (or `fcm_options.image`) from `userInfo`, downloads it with the same rules, attaches it, and always calls `contentHandler` (including in `serviceExtensionTimeWillExpire`).

- [ ] **Step 1: Write failing tests:**
  - `non-https url returns nil when httpsOnly`
  - `oversize, timeout, 404 and malformed urls return nil` (Review Focus)
  - `builder adds an attachment when a file url is given and none otherwise`
  - `service extension calls contentHandler with original content on download failure`

- [ ] **Step 2: Run the XCTest suite** (`xcodebuild test` on the example's iOS test scheme, or `flutter test integration_test` where applicable) — Expected: FAIL.

- [ ] **Step 3: Implement** with `URLSession` (ephemeral config, timeout, size check from `Content-Length` and the streamed total), file extension from the MIME type so `UNNotificationAttachment` accepts the file, and a `UNNotificationRequest` posted via `UNUserNotificationCenter` for `showNotification`.

- [ ] **Step 4: Re-run** — Expected: PASS.

- [ ] **Step 5: Commit** `feat(ios): native notification builder, image attachment and service extension class`.

### Task 9: Wire images into the Dart flow

**Files:**
- Modify: `lib/src/push_notifications.dart`, `lib/src/background_handler.dart`
- Test: add to `test/push_notifications_test.dart` and `test/background_handler_test.dart`

**Interfaces:**
- Consumes: Tasks 4, 5, 7, 8.

- [ ] **Step 1: Write failing tests:**
  - `foreground Android message with image shows content with imageUrl and ImageStyle.bigPicture`
  - `data-only background message with data['image'] shows image content`
  - `image download failure still results in showNotification with imageUrl null` (the host API decides; the Dart layer never throws)
  - `custom imageKey is honored`

- [ ] **Step 2: Run the tests** — Expected: FAIL.

- [ ] **Step 3: Implement** passing `imageUrl`/`imageStyle` through `contentFromRemote` and the foreground path, using `imageKey` and `imageHttpsOnly` from the stored config.

- [ ] **Step 4: Re-run and run the whole suite plus `flutter analyze`** — Expected: PASS / clean.

- [ ] **Step 5: Commit** `feat: wire image notifications`.

### Task 10: Example app, README and manual checklist

**Files:**
- Modify: `example/lib/main.dart`, `example/` platform config for Firebase placeholders
- Create: `README.md`, `doc/MANUAL_TEST_CHECKLIST.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: the full public API.

- [ ] **Step 1: Example app:** `main` calls `Firebase.initializeApp()`, then `PushNotifications.instance.init(decisionMaker: ...)` with a go_router-free decision maker that pushes a screen based on `data['type']`, then `markReady()` after the first frame; buttons for token, permission, badge set/clear.

- [ ] **Step 2: README:** installation, one-call setup, decision-maker example, the state × message-kind table from the spec, badge platform limitations, image rules, and the platform setup list (iOS capability, background modes, APNs key, Notification Service Extension target with `PushNotificationService`, `mutable-content: 1`, Android 13 permission, default channel meta-data matching `defaultChannelId`, how to send `android_channel_id` (FCM) or `data.channel_id`, and the Android rule that channel importance/sound cannot change after creation, small icon, native Firebase config).

- [ ] **Step 3: Manual checklist:** each of foreground / background / terminated × notification message / data-only × with and without image, on Android and iOS, plus badge set/clear/auto options and the cold-start queue.

- [ ] **Step 4: Run `flutter analyze`, `flutter test`, and `cd example && flutter build apk --debug`** — Expected: clean / pass / builds. (iOS build requires a configured Firebase project and is covered by the manual checklist.)

- [ ] **Step 5: Commit** `docs: example app, README and manual checklist`.

---

## Self-review notes

- Spec coverage: states table → Tasks 3–5; decision maker, queue, dedupe → Tasks 3–4; token/permission/topics → Task 4; Pigeon bridge/extensibility → Task 2, builders in 7–8; badge → Task 6; images → Tasks 7–9; README/setup → Task 10.
- Type names are consistent across tasks (`PushMessage`, `TapDispatcher`, `DecisionMaker`, `PushHostApi`, `NotificationContent`, `ImageStyle`, `BadgeConfig`).
- Known judgement call left to the builder: Android vendor-badge approach (Task 6) and the package org id (Task 1).

# push_notifications

Unified push notifications for Flutter on Android (Kotlin) and iOS (Swift,
Swift Package Manager only). It wraps `firebase_messaging` and
`flutter_local_notifications` so an app calls `init` once, supplies one
callback that decides which screen a tap opens, and gets consistent behavior in
the foreground, background and terminated states.

## Supported platforms

| Platform | Minimum version |
| --- | --- |
| Android | minSdk 24 (Android 7.0) with Google Play services |
| iOS | 15.0 (Swift Package Manager only) |

## Resolved dependency versions

- firebase_core ^5.1.0
- firebase_messaging ^17.0.1
- flutter_local_notifications ^22.3.3
- pigeon ^29.1.0 (dev)

## Install

```sh
flutter pub add push_notifications
flutter pub add firebase_core   # for Firebase.initializeApp() in your main()
```

Or in `pubspec.yaml`:

```yaml
dependencies:
  push_notifications: ^0.1.0
  firebase_core: ^5.1.0
```

`push_notifications` re-exports `RemoteMessage` (from `firebase_messaging`) and
`Importance` (from `flutter_local_notifications`), so you do not need either
package as a direct dependency just for those types.

Your app still needs Firebase: add `firebase_core`, call
`Firebase.initializeApp()` before `init`, and configure Firebase natively
(`google-services.json`, `GoogleService-Info.plist`). The background isolate
calls `Firebase.initializeApp()` without options, which relies on that native
configuration.

## One-call setup

```dart
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
// Also exports RemoteMessage and Importance.
import 'package:push_notifications/push_notifications.dart';

final navigatorKey = GlobalKey<NavigatorState>();

// Optional. Must be a top-level function.
@pragma('vm:entry-point')
Future<void> onBackgroundMessage(RemoteMessage message) async {}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await PushNotifications.instance.init(
    decisionMaker: (PushMessage m) {
      // Open a screen based on the message. Do not await the navigation: a
      // pushed route's future completes only when it is popped.
      if (m.data['type'] == 'chat') {
        navigatorKey.currentState?.pushNamed('/chat', arguments: m);
      }
    },
    channels: [
      PushChannel(id: 'default', name: 'General', importance: Importance.high),
      PushChannel(id: 'chat', name: 'Messages', importance: Importance.max),
    ],
    defaultChannelId: 'default',
    onBackgroundMessage: onBackgroundMessage,
  );
  runApp(MyApp(navigatorKey: navigatorKey));
  // The navigator exists after the first frame: release queued taps.
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => PushNotifications.instance.markReady(),
  );
}
```

`init` parameters: `decisionMaker` (required), `channels`, `defaultChannelId`
(default `'default'`, must be one of the channels; if `channels` is empty a
channel named "General" is created), `channelKey` (`'channel_id'`),
`showForegroundNotifications` (`true`), `onBackgroundMessage`, `badge`
(`BadgeConfig`), `imageKey` (`'image'`), `titleKey` (`'title'`), `bodyKey`
(`'body'`), `imageHttpsOnly` (`true`). Calling `init` again returns the first
call's result; a failed `init` can be retried. `autoRegister` (`true`) also
registers for the Firebase Installation ID, see
[Installation ID (FID) and FCM token](#installation-id-fid-and-fcm-token).

Other API: `markReady()`, `requestPermission()` (returns `PushPermissionStatus`),
`token`, `onTokenChanged`, `register` / `unregister` / `onRegistered` /
`onUnregistered` / `installationId`, `onForegroundMessage`, `onTap` (for analytics),
`subscribeToTopic` / `unsubscribeFromTopic`, `createChannel` / `deleteChannel`,
and the badge methods below.

### The decision maker

`DecisionMaker = FutureOr<void> Function(PushMessage)`. Every tap, from any
source and in any app state, goes through it. `PushMessage` has `id`, `title`,
`body`, `data`, `imageUrl`, `channelId`, `source` (`remote` or `local`),
`appState` (`foreground`, `background`, `terminated`) and `raw`.

- Taps that arrive before `markReady()` are queued and delivered in order when
  you call it. After that they are delivered immediately.
- Taps are delivered one at a time: the next tap waits until the decision
  maker's returned future completes. Return promptly; in particular do not
  `await` a `Navigator.push*` call (it completes only when the route is
  popped), or later taps stall. Delivery is single-flight, so the decision
  maker never runs for two taps at once; one that never completes stalls
  later taps (they stay queued, never dropped).
- An exception thrown by the decision maker is caught and logged; it does not
  block later taps.
- A repeated message id is delivered once (the dropped duplicate is logged).
- `appState` of a tap is captured where the tap is received, not when Dart
  gets it: launch taps are `terminated`; a tap on a notification posted by the
  plugin natively is `foreground` if the app was active when the OS reported
  the tap (iOS: the app became active and has not entered the background
  since, so a tap from Notification Center pulled over the app counts;
  Android: the activity had been resumed since it was last started), otherwise
  `background`; a tap reported by
  flutter_local_notifications or `onMessageOpenedApp` is `foreground` if the
  last lifecycle state other than `inactive` was `resumed`, otherwise
  `background`. A tap queued during a cold start that is not the launch tap
  keeps its captured state and is delivered after the launch tap. `appState`
  is informational (it does not affect
  routing or de-duplication).

## Installation ID (FID) and FCM token

With firebase_messaging 17, the direct-send target is the Firebase Installation
ID (FID), delivered by `register()` and `onRegistered`. The FCM token API
(`token`, `onTokenChanged`) still works unchanged, but the upstream
`getToken` / `onTokenRefresh` / `deleteToken` it wraps are deprecated. Use the
FID if you send to installation IDs; keep using the token if your backend sends
to FCM tokens, and then pass `autoRegister: false` (see
[Firebase Installation ID setup](#firebase-installation-id-setup) for the
caution against mixing FID and token APIs).

```dart
final push = PushNotifications.instance;
// Listen before or right after init; events are not replayed.
push.onRegistered.listen((fid) => api.saveInstallationId(fid));
push.onUnregistered.listen((fid) => api.removeInstallationId(fid));
await push.init(decisionMaker: ...); // autoRegister: true registers for you
final fid = push.installationId; // latest FID seen, or null so far
```

* `autoRegister` (default `true`): `init` subscribes to the FID streams first,
  then calls `register()` without awaiting it. A failing `register()` is logged
  and does not fail `init`; the token API keeps working. Pass
  `autoRegister: false` to control it yourself and call `register()` later
  (it attaches the listeners on first use).
* `installationId` is the most recent FID seen on `onRegistered`; it is `null`
  until the first event and is cleared when `onUnregistered` emits that FID.
  There is no way to read the FID without the stream.
* `unregister()` unregisters this app instance; `onUnregistered` then emits the
  FID that is no longer active, so remove it from your backend.
* Semantics of firebase_messaging 17.0.1: `onRegistered` / `onUnregistered` are
  plain broadcast streams without replay, so an event emitted while nobody
  listens is lost (hence listen first). `register()` is implemented on Android
  (FirebaseMessaging.register), iOS/macOS (`registerWithCompletion`) and web
  (a no-op on unsupported browsers). Whether the native SDK emits
  `onRegistered` again on a repeated `register()` is up to the native Firebase
  SDK and is not guaranteed by the Dart layer; do not rely on it, and use your
  own `onRegistered` listener (not a repeated call) to learn the FID.

## Platform token (FCM on Android, APNs on iOS)

`getPlatformToken()` returns the native platform token: the FCM token on
Android, the APNs device token on iOS.

```dart
final t = await PushNotifications.instance.getPlatformToken();
if (t != null) await api.savePlatformToken(t);
```

* It differs from `token`, which is always the FCM token on every platform.
* On iOS the APNs token is polled every 250 ms for up to `apnsTimeout`
  (default 3 s; `Duration.zero` makes a single attempt). firebase_messaging
  17.0.1 does not wait itself: `getAPNSToken()` returns `null` immediately
  while APNs has not delivered a token.
* It never throws: it returns `null` when the token is unavailable (errors are
  logged without the token), so you can call it again later.
* The APNs token only exists once the app has registered for remote
  notifications (request permission and set up push on iOS first). iOS
  simulators may never return one.
* The Firebase docs ([get-started page](https://firebase.google.com/docs/cloud-messaging/flutter/get-started),
  last updated 2026-10-28) state that in iOS SDK 10.4.0 and higher the APNs
  token must be available before making API requests, so on Apple platforms
  make sure `getAPNSToken()` is non-null before FCM plugin calls. In
  firebase_messaging 17.0.1 the iOS `getToken()` throws `apns-token-not-set`
  instead of waiting when it is not.
* The FID API (`register()` / `onRegistered` / `installationId`, see above) is
  the newer direct-send identifier.

## Behavior by app state

"Notification message" is an FCM payload with a `notification` block;
"data-only" has only `data`.

| State | Message kind | What happens | Tap path |
|---|---|---|---|
| Foreground | notification | `onForegroundMessage` emits first. Android: FCM shows nothing, so the package shows a local notification (if `showForegroundNotifications`; needs a `title` or `body`). iOS: the OS presents it (alert/badge/sound, via `setForegroundNotificationPresentationOptions`); the package does not also show one. | Android: local notification tap (big picture: the native tap hook). iOS: `onMessageOpenedApp` |
| Foreground | data-only | `onForegroundMessage` emits first. If `showForegroundNotifications` and `data` has a `title` or `body` (`titleKey`/`bodyKey`), the package shows a notification: Android a local one, iOS a native one (the OS presents nothing for data-only, so nothing is duplicated). A repeated message id is shown once. | Local notification tap, or the native tap hook |
| Background | notification | The OS displays it. | `onMessageOpenedApp` |
| Background | data-only | The package's top-level handler runs in a background isolate: it shows a notification from `data` (`title`/`body` keys), then initializes Firebase and runs your optional `onBackgroundMessage` (if Firebase init fails the hook is skipped; display and badge still happen). | Native/local notification tap |
| Terminated | notification | The OS displays it. | On next launch, `getInitialMessage()`; queued until `markReady()` |
| Terminated | data-only | Same background-handler path. Android: high priority. iOS: needs `content-available` and delivery is throttled by the OS. | Launch payload; queued until `markReady()` |

## Channels (Android)

A message's channel is picked in this order: FCM
`notification.android.channelId`, then `data[channelKey]`, then
`defaultChannelId`. An unknown id logs a warning and falls back to the default;
the message is never dropped. The default channel cannot be deleted.

Android fixes a channel's importance and sound when it is first created.
Changing them later requires a new channel id. iOS has no channels; the channel
id is only used as the notification `threadIdentifier`.

## Badge

```dart
await PushNotifications.instance.setBadgeCount(5);
await PushNotifications.instance.clearBadge();
final supported = await PushNotifications.instance.isBadgeSupported();
final count = await PushNotifications.instance.getBadgeCount(); // iOS only
```

- iOS: full support (`setBadgeCount`, read back with `getBadgeCount`).
  `requestPermission()` asks for the badge permission. `getBadgeCount` reads the
  number actually shown on the app icon, so it includes a value the OS applied
  from an APNs `aps.badge` (it falls back to the plugin's stored counter when the
  icon number cannot be read, and for 2 s after the plugin's own `setBadgeCount`,
  which the system applies asynchronously). `incrementBadge` and
  `autoIncrementOnPush` count from that same number, so they never lower an
  APNs-applied badge.
- Android: best effort. There is no official badge API; the plugin sends
  vendor broadcasts and `isBadgeSupported()` reports whether the launcher is
  recognized. `getBadgeCount()` returns `null`. The vendor badge permissions in
  the plugin's manifest merge into your app.
- `BadgeConfig(autoIncrementOnPush, autoClearOnForeground)`, both off by
  default. Auto-increment applies to pushes handled by the background handler
  (data-only messages while the app is not in the foreground); foreground
  pushes never increment. Auto-clear resets the badge at `init` and whenever the
  app returns to the foreground.
- With `autoIncrementOnPush` on, the background handler increments before it
  shows the notification. On iOS the notification carries the new count as its
  badge (the absolute icon value). On Android the notification gets no number:
  launchers that show dots or numbers from notifications derive them from the
  active notifications (and sum `setNumber`), so the running total is only sent
  to recognized launchers through the vendor badge counter. If the increment
  fails the notification is still shown, without a badge.

## Images

| Case | Android | iOS |
|---|---|---|
| Notification message | Automatic from the FCM `image` field. | Needs a Notification Service Extension and `mutable-content: 1` (below). |
| Data-only | Downloaded natively and shown as a big picture from `data['image']` (key configurable via `imageKey`). | Downloaded natively and attached to the notification (subject to iOS background limits). |
| Foreground | Big picture. | Notification message: OS presents it; the image shows only if the extension ran. Data-only: downloaded natively and attached. |

Downloads are https-only by default (`imageHttpsOnly`), time out after 10 s and
are capped at 5 MB. On any failure the notification is shown without the image.
The Notification Service Extension is always https-only with the same limits.

On iOS the downloaded bytes must be a JPEG, PNG or GIF, detected from the file
content (the `Content-Type` and URL path are not trusted; an HTML page served
with an image type is rejected). Images are cached in the temp directory, at
most 50 files (least recently used dropped first), each kept for up to 7 days
after its last use. On Android the collapsed view uses a
small thumbnail as the large icon, and the expanded view shows the picture once.

## Guarantees

- A tap is never silently dropped: with no decision maker it is logged and kept
  queued; a corrupt local payload still yields a minimal `PushMessage`.
- The same notification is not shown twice: on iOS a foreground notification
  message uses OS presentation only (the package shows only data-only
  messages, which the OS does not present), notification messages are never re-shown by the background handler, a
  repeated FCM message id is shown once, and local notification ids derive from
  the message id so a replay replaces the existing one.
- A launch tap is delivered once: delivered ids are also persisted natively so a
  stale initial message after a restart is ignored.

## Platform setup

Checked against the Firebase Flutter FCM get-started page (last updated
2026-10-28): <https://firebase.google.com/docs/cloud-messaging/flutter/get-started>.
Unless labeled "(this plugin)", an item summarizes that page. Items labeled
"(this plugin)" come from this plugin or its dependencies, not from that page
(for example notification permission on Android 13+, default channel and icon,
desugaring, Swift Package Manager and the app delegate).

### iOS

1. Open `ios/Runner.xcworkspace` in Xcode. Add the Push Notifications
   capability and, under Signing & Capabilities → Background Modes, enable
   both **Background fetch** and **Remote notifications** on the Runner
   target.
2. Upload your APNs authentication key (.p8) to Firebase: Firebase console →
   Settings → General → Cloud Messaging tab → iOS app configuration →
   APNs authentication key. Upload a development and/or production key (at
   least one) with the key ID and your Apple team ID (Firebase docs).
3. **Keep method swizzling enabled** (Firebase docs: the FCM Flutter plugin
   needs it on Apple devices; without it features such as FCM registration
   handling do not work properly). Do not set `FirebaseAppDelegateProxyEnabled`
   to `NO` in `Info.plist`. (This plugin) It also relies on Flutter's app delegate
   forwarding the notification callbacks.
4. (this plugin) In `AppDelegate.swift`, set the notification center delegate. This is
   required so native taps are forwarded to the plugin:

   ```swift
   override func application(
     _ application: UIApplication,
     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
   ) -> Bool {
     UNUserNotificationCenter.current().delegate = self
     return super.application(application, didFinishLaunchingWithOptions: launchOptions)
   }
   ```

5. (this plugin) The plugin supports Swift Package Manager only (no CocoaPods). Enable it with
   `flutter config --enable-swift-package-manager`.
6. (this plugin) If you develop the plugin locally from source, the plugin folder must be
   named `push_notifications`, because SwiftPM keys on the folder name.
7. On Apple platforms make sure the APNs token is available before calling FCM
   plugin APIs (Firebase docs, iOS SDK 10.4.0+); see
   [Platform token](#platform-token-fcm-on-android-apns-on-ios).

#### Notification Service Extension (iOS images)

1. In Xcode: File → New → Target → Notification Service Extension.
2. Add the `PushNotificationsServiceExtension` Swift package product (from this
   plugin's `ios/push_notifications` package) to the extension target.
3. Replace the generated class with:

   ```swift
   import PushNotificationsServiceExtension
   class NotificationService: PushNotificationService {}
   ```

   Fallback if you cannot link the product: copy
   `ios/push_notifications/Sources/PushNotificationsServiceExtension/PushNotificationService.swift`
   and the files in `Sources/PushNotificationsCore` into the extension target.
4. Send `mutable-content: 1`. The image URL is read from `image` or
   `fcm_options.image` in the payload.

### Android

- Requirements (Firebase docs): FCM clients need a device running Android 7.0
  or higher (API 24, which is this plugin's `minSdk`) with Google Play services
  installed, or an emulator running Android 7.0 with Google APIs. Your app is
  not limited to Play Store distribution. If Play services may be missing, call
  `GoogleApiAvailability.makeGooglePlayServicesAvailable()` (from
  `com.google.android.gms.common`) in your main activity's `onCreate()` or
  `onResume()` to check for and fix it.
- (this plugin) Android 13+ needs the `POST_NOTIFICATIONS` permission (declared by the plugin;
  `requestPermission()` asks for it).
- (this plugin) Set the default channel for notification messages in your app manifest, to
  the same value as `defaultChannelId`:

  ```xml
  <meta-data
      android:name="com.google.firebase.messaging.default_notification_channel_id"
      android:value="default" />
  ```
- (this plugin) Small icon (optional): set either
  `com.kishormainali.push_notifications.default_icon` or
  `com.google.firebase.messaging.default_notification_icon` meta-data to a
  drawable.
- (this plugin) `flutter_local_notifications` requires core library desugaring in
  `android/app/build.gradle.kts`:

  ```kotlin
  android {
      compileOptions {
          isCoreLibraryDesugaringEnabled = true
      }
  }
  dependencies {
      coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
  }
  ```
- (this plugin) Add `google-services.json` and the Google services Gradle plugin as described
  by FlutterFire.

### Firebase Installation ID setup

The Firebase docs recommend the Firebase Installation ID (FID) over the FCM
registration token. Enable it natively:

- Android: inside `<application>` in `android/app/src/main/AndroidManifest.xml`:

  ```xml
  <meta-data
      android:name="firebase_messaging_installation_id_enabled"
      android:value="true" />
  ```

- iOS: in `ios/Runner/Info.plist`:

  ```xml
  <key>FirebaseMessagingInstallationIdEnabled</key>
  <true/>
  ```

The example app has both set. Subscribe to `onRegistered` before calling
`register()` (the plugin does this for you in `init`). `onRegistered` emits the
FID at startup and on routine sync on Android and Apple platforms when
auto-init is enabled (default), after every `register()` call (even if already
registered), and when a change of the FID is detected. `register()` is required
on web, and on Android/Apple when auto-init is disabled or after
`unregister()`; calling it re-emits the existing FID.

**Caution (Firebase docs):** do not use the FID APIs and the deprecated
registration-token APIs for registration management at the same time. How this
maps to this plugin (this plugin, not from the Firebase page):

- `autoRegister` (default `true`) calls `register()` and uses `onRegistered`
  (FID). `token` / `onTokenChanged` (and `getPlatformToken()` on Android) use
  the deprecated `getToken` / `onTokenRefresh`, which Firebase says will be
  removed in a future release. On iOS `getPlatformToken()` reads the APNs
  token instead.
- `onTokenChanged` is lazy: the plugin subscribes to the deprecated
  `onTokenRefresh` only while `onTokenChanged` has at least one listener, and
  cancels it when the last listener leaves. If Firebase is not initialized
  when the first listener attaches, the attach is retried the next time
  listeners go from zero to one (a second concurrent listener does not retry).
  `init` never subscribes to it, so
  apps that use only the FID API never touch the deprecated stream.
- New apps: enable the FID flags above and use the FID API (`onRegistered`,
  `installationId`).
- Apps that still rely on registration tokens only: pass `autoRegister: false`
  to `init` and do not call the FID API (`register`, `unregister`,
  `onRegistered`, `installationId`).

Note that `autoRegister: true` calls `register()` even if you have not enabled
the FID flags; enable them (or set `autoRegister: false`) so the app uses one
model consistently.

### Auto-init

FCM auto-init is on by default. To disable it:

- iOS: `Info.plist` key `FirebaseMessagingAutoInitEnabled` = `NO`.
- Android: in `AndroidManifest.xml`, set the meta-data
  `firebase_messaging_auto_init_enabled` to `false` and
  `firebase_analytics_collection_enabled` to `false`.

With auto-init disabled, subscribe to `onRegistered` first, then call
`register()`. `setAutoInitEnabled(true)` (from `firebase_messaging`)
re-enables auto-init at runtime and the setting persists across app restarts.

(this plugin) The default `autoRegister: true` does the subscribe-then-register
at `init` (it subscribes to the FID streams, then calls `register()`), so it
registers even when auto-init is disabled. To defer registration (for example
until the user consents), disable auto-init, set `autoRegister: false` and call
`register()` after consent.

### Example project capabilities

The example project needs the Push Notifications capability and Background
Modes (Background fetch and Remote notifications) added in Xcode; they live in
the Xcode project, not only in `Info.plist`.

### Sending a test message

In the Firebase console go to Messaging → Send test message and paste your
Firebase Installation ID (from `onRegistered` / `installationId`) or FCM
registration token (from `token`) into the field "Add a Firebase Installation
ID or FCM registration token".

### Background handler caveats

- The hook must be a top-level function (annotate with
  `@pragma('vm:entry-point')`); otherwise it is logged and not run.
- The background isolate cannot touch UI or app state.
- Duplicate suppression is by `messageId`, process-local, and recorded only after
  a successful show (a failed show can be retried by a redelivery). A message
  without a `messageId` gets a unique generated id each time, so it is never
  deduplicated.
- On iOS a data-only push needs `content-available: 1` and the OS throttles
  delivery.

## Server payload examples

FCM notification message with image and channel:

```json
{
  "message": {
    "token": "<device token>",
    "notification": { "title": "Hi", "body": "Hello", "image": "https://example.com/pic.jpg" },
    "data": { "type": "chat", "chat_id": "42" },
    "android": { "notification": { "channel_id": "chat" } },
    "apns": { "payload": { "aps": { "mutable-content": 1 } } }
  }
}
```

Data-only message:

```json
{
  "message": {
    "token": "<device token>",
    "data": {
      "type": "chat",
      "title": "Hi",
      "body": "Hello",
      "image": "https://example.com/pic.jpg",
      "channel_id": "chat"
    },
    "android": { "priority": "high" },
    "apns": {
      "headers": { "apns-priority": "5", "apns-push-type": "background" },
      "payload": { "aps": { "content-available": 1 } }
    }
  }
}
```

## Example app and manual testing

`example/` is a small app (no Firebase config files; add your own). It enables
the Firebase Installation ID flags on both platforms. See
[doc/MANUAL_TEST_CHECKLIST.md](doc/MANUAL_TEST_CHECKLIST.md).

## Developing the plugin

```sh
flutter test
cd example/android && ./gradlew :push_notifications:testDebugUnitTest
cd ios/push_notifications && PUSH_NOTIFICATIONS_CORE_ONLY=1 swift test
```

## Contributing and issues

Bug reports and pull requests are welcome at
[https://github.com/kishormainali/push_notifications/issues](https://github.com/kishormainali/push_notifications/issues).

## License

MIT. See [LICENSE](LICENSE).

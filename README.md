# push_notifications

Unified push notifications for Flutter on Android (Kotlin) and iOS (Swift,
Swift Package Manager only). It wraps `firebase_messaging` and
`flutter_local_notifications` so an app calls `init` once, supplies one
callback that decides which screen a tap opens, and gets consistent behavior in
the foreground, background and terminated states.

## Resolved dependency versions

- firebase_core ^5.1.0
- firebase_messaging ^17.0.1
- flutter_local_notifications ^22.3.3
- pigeon ^29.1.0 (dev)

## Install

```yaml
dependencies:
  push_notifications: ^0.1.0
  # For Firebase.initializeApp() in your main().
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

Other API: `markReady()`, `requestPermission()` (returns `PermissionStatus`),
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
  popped), or later taps stall.
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
to FCM tokens.

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

## Behavior by app state

"Notification message" is an FCM payload with a `notification` block;
"data-only" has only `data`.

| State | Message kind | What happens | Tap path |
|---|---|---|---|
| Foreground | notification | `onForegroundMessage` emits first. Android: FCM shows nothing, so the package shows a local notification (if `showForegroundNotifications`; needs a `title` or `body`). iOS: the OS presents it (alert/badge/sound, via `setForegroundNotificationPresentationOptions`); the package does not also show one. | Android: local notification tap (big picture: the native tap hook). iOS: `onMessageOpenedApp` |
| Foreground | data-only | `onForegroundMessage` emits first. If `showForegroundNotifications` and `data` has a `title` or `body` (`titleKey`/`bodyKey`), the package shows a notification: Android a local one, iOS a native one (the OS presents nothing for data-only, so nothing is duplicated). A repeated message id is shown once. | Local notification tap, or the native tap hook |
| Background | notification | The OS displays it. | `onMessageOpenedApp` |
| Background | data-only | The package's top-level handler runs in a background isolate: it initializes Firebase, shows a notification from `data` (`title`/`body` keys), then runs your optional `onBackgroundMessage`. | Native/local notification tap |
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
  `requestPermission()` asks for the badge permission.
- Android: best effort. There is no official badge API; the plugin sends
  vendor broadcasts and `isBadgeSupported()` reports whether the launcher is
  recognized. `getBadgeCount()` returns `null`. The vendor badge permissions in
  the plugin's manifest merge into your app.
- `BadgeConfig(autoIncrementOnPush, autoClearOnForeground)`, both off by
  default. Auto-increment applies to pushes handled by the background handler
  (data-only messages while the app is not in the foreground); foreground
  pushes never increment. Auto-clear resets the badge at `init` and whenever the
  app returns to the foreground.

## Images

| Case | Android | iOS |
|---|---|---|
| Notification message | Automatic from the FCM `image` field. | Needs a Notification Service Extension and `mutable-content: 1` (below). |
| Data-only | Downloaded natively and shown as a big picture from `data['image']` (key configurable via `imageKey`). | Downloaded natively and attached to the notification (subject to iOS background limits). |
| Foreground | Big picture. | Notification message: OS presents it; the image shows only if the extension ran. Data-only: downloaded natively and attached. |

Downloads are https-only by default (`imageHttpsOnly`), time out after 10 s and
are capped at 5 MB. On any failure the notification is shown without the image.
The Notification Service Extension is always https-only with the same limits.

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

### iOS

1. Add the Push Notifications capability and Background Modes → Remote
   notifications to the Runner target.
2. Upload an APNs key to your Firebase project.
3. In `AppDelegate.swift`, set the notification center delegate. This is
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

4. The plugin supports Swift Package Manager only (no CocoaPods). Enable it with
   `flutter config --enable-swift-package-manager`.
5. If you develop the plugin locally from source, the plugin folder must be
   named `push_notifications`, because SwiftPM keys on the folder name.

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

- Android 13+ needs the `POST_NOTIFICATIONS` permission (declared by the plugin;
  `requestPermission()` asks for it).
- Set the default channel for notification messages in your app manifest, to
  the same value as `defaultChannelId`:

  ```xml
  <meta-data
      android:name="com.google.firebase.messaging.default_notification_channel_id"
      android:value="default" />
  ```
- Small icon (optional): set either
  `com.kishormainali.push_notifications.default_icon` or
  `com.google.firebase.messaging.default_notification_icon` meta-data to a
  drawable.
- `flutter_local_notifications` requires core library desugaring in
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
- Add `google-services.json` and the Google services Gradle plugin as described
  by FlutterFire.

### Background handler caveats

- The hook must be a top-level function (annotate with
  `@pragma('vm:entry-point')`); otherwise it is logged and not run.
- The background isolate cannot touch UI or app state.
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

`example/` is a small app (no Firebase config files; add your own). See
[doc/MANUAL_TEST_CHECKLIST.md](doc/MANUAL_TEST_CHECKLIST.md).

## Developing the plugin

```sh
flutter test
cd example/android && ./gradlew :push_notifications:testDebugUnitTest
cd ios/push_notifications && PUSH_NOTIFICATIONS_CORE_ONLY=1 swift test
```

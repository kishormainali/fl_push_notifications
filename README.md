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
  firebase_core: ^5.1.0
  # Needed only for PushChannel(importance: Importance.high) and the like.
  flutter_local_notifications: ^22.3.3
```

Firebase must be configured natively in your app (`google-services.json`,
`GoogleService-Info.plist`). The background isolate calls
`Firebase.initializeApp()` without options, which relies on that.

## One-call setup

```dart
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show Importance;
import 'package:push_notifications/push_notifications.dart';

final navigatorKey = GlobalKey<NavigatorState>();

// Optional. Must be a top-level function.
@pragma('vm:entry-point')
Future<void> onBackgroundMessage(RemoteMessage message) async {}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await PushNotifications.instance.init(
    decisionMaker: (PushMessage m) async {
      // Open a screen based on the message.
      if (m.data['type'] == 'chat') {
        await navigatorKey.currentState?.pushNamed('/chat', arguments: m);
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
call's result; a failed `init` can be retried.

Other API: `markReady()`, `requestPermission()` (returns `PermissionStatus`),
`token`, `onTokenChanged`, `onForegroundMessage`, `onTap` (for analytics),
`subscribeToTopic` / `unsubscribeFromTopic`, `createChannel` / `deleteChannel`,
and the badge methods below.

### The decision maker

`DecisionMaker = FutureOr<void> Function(PushMessage)`. Every tap, from any
source and in any app state, goes through it. `PushMessage` has `id`, `title`,
`body`, `data`, `imageUrl`, `channelId`, `source` (`remote` or `local`),
`appState` (`foreground`, `background`, `terminated`) and `raw`.

- Taps that arrive before `markReady()` are queued and delivered in order when
  you call it. After that they are delivered immediately.
- An exception thrown by the decision maker is caught and logged; it does not
  block later taps.
- A repeated message id is delivered once.

## Behavior by app state

"Notification message" is an FCM payload with a `notification` block;
"data-only" has only `data`.

| State | Message kind | What happens | Tap path |
|---|---|---|---|
| Foreground | any | Android: FCM shows nothing, so the package shows a local notification (if `showForegroundNotifications`; needs a `title` or `body`). iOS: the OS presents it (alert/badge/sound); the package does not also show one. `onForegroundMessage` emits. | Local notification tap, or the native tap hook on iOS |
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
| Foreground | Big picture. | OS presents it; the image shows only if the extension ran. |

Downloads are https-only by default (`imageHttpsOnly`), time out after 10 s and
are capped at 5 MB. On any failure the notification is shown without the image.
The Notification Service Extension is always https-only with the same limits.

## Guarantees

- A tap is never silently dropped: with no decision maker it is logged and kept
  queued; a corrupt local payload still yields a minimal `PushMessage`.
- The same notification is not shown twice: iOS foreground uses OS presentation
  only, notification messages are never re-shown by the background handler, a
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

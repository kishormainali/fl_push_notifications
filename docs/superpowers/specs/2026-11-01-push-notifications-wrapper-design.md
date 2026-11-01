# Push Notifications Wrapper — Design

Date: 2026-11-01 · Status: draft, awaiting approval

## Intent

Every Flutter app we build repeats the same push setup: configure
`firebase_messaging` and `flutter_local_notifications`, register the background
handler, work out how the app was launched, and route a tap to a screen. This
package does that once, correctly, for all apps.

Success: an app adds the package, calls `init` once in `main`, supplies one
callback that decides which screen to open, and gets correct behavior in the
foreground, background and terminated states on Android and iOS.

## Goals

- One-call setup for FCM + local notifications (permissions, Android channel, iOS foreground presentation, token, background handler).
- One unified tap event regardless of source or app state.
- A user-supplied **decision maker** that chooses the screen from the message (usually `data['type']`).
- Correct cold-start handling: taps that arrive before the router exists are queued, then delivered.
- Follow current FlutterFire / flutter_local_notifications guidance (named `settings:` in `initialize`, `@pragma('vm:entry-point')` top-level handlers, `getInitialMessage` / `onMessageOpenedApp`, `getNotificationAppLaunchDetails`).
- Standalone, publishable Flutter **plugin** (`push_notifications`), usable by any app. It contains native Android (Kotlin) and iOS (Swift) code because `flutter_local_notifications` does not manage the app icon badge.
- Multiple notification channels (Android): the app registers a list of channels at `init`; each incoming message is routed to a channel, falling back to a default. See "Channels".
- App badge management: set, clear and (where the OS allows) read the launcher icon badge count, kept consistent with push arrival in all three app states.

## Non-goals (v1)

- Scheduling, video/audio attachments, notification grouping/styles beyond a sensible default. (Custom notification layouts are a later phase; v1 only has to leave room for them, see Native bridge.)
- A guaranteed numeric badge on every Android launcher (not technically possible; best effort, documented).
- A federated plugin split (app-facing/platform-interface/implementations). One plugin package with `android/` and `ios/` folders for v1.
- Sending pushes from the client.
- Web, Linux, Windows. (macOS may work but is untested.)
- Depending on any router (go_router, auto_route, Navigator). The app does navigation in its callback.

## Anti-goals

Each is handled by a specific mechanism and pinned by a test:

- **Silently dropping a tap.** With no decision maker set, log loudly and keep the event queued. A decision-maker exception is caught and logged and never blocks later taps. A tap whose payload cannot be parsed (corrupt local payload, unknown channel) is still delivered as a minimal `PushMessage` rather than discarded. Only an exact duplicate id is dropped, and that drop is logged at debug level.
- **Showing the same notification twice.** (a) iOS foreground: a message with a `notification` block uses OS presentation only, never a package-shown one as well; a data-only message (which the OS does not present) is shown natively by the package, once. (b) A message with a `notification` block is never re-displayed by the background handler. (c) Android foreground shows a local notification only (FCM shows none). (d) The same FCM `messageId` arriving twice is displayed once (LRU of displayed ids). (e) Local notification ids are derived from the message id, so a replay replaces the existing notification instead of stacking.
- **Delivering the same launch tap twice.** Delivered-id LRU in memory, plus the last launch-tap id persisted natively, so a stale `getInitialMessage()` after process restart or hot restart is not re-delivered. `init` is idempotent. `getInitialMessage` and the launch-details check run once per `init`.

## Public API

```dart
await PushNotifications.instance.init(
  decisionMaker: (PushMessage m) async { /* open a screen */ },
  channels: [
    PushChannel(id: 'default', name: 'General', importance: Importance.high),
    PushChannel(id: 'chat', name: 'Messages', importance: Importance.max),
  ],
  defaultChannelId: 'default',                 // used when a message names no/unknown channel
  channelKey: 'channel_id',                    // data key for data-only messages
  showForegroundNotifications: true,          // default
  onBackgroundMessage: myTopLevelHandler,     // optional, must be top-level
  autoRegister: true,                         // default; registers for the FID, see below
);
// after the router/navigator exists:
PushNotifications.instance.markReady();
```

- `PushMessage { id, title, body, data, source (remote|local), appState (foreground|background|terminated), raw }`.
- `Future<PermissionStatus> requestPermission()` (FCM `requestPermission`, plus `requestNotificationsPermission()` on Android 13+).
- FCM token (unchanged): `Future<String?> get token`, `Stream<String> onTokenChanged` (wraps `onTokenRefresh`). The underlying `getToken`/`onTokenRefresh` are deprecated upstream (firebase_messaging 17) but kept.
- Firebase Installation ID (FID), the direct-send target in newer firebase_messaging: `Future<void> register()`, `Future<void> unregister()`, `Stream<String> onRegistered`, `Stream<String> onUnregistered` (plugin-owned broadcast streams forwarding the port streams) and `String? installationId` (latest FID from `onRegistered`; cleared when `onUnregistered` emits that same FID; a different FID from `onRegistered` replaces it). `init(autoRegister: true)` subscribes to both streams first and then calls `register()` without awaiting it; a failing `register()` is logged and never fails `init`. With `autoRegister: false`, calling `register()` attaches the listeners lazily (once). The FID is only readable from the stream; there is no getter that fetches it. Dart-only: no native or Pigeon changes.
- `Stream<PushMessage> onForegroundMessage`, `Stream<PushMessage> onTap` for analytics.
- `subscribeToTopic` / `unsubscribeFromTopic`.
- Badge: `Future<bool> isBadgeSupported()`, `Future<void> setBadgeCount(int)`, `Future<void> clearBadge()`, `Future<int?> getBadgeCount()` (iOS only; `null` on Android, where launchers do not expose it). Config on `init`: `badge: BadgeConfig(autoIncrementOnPush: false, autoClearOnForeground: false)`.

## Channels

- `PushChannel { id, name, description, importance, playSound, enableVibration, showBadge, groupId? }`. All channels given to `init` are created idempotently on Android (natively through Pigeon, so they also exist before a background isolate shows anything). iOS has no channels; the channel id is carried on `PushMessage` and used as the notification `threadIdentifier` only. No other iOS behavior.
- Routing, in order: FCM `notification.android.channelId` (notification messages are displayed by the OS, which needs the channel to exist) → `data[channelKey]` (data-only and foreground) → `defaultChannelId`. An unknown id logs a warning and falls back to the default; the message is never dropped.
- Runtime API: `createChannel(PushChannel)`, `deleteChannel(String id)`. The default channel cannot be deleted.
- `PushMessage.channelId` is set on every message and tap.
- Android fixes importance/sound at channel creation. Changing them later requires a new channel id; this is documented, not worked around.

## Native bridge (Pigeon)

All Dart ↔ native calls are defined in a Pigeon file (`pigeons/messages.dart`) that generates Dart, Kotlin and Swift. Generated code is committed. Reasons: type safety, and the schema is the extension point for the later custom-notifications phase.

- Pigeon host APIs (Dart → native): badge methods, `showNotification(NotificationContent)`, image download/attach helper, `getNativeLaunchPayload` if needed.
- `NotificationContent` is a Pigeon data class (id, title, body, channelId, data, `imageUrl`, `imageStyle`, `badge`, plus a reserved `Map<String?, Object?> extras`). A future custom notification type adds fields or a new class to this schema rather than changing the Dart public API.
- Native side is structured around a `NotificationBuilder` per platform (Kotlin and Swift) that turns `NotificationContent` into a platform notification. Later custom layouts replace or extend that builder. In v1 the builder handles title/body/image/badge only.
- Pigeon APIs must be usable from the background isolate (registered for background engines too).

## Image notifications

`PushMessage` gains `imageUrl` (read from FCM `notification.image` / `notification.android.imageUrl` / `notification.apple.imageUrl`, or `data['image']` for data-only; key configurable).

| Case | Android | iOS |
|---|---|---|
| Background/terminated, **notification message** | FCM/system downloads and shows the image automatically (BigPicture) when `image` is set in the payload. Nothing for the package to do. | Needs a **Notification Service Extension** in the host app (`mutable-content: 1`). The package ships a ready-made `PushNotificationService` Swift class that downloads `image` and attaches it; the app adds the extension target and subclasses/copies it. README has the steps. |
| Background/terminated, **data-only** | Background isolate shows a local notification with `BigPictureStyle`, image downloaded natively in the Pigeon handler (with timeout). | Data-only pushes cannot run the extension; the plugin downloads the image and attaches it as a `UNNotificationAttachment` to a local notification. Subject to iOS background execution limits; falls back to text-only. |
| Foreground | Package shows local notification with `BigPictureStyle`. | Notification message: OS presents the banner; the image is present only if the extension ran (requires `mutable-content`), otherwise text only. Data-only: the plugin downloads the image and attaches it to the notification it posts. |

Rules: download with a short timeout (≈10 s) and size cap, https only by default (configurable), cache in the temp dir, and **always fall back to a text-only notification** on any failure. Never block a tap or the notification on the image.

## Badge behavior

- **iOS (native, full support):** `UNUserNotificationCenter.setBadgeCount` (iOS 16+), falling back to `UIApplication.applicationIconBadgeNumber` below that. Requires the badge permission, which `requestPermission()` already requests. A push carrying an APNs `badge` value is applied by the OS with no app code; the plugin covers the cases the OS does not: data-only/silent pushes handled in the background isolate, and manual set/clear from Dart. The count can be read back.
- **Android (best effort):** Android has no official badge-count API. Launchers using notification dots derive the dot from active notifications (the package sets `setNumber` on the local notifications it shows). For launchers with numeric badges, the native side sends the vendor broadcast/provider calls (ShortcutBadger-style, covering Samsung, Xiaomi, Huawei, Sony, Oppo/Vivo, etc.). `isBadgeSupported()` reports whether the current launcher is recognized. Reading the count back is not possible.
- **Auto options (off by default):** `autoIncrementOnPush` increments a plugin-persisted counter whenever a push arrives while the app is not in the foreground (including data-only messages in the background isolate), and `autoClearOnForeground` resets it when the app comes to the foreground. The counter is stored natively (UserDefaults / SharedPreferences) so the background isolate and the main isolate agree.
- The badge calls must work from the background isolate, so they go through a native channel registered for background engines too.
- `show(...)`: display a local notification manually (used internally for foreground/data-only).

## Behavior by app state

The core requirement. "Notification message" = FCM payload with a `notification`
block; "data-only" = payload with only `data`.

| State | Message kind | What happens | Tap path → decision maker |
|---|---|---|---|
| **Foreground** | any | `onMessage` fires; `onForegroundMessage` is emitted first (before any display, which may wait on an image download). Android: FCM shows nothing, so the package shows a local notification (if `showForegroundNotifications`). iOS, notification message: `setForegroundNotificationPresentationOptions(alert/badge/sound)` so the OS shows it; the package does **not** also show one. iOS, data-only: the OS presents nothing, so the package shows a native notification from `data` title/body (if `showForegroundNotifications`; deduped by `messageId`). | Android: local plugin `onDidReceiveNotificationResponse` (a big-picture notification posted natively by the plugin: the plugin's native tap hook, `onNewIntent` → `onNativeTap`). iOS, notification message: `onMessageOpenedApp`. iOS, data-only: the plugin's native tap hook (`didReceive` → `onNativeTap`). Taps are de-duplicated by message id. |
| **Background** (process alive) | notification | OS displays it. | `onMessageOpenedApp`. |
| **Background** | data-only | Package's top-level background handler runs in its own isolate: `Firebase.initializeApp()`, init the local plugin, show a local notification from `data` (title/body keys, configurable), then call the app's optional `onBackgroundMessage`. | Local `onDidReceiveNotificationResponse`. |
| **Terminated** | notification | OS displays it. | On next launch, `getInitialMessage()` (consumed once). Queued until `markReady()`. |
| **Terminated** | data-only | Same background-handler path as above (Android high priority; iOS needs `content-available`, and delivery is throttled by the OS — documented, not fixable). | Local plugin `getNotificationAppLaunchDetails()` → payload. Queued until `markReady()`. |
| Any | local action button | `onDidReceiveBackgroundNotificationResponse` (top-level, entry-point) runs in an isolate. v1 only forwards simple taps; action buttons are out of scope. | — |

Rules that make this correct:

1. **Single entry for taps.** All of the above feed one internal `_handleTap(PushMessage)`.
2. **Cold-start queue.** Before `markReady()`, taps are appended to a queue; `markReady()` flushes in order. After `markReady()`, taps are delivered immediately.
3. **De-duplication.** Keep a small LRU of delivered message ids (FCM `messageId`, or a generated id embedded in the local payload). A tap whose id was already delivered is dropped (logged at debug level).
4. **Launch check once.** `init` calls `getInitialMessage()` and `getNotificationAppLaunchDetails()` exactly once.
5. **Local payload.** The local notification payload is the JSON-encoded `data` plus `id`, so a local tap rebuilds a full `PushMessage`.
6. **Background isolate rule.** Background code cannot touch app state or UI; the package keeps it to initialize + display + the user's top-level hook.
7. **Tap `appState`.** Launch taps (`getInitialMessage`, the local plugin's launch details, the head of the native `consumeLaunchPayload`) are `terminated`. Live taps are labelled by the app state at the moment the tap was received, not when Dart gets it (platform event ordering can deliver the lifecycle change first):
   - Native taps (notifications posted by the plugin) carry `appWasActive`, captured natively at the receive point: iOS, in `userNotificationCenter(_:didReceive:)`, a sticky flag set by `didBecomeActiveNotification` and cleared by `didEnterBackgroundNotification` (resigning active is ignored; seeded from `applicationState == .active` at registration), because `applicationState` alone is `.inactive` both for a tap from Notification Center pulled over a foreground app and for a tap bringing the app back from the background; Android, in `onNewIntent`, whether the host activity has been resumed since it was last started (Android may pause a resumed activity around `onNewIntent`, so the current lifecycle state cannot tell a foreground tap from a background one; a stop in between can, whether or not the pause happens; a late attach is seeded from the activity's current state). `true` → `foreground`, `false` → `background`. Android sends the tap to Dart inside `onNewIntent` (undispatched coroutine on `Dispatchers.Main.immediate`); iOS keeps an async hop, which is harmless because the flag was captured before it.
   - Taps from Dart plugins (flutter_local_notifications responses, `onMessageOpenedApp`) are `foreground` if the last lifecycle state other than `inactive` (seeded at `init`, then every change) was `resumed`, otherwise `background`. `inactive` is skipped because it is transitional on both sides of a tap: a resumed app goes inactive while the shade is open / the tap is delivered, and a backgrounded app passes through inactive on its way back.
   - Cold-start taps that are not the launch head (a second tap queued natively before Dart was ready, or a live delivery that failed and was re-queued) are delivered live with the flag captured when they were received, so they are `foreground`/`background`, not `terminated`. They are delivered after the launch taps: Android posts them to the main looper so they are sent after the `consumeLaunchPayload` reply, and Dart holds any native tap that arrives before `init` has delivered the launch taps and releases it after them.
   - `appState` is informational: it does not affect routing, de-duplication or display.
8. **Prompt decision maker.** Taps are delivered one at a time (each awaits the decision maker), so the decision maker must return promptly; it should start navigation without awaiting the pushed route.

## Platform setup the package cannot do (README)

- iOS images: add a Notification Service Extension target using the provided `PushNotificationService` class, and send `mutable-content: 1` from the server.
- iOS: Push Notifications capability, Background Modes → Remote notifications, APNs key uploaded to Firebase, `Info.plist` as needed.
- Android: `POST_NOTIFICATIONS` permission (13+), default channel meta-data for FCM notification messages (`com.google.firebase.messaging.default_notification_channel_id`) matching `defaultChannelId`, small icon.
- Firebase must be configured natively (`google-services.json` / `GoogleService-Info.plist`); the background isolate calls `Firebase.initializeApp()` without options, which relies on that.

## Constraints

- Dart/Flutter: latest stable. Pin the latest `firebase_core`, `firebase_messaging`, `flutter_local_notifications` from pub.dev at scaffold time.
- Platforms: Android, iOS.
- iOS packaging: Swift Package Manager only (no CocoaPods podspec). The Notification Service Extension class ships as a separate Flutter-free SwiftPM product so an extension target can depend on it.
- The app must call `Firebase.initializeApp()` before `PushNotifications.init`.

## Testing

- Unit tests (fake wrappers around the two plugins): queue-before-ready, flush order, de-duplication, payload round-trip, decision maker error handling, foreground display rules per platform.
- Image: download success, timeout, non-https, oversize, and fallback to text-only; manual checklist for each state × notification/data-only × image.
- Native: Kotlin unit tests for the badge channel handler and Swift/XCTest for the iOS handler where practical; Dart tests mock the channel.
- An `example/` app plus a manual test checklist for the three states × notification/data-only (cannot be automated without devices).

## Decisions made by me (not yet confirmed by you)

- Plugin implemented with **Pigeon** (your decision), generating Dart/Kotlin/Swift.
- Images: iOS rich push for remote notification messages requires the host app to add a Notification Service Extension; the plugin cannot create Xcode targets. I ship the Swift class and instructions instead.
- Image URL keys: `image` in `data` for data-only messages (configurable).
- Image download is done natively (not in Dart) so it works in the background isolate.
- Android badge uses vendor broadcasts written in-house rather than a dependency on an unmaintained badge library. If that proves too fragile, fall back to depending on a maintained package. Builder's call after a spike.
- Auto-increment/auto-clear are opt-in, off by default.
- Channels are Android-only; unknown channel falls back to default; default channel is undeletable; default `channelKey` is `channel_id`.
- Last launch-tap id is persisted natively (SharedPreferences / UserDefaults) through two Pigeon methods.
- Package name `push_notifications` (confirmed by you). Checked pub.dev on 2026-11-01: `push_notifications` and `fl_notifications` are not taken; `push_notification` and `flutter_push_notifications` are.
- `markReady()` as the cold-start gate.
- iOS foreground uses OS presentation options rather than a local notification for notification messages; foreground data-only messages (not presented by the OS) are shown natively by the plugin.
- Data-only messages are displayed via a local notification using `title`/`body` keys in `data` (configurable).
- No action buttons or scheduling in v1.
- Errors thrown by the decision maker are caught, logged, and do not break later taps.

## Left to the builder

Internal file layout, class names beyond the public API, logging approach, and example app UI.

# Manual test checklist

Run on a real Android device and a real iOS device with the example app, after
adding your own Firebase config (`google-services.json`,
`GoogleService-Info.plist`), an APNs key, and (for iOS images) a Notification
Service Extension. Items marked **[DEFERRED RISK]** could not be verified without
devices and need extra attention.

Tap result for every case: the detail page opens with the right title, body,
data, state and source, and "Recent taps" lists it.

## 1. State x message kind x image (repeat on Android and iOS)

For each row: send the push, confirm one notification is shown, tap it, confirm
the decision maker runs once with the expected `appState`. Foreground rows: tap
the banner, and also pull down the shade / Notification Center and tap it there
(the app turns inactive around the tap; it must still be `foreground`).
Background rows: tap from the shade / lock screen after pressing Home (the app
resumes around the tap; it must still be `background`).

| # | State | Kind | Image | Expected display | Expected `appState` |
|---|---|---|---|---|---|
| 1 | Foreground | notification | no | Android: local notification. iOS: OS banner. | foreground |
| 2 | Foreground | notification | yes | Android: big picture. iOS: banner, image only if the extension ran | foreground |
| 3 | Foreground | data-only | no | Android: local notification. iOS: one native notification from `data` title/body (shown by the package; the OS presents nothing) | foreground |
| 4 | Foreground | data-only | yes | Android: big picture. iOS: one native notification with the image attached | foreground |
| 5 | Background | notification | no | OS notification | background |
| 6 | Background | notification | yes | Android: image automatic. iOS: needs extension + `mutable-content` | background |
| 7 | Background | data-only | no | Notification from `data` title/body | background |
| 8 | Background | data-only | yes | Big picture (Android) / attachment (iOS) | background |
| 9 | Terminated | notification | no | OS notification | terminated |
| 10 | Terminated | notification | yes | As row 6 | terminated |
| 11 | Terminated | data-only | no | Notification from `data` (iOS needs `content-available`, may be throttled) | terminated |
| 12 | Terminated | data-only | yes | As row 8 | terminated |

Image failure cases (any row with an image): http URL (not shown, text-only),
404 URL, slower than 10 s, larger than 5 MB. Each must still show the text.

## 2. Tap routing and duplicates

- [ ] Tap goes through the decision maker (`data.type = chat` opens the chat
      page, anything else the detail page).
- [ ] Cold start: tap a notification while the app is terminated. The tap is
      queued until `markReady()` and the page opens after the first frame.
- [ ] No duplicate display: one notification per message in every row above
      (foreground Android must not show two; iOS foreground must not show two).
- [ ] No duplicate launch tap: after a launch tap, kill and restart the app from
      the launcher. The decision maker must not fire again.
- [ ] Sending the same `messageId` twice shows one notification.
- [ ] A repeated id replaces the existing notification instead of stacking.

## 3. Channels (Android)

- [ ] `android.notification.channel_id = chat` uses the "Messages" channel.
- [ ] Data-only `channel_id = chat` uses the "Messages" channel.
- [ ] Unknown channel id falls back to `default` (warning in logs, not dropped).
- [ ] Importance/sound set at first creation do not change after editing the
      channel definition and relaunching (new id needed).
- [ ] `deleteChannel('default')` throws.

## 4. Badge

- [ ] "Set badge" sets the count; "Clear badge" clears it.
- [ ] iOS: `getBadgeCount` reads back; Android: returns `null`.
- [ ] `autoIncrementOnPush`: data-only pushes in background/terminated increment;
      foreground pushes do not.
- [ ] `autoClearOnForeground`: badge clears at launch and on every resume.
- [ ] Both options off (default): neither happens.

## 5. Installation ID (FID)

- [ ] After `init` (autoRegister on), `onRegistered` emits a FID once and the
      example shows it next to the token.
- [ ] "Unregister" then `onUnregistered` emits that FID and the example clears
      it; "Register" brings a FID back.
- [ ] Token: "Show token" and `onTokenChanged` behave as before.
- [ ] "Platform token": Android shows the FCM token (present); iOS real device
      shows the APNs token (present); iOS simulator or APNs not ready shows
      null after about 3 s without an error.
- DEFERRED RISK: `getPlatformToken` APNs timing and the simulator behavior are
  device-only; unit tests use fakes.
- DEFERRED RISK: needs a real device with Firebase configured, not covered by
  unit tests: whether the native SDK re-emits `onRegistered` on a repeated
  `register()`, a FID rotating after reinstall/clear data, and sending to the FID
  from a backend.

## 6. Other

- [ ] Token: "Show token" returns a value; token refresh emits on
      `onTokenChanged` (e.g. after reinstall/clearing data).
- [ ] `init` called twice (hot restart, or call it a second time): no duplicate
      listeners, no duplicate taps.
- [ ] Decision maker that throws: error is logged, the next tap still works.
- [ ] Topic: subscribe to "news", send to the topic, receive it.
- [ ] Permission: denied and granted flows; Android 13+ shows the system prompt.

## 7. Device-only risks to verify  **[DEFERRED RISK]**

- [ ] **[DEFERRED RISK]** iOS cold-start tap arriving before the plugin
      registers: tap with the app killed and confirm the tap is not lost.
- [ ] **[DEFERRED RISK]** Android vendor badges on Samsung, Xiaomi, Huawei and
      Oppo launchers (`isBadgeSupported` and the actual count).
- [ ] **[DEFERRED RISK]** Android notification tap through `onNewIntent` (app in
      background) and through cold start.
- [ ] **[DEFERRED RISK]** Tap `appState` labels (inferred from platform event
      ordering, not device-verified): Android foreground tap from the shade
      (local and big-picture) is `foreground`; Android background tap on a
      data-only notification is `background`; iOS foreground tap on a
      notification message (`onMessageOpenedApp`) and on a data-only one
      (native) is `foreground`, both as a banner tap and from Notification
      Center pulled down over the running app (the app is `.inactive` then);
      background taps `background`.
- [ ] **[DEFERRED RISK]** Cold start with two taps (tap one, then a second
      before the first frame): the first is `terminated` and arrives first,
      the second keeps the state it was received in (usually `background`)
      and arrives after it.
- [ ] **[DEFERRED RISK]** Android big-picture rendering (collapsed and expanded).
- [ ] **[DEFERRED RISK]** Channel group (`groupId`) appears in system settings.
- [ ] **[DEFERRED RISK]** Repeated id replaces the existing notification on both
      platforms.
- [ ] **[DEFERRED RISK]** iOS data-only background delivery with
      `content-available` and image attachment (OS throttling).
- [ ] **[DEFERRED RISK]** iOS Notification Service Extension attaches the image
      for a notification message with `mutable-content: 1`.

# Notification coverage matrix

What the plugin does for each FCM payload shape. "Unit" means covered by the
Dart/Swift/Kotlin unit tests; "Manual" means it needs a device
(see `MANUAL_TEST_CHECKLIST.md`).

| Payload | State | Android | iOS | Verified |
| --- | --- | --- | --- | --- |
| `notification` block (title/body) | background / terminated | Shown by the FCM SDK; tap reaches Dart | Shown by the OS; tap reaches Dart | Unit (tap path), Manual (display) |
| `notification` block | foreground | Shown by the plugin (local/native) | Shown by the OS (`setForegroundPresentation`) | Unit |
| `notification` + `*_loc_key` (+ args) | background / terminated | FCM resolves from app string resources | OS resolves from `Localizable.strings` | Manual |
| `notification` + `*_loc_key` (+ args) | foreground | Resolved natively by the plugin (`resolveLocalizedString`); before, nothing was shown | OS presents it; the stream and tap messages get the resolved text | Unit (Dart), Swift unit (missing key) |
| data-only (`title`/`body` keys) | any | Plugin background handler / foreground handler shows it | Same, native | Unit |
| data-only without title and body | any | Not shown (logged); hook still runs | Same | Unit |
| data-only + `channelKey` | any | Shown on the named channel, default if unknown | n/a (no channels) | Unit |
| image (`android.imageUrl`, `apple.imageUrl`, data `imageKey`) | any | BigPicture; text-only on download failure | Service Extension attaches it; simulators don't render images | Unit, Manual (iOS display) |
| silent (`content-available`, no alert) | background | Handler runs, nothing shown | Handler runs on a fetch wake-up, nothing shown | Unit |
| tap that launches the app | terminated | `getInitialMessage` / launch payload | same, plus held `onMessageOpenedApp` (see README, UIScene) | Unit, simulator |
| same `messageId` delivered twice | any | Shown once | Shown once | Unit |

## Known gaps

* Android `notification` fields beyond title, body, image and channel (sound,
  color, tag, sticky, ticker) are not applied when the plugin itself shows the
  foreground notification.
* iOS subtitle and interruption level: the OS applies them to `notification`
  block messages. Data-only messages have no FCM field for them, so the
  plugin-shown notification has none.
* Tap messages for localized notifications are resolved like foreground ones
  (title and body from the loc keys); a key the app has no string for stays
  `null`.
* Payloads without a `gcm.message_id` are invisible to firebase_messaging taps
  on iOS.

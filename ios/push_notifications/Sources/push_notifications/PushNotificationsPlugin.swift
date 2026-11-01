import Flutter
import UIKit
import PushNotificationsCore
import UserNotifications

public class PushNotificationsPlugin: NSObject, FlutterPlugin {
  /// The single application delegate answering notification taps, held
  /// strongly here (the app delegate's registry may only hold it weakly) so it
  /// outlives whichever engine registered first (possibly a headless one).
  private static let tapHandler = PushNotificationsPlugin()
  private static var tapHandlerRegistered = false
  /// Foreground flag captured for native taps; observers are added once.
  private static var appActive: AppActiveTracker?
  private static var appStateObservers: [NSObjectProtocol] = []

  public static func register(with registrar: FlutterPluginRegistrar) {
    // Registered for every engine, including background/headless engines.
    let defaults = PushStorage.sharedDefaults()
    let flutterApi = PushFlutterApi(binaryMessenger: registrar.messenger())
    let api = PushHostApiImpl(
      badge: BadgeHandler(defaults: defaults, applier: SystemBadgeApplier()),
      storage: PushStorage(defaults: defaults),
      taps: TapRouter.shared,
      // Live taps go to the engine whose Dart ran `init` (it is the one that
      // calls consumeLaunchPayload), not to the first engine registered.
      deliverTap: Self.deliverer(flutterApi))
    PushHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: api)
    registrar.publish(PushNotificationsPlugin())

    if !tapHandlerRegistered {
      tapHandlerRegistered = true
      // FlutterAppDelegate forwards UNUserNotificationCenterDelegate calls to
      // every registered application delegate (when it is the center's
      // delegate), each with the same completion handler.
      registrar.addApplicationDelegate(tapHandler)
      observeAppState()
    }
  }

  /// Registration runs on the main thread, as do these notifications.
  private static func observeAppState() {
    let tracker = AppActiveTracker(active: UIApplication.shared.applicationState == .active)
    appActive = tracker
    let center = NotificationCenter.default
    appStateObservers = [
      center.addObserver(
        forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { _ in tracker.didBecomeActive() },
      center.addObserver(
        forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
      ) { _ in tracker.didEnterBackground() },
    ]
  }

  private static func deliverer(_ flutterApi: PushFlutterApi) -> TapRouter.Deliver {
    { tap, done in
      // This hop may let Dart see `resumed` before the tap; appState comes
      // from `tap.appWasActive`, captured in didReceive, not from Dart.
      Task { @MainActor in
        do {
          try await flutterApi.onNativeTap(payload: tap.payload, appWasActive: tap.appWasActive)
          done(true)
        } catch {
          NSLog("push_notifications: onNativeTap not delivered, keeping it: \(error)")
          done(false)
        }
      }
    }
  }

  // MARK: - UNUserNotificationCenterDelegate (forwarded by FlutterAppDelegate)
  //
  // Only notifications posted by this plugin (userInfo `push_payload`) are
  // answered; for any other one the completion handler is left to the plugin
  // that owns it (firebase_messaging, flutter_local_notifications).

  public func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    guard NotificationBuilder.isOurs(notification.request.content.userInfo) else { return }
    completionHandler([.banner, .list, .sound, .badge])
  }

  public func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    guard let payload = userInfo[NotificationBuilder.payloadKey] as? String else { return }
    if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
      // Captured synchronously at the receive point (main thread). Not
      // `applicationState == .active`: a foreground app is `.inactive` while
      // Notification Center is pulled down, like an app being brought back
      // from the background. The tracker stays set until the app actually
      // enters the background.
      let active =
        Self.appActive?.isActive ?? (UIApplication.shared.applicationState == .active)
      TapRouter.shared.handleTap(NativeTap(payload: payload, appWasActive: active))
    }
    completionHandler()
  }
}

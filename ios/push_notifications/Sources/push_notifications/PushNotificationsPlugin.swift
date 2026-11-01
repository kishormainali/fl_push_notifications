import Flutter
import PushNotificationsCore
import UserNotifications

public class PushNotificationsPlugin: NSObject, FlutterPlugin {
  /// Taps are handled by the first engine's instance only (the app's main
  /// engine), so background engines neither deliver nor answer them twice.
  private static var tapHandlerRegistered = false

  private var flutterApi: PushFlutterApi?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = PushNotificationsPlugin()
    // Registered for every engine, including background engines.
    let defaults = PushStorage.sharedDefaults()
    let api = PushHostApiImpl(
      badge: BadgeHandler(defaults: defaults, applier: SystemBadgeApplier()),
      storage: PushStorage(defaults: defaults),
      taps: TapRouter.shared)
    PushHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: api)
    let flutterApi = PushFlutterApi(binaryMessenger: registrar.messenger())
    instance.flutterApi = flutterApi
    registrar.publish(instance)

    if !tapHandlerRegistered {
      tapHandlerRegistered = true
      // FlutterAppDelegate forwards UNUserNotificationCenterDelegate calls to
      // every registered application delegate (when it is the center's
      // delegate), each with the same completion handler.
      registrar.addApplicationDelegate(instance)
      TapRouter.shared.deliver = { payload, done in
        Task { @MainActor in
          do {
            try await flutterApi.onNativeTap(payload: payload)
            done(true)
          } catch {
            NSLog("push_notifications: onNativeTap not delivered, keeping it: \(error)")
            done(false)
          }
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
      TapRouter.shared.handleTap(payload)
    }
    completionHandler()
  }
}

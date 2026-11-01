import Flutter

public class PushNotificationsPlugin: NSObject, FlutterPlugin {
  private var flutterApi: PushFlutterApi?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = PushNotificationsPlugin()
    // Registered for every engine, including background engines.
    let defaults = PushStorage.sharedDefaults()
    let api = PushHostApiImpl(
      badge: BadgeHandler(defaults: defaults, applier: SystemBadgeApplier()),
      storage: PushStorage(defaults: defaults))
    PushHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: api)
    instance.flutterApi = PushFlutterApi(binaryMessenger: registrar.messenger())
    registrar.publish(instance)
  }
}

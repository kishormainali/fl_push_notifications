import Flutter

public class PushNotificationsPlugin: NSObject, FlutterPlugin {
  private var flutterApi: PushFlutterApi?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = PushNotificationsPlugin()
    PushHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: PushHostApiImpl())
    instance.flutterApi = PushFlutterApi(binaryMessenger: registrar.messenger())
    registrar.publish(instance)
  }
}

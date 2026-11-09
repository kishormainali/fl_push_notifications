import Foundation

/// Persists the background config and the last launch-tap ids in the
/// `push_notifications` UserDefaults suite.
final class PushStorage {
  static let suiteName = "push_notifications"
  static let lastLaunchIdKey = "push_notifications.lastLaunchId"
  private static let cfg = "push_notifications.bgConfig."

  private let defaults: UserDefaults

  init(defaults: UserDefaults) { self.defaults = defaults }

  /// The shared suite (falls back to standard defaults if it cannot be opened).
  static func sharedDefaults() -> UserDefaults {
    UserDefaults(suiteName: suiteName) ?? .standard
  }

  func getLastLaunchId() -> String? { defaults.string(forKey: Self.lastLaunchIdKey) }

  func setLastLaunchId(_ id: String) { defaults.set(id, forKey: Self.lastLaunchIdKey) }

  func saveBackgroundConfig(_ c: BackgroundConfigMsg) {
    let k = Self.cfg
    defaults.set(c.defaultChannelId, forKey: k + "defaultChannelId")
    defaults.set(c.channelKey, forKey: k + "channelKey")
    defaults.set(c.imageKey, forKey: k + "imageKey")
    defaults.set(c.titleKey, forKey: k + "titleKey")
    defaults.set(c.bodyKey, forKey: k + "bodyKey")
    defaults.set(c.imageHttpsOnly, forKey: k + "imageHttpsOnly")
    defaults.set(c.autoIncrementOnPush, forKey: k + "autoIncrementOnPush")
    defaults.set(c.autoClearOnForeground, forKey: k + "autoClearOnForeground")
    if let h = c.hookHandle {
      defaults.set(NSNumber(value: h), forKey: k + "hookHandle")
    } else {
      defaults.removeObject(forKey: k + "hookHandle")
    }
  }

  func loadBackgroundConfig() -> BackgroundConfigMsg? {
    let k = Self.cfg
    func s(_ n: String) -> String? { defaults.string(forKey: k + n) }
    func b(_ n: String) -> Bool? { defaults.object(forKey: k + n) as? Bool }
    guard let defaultChannelId = s("defaultChannelId"), let channelKey = s("channelKey"),
      let imageKey = s("imageKey"), let titleKey = s("titleKey"), let bodyKey = s("bodyKey"),
      let imageHttpsOnly = b("imageHttpsOnly"), let autoIncrement = b("autoIncrementOnPush"),
      let autoClear = b("autoClearOnForeground")
    else { return nil }
    let hook = (defaults.object(forKey: k + "hookHandle") as? NSNumber)?.int64Value
    return BackgroundConfigMsg(
      defaultChannelId: defaultChannelId, channelKey: channelKey, imageKey: imageKey,
      titleKey: titleKey, bodyKey: bodyKey, imageHttpsOnly: imageHttpsOnly,
      autoIncrementOnPush: autoIncrement, autoClearOnForeground: autoClear, hookHandle: hook)
  }
}

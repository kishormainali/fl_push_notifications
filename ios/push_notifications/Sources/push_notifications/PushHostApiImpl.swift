import Flutter

/// Native implementation of `PushHostApi`. Badge, background config and launch
/// id are implemented; channels, display, image download and launch payload
/// are stubs until their owning tasks replace them.
final class PushHostApiImpl: PushHostApi {
  private let badge: BadgeHandler
  private let storage: PushStorage

  init(badge: BadgeHandler, storage: PushStorage) {
    self.badge = badge
    self.storage = storage
  }

  private func notImplemented() -> PigeonError {
    PigeonError(code: "not-implemented", message: "Not implemented yet", details: nil)
  }

  func isBadgeSupported() throws -> Bool { badge.isBadgeSupported() }
  func setBadgeCount(count: Int64) throws { badge.setBadgeCount(count) }
  func getBadgeCount() throws -> Int64? { badge.getBadgeCount() }
  func clearBadge() throws { badge.clearBadge() }
  func incrementBadge() throws -> Int64 { badge.incrementBadge() }
  func createChannel(c: ChannelConfig) throws { throw notImplemented() }
  func deleteChannel(id: String) throws { throw notImplemented() }
  func getLastLaunchId() throws -> String? { storage.getLastLaunchId() }
  func setLastLaunchId(id: String) throws { storage.setLastLaunchId(id) }
  func saveBackgroundConfig(config: BackgroundConfigMsg) throws {
    storage.saveBackgroundConfig(config)
  }
  func loadBackgroundConfig() throws -> BackgroundConfigMsg? { storage.loadBackgroundConfig() }
  func consumeLaunchPayload() throws -> String? { throw notImplemented() }
  func showNotification(content: NotificationContent) async throws { throw notImplemented() }
  func downloadImage(url: String, timeoutMs: Int64, maxBytes: Int64, httpsOnly: Bool) async throws -> String? {
    throw notImplemented()
  }
}

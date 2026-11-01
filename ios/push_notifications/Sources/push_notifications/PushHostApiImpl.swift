import Flutter

/// Native implementation of `PushHostApi`. Every method is a stub until the
/// owning task (badge, channels, notification display, config, launch payload)
/// replaces it.
final class PushHostApiImpl: PushHostApi {
  private func notImplemented() -> PigeonError {
    PigeonError(code: "not-implemented", message: "Not implemented yet", details: nil)
  }

  func isBadgeSupported() throws -> Bool { throw notImplemented() }
  func setBadgeCount(count: Int64) throws { throw notImplemented() }
  func getBadgeCount() throws -> Int64? { throw notImplemented() }
  func clearBadge() throws { throw notImplemented() }
  func incrementBadge() throws -> Int64 { throw notImplemented() }
  func createChannel(c: ChannelConfig) throws { throw notImplemented() }
  func deleteChannel(id: String) throws { throw notImplemented() }
  func getLastLaunchId() throws -> String? { throw notImplemented() }
  func setLastLaunchId(id: String) throws { throw notImplemented() }
  func saveBackgroundConfig(config: BackgroundConfigMsg) throws { throw notImplemented() }
  func loadBackgroundConfig() throws -> BackgroundConfigMsg? { throw notImplemented() }
  func consumeLaunchPayload() throws -> String? { throw notImplemented() }
  func showNotification(content: NotificationContent) async throws { throw notImplemented() }
  func downloadImage(url: String, timeoutMs: Int64, maxBytes: Int64, httpsOnly: Bool) async throws -> String? {
    throw notImplemented()
  }
}

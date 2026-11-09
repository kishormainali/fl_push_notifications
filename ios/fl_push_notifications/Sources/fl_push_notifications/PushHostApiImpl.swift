import Flutter
import PushNotificationsCore
import UserNotifications

/// Native implementation of `PushHostApi` on iOS.
final class PushHostApiImpl: PushHostApi {
  static let imageTimeout: TimeInterval = 10
  static let imageMaxBytes: Int64 = 5 * 1024 * 1024

  private let badge: BadgeHandler
  private let storage: PushStorage
  private let taps: TapRouter
  private let deliverTap: TapRouter.Deliver
  private let downloader: ImageDownloading

  init(
    badge: BadgeHandler, storage: PushStorage, taps: TapRouter,
    deliverTap: @escaping TapRouter.Deliver,
    downloader: ImageDownloading = ImageDownloader.shared
  ) {
    self.deliverTap = deliverTap
    self.badge = badge
    self.storage = storage
    self.taps = taps
    self.downloader = downloader
  }

  func isBadgeSupported() throws -> Bool { badge.isBadgeSupported() }
  func setBadgeCount(count: Int64) throws { badge.setBadgeCount(count) }
  func getBadgeCount() throws -> Int64? { badge.getBadgeCount() }
  func clearBadge() throws { badge.clearBadge() }
  func incrementBadge() throws -> Int64 { badge.incrementBadge() }
  // iOS has no notification channels.
  func createChannel(c: ChannelConfig) throws {}
  func deleteChannel(id: String) throws {}
  func getLastLaunchId() throws -> String? { storage.getLastLaunchId() }
  func setLastLaunchId(id: String) throws { storage.setLastLaunchId(id) }
  func saveBackgroundConfig(config: BackgroundConfigMsg) throws {
    storage.saveBackgroundConfig(config)
  }
  func loadBackgroundConfig() throws -> BackgroundConfigMsg? { storage.loadBackgroundConfig() }
  /// Called by Dart's `init` (after it registered the tap handler): binds live
  /// tap delivery to this engine and returns the launch tap.
  func consumeLaunchPayload() throws -> String? {
    taps.consumeLaunchPayload(deliver: deliverTap)?.payload
  }

  /// Downloads the image first (big picture only), falls back to text-only on
  /// any image failure, and posts with an id-derived identifier so the same
  /// id replaces the earlier notification.
  func showNotification(content: NotificationContent) async throws {
    var file: URL?
    if content.imageStyle == .bigPicture, let url = content.imageUrl, !url.isEmpty {
      let httpsOnly = storage.loadBackgroundConfig()?.imageHttpsOnly ?? true
      file = await downloader.download(
        url: url, timeout: Self.imageTimeout, maxBytes: Self.imageMaxBytes, httpsOnly: httpsOnly)
    }
    let request = UNNotificationRequest(
      identifier: NotificationBuilder.requestIdentifier(for: content.id),
      content: NotificationBuilder.build(Self.spec(content, imageFile: file)),
      trigger: nil)
    do {
      // Removes the temp attachment copy when the add fails.
      try await NotificationBuilder.post(request) { try await UNUserNotificationCenter.current().add($0) }
    } catch {
      throw PigeonError(code: "show-failed", message: "\(error)", details: nil)
    }
  }

  func downloadImage(url: String, timeoutMs: Int64, maxBytes: Int64, httpsOnly: Bool) async throws -> String? {
    await downloader.download(
      url: url, timeout: Double(max(timeoutMs, 1)) / 1000, maxBytes: maxBytes, httpsOnly: httpsOnly
    )?.path
  }

  static func spec(_ c: NotificationContent, imageFile: URL?) -> NotificationSpec {
    var data: [String: String?] = [:]
    for (k, v) in c.data {
      if let k { data[k] = v }
    }
    let messageId = (c.extras["messageId"] ?? nil) as? String
    return NotificationSpec(
      id: c.id, title: c.title, body: c.body, channelId: c.channelId, data: data,
      imageUrl: c.imageUrl, badge: c.badge.map { Int(clamping: $0) }, messageId: messageId,
      imageFile: imageFile)
  }
}

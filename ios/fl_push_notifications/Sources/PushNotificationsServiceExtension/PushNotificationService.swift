import Foundation
import PushNotificationsCore
import UserNotifications

/// Ready-made Notification Service Extension that attaches the push's image.
///
/// In the host app's extension target, link the `PushNotificationsServiceExtension`
/// product and set the extension's principal class to a subclass:
///
///     import PushNotificationsServiceExtension
///     class NotificationService: PushNotificationService {}
///
/// The image URL is read from `image` or `fcm_options.image` in the payload
/// (the server must send `mutable-content: 1`). It is downloaded https-only
/// with a timeout and size cap; on any failure the original content is shown.
/// The content handler is always called exactly once, including from
/// `serviceExtensionTimeWillExpire`.
open class PushNotificationService: UNNotificationServiceExtension {
  public static let timeout: TimeInterval = 10
  public static let maxBytes: Int64 = 5 * 1024 * 1024

  /// Replaceable for tests or a custom cache.
  public var imageDownloader: ImageDownloading = ImageDownloader.shared

  private let lock = NSLock()
  private var handler: ((UNNotificationContent) -> Void)?
  private var original: UNNotificationContent?

  open override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    lock.lock()
    handler = contentHandler
    original = request.content
    lock.unlock()

    guard let url = Self.imageURL(in: request.content.userInfo),
      let mutable = request.content.mutableCopy() as? UNMutableNotificationContent
    else { return deliver(request.content) }

    let downloader = imageDownloader
    // Strong capture: the handler must be called even if the system dropped
    // its reference to the extension instance.
    Task {
      let file = await downloader.download(
        url: url, timeout: Self.timeout, maxBytes: Self.maxBytes, httpsOnly: true)
      if let file, let attachment = NotificationBuilder.attachment(for: file) {
        mutable.attachments = mutable.attachments + [attachment]
        self.deliver(mutable)
      } else {
        self.deliver(request.content)
      }
    }
  }

  open override func serviceExtensionTimeWillExpire() {
    lock.lock()
    let content = original
    lock.unlock()
    if let content { deliver(content) }
  }

  /// `image`, else `fcm_options.image`, when a non-empty string.
  public static func imageURL(in userInfo: [AnyHashable: Any]) -> String? {
    if let s = userInfo["image"] as? String, !s.isEmpty { return s }
    if let fcm = userInfo["fcm_options"] as? [AnyHashable: Any], let s = fcm["image"] as? String,
      !s.isEmpty
    {
      return s
    }
    return nil
  }

  /// Calls the content handler at most once.
  private func deliver(_ content: UNNotificationContent) {
    lock.lock()
    let h = handler
    handler = nil
    lock.unlock()
    h?(content)
  }
}

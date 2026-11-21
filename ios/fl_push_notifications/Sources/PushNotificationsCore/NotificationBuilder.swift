import Foundation
import UserNotifications

/// A notification button: pressing it opens the app and reports `id`.
public struct NotificationActionSpec: Equatable {
  public var id: String
  public var title: String

  public init(id: String, title: String) {
    self.id = id
    self.title = title
  }
}

/// Platform-neutral input for [NotificationBuilder], mapped from the Pigeon
/// `NotificationContent` by the plugin.
public struct NotificationSpec {
  public var id: Int64
  public var title: String?
  public var body: String?
  /// iOS has no channels; used as the thread identifier and echoed in the payload.
  public var channelId: String
  public var data: [String: String?]
  public var imageUrl: String?
  public var badge: Int?
  /// `NotificationContent.extras["messageId"]`; the payload `id` when non-empty.
  public var messageId: String?
  /// Local image file to attach (already downloaded).
  public var imageFile: URL?
  /// Notifications with the same key share a thread (grouped in the list).
  public var groupKey: String?
  public var actions: [NotificationActionSpec]

  public init(
    id: Int64, title: String?, body: String?, channelId: String, data: [String: String?],
    imageUrl: String?, badge: Int?, messageId: String?, imageFile: URL?,
    groupKey: String? = nil, actions: [NotificationActionSpec] = []
  ) {
    self.id = id
    self.title = title
    self.body = body
    self.channelId = channelId
    self.data = data
    self.imageUrl = imageUrl
    self.badge = badge
    self.messageId = messageId
    self.imageFile = imageFile
    self.groupKey = groupKey
    self.actions = actions
  }
}

/// Turns a [NotificationSpec] into `UNMutableNotificationContent`. In v1 it
/// handles title/body/image/badge only.
public enum NotificationBuilder {
  /// userInfo key holding the tap payload JSON. Its presence marks a
  /// notification as posted by this plugin.
  public static let payloadKey = "push_payload"

  public static func build(_ spec: NotificationSpec) -> UNMutableNotificationContent {
    let c = UNMutableNotificationContent()
    if let t = spec.title { c.title = t }
    if let b = spec.body { c.body = b }
    if let badge = spec.badge { c.badge = NSNumber(value: max(0, badge)) }
    c.sound = .default
    c.threadIdentifier = (spec.groupKey?.isEmpty == false) ? spec.groupKey! : spec.channelId
    c.categoryIdentifier = NotificationCategories.identifier(for: spec.actions)
    c.userInfo = [payloadKey: payloadJSON(spec)]
    if let file = spec.imageFile, let a = attachment(for: file) {
      c.attachments = [a]
    }
    return c
  }

  /// Identifier of the `UNNotificationRequest`; the same id replaces.
  public static func requestIdentifier(for id: Int64) -> String { "push_notifications.\(id)" }

  /// True for notifications whose userInfo carries our tap payload.
  public static func isOurs(_ userInfo: [AnyHashable: Any]) -> Bool {
    userInfo[payloadKey] is String
  }

  /// Tap payload contract read by `PushMessage.fromLocalPayload` (identical to
  /// Android): `{"id","title","body","data","imageUrl","channelId"}`; `id` is
  /// the message id when present and non-empty, else the notification id.
  public static func payloadJSON(_ spec: NotificationSpec) -> String {
    let id = (spec.messageId?.isEmpty == false) ? spec.messageId! : String(spec.id)
    func v(_ s: String?) -> Any { s ?? NSNull() }
    var data: [String: Any] = [:]
    for (k, value) in spec.data { data[k] = v(value) }
    let obj: [String: Any] = [
      "id": id, "title": v(spec.title), "body": v(spec.body), "data": data,
      "imageUrl": v(spec.imageUrl), "channelId": spec.channelId,
    ]
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
      let s = String(data: d, encoding: .utf8)
    else { return "{\"id\":\"\(id)\"}" }
    return s
  }

  /// Posts `request` through `add` (normally `UNUserNotificationCenter.add`).
  /// On success the system has moved the attachment copies into its store;
  /// on failure they would be left in the temp directory, so they are
  /// removed before the error is rethrown.
  public static func post(
    _ request: UNNotificationRequest,
    add: (UNNotificationRequest) async throws -> Void
  ) async throws {
    do {
      try await add(request)
    } catch {
      for a in request.content.attachments { try? FileManager.default.removeItem(at: a.url) }
      throw error
    }
  }

  /// Attachment for `file`, or nil when the system rejects it. The system moves
  /// attached files into its own store, so a private copy is attached and the
  /// cached original stays usable.
  public static func attachment(for file: URL) -> UNNotificationAttachment? {
    let fm = FileManager.default
    let copy = fm.temporaryDirectory
      .appendingPathComponent("push_notifications_attach_\(UUID().uuidString).\(file.pathExtension)")
    do {
      try fm.copyItem(at: file, to: copy)
      return try UNNotificationAttachment(identifier: "image", url: copy, options: nil)
    } catch {
      try? fm.removeItem(at: copy)
      NSLog("fl_push_notifications: attachment failed, showing text-only: \(error)")
      return nil
    }
  }
}

/// Notification categories carry the buttons and ask iOS to report dismissals
/// (`customDismissAction`), which it otherwise does not.
public enum NotificationCategories {
  /// Category used when a notification has no buttons.
  public static let defaultIdentifier = "fl_push.default"

  /// Stable identifier for an ordered list of buttons.
  public static func identifier(for actions: [NotificationActionSpec]) -> String {
    if actions.isEmpty { return defaultIdentifier }
    var h: UInt32 = 0x811c_9dc5
    for u in actions.map({ "\($0.id)\u{1}\($0.title)" }).joined(separator: "\u{2}").utf8 {
      h = (h ^ UInt32(u)) &* 0x0100_0193
    }
    return "fl_push.\(String(h, radix: 16))"
  }

  public static func category(for actions: [NotificationActionSpec]) -> UNNotificationCategory {
    UNNotificationCategory(
      identifier: identifier(for: actions),
      actions: actions.map { UNNotificationAction(identifier: $0.id, title: $0.title, options: [.foreground]) },
      intentIdentifiers: [],
      options: [.customDismissAction])
  }

  /// Registers the category for `actions` next to the existing ones (the
  /// app's and other plugins' categories are kept).
  public static func register(
    for actions: [NotificationActionSpec], center: UNUserNotificationCenter = .current()
  ) async {
    let wanted = category(for: actions)
    var all = await center.notificationCategories()
    if all.contains(where: { $0.identifier == wanted.identifier }) { return }
    all.insert(wanted)
    center.setNotificationCategories(all)
  }

  /// `payload` with `actionId` added (the tap payload of a button press).
  public static func payloadWithAction(_ payload: String, actionId: String) -> String {
    guard let d = payload.data(using: .utf8),
      var obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    else { return payload }
    obj["actionId"] = actionId
    guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
      let s = String(data: out, encoding: .utf8)
    else { return payload }
    return s
  }
}

import Foundation

/// Applies a badge count to the app icon. Injected so the counter logic is
/// testable without UIKit.
public protocol BadgeApplier {
  func apply(_ count: Int)
}

/// Reads the number currently shown on the app icon, or nil when it cannot
/// be read (then the stored counter is reported).
public protocol BadgeReader {
  func currentBadge() -> Int?
}

/// App icon badge on iOS. The counter lives in the `push_notifications`
/// UserDefaults suite so the main and background engines agree.
///
/// `getBadgeCount` reports the real icon number: an APNs `aps.badge` value is
/// applied by the OS without this counter seeing it. Increment counts from
/// that number too, so it never lowers an APNs-applied badge.
public final class BadgeHandler {
  public static let countKey = "push_notifications.badgeCount"
  /// When this plugin last set the badge (seconds since 1970), shared by all
  /// engines through the same defaults.
  static let setAtKey = "push_notifications.badgeSetAt"

  private let defaults: UserDefaults
  private let applier: BadgeApplier
  private let reader: BadgeReader?

  /// The system applies `setBadgeCount` asynchronously (iOS 16+), so for this
  /// long after the plugin's own set the icon may still show the old number;
  /// the stored (just set) value is reported instead.
  public static let ownSetWindow: TimeInterval = 2
  private let now: () -> Date

  public init(
    defaults: UserDefaults, applier: BadgeApplier, reader: BadgeReader? = nil,
    now: @escaping () -> Date = Date.init
  ) {
    self.now = now
    self.defaults = defaults
    self.applier = applier
    self.reader = reader
  }

  public func isBadgeSupported() -> Bool { true }

  /// The actual icon number when readable, else the stored counter.
  public func getBadgeCount() -> Int64 {
    if !recentlySetByUs(), let shown = reader?.currentBadge() { return Int64(max(0, shown)) }
    return storedCount()
  }

  private func recentlySetByUs() -> Bool {
    guard let at = defaults.object(forKey: Self.setAtKey) as? Double else { return false }
    let elapsed = now().timeIntervalSince1970 - at
    return elapsed >= 0 && elapsed < Self.ownSetWindow
  }

  public func storedCount() -> Int64 { Int64(defaults.integer(forKey: Self.countKey)) }

  public func setBadgeCount(_ count: Int64) {
    let c = Int(max(0, min(count, Int64(Int32.max))))
    defaults.set(c, forKey: Self.countKey)
    defaults.set(now().timeIntervalSince1970, forKey: Self.setAtKey)
    applier.apply(c)
  }

  public func clearBadge() { setBadgeCount(0) }

  public func incrementBadge() -> Int64 {
    let next = getBadgeCount() + 1
    setBadgeCount(next)
    return next
  }
}

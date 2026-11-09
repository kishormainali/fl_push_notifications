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
/// applied by the OS without this counter seeing it. Increment still counts
/// from the stored counter.
public final class BadgeHandler {
  public static let countKey = "push_notifications.badgeCount"

  private let defaults: UserDefaults
  private let applier: BadgeApplier
  private let reader: BadgeReader?

  public init(defaults: UserDefaults, applier: BadgeApplier, reader: BadgeReader? = nil) {
    self.defaults = defaults
    self.applier = applier
    self.reader = reader
  }

  public func isBadgeSupported() -> Bool { true }

  /// The actual icon number when readable, else the stored counter.
  public func getBadgeCount() -> Int64 {
    if let shown = reader?.currentBadge() { return Int64(max(0, shown)) }
    return storedCount()
  }

  public func storedCount() -> Int64 { Int64(defaults.integer(forKey: Self.countKey)) }

  public func setBadgeCount(_ count: Int64) {
    let c = Int(max(0, min(count, Int64(Int32.max))))
    defaults.set(c, forKey: Self.countKey)
    applier.apply(c)
  }

  public func clearBadge() { setBadgeCount(0) }

  public func incrementBadge() -> Int64 {
    let next = storedCount() + 1
    setBadgeCount(next)
    return next
  }
}

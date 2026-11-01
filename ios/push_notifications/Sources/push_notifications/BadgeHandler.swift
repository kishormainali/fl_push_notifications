import Foundation

#if canImport(UIKit)
  import UIKit
  import UserNotifications
#endif

/// Applies a badge count to the app icon. Injected so the counter logic is
/// testable without UIKit.
protocol BadgeApplier {
  func apply(_ count: Int)
}

/// App icon badge on iOS. The counter lives in the `push_notifications`
/// UserDefaults suite so the main and background engines agree.
final class BadgeHandler {
  static let countKey = "push_notifications.badgeCount"

  private let defaults: UserDefaults
  private let applier: BadgeApplier

  init(defaults: UserDefaults, applier: BadgeApplier) {
    self.defaults = defaults
    self.applier = applier
  }

  func isBadgeSupported() -> Bool { true }

  func getBadgeCount() -> Int64 { Int64(defaults.integer(forKey: Self.countKey)) }

  func setBadgeCount(_ count: Int64) {
    let c = Int(max(0, min(count, Int64(Int32.max))))
    defaults.set(c, forKey: Self.countKey)
    applier.apply(c)
  }

  func clearBadge() { setBadgeCount(0) }

  func incrementBadge() -> Int64 {
    let next = getBadgeCount() + 1
    setBadgeCount(next)
    return next
  }
}

#if canImport(UIKit)
  /// Sets the real app icon badge on the main thread.
  struct SystemBadgeApplier: BadgeApplier {
    func apply(_ count: Int) {
      let work = {
        if #available(iOS 16.0, *) {
          UNUserNotificationCenter.current().setBadgeCount(count) { error in
            if let error { NSLog("push_notifications: setBadgeCount failed: \(error)") }
          }
        } else {
          UIApplication.shared.applicationIconBadgeNumber = count
        }
      }
      if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
  }
#endif

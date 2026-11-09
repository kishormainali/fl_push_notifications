import PushNotificationsCore
import UIKit
import UserNotifications

/// Sets the real app icon badge on the main thread.
struct SystemBadgeApplier: BadgeApplier {
  func apply(_ count: Int) {
    let work = {
      if #available(iOS 16.0, *) {
        UNUserNotificationCenter.current().setBadgeCount(count) { error in
          if let error { NSLog("push_notifications: setBadgeCount failed: \(error)") }
        }
      } else {
        (UIApplication.shared as IconBadgeNumberAccess).iconBadgeNumber = count
      }
    }
    if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
  }
}

/// Reads the icon number the user actually sees (including a value applied
/// by the OS from an APNs `aps.badge`). UIKit is main-thread only and a
/// synchronous hop to main could deadlock, so off the main thread this
/// returns nil and the stored counter is reported instead. Pigeon host
/// calls arrive on the main (platform) thread.
struct SystemBadgeReader: BadgeReader {
  func currentBadge() -> Int? {
    guard Thread.isMainThread else { return nil }
    return (UIApplication.shared as IconBadgeNumberAccess).iconBadgeNumber
  }
}

/// `applicationIconBadgeNumber` is deprecated (iOS 17) without a getter
/// replacement, but still works. Swift has no pragma to silence one
/// deprecation; calling a deprecated member through a protocol requirement
/// does not warn, so this protocol confines the deprecated use to the
/// extension below and keeps the call sites warning-free.
private protocol IconBadgeNumberAccess: AnyObject {
  var iconBadgeNumber: Int { get set }
}

extension UIApplication: IconBadgeNumberAccess {
  @available(iOS, deprecated: 17.0, message: "Only reachable through IconBadgeNumberAccess")
  fileprivate var iconBadgeNumber: Int {
    get { applicationIconBadgeNumber }
    set { applicationIconBadgeNumber = newValue }
  }
}

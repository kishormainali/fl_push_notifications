import Foundation

/// Whether the app is in the foreground for a notification tap arriving now.
///
/// `UIApplication.applicationState` cannot answer this alone: pulling down
/// Notification Center over a foreground app makes it `.inactive`, the same
/// state a tap that brings the app back from the background arrives in. The
/// flag is sticky instead: set when the app becomes active, cleared only when
/// it enters the background; resigning active is ignored.
public final class AppActiveTracker {
  private let lock = NSLock()
  private var active: Bool

  /// Seeded from `applicationState == .active` at registration.
  public init(active: Bool) {
    self.active = active
  }

  public var isActive: Bool {
    lock.lock()
    defer { lock.unlock() }
    return active
  }

  public func didBecomeActive() { set(true) }

  /// Ignored: the app may still be on screen (Notification Center, alerts).
  public func willResignActive() {}

  public func didEnterBackground() { set(false) }

  private func set(_ value: Bool) {
    lock.lock()
    active = value
    lock.unlock()
  }
}

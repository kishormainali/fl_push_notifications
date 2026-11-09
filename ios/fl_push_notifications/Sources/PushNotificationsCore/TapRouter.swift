import Foundation

/// A native tap: its payload and whether the app was active when the tap was
/// received (captured synchronously in `didReceive`; it labels
/// `PushMessage.appState` in Dart, whose lifecycle may change before the tap
/// reaches it).
public struct NativeTap: Equatable {
  public let payload: String
  public let appWasActive: Bool

  public init(payload: String, appWasActive: Bool) {
    self.payload = payload
    self.appWasActive = appWasActive
  }
}

/// Thread-safe FIFO of taps not yet delivered to Dart.
public final class TapPayloadQueue {
  private let lock = NSLock()
  private var items: [NativeTap] = []

  public init() {}

  public func enqueue(_ t: NativeTap) {
    lock.lock()
    items.append(t)
    lock.unlock()
  }

  public func dequeue() -> NativeTap? {
    lock.lock()
    defer { lock.unlock() }
    return items.isEmpty ? nil : items.removeFirst()
  }

  public func drain() -> [NativeTap] {
    lock.lock()
    defer { lock.unlock() }
    let all = items
    items = []
    return all
  }
}

/// Routes native notification taps to Dart without losing any.
///
/// Until Dart first calls `consumeLaunchPayload(deliver:)` (its init has
/// registered the tap handler by then) taps are queued; that call binds live
/// delivery to the calling engine, returns the oldest tap as the launch tap
/// and pushes the rest live. Afterwards taps go live; a failed live delivery
/// is queued again and retried, in order, on the next tap (or returned by the
/// next `consumeLaunchPayload`). Every tap keeps its captured `appWasActive`
/// while queued or re-queued.
public final class TapRouter {
  public typealias Deliver = (NativeTap, @escaping (Bool) -> Void) -> Void

  /// Process-wide router shared by every engine's host API.
  public static let shared = TapRouter()

  /// Live delivery; calls its completion with `true` once Dart accepted it.
  public var deliver: Deliver? {
    get { lock.lock(); defer { lock.unlock() }; return _deliver }
    set { lock.lock(); _deliver = newValue; lock.unlock() }
  }

  private let lock = NSLock()
  private var _deliver: Deliver?
  private var ready = false
  private let queue = TapPayloadQueue()

  public init() {}

  public func handleTap(_ tap: NativeTap) {
    queue.enqueue(tap)
    flush()
  }

  /// The oldest undelivered tap, returned once (Dart labels it `terminated`).
  /// A non-nil [deliver] (the asking engine's channel) replaces the live
  /// deliverer.
  public func consumeLaunchPayload(deliver: Deliver? = nil) -> NativeTap? {
    lock.lock()
    ready = true
    if let deliver { _deliver = deliver }
    lock.unlock()
    let head = queue.dequeue()
    flush()
    return head
  }

  /// Sends every queued tap live, in order; a failure re-queues that tap.
  private func flush() {
    lock.lock()
    let send = ready ? _deliver : nil
    lock.unlock()
    guard let send else { return }
    for t in queue.drain() {
      send(t) { [queue] ok in
        if !ok { queue.enqueue(t) }
      }
    }
  }
}

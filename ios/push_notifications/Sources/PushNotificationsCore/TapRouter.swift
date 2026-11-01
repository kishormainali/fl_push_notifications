import Foundation

/// Thread-safe FIFO of tap payloads not yet delivered to Dart.
public final class TapPayloadQueue {
  private let lock = NSLock()
  private var items: [String] = []

  public init() {}

  public func enqueue(_ p: String) {
    lock.lock()
    items.append(p)
    lock.unlock()
  }

  public func dequeue() -> String? {
    lock.lock()
    defer { lock.unlock() }
    return items.isEmpty ? nil : items.removeFirst()
  }

  public func drain() -> [String] {
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
/// next `consumeLaunchPayload`).
public final class TapRouter {
  public typealias Deliver = (String, @escaping (Bool) -> Void) -> Void

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

  public func handleTap(_ payload: String) {
    queue.enqueue(payload)
    flush()
  }

  /// The oldest undelivered tap, returned once. A non-nil [deliver] (the
  /// asking engine's channel) replaces the live deliverer.
  public func consumeLaunchPayload(deliver: Deliver? = nil) -> String? {
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
    for p in queue.drain() {
      send(p) { [queue] ok in
        if !ok { queue.enqueue(p) }
      }
    }
  }
}

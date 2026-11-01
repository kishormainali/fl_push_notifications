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
/// Until Dart first calls `consumeLaunchPayload()` (its init has registered the
/// tap handler by then) taps are queued; that call returns the oldest one as
/// the launch tap and pushes the rest live. Afterwards taps go live; a failed
/// live delivery is queued again for the next `consumeLaunchPayload()`.
public final class TapRouter {
  /// Process-wide router shared by every engine's host API.
  public static let shared = TapRouter()

  /// Live delivery; calls its completion with `true` once Dart accepted it.
  public var deliver: ((String, @escaping (Bool) -> Void) -> Void)? {
    get { lock.lock(); defer { lock.unlock() }; return _deliver }
    set { lock.lock(); _deliver = newValue; lock.unlock() }
  }

  private let lock = NSLock()
  private var _deliver: ((String, @escaping (Bool) -> Void) -> Void)?
  private var ready = false
  private let queue = TapPayloadQueue()

  public init() {}

  public func handleTap(_ payload: String) {
    lock.lock()
    let send = ready ? _deliver : nil
    lock.unlock()
    guard let send else { return queue.enqueue(payload) }
    send(payload) { [queue] ok in
      if !ok { queue.enqueue(payload) }
    }
  }

  /// The oldest undelivered tap, returned once.
  public func consumeLaunchPayload() -> String? {
    lock.lock()
    ready = true
    lock.unlock()
    let head = queue.dequeue()
    for p in queue.drain() { handleTap(p) }
    return head
  }
}

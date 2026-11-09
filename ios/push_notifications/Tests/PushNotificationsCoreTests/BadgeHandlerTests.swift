import XCTest

@testable import PushNotificationsCore

final class BadgeHandlerTests: XCTestCase {
  private final class RecordingApplier: BadgeApplier {
    var applied: [Int] = []
    func apply(_ count: Int) { applied.append(count) }
  }

  private struct FixedReader: BadgeReader {
    let value: Int?
    func currentBadge() -> Int? { value }
  }

  private var suite: String!
  private var defaults: UserDefaults!
  private let applier = RecordingApplier()

  override func setUp() {
    super.setUp()
    suite = "pn-badge-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
    super.tearDown()
  }

  private var clock = Date(timeIntervalSince1970: 1_000_000)

  private func handler(reading value: Int?) -> BadgeHandler {
    BadgeHandler(
      defaults: defaults, applier: applier, reader: FixedReader(value: value),
      now: { [unowned self] in self.clock })
  }

  /// Moves past the window in which the plugin's own (async) set may not
  /// have reached the icon yet.
  private func settle() { clock = clock.addingTimeInterval(BadgeHandler.ownSetWindow + 1) }

  func testGetBadgeCountReturnsTheRealIconNumber() {
    let h = handler(reading: 7)
    h.setBadgeCount(2)
    settle()
    // e.g. an APNs payload set the icon to 7 behind the counter's back.
    XCTAssertEqual(h.getBadgeCount(), 7)
    XCTAssertEqual(h.storedCount(), 2)
  }

  func testGetBadgeCountFallsBackToTheStoredCounter() {
    let h = handler(reading: nil)
    h.setBadgeCount(4)
    XCTAssertEqual(h.getBadgeCount(), 4)
  }

  func testSetStoresClampsAndApplies() {
    let h = handler(reading: nil)
    h.setBadgeCount(-3)
    XCTAssertEqual(h.storedCount(), 0)
    h.setBadgeCount(5)
    XCTAssertEqual(applier.applied, [0, 5])
  }

  func testIncrementCountsFromTheRealIconNumber() {
    // Icon shows 9 (APNs-applied), counter says 1: never lower the badge.
    let h = handler(reading: 9)
    h.setBadgeCount(1)
    settle()
    XCTAssertEqual(h.incrementBadge(), 10)
    XCTAssertEqual(h.storedCount(), 10)
    XCTAssertEqual(applier.applied, [1, 10])
  }

  func testIncrementWithoutAReadableIconUsesTheStoredCounter() {
    let h = handler(reading: nil)
    h.setBadgeCount(4)
    settle()
    XCTAssertEqual(h.incrementBadge(), 5)
  }

  func testGetRightAfterOwnSetReturnsTheSetValue() {
    // The reader still shows the old icon number (the async set has not
    // landed yet).
    let h = handler(reading: 9)
    h.setBadgeCount(3)
    XCTAssertEqual(h.getBadgeCount(), 3)
    clock = clock.addingTimeInterval(BadgeHandler.ownSetWindow / 2)
    XCTAssertEqual(h.getBadgeCount(), 3)
    settle()
    XCTAssertEqual(h.getBadgeCount(), 9)
  }

  func testIncrementRightAfterSetBuildsOnTheSetValue() {
    let h = handler(reading: 9)
    h.setBadgeCount(1)
    XCTAssertEqual(h.incrementBadge(), 2)
    XCTAssertEqual(h.incrementBadge(), 3)
  }

  func testOwnSetWindowIsSharedThroughTheStore() {
    // Another engine's handler on the same defaults sees the recent set.
    handler(reading: 9).setBadgeCount(2)
    XCTAssertEqual(handler(reading: 9).getBadgeCount(), 2)
  }

  func testClearResetsCounterAndIcon() {
    let h = handler(reading: nil)
    h.setBadgeCount(3)
    h.clearBadge()
    XCTAssertEqual(h.storedCount(), 0)
    XCTAssertEqual(applier.applied.last, 0)
  }
}

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

  private func handler(reading value: Int?) -> BadgeHandler {
    BadgeHandler(defaults: defaults, applier: applier, reader: FixedReader(value: value))
  }

  func testGetBadgeCountReturnsTheRealIconNumber() {
    let h = handler(reading: 7)
    h.setBadgeCount(2)
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

  func testIncrementUsesTheStoredCounter() {
    let h = handler(reading: 9)
    h.setBadgeCount(1)
    XCTAssertEqual(h.incrementBadge(), 2)
    XCTAssertEqual(applier.applied, [1, 2])
  }

  func testClearResetsCounterAndIcon() {
    let h = handler(reading: nil)
    h.setBadgeCount(3)
    h.clearBadge()
    XCTAssertEqual(h.storedCount(), 0)
    XCTAssertEqual(applier.applied.last, 0)
  }
}

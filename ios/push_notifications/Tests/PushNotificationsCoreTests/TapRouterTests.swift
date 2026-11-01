import XCTest

@testable import PushNotificationsCore

final class TapRouterTests: XCTestCase {
  func testQueueIsFifo() {
    let q = TapPayloadQueue()
    q.enqueue("a")
    q.enqueue("b")
    XCTAssertEqual(q.dequeue(), "a")
    XCTAssertEqual(q.dequeue(), "b")
    XCTAssertNil(q.dequeue())
  }

  func testTapsBeforeReadyAreQueuedAndConsumedOnce() {
    var delivered: [String] = []
    let r = TapRouter()
    r.deliver = { p, done in
      delivered.append(p)
      done(true)
    }
    r.handleTap("a")
    XCTAssertTrue(delivered.isEmpty, "not delivered before Dart asked for the launch payload")
    XCTAssertEqual(r.consumeLaunchPayload(), "a")
    XCTAssertNil(r.consumeLaunchPayload())
  }

  func testTwoUndeliveredTapsBothSurvive() {
    var delivered: [String] = []
    let r = TapRouter()
    r.deliver = { p, done in
      delivered.append(p)
      done(true)
    }
    r.handleTap("a")
    r.handleTap("b")
    XCTAssertEqual(r.consumeLaunchPayload(), "a")
    // The rest is pushed live once Dart is ready.
    XCTAssertEqual(delivered, ["b"])
    XCTAssertNil(r.consumeLaunchPayload())
  }

  func testAfterReadyTapsAreDeliveredLive() {
    var delivered: [String] = []
    let r = TapRouter()
    r.deliver = { p, done in
      delivered.append(p)
      done(true)
    }
    XCTAssertNil(r.consumeLaunchPayload())
    r.handleTap("x")
    XCTAssertEqual(delivered, ["x"])
    XCTAssertNil(r.consumeLaunchPayload())
  }

  func testFailedLiveDeliveryIsKept() {
    let r = TapRouter()
    r.deliver = { _, done in done(false) }
    XCTAssertNil(r.consumeLaunchPayload())
    r.handleTap("x")
    r.handleTap("y")
    XCTAssertEqual(r.consumeLaunchPayload(), "x")
    XCTAssertEqual(r.consumeLaunchPayload(), "y")
    XCTAssertNil(r.consumeLaunchPayload())
  }

  func testNoDelivererQueues() {
    let r = TapRouter()
    XCTAssertNil(r.consumeLaunchPayload())
    r.handleTap("x")
    XCTAssertEqual(r.consumeLaunchPayload(), "x")
  }
}

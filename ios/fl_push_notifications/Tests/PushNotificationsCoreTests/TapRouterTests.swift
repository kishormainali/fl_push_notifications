import XCTest

@testable import PushNotificationsCore

private func tap(_ p: String, _ active: Bool = false) -> NativeTap {
  NativeTap(payload: p, appWasActive: active)
}

final class TapRouterTests: XCTestCase {
  func testQueueIsFifo() {
    let q = TapPayloadQueue()
    q.enqueue(tap("a"))
    q.enqueue(tap("b", true))
    XCTAssertEqual(q.dequeue(), tap("a"))
    XCTAssertEqual(q.dequeue(), tap("b", true))
    XCTAssertNil(q.dequeue())
  }

  func testTapsBeforeReadyAreQueuedAndConsumedOnce() {
    var delivered: [NativeTap] = []
    let r = TapRouter()
    r.deliver = { t, done in
      delivered.append(t)
      done(true)
    }
    r.handleTap(tap("a"))
    XCTAssertTrue(delivered.isEmpty, "not delivered before Dart asked for the launch payload")
    XCTAssertEqual(r.consumeLaunchPayload()?.payload, "a")
    XCTAssertNil(r.consumeLaunchPayload())
  }

  func testTwoUndeliveredTapsBothSurviveWithTheirFlags() {
    var delivered: [NativeTap] = []
    let r = TapRouter()
    r.deliver = { t, done in
      delivered.append(t)
      done(true)
    }
    r.handleTap(tap("a"))
    r.handleTap(tap("b", true))
    r.handleTap(tap("c", false))
    XCTAssertEqual(r.consumeLaunchPayload()?.payload, "a")
    // The rest is pushed live once Dart is ready, in order, each with the
    // app state captured when it was received.
    XCTAssertEqual(delivered, [tap("b", true), tap("c", false)])
    XCTAssertNil(r.consumeLaunchPayload())
  }

  func testAfterReadyTapsAreDeliveredLiveWithTheirFlag() {
    var delivered: [NativeTap] = []
    let r = TapRouter()
    r.deliver = { t, done in
      delivered.append(t)
      done(true)
    }
    XCTAssertNil(r.consumeLaunchPayload())
    r.handleTap(tap("x", true))
    r.handleTap(tap("y", false))
    XCTAssertEqual(delivered, [tap("x", true), tap("y", false)])
    XCTAssertNil(r.consumeLaunchPayload())
  }

  func testFailedLiveDeliveryIsKept() {
    let r = TapRouter()
    r.deliver = { _, done in done(false) }
    XCTAssertNil(r.consumeLaunchPayload())
    r.handleTap(tap("x", true))
    r.handleTap(tap("y"))
    XCTAssertEqual(r.consumeLaunchPayload(), tap("x", true))
    XCTAssertEqual(r.consumeLaunchPayload(), tap("y"))
    XCTAssertNil(r.consumeLaunchPayload())
  }

  func testNoDelivererQueues() {
    let r = TapRouter()
    XCTAssertNil(r.consumeLaunchPayload())
    r.handleTap(tap("x"))
    XCTAssertEqual(r.consumeLaunchPayload()?.payload, "x")
  }

  func testRequeuedTapKeepsItsFlagAndIsDrainedFirstOnNextTap() {
    var delivered: [NativeTap] = []
    var accept = false
    let r = TapRouter()
    r.deliver = { t, done in
      if accept { delivered.append(t) }
      done(accept)
    }
    XCTAssertNil(r.consumeLaunchPayload())
    r.handleTap(tap("x", true))  // live delivery fails: re-queued
    XCTAssertTrue(delivered.isEmpty)
    accept = true
    r.handleTap(tap("y", false))  // retries x first, in order, flag intact
    XCTAssertEqual(delivered, [tap("x", true), tap("y", false)])
    XCTAssertNil(r.consumeLaunchPayload())
  }

  func testConsumeBindsTheDelivererOfTheEngineThatAsked() {
    var headless: [String] = []
    var main: [String] = []
    let r = TapRouter()
    // A headless engine registered first; its Dart never calls consume.
    r.deliver = { t, done in
      headless.append(t.payload)
      done(false)
    }
    r.handleTap(tap("a"))
    r.handleTap(tap("b"))
    XCTAssertEqual(
      r.consumeLaunchPayload(deliver: { t, done in
        main.append(t.payload)
        done(true)
      })?.payload, "a")
    XCTAssertEqual(main, ["b"])
    r.handleTap(tap("c"))
    XCTAssertEqual(main, ["b", "c"])
    XCTAssertTrue(headless.isEmpty)
  }

  func testRebindingReplacesTheDeliverer() {
    var first: [String] = []
    var second: [String] = []
    let r = TapRouter()
    XCTAssertNil(
      r.consumeLaunchPayload(deliver: { t, done in
        first.append(t.payload)
        done(true)
      }))
    r.handleTap(tap("a"))
    XCTAssertNil(
      r.consumeLaunchPayload(deliver: { t, done in
        second.append(t.payload)
        done(true)
      }))
    r.handleTap(tap("b"))
    XCTAssertEqual(first, ["a"])
    XCTAssertEqual(second, ["b"])
  }
}

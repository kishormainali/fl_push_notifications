import XCTest

@testable import PushNotificationsCore

final class AppActiveTrackerTests: XCTestCase {
  func testSeeded() {
    XCTAssertTrue(AppActiveTracker(active: true).isActive)
    XCTAssertFalse(AppActiveTracker(active: false).isActive)
  }

  func testBecomeActiveSetsTheFlag() {
    let t = AppActiveTracker(active: false)
    t.didBecomeActive()
    XCTAssertTrue(t.isActive)
  }

  func testResignActiveIsIgnored() {
    // Pulling down Notification Center over a foreground app makes it
    // inactive; a tap there is still a foreground tap.
    let t = AppActiveTracker(active: true)
    t.willResignActive()
    XCTAssertTrue(t.isActive)
  }

  func testEnterBackgroundClearsUntilActiveAgain() {
    let t = AppActiveTracker(active: true)
    t.willResignActive()
    t.didEnterBackground()
    XCTAssertFalse(t.isActive)
    // A background tap arrives while inactive, before didBecomeActive.
    t.willResignActive()
    XCTAssertFalse(t.isActive)
    t.didBecomeActive()
    XCTAssertTrue(t.isActive)
  }
}

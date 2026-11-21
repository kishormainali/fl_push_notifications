import XCTest

@testable import PushNotificationsCore

final class LocalizedStringsTests: XCTestCase {
  func testMissingKeyReturnsNil() {
    XCTAssertNil(LocalizedStrings.resolve(key: "no_such_key_xyz", args: []))
  }

  func testMissingKeyWithArgsReturnsNil() {
    XCTAssertNil(LocalizedStrings.resolve(key: "no_such_key_xyz", args: ["a"]))
  }
}

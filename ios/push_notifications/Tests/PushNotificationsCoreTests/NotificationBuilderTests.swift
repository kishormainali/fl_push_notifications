import UserNotifications
import XCTest

@testable import PushNotificationsCore

final class NotificationBuilderTests: XCTestCase {
  private var dir: URL!

  override func setUp() {
    super.setUp()
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pn-builder-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: dir)
    super.tearDown()
  }

  private func spec(
    messageId: String? = nil, imageFile: URL? = nil, badge: Int? = nil
  ) -> NotificationSpec {
    NotificationSpec(
      id: 42, title: "Hi", body: "There \"quoted\"\n", channelId: "news",
      data: ["k": "v", "n": nil], imageUrl: "https://img.test/a.png", badge: badge,
      messageId: messageId, imageFile: imageFile)
  }

  private func payload(_ c: UNNotificationContent) throws -> [String: Any] {
    let s = try XCTUnwrap(c.userInfo[NotificationBuilder.payloadKey] as? String)
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
  }

  func testPayloadKeyIsPushPayload() {
    XCTAssertEqual(NotificationBuilder.payloadKey, "push_payload")
  }

  func testTitleBodyBadgeThread() {
    let c = NotificationBuilder.build(spec(badge: 3))
    XCTAssertEqual(c.title, "Hi")
    XCTAssertEqual(c.body, "There \"quoted\"\n")
    XCTAssertEqual(c.badge, 3)
    XCTAssertEqual(c.threadIdentifier, "news")
  }

  func testNoBadgeLeavesBadgeUnset() {
    XCTAssertNil(NotificationBuilder.build(spec()).badge)
  }

  func testPayloadContractUsesMessageIdWhenPresent() throws {
    let j = try payload(NotificationBuilder.build(spec(messageId: "m-1")))
    XCTAssertEqual(Set(j.keys), ["id", "title", "body", "data", "imageUrl", "channelId"])
    XCTAssertEqual(j["id"] as? String, "m-1")
    XCTAssertEqual(j["title"] as? String, "Hi")
    XCTAssertEqual(j["body"] as? String, "There \"quoted\"\n")
    XCTAssertEqual(j["imageUrl"] as? String, "https://img.test/a.png")
    XCTAssertEqual(j["channelId"] as? String, "news")
    let data = try XCTUnwrap(j["data"] as? [String: Any])
    XCTAssertEqual(data["k"] as? String, "v")
    XCTAssertTrue(data["n"] is NSNull)
  }

  func testPayloadIdFallsBackToNotificationId() throws {
    XCTAssertEqual(try payload(NotificationBuilder.build(spec()))["id"] as? String, "42")
    XCTAssertEqual(try payload(NotificationBuilder.build(spec(messageId: "")))["id"] as? String, "42")
  }

  func testNullTitleBodyImageAreJsonNull() throws {
    let s = NotificationSpec(
      id: 7, title: nil, body: nil, channelId: "c", data: [:], imageUrl: nil, badge: nil,
      messageId: nil, imageFile: nil)
    let j = try payload(NotificationBuilder.build(s))
    XCTAssertTrue(j["title"] is NSNull)
    XCTAssertTrue(j["body"] is NSNull)
    XCTAssertTrue(j["imageUrl"] is NSNull)
    XCTAssertEqual((j["data"] as? [String: Any])?.count, 0)
  }

  func testAttachmentAddedWhenFileGiven() throws {
    let file = dir.appendingPathComponent("img.png")
    try tinyPNG.write(to: file)
    let c = NotificationBuilder.build(spec(imageFile: file))
    XCTAssertEqual(c.attachments.count, 1)
    // The cached original stays usable (the system moves attached files).
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
  }

  func testNoAttachmentWithoutFile() {
    XCTAssertTrue(NotificationBuilder.build(spec()).attachments.isEmpty)
  }

  func testNoAttachmentWhenCreationFails() {
    let missing = dir.appendingPathComponent("missing.png")
    XCTAssertTrue(NotificationBuilder.build(spec(imageFile: missing)).attachments.isEmpty)
  }

  func testRequestIdentifierIsStablePerId() {
    XCTAssertEqual(NotificationBuilder.requestIdentifier(for: 42), "push_notifications.42")
    XCTAssertEqual(
      NotificationBuilder.requestIdentifier(for: 42), NotificationBuilder.requestIdentifier(for: 42))
  }

  func testIsOursChecksPayloadString() {
    XCTAssertTrue(NotificationBuilder.isOurs(["push_payload": "{}"]))
    XCTAssertFalse(NotificationBuilder.isOurs(["push_payload": 1]))
    XCTAssertFalse(NotificationBuilder.isOurs(["gcm.message_id": "x"]))
  }
}

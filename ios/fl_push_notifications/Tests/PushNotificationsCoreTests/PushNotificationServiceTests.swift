import PushNotificationsCore
import UserNotifications
import XCTest

@testable import PushNotificationsServiceExtension

private final class FakeDownloader: ImageDownloading, @unchecked Sendable {
  enum Mode { case fail, file(URL), hang }
  let mode: Mode
  private let lock = NSLock()
  private var calls: [(String, Bool)] = []
  private var waiting: CheckedContinuation<URL?, Never>?

  init(_ mode: Mode) { self.mode = mode }

  var requests: [(String, Bool)] {
    lock.lock()
    defer { lock.unlock() }
    return calls
  }

  func download(url: String, timeout: TimeInterval, maxBytes: Int64, httpsOnly: Bool) async -> URL? {
    lock.withLock { calls.append((url, httpsOnly)) }
    switch mode {
    case .fail: return nil
    case .file(let u): return u
    case .hang:
      return await withCheckedContinuation { c in
        lock.withLock { waiting = c }
      }
    }
  }

  /// Completes a hanging download with a failure.
  func release() {
    lock.lock()
    let c = waiting
    waiting = nil
    lock.unlock()
    c?.resume(returning: nil)
  }
}

final class PushNotificationServiceTests: XCTestCase {
  private func request(_ userInfo: [AnyHashable: Any]) -> UNNotificationRequest {
    let c = UNMutableNotificationContent()
    c.title = "T"
    c.body = "B"
    c.userInfo = userInfo
    return UNNotificationRequest(identifier: "r", content: c, trigger: nil)
  }

  func testDownloadFailureDeliversOriginalContentOnce() {
    let fake = FakeDownloader(.fail)
    let svc = PushNotificationService()
    svc.imageDownloader = fake
    var calls: [UNNotificationContent] = []
    let done = expectation(description: "handler")
    svc.didReceive(request(["image": "https://img.test/a.png"])) { c in
      calls.append(c)
      done.fulfill()
    }
    wait(for: [done], timeout: 2)
    // Nothing else may arrive later, even on expiry.
    svc.serviceExtensionTimeWillExpire()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.title, "T")
    XCTAssertEqual(calls.first?.attachments.count, 0)
    XCTAssertEqual(fake.requests.first?.0, "https://img.test/a.png")
    XCTAssertEqual(fake.requests.first?.1, true, "service extension is https-only")
  }

  func testExpiryDeliversOriginalContentOnce() {
    let fake = FakeDownloader(.hang)
    let svc = PushNotificationService()
    svc.imageDownloader = fake
    var calls: [UNNotificationContent] = []
    svc.didReceive(request(["fcm_options": ["image": "https://img.test/a.png"]])) { c in
      calls.append(c)
    }
    // Let the download start.
    let started = expectation(description: "started")
    DispatchQueue.global().async {
      while fake.requests.isEmpty { usleep(1000) }
      started.fulfill()
    }
    wait(for: [started], timeout: 2)
    svc.serviceExtensionTimeWillExpire()
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.title, "T")
    fake.release()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertEqual(calls.count, 1, "late download completion must not call the handler again")
    XCTAssertEqual(fake.requests.first?.0, "https://img.test/a.png")
  }

  func testNoImageDeliversContentImmediately() {
    let fake = FakeDownloader(.fail)
    let svc = PushNotificationService()
    svc.imageDownloader = fake
    var calls = 0
    svc.didReceive(request(["k": "v"])) { _ in calls += 1 }
    XCTAssertEqual(calls, 1)
    XCTAssertTrue(fake.requests.isEmpty)
    svc.serviceExtensionTimeWillExpire()
    XCTAssertEqual(calls, 1)
  }

  func testSuccessfulDownloadAttachesImage() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pn-nse-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("a.png")
    try tinyPNG.write(to: file)

    let svc = PushNotificationService()
    svc.imageDownloader = FakeDownloader(.file(file))
    var calls: [UNNotificationContent] = []
    let done = expectation(description: "handler")
    svc.didReceive(request(["image": "https://img.test/a.png"])) { c in
      calls.append(c)
      done.fulfill()
    }
    wait(for: [done], timeout: 2)
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.attachments.count, 1)
    XCTAssertEqual(calls.first?.title, "T")
  }

  func testImageUrlLookup() {
    XCTAssertEqual(PushNotificationService.imageURL(in: ["image": "https://a"]), "https://a")
    XCTAssertEqual(PushNotificationService.imageURL(in: ["fcm_options": ["image": "https://b"]]), "https://b")
    XCTAssertNil(PushNotificationService.imageURL(in: ["image": ""]))
    XCTAssertNil(PushNotificationService.imageURL(in: [:]))
  }
}

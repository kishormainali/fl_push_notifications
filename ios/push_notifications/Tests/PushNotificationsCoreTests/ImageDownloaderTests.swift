import XCTest

@testable import PushNotificationsCore

final class ImageDownloaderTests: XCTestCase {
  private var dir: URL!
  private var downloader: ImageDownloader!

  override func setUp() {
    super.setUp()
    StubURLProtocol.reset()
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("pn-tests-\(UUID().uuidString)", isDirectory: true)
    downloader = ImageDownloader(cacheDirectory: dir, configuration: StubURLProtocol.configuration())
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: dir)
    StubURLProtocol.reset()
    super.tearDown()
  }

  private func get(
    _ url: String, timeout: TimeInterval = 5, maxBytes: Int64 = 1024, httpsOnly: Bool = true
  ) async -> URL? {
    await downloader.download(url: url, timeout: timeout, maxBytes: maxBytes, httpsOnly: httpsOnly)
  }

  func testHttpRejectedWhenHttpsOnly() async {
    StubURLProtocol.set("http://img.test/a.png", .respond(status: 200, headers: ["Content-Type": "image/png"], chunks: [tinyPNG]))
    let r = await get("http://img.test/a.png")
    XCTAssertNil(r)
    XCTAssertTrue(StubURLProtocol.requested.isEmpty, "must not even request a non-https url")
  }

  func testHttpAllowedWhenNotHttpsOnly() async {
    StubURLProtocol.set("http://img.test/a.png", .respond(status: 200, headers: ["Content-Type": "image/png"], chunks: [tinyPNG]))
    let r = await get("http://img.test/a.png", httpsOnly: false)
    XCTAssertNotNil(r)
  }

  func testNonHttpSchemeRejectedEvenWhenNotHttpsOnly() async {
    let r = await get("ftp://img.test/a.png", httpsOnly: false)
    XCTAssertNil(r)
  }

  func testMalformedUrlReturnsNil() async {
    let a = await get("not a url")
    let b = await get("")
    let c = await get("https://")
    XCTAssertNil(a)
    XCTAssertNil(b)
    XCTAssertNil(c)
  }

  func testNotFoundReturnsNil() async {
    StubURLProtocol.set("https://img.test/missing.png", .respond(status: 404, headers: ["Content-Type": "image/png"], chunks: [tinyPNG]))
    let r = await get("https://img.test/missing.png")
    XCTAssertNil(r)
  }

  func testDeclaredOversizeReturnsNil() async {
    StubURLProtocol.set(
      "https://img.test/big.png",
      .respond(status: 200, headers: ["Content-Type": "image/png", "Content-Length": "5000"], chunks: [Data(count: 5000)]))
    let r = await get("https://img.test/big.png", maxBytes: 1000)
    XCTAssertNil(r)
  }

  func testUndeclaredOversizeReturnsNil() async {
    let chunk = Data(count: 600)
    StubURLProtocol.set(
      "https://img.test/stream.png",
      .respond(status: 200, headers: ["Content-Type": "image/png"], chunks: [chunk, chunk]))
    let r = await get("https://img.test/stream.png", maxBytes: 1000)
    XCTAssertNil(r)
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    XCTAssertTrue(leftovers.isEmpty, "no partial file kept: \(leftovers)")
  }

  func testTimeoutReturnsNil() async {
    StubURLProtocol.set("https://img.test/slow.png", .hang)
    let start = Date()
    let r = await get("https://img.test/slow.png", timeout: 0.5)
    XCTAssertNil(r)
    XCTAssertLessThan(Date().timeIntervalSince(start), 3)
  }

  func testRedirectToHttpRejectedWhenHttpsOnly() async {
    StubURLProtocol.set("https://img.test/r.png", .redirect(to: "http://img.test/a.png"))
    StubURLProtocol.set("http://img.test/a.png", .respond(status: 200, headers: ["Content-Type": "image/png"], chunks: [tinyPNG]))
    let r = await get("https://img.test/r.png")
    XCTAssertNil(r)
    XCTAssertFalse(StubURLProtocol.requested.contains("http://img.test/a.png"))
  }

  func testRedirectToHttpsFollowed() async {
    StubURLProtocol.set("https://img.test/r.png", .redirect(to: "https://cdn.test/a.png"))
    StubURLProtocol.set("https://cdn.test/a.png", .respond(status: 200, headers: ["Content-Type": "image/png"], chunks: [tinyPNG]))
    let r = await get("https://img.test/r.png")
    XCTAssertNotNil(r)
  }

  func testSuccessWritesCachedFileWithExtensionFromMime() async throws {
    StubURLProtocol.set("https://img.test/pic", .respond(status: 200, headers: ["Content-Type": "image/jpeg; charset=binary"], chunks: [tinyPNG]))
    let rOpt = await get("https://img.test/pic")
    let r = try XCTUnwrap(rOpt)
    XCTAssertEqual(r.pathExtension, "jpg")
    XCTAssertEqual(r.deletingLastPathComponent().standardizedFileURL.path, dir.standardizedFileURL.path)
    XCTAssertEqual(try Data(contentsOf: r), tinyPNG)

    // Second call is served from the cache without a request.
    let before = StubURLProtocol.requested.count
    let again = await get("https://img.test/pic")
    XCTAssertEqual(again, r)
    XCTAssertEqual(StubURLProtocol.requested.count, before)
  }

  func testExtensionFromUrlWhenMimeUnknown() async throws {
    StubURLProtocol.set("https://img.test/a.gif?x=1", .respond(status: 200, headers: ["Content-Type": "application/octet-stream"], chunks: [Data("GIF89a....".utf8)]))
    let rOpt = await get("https://img.test/a.gif?x=1")
    let r = try XCTUnwrap(rOpt)
    XCTAssertEqual(r.pathExtension, "gif")
  }

  func testExtensionSniffedWhenMimeAndUrlUnknown() async throws {
    StubURLProtocol.set("https://img.test/blob", .respond(status: 200, headers: [:], chunks: [tinyPNG]))
    let rOpt = await get("https://img.test/blob")
    let r = try XCTUnwrap(rOpt)
    XCTAssertEqual(r.pathExtension, "png")
  }

  func testUnidentifiableTypeReturnsNil() async {
    StubURLProtocol.set("https://img.test/blob", .respond(status: 200, headers: ["Content-Type": "text/html"], chunks: [Data("<html>".utf8)]))
    let r = await get("https://img.test/blob")
    XCTAssertNil(r)
  }

  func testEmptyBodyReturnsNil() async {
    StubURLProtocol.set("https://img.test/empty.png", .respond(status: 200, headers: ["Content-Type": "image/png"], chunks: []))
    let r = await get("https://img.test/empty.png")
    XCTAssertNil(r)
  }

  func testCacheKeyedByUrlHash() async throws {
    StubURLProtocol.set("https://img.test/1.png", .respond(status: 200, headers: ["Content-Type": "image/png"], chunks: [tinyPNG]))
    StubURLProtocol.set("https://img.test/2.png", .respond(status: 200, headers: ["Content-Type": "image/png"], chunks: [tinyPNG]))
    let aOpt = await get("https://img.test/1.png")
    let a = try XCTUnwrap(aOpt)
    let bOpt = await get("https://img.test/2.png")
    let b = try XCTUnwrap(bOpt)
    XCTAssertNotEqual(a, b)
  }
}

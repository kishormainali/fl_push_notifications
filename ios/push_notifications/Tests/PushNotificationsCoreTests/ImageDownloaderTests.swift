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

  func testSuccessWritesCachedFileWithExtensionFromSignature() async throws {
    StubURLProtocol.set("https://img.test/pic", .respond(status: 200, headers: ["Content-Type": "image/jpeg; charset=binary"], chunks: [tinyPNG]))
    let rOpt = await get("https://img.test/pic")
    let r = try XCTUnwrap(rOpt)
    // The extension comes from the content signature, not the declared MIME.
    XCTAssertEqual(r.pathExtension, "png")
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

  // MARK: - Content sniffing

  private func files() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
  }

  func testHtmlBodyWithImageMimeAndUrlReturnsNilAndCachesNothing() async {
    StubURLProtocol.set(
      "https://img.test/photo.jpg",
      .respond(status: 200, headers: ["Content-Type": "image/jpeg"], chunks: [Data("<!doctype html><html></html>".utf8)]))
    let r = await get("https://img.test/photo.jpg")
    XCTAssertNil(r)
    XCTAssertTrue(files().isEmpty, "nothing cached: \(files())")
  }

  func testUnsupportedImageTypeIsRejected() async {
    // HEIC is not in the accepted set (JPEG, PNG, GIF).
    var heic = Data([0, 0, 0, 0x18])
    heic.append(Data("ftypheic".utf8))
    heic.append(Data(count: 16))
    StubURLProtocol.set("https://img.test/a.heic", .respond(status: 200, headers: ["Content-Type": "image/heic"], chunks: [heic]))
    let r = await get("https://img.test/a.heic")
    XCTAssertNil(r)
    XCTAssertTrue(files().isEmpty)
  }

  func testSignatureDetection() {
    XCTAssertEqual(ImageDownloader.imageType(of: Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10])), "jpg")
    XCTAssertEqual(ImageDownloader.imageType(of: tinyPNG), "png")
    XCTAssertEqual(ImageDownloader.imageType(of: Data("GIF87a..".utf8)), "gif")
    XCTAssertEqual(ImageDownloader.imageType(of: Data("GIF89a..".utf8)), "gif")
    XCTAssertNil(ImageDownloader.imageType(of: Data("<html>".utf8)))
    XCTAssertNil(ImageDownloader.imageType(of: Data([0xFF, 0xD8])))
    XCTAssertNil(ImageDownloader.imageType(of: Data()))
  }

  // MARK: - Cache hit validation

  func testCachedFileOverCurrentMaxBytesIsAMissAndDeleted() async throws {
    var big = tinyPNG
    big.append(Data(count: 500))
    StubURLProtocol.set("https://img.test/big.png", .respond(status: 200, headers: ["Content-Type": "image/png"], chunks: [big]))
    let firstOpt = await get("https://img.test/big.png", maxBytes: 1024)
    let first = try XCTUnwrap(firstOpt)
    let before = StubURLProtocol.requested.count
    let again = await get("https://img.test/big.png", maxBytes: 100)
    XCTAssertNil(again, "the refetch is over the new cap too")
    XCTAssertEqual(StubURLProtocol.requested.count, before + 1, "stale oversize hit must not be served")
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
  }

  func testCachedNonImageFileFromOlderVersionIsAMiss() async throws {
    let url = "https://img.test/old.jpg"
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let stale = dir.appendingPathComponent("push_notifications_img_\(ImageDownloader.sha256(url)).jpg")
    try Data("<html>login</html>".utf8).write(to: stale)
    StubURLProtocol.set(url, .respond(status: 200, headers: ["Content-Type": "image/jpeg"], chunks: [tinyPNG]))
    let rOpt = await get(url)
    let r = try XCTUnwrap(rOpt)
    XCTAssertEqual(r.pathExtension, "png")
    XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
  }

  // MARK: - Pruning

  private func makeFile(_ name: String, age: TimeInterval, now: Date) throws -> URL {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let u = dir.appendingPathComponent(name)
    try tinyPNG.write(to: u)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: u.path)
    return u
  }

  func testPruneDropsFilesOlderThanMaxAgeButNeverTheKeptFile() throws {
    let now = Date()
    let day: TimeInterval = 24 * 3600
    let old = try makeFile("push_notifications_img_old.png", age: 8 * day, now: now)
    let fresh = try makeFile("push_notifications_img_fresh.png", age: 1 * day, now: now)
    let keptOld = try makeFile("push_notifications_img_kept.png", age: 30 * day, now: now)
    ImageDownloader.pruneCache(directory: dir, keeping: keptOld, now: now)
    XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: keptOld.path))
  }

  func testPruneKeepsAtMostMaxFilesNewestFirst() throws {
    let now = Date()
    var made: [URL] = []
    for i in 0..<55 {
      made.append(try makeFile("push_notifications_img_\(i).png", age: TimeInterval(i * 60), now: now))
    }
    // The oldest file is the one just written: it must survive.
    let kept = made[54]
    ImageDownloader.pruneCache(directory: dir, keeping: kept, now: now)
    XCTAssertEqual(files().count, 50)
    XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
    for i in 0..<49 { XCTAssertTrue(FileManager.default.fileExists(atPath: made[i].path), "\(i)") }
    for i in 49..<54 { XCTAssertFalse(FileManager.default.fileExists(atPath: made[i].path), "\(i)") }
  }

  func testPruneOnMissingDirectoryDoesNotThrow() {
    ImageDownloader.pruneCache(directory: dir.appendingPathComponent("nope"), keeping: nil, now: Date())
  }

  func testDownloadPrunesExpiredFiles() async throws {
    let old = try makeFile("push_notifications_img_expired.png", age: 8 * 24 * 3600, now: Date())
    StubURLProtocol.set("https://img.test/new.png", .respond(status: 200, headers: ["Content-Type": "image/png"], chunks: [tinyPNG]))
    let rOpt = await get("https://img.test/new.png")
    let r = try XCTUnwrap(rOpt)
    XCTAssertTrue(FileManager.default.fileExists(atPath: r.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
  }

  func testCacheHitRefreshesModificationDateSoPruningIsLRU() async throws {
    StubURLProtocol.set("https://img.test/hot.png", .respond(status: 200, headers: ["Content-Type": "image/png"], chunks: [tinyPNG]))
    let firstOpt = await get("https://img.test/hot.png")
    let hot = try XCTUnwrap(firstOpt)
    let now = Date()
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2 * 24 * 3600)], ofItemAtPath: hot.path)
    let hitOpt = await get("https://img.test/hot.png")
    XCTAssertEqual(hitOpt, hot)
    let mtime = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: hot.path)[.modificationDate] as? Date)
    XCTAssertLessThan(abs(mtime.timeIntervalSinceNow), 60, "hit refreshed the mtime")

    // Newer-than-before files exist; the recently used one survives a prune.
    let a = try makeFile("push_notifications_img_a.png", age: 3600, now: now)
    let b = try makeFile("push_notifications_img_b.png", age: 7200, now: now)
    ImageDownloader.pruneCache(directory: dir, keeping: nil, now: now, maxFiles: 2)
    XCTAssertTrue(FileManager.default.fileExists(atPath: hot.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
  }
}

import CryptoKit
import Foundation

/// Seam over [ImageDownloader] so the service extension can be tested.
public protocol ImageDownloading: AnyObject {
  /// A local file holding the image, or `nil` on any failure.
  func download(url: String, timeout: TimeInterval, maxBytes: Int64, httpsOnly: Bool) async -> URL?
}

/// Downloads notification images into a temp-dir cache keyed by a hash of the
/// URL. Every failure yields `nil` so callers fall back to text-only:
/// malformed url, disallowed scheme (also on redirects), non-2xx status,
/// timeout, body over `maxBytes` (declared or streamed), empty body, or bytes
/// that are not JPEG, PNG or GIF (sniffed from the content; the MIME type and
/// URL path are not trusted). The cache is bounded: after each write it keeps
/// at most [maxCachedFiles] files and drops files older than [maxCacheAge].
public final class ImageDownloader: ImageDownloading {
  /// Shared instance caching in `<tmp>/push_notifications_images`.
  public static let shared = ImageDownloader(
    cacheDirectory: FileManager.default.temporaryDirectory
      .appendingPathComponent("push_notifications_images", isDirectory: true))

  private static let prefix = "push_notifications_img_"
  private let cacheDirectory: URL
  private let configuration: URLSessionConfiguration

  public init(cacheDirectory: URL, configuration: URLSessionConfiguration = .ephemeral) {
    self.cacheDirectory = cacheDirectory
    self.configuration = configuration
  }

  public func download(url: String, timeout: TimeInterval, maxBytes: Int64, httpsOnly: Bool) async -> URL? {
    guard let parsed = Self.parse(url) else { return fail("malformed url") }
    guard Self.isAllowed(parsed, httpsOnly: httpsOnly) else { return fail("url not allowed") }
    let key = Self.prefix + Self.sha256(url)
    if let cached = cachedFile(key, maxBytes: maxBytes) { return cached }

    let config = configuration.copy() as! URLSessionConfiguration
    let t = max(timeout, 0.001)
    config.timeoutIntervalForRequest = t
    config.timeoutIntervalForResource = t
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.urlCache = nil

    let fetch = Fetch(maxBytes: maxBytes, httpsOnly: httpsOnly)
    let session = URLSession(configuration: config, delegate: fetch, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let result = await fetch.run(session: session, url: parsed, timeout: t)
    guard case .success(let data, _) = result else {
      if case .failure(let reason) = result { return fail(reason) }
      return nil
    }
    // Only the signature decides: a wrong MIME plus an image-looking URL
    // path must not get an HTML page cached under a `.jpg` name.
    guard let ext = Self.imageType(of: data) else {
      return fail("not a JPEG, PNG or GIF")
    }
    do {
      try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
      let target = cacheDirectory.appendingPathComponent("\(key).\(ext)")
      let part = cacheDirectory.appendingPathComponent("\(key).\(UUID().uuidString).part")
      try data.write(to: part)
      do {
        if FileManager.default.fileExists(atPath: target.path) {
          _ = try FileManager.default.replaceItemAt(target, withItemAt: part)
        } else {
          try FileManager.default.moveItem(at: part, to: target)
        }
      } catch {
        try? FileManager.default.removeItem(at: part)
        throw error
      }
      Self.pruneCache(directory: cacheDirectory, keeping: target, now: Date())
      return target
    } catch {
      return fail("write failed: \(error)")
    }
  }

  /// A cached file for `key`, re-validated on every hit: it must fit the
  /// current `maxBytes` and still carry the signature its extension claims
  /// (files cached by older versions may not). A stale file is deleted and
  /// treated as a miss; a valid hit gets a fresh modification date.
  private func cachedFile(_ key: String, maxBytes: Int64) -> URL? {
    let fm = FileManager.default
    let names = (try? fm.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []
    for name in names where name.hasPrefix(key + ".") && !name.hasSuffix(".part") {
      let u = cacheDirectory.appendingPathComponent(name)
      let size = (try? fm.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value ?? 0
      if size > 0, size <= maxBytes, let head = Self.head(of: u), Self.imageType(of: head) == u.pathExtension {
        // Touch on use: pruning drops the least recently used files first.
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
        return u
      }
      try? fm.removeItem(at: u)
    }
    return nil
  }

  private static func head(of file: URL) -> Data? {
    guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? h.close() }
    return try? h.read(upToCount: 4)
  }

  private func fail(_ reason: String) -> URL? {
    NSLog("push_notifications: image download skipped: \(reason)")
    return nil
  }

  // MARK: - Rules

  /// https always; http only when `httpsOnly` is false; nothing else.
  static func isAllowed(_ url: URL, httpsOnly: Bool) -> Bool {
    let scheme = url.scheme?.lowercased()
    return scheme == "https" || (!httpsOnly && scheme == "http")
  }

  static func parse(_ s: String) -> URL? {
    guard let c = URLComponents(string: s), let host = c.host, !host.isEmpty, c.scheme != nil else {
      return nil
    }
    return c.url
  }

  /// Extension for the accepted image types, from the content signature
  /// only: JPEG (`FF D8 FF`), PNG (`89 50 4E 47`), GIF (`GIF8`). Anything
  /// else (an HTML error page served with an image MIME or `.jpg` path) is nil.
  static func imageType(of data: Data) -> String? {
    let b = [UInt8](data.prefix(4))
    if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
    if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
    if b.starts(with: Array("GIF8".utf8)) { return "gif" }
    return nil
  }

  /// Cache bounds applied after every write.
  public static let maxCachedFiles = 50
  public static let maxCacheAge: TimeInterval = 7 * 24 * 3600

  /// Deletes cached images older than `maxAge`, then the oldest beyond
  /// `maxFiles`. `keeping` (the file just written) is never deleted and
  /// counts toward `maxFiles`. In-flight `.part` files are only removed by
  /// age. Never throws; every failure is ignored.
  static func pruneCache(
    directory: URL, keeping: URL?, now: Date,
    maxFiles: Int = maxCachedFiles, maxAge: TimeInterval = maxCacheAge,
    fileManager fm: FileManager = .default
  ) {
    guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
    let keptName = keeping?.lastPathComponent
    var live: [(url: URL, date: Date)] = []
    for name in names where name.hasPrefix(prefix) && name != keptName {
      let u = directory.appendingPathComponent(name)
      guard let attrs = try? fm.attributesOfItem(atPath: u.path),
        (attrs[.type] as? FileAttributeType) == .typeRegular
      else { continue }
      let date = (attrs[.modificationDate] as? Date) ?? .distantPast
      if now.timeIntervalSince(date) > maxAge {
        try? fm.removeItem(at: u)
      } else if !name.hasSuffix(".part") {
        live.append((u, date))
      }
    }
    let budget = max(0, maxFiles - (keptName == nil ? 0 : 1))
    guard live.count > budget else { return }
    live.sort { $0.date > $1.date }
    for victim in live[budget...] { try? fm.removeItem(at: victim.url) }
  }

  static func sha256(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

/// One download: enforces the redirect policy, status, size cap and deadline.
private final class Fetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  enum Result {
    case success(Data, String?)
    case failure(String)
  }

  private let maxBytes: Int64
  private let httpsOnly: Bool
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Result, Never>?
  private var finished = false
  private var data = Data()
  private var mime: String?
  private var failure: String?

  init(maxBytes: Int64, httpsOnly: Bool) {
    self.maxBytes = maxBytes
    self.httpsOnly = httpsOnly
  }

  func run(session: URLSession, url: URL, timeout: TimeInterval) async -> Result {
    await withCheckedContinuation { c in
      lock.lock()
      continuation = c
      lock.unlock()
      let task = session.dataTask(with: url)
      // Hard deadline for the whole transfer, independent of URLSession's.
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self, weak task] in
        task?.cancel()
        self?.finish(.failure("timeout"))
      }
      task.resume()
    }
  }

  private func finish(_ r: Result) {
    lock.lock()
    guard !finished, let c = continuation else {
      lock.unlock()
      return
    }
    finished = true
    continuation = nil
    lock.unlock()
    c.resume(returning: r)
  }

  private func reject(_ task: URLSessionTask, _ reason: String) {
    lock.lock()
    if failure == nil { failure = reason }
    lock.unlock()
    task.cancel()
    finish(.failure(reason))
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let u = request.url, ImageDownloader.isAllowed(u, httpsOnly: httpsOnly) else {
      completionHandler(nil)
      reject(task, "redirect not allowed")
      return
    }
    completionHandler(request)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      completionHandler(.cancel)
      reject(dataTask, "http \((response as? HTTPURLResponse)?.statusCode ?? -1)")
      return
    }
    if response.expectedContentLength > maxBytes {
      completionHandler(.cancel)
      reject(dataTask, "content-length over cap")
      return
    }
    lock.lock()
    mime = http.value(forHTTPHeaderField: "Content-Type") ?? response.mimeType
    lock.unlock()
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
    lock.lock()
    data.append(chunk)
    let over = Int64(data.count) > maxBytes
    lock.unlock()
    if over { reject(dataTask, "body over cap") }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let reason = failure
    let body = data
    let type = mime
    let status = (task.response as? HTTPURLResponse)?.statusCode
    lock.unlock()
    if let reason { return finish(.failure(reason)) }
    if let error { return finish(.failure("network: \(error.localizedDescription)")) }
    guard let status, (200...299).contains(status) else {
      return finish(.failure("http \(status ?? -1)"))
    }
    if body.isEmpty { return finish(.failure("empty body")) }
    finish(.success(body, type))
  }
}

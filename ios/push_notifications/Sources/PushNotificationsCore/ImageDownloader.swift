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
/// timeout, body over `maxBytes` (declared or streamed), empty body, or a type
/// `UNNotificationAttachment` would not accept.
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
    if let cached = cachedFile(key) { return cached }

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
    guard case .success(let data, let mime) = result else {
      if case .failure(let reason) = result { return fail(reason) }
      return nil
    }
    guard let ext = Self.fileExtension(mime: mime, url: parsed, data: data) else {
      return fail("unsupported image type")
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
      return target
    } catch {
      return fail("write failed: \(error)")
    }
  }

  private func cachedFile(_ key: String) -> URL? {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []
    for name in names where name.hasPrefix(key + ".") && !name.hasSuffix(".part") {
      let u = cacheDirectory.appendingPathComponent(name)
      let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value ?? 0
      if size > 0 { return u }
    }
    return nil
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

  /// Extension `UNNotificationAttachment` accepts, from the MIME type, then
  /// the URL path, then the file signature.
  static func fileExtension(mime: String?, url: URL, data: Data) -> String? {
    let byMime: [String: String] = [
      "image/jpeg": "jpg", "image/jpg": "jpg", "image/pjpeg": "jpg", "image/png": "png",
      "image/gif": "gif", "image/heic": "heic", "image/heif": "heic",
    ]
    if let m = mime?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(),
      let ext = byMime[m]
    {
      return ext
    }
    let byPath: [String: String] = ["jpg": "jpg", "jpeg": "jpg", "png": "png", "gif": "gif", "heic": "heic"]
    if let ext = byPath[url.pathExtension.lowercased()] { return ext }
    let b = [UInt8](data.prefix(12))
    if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
    if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
    if b.starts(with: Array("GIF8".utf8)) { return "gif" }
    if b.count >= 12, Array(b[4..<8]) == Array("ftyp".utf8),
      ["heic", "heix", "mif1", "msf1"].contains(String(decoding: b[8..<12], as: UTF8.self))
    {
      return "heic"
    }
    return nil
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

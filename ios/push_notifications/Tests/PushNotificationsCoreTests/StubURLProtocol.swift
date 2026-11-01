import Foundation

/// In-process HTTP stub so downloader tests never touch the network.
/// Routes are keyed by absolute URL string.
final class StubURLProtocol: URLProtocol {
  enum Route {
    /// Status, headers, body chunks (sent one after another).
    case respond(status: Int, headers: [String: String], chunks: [Data])
    /// 302 to the given location.
    case redirect(to: String)
    /// Never answers (for timeouts).
    case hang
  }

  private static let lock = NSLock()
  private static var routes: [String: Route] = [:]
  private static var hits: [String] = []

  static func set(_ url: String, _ route: Route) {
    lock.lock()
    routes[url] = route
    lock.unlock()
  }

  static func reset() {
    lock.lock()
    routes = [:]
    hits = []
    lock.unlock()
  }

  static var requested: [String] {
    lock.lock()
    defer { lock.unlock() }
    return hits
  }

  static func configuration() -> URLSessionConfiguration {
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [StubURLProtocol.self]
    return c
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let url = request.url!.absoluteString
    Self.lock.lock()
    Self.hits.append(url)
    let route = Self.routes[url]
    Self.lock.unlock()
    switch route {
    case .none:
      client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
    case .hang:
      break
    case .redirect(let location):
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
        headerFields: ["Location": location])!
      var next = URLRequest(url: URL(string: location)!)
      next.httpMethod = request.httpMethod
      client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
      // Finished when the client cancels or follows the redirect.
      client?.urlProtocolDidFinishLoading(self)
    case .respond(let status, let headers, let chunks):
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      for c in chunks { client?.urlProtocol(self, didLoad: c) }
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}

/// 1x1 transparent PNG.
let tinyPNG = Data(
  base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
)!

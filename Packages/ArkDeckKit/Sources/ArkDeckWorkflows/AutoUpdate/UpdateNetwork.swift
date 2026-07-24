import Foundation

public enum UpdateNetworkError: Error, Equatable, Sendable {
  case invalidInitialURL
  case invalidRequest
  case invalidResponse
  case httpStatus(Int)
  case responseTooLarge
  case redirectLimitExceeded
  case redirectRejected
}

public enum UpdateNetworkContract {
  public static let productionFeedURL =
    "https://github.com/ArkDeck/ArkDeck/releases/latest/download/"
    + "arkdeck-update-feed-v1.json"
  public static let acceptHeader = "application/vnd.arkdeck.update-feed.v1+json"
  public static let userAgentHeader = "ArkDeck-Update/1"
  public static let maximumRedirects = 5
  public static let allowedHosts: Set<String> = [
    "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com",
  ]
  public static let productQueryNames: Set<String> = ["appVersion", "osVersion", "arch"]
}

public struct UpdateProductIdentity: Equatable, Sendable {
  public let appVersion: String
  public let osVersion: String
  public let architecture: String

  public init(appVersion: String, osVersion: String, architecture: String) {
    self.appVersion = appVersion
    self.osVersion = osVersion
    self.architecture = architecture
  }
}

public enum UpdateRequestFactory {
  public static func feedRequest(identity: UpdateProductIdentity) throws -> URLRequest {
    guard var components = URLComponents(string: UpdateNetworkContract.productionFeedURL) else {
      throw UpdateNetworkError.invalidInitialURL
    }
    components.queryItems = [
      URLQueryItem(name: "appVersion", value: identity.appVersion),
      URLQueryItem(name: "osVersion", value: identity.osVersion),
      URLQueryItem(name: "arch", value: identity.architecture),
    ]
    guard let url = components.url else { throw UpdateNetworkError.invalidInitialURL }
    return try request(url: url)
  }

  public static func artifactRequest(signedURL: String) throws -> URLRequest {
    guard let url = URL(string: signedURL), url.absoluteString == signedURL else {
      throw UpdateNetworkError.invalidInitialURL
    }
    try UpdateRedirectPolicy.validate(url)
    return try request(url: url)
  }

  public static func request(url: URL) throws -> URLRequest {
    try UpdateRedirectPolicy.validate(url)
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
    request.httpMethod = "GET"
    request.httpBody = nil
    request.httpShouldHandleCookies = false
    request.setValue(UpdateNetworkContract.acceptHeader, forHTTPHeaderField: "Accept")
    request.setValue(UpdateNetworkContract.userAgentHeader, forHTTPHeaderField: "User-Agent")
    return request
  }
}

public enum UpdateRedirectPolicy {
  public static func redirectedRequest(
    proposed: URLRequest,
    redirectCount: Int
  ) throws -> URLRequest {
    guard redirectCount <= UpdateNetworkContract.maximumRedirects,
      let proposedURL = proposed.url
    else {
      throw redirectCount > UpdateNetworkContract.maximumRedirects
        ? UpdateNetworkError.redirectLimitExceeded : UpdateNetworkError.redirectRejected
    }
    guard var components = URLComponents(url: proposedURL, resolvingAgainstBaseURL: false) else {
      throw UpdateNetworkError.redirectRejected
    }
    let sanitizedItems = components.queryItems?.filter {
      !UpdateNetworkContract.productQueryNames.contains($0.name)
    }
    components.queryItems = sanitizedItems
    guard let sanitizedURL = components.url else {
      throw UpdateNetworkError.redirectRejected
    }
    try validate(sanitizedURL)
    return try UpdateRequestFactory.request(url: sanitizedURL)
  }

  public static func validate(_ url: URL) throws {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme == "https", components.user == nil, components.password == nil,
      components.fragment == nil, components.port == nil,
      let host = components.host?.lowercased(),
      UpdateNetworkContract.allowedHosts.contains(host), !isIPAddress(host)
    else { throw UpdateNetworkError.redirectRejected }
  }

  private static func isIPAddress(_ host: String) -> Bool {
    if host.contains(":") { return true }
    let components = host.split(separator: ".")
    return components.count == 4 && components.allSatisfy { UInt8($0) != nil }
  }
}

public protocol UpdateHTTPStreaming: Sendable {
  func stream(
    for request: URLRequest,
    maximumBytes: UInt64
  ) -> AsyncThrowingStream<Data, any Error>
}

/// An ephemeral, cookie-free URLSession transport. The delegate validates every redirect before
/// URLSession can follow it and emits bounded response chunks to the update state machine.
public final class URLSessionUpdateHTTPStreamer: UpdateHTTPStreaming, @unchecked Sendable {
  private let protocolClasses: [AnyClass]?

  public init(protocolClasses: [AnyClass]? = nil) {
    self.protocolClasses = protocolClasses
  }

  public func stream(
    for request: URLRequest,
    maximumBytes: UInt64
  ) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
      let configuration = URLSessionConfiguration.ephemeral
      configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
      configuration.urlCache = nil
      configuration.httpCookieStorage = nil
      configuration.httpShouldSetCookies = false
      configuration.httpAdditionalHeaders = [:]
      if let protocolClasses { configuration.protocolClasses = protocolClasses }

      let delegate = UpdateStreamingDelegate(
        maximumBytes: maximumBytes, continuation: continuation)
      let session = URLSession(
        configuration: configuration, delegate: delegate, delegateQueue: nil)
      delegate.attach(session: session)
      let task = session.dataTask(with: request)
      continuation.onTermination = { @Sendable _ in
        task.cancel()
        session.invalidateAndCancel()
      }
      task.resume()
    }
  }
}

private final class UpdateStreamingDelegate: NSObject, URLSessionDataDelegate,
  @unchecked Sendable
{
  private let maximumBytes: UInt64
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let lock = NSLock()
  private weak var session: URLSession?
  private var redirectCount = 0
  private var receivedBytes: UInt64 = 0
  private var terminal = false

  init(
    maximumBytes: UInt64,
    continuation: AsyncThrowingStream<Data, any Error>.Continuation
  ) {
    self.maximumBytes = maximumBytes
    self.continuation = continuation
  }

  func attach(session: URLSession) {
    lock.withLock { self.session = session }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    do {
      let nextCount = lock.withLock {
        redirectCount += 1
        return redirectCount
      }
      completionHandler(
        try UpdateRedirectPolicy.redirectedRequest(
          proposed: request, redirectCount: nextCount))
    } catch {
      finish(throwing: error)
      completionHandler(nil)
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let response = response as? HTTPURLResponse else {
      finish(throwing: UpdateNetworkError.invalidResponse)
      completionHandler(.cancel)
      return
    }
    guard response.statusCode == 200 else {
      finish(throwing: UpdateNetworkError.httpStatus(response.statusCode))
      completionHandler(.cancel)
      return
    }
    if response.expectedContentLength > 0,
      UInt64(response.expectedContentLength) > maximumBytes
    {
      finish(throwing: UpdateNetworkError.responseTooLarge)
      completionHandler(.cancel)
      return
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let accepted = lock.withLock {
      guard !terminal, UInt64(data.count) <= maximumBytes - min(maximumBytes, receivedBytes) else {
        return false
      }
      receivedBytes += UInt64(data.count)
      return true
    }
    guard accepted else {
      finish(throwing: UpdateNetworkError.responseTooLarge)
      dataTask.cancel()
      return
    }
    continuation.yield(data)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    if let error {
      finish(throwing: error)
    } else {
      finish()
    }
  }

  private func finish(throwing error: (any Error)? = nil) {
    let shouldFinish = lock.withLock {
      guard !terminal else { return false }
      terminal = true
      return true
    }
    guard shouldFinish else { return }
    if let error {
      continuation.finish(throwing: error)
    } else {
      continuation.finish()
    }
    session?.finishTasksAndInvalidate()
  }
}

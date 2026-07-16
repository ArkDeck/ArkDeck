import CoreFoundation
import Darwin
import Foundation

public struct ActivationRequest: Codable, Equatable, Sendable {
  public let requestID: String
  public let productIdentifier: String
  public let userIdentifier: String

  public init(
    requestID: String = UUID().uuidString,
    productIdentifier: String,
    userIdentifier: String = String(geteuid())
  ) {
    self.requestID = requestID
    self.productIdentifier = productIdentifier
    self.userIdentifier = userIdentifier
  }
}

public enum ActivationDelivery: String, Codable, Equatable, Sendable {
  case activated
  case duplicate
  case activationFailed
  case rejected
  case unavailable
  case requestTooLarge
  case invalidResponse
}

public protocol ActivationRequestSending: Sendable {
  func requestActivation() -> ActivationDelivery
}

/// Bounded request/reply client for `PORT-ACTIVATION-001`. Endpoint presence
/// never grants writer authority; only `SingleInstanceGuard` can do that.
public struct MacOSActivationRequestSender: ActivationRequestSending, Sendable {
  public let request: ActivationRequest
  public let timeout: TimeInterval

  public init(
    productIdentifier: String,
    userIdentifier: String = String(geteuid()),
    requestID: String = UUID().uuidString,
    timeout: TimeInterval = 1
  ) {
    request = ActivationRequest(
      requestID: requestID,
      productIdentifier: productIdentifier,
      userIdentifier: userIdentifier
    )
    self.timeout = timeout.isFinite ? min(max(timeout, 0.05), 5) : 1
  }

  public func requestActivation() -> ActivationDelivery {
    guard let payload = try? JSONEncoder().encode(request) else {
      return .invalidResponse
    }
    guard payload.count <= 4_096 else {
      return .requestTooLarge
    }
    guard
      let port = CFMessagePortCreateRemote(
        nil,
        MacOSActivationListener.portName(
          productIdentifier: request.productIdentifier,
          userIdentifier: request.userIdentifier
        ) as CFString
      )
    else {
      return .unavailable
    }

    var response: Unmanaged<CFData>?
    let result = CFMessagePortSendRequest(
      port,
      1,
      payload as CFData,
      timeout,
      timeout,
      CFRunLoopMode.defaultMode.rawValue,
      &response
    )
    guard result == kCFMessagePortSuccess, let response else {
      return .unavailable
    }
    let data = response.takeRetainedValue() as Data
    return (try? JSONDecoder().decode(ActivationDelivery.self, from: data)) ?? .invalidResponse
  }
}

/// Main-instance activation listener. It validates product/user, remembers a
/// bounded set of request IDs, and calls the activation handler at most once
/// for every request ID.
public final class MacOSActivationListener: @unchecked Sendable {
  public typealias Handler = @Sendable () -> Bool

  private let productIdentifier: String
  private let userIdentifier: String
  private let handler: Handler
  private let lock = NSLock()
  private var processedRequestFilter: BoundedRequestIDFilter
  private var messagePort: CFMessagePort?
  private var messagePortContext: ActivationMessagePortContext?
  private var runLoopSource: CFRunLoopSource?
  private var runLoop: CFRunLoop?

  public init(
    productIdentifier: String,
    userIdentifier: String = String(geteuid()),
    deduplicationBitCount: Int = 8_192,
    handler: @escaping Handler
  ) {
    self.productIdentifier = productIdentifier
    self.userIdentifier = userIdentifier
    processedRequestFilter = BoundedRequestIDFilter(bitCount: deduplicationBitCount)
    self.handler = handler
  }

  deinit {
    stop()
  }

  public func start(on runLoop: CFRunLoop = CFRunLoopGetCurrent()) throws {
    lock.lock()
    defer { lock.unlock() }
    guard messagePort == nil else { return }

    let contextBox = ActivationMessagePortContext(listener: self)
    var context = CFMessagePortContext(
      version: 0,
      info: Unmanaged.passUnretained(contextBox).toOpaque(),
      retain: { info in
        guard let info else { return nil }
        _ = Unmanaged<ActivationMessagePortContext>.fromOpaque(info).retain()
        return info
      },
      release: { info in
        guard let info else { return }
        Unmanaged<ActivationMessagePortContext>.fromOpaque(info).release()
      },
      copyDescription: nil
    )
    var shouldFreeInfo = DarwinBoolean(false)
    guard
      let port = CFMessagePortCreateLocal(
        nil,
        Self.portName(
          productIdentifier: productIdentifier,
          userIdentifier: userIdentifier
        ) as CFString,
        activationMessagePortCallback,
        &context,
        &shouldFreeInfo
      )
    else {
      throw ActivationListenerError.endpointUnavailable
    }
    guard !shouldFreeInfo.boolValue else {
      throw ActivationListenerError.endpointUnavailable
    }
    guard let source = CFMessagePortCreateRunLoopSource(nil, port, 0) else {
      CFMessagePortInvalidate(port)
      throw ActivationListenerError.endpointUnavailable
    }
    CFRunLoopAddSource(runLoop, source, .defaultMode)
    messagePort = port
    messagePortContext = contextBox
    runLoopSource = source
    self.runLoop = runLoop
  }

  public func stop() {
    lock.lock()
    let port = messagePort
    let source = runLoopSource
    let loop = runLoop
    let context = messagePortContext
    messagePort = nil
    messagePortContext = nil
    runLoopSource = nil
    runLoop = nil
    lock.unlock()

    if let source, let loop {
      CFRunLoopRemoveSource(loop, source, .defaultMode)
    }
    if let port {
      CFMessagePortInvalidate(port)
    }
    withExtendedLifetime(context) {}
  }

  public func receive(_ data: Data) -> ActivationDelivery {
    guard data.count <= 4_096,
      let request = try? JSONDecoder().decode(ActivationRequest.self, from: data),
      request.productIdentifier == productIdentifier,
      request.userIdentifier == userIdentifier,
      !request.requestID.isEmpty,
      !productIdentifier.isEmpty,
      !userIdentifier.isEmpty
    else {
      return .rejected
    }

    lock.lock()
    guard processedRequestFilter.insertIfNew(request.requestID) else {
      lock.unlock()
      return .duplicate
    }
    lock.unlock()

    return handler() ? .activated : .activationFailed
  }

  fileprivate static func portName(
    productIdentifier: String,
    userIdentifier: String
  ) -> String {
    let product = productIdentifier.unicodeScalars.map { scalar in
      CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
    }.joined()
    let user = userIdentifier.unicodeScalars.map { scalar in
      CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
    }.joined()
    return "dev.arkdeck.activation.\(product.prefix(80)).\(user.prefix(32))"
  }
}

/// A fixed-size, fail-closed deduplication filter. False positives may suppress
/// an activation request, but a repeated request ID can never activate twice.
private struct BoundedRequestIDFilter {
  private var words: [UInt64]
  private let bitCount: Int

  init(bitCount: Int) {
    let boundedCount = min(max(bitCount, 64), 65_536)
    self.bitCount = ((boundedCount + 63) / 64) * 64
    words = Array(repeating: 0, count: self.bitCount / 64)
  }

  mutating func insertIfNew(_ value: String) -> Bool {
    let first = Int(fnv1a(value.utf8, seed: 14_695_981_039_346_656_037) % UInt64(bitCount))
    let second = Int(
      fnv1a(value.utf8, seed: 7_809_847_782_465_536_322) % UInt64(bitCount)
    )
    let firstSet = contains(first)
    let secondSet = contains(second)
    set(first)
    set(second)
    return !(firstSet && secondSet)
  }

  private func contains(_ index: Int) -> Bool {
    words[index / 64] & (UInt64(1) << UInt64(index % 64)) != 0
  }

  private mutating func set(_ index: Int) {
    words[index / 64] |= UInt64(1) << UInt64(index % 64)
  }

  private func fnv1a<S: Sequence>(_ bytes: S, seed: UInt64) -> UInt64 where S.Element == UInt8 {
    bytes.reduce(seed) { hash, byte in
      (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
  }
}

public enum ActivationListenerError: Error, Equatable, Sendable {
  case endpointUnavailable
}

private final class ActivationMessagePortContext {
  weak var listener: MacOSActivationListener?

  init(listener: MacOSActivationListener) {
    self.listener = listener
  }
}

private func activationMessagePortCallback(
  _: CFMessagePort?,
  _: Int32,
  data: CFData?,
  info: UnsafeMutableRawPointer?
) -> Unmanaged<CFData>? {
  guard let data, let info else { return nil }
  let context = Unmanaged<ActivationMessagePortContext>.fromOpaque(info).takeUnretainedValue()
  guard let listener = context.listener else { return nil }
  let delivery = listener.receive(data as Data)
  guard let encoded = try? JSONEncoder().encode(delivery) else { return nil }
  return Unmanaged.passRetained(encoded as CFData)
}

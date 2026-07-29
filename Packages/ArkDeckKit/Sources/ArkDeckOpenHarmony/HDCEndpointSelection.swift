// HDC server endpoint selection (source, selection, selector).
//
// Pure move out of HDCProduction.swift (CHG-2026-047 T06): bytes are
// unchanged apart from this header and the shared import block. The
// dispatch-security core (semantic bindings, prepared commands, dispatch
// permits, lifecycle executor) deliberately stays in HDCProduction.swift:
// its private/fileprivate web is a load-bearing anti-forgery boundary.

import ArkDeckProcess
import CryptoKit
import Darwin
import Foundation

public enum HDCServerEndpointSource: String, Sendable, Equatable {
  case explicit
  case inheritedEnvironment
  case `default`
}

public enum HDCServerEndpointSelectionError: Error, Sendable, Equatable {
  case invalidExplicitEndpoint(String)
  case invalidInheritedPort(String)
}

public struct HDCServerEndpointSelection: Sendable, Equatable {
  public static let defaultPort = 8710

  public let endpoint: HDCServerEndpoint
  public let source: HDCServerEndpointSource
  public let childEnvironment: [String: String]

  public init(
    endpoint: HDCServerEndpoint,
    source: HDCServerEndpointSource,
    childEnvironment: [String: String]
  ) {
    self.endpoint = endpoint
    self.source = source
    self.childEnvironment = childEnvironment
  }

  /// `OHOS_HDC_SERVER_PORT` selects only a port. Preserve an explicitly
  /// selected host as well by binding endpoint-sensitive read-only probes to
  /// the registered `-s <endpoint>` form.
  func argumentsForEndpointSensitiveProbe(_ arguments: [String]) -> [String] {
    guard source == .explicit else { return arguments }
    return ["-s", endpoint.rawValue] + arguments
  }
}

public enum HDCServerEndpointSelector {
  /// Explicit endpoint wins, followed by the inherited HDC port, then the
  /// documented default.  The inherited environment is an input snapshot, not
  /// a global process mutation.
  public static func select(
    explicitEndpoint: String? = nil,
    inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> HDCServerEndpointSelection {
    if let explicitEndpoint {
      guard let port = port(in: explicitEndpoint) else {
        throw HDCServerEndpointSelectionError.invalidExplicitEndpoint(explicitEndpoint)
      }
      return HDCServerEndpointSelection(
        endpoint: HDCServerEndpoint(explicitEndpoint),
        source: .explicit,
        childEnvironment: ["OHOS_HDC_SERVER_PORT": String(port)]
      )
    }

    if let inheritedPort = inheritedEnvironment["OHOS_HDC_SERVER_PORT"] {
      guard let port = validPort(inheritedPort) else {
        throw HDCServerEndpointSelectionError.invalidInheritedPort(inheritedPort)
      }
      return HDCServerEndpointSelection(
        endpoint: HDCServerEndpoint("127.0.0.1:\(port)"),
        source: .inheritedEnvironment,
        childEnvironment: ["OHOS_HDC_SERVER_PORT": String(port)]
      )
    }

    return HDCServerEndpointSelection(
      endpoint: HDCServerEndpoint("127.0.0.1:\(HDCServerEndpointSelection.defaultPort)"),
      source: .default,
      childEnvironment: ["OHOS_HDC_SERVER_PORT": String(HDCServerEndpointSelection.defaultPort)]
    )
  }

  private static func port(in endpoint: String) -> Int? {
    guard !endpoint.contains("\0"),
      let separator = endpoint.lastIndex(of: ":"),
      separator != endpoint.startIndex,
      separator < endpoint.index(before: endpoint.endIndex)
    else { return nil }
    return validPort(String(endpoint[endpoint.index(after: separator)...]))
  }

  private static func validPort(_ value: String) -> Int? {
    guard let port = Int(value), (1...65_535).contains(port) else { return nil }
    return port
  }
}

/// Module-internal process request. The public HDC surface never exposes an
/// argv-bearing command: production callers use only registered probes with
/// their required identity preconditions, while lifecycle argv is assembled
/// only by the confirmed executor. Legacy `checkserver`/`-v` entry points stay
/// internal for package compatibility contracts.
/// It intentionally has no fallback to PATH or a settings object.

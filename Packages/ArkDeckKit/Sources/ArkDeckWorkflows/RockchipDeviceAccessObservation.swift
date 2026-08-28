import ArkForgeClient
import ArkForgeProtocol
import Foundation

/// Read-only, redacted RockUSB discovery. No identity, socket path, execution
/// session or capability crosses the App boundary.
public protocol RockchipDeviceAccessObserving: Sendable {
  func observeDeviceAccess() throws -> [RockchipDeviceMode]
}

/// Runs in Runtime, outside App Sandbox, against the composed ArkForge lane's
/// public discovery socket. IOKit presence alone is not an access observation.
package struct ProductRockchipDeviceAccessObserver: RockchipDeviceAccessObserving {
  private let discover: @Sendable () throws -> [ArkForgeDeviceObservation]

  package init(runtimeDirectory: URL) {
    let socketPath = runtimeDirectory.appending(path: "public.sock").path
    discover = {
      let client = try ArkForgePublicClient(socketPath: socketPath, timeoutSeconds: 15)
      return try client.discoverDevices(
        requestID: "runtime-device-access-\(UUID().uuidString.lowercased())")
    }
  }

  init(discover: @escaping @Sendable () throws -> [ArkForgeDeviceObservation]) {
    self.discover = discover
  }

  package func observeDeviceAccess() throws -> [RockchipDeviceMode] {
    try discover().compactMap { observation in
      switch observation.mode {
      case "rockusb-loader", "loader": .loader
      case "rockusb-maskrom", "maskrom": .maskrom
      default: nil
      }
    }
  }
}

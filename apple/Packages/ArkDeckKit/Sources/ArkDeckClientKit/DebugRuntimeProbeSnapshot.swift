import Foundation

// The debug probe's read models. The probe itself stays in Workflows, next to
// the device providers it drives (docs/ArchitectureRules.md).

public enum DebugRuntimeCommandTemplate: String, Codable, CaseIterable, Sendable {
  case packageInventory = "device.packageInventory"
  case debugParameterRead = "device.debugParameterRead"
  case windowInventory = "device.windowInventory"
  case uptime = "device.uptime"

  /// The closed remote command tokens after the connect-key selector. This
  /// table is the single owner of what each template runs: the legacy direct
  /// probe, the `debug.template@1` Catalog operation and the CLI disclosure
  /// all read it, so a member cannot drift between the three.
  public var remoteCommand: [String] {
    switch self {
    case .packageInventory: return ["shell", "bm", "dump", "-a"]
    case .debugParameterRead: return ["shell", "param", "get", "persist.ace.debug.enabled"]
    case .windowInventory: return ["shell", "hidumper", "-s", "WindowManagerService", "-a", "-a"]
    case .uptime: return ["shell", "uptime"]
    }
  }

  /// The stdout budget the template's output must fit in; a larger answer
  /// is a truncated, failed read rather than a partial success.
  public var outputByteBudget: Int {
    switch self {
    case .packageInventory: return 2 * 1024 * 1024
    case .debugParameterRead: return 4 * 1024
    case .windowInventory: return 8 * 1024 * 1024
    case .uptime: return 16 * 1024
    }
  }

  public var title: String {
    switch self {
    case .packageInventory: return "Installed package inventory"
    case .debugParameterRead: return "ACE debug parameter readback"
    case .windowInventory: return "Window manager inventory"
    case .uptime: return "Device uptime"
    }
  }
}

public enum DebugRuntimePortDirection: String, Codable, Sendable {
  case forward
  case reverse
}

public struct DebugRuntimePortRule: Codable, Sendable, Equatable {
  public let direction: DebugRuntimePortDirection
  public let localPort: Int
  public let remotePort: Int

  public init(direction: DebugRuntimePortDirection, localPort: Int, remotePort: Int) {
    self.direction = direction
    self.localPort = localPort
    self.remotePort = remotePort
  }
}

public struct DebugRuntimeProbeSnapshot: Codable, Sendable, Equatable {
  public let targetID: String
  public let bindingRevision: Int
  public let packages: [String]
  public let portRules: [DebugRuntimePortRule]
  public let warnings: [String]

  public init(
    targetID: String,
    bindingRevision: Int,
    packages: [String],
    portRules: [DebugRuntimePortRule],
    warnings: [String]
  ) {
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.packages = packages
    self.portRules = portRules
    self.warnings = warnings
  }
}

/// A target-bound, read-only Debug portrait. The caller can choose only one
/// of the closed templates above; executable discovery, connect key and argv
/// lowering remain daemon-owned. It never creates a RuntimeCapability.

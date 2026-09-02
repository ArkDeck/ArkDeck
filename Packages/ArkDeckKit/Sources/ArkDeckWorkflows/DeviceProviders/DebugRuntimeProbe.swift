import ArkDeckCore
import CryptoKit
import Foundation

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

public struct DebugRuntimeCommandResult: Codable, Sendable, Equatable {
  public let targetID: String
  public let bindingRevision: Int
  public let templateID: String
  public let effect: String
  public let executable: String
  public let executableSHA256: String
  public let argumentDisclosure: [String]
  public let loweringSHA256: String
  public let exitCode: Int?
  public let durationMilliseconds: Int
  public let stdout: String
  public let stderr: String
  public let outputTruncated: Bool

  public init(
    targetID: String,
    bindingRevision: Int,
    templateID: String,
    effect: String,
    executable: String,
    executableSHA256: String,
    argumentDisclosure: [String],
    loweringSHA256: String,
    exitCode: Int?,
    durationMilliseconds: Int,
    stdout: String,
    stderr: String,
    outputTruncated: Bool
  ) {
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.templateID = templateID
    self.effect = effect
    self.executable = executable
    self.executableSHA256 = executableSHA256
    self.argumentDisclosure = argumentDisclosure
    self.loweringSHA256 = loweringSHA256
    self.exitCode = exitCode
    self.durationMilliseconds = durationMilliseconds
    self.stdout = stdout
    self.stderr = stderr
    self.outputTruncated = outputTruncated
  }
}

/// A target-bound, read-only Debug portrait. The caller can choose only one
/// of the closed templates above; executable discovery, connect key and argv
/// lowering remain daemon-owned. It never creates a RuntimeCapability.
public protocol DebugRuntimeProbing: Sendable {
  func probeDebugRuntime(targetID: String) async throws -> DebugRuntimeProbeSnapshot
  func runDebugTemplate(
    targetID: String, template: DebugRuntimeCommandTemplate
  ) async throws -> DebugRuntimeCommandResult
}

package struct FoundationDebugRuntimeProbe: DebugRuntimeProbing {
  private struct PackageObservation: Sendable {
    let packages: [String]
    let warnings: [String]
  }

  private struct PortObservation: Sendable {
    let rules: [DebugRuntimePortRule]
    let warnings: [String]
  }

  private let targetStore: RuntimeTargetStore
  private let hdcResolver: any RuntimeExecutableResolving
  private let runner: any RockchipRuntimeCommandRunning

  package init(
    targetStore: RuntimeTargetStore,
    hdcResolver: any RuntimeExecutableResolving,
    workingDirectory: URL
  ) {
    self.init(
      targetStore: targetStore,
      hdcResolver: hdcResolver,
      runner: FoundationRockchipRuntimeCommandRunner(workingDirectory: workingDirectory))
  }

  init(
    targetStore: RuntimeTargetStore,
    hdcResolver: any RuntimeExecutableResolving,
    runner: any RockchipRuntimeCommandRunning
  ) {
    self.targetStore = targetStore
    self.hdcResolver = hdcResolver
    self.runner = runner
  }

  package func probeDebugRuntime(
    targetID: String
  ) async throws -> DebugRuntimeProbeSnapshot {
    let route = try requireRoute(targetID)
    let hdc = try hdcResolver.resolveExecutable(providerID: "hdc")
    // Package and port inventories are independent, target-bound read-only
    // commands. Preserve their presentation order while allowing HDC to run
    // all three clients concurrently.
    async let packageObservation = probePackages(hdc, route: route)
    async let forwardObservation = probePortRules(
      hdc, route: route, direction: .forward, verb: "fport")
    async let reverseObservation = probePortRules(
      hdc, route: route, direction: .reverse, verb: "rport")
    let (package, forward, reverse) = await (
      packageObservation, forwardObservation, reverseObservation
    )

    return DebugRuntimeProbeSnapshot(
      targetID: route.targetID,
      bindingRevision: route.bindingRevision,
      packages: package.packages.sorted(),
      portRules: forward.rules + reverse.rules,
      warnings: package.warnings + forward.warnings + reverse.warnings)
  }

  private func probePackages(
    _ executable: ResolvedExecutable,
    route: RuntimeTargetHDCRoute
  ) async -> PackageObservation {
    do {
      let receipt = try await run(
        executable, route: route, command: ["shell", "bm", "dump", "-a"],
        byteBudget: 2 * 1024 * 1024)
      guard receipt.exitStatus == 0, !receipt.stdoutTruncated else {
        return PackageObservation(packages: [], warnings: ["packageInventoryUnavailable"])
      }
      let packages = Self.packageNames(receipt.stdout)
      let warnings =
        packages.isEmpty && !receipt.stdout.isEmpty
        ? ["packageInventoryUnparseable"] : []
      return PackageObservation(packages: packages, warnings: warnings)
    } catch {
      return PackageObservation(packages: [], warnings: ["packageInventoryUnavailable"])
    }
  }

  private func probePortRules(
    _ executable: ResolvedExecutable,
    route: RuntimeTargetHDCRoute,
    direction: DebugRuntimePortDirection,
    verb: String
  ) async -> PortObservation {
    do {
      let receipt = try await run(
        executable, route: route, command: [verb, "ls"], byteBudget: 128 * 1024)
      guard receipt.exitStatus == 0, !receipt.stdoutTruncated else {
        return PortObservation(
          rules: [], warnings: ["\(direction.rawValue)RulesUnavailable"])
      }
      return PortObservation(
        rules: Self.portRules(receipt.stdout, direction: direction), warnings: [])
    } catch {
      return PortObservation(
        rules: [], warnings: ["\(direction.rawValue)RulesUnavailable"])
    }
  }

  package func runDebugTemplate(
    targetID: String,
    template: DebugRuntimeCommandTemplate
  ) async throws -> DebugRuntimeCommandResult {
    let route = try requireRoute(targetID)
    let hdc = try hdcResolver.resolveExecutable(providerID: "hdc")
    let command = template.remoteCommand
    let budget = template.outputByteBudget
    let exactArguments = deviceArguments(route: route, command: command)
    let receipt = try await runner.run(
      executable: hdc, arguments: exactArguments,
      timeoutSeconds: 30, outputByteBudget: budget,
      criticalNonInterruptible: false)
    guard let stdout = String(data: receipt.stdout, encoding: .utf8),
      let stderr = String(data: receipt.stderr, encoding: .utf8)
    else {
      throw DeviceProviderError.factsUnavailable(
        "Debug read-only template output is not UTF-8")
    }
    var disclosure = exactArguments
    if disclosure.count >= 2, disclosure[0] == "-t" {
      disclosure[1] = "<redacted-connect-key>"
    }
    let loweringBytes = Data(
      ([hdc.sha256] + exactArguments).joined(separator: "\u{0}").utf8)
    let loweringSHA256 = SHA256Hex.string(of: loweringBytes)
    return DebugRuntimeCommandResult(
      targetID: route.targetID,
      bindingRevision: route.bindingRevision,
      templateID: template.rawValue,
      effect: "readOnly",
      executable: "hdc",
      executableSHA256: hdc.sha256,
      argumentDisclosure: disclosure,
      loweringSHA256: loweringSHA256,
      exitCode: receipt.exitStatus.map(Int.init),
      durationMilliseconds: Int((receipt.durationSeconds * 1_000).rounded()),
      stdout: stdout,
      stderr: stderr,
      outputTruncated: receipt.stdoutTruncated)
  }

  private func requireRoute(_ targetID: String) throws -> RuntimeTargetHDCRoute {
    guard let route = try targetStore.hdcExecutionRoute(targetID: targetID) else {
      throw DeviceProviderError.factsUnavailable("target \(targetID) has not been adopted")
    }
    return route
  }

  private func deviceArguments(route: RuntimeTargetHDCRoute, command: [String]) -> [String] {
    ["-t", route.connectKey] + command
  }

  private func run(
    _ executable: ResolvedExecutable,
    route: RuntimeTargetHDCRoute,
    command: [String],
    byteBudget: Int
  ) async throws -> ProviderSubprocessReceipt {
    let receipt = try await runner.run(
      executable: executable,
      arguments: deviceArguments(route: route, command: command),
      timeoutSeconds: 30,
      outputByteBudget: byteBudget,
      criticalNonInterruptible: false)
    try HDCReadOnlyProbeReceiptValidation.requireNoSemanticFailure(
      receipt, context: "Debug read-only probe failed")
    return receipt
  }

  static func packageNames(_ data: Data) -> [String] {
    guard let text = String(data: data, encoding: .utf8) else { return [] }
    let pattern = #"^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$"#
    return Array(
      Set(
        text.split(whereSeparator: \Character.isNewline).compactMap { line -> String? in
          let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
          return value.range(of: pattern, options: .regularExpression) != nil ? value : nil
        }))
  }

  static func portRules(
    _ data: Data,
    direction: DebugRuntimePortDirection
  ) -> [DebugRuntimePortRule] {
    guard let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(whereSeparator: \Character.isNewline).compactMap { line in
      let ports = line.split(whereSeparator: \Character.isWhitespace).compactMap { token -> Int? in
        let value = String(token)
        guard value.hasPrefix("tcp:"), let port = Int(value.dropFirst(4)),
          (1_024...65_535).contains(port)
        else { return nil }
        return port
      }
      guard ports.count >= 2 else { return nil }
      return DebugRuntimePortRule(
        direction: direction, localPort: ports[0], remotePort: ports[1])
    }
  }
}

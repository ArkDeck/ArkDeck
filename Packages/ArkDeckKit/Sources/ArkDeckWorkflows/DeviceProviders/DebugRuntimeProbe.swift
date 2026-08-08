import CryptoKit
import Foundation

public enum DebugRuntimeCommandTemplate: String, Codable, CaseIterable, Sendable {
  case packageInventory = "device.packageInventory"
  case debugParameterRead = "device.debugParameterRead"
  case windowInventory = "device.windowInventory"
  case uptime = "device.uptime"
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
    let target = try requireTarget(targetID)
    let hdc = try hdcResolver.resolveExecutable(providerID: "hdc")
    var packages: [String] = []
    var portRules: [DebugRuntimePortRule] = []
    var warnings: [String] = []

    do {
      let receipt = try await run(
        hdc, target: target, command: ["shell", "bm", "dump", "-a"], byteBudget: 2 * 1024 * 1024)
      if receipt.exitStatus == 0, !receipt.stdoutTruncated {
        packages = Self.packageNames(receipt.stdout)
        if packages.isEmpty, !receipt.stdout.isEmpty {
          warnings.append("packageInventoryUnparseable")
        }
      } else {
        warnings.append("packageInventoryUnavailable")
      }
    } catch {
      warnings.append("packageInventoryUnavailable")
    }

    for (direction, verb) in [
      (DebugRuntimePortDirection.forward, "fport"),
      (DebugRuntimePortDirection.reverse, "rport"),
    ] {
      do {
        let receipt = try await run(
          hdc, target: target, command: [verb, "ls"], byteBudget: 128 * 1024)
        if receipt.exitStatus == 0, !receipt.stdoutTruncated {
          portRules += Self.portRules(receipt.stdout, direction: direction)
        } else {
          warnings.append("\(direction.rawValue)RulesUnavailable")
        }
      } catch {
        warnings.append("\(direction.rawValue)RulesUnavailable")
      }
    }

    return DebugRuntimeProbeSnapshot(
      targetID: target.targetID,
      bindingRevision: target.bindingRevision,
      packages: packages.sorted(),
      portRules: portRules,
      warnings: warnings)
  }

  package func runDebugTemplate(
    targetID: String,
    template: DebugRuntimeCommandTemplate
  ) async throws -> DebugRuntimeCommandResult {
    let target = try requireTarget(targetID)
    let hdc = try hdcResolver.resolveExecutable(providerID: "hdc")
    let command: [String]
    let budget: Int
    switch template {
    case .packageInventory:
      command = ["shell", "bm", "dump", "-a"]
      budget = 2 * 1024 * 1024
    case .debugParameterRead:
      command = ["shell", "param", "get", "persist.ace.debug.enabled"]
      budget = 4 * 1024
    case .windowInventory:
      command = ["shell", "hidumper", "-s", "WindowManagerService", "-a", "-a"]
      budget = 8 * 1024 * 1024
    case .uptime:
      command = ["shell", "uptime"]
      budget = 16 * 1024
    }
    let exactArguments = deviceArguments(target: target, command: command)
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
    let loweringSHA256 = SHA256.hash(data: loweringBytes)
      .map { String(format: "%02x", $0) }.joined()
    return DebugRuntimeCommandResult(
      targetID: target.targetID,
      bindingRevision: target.bindingRevision,
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

  private func requireTarget(_ targetID: String) throws -> RuntimeTargetRecord {
    guard let target = try targetStore.find(targetID: targetID) else {
      throw DeviceProviderError.factsUnavailable("target \(targetID) has not been adopted")
    }
    return target
  }

  private func deviceArguments(target: RuntimeTargetRecord, command: [String]) -> [String] {
    ["-t", target.connectKey] + command
  }

  private func run(
    _ executable: ResolvedExecutable,
    target: RuntimeTargetRecord,
    command: [String],
    byteBudget: Int
  ) async throws -> ProviderSubprocessReceipt {
    let receipt = try await runner.run(
      executable: executable,
      arguments: deviceArguments(target: target, command: command),
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
          (1...65_535).contains(port)
        else { return nil }
        return port
      }
      guard ports.count >= 2 else { return nil }
      return DebugRuntimePortRule(
        direction: direction, localPort: ports[0], remotePort: ports[1])
    }
  }
}

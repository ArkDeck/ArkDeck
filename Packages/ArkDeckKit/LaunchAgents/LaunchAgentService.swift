import CryptoKit
import Darwin
import Foundation

public enum ArkDeckLaunchAgent {
  public static let label = "com.arkdeck.agentd"
  public static let hdcEnvironmentKey = "ARKDECK_HDC_PATH"
}

public struct LaunchAgentCommandResult: Sendable, Equatable {
  public let exitStatus: Int32
  public let stdout: Data
  public let stderr: Data

  public init(exitStatus: Int32, stdout: Data = Data(), stderr: Data = Data()) {
    self.exitStatus = exitStatus
    self.stdout = stdout
    self.stderr = stderr
  }
}

/// Runs the fixed `/bin/launchctl` executable with an argument array. The
/// service manager has no shell surface and never constructs a device command.
public protocol LaunchAgentCommandRunning: Sendable {
  func run(arguments: [String]) throws -> LaunchAgentCommandResult
}

public struct FoundationLaunchAgentCommandRunner: LaunchAgentCommandRunning {
  public init() {}

  public func run(arguments: [String]) throws -> LaunchAgentCommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    return LaunchAgentCommandResult(
      exitStatus: process.terminationStatus,
      stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
      stderr: stderr.fileHandleForReading.readDataToEndOfFile())
  }
}

public struct LaunchAgentPaths: Sendable, Equatable {
  public let homeDirectory: URL
  public let plist: URL
  public let installedDaemon: URL
  public let receipt: URL
  public let logDirectory: URL
  public let standardOutput: URL
  public let standardError: URL
  public let stateDirectory: URL
  public let socket: URL

  public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.homeDirectory = homeDirectory.standardizedFileURL
    let library = self.homeDirectory.appendingPathComponent("Library", isDirectory: true)
    let support = library.appendingPathComponent(
      "Application Support/ArkDeck", isDirectory: true)
    self.plist = library.appendingPathComponent(
      "LaunchAgents/\(ArkDeckLaunchAgent.label).plist")
    self.installedDaemon = support.appendingPathComponent("bin/arkdeck-agentd")
    self.receipt = support.appendingPathComponent("LaunchAgent/install-receipt.json")
    self.logDirectory = library.appendingPathComponent("Logs/ArkDeck", isDirectory: true)
    self.standardOutput = self.logDirectory.appendingPathComponent("agentd.log")
    self.standardError = self.logDirectory.appendingPathComponent("agentd.error.log")
    self.stateDirectory = support.appendingPathComponent("Agentd", isDirectory: true)
    self.socket = self.stateDirectory.appendingPathComponent("agentd.sock")
  }
}

public struct LaunchAgentInstallReceipt: Codable, Sendable, Equatable {
  public let schemaVersion: String
  public let installedAtUTC: String
  public let daemonPath: String
  public let daemonSHA256: String
  public let hdcPath: String
  public let hdcSHA256: String

  public init(
    installedAtUTC: String, daemonPath: String, daemonSHA256: String,
    hdcPath: String, hdcSHA256: String
  ) {
    self.schemaVersion = "arkdeck-launchagent-install/v1"
    self.installedAtUTC = installedAtUTC
    self.daemonPath = daemonPath
    self.daemonSHA256 = daemonSHA256
    self.hdcPath = hdcPath
    self.hdcSHA256 = hdcSHA256
  }
}

public struct LaunchAgentStatus: Codable, Sendable, Equatable {
  public let installed: Bool
  public let loaded: Bool
  public let launchDomain: String
  public let plistPath: String
  public let daemonPath: String?
  public let daemonSHA256: String?
  public let hdcPath: String?
  public let hdcSHA256: String?
  public let socketPath: String
  public let socketPresent: Bool
  public let standardOutputPath: String
  public let standardErrorPath: String
  public let diagnostics: [String]
  public let ready: Bool
}

public struct LaunchAgentRemoval: Codable, Sendable, Equatable {
  public let removedPlist: Bool
  public let removedDaemon: Bool
  public let removedReceipt: Bool
  public let preservedStateDirectory: String
  public let preservedLogDirectory: String
}

public enum LaunchAgentServiceError: Error, CustomStringConvertible, Equatable {
  case invalidExecutable(String)
  case invalidTemplate(String)
  case launchctl(String)
  case configuration(String)

  public var description: String {
    switch self {
    case .invalidExecutable(let detail): return "invalid executable: \(detail)"
    case .invalidTemplate(let detail): return "invalid LaunchAgent template: \(detail)"
    case .launchctl(let detail): return "launchctl failed: \(detail)"
    case .configuration(let detail): return "LaunchAgent configuration failed: \(detail)"
    }
  }
}

public final class LaunchAgentService: @unchecked Sendable {
  private static let daemonToken = "__ARKDECK_AGENTD_EXECUTABLE__"
  private static let hdcToken = "__ARKDECK_HDC_EXECUTABLE__"
  private static let stdoutToken = "__ARKDECK_AGENTD_STDOUT__"
  private static let stderrToken = "__ARKDECK_AGENTD_STDERR__"

  private let paths: LaunchAgentPaths
  private let runner: any LaunchAgentCommandRunning
  private let fileManager: FileManager
  private let uid: uid_t
  private let nowUTC: @Sendable () -> String

  public init(
    paths: LaunchAgentPaths = LaunchAgentPaths(),
    runner: any LaunchAgentCommandRunning = FoundationLaunchAgentCommandRunner(),
    fileManager: FileManager = .default,
    uid: uid_t = geteuid(),
    nowUTC: @escaping @Sendable () -> String = LaunchAgentService.utcNow
  ) {
    self.paths = paths
    self.runner = runner
    self.fileManager = fileManager
    self.uid = uid
    self.nowUTC = nowUTC
  }

  public var launchDomain: String { "gui/\(uid)" }

  @discardableResult
  public func install(daemonSource: URL, hdcExecutable: URL) throws -> LaunchAgentInstallReceipt {
    let daemonSource = try validatedExecutable(daemonSource, name: "arkdeck-agentd")
    let hdcExecutable = try validatedExecutable(hdcExecutable, name: "HDC")
    let daemonSHA256 = try sha256(daemonSource)
    let hdcSHA256 = try sha256(hdcExecutable)

    try createOwnedDirectory(paths.plist.deletingLastPathComponent())
    try createOwnedDirectory(paths.installedDaemon.deletingLastPathComponent())
    try createOwnedDirectory(paths.receipt.deletingLastPathComponent())
    try createOwnedDirectory(paths.logDirectory)

    if try isLoaded() {
      try requireSuccess(
        runner.run(arguments: ["bootout", launchDomain + "/" + ArkDeckLaunchAgent.label]),
        operation: "bootout")
    }

    if daemonSource.path != paths.installedDaemon.path {
      let staging = paths.installedDaemon.deletingLastPathComponent()
        .appendingPathComponent(".arkdeck-agentd-\(UUID().uuidString)")
      defer { try? fileManager.removeItem(at: staging) }
      try fileManager.copyItem(at: daemonSource, to: staging)
      try fileManager.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: staging.path)
      try replaceItem(at: paths.installedDaemon, with: staging)
    }

    let renderedPlist = try renderTemplate(
      daemonPath: paths.installedDaemon.path,
      hdcPath: hdcExecutable.path,
      stdoutPath: paths.standardOutput.path,
      stderrPath: paths.standardError.path)
    try renderedPlist.write(to: paths.plist, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.plist.path)

    let receipt = LaunchAgentInstallReceipt(
      installedAtUTC: nowUTC(), daemonPath: paths.installedDaemon.path,
      daemonSHA256: daemonSHA256, hdcPath: hdcExecutable.path,
      hdcSHA256: hdcSHA256)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    try encoder.encode(receipt).write(to: paths.receipt, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.receipt.path)

    try bootstrap()
    return receipt
  }

  public func uninstall() throws -> LaunchAgentRemoval {
    if try isLoaded() {
      try requireSuccess(
        runner.run(arguments: ["bootout", launchDomain + "/" + ArkDeckLaunchAgent.label]),
        operation: "bootout")
    }
    let removedPlist = try removeIfPresent(paths.plist)
    let removedDaemon = try removeIfPresent(paths.installedDaemon)
    let removedReceipt = try removeIfPresent(paths.receipt)
    return LaunchAgentRemoval(
      removedPlist: removedPlist, removedDaemon: removedDaemon,
      removedReceipt: removedReceipt,
      preservedStateDirectory: paths.stateDirectory.path,
      preservedLogDirectory: paths.logDirectory.path)
  }

  public func status() throws -> LaunchAgentStatus {
    let installed = fileManager.fileExists(atPath: paths.plist.path)
    var diagnostics: [String] = []
    var daemonPath: String?
    var hdcPath: String?
    var daemonSHA256: String?
    var hdcSHA256: String?

    if installed {
      do {
        let configuration = try configuredPaths()
        daemonPath = configuration.daemon
        hdcPath = configuration.hdc
        if configuration.daemon != paths.installedDaemon.path {
          diagnostics.append("ProgramArguments does not name the ArkDeck-managed daemon path")
        }
        do {
          let daemon = try validatedExecutable(
            URL(fileURLWithPath: configuration.daemon), name: "configured arkdeck-agentd")
          if daemon.path != configuration.daemon {
            diagnostics.append("configured daemon path is not canonical")
          }
          daemonSHA256 = try sha256(daemon)
        } catch {
          diagnostics.append("configured arkdeck-agentd is invalid: \(error)")
        }
        do {
          let hdc = try validatedExecutable(
            URL(fileURLWithPath: configuration.hdc), name: "configured HDC")
          if hdc.path != configuration.hdc {
            diagnostics.append("configured HDC path is not canonical")
          }
          hdcSHA256 = try sha256(hdc)
        } catch {
          diagnostics.append("configured HDC is invalid: \(error)")
        }
      } catch {
        diagnostics.append("configuration is invalid: \(error)")
      }

      do {
        let receipt = try JSONDecoder().decode(
          LaunchAgentInstallReceipt.self, from: Data(contentsOf: paths.receipt))
        guard receipt.schemaVersion == "arkdeck-launchagent-install/v1" else {
          throw LaunchAgentServiceError.configuration("unsupported install receipt schema")
        }
        if receipt.daemonPath != daemonPath || receipt.daemonSHA256 != daemonSHA256 {
          diagnostics.append("arkdeck-agentd identity drifted since installation")
        }
        if receipt.hdcPath != hdcPath || receipt.hdcSHA256 != hdcSHA256 {
          diagnostics.append("HDC identity drifted since installation")
        }
      } catch {
        diagnostics.append("install receipt is unavailable or invalid: \(error)")
      }
    } else {
      diagnostics.append("LaunchAgent is not installed")
    }

    let loaded = installed ? try isLoaded() : false
    if installed && !loaded { diagnostics.append("LaunchAgent is not loaded in \(launchDomain)") }
    let socketPresent = fileManager.fileExists(atPath: paths.socket.path)
    if installed && loaded && !socketPresent {
      diagnostics.append(
        "daemon socket is absent; service may still be starting; "
          + "re-run status, then inspect the LaunchAgent error log")
    }
    return LaunchAgentStatus(
      installed: installed, loaded: loaded, launchDomain: launchDomain,
      plistPath: paths.plist.path, daemonPath: daemonPath,
      daemonSHA256: daemonSHA256, hdcPath: hdcPath, hdcSHA256: hdcSHA256,
      socketPath: paths.socket.path, socketPresent: socketPresent,
      standardOutputPath: paths.standardOutput.path,
      standardErrorPath: paths.standardError.path,
      diagnostics: diagnostics,
      ready: installed && loaded && socketPresent && diagnostics.isEmpty)
  }

  private func configuredPaths() throws -> (daemon: String, hdc: String) {
    let data = try Data(contentsOf: paths.plist)
    guard
      let document = try PropertyListSerialization.propertyList(
        from: data, options: [], format: nil) as? [String: Any],
      let arguments = document["ProgramArguments"] as? [String], arguments.count == 1,
      let daemon = arguments.first,
      let environment = document["EnvironmentVariables"] as? [String: String],
      let hdc = environment[ArkDeckLaunchAgent.hdcEnvironmentKey],
      document["Label"] as? String == ArkDeckLaunchAgent.label,
      document["RunAtLoad"] as? Bool == true,
      document["KeepAlive"] as? Bool == true,
      document["LimitLoadToSessionType"] as? String == "Aqua",
      (document["MachServices"] as? [String: Bool])?[ArkDeckLaunchAgent.label] == true,
      document["StandardOutPath"] as? String == paths.standardOutput.path,
      document["StandardErrorPath"] as? String == paths.standardError.path
    else {
      throw LaunchAgentServiceError.configuration(
        "plist must keep the user-session lifecycle, Mach service, log paths, "
          + "one daemon argument and an explicit ARKDECK_HDC_PATH")
    }
    return (daemon, hdc)
  }

  private func renderTemplate(
    daemonPath: String, hdcPath: String, stdoutPath: String, stderrPath: String
  ) throws -> Data {
    guard
      let template = Bundle.module.url(
        forResource: ArkDeckLaunchAgent.label, withExtension: "plist")
    else {
      throw LaunchAgentServiceError.invalidTemplate("bundled plist is missing")
    }
    let data = try Data(contentsOf: template)
    guard
      var document = try PropertyListSerialization.propertyList(
        from: data, options: [], format: nil) as? [String: Any],
      var arguments = document["ProgramArguments"] as? [String],
      arguments == [Self.daemonToken],
      var environment = document["EnvironmentVariables"] as? [String: String],
      environment[ArkDeckLaunchAgent.hdcEnvironmentKey] == Self.hdcToken,
      document["StandardOutPath"] as? String == Self.stdoutToken,
      document["StandardErrorPath"] as? String == Self.stderrToken
    else {
      throw LaunchAgentServiceError.invalidTemplate("placeholder contract drifted")
    }
    arguments[0] = daemonPath
    environment[ArkDeckLaunchAgent.hdcEnvironmentKey] = hdcPath
    document["ProgramArguments"] = arguments
    document["EnvironmentVariables"] = environment
    document["StandardOutPath"] = stdoutPath
    document["StandardErrorPath"] = stderrPath
    return try PropertyListSerialization.data(
      fromPropertyList: document, format: .xml, options: 0)
  }

  private func validatedExecutable(_ candidate: URL, name: String) throws -> URL {
    guard candidate.path.hasPrefix("/") else {
      throw LaunchAgentServiceError.invalidExecutable("\(name) path must be absolute")
    }
    let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
      !isDirectory.boolValue,
      fileManager.isExecutableFile(atPath: canonical.path)
    else {
      throw LaunchAgentServiceError.invalidExecutable(
        "\(name) is missing, is not a regular file, or is not executable: \(canonical.path)")
    }
    return canonical
  }

  private func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url))
      .map { String(format: "%02x", $0) }.joined()
  }

  private func isLoaded() throws -> Bool {
    try runner.run(arguments: ["print", launchDomain + "/" + ArkDeckLaunchAgent.label])
      .exitStatus == 0
  }

  private func requireSuccess(_ result: LaunchAgentCommandResult, operation: String) throws {
    guard result.exitStatus == 0 else {
      let detail = String(decoding: result.stderr, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw LaunchAgentServiceError.launchctl(
        "\(operation) exited \(result.exitStatus)\(detail.isEmpty ? "" : ": \(detail)")")
    }
  }

  /// `bootout` can report success before launchd has finished unregistering
  /// the old service. An immediate `bootstrap` then transiently exits with
  /// EIO. Retry only that exact launchctl status, for a bounded two seconds;
  /// every other configuration or permission failure remains fail-closed on
  /// its first response.
  private func bootstrap() throws {
    let arguments = ["bootstrap", launchDomain, paths.plist.path]
    let maximumAttempts = 20
    for attempt in 1...maximumAttempts {
      let result = try runner.run(arguments: arguments)
      if result.exitStatus == 0 { return }
      guard result.exitStatus == EIO, attempt < maximumAttempts else {
        try requireSuccess(result, operation: "bootstrap")
        return
      }
      usleep(100_000)
    }
  }

  private func createOwnedDirectory(_ url: URL) throws {
    try fileManager.createDirectory(
      at: url, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }

  private func replaceItem(at destination: URL, with staging: URL) throws {
    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
    } else {
      try fileManager.moveItem(at: staging, to: destination)
    }
  }

  private func removeIfPresent(_ url: URL) throws -> Bool {
    guard fileManager.fileExists(atPath: url.path) else { return false }
    try fileManager.removeItem(at: url)
    return true
  }

  public static func utcNow() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date())
  }
}

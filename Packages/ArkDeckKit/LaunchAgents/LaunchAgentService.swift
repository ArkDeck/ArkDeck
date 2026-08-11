import CryptoKit
import Darwin
import Foundation

public enum ArkDeckLaunchAgent {
  public static let label = "com.arkdeck.agentd"
  public static let hdcEnvironmentKey = "ARKDECK_HDC_PATH"
  public static let workspaceProjectsEnvironmentKey = "ARKDECK_WORKSPACE_PROJECTS"
  public static let workspaceActiveProjectEnvironmentKey = "ARKDECK_WORKSPACE_ACTIVE_PROJECT"
  public static let devecoSDKEnvironmentKey = "ARKDECK_DEVECO_SDK_HOME"
  public static let analyzerEnvironmentKey = "ARKDECK_ANALYZER_PATH"
  public static let workspaceInspectorEnvironmentKey = "ARKDECK_WORKSPACE_INSPECTOR"
  public static let harnessSensitiveEvidenceEnvironmentKey =
    "ARKDECK_HARNESS_SENSITIVE_EVIDENCE"
  public static let harnessModelProviderEnvironmentKey =
    "ARKDECK_HARNESS_MODEL_PROVIDER"
  public static let harnessModelNameEnvironmentKey = "ARKDECK_HARNESS_MODEL_NAME"
  public static let harnessCLIPathEnvironmentKey = "ARKDECK_HARNESS_CLI_PATH"
  public static let harnessCLIWorkingDirectoryEnvironmentKey =
    "ARKDECK_HARNESS_CLI_WORKDIR"
  public static let harnessCLITimeoutEnvironmentKey =
    "ARKDECK_HARNESS_CLI_TIMEOUT_SECONDS"
  public static let harnessEgressProjectsEnvironmentKey =
    "ARKDECK_HARNESS_EGRESS_PROJECTS"
  public static let waterFlowProjectRef = "demo-app"
  public static let harnessLocalModelProviders = ["claude-code", "codex"]
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
  public let workspaceProjectPath: String?
  public let devecoSDKPath: String?
  /// Optional keeps receipts written before this setting was productized
  /// decodable; new receipts always write a (possibly empty) sorted array.
  public let harnessSensitiveEvidence: [String]?
  /// Optional keeps receipts written before headless model composition was
  /// productized decodable. Local CLI configuration contains no credential.
  public let harnessModel: LaunchAgentHarnessModelStatus?

  public init(
    installedAtUTC: String, daemonPath: String, daemonSHA256: String,
    hdcPath: String, hdcSHA256: String, workspaceProjectPath: String? = nil,
    devecoSDKPath: String? = nil, harnessSensitiveEvidence: [String] = [],
    harnessModel: LaunchAgentHarnessModelStatus? = nil
  ) {
    self.schemaVersion = "arkdeck-launchagent-install/v1"
    self.installedAtUTC = installedAtUTC
    self.daemonPath = daemonPath
    self.daemonSHA256 = daemonSHA256
    self.hdcPath = hdcPath
    self.hdcSHA256 = hdcSHA256
    self.workspaceProjectPath = workspaceProjectPath
    self.devecoSDKPath = devecoSDKPath
    self.harnessSensitiveEvidence = harnessSensitiveEvidence
    self.harnessModel = harnessModel
  }
}

public struct LaunchAgentWorkspaceConfiguration: Sendable, Equatable {
  public let projectRoot: URL
  public let devecoSDKRoot: URL

  public init(projectRoot: URL, devecoSDKRoot: URL) {
    self.projectRoot = projectRoot
    self.devecoSDKRoot = devecoSDKRoot
  }
}

/// Explicit, credential-free composition for an already signed-in local
/// model CLI. The LaunchAgent never accepts an API key or arbitrary argv.
public struct LaunchAgentHarnessModelConfiguration: Sendable, Equatable {
  public let provider: String
  public let modelName: String
  public let cliExecutable: URL
  public let cliWorkingDirectory: URL
  public let cliTimeoutSeconds: Int

  public init(
    provider: String, modelName: String, cliExecutable: URL,
    cliWorkingDirectory: URL, cliTimeoutSeconds: Int = 600
  ) {
    self.provider = provider
    self.modelName = modelName
    self.cliExecutable = cliExecutable
    self.cliWorkingDirectory = cliWorkingDirectory
    self.cliTimeoutSeconds = cliTimeoutSeconds
  }
}

public struct LaunchAgentHarnessModelStatus: Codable, Sendable, Equatable {
  public let provider: String
  public let modelName: String
  public let cliPath: String
  public let cliSHA256: String
  public let cliWorkingDirectory: String
  public let cliTimeoutSeconds: Int
  public let egressProjects: [String]
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
  public let workspaceProjectPath: String?
  public let devecoSDKPath: String?
  public let harnessSensitiveEvidence: [String]
  public let harnessModel: LaunchAgentHarnessModelStatus?
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
  public func install(
    daemonSource: URL, hdcExecutable: URL,
    workspace: LaunchAgentWorkspaceConfiguration? = nil,
    harnessSensitiveEvidence: [String] = [],
    harnessModel: LaunchAgentHarnessModelConfiguration? = nil,
    beforeBootstrap: (@Sendable () throws -> Void)? = nil
  ) throws -> LaunchAgentInstallReceipt {
    let daemonSource = try validatedExecutable(daemonSource, name: "arkdeck-agentd")
    let hdcExecutable = try validatedExecutable(hdcExecutable, name: "HDC")
    let workspace = try workspace.map(validatedWorkspace)
    let harnessSensitiveEvidence = try validatedSensitiveEvidence(harnessSensitiveEvidence)
    let harnessModel = try harnessModel.map {
      try validatedHarnessModel($0, workspace: workspace)
    }
    let daemonSHA256 = try sha256(daemonSource)
    let hdcSHA256 = try sha256(hdcExecutable)
    let installedDaemonSHA256 = try? sha256(paths.installedDaemon)
    let previousReceipt = try? JSONDecoder().decode(
      LaunchAgentInstallReceipt.self, from: Data(contentsOf: paths.receipt))
    let credentialIdentityChanged = previousReceipt?.daemonSHA256 != daemonSHA256

    try createOwnedDirectory(paths.plist.deletingLastPathComponent())
    try createOwnedDirectory(paths.installedDaemon.deletingLastPathComponent())
    try createOwnedDirectory(paths.receipt.deletingLastPathComponent())
    try createOwnedDirectory(paths.logDirectory)

    if try isLoaded() {
      try requireSuccess(
        runner.run(arguments: ["bootout", launchDomain + "/" + ArkDeckLaunchAgent.label]),
        operation: "bootout")
    }

    if daemonSource.path != paths.installedDaemon.path,
      installedDaemonSHA256 != daemonSHA256
    {
      let staging = paths.installedDaemon.deletingLastPathComponent()
        .appendingPathComponent(".arkdeck-agentd-\(UUID().uuidString)")
      defer { try? fileManager.removeItem(at: staging) }
      try fileManager.copyItem(at: daemonSource, to: staging)
      try fileManager.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: staging.path)
      try replaceItem(at: paths.installedDaemon, with: staging)
      // `replaceItemAt` may preserve the destination's previous mode. Restore
      // the installer contract on the final inode before credential ACLs are
      // refreshed or launchd is allowed to execute it.
    }
    // Reassert the final inode's owner-only contract even when an identical
    // binary update avoids replacement and credential ACL churn.
    try fileManager.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: paths.installedDaemon.path)

    let renderedPlist = try renderTemplate(
      daemonPath: paths.installedDaemon.path,
      hdcPath: hdcExecutable.path,
      stdoutPath: paths.standardOutput.path,
      stderrPath: paths.standardError.path,
      workspace: workspace,
      harnessSensitiveEvidence: harnessSensitiveEvidence,
      harnessModel: harnessModel)
    try renderedPlist.write(to: paths.plist, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.plist.path)

    let receipt = LaunchAgentInstallReceipt(
      installedAtUTC: nowUTC(), daemonPath: paths.installedDaemon.path,
      daemonSHA256: daemonSHA256, hdcPath: hdcExecutable.path,
      hdcSHA256: hdcSHA256,
      workspaceProjectPath: workspace?.projectRoot.path,
      devecoSDKPath: workspace?.devecoSDKRoot.path,
      harnessSensitiveEvidence: harnessSensitiveEvidence,
      harnessModel: harnessModel?.status)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    try encoder.encode(receipt).write(to: paths.receipt, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.receipt.path)

    // Let the CLI compare the replacement's exact SecTrustedApplication
    // binary identity with dependent user-domain credentials after the
    // receipt is durable but before launchd starts the replacement executable.
    if credentialIdentityChanged {
      do {
        try beforeBootstrap?()
      } catch {
        // Credential maintenance is allowed to fail closed for signing, but
        // it must not strand the whole read-only Device Runtime offline after
        // a successful bootout/copy. Start the fully validated replacement
        // before surfacing the maintenance failure to the caller.
        do {
          try bootstrap()
        } catch let recoveryError {
          throw LaunchAgentServiceError.launchctl(
            "credential refresh failed (\(error)); replacement daemon recovery failed (\(recoveryError))")
        }
        throw error
      }
    }
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
    var workspaceProjectPath: String?
    var devecoSDKPath: String?
    var harnessSensitiveEvidence: [String] = []
    var harnessModel: LaunchAgentHarnessModelStatus?

    if installed {
      do {
        let configuration = try configuredPaths()
        daemonPath = configuration.daemon
        hdcPath = configuration.hdc
        workspaceProjectPath = configuration.workspace?.projectRoot.path
        devecoSDKPath = configuration.workspace?.devecoSDKRoot.path
        harnessSensitiveEvidence = configuration.harnessSensitiveEvidence
        harnessModel = configuration.harnessModel?.status
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
        if receipt.workspaceProjectPath != workspaceProjectPath
          || receipt.devecoSDKPath != devecoSDKPath
        {
          diagnostics.append("workspace configuration drifted since installation")
        }
        if (receipt.harnessSensitiveEvidence ?? []) != harnessSensitiveEvidence {
          diagnostics.append("Harness sensitive-evidence opt-in drifted since installation")
        }
        if receipt.harnessModel != harnessModel {
          diagnostics.append("Harness local model configuration drifted since installation")
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
      workspaceProjectPath: workspaceProjectPath, devecoSDKPath: devecoSDKPath,
      harnessSensitiveEvidence: harnessSensitiveEvidence,
      harnessModel: harnessModel,
      socketPath: paths.socket.path, socketPresent: socketPresent,
      standardOutputPath: paths.standardOutput.path,
      standardErrorPath: paths.standardError.path,
      diagnostics: diagnostics,
      ready: installed && loaded && socketPresent && diagnostics.isEmpty)
  }

  private struct ConfiguredPaths {
    let daemon: String
    let hdc: String
    let workspace: LaunchAgentWorkspaceConfiguration?
    let harnessSensitiveEvidence: [String]
    let harnessModel: ValidatedHarnessModel?
  }

  private struct ValidatedHarnessModel {
    let configuration: LaunchAgentHarnessModelConfiguration
    let status: LaunchAgentHarnessModelStatus
  }

  private func configuredPaths() throws -> ConfiguredPaths {
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
    let projectEntry = environment[ArkDeckLaunchAgent.workspaceProjectsEnvironmentKey]
    let activeProject = environment[ArkDeckLaunchAgent.workspaceActiveProjectEnvironmentKey]
    let sdk = environment[ArkDeckLaunchAgent.devecoSDKEnvironmentKey]
    let analyzer = environment[ArkDeckLaunchAgent.analyzerEnvironmentKey]
    let inspector = environment[ArkDeckLaunchAgent.workspaceInspectorEnvironmentKey]
    let harnessSensitiveEvidence = try validatedSensitiveEvidence(
      environment[ArkDeckLaunchAgent.harnessSensitiveEvidenceEnvironmentKey].map {
        $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
      } ?? [])
    let workspaceValues = [projectEntry, activeProject, sdk, analyzer, inspector]
    let workspace: LaunchAgentWorkspaceConfiguration?
    if workspaceValues.allSatisfy({ $0 == nil }) {
      workspace = nil
    } else {
      let prefix = ArkDeckLaunchAgent.waterFlowProjectRef + "="
      guard let projectEntry, projectEntry.hasPrefix(prefix),
        !String(projectEntry.dropFirst(prefix.count)).isEmpty,
        activeProject == ArkDeckLaunchAgent.waterFlowProjectRef,
        let sdk, analyzer == daemon, inspector == "/usr/bin/grep"
      else {
        throw LaunchAgentServiceError.configuration(
          "workspace environment must be the closed demo-app ProjectProfile configuration")
      }
      workspace = try validatedWorkspace(
        LaunchAgentWorkspaceConfiguration(
          projectRoot: URL(fileURLWithPath: String(projectEntry.dropFirst(prefix.count))),
          devecoSDKRoot: URL(fileURLWithPath: sdk)))
    }
    let harnessModel = try configuredHarnessModel(
      environment: environment, workspace: workspace)
    return ConfiguredPaths(
      daemon: daemon, hdc: hdc, workspace: workspace,
      harnessSensitiveEvidence: harnessSensitiveEvidence,
      harnessModel: harnessModel)
  }

  private func renderTemplate(
    daemonPath: String, hdcPath: String, stdoutPath: String, stderrPath: String,
    workspace: LaunchAgentWorkspaceConfiguration?, harnessSensitiveEvidence: [String],
    harnessModel: ValidatedHarnessModel?
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
    if let workspace {
      environment[ArkDeckLaunchAgent.workspaceProjectsEnvironmentKey] =
        ArkDeckLaunchAgent.waterFlowProjectRef + "=" + workspace.projectRoot.path
      environment[ArkDeckLaunchAgent.workspaceActiveProjectEnvironmentKey] =
        ArkDeckLaunchAgent.waterFlowProjectRef
      environment[ArkDeckLaunchAgent.devecoSDKEnvironmentKey] = workspace.devecoSDKRoot.path
      environment[ArkDeckLaunchAgent.analyzerEnvironmentKey] = daemonPath
      environment[ArkDeckLaunchAgent.workspaceInspectorEnvironmentKey] = "/usr/bin/grep"
    }
    if !harnessSensitiveEvidence.isEmpty {
      environment[ArkDeckLaunchAgent.harnessSensitiveEvidenceEnvironmentKey] =
        harnessSensitiveEvidence.joined(separator: ",")
    }
    if let harnessModel {
      environment[ArkDeckLaunchAgent.harnessModelProviderEnvironmentKey] =
        harnessModel.configuration.provider
      environment[ArkDeckLaunchAgent.harnessModelNameEnvironmentKey] =
        harnessModel.configuration.modelName
      environment[ArkDeckLaunchAgent.harnessCLIPathEnvironmentKey] =
        harnessModel.configuration.cliExecutable.path
      environment[ArkDeckLaunchAgent.harnessCLIWorkingDirectoryEnvironmentKey] =
        harnessModel.configuration.cliWorkingDirectory.path
      environment[ArkDeckLaunchAgent.harnessCLITimeoutEnvironmentKey] =
        String(harnessModel.configuration.cliTimeoutSeconds)
      environment[ArkDeckLaunchAgent.harnessEgressProjectsEnvironmentKey] =
        ArkDeckLaunchAgent.waterFlowProjectRef
    }
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

  private func validatedWorkspace(
    _ configuration: LaunchAgentWorkspaceConfiguration
  ) throws -> LaunchAgentWorkspaceConfiguration {
    func directory(_ candidate: URL, name: String) throws -> URL {
      guard candidate.path.hasPrefix("/") else {
        throw LaunchAgentServiceError.configuration("\(name) path must be absolute")
      }
      let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        throw LaunchAgentServiceError.configuration("\(name) directory is absent")
      }
      return canonical
    }
    let project = try directory(configuration.projectRoot, name: "WaterFlow project")
    let protectedRoots = ["Desktop", "Documents", "Downloads"].map {
      paths.homeDirectory.appendingPathComponent($0, isDirectory: true)
        .standardizedFileURL.path
    }
    guard !protectedRoots.contains(where: {
      project.path == $0 || project.path.hasPrefix($0 + "/")
    }) else {
      throw LaunchAgentServiceError.configuration(
        "WaterFlow project cannot be under macOS privacy-managed Desktop, "
          + "Documents or Downloads; use an absolute path under ~/Developer "
          + "or another LaunchAgent-readable directory")
    }
    guard !project.path.contains(","), !project.path.contains("=") else {
      throw LaunchAgentServiceError.configuration(
        "WaterFlow project path cannot contain ',' or '='")
    }
    guard fileManager.fileExists(
      atPath: project.appendingPathComponent("build-profile.json5").path),
      fileManager.fileExists(
        atPath: project.appendingPathComponent("entry/src/main/module.json5").path)
    else {
      throw LaunchAgentServiceError.configuration(
        "WaterFlow project is missing build-profile.json5 or entry/src/main/module.json5")
    }
    let sdk = try directory(configuration.devecoSDKRoot, name: "DevEco SDK")
    var openHarmonyIsDirectory: ObjCBool = false
    guard fileManager.fileExists(
      atPath: sdk.appendingPathComponent("default/openharmony").path,
      isDirectory: &openHarmonyIsDirectory), openHarmonyIsDirectory.boolValue
    else {
      throw LaunchAgentServiceError.configuration(
        "DevEco SDK does not contain default/openharmony")
    }
    return LaunchAgentWorkspaceConfiguration(projectRoot: project, devecoSDKRoot: sdk)
  }

  private func validatedSensitiveEvidence(_ names: [String]) throws -> [String] {
    guard names.count <= 16 else {
      throw LaunchAgentServiceError.configuration(
        "Harness sensitive-evidence opt-in accepts at most 16 artifact names")
    }
    let normalized = Array(Set(names)).sorted()
    guard normalized.count == names.count,
      normalized.allSatisfy({ name in
        !name.isEmpty && name.utf8.count <= 128
          && name.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
            options: .regularExpression) != nil
      })
    else {
      throw LaunchAgentServiceError.configuration(
        "Harness sensitive-evidence opt-in must contain unique safe artifact basenames")
    }
    return normalized
  }

  private func configuredHarnessModel(
    environment: [String: String], workspace: LaunchAgentWorkspaceConfiguration?
  ) throws -> ValidatedHarnessModel? {
    let provider = environment[ArkDeckLaunchAgent.harnessModelProviderEnvironmentKey]
    let model = environment[ArkDeckLaunchAgent.harnessModelNameEnvironmentKey]
    let executable = environment[ArkDeckLaunchAgent.harnessCLIPathEnvironmentKey]
    let workdir = environment[ArkDeckLaunchAgent.harnessCLIWorkingDirectoryEnvironmentKey]
    let timeout = environment[ArkDeckLaunchAgent.harnessCLITimeoutEnvironmentKey]
    let egress = environment[ArkDeckLaunchAgent.harnessEgressProjectsEnvironmentKey]
    let values = [provider, model, executable, workdir, timeout, egress]
    if values.allSatisfy({ $0 == nil }) { return nil }
    guard let provider, let model, let executable, let workdir, let rawTimeout = timeout,
      let timeout = Int(rawTimeout), egress == ArkDeckLaunchAgent.waterFlowProjectRef
    else {
      throw LaunchAgentServiceError.configuration(
        "Harness local model environment must be complete and scoped to demo-app")
    }
    return try validatedHarnessModel(
      LaunchAgentHarnessModelConfiguration(
        provider: provider, modelName: model,
        cliExecutable: URL(fileURLWithPath: executable),
        cliWorkingDirectory: URL(fileURLWithPath: workdir),
        cliTimeoutSeconds: timeout),
      workspace: workspace)
  }

  private func validatedHarnessModel(
    _ configuration: LaunchAgentHarnessModelConfiguration,
    workspace: LaunchAgentWorkspaceConfiguration?
  ) throws -> ValidatedHarnessModel {
    guard let workspace else {
      throw LaunchAgentServiceError.configuration(
        "Harness local model requires the validated demo-app workspace configuration")
    }
    let provider = configuration.provider.lowercased()
    guard ArkDeckLaunchAgent.harnessLocalModelProviders.contains(provider) else {
      throw LaunchAgentServiceError.configuration(
        "Harness local model provider must be codex or claude-code")
    }
    guard configuration.modelName.utf8.count <= 200,
      configuration.modelName.range(
        of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#,
        options: .regularExpression) != nil
    else {
      throw LaunchAgentServiceError.configuration(
        "Harness model name must be a non-empty safe identifier")
    }
    guard (1...900).contains(configuration.cliTimeoutSeconds) else {
      throw LaunchAgentServiceError.configuration(
        "Harness local CLI timeout must be between 1 and 900 seconds")
    }
    let executable = try validatedExecutable(
      configuration.cliExecutable, name: "Harness local model CLI")
    guard configuration.cliWorkingDirectory.path.hasPrefix("/") else {
      throw LaunchAgentServiceError.configuration(
        "Harness local CLI working directory must be absolute")
    }
    let workdir = configuration.cliWorkingDirectory.resolvingSymlinksInPath()
      .standardizedFileURL
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: workdir.path, isDirectory: &isDirectory),
      isDirectory.boolValue, workdir.path == workspace.projectRoot.path
    else {
      throw LaunchAgentServiceError.configuration(
        "Harness local CLI working directory must be the validated demo-app project")
    }
    let normalized = LaunchAgentHarnessModelConfiguration(
      provider: provider, modelName: configuration.modelName,
      cliExecutable: executable, cliWorkingDirectory: workdir,
      cliTimeoutSeconds: configuration.cliTimeoutSeconds)
    return ValidatedHarnessModel(
      configuration: normalized,
      status: LaunchAgentHarnessModelStatus(
        provider: provider, modelName: configuration.modelName,
        cliPath: executable.path, cliSHA256: try sha256(executable),
        cliWorkingDirectory: workdir.path,
        cliTimeoutSeconds: configuration.cliTimeoutSeconds,
        egressProjects: [ArkDeckLaunchAgent.waterFlowProjectRef]))
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

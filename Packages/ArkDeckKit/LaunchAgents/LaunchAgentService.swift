import ArkDeckCore
import ArkForgeClient
import CryptoKit
import Darwin
import Foundation
import Security

public enum ArkDeckLaunchAgent {
  public static let label = "com.arkdeck.agentd"
  public static let hdcEnvironmentKey = "ARKDECK_HDC_PATH"
  public static let workspaceProjectsEnvironmentKey = "ARKDECK_WORKSPACE_PROJECTS"
  public static let workspaceActiveProjectEnvironmentKey = "ARKDECK_WORKSPACE_ACTIVE_PROJECT"
  public static let devecoSDKEnvironmentKey = "ARKDECK_DEVECO_SDK_HOME"
  public static let analyzerEnvironmentKey = "ARKDECK_ANALYZER_PATH"
  public static let workspaceInspectorEnvironmentKey = "ARKDECK_WORKSPACE_INSPECTOR"
  public static let arkTraceDescriptorEnvironmentKey =
    "ARKDECK_ARKTRACE_DESCRIPTOR"
  /// The only release-identity input the ArkForge lane needs. The manifest
  /// below this canonical bundle root binds the daemon and every profile.
  public static let arkForgeBundleEnvironmentKey = "ARKDECK_ARKFORGE_BUNDLE_PATH"
  /// Read-only migration names for one compatibility cycle. New plists never
  /// write them and a mixed old/new configuration is refused.
  public static let arkForgedPathEnvironmentKey = "ARKDECK_ARKFORGED_PATH"
  public static let arkForgedSHA256EnvironmentKey = "ARKDECK_ARKFORGED_SHA256"
  public static let arkForgeProfileEnvironmentKey = "ARKDECK_ARKFORGE_PROFILE_PATH"
  /// The acceptance campaign the lane is authorized to run.
  ///
  /// Outside the required set below on purpose. Those three decide whether a
  /// lane exists; this decides whether it may execute a combination nobody has
  /// verified, which is the larger decision. Unset means `arkforged` publishes
  /// `hardwareGated`, materializes assessments only, and reaches no device.
  public static let arkForgeCampaignEnvironmentKey = "ARKDECK_ARKFORGE_CAMPAIGN"

  /// Every current release-identity key the lane requires. The campaign is an
  /// authorization on a lane, not part of the release unit.
  public static let arkForgeEnvironmentKeys = [arkForgeBundleEnvironmentKey]
  public static let legacyArkForgeEnvironmentKeys = [
    arkForgedPathEnvironmentKey, arkForgedSHA256EnvironmentKey,
    arkForgeProfileEnvironmentKey,
  ]
  public static let waterFlowProjectRef = "demo-app"
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
    process.executableURL = URL(filePath: "/bin/launchctl")
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
  public let installedDaemonBundle: URL
  public let installedDaemon: URL
  public let receipt: URL
  public let logDirectory: URL
  public let standardOutput: URL
  public let standardError: URL
  public let stateDirectory: URL
  public let socket: URL

  public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.homeDirectory = homeDirectory.standardizedFileURL
    let library = self.homeDirectory.appending(path: "Library", directoryHint: .isDirectory)
    let support = library.appending(
      path:
        "Application Support/ArkDeck", directoryHint: .isDirectory)
    self.plist = library.appending(
      path:
        "LaunchAgents/\(ArkDeckLaunchAgent.label).plist")
    self.installedDaemonBundle = support.appending(
      path:
        "Helpers/\(ArkDeckHelperIdentity.daemonBundleName)", directoryHint: .isDirectory)
    self.installedDaemon = self.installedDaemonBundle.appending(
      path:
        "Contents/MacOS/\(ArkDeckHelperIdentity.daemonExecutableName)")
    self.receipt = support.appending(path: "LaunchAgent/install-receipt.json")
    self.logDirectory = library.appending(path: "Logs/ArkDeck", directoryHint: .isDirectory)
    self.standardOutput = self.logDirectory.appending(path: "agentd.log")
    self.standardError = self.logDirectory.appending(path: "agentd.error.log")
    self.stateDirectory = support.appending(path: "Agentd", directoryHint: .isDirectory)
    self.socket = self.stateDirectory.appending(path: "agentd.sock")
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
  /// Optional keeps receipts written before the reviewed ArkTrace profile was
  /// selectable through the production LaunchAgent installer decodable.
  public let arkTraceDescriptor: LaunchAgentArkTraceDescriptorStatus?
  /// Optional keeps v1 receipts written before single-bundle ArkForge
  /// configuration decodable. New receipts pin the manifest digest here.
  public let arkForgeLane: LaunchAgentArkForgeLaneStatus?

  public init(
    installedAtUTC: String, daemonPath: String, daemonSHA256: String,
    hdcPath: String, hdcSHA256: String, workspaceProjectPath: String? = nil,
    devecoSDKPath: String? = nil,
    arkTraceDescriptor: LaunchAgentArkTraceDescriptorStatus? = nil,
    arkForgeLane: LaunchAgentArkForgeLaneStatus? = nil
  ) {
    self.schemaVersion = "arkdeck-launchagent-install/v1"
    self.installedAtUTC = installedAtUTC
    self.daemonPath = daemonPath
    self.daemonSHA256 = daemonSHA256
    self.hdcPath = hdcPath
    self.hdcSHA256 = hdcSHA256
    self.workspaceProjectPath = workspaceProjectPath
    self.devecoSDKPath = devecoSDKPath
    self.arkTraceDescriptor = arkTraceDescriptor
    self.arkForgeLane = arkForgeLane
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

public struct LaunchAgentArkTraceDescriptorStatus: Codable, Sendable, Equatable {
  public let descriptorPath: String
  public let descriptorSHA256: String
  public let descriptorByteCount: Int

  public init(descriptorPath: String, descriptorSHA256: String, descriptorByteCount: Int) {
    self.descriptorPath = descriptorPath
    self.descriptorSHA256 = descriptorSHA256
    self.descriptorByteCount = descriptorByteCount
  }
}

/// The ArkForge lane's installed configuration, as recorded in the receipt.
///
/// One validated ArkForge release unit, as recorded in the receipt.
///
/// The public configuration is only `bundlePath`; the remaining fields are
/// manifest-derived evidence retained so status can detect drift.
public struct LaunchAgentArkForgeLaneStatus: Codable, Sendable, Equatable {
  public static let deviceProfileID = "org.openharmony.dayu200"

  public let bundlePath: String
  public let manifestSHA256: String
  public let daemonPath: String
  public let daemonSHA256: String
  public let deviceProfilePath: String
  /// Empty when no campaign is authorized, which is the normal state.
  public let campaign: String

  public init(
    bundlePath: String, manifestSHA256: String,
    daemonPath: String, daemonSHA256: String, deviceProfilePath: String,
    campaign: String = ""
  ) {
    self.bundlePath = bundlePath
    self.manifestSHA256 = manifestSHA256
    self.daemonPath = daemonPath
    self.daemonSHA256 = daemonSHA256
    self.deviceProfilePath = deviceProfilePath
    self.campaign = campaign
  }

  /// Why a lane configuration was refused. Each names something to fix.
  public enum Refusal: Error, Equatable, CustomStringConvertible {
    case notAbsolute(String)
    case invalidBundle(String)
    case missingProfile(String)
    case mixedLegacyConfiguration
    case partialLegacyConfiguration(missing: [String])
    case crossBundleLegacyConfiguration
    case digestMismatch(path: String, declared: String, measured: String)

    public var description: String {
      switch self {
      case .notAbsolute(let path):
        return "\(path) is not an absolute ArkForge.bundle path"
      case .invalidBundle(let detail):
        return "ArkForge.bundle is invalid: \(detail)"
      case .missingProfile(let id):
        return "ArkForge.bundle does not publish required profile \(id)"
      case .mixedLegacyConfiguration:
        return
          "current ArkForge bundle configuration cannot be mixed with legacy three-key "
          + "configuration"
      case .partialLegacyConfiguration(let missing):
        return
          "legacy ArkForge configuration is partial; missing "
          + missing.joined(separator: ", ")
      case .crossBundleLegacyConfiguration:
        return
          "legacy ArkForge daemon and profile do not resolve to one validated ArkForge.bundle"
      case .digestMismatch(let path, let declared, let measured):
        return
          "\(path) hashes to \(measured) and was declared as \(declared). An unpinned "
          + "executable is one nobody chose"
      }
    }
  }

  /// Resolves and independently verifies every manifest-declared member.
  public static func measuring(
    bundlePath: String,
    campaign: String = ""
  ) throws -> LaunchAgentArkForgeLaneStatus {
    guard bundlePath.hasPrefix("/") else { throw Refusal.notAbsolute(bundlePath) }
    let bundle: ArkForgeReleaseBundle
    do {
      bundle = try ArkForgeReleaseBundleReader.load(
        bundleURL: URL(filePath: bundlePath, directoryHint: .isDirectory))
    } catch {
      throw Refusal.invalidBundle(String(describing: error))
    }
    guard let profile = bundle.profileURLs[deviceProfileID] else {
      throw Refusal.missingProfile(deviceProfileID)
    }
    let daemonDigest = SHA256Hex.string(of: try Data(contentsOf: bundle.daemonURL))

    return LaunchAgentArkForgeLaneStatus(
      bundlePath: bundle.rootURL.path, manifestSHA256: bundle.manifestSHA256,
      daemonPath: bundle.daemonURL.path, daemonSHA256: daemonDigest,
      deviceProfilePath: profile.path,
      campaign: campaign.trimmingCharacters(in: .whitespaces))
  }

  /// The environment the daemon is started with.
  public var environment: [String: String] {
    var out = [ArkDeckLaunchAgent.arkForgeBundleEnvironmentKey: bundlePath]
    // Written only when authorized. An empty value in the plist would read as
    // an unnamed campaign, and an unnamed campaign is one nobody can be held
    // to a result on.
    if !campaign.isEmpty {
      out[ArkDeckLaunchAgent.arkForgeCampaignEnvironmentKey] = campaign
    }
    return out
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
  public let workspaceProjectPath: String?
  public let devecoSDKPath: String?
  public let arkTraceDescriptor: LaunchAgentArkTraceDescriptorStatus?
  public let arkForgeLane: LaunchAgentArkForgeLaneStatus?
  public let socketPath: String
  public let socketPresent: Bool
  public let standardOutputPath: String
  public let standardErrorPath: String
  public let diagnostics: [String]
  public let ready: Bool
}

/// The daemon-owned process identity written before its UDS starts accepting
/// requests. The LaunchAgent client reads this only to prove that a restart
/// produced a distinct process; it is never an authority for device work.
public struct LaunchAgentDaemonInstance: Codable, Sendable, Equatable {
  public let pid: Int32
  public let socketPath: String
  public let protocolVersion: String
  public let startedAtUTC: String
}

/// Receipt for a configuration-preserving LaunchAgent restart.
///
/// Restart never copies a helper, rewrites the plist/install receipt or
/// touches Runtime state. The CLI separately proves the replacement process
/// is reachable and speaks the same catalog before reporting success.
public struct LaunchAgentRestartReceipt: Codable, Sendable, Equatable {
  public let schemaVersion: String
  public let restartedAtUTC: String
  public let launchDomain: String
  public let plistPath: String
  public let daemonPath: String
  public let daemonSHA256: String
  public let hdcSHA256: String
  public let preservedStateDirectory: String
  public let preservedLogDirectory: String
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
  private let daemonBundleValidator: (URL) throws -> URL

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
    self.daemonBundleValidator = { candidate in
      try LaunchAgentService.validateProductionDaemonBundle(
        candidate, fileManager: fileManager)
    }
  }

  package init(
    paths: LaunchAgentPaths, runner: any LaunchAgentCommandRunning,
    fileManager: FileManager = .default, uid: uid_t,
    nowUTC: @escaping @Sendable () -> String,
    daemonBundleValidator: @escaping (URL) throws -> URL
  ) {
    self.paths = paths
    self.runner = runner
    self.fileManager = fileManager
    self.uid = uid
    self.nowUTC = nowUTC
    self.daemonBundleValidator = daemonBundleValidator
  }

  public var launchDomain: String { "gui/\(uid)" }

  @discardableResult
  public func install(
    daemonBundleSource: URL, hdcExecutable: URL,
    workspace: LaunchAgentWorkspaceConfiguration? = nil,
    beforeBootstrap: (@Sendable () throws -> Void)? = nil
  ) throws -> LaunchAgentInstallReceipt {
    try install(
      daemonBundleSource: daemonBundleSource, hdcExecutable: hdcExecutable,
      workspace: workspace, arkTraceDescriptor: nil, arkForgeLane: nil,
      beforeBootstrap: beforeBootstrap)
  }

  @discardableResult
  public func install(
    daemonBundleSource: URL, hdcExecutable: URL,
    workspace: LaunchAgentWorkspaceConfiguration? = nil,
    arkTraceDescriptor: URL?,
    arkForgeLane: LaunchAgentArkForgeLaneStatus?,
    beforeBootstrap: (@Sendable () throws -> Void)? = nil
  ) throws -> LaunchAgentInstallReceipt {
    let daemonBundleSource = try daemonBundleValidator(daemonBundleSource)
    let daemonSource = daemonBundleSource.appending(
      path:
        "Contents/MacOS/\(ArkDeckHelperIdentity.daemonExecutableName)")
    let hdcExecutable = try validatedExecutable(hdcExecutable, name: "HDC")
    let workspace = try workspace.map(validatedWorkspace)
    let arkTraceDescriptor = try arkTraceDescriptor.map(validatedArkTraceDescriptor)
    let daemonSHA256 = try sha256(daemonSource)
    let hdcSHA256 = try sha256(hdcExecutable)
    try createOwnedDirectory(paths.plist.deletingLastPathComponent())
    try createOwnedDirectory(paths.installedDaemonBundle.deletingLastPathComponent())
    try createOwnedDirectory(paths.receipt.deletingLastPathComponent())
    try createOwnedDirectory(paths.logDirectory)

    if try isLoaded() {
      try requireSuccess(
        runner.run(arguments: ["bootout", launchDomain + "/" + ArkDeckLaunchAgent.label]),
        operation: "bootout")
    }

    if daemonBundleSource.path != paths.installedDaemonBundle.path {
      let staging = paths.installedDaemonBundle.deletingLastPathComponent()
        .appending(path: ".arkdeck-agentd-\(UUID().uuidString).app")
      defer { try? fileManager.removeItem(at: staging) }
      try fileManager.copyItem(at: daemonBundleSource, to: staging)
      // The executable bytes can remain identical while its Developer ID
      // signature, embedded profile, entitlements or notarization changes.
      // Replace and revalidate the complete helper bundle on every update.
      try replaceItem(at: paths.installedDaemonBundle, with: staging)
    }
    _ = try daemonBundleValidator(paths.installedDaemonBundle)
    try fileManager.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: paths.installedDaemon.path)

    let renderedPlist = try renderTemplate(
      daemonPath: paths.installedDaemon.path,
      hdcPath: hdcExecutable.path,
      stdoutPath: paths.standardOutput.path,
      stderrPath: paths.standardError.path,
      workspace: workspace,
      arkTraceDescriptor: arkTraceDescriptor, arkForgeLane: arkForgeLane)
    try renderedPlist.write(to: paths.plist, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.plist.path)

    let receipt = LaunchAgentInstallReceipt(
      installedAtUTC: nowUTC(), daemonPath: paths.installedDaemon.path,
      daemonSHA256: daemonSHA256, hdcPath: hdcExecutable.path,
      hdcSHA256: hdcSHA256,
      workspaceProjectPath: workspace?.projectRoot.path,
      devecoSDKPath: workspace?.devecoSDKRoot.path,
      arkTraceDescriptor: arkTraceDescriptor?.status,
      arkForgeLane: arkForgeLane)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    try encoder.encode(receipt).write(to: paths.receipt, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.receipt.path)

    // Migrate any legacy file-based Keychain item and update the exact daemon
    // identity receipt after the replacement is durable but before launchd
    // starts it. Current Data Protection Keychain items remain in place.
    if let beforeBootstrap {
      do {
        try beforeBootstrap()
      } catch {
        // Credential maintenance is allowed to fail closed for signing, but
        // it must not strand the whole read-only Device Runtime offline after
        // a successful bootout/copy. Start the fully validated replacement
        // before surfacing the maintenance failure to the caller.
        do {
          try bootstrap()
        } catch let recoveryError {
          throw LaunchAgentServiceError.launchctl(
            "credential refresh failed (\(error)); replacement daemon recovery failed (\(recoveryError))"
          )
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
    let removedDaemon = try removeIfPresent(paths.installedDaemonBundle)
    let removedReceipt = try removeIfPresent(paths.receipt)
    return LaunchAgentRemoval(
      removedPlist: removedPlist, removedDaemon: removedDaemon,
      removedReceipt: removedReceipt,
      preservedStateDirectory: paths.stateDirectory.path,
      preservedLogDirectory: paths.logDirectory.path)
  }

  /// The lane an `update` keeps when its flags are not restated.
  ///
  /// Read back from the live plist rather than remembered, so an `update` that
  /// says nothing about the lane preserves what is actually installed — not
  /// what some earlier receipt said was installed.
  public func arkForgeLaneForPreservingUpdate() throws -> LaunchAgentArkForgeLaneStatus? {
    guard let document = try? PropertyListSerialization.propertyList(
      from: try Data(contentsOf: paths.plist), options: [], format: nil) as? [String: Any],
      let environment = document["EnvironmentVariables"] as? [String: String]
    else { return nil }
    return try configuredArkForgeLane(environment)
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
    var arkTraceDescriptor: LaunchAgentArkTraceDescriptorStatus?
    var arkForgeLane: LaunchAgentArkForgeLaneStatus?

    if installed {
      do {
        let configuration = try configuredPaths()
        daemonPath = configuration.daemon
        hdcPath = configuration.hdc
        workspaceProjectPath = configuration.workspace?.projectRoot.path
        devecoSDKPath = configuration.workspace?.devecoSDKRoot.path
        arkTraceDescriptor = configuration.arkTraceDescriptor?.status
        arkForgeLane = configuration.arkForgeLane
        do {
          let validatedBundle = try daemonBundleValidator(paths.installedDaemonBundle)
          if validatedBundle.path != paths.installedDaemonBundle.path {
            diagnostics.append("installed daemon helper bundle path is not canonical")
          }
        } catch {
          diagnostics.append("installed daemon helper bundle is invalid: \(error)")
        }
        if configuration.daemon != paths.installedDaemon.path {
          diagnostics.append("ProgramArguments does not name the ArkDeck-managed daemon path")
        }
        do {
          let daemon = try validatedExecutable(
            URL(filePath: configuration.daemon), name: "configured arkdeck-agentd")
          if daemon.path != configuration.daemon {
            diagnostics.append("configured daemon path is not canonical")
          }
          daemonSHA256 = try sha256(daemon)
        } catch {
          diagnostics.append("configured arkdeck-agentd is invalid: \(error)")
        }
        do {
          let hdc = try validatedExecutable(
            URL(filePath: configuration.hdc), name: "configured HDC")
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
        if receipt.arkTraceDescriptor != arkTraceDescriptor {
          diagnostics.append("ArkTrace distribution descriptor drifted since installation")
        }
        if receipt.arkForgeLane != arkForgeLane {
          diagnostics.append("ArkForge release bundle drifted since installation")
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
      arkTraceDescriptor: arkTraceDescriptor, arkForgeLane: arkForgeLane,
      socketPath: paths.socket.path, socketPresent: socketPresent,
      standardOutputPath: paths.standardOutput.path,
      standardErrorPath: paths.standardError.path,
      diagnostics: diagnostics,
      ready: installed && loaded && socketPresent && diagnostics.isEmpty)
  }

  /// Reads the daemon process identity from the Runtime-owned state directory.
  /// A stale document is possible after a crash, so callers must pair this
  /// value with a successful UDS health request before trusting liveness.
  public func daemonInstance() throws -> LaunchAgentDaemonInstance {
    let instanceURL = paths.stateDirectory.appending(path: "instance.json")
    let instance: LaunchAgentDaemonInstance
    do {
      instance = try JSONDecoder().decode(
        LaunchAgentDaemonInstance.self, from: Data(contentsOf: instanceURL))
    } catch {
      throw LaunchAgentServiceError.configuration(
        "daemon instance document is unavailable or invalid: \(error)")
    }
    guard instance.pid > 0,
      instance.socketPath == paths.socket.path,
      !instance.protocolVersion.isEmpty,
      !instance.startedAtUTC.isEmpty
    else {
      throw LaunchAgentServiceError.configuration(
        "daemon instance document does not match the managed LaunchAgent")
    }
    return instance
  }

  /// Restarts the already healthy managed service without changing any
  /// installed bytes or Runtime state. The CLI owns the zero-current-Job
  /// preflight and post-bootstrap UDS/PID/catalog proof around this narrow
  /// launchd lifecycle operation.
  public func restart() throws -> LaunchAgentRestartReceipt {
    let before = try status()
    guard before.ready,
      let daemonPath = before.daemonPath,
      let daemonSHA256 = before.daemonSHA256,
      let hdcSHA256 = before.hdcSHA256
    else {
      throw LaunchAgentServiceError.configuration(
        "restart requires a ready, identity-checked LaunchAgent: "
          + before.diagnostics.joined(separator: "; "))
    }
    try requireSuccess(
      runner.run(arguments: ["bootout", launchDomain + "/" + ArkDeckLaunchAgent.label]),
      operation: "bootout")
    try bootstrap()
    return LaunchAgentRestartReceipt(
      schemaVersion: "arkdeck-launchagent-restart/v1",
      restartedAtUTC: nowUTC(), launchDomain: launchDomain,
      plistPath: paths.plist.path, daemonPath: daemonPath,
      daemonSHA256: daemonSHA256, hdcSHA256: hdcSHA256,
      preservedStateDirectory: paths.stateDirectory.path,
      preservedLogDirectory: paths.logDirectory.path)
  }

  /// Returns the descriptor selected by the last successful installation,
  /// but only while the live plist and descriptor bytes still match that
  /// installation receipt. An ordinary daemon update must not silently turn
  /// a drifted descriptor into the new trusted baseline.
  public func arkTraceDescriptorForPreservingUpdate() throws -> URL? {
    let configuration = try configuredPaths()
    let receiptData = try Data(contentsOf: paths.receipt)
    let receipt = try JSONDecoder().decode(
      LaunchAgentInstallReceipt.self, from: receiptData)
    guard receipt.arkTraceDescriptor == configuration.arkTraceDescriptor?.status else {
      throw LaunchAgentServiceError.configuration(
        "ArkTrace distribution descriptor drifted since installation; pass --arktrace-descriptor explicitly to select reviewed bytes")
    }
    return configuration.arkTraceDescriptor?.url
  }

  private struct ConfiguredPaths {
    let daemon: String
    let hdc: String
    let workspace: LaunchAgentWorkspaceConfiguration?
    let arkTraceDescriptor: ValidatedArkTraceDescriptor?
    let arkForgeLane: LaunchAgentArkForgeLaneStatus?
  }

  private struct ValidatedArkTraceDescriptor {
    let url: URL
    let status: LaunchAgentArkTraceDescriptorStatus
  }

  private struct ArkTraceDescriptorDocument: Decodable {
    let distributionRoot: String
    let formatVersion: Int
    let manifestSHA256: String
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
          projectRoot: URL(filePath: String(projectEntry.dropFirst(prefix.count))),
          devecoSDKRoot: URL(filePath: sdk)))
    }
    // Legacy harness gateway keys from a pre-CHG-2026-064 installation are
    // deliberately ignored here: `agentd update` reads this configuration and
    // regenerates the plist, which is exactly how those keys get retired.
    let arkTraceDescriptor = try environment[ArkDeckLaunchAgent.arkTraceDescriptorEnvironmentKey]
      .map { try validatedArkTraceDescriptor(URL(filePath: $0)) }
    let arkForgeLane = try configuredArkForgeLane(environment)
    return ConfiguredPaths(
      daemon: daemon, hdc: hdc, workspace: workspace,
      arkTraceDescriptor: arkTraceDescriptor, arkForgeLane: arkForgeLane)
  }

  /// Reads the current one-key configuration, or migrates one exact legacy
  /// three-key plist for the next `agentd update`.
  ///
  /// Migration is deliberately structural rather than heuristic: the old
  /// daemon path must be the canonical daemon member, the old profile must be
  /// the canonical DAYU200 member, and the old digest must match the manifest-
  /// verified daemon. Partial, aliased and cross-bundle configurations fail.
  private func configuredArkForgeLane(
    _ environment: [String: String]
  ) throws -> LaunchAgentArkForgeLaneStatus? {
    let current = environment[ArkDeckLaunchAgent.arkForgeBundleEnvironmentKey]
    let legacyPresent = ArkDeckLaunchAgent.legacyArkForgeEnvironmentKeys.filter {
      environment[$0] != nil
    }
    let campaign = environment[ArkDeckLaunchAgent.arkForgeCampaignEnvironmentKey] ?? ""

    if let current {
      guard legacyPresent.isEmpty else {
        throw LaunchAgentArkForgeLaneStatus.Refusal.mixedLegacyConfiguration
      }
      return try LaunchAgentArkForgeLaneStatus.measuring(
        bundlePath: current, campaign: campaign)
    }
    guard !legacyPresent.isEmpty else { return nil }
    let missing = ArkDeckLaunchAgent.legacyArkForgeEnvironmentKeys.filter {
      environment[$0]?.isEmpty != false
    }
    guard missing.isEmpty else {
      throw LaunchAgentArkForgeLaneStatus.Refusal.partialLegacyConfiguration(missing: missing)
    }

    let legacyDaemon = environment[ArkDeckLaunchAgent.arkForgedPathEnvironmentKey]!
    let legacyDigest = environment[ArkDeckLaunchAgent.arkForgedSHA256EnvironmentKey]!
    let legacyProfile = environment[ArkDeckLaunchAgent.arkForgeProfileEnvironmentKey]!
    let daemonURL = URL(filePath: legacyDaemon).standardizedFileURL
    let inferredRoot = daemonURL.deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let migrated: LaunchAgentArkForgeLaneStatus
    do {
      migrated = try LaunchAgentArkForgeLaneStatus.measuring(
        bundlePath: inferredRoot.path, campaign: campaign)
    } catch {
      throw LaunchAgentArkForgeLaneStatus.Refusal.crossBundleLegacyConfiguration
    }
    guard migrated.daemonPath == daemonURL.path,
      migrated.deviceProfilePath == URL(filePath: legacyProfile).standardizedFileURL.path
    else {
      throw LaunchAgentArkForgeLaneStatus.Refusal.crossBundleLegacyConfiguration
    }
    guard migrated.daemonSHA256 == legacyDigest.lowercased() else {
      throw LaunchAgentArkForgeLaneStatus.Refusal.digestMismatch(
        path: legacyDaemon, declared: legacyDigest, measured: migrated.daemonSHA256)
    }
    return migrated
  }

  private func renderTemplate(
    daemonPath: String, hdcPath: String, stdoutPath: String, stderrPath: String,
    workspace: LaunchAgentWorkspaceConfiguration?,
    arkTraceDescriptor: ValidatedArkTraceDescriptor?,
    arkForgeLane: LaunchAgentArkForgeLaneStatus?
  ) throws -> Data {
    guard
      let template = Self.bundledTemplateURL()
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
    if let arkTraceDescriptor {
      environment[ArkDeckLaunchAgent.arkTraceDescriptorEnvironmentKey] =
        arkTraceDescriptor.url.path
    }
    // All three or none. The lane refuses a partial set, so writing two would
    // produce a daemon that starts, looks configured, and has no lane.
    if let arkForgeLane {
      environment.merge(arkForgeLane.environment) { _, new in new }
    }
    document["ProgramArguments"] = arguments
    document["EnvironmentVariables"] = environment
    document["StandardOutPath"] = stdoutPath
    document["StandardErrorPath"] = stderrPath
    return try PropertyListSerialization.data(
      fromPropertyList: document, format: .xml, options: 0)
  }

  /// Distributed helpers keep SwiftPM resources in the code-signable macOS
  /// app location (`Contents/Resources`). Avoid `Bundle.module` because its
  /// generated fallback embeds the build worktree and traps after that path is
  /// removed. The sibling candidates retain direct `swift test`/CLI support.
  private static func resourceBundle() -> Bundle? {
    resourceBundleCandidates(named: "ArkDeckKit_ArkDeckLaunchAgent.bundle")
      .lazy.compactMap(Bundle.init(url:)).first
  }

  private static func bundledTemplateURL() -> URL? {
    if let packaged = resourceBundle()?.url(
      forResource: ArkDeckLaunchAgent.label, withExtension: "plist")
    {
      return packaged
    }
    let sourceFallback = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .appending(
        path: ArkDeckLaunchAgent.label + ".plist", directoryHint: .notDirectory)
    return FileManager.default.fileExists(atPath: sourceFallback.path)
      ? sourceFallback : nil
  }

  private static func resourceBundleCandidates(named name: String) -> [URL] {
    let main = Bundle.main.bundleURL
    var candidates: [URL] = []
    if let resources = Bundle.main.resourceURL {
      candidates.append(resources.appending(path: name, directoryHint: .isDirectory))
    }
    if let executable = Bundle.main.executableURL {
      candidates.append(
        executable.deletingLastPathComponent()
          .appending(path: name, directoryHint: .isDirectory))
    }
    candidates.append(main.appending(path: name, directoryHint: .isDirectory))
    candidates.append(
      main.deletingLastPathComponent().appending(path: name, directoryHint: .isDirectory))
    var seen: Set<String> = []
    return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
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

  /// Pins the small owner-selected profile descriptor that the daemon will
  /// revalidate against the full signed ArkTrace distribution. This boundary
  /// deliberately validates the descriptor through one `openat(O_NOFOLLOW)`
  /// component walk; resolving a path first and opening it later would allow
  /// an exchanged ancestor to select different bytes.
  private func validatedArkTraceDescriptor(
    _ candidate: URL
  ) throws -> ValidatedArkTraceDescriptor {
    let maximumByteCount = 16 * 1_024
    guard candidate.isFileURL, candidate.path.hasPrefix("/") else {
      throw LaunchAgentServiceError.configuration(
        "ArkTrace distribution descriptor path must be absolute")
    }
    let physicalPath = Self.physicalAbsolutePath(candidate.path)
    let components = physicalPath.split(
      separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw LaunchAgentServiceError.configuration(
        "ArkTrace distribution descriptor path is invalid")
    }

    var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard directory >= 0 else {
      throw LaunchAgentServiceError.configuration(
        "ArkTrace distribution descriptor root is unavailable")
    }
    var descriptor: Int32 = -1
    defer {
      if descriptor >= 0 { Darwin.close(descriptor) }
      if directory >= 0 { Darwin.close(directory) }
    }
    for component in components.dropLast() {
      let next = component.withCString {
        Darwin.openat(
          directory, $0,
          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      }
      guard next >= 0 else {
        throw LaunchAgentServiceError.configuration(
          "ArkTrace distribution descriptor has an unavailable or symbolic ancestor")
      }
      var metadata = stat()
      guard fstat(next, &metadata) == 0,
        metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
        (metadata.st_uid == uid || metadata.st_uid == 0),
        metadata.st_mode & 0o022 == 0
      else {
        Darwin.close(next)
        throw LaunchAgentServiceError.configuration(
          "ArkTrace distribution descriptor ancestors must be owner-controlled")
      }
      Darwin.close(directory)
      directory = next
    }
    descriptor = components.last!.withCString {
      Darwin.openat(
        directory, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      throw LaunchAgentServiceError.configuration(
        "ArkTrace distribution descriptor must be a physical regular file")
    }
    var initial = stat()
    guard fstat(descriptor, &initial) == 0,
      initial.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      (initial.st_uid == uid || initial.st_uid == 0),
      initial.st_mode & 0o022 == 0,
      initial.st_size > 0,
      initial.st_size <= maximumByteCount
    else {
      throw LaunchAgentServiceError.configuration(
        "ArkTrace distribution descriptor must be bounded and owner-controlled")
    }

    let byteCount = Int(initial.st_size)
    var bytes = Data(count: byteCount)
    var offset = 0
    while offset < byteCount {
      let count = bytes.withUnsafeMutableBytes { buffer in
        pread(
          descriptor, buffer.baseAddress!.advanced(by: offset),
          byteCount - offset, off_t(offset))
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw LaunchAgentServiceError.configuration(
          "ArkTrace distribution descriptor could not be read completely")
      }
      offset += count
    }
    var extra: UInt8 = 0
    guard pread(descriptor, &extra, 1, off_t(byteCount)) == 0 else {
      throw LaunchAgentServiceError.configuration(
        "ArkTrace distribution descriptor changed while it was read")
    }
    var final = stat()
    guard fstat(descriptor, &final) == 0,
      final.st_dev == initial.st_dev,
      final.st_ino == initial.st_ino,
      final.st_uid == initial.st_uid,
      final.st_mode == initial.st_mode,
      final.st_size == initial.st_size,
      final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
      final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
      final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
      final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec
    else {
      throw LaunchAgentServiceError.configuration(
        "ArkTrace distribution descriptor identity changed while it was read")
    }

    do {
      var duplicateValidator = StrictJSONDuplicateValidator(data: bytes)
      try duplicateValidator.validate()
    } catch {
      throw LaunchAgentServiceError.configuration(
        "ArkTrace distribution descriptor schema is invalid")
    }
    guard
      let document = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      Set(document.keys) == Set(["distributionRoot", "formatVersion", "manifestSHA256"]),
      let typed = try? JSONDecoder().decode(ArkTraceDescriptorDocument.self, from: bytes),
      typed.distributionRoot.hasPrefix("/"), typed.distributionRoot.utf8.count <= 4_096,
      typed.formatVersion == 1,
      typed.manifestSHA256.range(
        of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    else {
      throw LaunchAgentServiceError.configuration(
        "ArkTrace distribution descriptor schema is invalid")
    }
    let sha256 = SHA256.hash(data: bytes)
      .map { String(format: "%02x", $0) }.joined()
    let status = LaunchAgentArkTraceDescriptorStatus(
      descriptorPath: physicalPath, descriptorSHA256: sha256,
      descriptorByteCount: byteCount)
    return ValidatedArkTraceDescriptor(
      url: URL(filePath: physicalPath), status: status)
  }

  private static func physicalAbsolutePath(_ path: String) -> String {
    if path == "/var" || path.hasPrefix("/var/") { return "/private" + path }
    if path == "/tmp" || path.hasPrefix("/tmp/") { return "/private" + path }
    if path == "/etc" || path.hasPrefix("/etc/") { return "/private" + path }
    return path
  }

  package static func validateProductionDaemonBundle(
    _ candidate: URL, fileManager: FileManager
  ) throws -> URL {
    guard candidate.path.hasPrefix("/") else {
      throw LaunchAgentServiceError.invalidExecutable(
        "arkdeck-agentd helper bundle path must be absolute")
    }
    let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
      isDirectory.boolValue, canonical.pathExtension == "app"
    else {
      throw LaunchAgentServiceError.invalidExecutable(
        "arkdeck-agentd must be supplied as an app-like helper bundle")
    }
    let infoURL = canonical.appending(path: "Contents/Info.plist")
    let executableURL = canonical.appending(
      path:
        "Contents/MacOS/\(ArkDeckHelperIdentity.daemonExecutableName)")
    guard
      let info = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: infoURL), format: nil) as? [String: Any],
      info["CFBundleIdentifier"] as? String == ArkDeckHelperIdentity.daemonBundleIdentifier,
      info["CFBundleExecutable"] as? String == ArkDeckHelperIdentity.daemonExecutableName
    else {
      throw LaunchAgentServiceError.invalidExecutable(
        "arkdeck-agentd helper Info.plist identity is invalid")
    }
    var executableIsDirectory: ObjCBool = false
    guard
      fileManager.fileExists(
        atPath: executableURL.path, isDirectory: &executableIsDirectory),
      !executableIsDirectory.boolValue,
      fileManager.isExecutableFile(atPath: executableURL.path)
    else {
      throw LaunchAgentServiceError.invalidExecutable(
        "arkdeck-agentd helper executable is missing or is not executable")
    }
    var staticCode: SecStaticCode?
    let createStatus = SecStaticCodeCreateWithPath(canonical as CFURL, SecCSFlags(), &staticCode)
    guard createStatus == errSecSuccess, let staticCode else {
      throw LaunchAgentServiceError.invalidExecutable(
        "arkdeck-agentd helper signature is unreadable (status \(createStatus))")
    }
    var staticRequirement: SecRequirement?
    let requirementStatus = SecRequirementCreateWithString(
      ArkDeckHelperIdentity.daemonCodeRequirement as CFString,
      SecCSFlags(), &staticRequirement)
    guard requirementStatus == errSecSuccess, let staticRequirement else {
      throw LaunchAgentServiceError.invalidExecutable(
        "arkdeck-agentd helper requirement is invalid (status \(requirementStatus))")
    }
    let validityStatus = SecStaticCodeCheckValidity(
      staticCode,
      SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
      staticRequirement)
    guard validityStatus == errSecSuccess else {
      throw LaunchAgentServiceError.invalidExecutable(
        "arkdeck-agentd helper signature does not match ArkDeck (status \(validityStatus))")
    }
    var rawInformation: CFDictionary?
    let informationStatus = SecCodeCopySigningInformation(
      staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInformation)
    // CS_RUNTIME from <Security/CSCommon.h>; the Swift overlay does not expose
    // the enum case even though kSecCodeInfoFlags is public.
    let hardenedRuntimeFlag: UInt32 = 0x0001_0000
    guard informationStatus == errSecSuccess,
      let information = rawInformation as? [String: Any],
      information[kSecCodeInfoTeamIdentifier as String] as? String
        == ArkDeckHelperIdentity.teamIdentifier,
      let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
      entitlements["com.apple.application-identifier"] as? String
        == ArkDeckHelperIdentity.applicationIdentifier(
          bundleIdentifier: ArkDeckHelperIdentity.daemonBundleIdentifier),
      (entitlements["keychain-access-groups"] as? [String])?.contains(
        ArkDeckHelperIdentity.keychainAccessGroup) == true,
      let flags = information[kSecCodeInfoFlags as String] as? NSNumber,
      flags.uint32Value & hardenedRuntimeFlag != 0,
      fileManager.fileExists(
        atPath: canonical.appending(path: "Contents/embedded.provisionprofile").path)
    else {
      throw LaunchAgentServiceError.invalidExecutable(
        "arkdeck-agentd helper lacks its team, hardened runtime, shared Keychain group, "
          + "or embedded provisioning profile")
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
      paths.homeDirectory.appending(path: $0, directoryHint: .isDirectory)
        .standardizedFileURL.path
    }
    guard
      !protectedRoots.contains(where: {
        project.path == $0 || project.path.hasPrefix($0 + "/")
      })
    else {
      throw LaunchAgentServiceError.configuration(
        "WaterFlow project cannot be under macOS privacy-managed Desktop, "
          + "Documents or Downloads; use an absolute path under ~/Developer "
          + "or another LaunchAgent-readable directory")
    }
    guard !project.path.contains(","), !project.path.contains("=") else {
      throw LaunchAgentServiceError.configuration(
        "WaterFlow project path cannot contain ',' or '='")
    }
    guard
      fileManager.fileExists(
        atPath: project.appending(path: "build-profile.json5").path),
      fileManager.fileExists(
        atPath: project.appending(path: "entry/src/main/module.json5").path)
    else {
      throw LaunchAgentServiceError.configuration(
        "WaterFlow project is missing build-profile.json5 or entry/src/main/module.json5")
    }
    let sdk = try directory(configuration.devecoSDKRoot, name: "DevEco SDK")
    var openHarmonyIsDirectory: ObjCBool = false
    guard
      fileManager.fileExists(
        atPath: sdk.appending(path: "default/openharmony").path,
        isDirectory: &openHarmonyIsDirectory), openHarmonyIsDirectory.boolValue
    else {
      throw LaunchAgentServiceError.configuration(
        "DevEco SDK does not contain default/openharmony")
    }
    return LaunchAgentWorkspaceConfiguration(projectRoot: project, devecoSDKRoot: sdk)
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
  /// EIO. A persistently disabled user service reports the same status, so an
  /// explicit install/update repairs that state once after three consecutive
  /// EIO responses. Retry only that exact launchctl status, for a bounded two
  /// seconds; every other configuration or permission failure remains
  /// fail-closed on its first response.
  private func bootstrap() throws {
    let arguments = ["bootstrap", launchDomain, paths.plist.path]
    let maximumAttempts = 20
    let enableAfterAttempt = 3
    var enableAttempted = false
    for attempt in 1...maximumAttempts {
      let result = try runner.run(arguments: arguments)
      if result.exitStatus == 0 { return }
      guard result.exitStatus == EIO, attempt < maximumAttempts else {
        try requireSuccess(result, operation: "bootstrap")
        return
      }
      if attempt == enableAfterAttempt, !enableAttempted {
        try requireSuccess(
          runner.run(arguments: ["enable", launchDomain + "/" + ArkDeckLaunchAgent.label]),
          operation: "enable")
        enableAttempted = true
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
    ISO8601Timestamps.string(from: Date())
  }
}

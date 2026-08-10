import CryptoKit
import Darwin
import XCTest

@testable import ArkDeckCLI
@testable import ArkDeckLaunchAgent

final class LaunchAgentServiceContractTests: XCTestCase {
  private var root: URL!
  private var paths: LaunchAgentPaths!
  private var daemon: URL!
  private var hdc: URL!
  private var runner: FakeLaunchAgentCommandRunner!
  private var service: LaunchAgentService!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-launchagent-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    paths = LaunchAgentPaths(homeDirectory: root.appendingPathComponent("home", isDirectory: true))
    daemon = root.appendingPathComponent("products/arkdeck-agentd")
    hdc = root.appendingPathComponent("DevEco/toolchains/hdc")
    try makeExecutable(daemon, bytes: "daemon-v1")
    try makeExecutable(hdc, bytes: "hdc-v1")
    runner = FakeLaunchAgentCommandRunner()
    service = LaunchAgentService(
      paths: paths, runner: runner, uid: 501,
      nowUTC: { "2026-08-08T12:00:00Z" })
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  func testInstallClosesTemplateExecutableHDCAndUserDomainLifecycle() throws {
    let receipt = try service.install(daemonSource: daemon, hdcExecutable: hdc)

    XCTAssertEqual(receipt.daemonPath, paths.installedDaemon.path)
    XCTAssertEqual(receipt.daemonSHA256, try digest(daemon))
    XCTAssertEqual(receipt.hdcPath, hdc.path)
    XCTAssertEqual(receipt.hdcSHA256, try digest(hdc))
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: paths.installedDaemon.path))

    let document = try plist(at: paths.plist)
    XCTAssertEqual(document["Label"] as? String, ArkDeckLaunchAgent.label)
    XCTAssertEqual(
      document["ProgramArguments"] as? [String], [paths.installedDaemon.path])
    XCTAssertEqual(
      (document["EnvironmentVariables"] as? [String: String])?["ARKDECK_HDC_PATH"],
      hdc.path)
    XCTAssertEqual(document["KeepAlive"] as? Bool, true)
    XCTAssertEqual(document["RunAtLoad"] as? Bool, true)
    XCTAssertEqual(document["LimitLoadToSessionType"] as? String, "Aqua")
    XCTAssertEqual(document["StandardOutPath"] as? String, paths.standardOutput.path)
    XCTAssertEqual(document["StandardErrorPath"] as? String, paths.standardError.path)
    XCTAssertEqual(
      (document["MachServices"] as? [String: Bool])?[ArkDeckLaunchAgent.label], true)
    XCTAssertFalse(
      String(decoding: try Data(contentsOf: paths.plist), as: UTF8.self).contains("__ARKDECK_"))

    XCTAssertEqual(
      runner.commands,
      [
        ["print", "gui/501/\(ArkDeckLaunchAgent.label)"],
        ["bootstrap", "gui/501", paths.plist.path],
      ])

    var status = try service.status()
    XCTAssertTrue(status.installed)
    XCTAssertTrue(status.loaded)
    XCTAssertFalse(status.ready)
    XCTAssertTrue(status.diagnostics.contains { $0.contains("socket is absent") })

    try FileManager.default.createDirectory(
      at: paths.stateDirectory, withIntermediateDirectories: true)
    XCTAssertTrue(FileManager.default.createFile(atPath: paths.socket.path, contents: Data()))
    status = try service.status()
    XCTAssertTrue(status.ready, "\(status.diagnostics)")
    XCTAssertEqual(status.daemonSHA256, receipt.daemonSHA256)
    XCTAssertEqual(status.hdcSHA256, receipt.hdcSHA256)
  }

  func testUpdateBootsOutLoadedServiceRefreshesIdentitiesAndCLIUsesSameManager() throws {
    _ = try service.install(daemonSource: daemon, hdcExecutable: hdc)
    let oldReceipt = try JSONDecoder().decode(
      LaunchAgentInstallReceipt.self, from: Data(contentsOf: paths.receipt))
    try makeExecutable(daemon, bytes: "daemon-v2")
    try makeExecutable(hdc, bytes: "hdc-v2")
    runner.removeAllCommands()

    try RuntimeCLI.runAgentDaemon(
      ["update", "--daemon", daemon.path, "--hdc", hdc.path, "--json"],
      service: service)

    let refreshed = try JSONDecoder().decode(
      LaunchAgentInstallReceipt.self, from: Data(contentsOf: paths.receipt))
    XCTAssertNotEqual(refreshed.daemonSHA256, oldReceipt.daemonSHA256)
    XCTAssertNotEqual(refreshed.hdcSHA256, oldReceipt.hdcSHA256)
    XCTAssertEqual(refreshed.daemonSHA256, try digest(paths.installedDaemon))
    XCTAssertEqual(
      runner.commands,
      [
        ["print", "gui/501/\(ArkDeckLaunchAgent.label)"],
        // `update` reads the installed status first so optional workspace
        // configuration survives when the caller only refreshes binaries.
        ["print", "gui/501/\(ArkDeckLaunchAgent.label)"],
        ["bootout", "gui/501/\(ArkDeckLaunchAgent.label)"],
        ["bootstrap", "gui/501", paths.plist.path],
      ])
  }

  func testInstallPersistsValidatedWaterFlowWorkspaceForHeadlessGJ5AndUpdateKeepsIt()
    throws
  {
    let project = root.appendingPathComponent("WaterFlowLayoutDemo", isDirectory: true)
    let module = project.appendingPathComponent("entry/src/main", isDirectory: true)
    try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: project.appendingPathComponent("build-profile.json5"))
    try Data("{}".utf8).write(to: module.appendingPathComponent("module.json5"))
    let sdk = root.appendingPathComponent("DevEco/sdk", isDirectory: true)
    try FileManager.default.createDirectory(
      at: sdk.appendingPathComponent("default/openharmony", isDirectory: true),
      withIntermediateDirectories: true)

    let receipt = try service.install(
      daemonSource: daemon, hdcExecutable: hdc,
      workspace: LaunchAgentWorkspaceConfiguration(
        projectRoot: project, devecoSDKRoot: sdk),
      harnessSensitiveEvidence: ["hilog.txt", "crash-index.txt"])
    XCTAssertEqual(receipt.workspaceProjectPath, project.path)
    XCTAssertEqual(receipt.devecoSDKPath, sdk.path)
    XCTAssertEqual(receipt.harnessSensitiveEvidence, ["crash-index.txt", "hilog.txt"])

    var environment = try XCTUnwrap(
      (try plist(at: paths.plist))["EnvironmentVariables"] as? [String: String])
    XCTAssertEqual(environment["ARKDECK_WORKSPACE_PROJECTS"], "demo-app=\(project.path)")
    XCTAssertEqual(environment["ARKDECK_WORKSPACE_ACTIVE_PROJECT"], "demo-app")
    XCTAssertEqual(environment["ARKDECK_DEVECO_SDK_HOME"], sdk.path)
    XCTAssertEqual(environment["ARKDECK_ANALYZER_PATH"], paths.installedDaemon.path)
    XCTAssertEqual(environment["ARKDECK_WORKSPACE_INSPECTOR"], "/usr/bin/grep")
    XCTAssertEqual(
      environment["ARKDECK_HARNESS_SENSITIVE_EVIDENCE"],
      "crash-index.txt,hilog.txt")

    try FileManager.default.createDirectory(
      at: paths.stateDirectory, withIntermediateDirectories: true)
    XCTAssertTrue(FileManager.default.createFile(atPath: paths.socket.path, contents: Data()))
    var status = try service.status()
    XCTAssertTrue(status.ready, "\(status.diagnostics)")
    XCTAssertEqual(status.workspaceProjectPath, project.path)
    XCTAssertEqual(status.devecoSDKPath, sdk.path)
    XCTAssertEqual(status.harnessSensitiveEvidence, ["crash-index.txt", "hilog.txt"])

    try makeExecutable(daemon, bytes: "daemon-v2")
    try RuntimeCLI.runAgentDaemon(
      ["update", "--daemon", daemon.path, "--json"], service: service)
    environment = try XCTUnwrap(
      (try plist(at: paths.plist))["EnvironmentVariables"] as? [String: String])
    XCTAssertEqual(environment["ARKDECK_WORKSPACE_PROJECTS"], "demo-app=\(project.path)")
    XCTAssertEqual(environment["ARKDECK_DEVECO_SDK_HOME"], sdk.path)
    XCTAssertEqual(
      environment["ARKDECK_HARNESS_SENSITIVE_EVIDENCE"],
      "crash-index.txt,hilog.txt")
    status = try service.status()
    XCTAssertEqual(status.workspaceProjectPath, project.path)
    XCTAssertEqual(status.harnessSensitiveEvidence, ["crash-index.txt", "hilog.txt"])

    try RuntimeCLI.runAgentDaemon(
      ["update", "--daemon", daemon.path, "--sensitive-evidence", "none", "--json"],
      service: service)
    environment = try XCTUnwrap(
      (try plist(at: paths.plist))["EnvironmentVariables"] as? [String: String])
    XCTAssertNil(environment["ARKDECK_HARNESS_SENSITIVE_EVIDENCE"])
    XCTAssertEqual(try service.status().harnessSensitiveEvidence, [])
  }

  func testWorkspaceConfigurationFailsClosedUnlessProjectAndSDKAreBothValid() throws {
    XCTAssertThrowsError(
      try RuntimeCLI.runAgentDaemon(
        ["install", "--daemon", daemon.path, "--hdc", hdc.path,
          "--workspace-project", root.path],
        service: service)) { error in
          XCTAssertTrue("\(error)".contains("--workspace-project and --deveco-sdk together"))
        }

    let missingProject = root.appendingPathComponent("missing-project", isDirectory: true)
    let missingSDK = root.appendingPathComponent("missing-sdk", isDirectory: true)
    XCTAssertThrowsError(
      try service.install(
        daemonSource: daemon, hdcExecutable: hdc,
        workspace: LaunchAgentWorkspaceConfiguration(
          projectRoot: missingProject, devecoSDKRoot: missingSDK)))

    let protectedProject = paths.homeDirectory.appendingPathComponent(
      "Downloads/WaterFlowLayoutDemo", isDirectory: true)
    try FileManager.default.createDirectory(
      at: protectedProject.appendingPathComponent("entry/src/main", isDirectory: true),
      withIntermediateDirectories: true)
    try Data("{}".utf8).write(
      to: protectedProject.appendingPathComponent("build-profile.json5"))
    try Data("{}".utf8).write(
      to: protectedProject.appendingPathComponent("entry/src/main/module.json5"))
    let validSDK = root.appendingPathComponent("valid-sdk", isDirectory: true)
    try FileManager.default.createDirectory(
      at: validSDK.appendingPathComponent("default/openharmony", isDirectory: true),
      withIntermediateDirectories: true)
    XCTAssertThrowsError(
      try service.install(
        daemonSource: daemon, hdcExecutable: hdc,
        workspace: LaunchAgentWorkspaceConfiguration(
          projectRoot: protectedProject, devecoSDKRoot: validSDK))) { error in
          XCTAssertTrue("\(error)".contains("macOS privacy-managed"))
          XCTAssertTrue("\(error)".contains("~/Developer"))
        }
    XCTAssertTrue(runner.commands.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.plist.path))

    for invalid in [["../crash-index.txt"], ["hilog.txt", "hilog.txt"], [""]] {
      XCTAssertThrowsError(
        try service.install(
          daemonSource: daemon, hdcExecutable: hdc,
          harnessSensitiveEvidence: invalid)) { error in
            XCTAssertTrue("\(error)".contains("unique safe artifact basenames"))
          }
    }
  }

  func testStatusNamesHDCIdentityDriftAndUninstallPreservesStateAndLogs() throws {
    _ = try service.install(daemonSource: daemon, hdcExecutable: hdc)
    try makeExecutable(hdc, bytes: "unreviewed-hdc-replacement")
    let stateMarker = paths.stateDirectory.appendingPathComponent("jobs.sqlite")
    try FileManager.default.createDirectory(
      at: paths.stateDirectory, withIntermediateDirectories: true)
    try Data("history".utf8).write(to: stateMarker)
    try Data("log".utf8).write(to: paths.standardOutput)

    let drifted = try service.status()
    XCTAssertTrue(drifted.diagnostics.contains("HDC identity drifted since installation"))
    XCTAssertFalse(
      drifted.diagnostics.contains("arkdeck-agentd identity drifted since installation"),
      "an HDC-only drift must not accuse the daemon: \(drifted.diagnostics)")

    runner.removeAllCommands()
    let removal = try service.uninstall()
    XCTAssertTrue(removal.removedPlist)
    XCTAssertTrue(removal.removedDaemon)
    XCTAssertTrue(removal.removedReceipt)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.plist.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: stateMarker.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: paths.standardOutput.path))
    XCTAssertEqual(
      runner.commands,
      [
        ["print", "gui/501/\(ArkDeckLaunchAgent.label)"],
        ["bootout", "gui/501/\(ArkDeckLaunchAgent.label)"],
      ])
  }

  func testUpdateRetriesOnlyTransientLaunchdEIOAfterBootout() throws {
    _ = try service.install(daemonSource: daemon, hdcExecutable: hdc)
    runner.removeAllCommands()
    runner.failNextBootstrapWithEIO()

    _ = try service.install(daemonSource: daemon, hdcExecutable: hdc)

    XCTAssertEqual(
      runner.commands,
      [
        ["print", "gui/501/\(ArkDeckLaunchAgent.label)"],
        ["bootout", "gui/501/\(ArkDeckLaunchAgent.label)"],
        ["bootstrap", "gui/501", paths.plist.path],
        ["bootstrap", "gui/501", paths.plist.path],
      ])
  }

  func testInvalidOrMissingExecutablesFailBeforeLaunchctlAndConfigurationWrites() throws {
    let nonExecutable = root.appendingPathComponent("not-executable")
    try Data("bytes".utf8).write(to: nonExecutable)

    XCTAssertThrowsError(
      try service.install(daemonSource: nonExecutable, hdcExecutable: hdc))
    XCTAssertThrowsError(
      try service.install(
        daemonSource: daemon,
        hdcExecutable: root.appendingPathComponent("missing-hdc")))
    XCTAssertTrue(runner.commands.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.plist.path))
  }

  func testHeadlessVerifyRefusesAnUnreadyLaunchAgentBeforeOpeningUDS() throws {
    XCTAssertThrowsError(
      try RuntimeCLI.runAgentDaemon(["verify", "--json"], service: service)
    ) { error in
      guard let cli = error as? CLIError else {
        return XCTFail("expected a CLI readiness failure, got \(error)")
      }
      XCTAssertEqual(cli.exitCode, 69)
      XCTAssertTrue(cli.message.contains("LaunchAgent is not ready"))
    }
    XCTAssertTrue(
      runner.commands.isEmpty,
      "an uninstalled LaunchAgent must fail before launchctl probing or UDS access")
  }

  private func makeExecutable(_ url: URL, bytes: String) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(bytes.utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  private func plist(at url: URL) throws -> [String: Any] {
    try XCTUnwrap(
      PropertyListSerialization.propertyList(
        from: Data(contentsOf: url), options: [], format: nil) as? [String: Any])
  }

  private func digest(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url))
      .map { String(format: "%02x", $0) }.joined()
  }
}

private final class FakeLaunchAgentCommandRunner: LaunchAgentCommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var recordedCommands: [[String]] = []
  private var loaded = false
  private var bootstrapEIOFailuresRemaining = 0

  func run(arguments: [String]) throws -> LaunchAgentCommandResult {
    lock.lock()
    defer { lock.unlock() }
    recordedCommands.append(arguments)
    switch arguments.first {
    case "print":
      return LaunchAgentCommandResult(exitStatus: loaded ? 0 : 113)
    case "bootstrap":
      if bootstrapEIOFailuresRemaining > 0 {
        bootstrapEIOFailuresRemaining -= 1
        return LaunchAgentCommandResult(
          exitStatus: EIO, stderr: Data("Bootstrap failed: 5: Input/output error".utf8))
      }
      loaded = true
      return LaunchAgentCommandResult(exitStatus: 0)
    case "bootout":
      loaded = false
      return LaunchAgentCommandResult(exitStatus: 0)
    default:
      return LaunchAgentCommandResult(
        exitStatus: 64, stderr: Data("unexpected command".utf8))
    }
  }

  var commands: [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return recordedCommands
  }

  func removeAllCommands() {
    lock.lock()
    recordedCommands.removeAll()
    lock.unlock()
  }

  func failNextBootstrapWithEIO() {
    lock.lock()
    bootstrapEIOFailuresRemaining = 1
    lock.unlock()
  }
}

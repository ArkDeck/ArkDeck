import CryptoKit
import Darwin
import XCTest

@testable import ArkDeckAgentComposition
@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckLaunchAgent

final class LaunchAgentServiceContractTests: XCTestCase {
  private var root: URL!
  private var paths: LaunchAgentPaths!
  private var daemonBundle: URL!
  private var daemon: URL!
  private var hdc: URL!
  private var runner: FakeLaunchAgentCommandRunner!
  private var service: LaunchAgentService!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-launchagent-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    paths = LaunchAgentPaths(
      homeDirectory: root.appending(path: "home", directoryHint: .isDirectory))
    daemonBundle = root.appending(
      path:
        "products/\(ArkDeckHelperIdentity.daemonBundleName)", directoryHint: .isDirectory)
    daemon = daemonBundle.appending(
      path:
        "Contents/MacOS/\(ArkDeckHelperIdentity.daemonExecutableName)")
    hdc = root.appending(path: "DevEco/toolchains/hdc")
    try makeDaemonBundle(daemonBundle)
    try makeExecutable(daemon, bytes: "daemon-v1")
    try makeExecutable(hdc, bytes: "hdc-v1")
    runner = FakeLaunchAgentCommandRunner()
    service = LaunchAgentService(
      paths: paths, runner: runner, uid: 501,
      nowUTC: { "2026-08-08T12:00:00Z" },
      daemonBundleValidator: { $0.resolvingSymlinksInPath().standardizedFileURL })
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  func testCLIAndDaemonShareTheDefaultSocketLayout() {
    XCTAssertEqual(
      RuntimeCLI.defaultSocketPath(),
      ArkDeckAgentFilesystemLayout.defaultSocketURL().path)
    XCTAssertEqual(
      ArkDeckAgentFilesystemLayout.defaultSocketURL().lastPathComponent,
      ArkDeckAgentFilesystemLayout.socketFilename)
  }

  func testDistributionHelpersShareOnlyTheProvisionedKeychainGroup() throws {
    let distribution = packageRoot.appending(path: "Distribution/macOS")
    let cliInfo = try plist(at: distribution.appending(path: "ArkDeckCLI-Info.plist"))
    let daemonInfo = try plist(
      at: distribution.appending(path: "ArkDeckAgent-Info.plist"))
    XCTAssertEqual(
      cliInfo["CFBundleIdentifier"] as? String, ArkDeckHelperIdentity.cliBundleIdentifier)
    XCTAssertEqual(
      daemonInfo["CFBundleIdentifier"] as? String,
      ArkDeckHelperIdentity.daemonBundleIdentifier)
    for name in ["ArkDeckCLI.entitlements", "ArkDeckAgent.entitlements"] {
      let entitlements = try plist(at: distribution.appending(path: name))
      XCTAssertEqual(
        entitlements["com.apple.developer.team-identifier"] as? String,
        ArkDeckHelperIdentity.teamIdentifier)
      let bundleIdentifier =
        name == "ArkDeckCLI.entitlements"
        ? ArkDeckHelperIdentity.cliBundleIdentifier
        : ArkDeckHelperIdentity.daemonBundleIdentifier
      XCTAssertEqual(
        entitlements["com.apple.application-identifier"] as? String,
        ArkDeckHelperIdentity.applicationIdentifier(bundleIdentifier: bundleIdentifier))
      XCTAssertEqual(
        entitlements["keychain-access-groups"] as? [String],
        [ArkDeckHelperIdentity.keychainAccessGroup])
    }
    let releaseScript = try String(
      contentsOf: distribution.appending(path: "build-helpers.sh"), encoding: .utf8)
    for requiredStep in [
      "security cms -D",
      "codesign --verify --strict --deep",
      "xcrun notarytool submit",
      "xcrun stapler staple",
      "spctl --assess --type execute",
      "cp -R \"$workflows_resource_bundle\" \"$cli_bundle/Contents/Resources/\"",
      "cp -R \"$workflows_resource_bundle\" \"$daemon_bundle/Contents/Resources/\"",
      "cp -R \"$launch_agent_resource_bundle\" \"$cli_bundle/Contents/Resources/\"",
    ] {
      XCTAssertTrue(
        releaseScript.contains(requiredStep),
        "release helper pipeline must retain \(requiredStep)")
    }
  }

  func testProductionInstallerRejectsAnUnsignedHelperBeforeLaunchctl() throws {
    let production = LaunchAgentService(
      paths: paths, runner: runner, uid: 501,
      nowUTC: { "2026-08-08T12:00:00Z" })
    XCTAssertThrowsError(
      try production.install(
        daemonBundleSource: daemonBundle, hdcExecutable: hdc)
    ) { error in
      XCTAssertTrue("\(error)".contains("signature"), "unexpected error: \(error)")
    }
    XCTAssertTrue(runner.commands.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.plist.path))
  }

  func testInstallClosesTemplateExecutableHDCAndUserDomainLifecycle() throws {
    XCTAssertEqual(
      ArkDeckLaunchAgent.harnessLocalModelProviders,
      HarnessLocalAgentCLIProfile.all.map(\.profileID).sorted(),
      "the installer and daemon composition must keep one closed local-provider vocabulary")
    let receipt = try service.install(
      daemonBundleSource: daemonBundle, hdcExecutable: hdc)

    XCTAssertEqual(receipt.daemonPath, paths.installedDaemon.path)
    XCTAssertEqual(receipt.daemonSHA256, try digest(daemon))
    XCTAssertEqual(receipt.hdcPath, hdc.path)
    XCTAssertEqual(receipt.hdcSHA256, try digest(hdc))
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: paths.installedDaemon.path))
    XCTAssertEqual(try permissions(paths.installedDaemon), 0o700)

    let document = try plist(at: paths.plist)
    XCTAssertEqual(document["Label"] as? String, ArkDeckLaunchAgent.label)
    XCTAssertEqual(
      document["ProgramArguments"] as? [String], [paths.installedDaemon.path])
    XCTAssertEqual(
      (document["EnvironmentVariables"] as? [String: String])?[ArkDeckEnvironmentKey.hdcPath],
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
    _ = try service.install(daemonBundleSource: daemonBundle, hdcExecutable: hdc)
    let oldReceipt = try JSONDecoder().decode(
      LaunchAgentInstallReceipt.self, from: Data(contentsOf: paths.receipt))
    // Foundation replacement can preserve this old destination mode. The
    // update must restore the owner-only daemon contract before credential migration.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: paths.installedDaemon.path)
    try makeExecutable(daemon, bytes: "daemon-v2")
    try makeExecutable(hdc, bytes: "hdc-v2")
    runner.removeAllCommands()
    let signingAccessRefresh = CallbackFlag()
    let commandRunner = try XCTUnwrap(runner)
    let installedDaemonPath = paths.installedDaemon.path

    try RuntimeCLI.runAgentDaemon(
      ["update", "--daemon", daemonBundle.path, "--hdc", hdc.path, "--json"],
      service: service,
      beforeBootstrap: {
        XCTAssertFalse(
          commandRunner.commands.contains { $0.first == "bootstrap" },
          "signing Keychain migration must finish before the replacement daemon starts")
        var installedInfo = stat()
        XCTAssertEqual(
          installedDaemonPath.withCString { lstat($0, &installedInfo) }, 0)
        XCTAssertEqual(Int(installedInfo.st_mode & 0o777), 0o700)
        signingAccessRefresh.mark()
      })

    let refreshed = try JSONDecoder().decode(
      LaunchAgentInstallReceipt.self, from: Data(contentsOf: paths.receipt))
    XCTAssertNotEqual(refreshed.daemonSHA256, oldReceipt.daemonSHA256)
    XCTAssertNotEqual(refreshed.hdcSHA256, oldReceipt.hdcSHA256)
    XCTAssertEqual(refreshed.daemonSHA256, try digest(paths.installedDaemon))
    XCTAssertTrue(signingAccessRefresh.isMarked)
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

  func testInstallPinsArkTraceDescriptorAndUpdatePreservesOrExplicitlyRemovesIt() throws {
    let descriptor = root.appending(path: "ArkTrace/distribution-descriptor.json")
    try makeArkTraceDescriptor(descriptor)

    let receipt = try service.install(
      daemonBundleSource: daemonBundle, hdcExecutable: hdc,
      arkTraceDescriptor: descriptor, arkForgeLane: nil)
    let physicalDescriptorPath =
      descriptor.path == "/var" || descriptor.path.hasPrefix("/var/")
      ? "/private" + descriptor.path : descriptor.path
    let expected = LaunchAgentArkTraceDescriptorStatus(
      descriptorPath: physicalDescriptorPath,
      descriptorSHA256: try digest(descriptor),
      descriptorByteCount: try Data(contentsOf: descriptor).count)
    XCTAssertEqual(receipt.arkTraceDescriptor, expected)
    var environment = try XCTUnwrap(
      (try plist(at: paths.plist))["EnvironmentVariables"] as? [String: String])
    XCTAssertEqual(environment["ARKDECK_ARKTRACE_DESCRIPTOR"], physicalDescriptorPath)
    XCTAssertEqual(try service.status().arkTraceDescriptor, expected)

    try RuntimeCLI.runAgentDaemon(
      ["update", "--daemon", daemonBundle.path, "--json"], service: service)
    environment = try XCTUnwrap(
      (try plist(at: paths.plist))["EnvironmentVariables"] as? [String: String])
    XCTAssertEqual(environment["ARKDECK_ARKTRACE_DESCRIPTOR"], physicalDescriptorPath)
    XCTAssertEqual(try service.status().arkTraceDescriptor, expected)

    try RuntimeCLI.runAgentDaemon(
      [
        "update", "--daemon", daemonBundle.path,
        "--arktrace-descriptor", "none", "--json",
      ], service: service)
    environment = try XCTUnwrap(
      (try plist(at: paths.plist))["EnvironmentVariables"] as? [String: String])
    XCTAssertNil(environment["ARKDECK_ARKTRACE_DESCRIPTOR"])
    XCTAssertNil(try service.status().arkTraceDescriptor)
  }

  func testArkTraceDescriptorFailsClosedOnUnsafePathSchemaAndIdentityDrift() throws {
    let descriptor = root.appending(path: "ArkTrace/distribution-descriptor.json")
    try makeArkTraceDescriptor(descriptor)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o666], ofItemAtPath: descriptor.path)
    XCTAssertThrowsError(
      try service.install(
        daemonBundleSource: daemonBundle, hdcExecutable: hdc,
        arkTraceDescriptor: descriptor, arkForgeLane: nil)
    ) { error in
      XCTAssertTrue("\(error)".contains("owner-controlled"), "unexpected error: \(error)")
    }
    XCTAssertTrue(runner.commands.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.plist.path))

    try makeArkTraceDescriptor(descriptor)
    let symbolic = root.appending(path: "ArkTrace/symbolic-descriptor.json")
    try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: descriptor)
    XCTAssertThrowsError(
      try service.install(
        daemonBundleSource: daemonBundle, hdcExecutable: hdc,
        arkTraceDescriptor: symbolic, arkForgeLane: nil)
    ) { error in
      XCTAssertTrue("\(error)".contains("physical regular file"), "unexpected error: \(error)")
    }
    XCTAssertTrue(runner.commands.isEmpty)

    let external = root.appending(path: "external", directoryHint: .isDirectory)
    let externalDescriptor = external.appending(path: "distribution-descriptor.json")
    try makeArkTraceDescriptor(externalDescriptor)
    let symbolicParent = root.appending(path: "symbolic-parent", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: symbolicParent, withDestinationURL: external)
    XCTAssertThrowsError(
      try service.install(
        daemonBundleSource: daemonBundle, hdcExecutable: hdc,
        arkTraceDescriptor: symbolicParent.appending(path: "distribution-descriptor.json"),
        arkForgeLane: nil)
    ) { error in
      XCTAssertTrue(
        "\(error)".contains("symbolic ancestor"), "unexpected error: \(error)")
    }
    XCTAssertTrue(runner.commands.isEmpty)

    try Data(#"{"formatVersion":1}"#.utf8).write(to: descriptor, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: descriptor.path)
    XCTAssertThrowsError(
      try service.install(
        daemonBundleSource: daemonBundle, hdcExecutable: hdc,
        arkTraceDescriptor: descriptor, arkForgeLane: nil)
    ) { error in
      XCTAssertTrue("\(error)".contains("schema is invalid"), "unexpected error: \(error)")
    }

    try makeArkTraceDescriptor(descriptor)
    _ = try service.install(
      daemonBundleSource: daemonBundle, hdcExecutable: hdc,
      arkTraceDescriptor: descriptor, arkForgeLane: nil)
    try Data(
      #"{"distributionRoot":"/changed","formatVersion":1,"manifestSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#.utf8
    ).write(to: descriptor, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: descriptor.path)
    let status = try service.status()
    XCTAssertFalse(status.ready)
    XCTAssertTrue(
      status.diagnostics.contains(
        "ArkTrace distribution descriptor drifted since installation"),
      "unexpected diagnostics: \(status.diagnostics)")
    XCTAssertThrowsError(
      try RuntimeCLI.runAgentDaemon(
        ["update", "--daemon", daemonBundle.path, "--json"], service: service)
    ) { error in
      XCTAssertTrue(
        "\(error)".contains("pass --arktrace-descriptor explicitly"),
        "unexpected error: \(error)")
    }
  }

  func testIdenticalExecutableUpdateRevalidatesBundleAndCredentialIdentity() throws {
    _ = try service.install(daemonBundleSource: daemonBundle, hdcExecutable: hdc)
    runner.removeAllCommands()
    let identityRefresh = CallbackFlag()
    try Data("profile-v2".utf8).write(
      to: daemonBundle.appending(path: "Contents/embedded.provisionprofile"))

    _ = try service.install(
      daemonBundleSource: daemonBundle, hdcExecutable: hdc,
      beforeBootstrap: { identityRefresh.mark() })

    XCTAssertTrue(identityRefresh.isMarked)
    XCTAssertEqual(
      try Data(
        contentsOf: paths.installedDaemonBundle.appending(
          path:
            "Contents/embedded.provisionprofile")),
      Data("profile-v2".utf8),
      "a renewed signing profile must not be skipped when executable bytes are unchanged")
    XCTAssertEqual(try permissions(paths.installedDaemon), 0o700)
    XCTAssertEqual(
      runner.commands,
      [
        ["print", "gui/501/\(ArkDeckLaunchAgent.label)"],
        ["bootout", "gui/501/\(ArkDeckLaunchAgent.label)"],
        ["bootstrap", "gui/501", paths.plist.path],
      ])
  }

  func testCredentialRefreshFailureRestartsValidatedReplacementBeforeReturningError()
    throws
  {
    _ = try service.install(daemonBundleSource: daemonBundle, hdcExecutable: hdc)
    try makeExecutable(daemon, bytes: "daemon-v2")
    runner.removeAllCommands()

    XCTAssertThrowsError(
      try service.install(
        daemonBundleSource: daemonBundle, hdcExecutable: hdc,
        beforeBootstrap: { throw CredentialRefreshFixtureError.refused }))

    XCTAssertEqual(
      runner.commands,
      [
        ["print", "gui/501/\(ArkDeckLaunchAgent.label)"],
        ["bootout", "gui/501/\(ArkDeckLaunchAgent.label)"],
        ["bootstrap", "gui/501", paths.plist.path],
      ])
    XCTAssertTrue(try service.status().loaded)
    XCTAssertEqual(try digest(paths.installedDaemon), try digest(daemon))
  }

  func testInstallPersistsValidatedWaterFlowWorkspaceForHeadlessGJ5AndUpdateKeepsIt()
    throws
  {
    let project = root.appending(path: "WaterFlowLayoutDemo", directoryHint: .isDirectory)
    let module = project.appending(path: "entry/src/main", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: project.appending(path: "build-profile.json5"))
    try Data("{}".utf8).write(to: module.appending(path: "module.json5"))
    let sdk = root.appending(path: "DevEco/sdk", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: sdk.appending(path: "default/openharmony", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    let modelCLI = root.appending(path: "model-cli/claude")
    try makeExecutable(modelCLI, bytes: "claude-cli-v1")
    let harnessModel = LaunchAgentHarnessModelConfiguration(
      provider: "claude-code", modelName: "sonnet", cliExecutable: modelCLI,
      cliWorkingDirectory: project, cliTimeoutSeconds: 900)

    let receipt = try service.install(
      daemonBundleSource: daemonBundle, hdcExecutable: hdc,
      workspace: LaunchAgentWorkspaceConfiguration(
        projectRoot: project, devecoSDKRoot: sdk),
      harnessSensitiveEvidence: ["hilog.txt", "crash-index.txt"],
      harnessModel: harnessModel)
    XCTAssertEqual(receipt.workspaceProjectPath, project.path)
    XCTAssertEqual(receipt.devecoSDKPath, sdk.path)
    XCTAssertEqual(receipt.harnessSensitiveEvidence, ["crash-index.txt", "hilog.txt"])
    XCTAssertEqual(receipt.harnessModel?.provider, "claude-code")
    XCTAssertEqual(receipt.harnessModel?.cliPath, modelCLI.path)
    XCTAssertEqual(receipt.harnessModel?.cliSHA256, try digest(modelCLI))
    XCTAssertEqual(receipt.harnessModel?.egressProjects, ["demo-app"])

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
    XCTAssertEqual(environment["ARKDECK_HARNESS_MODEL_PROVIDER"], "claude-code")
    XCTAssertEqual(environment["ARKDECK_HARNESS_MODEL_NAME"], "sonnet")
    XCTAssertEqual(environment["ARKDECK_HARNESS_CLI_PATH"], modelCLI.path)
    XCTAssertEqual(environment["ARKDECK_HARNESS_CLI_WORKDIR"], project.path)
    XCTAssertEqual(environment["ARKDECK_HARNESS_CLI_TIMEOUT_SECONDS"], "900")
    XCTAssertEqual(environment["ARKDECK_HARNESS_EGRESS_PROJECTS"], "demo-app")

    try FileManager.default.createDirectory(
      at: paths.stateDirectory, withIntermediateDirectories: true)
    XCTAssertTrue(FileManager.default.createFile(atPath: paths.socket.path, contents: Data()))
    var status = try service.status()
    XCTAssertTrue(status.ready, "\(status.diagnostics)")
    XCTAssertEqual(status.workspaceProjectPath, project.path)
    XCTAssertEqual(status.devecoSDKPath, sdk.path)
    XCTAssertEqual(status.harnessSensitiveEvidence, ["crash-index.txt", "hilog.txt"])
    XCTAssertEqual(status.harnessModel, receipt.harnessModel)

    try makeExecutable(daemon, bytes: "daemon-v2")
    try RuntimeCLI.runAgentDaemon(
      ["update", "--daemon", daemonBundle.path, "--json"], service: service)
    environment = try XCTUnwrap(
      (try plist(at: paths.plist))["EnvironmentVariables"] as? [String: String])
    XCTAssertEqual(environment["ARKDECK_WORKSPACE_PROJECTS"], "demo-app=\(project.path)")
    XCTAssertEqual(environment["ARKDECK_DEVECO_SDK_HOME"], sdk.path)
    XCTAssertEqual(
      environment["ARKDECK_HARNESS_SENSITIVE_EVIDENCE"],
      "crash-index.txt,hilog.txt")
    XCTAssertEqual(environment["ARKDECK_HARNESS_MODEL_PROVIDER"], "claude-code")
    XCTAssertEqual(environment["ARKDECK_HARNESS_CLI_PATH"], modelCLI.path)
    status = try service.status()
    XCTAssertEqual(status.workspaceProjectPath, project.path)
    XCTAssertEqual(status.harnessSensitiveEvidence, ["crash-index.txt", "hilog.txt"])
    XCTAssertEqual(status.harnessModel, receipt.harnessModel)

    try RuntimeCLI.runAgentDaemon(
      ["update", "--daemon", daemonBundle.path, "--sensitive-evidence", "none", "--json"],
      service: service)
    environment = try XCTUnwrap(
      (try plist(at: paths.plist))["EnvironmentVariables"] as? [String: String])
    XCTAssertNil(environment["ARKDECK_HARNESS_SENSITIVE_EVIDENCE"])
    XCTAssertEqual(try service.status().harnessSensitiveEvidence, [])

    try RuntimeCLI.runAgentDaemon(
      ["update", "--daemon", daemonBundle.path, "--harness-model-provider", "none", "--json"],
      service: service)
    environment = try XCTUnwrap(
      (try plist(at: paths.plist))["EnvironmentVariables"] as? [String: String])
    XCTAssertNil(environment["ARKDECK_HARNESS_MODEL_PROVIDER"])
    XCTAssertNil(environment["ARKDECK_HARNESS_MODEL_NAME"])
    XCTAssertNil(environment["ARKDECK_HARNESS_CLI_PATH"])
    XCTAssertNil(environment["ARKDECK_HARNESS_CLI_WORKDIR"])
    XCTAssertNil(environment["ARKDECK_HARNESS_CLI_TIMEOUT_SECONDS"])
    XCTAssertNil(environment["ARKDECK_HARNESS_EGRESS_PROJECTS"])
    XCTAssertNil(try service.status().harnessModel)
  }

  func testWorkspaceConfigurationFailsClosedUnlessProjectAndSDKAreBothValid() throws {
    XCTAssertThrowsError(
      try RuntimeCLI.runAgentDaemon(
        [
          "install", "--daemon", daemonBundle.path, "--hdc", hdc.path,
          "--workspace-project", root.path,
        ],
        service: service)
    ) { error in
      XCTAssertTrue("\(error)".contains("--workspace-project and --deveco-sdk together"))
    }

    let missingProject = root.appending(path: "missing-project", directoryHint: .isDirectory)
    let missingSDK = root.appending(path: "missing-sdk", directoryHint: .isDirectory)
    XCTAssertThrowsError(
      try service.install(
        daemonBundleSource: daemonBundle, hdcExecutable: hdc,
        workspace: LaunchAgentWorkspaceConfiguration(
          projectRoot: missingProject, devecoSDKRoot: missingSDK)))

    let protectedProject = paths.homeDirectory.appending(
      path:
        "Downloads/WaterFlowLayoutDemo", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: protectedProject.appending(path: "entry/src/main", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try Data("{}".utf8).write(
      to: protectedProject.appending(path: "build-profile.json5"))
    try Data("{}".utf8).write(
      to: protectedProject.appending(path: "entry/src/main/module.json5"))
    let validSDK = root.appending(path: "valid-sdk", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: validSDK.appending(path: "default/openharmony", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    XCTAssertThrowsError(
      try service.install(
        daemonBundleSource: daemonBundle, hdcExecutable: hdc,
        workspace: LaunchAgentWorkspaceConfiguration(
          projectRoot: protectedProject, devecoSDKRoot: validSDK))
    ) { error in
      XCTAssertTrue("\(error)".contains("macOS privacy-managed"))
      XCTAssertTrue("\(error)".contains("~/Developer"))
    }
    XCTAssertTrue(runner.commands.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.plist.path))

    for invalid in [["../crash-index.txt"], ["hilog.txt", "hilog.txt"], [""]] {
      XCTAssertThrowsError(
        try service.install(
          daemonBundleSource: daemonBundle, hdcExecutable: hdc,
          harnessSensitiveEvidence: invalid)
      ) { error in
        XCTAssertTrue("\(error)".contains("unique safe artifact basenames"))
      }
    }

    let modelCLI = root.appending(path: "model-cli/codex")
    try makeExecutable(modelCLI, bytes: "codex-cli-v1")
    XCTAssertThrowsError(
      try service.install(
        daemonBundleSource: daemonBundle, hdcExecutable: hdc,
        harnessModel: LaunchAgentHarnessModelConfiguration(
          provider: "codex", modelName: "gpt-5", cliExecutable: modelCLI,
          cliWorkingDirectory: root))
    ) { error in
      XCTAssertTrue("\(error)".contains("requires the validated demo-app workspace"))
    }
    XCTAssertThrowsError(
      try RuntimeCLI.runAgentDaemon(
        [
          "install", "--daemon", daemonBundle.path, "--hdc", hdc.path,
          "--harness-cli", modelCLI.path,
        ],
        service: service)
    ) { error in
      XCTAssertTrue("\(error)".contains("require --harness-model-provider"))
    }
  }

  func testHarnessLocalModelConfigurationFailsClosedOnProviderAndIdentityDrift() throws {
    let project = root.appending(path: "WaterFlowLayoutDemo", directoryHint: .isDirectory)
    let module = project.appending(path: "entry/src/main", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: project.appending(path: "build-profile.json5"))
    try Data("{}".utf8).write(to: module.appending(path: "module.json5"))
    let sdk = root.appending(path: "DevEco/sdk", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: sdk.appending(path: "default/openharmony", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    let modelCLI = root.appending(path: "model-cli/codex")
    try makeExecutable(modelCLI, bytes: "codex-cli-v1")
    let workspace = LaunchAgentWorkspaceConfiguration(
      projectRoot: project, devecoSDKRoot: sdk)

    XCTAssertThrowsError(
      try service.install(
        daemonBundleSource: daemonBundle, hdcExecutable: hdc, workspace: workspace,
        harnessModel: LaunchAgentHarnessModelConfiguration(
          provider: "shell", modelName: "anything", cliExecutable: modelCLI,
          cliWorkingDirectory: project))
    ) { error in
      XCTAssertTrue("\(error)".contains("must be codex or claude-code"))
    }

    _ = try service.install(
      daemonBundleSource: daemonBundle, hdcExecutable: hdc, workspace: workspace,
      harnessModel: LaunchAgentHarnessModelConfiguration(
        provider: "codex", modelName: "gpt-5", cliExecutable: modelCLI,
        cliWorkingDirectory: project))
    try FileManager.default.createDirectory(
      at: paths.stateDirectory, withIntermediateDirectories: true)
    XCTAssertTrue(FileManager.default.createFile(atPath: paths.socket.path, contents: Data()))
    try makeExecutable(modelCLI, bytes: "unreviewed-model-cli-replacement")

    let status = try service.status()
    XCTAssertFalse(status.ready)
    XCTAssertTrue(
      status.diagnostics.contains(
        "Harness local model configuration drifted since installation"))
  }

  func testStatusNamesHDCIdentityDriftAndUninstallPreservesStateAndLogs() throws {
    _ = try service.install(daemonBundleSource: daemonBundle, hdcExecutable: hdc)
    try makeExecutable(hdc, bytes: "unreviewed-hdc-replacement")
    let stateMarker = paths.stateDirectory.appending(path: "jobs.sqlite")
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
    _ = try service.install(daemonBundleSource: daemonBundle, hdcExecutable: hdc)
    runner.removeAllCommands()
    runner.failNextBootstrapWithEIO()

    _ = try service.install(daemonBundleSource: daemonBundle, hdcExecutable: hdc)

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
    let nonExecutable = root.appending(path: "not-executable")
    try Data("bytes".utf8).write(to: nonExecutable)

    XCTAssertThrowsError(
      try service.install(daemonBundleSource: nonExecutable, hdcExecutable: hdc))
    XCTAssertThrowsError(
      try service.install(
        daemonBundleSource: daemonBundle,
        hdcExecutable: root.appending(path: "missing-hdc")))
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

  private func makeDaemonBundle(_ url: URL) throws {
    let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: contents.appending(path: "MacOS", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    let info: [String: Any] = [
      "CFBundleIdentifier": ArkDeckHelperIdentity.daemonBundleIdentifier,
      "CFBundleExecutable": ArkDeckHelperIdentity.daemonExecutableName,
      "CFBundlePackageType": "APPL",
    ]
    try PropertyListSerialization.data(
      fromPropertyList: info, format: .xml, options: 0
    ).write(to: contents.appending(path: "Info.plist"))
  }

  private func makeArkTraceDescriptor(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(
      #"{"distributionRoot":"/reviewed/ArkTraceCLI-0.1.0","formatVersion":1,"manifestSHA256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}"#.utf8
    ).write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func plist(at url: URL) throws -> [String: Any] {
    try XCTUnwrap(
      PropertyListSerialization.propertyList(
        from: Data(contentsOf: url), options: [], format: nil) as? [String: Any])
  }

  private var packageRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func digest(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url))
      .map { String(format: "%02x", $0) }.joined()
  }

  private func permissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
  }
}

private final class CallbackFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var marked = false

  var isMarked: Bool { lock.withLock { marked } }
  func mark() { lock.withLock { marked = true } }
}

private enum CredentialRefreshFixtureError: Error {
  case refused
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

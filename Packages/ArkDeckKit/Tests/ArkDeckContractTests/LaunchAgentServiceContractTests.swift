import CryptoKit
import Darwin
import XCTest

@testable import ArkDeckAgentComposition
@testable import ArkDeckBootstrap
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

  func testPreservingUpdateMigratesLegacyThreeKeyLaneToOneBundle() throws {
    let bundle = try makeArkForgeBundle(
      at: root.appending(path: "ArkForge.bundle", directoryHint: .isDirectory))
    try FileManager.default.createDirectory(
      at: paths.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
    let environment = [
      "ARKDECK_ARKFORGED_PATH": bundle.daemon.path,
      "ARKDECK_ARKFORGED_SHA256": bundle.daemonSHA256,
      "ARKDECK_ARKFORGE_PROFILE_PATH": bundle.profile.path,
      "ARKDECK_RKDEVELOPTOOL_PATH": "/legacy/rkdeveloptool",
      "ARKDECK_ARKFORGE_CAMPAIGN": "AFA-AC-7",
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["EnvironmentVariables": environment],
      format: .xml, options: 0)
    try data.write(to: paths.plist)

    let migrated = try XCTUnwrap(service.arkForgeLaneForPreservingUpdate())

    XCTAssertEqual(migrated.bundlePath, bundle.root.path)
    XCTAssertEqual(migrated.manifestSHA256, bundle.manifestSHA256)
    XCTAssertEqual(migrated.daemonPath, bundle.daemon.path)
    XCTAssertEqual(migrated.campaign, "AFA-AC-7")
    XCTAssertEqual(
      Set(migrated.environment.keys),
      Set(ArkDeckLaunchAgent.arkForgeEnvironmentKeys + [
        ArkDeckLaunchAgent.arkForgeCampaignEnvironmentKey
      ]))
    XCTAssertNil(migrated.environment["ARKDECK_RKDEVELOPTOOL_PATH"])
  }

  func testInstallReceiptAndPlistPinOneArkForgeBundle() throws {
    let bundle = try makeArkForgeBundle(
      at: root.appending(path: "ArkForge.bundle", directoryHint: .isDirectory))
    let lane = try LaunchAgentArkForgeLaneStatus.measuring(bundlePath: bundle.root.path)

    let receipt = try service.install(
      daemonBundleSource: daemonBundle, hdcExecutable: hdc,
      arkTraceDescriptor: nil, arkForgeLane: lane)

    XCTAssertEqual(receipt.arkForgeLane, lane)
    let environment = try XCTUnwrap(
      (try plist(at: paths.plist))["EnvironmentVariables"] as? [String: String])
    XCTAssertEqual(environment["ARKDECK_ARKFORGE_BUNDLE_PATH"], bundle.root.path)
    for key in ArkDeckLaunchAgent.legacyArkForgeEnvironmentKeys {
      XCTAssertNil(environment[key])
    }
    XCTAssertEqual(try service.status().arkForgeLane, lane)
  }

  func testLegacyMigrationRefusesPartialOrCrossBundleInputs() throws {
    let first = try makeArkForgeBundle(
      at: root.appending(path: "First.bundle", directoryHint: .isDirectory))
    let second = try makeArkForgeBundle(
      at: root.appending(path: "Second.bundle", directoryHint: .isDirectory))
    try FileManager.default.createDirectory(
      at: paths.plist.deletingLastPathComponent(), withIntermediateDirectories: true)

    func writeEnvironment(_ environment: [String: String]) throws {
      try PropertyListSerialization.data(
        fromPropertyList: ["EnvironmentVariables": environment], format: .xml, options: 0
      ).write(to: paths.plist)
    }

    try writeEnvironment(["ARKDECK_ARKFORGED_PATH": first.daemon.path])
    XCTAssertThrowsError(try service.arkForgeLaneForPreservingUpdate()) { error in
      XCTAssertTrue("\(error)".contains("partial"), "\(error)")
    }

    try writeEnvironment([
      "ARKDECK_ARKFORGED_PATH": first.daemon.path,
      "ARKDECK_ARKFORGED_SHA256": first.daemonSHA256,
      "ARKDECK_ARKFORGE_PROFILE_PATH": second.profile.path,
    ])
    XCTAssertThrowsError(try service.arkForgeLaneForPreservingUpdate()) { error in
      XCTAssertTrue("\(error)".contains("one validated"), "\(error)")
    }
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
      "swift build --package-path \"$package_root\" --arch arm64 -c release --product arkdeck",
      "swift build --package-path \"$package_root\" --arch arm64 -c release --product arkdeck-agentd",
      "swift build --package-path \"$package_root\" --arch arm64 -c release --show-bin-path",
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

    let localScript = try String(
      contentsOf: distribution.appending(path: "build-local-helpers.sh"), encoding: .utf8)
    for requiredStep in [
      "security cms -D",
      "security find-identity -v -p codesigning",
      "swift build --package-path \"$package_root\" --arch arm64 -c debug --product arkdeck",
      "swift build --package-path \"$package_root\" --arch arm64 -c debug --product arkdeck-agentd",
      "swift build --package-path \"$package_root\" --arch arm64 -c debug --show-bin-path",
      "codesign --verify --strict --deep",
      "--options runtime --timestamp=none",
      "LOCAL-DEVELOPMENT-BUILD.txt",
      "-e \"$output_root\" || -L \"$output_root\"",
      "cp -R \"$workflows_resource_bundle\" \"$cli_bundle/Contents/Resources/\"",
      "cp -R \"$workflows_resource_bundle\" \"$daemon_bundle/Contents/Resources/\"",
      "cp -R \"$launch_agent_resource_bundle\" \"$cli_bundle/Contents/Resources/\"",
    ] {
      XCTAssertTrue(
        localScript.contains(requiredStep),
        "local helper pipeline must retain \(requiredStep)")
    }
    for releaseOnlyStep in [
      "ARKDECK_NOTARY_KEYCHAIN_PROFILE", "notarytool", "stapler", "spctl",
    ] {
      XCTAssertFalse(
        localScript.contains(releaseOnlyStep),
        "local helper pipeline must stay separate from release step \(releaseOnlyStep)")
      XCTAssertTrue(
        releaseScript.contains(releaseOnlyStep),
        "release helper pipeline must retain \(releaseOnlyStep)")
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
      spelledAs: "agentd", service: service,
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

  func testTargetServiceInstallsRegisteredResourcesOnlyOnTheZeroRuntimePath() throws {
    let bootstrapOwner = BootstrapBundleRegistry(
      root: root.appending(path: "bootstrap"), validateBundle: { _ in })
    let tools = BootstrapToolRegistry(
      owner: bootstrapOwner,
      knownIdentity: { _ in
        BootstrapToolRegistry.PublishedIdentity(
          version: "fixture-1", profileReferences: ["fixture-profile"])
      })
    let nativeHDC = root.appending(path: "registered-hdc")
    try FileManager.default.copyItem(
      at: Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        .appending(path: "ArkDeckFakeHDCFixture"),
      to: nativeHDC)
    let firstBundle = try object(bootstrapOwner.register(file: daemonBundle))
    let tool = try object(tools.register(file: nativeHDC))
    let firstBundleReference = try string(firstBundle["bundleRef"])
    let toolReference = try string(tool["toolRef"])

    XCTAssertThrowsError(
      try RuntimeCLI.runAgentDaemon(
        ["install", "--daemon", daemonBundle.path, "--hdc", nativeHDC.path],
        spelledAs: "runtime.service", service: service,
        bundleRegistry: bootstrapOwner, toolRegistry: tools))
    XCTAssertTrue(runner.commands.isEmpty, "raw target inputs must fail before launchctl")

    XCTAssertThrowsError(
      try RuntimeCLI.runAgentDaemon(
        [
          "install", "--bundle", firstBundleReference, "--bundle-generation", "2",
          "--tool", toolReference, "--tool-generation", "1",
        ],
        spelledAs: "runtime.service", service: service,
        bundleRegistry: bootstrapOwner, toolRegistry: tools))
    guard case .array(let ownersBeforeAcquire)? = try object(
      bootstrapOwner.inspect(firstBundleReference))["references"]
    else { return XCTFail("bundle reference projection is malformed") }
    XCTAssertEqual(ownersBeforeAcquire, [])
    XCTAssertNil(try tools.startupSelection())

    XCTAssertThrowsError(
      try RuntimeCLI.runAgentDaemon(
        [
          "install", "--bundle", firstBundleReference, "--bundle-generation", "1",
          "--tool", toolReference, "--tool-generation", "2",
        ],
        spelledAs: "runtime.service", service: service,
        bundleRegistry: bootstrapOwner, toolRegistry: tools))
    guard case .array(let retainedAfterToolFailure)? = try object(
      bootstrapOwner.inspect(firstBundleReference))["references"]
    else { return XCTFail("bundle reference projection is malformed") }
    XCTAssertEqual(retainedAfterToolFailure.count, 1)
    XCTAssertNil(try tools.startupSelection())
    XCTAssertTrue(runner.commands.isEmpty, "generation drift must fail before launchctl")

    try RuntimeCLI.runAgentDaemon(
      [
        "install", "--bundle", firstBundleReference, "--bundle-generation", "1",
        "--tool", toolReference, "--tool-generation", "1",
      ],
      spelledAs: "runtime.service", service: service,
      bundleRegistry: bootstrapOwner, toolRegistry: tools)
    XCTAssertEqual(try XCTUnwrap(tools.startupSelection()).toolRef, toolReference)
    guard case .array(let firstOwners)? = try object(
      bootstrapOwner.inspect(firstBundleReference))["references"]
    else { return XCTFail("installed bundle omitted its durable reference") }
    XCTAssertEqual(firstOwners.count, 1)
    XCTAssertEqual(try service.status().hdcSHA256, try digest(nativeHDC))

    runner.removeAllCommands()
    XCTAssertThrowsError(
      try RuntimeCLI.runAgentDaemon(
        [
          "install", "--bundle", firstBundleReference, "--bundle-generation", "1",
          "--tool", toolReference, "--tool-generation", "1",
        ],
        spelledAs: "runtime.service", service: service,
        bundleRegistry: bootstrapOwner, toolRegistry: tools)
    ) { error in
      XCTAssertTrue("\(error)".contains("zero-Runtime bootstrap path"), "\(error)")
    }
    XCTAssertEqual(
      runner.commands, [["print", "gui/501/\(ArkDeckLaunchAgent.label)"]],
      "an existing service must be read, then refused without lifecycle mutation")

    try RuntimeCLI.runAgentDaemon(
      ["uninstall"], spelledAs: "runtime.service", service: service,
      bundleRegistry: bootstrapOwner, toolRegistry: tools)
    XCTAssertNoThrow(
      try bootstrapOwner.remove(firstBundleReference, expectedGeneration: "1"))
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
      ["update", "--daemon", daemonBundle.path, "--json"],
      spelledAs: "agentd", service: service)
    environment = try XCTUnwrap(
      (try plist(at: paths.plist))["EnvironmentVariables"] as? [String: String])
    XCTAssertEqual(environment["ARKDECK_ARKTRACE_DESCRIPTOR"], physicalDescriptorPath)
    XCTAssertEqual(try service.status().arkTraceDescriptor, expected)

    try RuntimeCLI.runAgentDaemon(
      [
        "update", "--daemon", daemonBundle.path,
        "--arktrace-descriptor", "none", "--json",
      ], spelledAs: "agentd", service: service)
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
        ["update", "--daemon", daemonBundle.path, "--json"],
        spelledAs: "agentd", service: service)
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
    let receipt = try service.install(
      daemonBundleSource: daemonBundle, hdcExecutable: hdc,
      workspace: LaunchAgentWorkspaceConfiguration(
        projectRoot: project, devecoSDKRoot: sdk))
    XCTAssertEqual(receipt.workspaceProjectPath, project.path)
    XCTAssertEqual(receipt.devecoSDKPath, sdk.path)

    var environment = try XCTUnwrap(
      (try plist(at: paths.plist))["EnvironmentVariables"] as? [String: String])
    XCTAssertEqual(environment["ARKDECK_WORKSPACE_PROJECTS"], "demo-app=\(project.path)")
    XCTAssertEqual(environment["ARKDECK_WORKSPACE_ACTIVE_PROJECT"], "demo-app")
    XCTAssertEqual(environment["ARKDECK_DEVECO_SDK_HOME"], sdk.path)
    XCTAssertEqual(environment["ARKDECK_ANALYZER_PATH"], paths.installedDaemon.path)
    XCTAssertEqual(environment["ARKDECK_WORKSPACE_INSPECTOR"], "/usr/bin/grep")

    try FileManager.default.createDirectory(
      at: paths.stateDirectory, withIntermediateDirectories: true)
    XCTAssertTrue(FileManager.default.createFile(atPath: paths.socket.path, contents: Data()))
    var status = try service.status()
    XCTAssertTrue(status.ready, "\(status.diagnostics)")
    XCTAssertEqual(status.workspaceProjectPath, project.path)
    XCTAssertEqual(status.devecoSDKPath, sdk.path)

    try makeExecutable(daemon, bytes: "daemon-v2")
    try RuntimeCLI.runAgentDaemon(
      ["update", "--daemon", daemonBundle.path, "--json"],
      spelledAs: "agentd", service: service)
    environment = try XCTUnwrap(
      (try plist(at: paths.plist))["EnvironmentVariables"] as? [String: String])
    XCTAssertEqual(environment["ARKDECK_WORKSPACE_PROJECTS"], "demo-app=\(project.path)")
    XCTAssertEqual(environment["ARKDECK_DEVECO_SDK_HOME"], sdk.path)
    status = try service.status()
    XCTAssertEqual(status.workspaceProjectPath, project.path)

    // Migration (CHG-2026-064): a plist installed before the decision-plane
    // removal still carries gateway keys. `agentd update` reads the legacy
    // configuration, ignores those keys, and regenerates the plist without
    // them — that is how a live machine sheds the removed plane.
    var document = try XCTUnwrap(try plist(at: paths.plist))
    var legacyEnvironment = try XCTUnwrap(
      document["EnvironmentVariables"] as? [String: String])
    legacyEnvironment["ARKDECK_HARNESS_MODEL_PROVIDER"] = "codex"
    legacyEnvironment["ARKDECK_HARNESS_MODEL_NAME"] = "gpt-5.6-terra"
    // The credential pair is the reason this assertion matters. `agent chat`
    // is deleted, so nothing reads these any more — but a machine that ran the
    // old build still has an API key sitting in a plist that every process the
    // daemon spawns would inherit. `update` regenerates from the bundled
    // template rather than editing the old plist, so the key is dropped by
    // construction; this pins that, because the daemon now refuses to start
    // while any `ARKDECK_HARNESS_*` key survives.
    legacyEnvironment["ARKDECK_HARNESS_MODEL_API_KEY"] = "sk-live-should-not-survive"
    legacyEnvironment["ARKDECK_HARNESS_MODEL_ENDPOINT"] = "https://api.openai.com/v1"
    legacyEnvironment["ARKDECK_HARNESS_CLI_PATH"] = "/usr/bin/true"
    legacyEnvironment["ARKDECK_HARNESS_CLI_WORKDIR"] = project.path
    legacyEnvironment["ARKDECK_HARNESS_CLI_TIMEOUT_SECONDS"] = "300"
    legacyEnvironment["ARKDECK_HARNESS_EGRESS_PROJECTS"] = "demo-app"
    legacyEnvironment["ARKDECK_HARNESS_SENSITIVE_EVIDENCE"] = "hilog.txt"
    document["EnvironmentVariables"] = legacyEnvironment
    try PropertyListSerialization.data(
      fromPropertyList: document, format: .xml, options: 0
    ).write(to: paths.plist, options: .atomic)

    try RuntimeCLI.runAgentDaemon(
      ["update", "--daemon", daemonBundle.path, "--json"],
      spelledAs: "agentd", service: service)
    environment = try XCTUnwrap(
      (try plist(at: paths.plist))["EnvironmentVariables"] as? [String: String])
    for removed in [
      "ARKDECK_HARNESS_MODEL_PROVIDER", "ARKDECK_HARNESS_MODEL_NAME",
      "ARKDECK_HARNESS_MODEL_API_KEY", "ARKDECK_HARNESS_MODEL_ENDPOINT",
      "ARKDECK_HARNESS_CLI_PATH", "ARKDECK_HARNESS_CLI_WORKDIR",
      "ARKDECK_HARNESS_CLI_TIMEOUT_SECONDS", "ARKDECK_HARNESS_EGRESS_PROJECTS",
      "ARKDECK_HARNESS_SENSITIVE_EVIDENCE",
    ] {
      XCTAssertNil(environment[removed], removed)
    }
    XCTAssertEqual(environment["ARKDECK_WORKSPACE_PROJECTS"], "demo-app=\(project.path)")
  }

  func testTargetUpdateMigratesOutOfTheLegacyWorkspaceConfiguration() throws {
    let project = root.appending(path: "WaterFlowLayoutDemo", directoryHint: .isDirectory)
    let module = project.appending(path: "entry/src/main", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: project.appending(path: "build-profile.json5"))
    try Data("{}".utf8).write(to: module.appending(path: "module.json5"))
    let sdk = root.appending(path: "DevEco/sdk", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: sdk.appending(path: "default/openharmony", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    _ = try service.install(
      daemonBundleSource: daemonBundle, hdcExecutable: hdc,
      workspace: LaunchAgentWorkspaceConfiguration(
        projectRoot: project, devecoSDKRoot: sdk))

    runner.removeAllCommands()
    try RuntimeCLI.runAgentDaemon(
      ["update", "--daemon", daemonBundle.path, "--json"],
      service: service)

    let environment = try XCTUnwrap(
      (try plist(at: paths.plist))["EnvironmentVariables"] as? [String: String])
    for key in [
      ArkDeckLaunchAgent.workspaceProjectsEnvironmentKey,
      ArkDeckLaunchAgent.workspaceActiveProjectEnvironmentKey,
      ArkDeckLaunchAgent.devecoSDKEnvironmentKey,
      ArkDeckLaunchAgent.analyzerEnvironmentKey,
      ArkDeckLaunchAgent.workspaceInspectorEnvironmentKey,
    ] {
      XCTAssertNil(environment[key], key)
    }
    let receipt = try JSONDecoder().decode(
      LaunchAgentInstallReceipt.self, from: Data(contentsOf: paths.receipt))
    XCTAssertNil(receipt.workspaceProjectPath)
    XCTAssertNil(receipt.devecoSDKPath)
    let status = try service.status()
    XCTAssertNil(status.workspaceProjectPath)
    XCTAssertNil(status.devecoSDKPath)
  }

  func testWorkspaceConfigurationFailsClosedUnlessProjectAndSDKAreBothValid() throws {
    XCTAssertThrowsError(
      try RuntimeCLI.runAgentDaemon(
        [
          "install", "--daemon", daemonBundle.path, "--hdc", hdc.path,
          "--workspace-project", root.path,
        ],
        spelledAs: "agentd", service: service)
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

    // Removed by CHG-2026-064: the gateway flags are refused by name so an
    // operator's muscle memory gets a real answer instead of silence.
    for removed in [
      "--sensitive-evidence", "--harness-model-provider", "--harness-model-name",
      "--harness-cli", "--harness-cli-timeout-seconds",
    ] {
      XCTAssertThrowsError(
        try RuntimeCLI.runAgentDaemon(
          ["install", "--daemon", daemonBundle.path, "--hdc", hdc.path, removed, "x"],
          spelledAs: "agentd", service: service)
      ) { error in
        XCTAssertTrue("\(error)".contains("removed by CHG-2026-064"), "\(error)")
      }
    }
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

  func testInstallReenablesPersistentlyDisabledServiceAfterBoundedEIO() throws {
    runner.requireEnableBeforeBootstrap()

    _ = try service.install(daemonBundleSource: daemonBundle, hdcExecutable: hdc)

    XCTAssertEqual(
      runner.commands,
      [
        ["print", "gui/501/\(ArkDeckLaunchAgent.label)"],
        ["bootstrap", "gui/501", paths.plist.path],
        ["bootstrap", "gui/501", paths.plist.path],
        ["bootstrap", "gui/501", paths.plist.path],
        ["enable", "gui/501/\(ArkDeckLaunchAgent.label)"],
        ["bootstrap", "gui/501", paths.plist.path],
      ])
  }

  func testRestartPreservesInstalledIdentityConfigurationAndRuntimeState() throws {
    _ = try service.install(daemonBundleSource: daemonBundle, hdcExecutable: hdc)
    try FileManager.default.createDirectory(
      at: paths.stateDirectory, withIntermediateDirectories: true)
    XCTAssertTrue(FileManager.default.createFile(atPath: paths.socket.path, contents: Data()))
    let stateMarker = paths.stateDirectory.appending(path: "jobs.sqlite")
    try Data("durable-runtime-history".utf8).write(to: stateMarker)
    let instance = LaunchAgentDaemonInstance(
      pid: 4242, socketPath: paths.socket.path,
      protocolVersion: "1.0.0", startedAtUTC: "2026-08-08T11:59:00Z")
    try JSONEncoder().encode(instance).write(
      to: paths.stateDirectory.appending(path: "instance.json"))

    let plistBefore = try Data(contentsOf: paths.plist)
    let daemonBefore = try Data(contentsOf: paths.installedDaemon)
    let installReceiptBefore = try Data(contentsOf: paths.receipt)
    runner.removeAllCommands()

    let restart = try service.restart()

    XCTAssertEqual(restart.schemaVersion, "arkdeck-launchagent-restart/v1")
    XCTAssertEqual(restart.daemonPath, paths.installedDaemon.path)
    XCTAssertEqual(restart.daemonSHA256, try digest(paths.installedDaemon))
    XCTAssertEqual(restart.hdcSHA256, try digest(hdc))
    XCTAssertEqual(restart.preservedStateDirectory, paths.stateDirectory.path)
    XCTAssertEqual(try service.daemonInstance(), instance)
    XCTAssertEqual(try Data(contentsOf: paths.plist), plistBefore)
    XCTAssertEqual(try Data(contentsOf: paths.installedDaemon), daemonBefore)
    XCTAssertEqual(try Data(contentsOf: paths.receipt), installReceiptBefore)
    XCTAssertEqual(try Data(contentsOf: stateMarker), Data("durable-runtime-history".utf8))
    XCTAssertEqual(
      runner.commands,
      [
        ["print", "gui/501/\(ArkDeckLaunchAgent.label)"],
        ["bootout", "gui/501/\(ArkDeckLaunchAgent.label)"],
        ["bootstrap", "gui/501", paths.plist.path],
      ])
  }

  func testRestartPreflightPreservesOnlyClosedUnknownRecoveryJobs() throws {
    func currentJob(
      _ id: String, state: String = "waitingForRecovery",
      outcomeUnknown: Bool = true, waitingForHuman: Bool = false,
      residue: Int = 0, processProgress: JSONValue = .null,
      finishedAtUTC: JSONValue = .string("2026-08-09T03:15:26Z")
    ) -> JSONValue {
      .object([
        "jobId": .string(id), "state": .string(state),
        "outcomeUnknown": .bool(outcomeUnknown),
        "waitingForHuman": .bool(waitingForHuman),
        "outstandingResidueCount": .integer(Int64(residue)),
        "processProgress": processProgress, "finishedAtUtc": finishedAtUTC,
      ])
    }

    let classified = try RuntimeCLI.classifyAgentdRestartCurrentJobs([
      currentJob("job-closed-unknown-b"),
      currentJob("job-running", state: "running", outcomeUnknown: false),
      currentJob("job-cleanup", residue: 1),
      currentJob("job-human", waitingForHuman: true),
      currentJob("job-open-process", processProgress: .object(["phase": .string("running")])),
      currentJob("job-no-finish", finishedAtUTC: .null),
      currentJob("job-closed-unknown-a"),
    ])

    XCTAssertEqual(
      classified.preservedUnknownJobIDs,
      ["job-closed-unknown-a", "job-closed-unknown-b"])
    XCTAssertEqual(
      classified.blockingJobIDs,
      ["job-cleanup", "job-human", "job-no-finish", "job-open-process", "job-running"])
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

  private func object(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let fields) = value else {
      throw CredentialRefreshFixtureError.refused
    }
    return fields
  }

  private func string(_ value: JSONValue?) throws -> String {
    guard case .string(let text)? = value else {
      throw CredentialRefreshFixtureError.refused
    }
    return text
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
  private var bootstrapRequiresEnable = false

  func run(arguments: [String]) throws -> LaunchAgentCommandResult {
    lock.lock()
    defer { lock.unlock() }
    recordedCommands.append(arguments)
    switch arguments.first {
    case "print":
      return LaunchAgentCommandResult(exitStatus: loaded ? 0 : 113)
    case "bootstrap":
      if bootstrapRequiresEnable {
        return LaunchAgentCommandResult(
          exitStatus: EIO, stderr: Data("Bootstrap failed: 5: Input/output error".utf8))
      }
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
    case "enable":
      bootstrapRequiresEnable = false
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

  func requireEnableBeforeBootstrap() {
    lock.lock()
    bootstrapRequiresEnable = true
    lock.unlock()
  }
}

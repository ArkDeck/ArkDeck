import ArkDeckCore
import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class WorkspaceProviderContractTests: XCTestCase {
  private var root: URL!
  private var state: URL!
  private var profile: WorkspaceProjectProfile!
  private var provider: WorkspaceOperationsProvider!
  private var dispatcher: DescriptorBoundProcessDispatcher!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path:
        "arkdeck-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
    state = FileManager.default.temporaryDirectory.appending(
      path:
        "arkdeck-workspace-state-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root.appending(path: "Sources", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try Data("old\n".utf8).write(
      to: root.appending(path: "Sources/App.txt"))

    let grep = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/grep")
    let patch = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/patch")
    let printf = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/printf")
    let cat = try WorkspaceExecutableIdentity.hashing(path: "/bin/cat")
    let inspection = try WorkspaceCommandPreset(
      presetID: "inspect", executable: grep, fixedArguments: [], timeoutSeconds: 10)
    let patching = try WorkspaceCommandPreset(
      presetID: "patch", executable: patch, fixedArguments: [], timeoutSeconds: 10)
    let build = try WorkspaceCommandPreset(
      presetID: "build-ok", executable: printf,
      fixedArguments: ["BUILD_OK\\n"], timeoutSeconds: 10)
    let tests = try WorkspaceCommandPreset(
      presetID: "tests-ok", executable: printf,
      fixedArguments: ["TESTS_OK\\n"], timeoutSeconds: 10)
    let symbols = try WorkspaceCommandPreset(
      presetID: "symbols", executable: cat, fixedArguments: [], timeoutSeconds: 10)
    profile = try WorkspaceProjectProfile(
      profileID: "test-workspace@1", projectRef: "TestProject",
      projectRoot: root.path,
      allowedFileGlobs: ["Sources/**"],
      inspectionPreset: inspection, patchPreset: patching,
      buildPresets: [build.presetID: build],
      testPresets: [tests.presetID: tests],
      symbolPresets: [symbols.presetID: symbols])
    provider = WorkspaceOperationsProvider(
      profile: profile,
      attemptStore: try WorkspacePatchAttemptStore(
        rootURL: state.appending(path: "attempts", directoryHint: .isDirectory)),
      nowUTC: { "2026-07-31T00:00:00Z" })
    dispatcher = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: profile))
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
    if let state { try? FileManager.default.removeItem(at: state) }
  }

  func testFiveOperationsLowerPresetOwnedArgvTokenForToken() async throws {
    let context = executionContext()
    XCTAssertTrue(WorkspaceProviderSupport.matches("Sources/App.txt", glob: "Sources/**"))
    XCTAssertEqual(
      try WorkspaceProviderSupport.files(
        root: profile.projectRoot, profileGlobs: ["Sources/**"],
        requestGlobs: ["Sources/**"]),
      [
        URL(filePath: profile.projectRoot)
          .appending(path: "Sources/App.txt").path
      ])

    XCTAssertTrue(
      WorkspaceProviderSupport.globMayMatchDescendant(
        directory: "entry", glob: "entry/src/main/ets/**"))
    XCTAssertTrue(
      WorkspaceProviderSupport.globMayMatchDescendant(
        directory: "entry/src/main/ets/pages",
        glob: "entry/src/main/ets/**"))
    XCTAssertFalse(
      WorkspaceProviderSupport.globMayMatchDescendant(
        directory: "entry/build", glob: "entry/src/main/ets/**"))
    XCTAssertFalse(
      WorkspaceProviderSupport.globMayMatchDescendant(
        directory: "oh_modules", glob: "entry/src/main/ets/**"))
    XCTAssertEqual(
      WorkspaceProviderSupport.globEnumerationAnchor(
        "entry/src/main/ets/**"),
      "entry/src/main/ets")
    XCTAssertEqual(
      WorkspaceProviderSupport.globEnumerationAnchor("Sources/*.swift"),
      "Sources")
    XCTAssertEqual(
      WorkspaceProviderSupport.globEnumerationAnchor("Sources/App.txt"),
      "Sources")
    XCTAssertNil(WorkspaceProviderSupport.globEnumerationAnchor("**/*.swift"))

    let build = try workspaceAction(
      "workspace.build-openharmony@1",
      inputs: [
        "projectRef": .string("TestProject"),
        "buildPresetRef": .string("build-ok"),
      ], context: context)
    XCTAssertEqual(
      try XCTUnwrap(build.operationInvocation).arguments,
      ["BUILD_OK\\n"])
    XCTAssertEqual(
      try provider.lower(action: .workspace(build), context: context).workingDirectory,
      profile.projectRoot)

    let tests = try workspaceAction(
      "workspace.run-tests@1",
      inputs: [
        "projectRef": .string("TestProject"),
        "testPresetRef": .string("tests-ok"),
      ], context: context)
    XCTAssertEqual(
      try XCTUnwrap(tests.operationInvocation).arguments,
      ["TESTS_OK\\n"])

    let dump = root.appending(path: "dump.txt")
    try Data("0x1234\n".utf8).write(to: dump)
    let symbolContext = executionContext(
      artifact: resolvedArtifact(dump, artifactID: "ART-DUMP"))
    let symbolize = try workspaceAction(
      "workspace.symbolize-crash@1",
      inputs: [
        "projectRef": .string("TestProject"),
        "dumpArtifactRef": .string("lease-v1:input:ART-DUMP"),
        "symbolPresetRef": .string("symbols"),
      ], context: symbolContext)
    XCTAssertEqual(
      try XCTUnwrap(symbolize.operationInvocation).arguments,
      [dump.path])

    let patchURL = try writePatch(relativePath: "Sources/App.txt")
    let patchContext = executionContext(
      artifact: resolvedArtifact(patchURL, artifactID: "ART-PATCH"))
    let apply = try workspaceAction(
      "workspace.apply-patch@1",
      inputs: [
        "projectRef": .string("TestProject"),
        "patchArtifactRef": .string("lease-v1:input:ART-PATCH"),
        "allowedFileGlobs": .array([.string("Sources/**")]),
      ], context: patchContext)
    guard case .applyPatch(let patch) = apply else {
      return XCTFail("expected applyPatch")
    }
    XCTAssertEqual(
      patch.invocation.arguments,
      ["-f", "-p1", "-d", profile.projectRoot, "-i", patchURL.path])

    let receipt = try await dispatcher.dispatch(
      try provider.lower(action: .workspace(apply), context: patchContext))
    guard
      case .verified(let summary) = try provider.verify(
        receipt: receipt, action: .workspace(apply), context: patchContext),
      let reference = summary["patchAttemptRef"]
    else {
      return XCTFail("patch did not verify")
    }
    let revert = try workspaceAction(
      "workspace.revert-patch@1",
      inputs: [
        "projectRef": .string("TestProject"),
        "patchAttemptRef": .string(reference),
      ], context: context)
    let durablePatchPath = state.appending(
      path:
        "attempts/\(reference).patch"
    ).path
    XCTAssertEqual(
      try XCTUnwrap(revert.operationInvocation).arguments,
      ["-f", "-R", "-p1", "-d", profile.projectRoot, "-i", durablePatchPath])
    XCTAssertEqual(
      try Data(contentsOf: URL(filePath: durablePatchPath)),
      try Data(contentsOf: patchURL))
  }

  func testInspectSourceIsAvailableWhenTheProfilePinsAnInspector() throws {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "workspace.inspect-source@1"))
    XCTAssertEqual(provider.runtimeAvailability(for: descriptor), .available)
  }

  func testProductionProfileBindsSwiftPMExecutableRoleAndSelfSafeTestPreset() throws {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let production = try WorkspaceProjectProfile.arkDeck(rootURL: repository)
    let build = try XCTUnwrap(production.buildPresets["arkdeck-debug"])
    XCTAssertTrue(build.executable.path.hasSuffix("/usr/bin/swift-package"))
    XCTAssertTrue(build.argumentZero?.hasSuffix("/usr/bin/swift-build") == true)
    XCTAssertEqual(
      build.fixedArguments,
      [
        "--package-path",
        URL(filePath: production.projectRoot, directoryHint: .isDirectory)
          .appending(path: "Packages/ArkDeckKit").path,
      ])
    let tests = try XCTUnwrap(production.testPresets["arkdeck-tests"])
    XCTAssertEqual(tests.executable, build.executable)
    XCTAssertTrue(tests.argumentZero?.hasSuffix("/usr/bin/swift-test") == true)
    XCTAssertEqual(
      Array(tests.fixedArguments.suffix(2)),
      [
        "--skip",
        "ArkDeckContractTests.AgentDaemonContractTests/"
          + "testDaemonBinaryStaysAliveAndServesRequests",
      ])
  }

  /// Symbolization is reachable from this host, and reaching for it badly
  /// costs one operation rather than the profile.
  ///
  /// Both halves matter and neither was covered. The first is the claim the
  /// availability answer used to deny outright. The second is what made the
  /// denial hard to see: a configured-but-unresolvable analyzer threw out of
  /// the factory, so the daemon reported `projectProfileUnavailable` and every
  /// `workspace.*` operation went dark at once, naming none of them.
  func testSymbolizerFollowsHostConfigurationAndAStalePathCostsOnlyThatOperation() throws {
    let project = state.appending(path: "waterflow-symbolizer", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: project.appending(path: "entry/src/main", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: project.appending(path: "build-profile.json5"))
    try Data("{}".utf8).write(to: project.appending(path: "entry/src/main/module.json5"))
    let script = project.appending(path: "hvigorw.js")
    try Data("// fixture".utf8).write(to: script)

    let symbolize = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "workspace.symbolize-crash@1"))
    let build = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "workspace.build-openharmony@1"))

    func provider(
      _ profile: WorkspaceProjectProfile, _ label: String
    ) throws -> WorkspaceOperationsProvider {
      WorkspaceOperationsProvider(
        profile: profile,
        attemptStore: try WorkspacePatchAttemptStore(
          rootURL: state.appending(path: label, directoryHint: .isDirectory)),
        nowUTC: { "2026-08-20T00:00:00Z" })
    }

    // Configured. `/usr/bin/true` stands in for the pinned analyzer daemon the
    // LaunchAgent installs; what matters is that the path resolves.
    let configured = try WorkspaceProjectProfile.waterFlowDemo(
      rootURL: project, nodePath: "/usr/bin/true", hvigorScriptPath: script.path,
      symbolizerPath: "/usr/bin/true")
    XCTAssertEqual(configured.symbolPresets["arkts-sourcemap"]?.executable.path, "/usr/bin/true")
    XCTAssertEqual(
      try provider(configured, "configured").runtimeAvailability(for: symbolize), .available,
      "an analyzer this host has configured must reach symbolize-crash")

    // Not configured. Unavailable, but as something this host is missing.
    let unconfigured = try WorkspaceProjectProfile.waterFlowDemo(
      rootURL: project, nodePath: "/usr/bin/true", hvigorScriptPath: script.path)
    guard
      case .unavailable(let code, _) = try provider(unconfigured, "unconfigured")
        .runtimeAvailability(for: symbolize)
    else {
      return XCTFail("symbolize-crash is unavailable without an analyzer")
    }
    XCTAssertEqual(code.origin, .hostConfiguration)

    // Configured at a path that no longer resolves. The profile still builds,
    // and only the symbolizer is missing from it.
    let stale = try WorkspaceProjectProfile.waterFlowDemo(
      rootURL: project, nodePath: "/usr/bin/true", hvigorScriptPath: script.path,
      symbolizerPath: project.appending(path: "analyzer-that-was-removed").path)
    XCTAssertTrue(stale.symbolPresets.isEmpty)
    let staleProvider = try provider(stale, "stale")
    XCTAssertEqual(
      staleProvider.runtimeAvailability(for: build), .available,
      "a stale analyzer path must not take unrelated workspace operations down with it")
    guard case .unavailable(let staleCode, let staleReason) = staleProvider
      .runtimeAvailability(for: symbolize)
    else {
      return XCTFail("a stale analyzer path leaves symbolize-crash unavailable")
    }
    XCTAssertEqual(staleCode, .workspacePresetUnavailable)
    XCTAssertEqual(staleReason, "workspace.symbolPresetUnavailable")
  }

  func testWaterFlowProfilePinsTheRealBuildTestAndDeployProduct() throws {
    let project = root.appending(path: "WaterFlow", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: project.appending(path: "entry/src/main", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: project.appending(path: "build-profile.json5"))
    try Data("{}".utf8).write(
      to: project.appending(path: "entry/src/main/module.json5"))
    let script = project.appending(path: "hvigorw.js")
    try Data("// fixture".utf8).write(to: script)

    let production = try WorkspaceProjectProfile.waterFlowDemo(
      rootURL: project, nodePath: "/usr/bin/true", hvigorScriptPath: script.path)
    XCTAssertEqual(production.profileID, "waterflow-openharmony@1")
    XCTAssertEqual(production.projectRef, "demo-app")
    XCTAssertEqual(production.sourceReaderPreset?.executable.path, "/usr/bin/sed")
    XCTAssertNil(production.sourceControlPreset, "the demo is not required to be a git checkout")
    let build = try XCTUnwrap(production.buildPresets["waterflow-debug"])
    XCTAssertEqual(
      build.fixedArguments,
      [
        script.path, "assembleHap", "--mode", "module",
        "-p", "module=entry@default", "-p", "product=default",
        "-p", "buildMode=debug", "--analyze=normal", "--parallel",
        "--incremental", "--no-daemon",
      ])
    let tests = try XCTUnwrap(production.testPresets["waterflow-tests"])
    XCTAssertEqual(tests.fixedArguments[1], "test")
    XCTAssertEqual(
      production.buildProducts[build.presetID],
      "entry/build/default/outputs/default/entry-default-unsigned.hap")
    XCTAssertEqual(
      production.allowedFileGlobs,
      [
        "entry/src/main/ets/**", "entry/src/main/cpp/**",
        "entry/src/test/**", "entry/src/ohosTest/**",
      ])
  }

  func testWaterFlowProfileWithLegacyConfigurationStillCarriesRegisteredPresets() throws {
    // A daemon started with the legacy `--workspace-project` root composes
    // the WaterFlow profile from environment-derived Node/Hvigor paths. The
    // presets a caller registered against the same project through
    // `workspace preset register` are reported active by the registration
    // owner, so the composition must carry them: the registered preset is
    // the one a Job can acquire (`waterflow-debug` is not a registered
    // reference), and the legacy signing fallback closes once a registered
    // signing preset can be pinned.
    let project = root.appending(path: "LegacyWaterFlow", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: project.appending(path: "entry/src/main", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: project.appending(path: "build-profile.json5"))
    try Data("{}".utf8).write(
      to: project.appending(path: "entry/src/main/module.json5"))
    let script = project.appending(path: "hvigorw.js")
    try Data("// fixture".utf8).write(to: script)
    let resource = RuntimeWorkspacePresetResource(
      presetRef: "preset-legacy-host-build", generation: 1,
      projectRef: "demo-app", kind: "build",
      templateRef: "openharmony.hvigor-build@1",
      toolchainRef: "toolchain:sha256:" + String(repeating: "b", count: 64),
      toolchainGeneration: 1, credentialRef: nil, timeoutSeconds: 1_200,
      constraints: RuntimeWorkspacePresetConstraints(
        module: "entry", product: "default", buildMode: "debug"),
      registeredAtUTC: "2026-09-02T00:00:00.000Z",
      updatedAtUTC: "2026-09-02T00:00:00.000Z", configurationStatus: "active")
    let registered = try WorkspaceProjectProfile.waterFlowDemo(
      rootURL: project, projectRef: resource.projectRef,
      nodePath: "/usr/bin/true", hvigorScriptPath: script.path,
      registeredPresets: [
        RuntimeWorkspaceResolvedPreset(
          resource: resource, nodePath: "/usr/bin/true",
          hvigorScriptPath: script.path, sdkRootPath: "/private/sdk",
          verifiedResources: [])
      ])
    let build = try XCTUnwrap(registered.buildPresets[resource.presetRef])
    XCTAssertEqual(build.timeoutSeconds, 1_200)
    XCTAssertEqual(
      registered.buildProducts[resource.presetRef],
      "entry/build/default/outputs/default/entry-default-unsigned.hap")
    XCTAssertNil(
      registered.buildPresets["waterflow-debug"],
      "a registered preset replaces the environment-derived one it supersedes")
    XCTAssertFalse(registered.allowsLegacySigningPresetFallback)

    // Without a registration the legacy composition is exactly what it was.
    let legacy = try WorkspaceProjectProfile.waterFlowDemo(
      rootURL: project, projectRef: "demo-app",
      nodePath: "/usr/bin/true", hvigorScriptPath: script.path,
      registeredPresets: nil)
    XCTAssertNotNil(legacy.buildPresets["waterflow-debug"])
    XCTAssertNil(legacy.buildPresets[resource.presetRef])
    XCTAssertTrue(legacy.allowsLegacySigningPresetFallback)
  }

  func testWaterFlowProfileLowersRegisteredPresetConstraintsWithoutLegacyFallback() throws {
    let project = root.appending(path: "RegisteredWaterFlow", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: project.appending(path: "entry/src/main", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: project.appending(path: "build-profile.json5"))
    try Data("{}".utf8).write(
      to: project.appending(path: "entry/src/main/module.json5"))
    let script = project.appending(path: "hvigorw.js")
    try Data("// fixture".utf8).write(to: script)
    let manifest = project.appending(path: "sdk-pkg.json")
    let manifestData = Data("{\"version\":\"fixture\"}".utf8)
    try manifestData.write(to: manifest)
    let verifiedResource = ResolvedExecutableResource(
      path: manifest.path, sha256: SHA256Hex.string(of: manifestData),
      byteCount: manifestData.count, requireExecutable: false)
    let resource = RuntimeWorkspacePresetResource(
      presetRef: "preset-registered-build", generation: 1,
      projectRef: "registered-demo", kind: "build",
      templateRef: "openharmony.hvigor-build@1",
      toolchainRef: "toolchain:sha256:" + String(repeating: "a", count: 64),
      toolchainGeneration: 1, credentialRef: nil, timeoutSeconds: 900,
      constraints: RuntimeWorkspacePresetConstraints(
        module: "entry", product: "release", buildMode: "release"),
      registeredAtUTC: "2026-09-01T00:00:00.000Z",
      updatedAtUTC: "2026-09-01T00:00:00.000Z", configurationStatus: "active")
    let production = try WorkspaceProjectProfile.waterFlowDemo(
      rootURL: project, projectRef: resource.projectRef,
      registeredPresets: [
        RuntimeWorkspaceResolvedPreset(
          resource: resource, nodePath: "/usr/bin/true",
          hvigorScriptPath: script.path, sdkRootPath: "/private/sdk",
          verifiedResources: [verifiedResource]),
      ])
    XCTAssertNil(production.buildPresets["waterflow-debug"])
    let build = try XCTUnwrap(production.buildPresets[resource.presetRef])
    XCTAssertEqual(build.timeoutSeconds, 900)
    XCTAssertEqual(build.verifiedResources, [verifiedResource])
    XCTAssertEqual(
      build.fixedArguments,
      [
        script.path, "assembleHap", "--mode", "module",
        "-p", "module=entry@release", "-p", "product=release",
        "-p", "buildMode=release", "--analyze=normal", "--parallel",
        "--incremental", "--no-daemon",
      ])
    XCTAssertEqual(
      production.buildProducts[resource.presetRef],
      "entry/build/release/outputs/release/entry-release-unsigned.hap")

    let operationProvider = WorkspaceOperationsProvider(
      profile: production,
      attemptStore: try WorkspacePatchAttemptStore(
        rootURL: state.appending(
          path: "registered-preset-attempts", directoryHint: .isDirectory)),
      nowUTC: { "2026-09-01T00:00:00Z" })
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "workspace.build-openharmony@1"))
    let action = try operationProvider.action(
      for: descriptor.steps[0], operation: descriptor,
      inputs: [
        "projectRef": .string(resource.projectRef),
        "buildPresetRef": .string(resource.presetRef),
      ], context: executionContext())
    let executable = try WorkspaceActionExecutableResolver(profile: production)
      .resolveExecutable(for: action)
    XCTAssertEqual(executable.verifiedResources, [verifiedResource])

    let readOnly = try WorkspaceProjectProfile.waterFlowDemo(
      rootURL: project, projectRef: "registered-read-only", registeredPresets: [])
    XCTAssertTrue(readOnly.buildPresets.isEmpty)
    XCTAssertTrue(readOnly.testPresets.isEmpty)
  }

  func testDispatcherOverlaysProfileEnvironmentOnlyOnTheChild() async throws {
    let key = "ARKDECK_TEST_CHILD_SDK_HOME"
    let value = "/private/tmp/arkdeck-sdk"
    let inheritedValue = ProcessInfo.processInfo.environment[key]
    let env = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/env")
    let build = try WorkspaceCommandPreset(
      presetID: "print-environment", executable: env,
      fixedArguments: [], timeoutSeconds: 10)
    let environmentProfile = try WorkspaceProjectProfile(
      profileID: "environment-test@1", projectRef: "TestProject",
      projectRoot: root.path, allowedFileGlobs: ["Sources/**"],
      inspectionPreset: profile.inspectionPreset,
      patchPreset: profile.patchPreset,
      buildPresets: [build.presetID: build], testPresets: [:], symbolPresets: [:])
    let environmentProvider = WorkspaceOperationsProvider(
      profile: environmentProfile,
      attemptStore: try WorkspacePatchAttemptStore(
        rootURL: state.appending(path: "environment-attempts", directoryHint: .isDirectory)),
      nowUTC: { "2026-08-01T00:00:00Z" })
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "workspace.build-openharmony@1"))
    let action = try environmentProvider.action(
      for: descriptor.steps[0], operation: descriptor,
      inputs: [
        "projectRef": .string("TestProject"),
        "buildPresetRef": .string(build.presetID),
      ], context: executionContext())
    let environmentDispatcher = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: environmentProfile),
      childEnvironment: [key: "wrong-default"],
      childEnvironmentByExecutablePath: [env.path: [key: value]])
    let receipt = try await environmentDispatcher.dispatch(
      try environmentProvider.lower(action: action, context: executionContext()))
    let lines = String(decoding: receipt.stdout, as: UTF8.self).split(separator: "\n")

    XCTAssertTrue(lines.contains(Substring("\(key)=\(value)")))
    XCTAssertEqual(ProcessInfo.processInfo.environment[key], inheritedValue)
  }

  func testPatchScopeApplyArtifactReadbackAndExactRevert() async throws {
    let original = try Data(contentsOf: root.appending(path: "Sources/App.txt"))
    let originalRevision = sha(original)
    let patchURL = try writePatch(relativePath: "Sources/App.txt")
    let patchContext = executionContext(
      artifact: resolvedArtifact(patchURL, artifactID: "ART-PATCH"))
    let action = try workspaceAction(
      "workspace.apply-patch@1",
      inputs: [
        "projectRef": .string("TestProject"),
        "patchArtifactRef": .string("lease-v1:input:ART-PATCH"),
        "allowedFileGlobs": .array([.string("Sources/**")]),
      ], context: patchContext)
    let plan = try provider.lower(action: .workspace(action), context: patchContext)
    let receipt = try await dispatcher.dispatch(plan)
    guard
      case .verified(let summary) = try provider.verify(
        receipt: receipt, action: .workspace(action), context: patchContext),
      let reference = summary["patchAttemptRef"]
    else {
      return XCTFail("apply must produce a durable patchAttemptRef")
    }
    try FileManager.default.removeItem(at: patchURL)
    XCTAssertEqual(
      String(
        data: try Data(
          contentsOf: root.appending(path: "Sources/App.txt")), encoding: .utf8),
      "new\n")

    let persisted = try PersistedTypedProviderAction(.workspace(action))
    XCTAssertEqual(try persisted.materialize(), .workspace(action))
    let reconciliation = try await provider.reconcile(
      intent: ProviderDurableIntentReference(
        jobID: "job-workspace", stepID: "apply-patch",
        intentEventID: "intent-apply", action: .workspace(action)),
      context: patchContext)
    guard case .confirmedCompleted = reconciliation else {
      return XCTFail("exact postimage must reconcile as completed")
    }

    let revertContext = executionContext()
    let revert = try workspaceAction(
      "workspace.revert-patch@1",
      inputs: [
        "projectRef": .string("TestProject"),
        "patchAttemptRef": .string(reference),
      ], context: revertContext)
    let revertReceipt = try await dispatcher.dispatch(
      try provider.lower(action: .workspace(revert), context: revertContext))
    guard
      case .verified(let revertSummary) = try provider.verify(
        receipt: revertReceipt, action: .workspace(revert), context: revertContext)
    else {
      return XCTFail("revert must verify by exact original file hashes")
    }
    XCTAssertEqual(
      revertSummary["workspaceRevision"],
      shaSnapshot(
        path: "Sources/App.txt", sha256: originalRevision))
    XCTAssertEqual(
      try Data(contentsOf: root.appending(path: "Sources/App.txt")), original)
  }

  func testRuntimeConsumesHostBoundPatchLeaseAndRevertsExactAttempt() async throws {
    let artifactStore = try RuntimeArtifactStore(
      rootURL: state.appending(path: "patch-runtime-artifacts"),
      nowUTC: { "2026-07-31T00:00:00Z" })
    let patchBytes = try Data(
      contentsOf: writePatch(relativePath: "Sources/App.txt"))
    let imported = try await artifactStore.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-import-patch", sessionID: "session-import-patch",
        stepID: "import-patch", name: "change.patch",
        mediaType: "text/x-diff", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "workspace.patch-import", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "workspace-test", bindingRevision: nil,
          stableIdentitySHA256: nil),
        contents: patchBytes))
    let patchLease = try await artifactStore.leaseReference(
      jobID: imported.jobID, artifactID: imported.artifactID)
    let grantStore1 = try RuntimeCapabilityStore(
      directoryURL: state.appending(path: "workspace-grant-1"))
    // One bounded workspace standing grant covers the approved route. Each
    // exact operation and its typed inputs are still materialized, authorized,
    // consumed and outcome-recorded independently.
    try await installWorkspaceGrant(
      into: grantStore1,
      operations: ["workspace.apply-patch", "workspace.revert-patch"])
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state.appending(path: "patch-runtime-engine")),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: RuntimeProcessDispatcherRouter(
        hdc: dispatcher, rockchip: dispatcher, workspace: dispatcher),
      capabilityStore: grantStore1,
      artifactStore: artifactStore,
      nowUTC: { "2026-07-31T00:00:00Z" })

    let apply = try operationRequest(
      id: "workspace.apply-patch",
      inputs: [
        "projectRef": .string("TestProject"),
        "patchArtifactRef": .string(patchLease),
        "allowedFileGlobs": .array([.string("Sources/**")]),
      ],
      requestID: "request-runtime-apply",
      idempotencyKey: "idempotency-runtime-apply",
      authorization: Self.workspaceGrantReference)
    let applyAcceptance = try await engine.submit(try JSONEncoder().encode(apply))
    let applyStatus = try await engine.run(jobID: applyAcceptance.jobID)
    XCTAssertEqual(applyStatus.state, "succeeded")
    XCTAssertEqual(
      try Data(contentsOf: root.appending(path: "Sources/App.txt")),
      Data("new\n".utf8))

    let applyArtifacts = try await artifactStore.list(jobID: applyAcceptance.jobID)
    let report = try XCTUnwrap(
      applyArtifacts.first { $0.name == "applied-patch.json" })
    let reportLease = try await artifactStore.leaseReference(
      jobID: report.jobID, artifactID: report.artifactID)
    let reportFile = try await artifactStore.resolveLease(reportLease)
    let fields = try JSONDecoder().decode(
      [String: JSONValue].self, from: Data(contentsOf: reportFile.fileURL))
    guard case .string(let patchAttemptRef)? = fields["patchAttemptRef"] else {
      return XCTFail("applied-patch.json must carry the durable patchAttemptRef")
    }

    let revert = try operationRequest(
      id: "workspace.revert-patch",
      inputs: [
        "projectRef": .string("TestProject"),
        "patchAttemptRef": .string(patchAttemptRef),
      ],
      requestID: "request-runtime-revert",
      idempotencyKey: "idempotency-runtime-revert",
      authorization: Self.workspaceGrantReference)
    let revertAcceptance = try await engine.submit(try JSONEncoder().encode(revert))
    let revertStatus = try await engine.run(jobID: revertAcceptance.jobID)
    XCTAssertEqual(revertStatus.state, "succeeded")
    XCTAssertEqual(
      try Data(contentsOf: root.appending(path: "Sources/App.txt")),
      Data("old\n".utf8))
    let inspectedGrant = try await grantStore1.inspect(
      capabilityID: Self.workspaceGrantID)
    let grantStatus = try XCTUnwrap(inspectedGrant)
    XCTAssertEqual(grantStatus.consumptionCount, 2)
    XCTAssertEqual(
      grantStatus.lineage.map(\.operationReference),
      ["workspace.apply-patch@1", "workspace.revert-patch@1"])
    XCTAssertEqual(grantStatus.lineage.map(\.outcome), [.confirmed, .confirmed])
  }

  func testRuntimeConsumesADeviceScopedPatchLeaseOnlyUnderThatTarget() async throws {
    // `artifact import workspace-patch` binds its lease to the durable device
    // target the caller named, with no binding revision and no identity. The
    // consuming host-only request keeps that target as its scope; the same
    // lease under the project scope stays unresolvable, exactly as before.
    let artifactStore = try RuntimeArtifactStore(
      rootURL: state.appending(path: "device-scoped-patch-artifacts"),
      nowUTC: { "2026-07-31T00:00:00Z" })
    let patchBytes = try Data(
      contentsOf: writePatch(relativePath: "Sources/App.txt"))
    let imported = try await artifactStore.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-import-device-patch", sessionID: "session-import-device-patch",
        stepID: "import-patch", name: "change.patch",
        mediaType: "text/x-diff", privacy: .sensitive,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "artifact.import-workspace-patch", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-DEVICE", bindingRevision: nil,
          stableIdentitySHA256: nil),
        contents: patchBytes))
    let patchLease = try await artifactStore.leaseReference(
      jobID: imported.jobID, artifactID: imported.artifactID)
    let grantStore = try RuntimeCapabilityStore(
      directoryURL: state.appending(path: "device-scoped-patch-grant"))
    try await installWorkspaceGrant(
      into: grantStore, operations: ["workspace.apply-patch"])
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state.appending(path: "device-scoped-patch-engine")),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: RuntimeProcessDispatcherRouter(
        hdc: dispatcher, rockchip: dispatcher, workspace: dispatcher),
      capabilityStore: grantStore,
      artifactStore: artifactStore,
      nowUTC: { "2026-07-31T00:00:00Z" })
    let inputs: [String: JSONValue] = [
      "projectRef": .string("TestProject"),
      "patchArtifactRef": .string(patchLease),
      "allowedFileGlobs": .array([.string("Sources/**")]),
    ]

    // Project scope: the lease names another target, so admission refuses it
    // before any dispatch and the tree is untouched.
    do {
      _ = try await engine.submit(
        try JSONEncoder().encode(
          try operationRequest(
            id: "workspace.apply-patch", inputs: inputs,
            requestID: "request-project-scoped-patch",
            idempotencyKey: "idempotency-project-scoped-patch")))
      XCTFail("a device-scoped patch lease must not resolve under the project scope")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(let code, let detail) = error else { return XCTFail("\(error)") }
      XCTAssertEqual(code, .invalidInput)
      XCTAssertTrue(detail.contains("does not match the materialized request"), detail)
    }
    XCTAssertEqual(
      try Data(contentsOf: root.appending(path: "Sources/App.txt")),
      Data("old\n".utf8))

    // The target the import named: no binding revision is pinned, the lease
    // resolves, and the patch lands.
    let accepted = try await engine.submit(
      try JSONEncoder().encode(
        try operationRequest(
          id: "workspace.apply-patch", inputs: inputs,
          requestID: "request-device-scoped-patch",
          idempotencyKey: "idempotency-device-scoped-patch",
          targetID: "TGT-DEVICE")))
    let status = try await engine.run(jobID: accepted.jobID)
    XCTAssertEqual(status.state, "succeeded", "timeline: \(status.timeline)")
    XCTAssertEqual(
      try Data(contentsOf: root.appending(path: "Sources/App.txt")),
      Data("new\n".utf8))
    let published = try await artifactStore.list(jobID: accepted.jobID)
    let report = try XCTUnwrap(published.first { $0.name == "applied-patch.json" })
    XCTAssertEqual(report.bindingSnapshot.targetID, "TGT-DEVICE")
    XCTAssertNil(report.bindingSnapshot.bindingRevision)
    XCTAssertNil(report.bindingSnapshot.stableIdentitySHA256)
  }

  func testReceiptLostRevertReconcilesOnceAndClosesAttempt() async throws {
    let patchURL = try writePatch(relativePath: "Sources/App.txt")
    let patchContext = executionContext(
      artifact: resolvedArtifact(patchURL, artifactID: "ART-RECONCILE"))
    let apply = try workspaceAction(
      "workspace.apply-patch@1",
      inputs: [
        "projectRef": .string("TestProject"),
        "patchArtifactRef": .string("lease-v1:input:ART-RECONCILE"),
        "allowedFileGlobs": .array([.string("Sources/**")]),
      ], context: patchContext)
    let applyReceipt = try await dispatcher.dispatch(
      try provider.lower(action: .workspace(apply), context: patchContext))
    guard
      case .verified(let summary) = try provider.verify(
        receipt: applyReceipt, action: .workspace(apply), context: patchContext),
      let reference = summary["patchAttemptRef"]
    else {
      return XCTFail("apply must produce a durable attempt")
    }

    let revertContext = executionContext()
    let revert = try workspaceAction(
      "workspace.revert-patch@1",
      inputs: [
        "projectRef": .string("TestProject"),
        "patchAttemptRef": .string(reference),
      ], context: revertContext)
    _ = try await dispatcher.dispatch(
      try provider.lower(action: .workspace(revert), context: revertContext))
    let reconciliation = try await provider.reconcile(
      intent: ProviderDurableIntentReference(
        jobID: "job-workspace", stepID: "revert-patch",
        intentEventID: "intent-revert", action: .workspace(revert)),
      context: revertContext)
    guard case .confirmedCompleted = reconciliation else {
      return XCTFail("exact original preimage must reconcile as completed")
    }
    XCTAssertThrowsError(
      try workspaceAction(
        "workspace.revert-patch@1",
        inputs: [
          "projectRef": .string("TestProject"),
          "patchAttemptRef": .string(reference),
        ], context: revertContext)
    ) { error in
      XCTAssertTrue("\(error)".contains("not active"))
    }
  }

  func testOutOfGlobPatchFailsBeforeSpawnAndLeavesWorkspaceUntouched() throws {
    let forbidden = root.appending(path: "Forbidden.txt")
    try Data("old\n".utf8).write(to: forbidden)
    let patchURL = try writePatch(relativePath: "Forbidden.txt")
    let context = executionContext(
      artifact: resolvedArtifact(patchURL, artifactID: "ART-OUTSIDE"))
    XCTAssertThrowsError(
      try workspaceAction(
        "workspace.apply-patch@1",
        inputs: [
          "projectRef": .string("TestProject"),
          "patchArtifactRef": .string("lease-v1:input:ART-OUTSIDE"),
          "allowedFileGlobs": .array([.string("Sources/**")]),
        ], context: context)
    ) { error in
      XCTAssertTrue("\(error)".contains("workspace.patchScopeViolation"))
    }
    XCTAssertEqual(try Data(contentsOf: forbidden), Data("old\n".utf8))
  }

  func testPatchPrefixCannotChangeThePathAfterP1ScopeValidation() throws {
    let outside = root.appending(path: "App.txt")
    try Data("old\n".utf8).write(to: outside)
    let patch = """
      --- Sources/App.txt
      +++ Sources/App.txt
      @@ -1 +1 @@
      -old
      +new

      """
    let patchURL = state.appending(path: "prefix-bypass.patch")
    try Data(patch.utf8).write(to: patchURL)
    let context = executionContext(
      artifact: resolvedArtifact(patchURL, artifactID: "ART-PREFIX-BYPASS"))
    XCTAssertThrowsError(
      try workspaceAction(
        "workspace.apply-patch@1",
        inputs: [
          "projectRef": .string("TestProject"),
          "patchArtifactRef": .string("lease-v1:input:ART-PREFIX-BYPASS"),
          "allowedFileGlobs": .array([.string("Sources/**")]),
        ], context: context)
    ) { error in
      XCTAssertTrue("\(error)".contains("unsafe path"))
    }
    XCTAssertEqual(try Data(contentsOf: outside), Data("old\n".utf8))
    XCTAssertEqual(
      try Data(contentsOf: root.appending(path: "Sources/App.txt")),
      Data("old\n".utf8))
  }

  func testBuildAndTestsReallySpawnAndFailureIsHonest() async throws {
    for (reference, inputKey, preset) in [
      ("workspace.build-openharmony@1", "buildPresetRef", "build-ok"),
      ("workspace.run-tests@1", "testPresetRef", "tests-ok"),
    ] {
      let context = executionContext()
      let action = try workspaceAction(
        reference,
        inputs: [
          "projectRef": .string("TestProject"),
          inputKey: .string(preset),
        ], context: context)
      let receipt = try await dispatcher.dispatch(
        try provider.lower(action: .workspace(action), context: context))
      guard
        case .verified(let summary) = try provider.verify(
          receipt: receipt, action: .workspace(action), context: context)
      else {
        return XCTFail("\(reference) must verify its real process receipt")
      }
      XCTAssertEqual(summary["exitStatus"], "0")
      XCTAssertGreaterThan(Int(summary["stdoutByteCount"] ?? "0") ?? 0, 0)
    }

    let failureProfile = try profileWithFailingBuild()
    let failureProvider = WorkspaceOperationsProvider(
      profile: failureProfile,
      attemptStore: try WorkspacePatchAttemptStore(
        rootURL: state.appending(path: "failure-attempts")),
      nowUTC: { "2026-07-31T00:00:00Z" })
    let failureDispatcher = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: failureProfile))
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "workspace.build-openharmony@1"))
    let action = try failureProvider.action(
      for: descriptor.steps[0], operation: descriptor,
      inputs: [
        "projectRef": .string("TestProject"),
        "buildPresetRef": .string("build-fail"),
      ], context: executionContext())
    let receipt = try await failureDispatcher.dispatch(
      try failureProvider.lower(action: action, context: executionContext()))
    guard
      case .failed(let code, _) = try failureProvider.verify(
        receipt: receipt, action: action, context: executionContext())
    else {
      return XCTFail("a non-zero build must not become verified")
    }
    XCTAssertEqual(code, "workspace.buildFailed")

    let stderrProfile = try profileWithFailingBuildAndStderr()
    let stderrProvider = WorkspaceOperationsProvider(
      profile: stderrProfile,
      attemptStore: try WorkspacePatchAttemptStore(
        rootURL: state.appending(path: "stderr-attempts")),
      nowUTC: { "2026-07-31T00:00:00Z" })
    let stderrAction = try stderrProvider.action(
      for: descriptor.steps[0], operation: descriptor,
      inputs: [
        "projectRef": .string("TestProject"),
        "buildPresetRef": .string("build-fail-stderr"),
      ], context: executionContext())
    let stderrBounded = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: stderrProfile),
      outputByteBudget: 1)
    let truncated = try await stderrBounded.dispatch(
      try stderrProvider.lower(action: stderrAction, context: executionContext()))
    guard
      case .failed(let truncatedCode, _) = try stderrProvider.verify(
        receipt: truncated, action: stderrAction, context: executionContext())
    else {
      return XCTFail("a truncated diagnostic stream must fail closed")
    }
    XCTAssertEqual(truncatedCode, "workspace.outputTruncated")
  }

  func testUnapprovedBuildAndTestPresetsFailBeforeMaterialization() throws {
    for (reference, inputKey, preset) in [
      ("workspace.build-openharmony@1", "buildPresetRef", "build-not-approved"),
      ("workspace.run-tests@1", "testPresetRef", "tests-not-approved"),
    ] {
      let descriptor = try XCTUnwrap(
        RuntimeOperationCatalog.descriptor(reference: reference))
      XCTAssertThrowsError(
        try provider.action(
          for: descriptor.steps[0], operation: descriptor,
          inputs: [
            "projectRef": .string("TestProject"),
            inputKey: .string(preset),
          ], context: executionContext())
      ) { error in
        XCTAssertTrue("\(error)".contains("PresetUnavailable"), reference)
      }
    }
  }

  func testProfileOperationsDoNotDependOnTheOptionalSourceInspector() throws {
    let combined = WorkspaceProvider(
      registry: WorkspaceProjectRegistry(roots: ["TestProject": root.path]),
      operations: provider)
    let context = executionContext()
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "workspace.run-tests@1"))
    let action = try combined.action(
      for: descriptor.steps[0], operation: descriptor,
      inputs: [
        "projectRef": .string("TestProject"),
        "testPresetRef": .string("tests-ok"),
      ], context: context)
    let plan = try combined.lower(action: action, context: context)
    XCTAssertEqual(plan.workingDirectory, profile.projectRoot)
  }

  func testUnavailableReasonIsMachineReadableAndRawArgvIsRejected() async throws {
    let symbolDescriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "workspace.symbolize-crash@1"))
    let noSymbols = try profileWithoutSymbols()
    let unavailable = WorkspaceOperationsProvider(
      profile: noSymbols,
      attemptStore: try WorkspacePatchAttemptStore(
        rootURL: state.appending(path: "unavailable-attempts")),
      nowUTC: { "2026-07-31T00:00:00Z" })
    // A profile without symbol presets is a host that has not configured an
    // analyzer, not a build that cannot symbolize: `waterFlowDemo` ships the
    // preset once `ARKDECK_ANALYZER_PATH` resolves. The answer names which
    // preset is missing, and its origin says configuring this machine helps.
    XCTAssertEqual(
      unavailable.runtimeAvailability(for: symbolDescriptor),
      .unavailable(
        code: .workspacePresetUnavailable, reason: "workspace.symbolPresetUnavailable"))
    XCTAssertEqual(
      RuntimeAvailabilityReasonCode.workspacePresetUnavailable.origin, .hostConfiguration)

    XCTAssertNoThrow(
      try RuntimeOperationRequest(
        requestID: "request-typed-workspace",
        idempotencyKey: "idempotency-typed-workspace",
        target: DurableTargetReference(
          targetID: "workspace-test"),
        operation: RuntimeOperationReference(
          id: "workspace.build-openharmony", version: 1),
        inputs: [
          "projectRef": .string("TestProject"),
          "buildPresetRef": .string("build-ok"),
        ]))
    XCTAssertThrowsError(
      try RuntimeOperationRequest(
        requestID: "request-raw-argv",
        idempotencyKey: "idempotency-raw-argv",
        target: DurableTargetReference(
          targetID: "workspace-test"),
        operation: RuntimeOperationReference(
          id: "workspace.build-openharmony", version: 1),
        inputs: [
          "projectRef": .string("TestProject"),
          "buildPresetRef": .string("build-ok"),
          "argv": .array([.string("--unsafe")]),
        ]))

  }

  func testRuntimeAvailabilityRejectsBeforeJobOrCapabilityConsumption() async throws {
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: state.appending(path: "unavailable-capabilities"))
    let artifactStore = try RuntimeArtifactStore(
      rootURL: state.appending(path: "unavailable-artifacts"),
      nowUTC: { "2026-07-31T00:00:00Z" })
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state.appending(path: "unavailable-engine")),
      providers: DeviceProviderRegistry(providers: [
        UnavailableWorkspaceOperationsProvider(reason: "workspace.toolchainUnavailable")
      ]),
      dispatcher: dispatcher,
      capabilityStore: capabilityStore,
      artifactStore: artifactStore,
      nowUTC: { "2026-07-31T00:00:00Z" })

    let operationAvailability = await engine.operationAvailability()
    let availability = try XCTUnwrap(
      operationAvailability.first {
        $0.reference == "workspace.build-openharmony@1"
      })
    XCTAssertEqual(availability.state, .unavailable)
    XCTAssertEqual(availability.reasons, ["workspace.toolchainUnavailable"])

    let request = try operationRequest(
      id: "workspace.build-openharmony",
      inputs: [
        "projectRef": .string("TestProject"),
        "buildPresetRef": .string("build-ok"),
      ],
      requestID: "request-unavailable",
      idempotencyKey: "idempotency-unavailable")
    do {
      _ = try await engine.submit(try JSONEncoder().encode(request))
      XCTFail("an unavailable provider must reject before Job admission")
    } catch {
      XCTAssertTrue("\(error)".contains("workspace.toolchainUnavailable"))
    }
    let jobs = try await engine.listJobs()
    let capabilities = try await capabilityStore.list()
    XCTAssertTrue(jobs.isEmpty)
    XCTAssertTrue(capabilities.isEmpty)
  }

  func testMaterializedPlanDigestBindsSemanticArgumentZero() async throws {
    var digests: [String] = []
    for (index, argumentZero) in [nil, "profile-owned-printf"].enumerated() {
      let preset = try WorkspaceCommandPreset(
        presetID: "build-ok", executable: profile.buildPresets["build-ok"]!.executable,
        argumentZero: argumentZero,
        fixedArguments: ["BUILD_OK\\n"], timeoutSeconds: 10)
      let variant = try WorkspaceProjectProfile(
        profileID: profile.profileID, projectRef: profile.projectRef,
        projectRoot: profile.projectRoot,
        allowedFileGlobs: profile.allowedFileGlobs,
        inspectionPreset: profile.inspectionPreset,
        patchPreset: profile.patchPreset,
        buildPresets: [preset.presetID: preset],
        testPresets: profile.testPresets,
        symbolPresets: profile.symbolPresets)
      let variantProvider = WorkspaceOperationsProvider(
        profile: variant,
        attemptStore: try WorkspacePatchAttemptStore(
          rootURL: state.appending(path: "digest-attempts-\(index)")),
        nowUTC: { "2026-07-31T00:00:00Z" })
      let variantDispatcher = DescriptorBoundProcessDispatcher(
        resolver: WorkspaceActionExecutableResolver(profile: variant))
      let engineRoot = state.appending(path: "digest-engine-\(index)")
      // The variant profile is a *different* tree, so its grant must be
      // issued against that identity — a capability for one workspace does
      // not authorize another (CHG-2026-055, TASK-HFA-009 r2).
      let variantGrants = try RuntimeCapabilityStore(
        directoryURL: state.appending(path: "digest-capabilities-\(index)"))
      try await installWorkspaceGrant(
        into: variantGrants, operations: ["workspace.build-openharmony"], profile: variant)
      let engine = try RuntimeJobEngine(
        configuration: .init(stateDirectory: engineRoot),
        providers: DeviceProviderRegistry(providers: [variantProvider]),
        dispatcher: RuntimeProcessDispatcherRouter(
          hdc: variantDispatcher, rockchip: variantDispatcher,
          workspace: variantDispatcher),
        capabilityStore: variantGrants,
        artifactStore: try RuntimeArtifactStore(
          rootURL: state.appending(path: "digest-artifacts-\(index)"),
          nowUTC: { "2026-07-31T00:00:00Z" }),
        nowUTC: { "2026-07-31T00:00:00Z" })
      let request = try operationRequest(
        id: "workspace.build-openharmony",
        inputs: [
          "projectRef": .string("TestProject"),
          "buildPresetRef": .string("build-ok"),
        ],
        requestID: "request-plan-digest-\(index)",
        idempotencyKey: "idempotency-plan-digest-\(index)")
      let acceptance = try await engine.submit(try JSONEncoder().encode(request))
      let record = try RuntimeJobRecord.load(
        from: engineRoot.appending(
          path:
            "jobs/\(acceptance.jobID)", directoryHint: .isDirectory))
      digests.append(try XCTUnwrap(record.materializedPlanDigest))
    }
    XCTAssertNotEqual(digests[0], digests[1])
  }

  func testCatalogToRuntimeBuildSpawnsAndPublishesExactArtifact() async throws {
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: state.appending(path: "runtime-capabilities"))
    let artifactStore = try RuntimeArtifactStore(
      rootURL: state.appending(path: "runtime-artifacts"),
      nowUTC: { "2026-07-31T00:00:00Z" })
    try await installWorkspaceGrant(
      into: capabilityStore, operations: ["workspace.build-openharmony"])
    let engineRoot = state.appending(path: "runtime-engine")
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: engineRoot),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: RuntimeProcessDispatcherRouter(
        hdc: dispatcher, rockchip: dispatcher, workspace: dispatcher),
      capabilityStore: capabilityStore,
      artifactStore: artifactStore,
      nowUTC: { "2026-07-31T00:00:00Z" })
    let operationAvailability = await engine.operationAvailability()
    let availability = try XCTUnwrap(
      operationAvailability.first {
        $0.reference == "workspace.build-openharmony@1"
      })
    XCTAssertEqual(availability.state, .available)

    let request = try operationRequest(
      id: "workspace.build-openharmony",
      inputs: [
        "projectRef": .string("TestProject"),
        "buildPresetRef": .string("build-ok"),
      ],
      requestID: "request-runtime-build",
      idempotencyKey: "idempotency-runtime-build")
    let acceptance = try await engine.submit(try JSONEncoder().encode(request))
    let admitted = try RuntimeJobRecord.load(
      from: engineRoot.appending(
        path:
          "jobs/\(acceptance.jobID)", directoryHint: .isDirectory))
    XCTAssertNil(admitted.materializedStableTargetIdentitySHA256)
    XCTAssertNil(admitted.materializedBindingRevision)
    XCTAssertNotNil(admitted.materializedPlanDigest)
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))

    let artifacts = try await artifactStore.list(jobID: acceptance.jobID)
    let buildLog = try XCTUnwrap(artifacts.first { $0.name == "build.log" })
    XCTAssertTrue(buildLog.status.isPublished)
    let lease = try await artifactStore.leaseReference(
      jobID: acceptance.jobID, artifactID: buildLog.artifactID)
    let resolved = try await artifactStore.resolveLease(lease)
    XCTAssertEqual(try Data(contentsOf: resolved.fileURL), Data("BUILD_OK\n".utf8))
  }

  func testCatalogToRuntimeArchiveCheckpointPublishesReceiptAndConfirmsCapabilityLineage()
    async throws
  {
    let checkpointPreset = try WorkspaceCommandPreset(
      presetID: "checkpoint",
      executable: try WorkspaceExecutableIdentity.hashing(
        path: "/usr/bin/bsdtar"), fixedArguments: [], timeoutSeconds: 10)
    let checkpointProfile = try WorkspaceProjectProfile(
      profileID: profile.profileID, projectRef: profile.projectRef,
      projectRoot: profile.projectRoot,
      allowedFileGlobs: profile.allowedFileGlobs,
      inspectionPreset: profile.inspectionPreset,
      archiveCheckpointPreset: checkpointPreset,
      patchPreset: profile.patchPreset,
      buildPresets: profile.buildPresets,
      testPresets: profile.testPresets,
      symbolPresets: profile.symbolPresets)
    let checkpointProvider = WorkspaceOperationsProvider(
      profile: checkpointProfile,
      attemptStore: try WorkspacePatchAttemptStore(
        rootURL: state.appending(path: "checkpoint-attempts", directoryHint: .isDirectory)),
      nowUTC: { "2026-07-31T00:00:00Z" })
    let checkpointDispatcher = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: checkpointProfile))
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: state.appending(path: "checkpoint-capabilities"))
    let artifactStore = try RuntimeArtifactStore(
      rootURL: state.appending(path: "checkpoint-artifacts"),
      nowUTC: { "2026-07-31T00:00:00Z" })
    let checkpointEngineRoot = state.appending(path: "checkpoint-engine")
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: checkpointEngineRoot),
      providers: DeviceProviderRegistry(providers: [checkpointProvider]),
      dispatcher: RuntimeProcessDispatcherRouter(
        hdc: checkpointDispatcher, rockchip: checkpointDispatcher,
        workspace: checkpointDispatcher),
      capabilityStore: capabilityStore,
      artifactStore: artifactStore,
      nowUTC: { "2026-07-31T00:00:00Z" })
    let relativePath = "Sources/App.txt"
    // The revision a checkpoint states is the profile-scoped workspace
    // revision - the same digest the authorization facts, the issued
    // capability's scope and `apply-patch` speak. It is deliberately *not* a
    // digest of only `checkpointFilePaths`: no caller can compute that one,
    // and demanding it refused every checkpoint the repair route ever sent.
    let request = try operationRequest(
      id: "workspace.create-checkpoint",
      inputs: [
        "projectRef": .string(checkpointProfile.projectRef),
        "expectedWorkspaceRevision": .string(
          try WorkspaceProviderSupport.workspaceRevision(
            root: checkpointProfile.projectRoot,
            profileVersion: checkpointProfile.profileID,
            globs: checkpointProfile.allowedFileGlobs)),
        "checkpointFilePaths": .array([.string(relativePath)]),
      ],
      requestID: "request-runtime-checkpoint",
      idempotencyKey: "idempotency-runtime-checkpoint",
      authorization: nil)

    // ...and the narrow file-set digest is refused, so the two meanings cannot
    // quietly swap back.
    let narrowSnapshots = try WorkspaceProviderSupport.snapshots(
      relativePaths: [relativePath], root: checkpointProfile.projectRoot)
    let narrow = try operationRequest(
      id: "workspace.create-checkpoint",
      inputs: [
        "projectRef": .string(checkpointProfile.projectRef),
        "expectedWorkspaceRevision": .string(
          WorkspaceProviderSupport.revision(narrowSnapshots)),
        "checkpointFilePaths": .array([.string(relativePath)]),
      ],
      requestID: "request-runtime-checkpoint-narrow",
      idempotencyKey: "idempotency-runtime-checkpoint-narrow",
      authorization: nil)
    do {
      _ = try await engine.submit(try JSONEncoder().encode(narrow))
      XCTFail("the narrow file-set digest must not authorize a checkpoint")
    } catch {
      XCTAssertTrue("\(error)".contains("workspace.revisionConflict"), "\(error)")
    }

    let callerInjected = try operationRequest(
      id: "workspace.create-checkpoint",
      inputs: request.inputs,
      requestID: "request-runtime-checkpoint-caller-capability",
      idempotencyKey: "idempotency-runtime-checkpoint-caller-capability")
    do {
      _ = try await engine.submit(try JSONEncoder().encode(callerInjected))
      XCTFail("a caller capability must not replace the Runtime-owned checkpoint policy")
    } catch {
      XCTAssertTrue(
        "\(error)".contains("caller-supplied capabilities cannot admit a Runtime-owned policy"),
        "\(error)")
    }
    let capabilitiesBeforePolicyIssuance = try await capabilityStore.list()
    XCTAssertTrue(capabilitiesBeforePolicyIssuance.isEmpty)

    let acceptance = try await engine.submit(try JSONEncoder().encode(request))
    let admitted = try RuntimeJobRecord.load(
      from: checkpointEngineRoot.appending(
        path: "jobs/\(acceptance.jobID)", directoryHint: .isDirectory))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))

    let artifacts = try await artifactStore.list(jobID: acceptance.jobID)
    let checkpoint = try XCTUnwrap(artifacts.first { $0.name == "checkpoint.txt" })
    XCTAssertTrue(checkpoint.status.isPublished)
    let lease = try await artifactStore.leaseReference(
      jobID: acceptance.jobID, artifactID: checkpoint.artifactID)
    let resolved = try await artifactStore.resolveLease(lease)
    let receipt = try JSONDecoder().decode(
      [String: JSONValue].self, from: Data(contentsOf: resolved.fileURL))
    XCTAssertEqual(receipt["checkpointKind"], .string("sealedArchive"))
    XCTAssertNotNil(receipt["checkpointObject"])

    let capabilities = try await capabilityStore.list()
    XCTAssertEqual(capabilities.count, 1)
    let issued = try XCTUnwrap(capabilities.first)
    XCTAssertEqual(issued.capability.issuer.kind, .runtimeDefaultPolicy)
    XCTAssertEqual(
      issued.capability.operationScope,
      [.init(operationID: "workspace.create-checkpoint", version: 1)])
    XCTAssertEqual(issued.capability.maximumUses, 1)
    XCTAssertEqual(issued.capability.exactPlanDigest, admitted.materializedPlanDigest)
    XCTAssertEqual(issued.capability.exactInputs, request.inputs)
    guard case .workspaceIdentity(
      _, let expectedRevision, let scopesDigest) = issued.capability.targetScope
    else {
      return XCTFail("checkpoint capability must bind the workspace subject")
    }
    guard case .string(let requestedRevision)? = request.inputs["expectedWorkspaceRevision"] else {
      return XCTFail("checkpoint request must carry its exact workspace revision")
    }
    XCTAssertEqual(expectedRevision, requestedRevision)
    XCTAssertEqual(
      scopesDigest,
      WorkspaceProviderSupport.sha256(
        Data(checkpointProfile.allowedFileGlobs.sorted().joined(separator: "\n").utf8)))
    XCTAssertEqual(issued.consumptionCount, 1)
    XCTAssertEqual(issued.lineage.map(\.outcome), [.confirmed])
  }

  func testWorkspaceIsUnavailableWithoutArtifactStoreBeforeAdmission() async throws {
    let grantStore2 = try RuntimeCapabilityStore(
      directoryURL: state.appending(path: "workspace-grant-2"))
    try await installWorkspaceGrant(
      into: grantStore2,
      operations: [
        "workspace.apply-patch", "workspace.build-openharmony", "workspace.revert-patch",
        "workspace.run-tests", "workspace.create-checkpoint",
      ])
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state.appending(path: "missing-artifact-engine")),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: RuntimeProcessDispatcherRouter(
        hdc: dispatcher, rockchip: dispatcher, workspace: dispatcher),
      capabilityStore: grantStore2,
      nowUTC: { "2026-07-31T00:00:00Z" })
    let operationAvailability = await engine.operationAvailability()
    let availability = try XCTUnwrap(
      operationAvailability.first {
        $0.reference == "workspace.build-openharmony@1"
      })
    XCTAssertEqual(availability.state, .unavailable)
    XCTAssertEqual(availability.reasons, ["runtime.artifactStoreUnavailable"])

    let request = try operationRequest(
      id: "workspace.build-openharmony",
      inputs: [
        "projectRef": .string("TestProject"),
        "buildPresetRef": .string("build-ok"),
      ],
      requestID: "request-missing-artifact-store",
      idempotencyKey: "idempotency-missing-artifact-store")
    do {
      _ = try await engine.submit(try JSONEncoder().encode(request))
      XCTFail("a workspace Job without Artifact storage must not be admitted")
    } catch {
      XCTAssertTrue("\(error)".contains("runtime.artifactStoreUnavailable"))
    }
    let jobs = try await engine.listJobs()
    XCTAssertTrue(jobs.isEmpty)
  }

  func testRuntimePublishesFailedBuildLogWithoutFabricatingSuccess() async throws {
    let failureProfile = try profileWithFailingBuildAndStderr()
    let failureProvider = WorkspaceOperationsProvider(
      profile: failureProfile,
      attemptStore: try WorkspacePatchAttemptStore(
        rootURL: state.appending(path: "runtime-failure-attempts")),
      nowUTC: { "2026-07-31T00:00:00Z" })
    let failureDispatcher = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: failureProfile))
    let artifactStore = try RuntimeArtifactStore(
      rootURL: state.appending(path: "runtime-failure-artifacts"),
      nowUTC: { "2026-07-31T00:00:00Z" })
    let grantStore3 = try RuntimeCapabilityStore(
      directoryURL: state.appending(path: "workspace-grant-3"))
    try await installWorkspaceGrant(
      into: grantStore3,
      operations: [
        "workspace.apply-patch", "workspace.build-openharmony", "workspace.revert-patch",
        "workspace.run-tests", "workspace.create-checkpoint",
      ])
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state.appending(path: "runtime-failure-engine")),
      providers: DeviceProviderRegistry(providers: [failureProvider]),
      dispatcher: RuntimeProcessDispatcherRouter(
        hdc: failureDispatcher, rockchip: failureDispatcher,
        workspace: failureDispatcher),
      capabilityStore: grantStore3,
      artifactStore: artifactStore,
      nowUTC: { "2026-07-31T00:00:00Z" })

    let request = try operationRequest(
      id: "workspace.build-openharmony",
      inputs: [
        "projectRef": .string("TestProject"),
        "buildPresetRef": .string("build-fail-stderr"),
      ],
      requestID: "request-runtime-build-failure",
      idempotencyKey: "idempotency-runtime-build-failure")
    let acceptance = try await engine.submit(try JSONEncoder().encode(request))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "failed")

    let artifacts = try await artifactStore.list(jobID: acceptance.jobID)
    let buildLog = try XCTUnwrap(artifacts.first { $0.name == "build.log" })
    XCTAssertTrue(buildLog.status.isPublished)
    let lease = try await artifactStore.leaseReference(
      jobID: acceptance.jobID, artifactID: buildLog.artifactID)
    let resolved = try await artifactStore.resolveLease(lease)
    let contents = try Data(contentsOf: resolved.fileURL)
    XCTAssertFalse(contents.isEmpty)
    XCTAssertTrue(
      String(decoding: contents, as: UTF8.self).contains("No such file"))
  }

  private func workspaceAction(
    _ reference: String,
    inputs: [String: JSONValue],
    context: ProviderExecutionContext
  ) throws -> WorkspaceProviderAction {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: reference))
    let action = try provider.action(
      for: descriptor.steps[0], operation: descriptor,
      inputs: inputs, context: context)
    guard case .workspace(let workspace) = action else {
      throw DeviceProviderError.unsupportedAction("not workspace")
    }
    return workspace
  }

  private func operationRequest(
    id: String,
    inputs: [String: JSONValue],
    requestID: String,
    idempotencyKey: String,
    authorization: RuntimeCapabilityReference? = workspaceGrantReference,
    targetID: String = "workspace-test"
  ) throws -> RuntimeOperationRequest {
    try RuntimeOperationRequest(
      requestID: requestID,
      idempotencyKey: idempotencyKey,
      target: DurableTargetReference(
        targetID: targetID),
      operation: RuntimeOperationReference(id: id, version: 1),
      inputs: inputs,
      authorization: authorization)
  }

  /// The grant a maintainer would have issued for this tree (CHG-2026-055,
  /// TASK-HFA-009 r2). Since r2 a workspace mutation is E1: it needs a
  /// capability scoped to this workspace identity and these writable scopes,
  /// and the runtime will not mint one for itself.
  private func installWorkspaceGrant(
    into store: RuntimeCapabilityStore, operations: [String],
    profile grantProfile: WorkspaceProjectProfile? = nil,
    capabilityID: String = WorkspaceProviderContractTests.workspaceGrantID
  ) async throws {
    let profile = grantProfile ?? self.profile!
    let capability = try RuntimeCapability(
      capabilityID: capabilityID,
      targetScope: .workspaceIdentity(
        sha256: WorkspaceProviderSupport.workspaceIdentity(
          root: profile.projectRoot, profileID: profile.profileID),
        // Empty: a standing grant for this tree, not a one-shot pinned to the
        // revision it happened to be at when it was issued.
        expectedWorkspaceRevision: "",
        allowedFileScopesDigest: WorkspaceProviderSupport.sha256(
          Data(profile.allowedFileGlobs.sorted().joined(separator: "\n").utf8))),
      operationScope: operations.map {
        RuntimeCapabilityOperationScope(operationID: $0, version: 1)
      },
      effectCeiling: .deviceMutation,
      issuedAtUTC: "2026-07-30T00:00:00Z",
      expiresAtUTC: "2026-12-31T00:00:00Z",
      maximumUses: 16,
      issuer: RuntimeCapabilityIssuer(
        kind: .maintainerMergedPR,
        reference: "test-fixture:workspace-grant"))
    try await store.install(capability)
  }

  private static let workspaceGrantID = "CAP-RT-WORKSPACE-TESTFIXTURE"
  private static let workspaceGrantReference = RuntimeCapabilityReference(
    capabilityID: workspaceGrantID)

  private func executionContext(
    artifact: ProviderResolvedInputArtifact? = nil
  ) -> ProviderExecutionContext {
    ProviderExecutionContext(
      jobID: "job-workspace", stepID: "workspace-step",
      targetID: "workspace-test", bindingRevision: nil,
      nowUTC: "2026-07-31T00:00:00Z",
      resolvedInputArtifact: artifact)
  }

  private func resolvedArtifact(
    _ url: URL, artifactID: String
  ) -> ProviderResolvedInputArtifact {
    let data = try! Data(contentsOf: url)
    return ProviderResolvedInputArtifact(
      artifactID: artifactID, fileURL: url,
      sha256: sha(data), byteCount: data.count)
  }

  private func writePatch(relativePath: String) throws -> URL {
    let patch = """
      diff --git a/\(relativePath) b/\(relativePath)
      --- a/\(relativePath)
      +++ b/\(relativePath)
      @@ -1 +1 @@
      -old
      +new

      """
    let url = state.appending(path: "\(UUID().uuidString).patch")
    try Data(patch.utf8).write(to: url)
    return url
  }

  private func profileWithFailingBuild() throws -> WorkspaceProjectProfile {
    let failure = try WorkspaceCommandPreset(
      presetID: "build-fail",
      executable: try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/false"),
      fixedArguments: [], timeoutSeconds: 10)
    return try WorkspaceProjectProfile(
      profileID: profile.profileID, projectRef: profile.projectRef,
      projectRoot: profile.projectRoot,
      allowedFileGlobs: profile.allowedFileGlobs,
      inspectionPreset: profile.inspectionPreset,
      patchPreset: profile.patchPreset,
      buildPresets: [failure.presetID: failure],
      testPresets: profile.testPresets,
      symbolPresets: profile.symbolPresets)
  }

  private func profileWithFailingBuildAndStderr() throws -> WorkspaceProjectProfile {
    let failure = try WorkspaceCommandPreset(
      presetID: "build-fail-stderr",
      executable: try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/grep"),
      fixedArguments: [
        "fixture", "/definitely-missing-arkdeck-workspace-input",
      ],
      timeoutSeconds: 10)
    return try WorkspaceProjectProfile(
      profileID: profile.profileID, projectRef: profile.projectRef,
      projectRoot: profile.projectRoot,
      allowedFileGlobs: profile.allowedFileGlobs,
      inspectionPreset: profile.inspectionPreset,
      patchPreset: profile.patchPreset,
      buildPresets: [failure.presetID: failure],
      testPresets: profile.testPresets,
      symbolPresets: profile.symbolPresets)
  }

  private func profileWithoutSymbols() throws -> WorkspaceProjectProfile {
    try WorkspaceProjectProfile(
      profileID: profile.profileID, projectRef: profile.projectRef,
      projectRoot: profile.projectRoot,
      allowedFileGlobs: profile.allowedFileGlobs,
      inspectionPreset: profile.inspectionPreset,
      patchPreset: profile.patchPreset,
      buildPresets: profile.buildPresets, testPresets: profile.testPresets,
      symbolPresets: [:])
  }

  private func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func shaSnapshot(path: String, sha256: String) -> String {
    sha(Data("\(path)\t\(sha256)".utf8))
  }

}

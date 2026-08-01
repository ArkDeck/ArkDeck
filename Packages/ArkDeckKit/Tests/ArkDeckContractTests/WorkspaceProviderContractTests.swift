import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows
import CryptoKit
import Foundation
import XCTest

final class WorkspaceProviderContractTests: XCTestCase {
  private var root: URL!
  private var state: URL!
  private var profile: WorkspaceProjectProfile!
  private var provider: WorkspaceOperationsProvider!
  private var dispatcher: DescriptorBoundProcessDispatcher!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "arkdeck-workspace-\(UUID().uuidString)", isDirectory: true)
    state = FileManager.default.temporaryDirectory.appendingPathComponent(
      "arkdeck-workspace-state-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Sources", isDirectory: true),
      withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try Data("old\n".utf8).write(
      to: root.appendingPathComponent("Sources/App.txt"))

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
        rootURL: state.appendingPathComponent("attempts", isDirectory: true)),
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
      [URL(fileURLWithPath: profile.projectRoot)
        .appendingPathComponent("Sources/App.txt").path])

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

    let dump = root.appendingPathComponent("dump.txt")
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
    guard case .verified(let summary) = try provider.verify(
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
    let durablePatchPath = state.appendingPathComponent(
      "attempts/\(reference).patch").path
    XCTAssertEqual(
      try XCTUnwrap(revert.operationInvocation).arguments,
      ["-f", "-R", "-p1", "-d", profile.projectRoot, "-i", durablePatchPath])
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: durablePatchPath)),
                   try Data(contentsOf: patchURL))
  }

  func testProductionProfileBindsSwiftPMExecutableRoleAndSelfSafeTestPreset() throws {
    var repository = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let production = try WorkspaceProjectProfile.arkDeck(rootURL: repository)
    let build = try XCTUnwrap(production.buildPresets["arkdeck-debug"])
    XCTAssertTrue(build.executable.path.hasSuffix("/usr/bin/swift-package"))
    XCTAssertTrue(build.argumentZero?.hasSuffix("/usr/bin/swift-build") == true)
    XCTAssertEqual(
      build.fixedArguments,
      [
        "--package-path",
        repository.appendingPathComponent("Packages/ArkDeckKit").path,
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

  func testWaterFlowProfilePinsTheRealBuildTestAndDeployProduct() throws {
    let project = root.appendingPathComponent("WaterFlow", isDirectory: true)
    try FileManager.default.createDirectory(
      at: project.appendingPathComponent("entry/src/main", isDirectory: true),
      withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: project.appendingPathComponent("build-profile.json5"))
    try Data("{}".utf8).write(
      to: project.appendingPathComponent("entry/src/main/module.json5"))
    let script = project.appendingPathComponent("hvigorw.js")
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
      "entry/build/default/outputs/default/entry-default-signed.hap")
    XCTAssertEqual(
      production.allowedFileGlobs,
      [
        "entry/src/main/ets/**", "entry/src/main/cpp/**",
        "entry/src/test/**", "entry/src/ohosTest/**",
      ])
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
        rootURL: state.appendingPathComponent("environment-attempts", isDirectory: true)),
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
      childEnvironment: [key: value])
    let receipt = try await environmentDispatcher.dispatch(
      try environmentProvider.lower(action: action, context: executionContext()))
    let lines = String(decoding: receipt.stdout, as: UTF8.self).split(separator: "\n")

    XCTAssertTrue(lines.contains(Substring("\(key)=\(value)")))
    XCTAssertEqual(ProcessInfo.processInfo.environment[key], inheritedValue)
  }

  func testPatchScopeApplyArtifactReadbackAndExactRevert() async throws {
    let original = try Data(contentsOf: root.appendingPathComponent("Sources/App.txt"))
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
    guard case .verified(let summary) = try provider.verify(
      receipt: receipt, action: .workspace(action), context: patchContext),
      let reference = summary["patchAttemptRef"]
    else {
      return XCTFail("apply must produce a durable patchAttemptRef")
    }
    try FileManager.default.removeItem(at: patchURL)
    XCTAssertEqual(
      String(data: try Data(
        contentsOf: root.appendingPathComponent("Sources/App.txt")), encoding: .utf8),
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
    guard case .verified(let revertSummary) = try provider.verify(
      receipt: revertReceipt, action: .workspace(revert), context: revertContext)
    else {
      return XCTFail("revert must verify by exact original file hashes")
    }
    XCTAssertEqual(revertSummary["workspaceRevision"], shaSnapshot(
      path: "Sources/App.txt", sha256: originalRevision))
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("Sources/App.txt")), original)
  }

  func testRuntimeConsumesHostBoundPatchLeaseAndRevertsExactAttempt() async throws {
    let artifactStore = try RuntimeArtifactStore(
      rootURL: state.appendingPathComponent("patch-runtime-artifacts"),
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
      directoryURL: state.appendingPathComponent("workspace-grant-1"))
    // One grant per operation: a capability's lineage is tied to the
    // operation and typed inputs of its first use, so a single grant cannot
    // cover apply-patch *and* revert-patch. That is the model the device side
    // already uses; TASK-HFA-009 r2 makes it visible for workspaces too.
    try await installWorkspaceGrant(
      into: grantStore1, operations: ["workspace.apply-patch"],
      capabilityID: "CAP-RT-WORKSPACE-APPLY")
    try await installWorkspaceGrant(
      into: grantStore1, operations: ["workspace.revert-patch"],
      capabilityID: "CAP-RT-WORKSPACE-REVERT")
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state.appendingPathComponent("patch-runtime-engine")),
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
      authorization: RuntimeCapabilityReference(capabilityID: "CAP-RT-WORKSPACE-APPLY"))
    let applyAcceptance = try await engine.submit(try JSONEncoder().encode(apply))
    let applyStatus = try await engine.run(jobID: applyAcceptance.jobID)
    XCTAssertEqual(applyStatus.state, "succeeded")
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("Sources/App.txt")),
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
      authorization: RuntimeCapabilityReference(capabilityID: "CAP-RT-WORKSPACE-REVERT"))
    let revertAcceptance = try await engine.submit(try JSONEncoder().encode(revert))
    let revertStatus = try await engine.run(jobID: revertAcceptance.jobID)
    XCTAssertEqual(revertStatus.state, "succeeded")
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("Sources/App.txt")),
      Data("old\n".utf8))
  }

  func testRuntimeDraftsAReviewableWorkspaceCapabilityWithoutInstallingOrDispatching()
    async throws
  {
    let artifactStore = try RuntimeArtifactStore(
      rootURL: state.appendingPathComponent("workspace-draft-artifacts"),
      nowUTC: { "2026-08-01T00:00:00Z" })
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: state.appendingPathComponent("workspace-draft-capabilities"))
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state.appendingPathComponent("workspace-draft-engine")),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: RuntimeProcessDispatcherRouter(
        hdc: dispatcher, rockchip: dispatcher, workspace: dispatcher),
      capabilityStore: capabilityStore,
      artifactStore: artifactStore,
      nowUTC: { "2026-08-01T00:00:00Z" })
    let observedRevision = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: profile.allowedFileGlobs)
    let request = try operationRequest(
      id: "workspace.build-openharmony",
      inputs: [
        "projectRef": .string("TestProject"),
        "buildPresetRef": .string("build-ok"),
        "expectedWorkspaceRevision": .string(observedRevision),
      ],
      requestID: "request-workspace-draft",
      idempotencyKey: "idempotency-workspace-draft",
      authorization: nil)

    let draft = try await engine.draftCapability(
      try JSONEncoder().encode(request),
      issuedAtUTC: "2026-08-01T00:00:00Z",
      expiresAtUTC: "2026-08-01T01:00:00Z",
      issuerReference: "PENDING-MAINTAINER-PR",
      maximumUses: 4)

    let expectedIdentity = WorkspaceProviderSupport.workspaceIdentity(
      root: profile.projectRoot, profileID: profile.profileID)
    let expectedScopes = WorkspaceProviderSupport.sha256(
      Data(profile.allowedFileGlobs.sorted().joined(separator: "\n").utf8))
    guard
      case .workspaceIdentity(let identity, let pinnedRevision, let scopes) =
        draft.capability.targetScope
    else {
      return XCTFail("workspace draft must carry a workspace target scope")
    }
    XCTAssertEqual(identity, expectedIdentity)
    XCTAssertEqual(pinnedRevision, "", "a standing grant survives its own mutations")
    XCTAssertEqual(scopes, expectedScopes)
    XCTAssertNil(draft.bindingRevision)
    XCTAssertNil(draft.stableIdentitySHA256)
    XCTAssertEqual(draft.workspaceIdentitySHA256, expectedIdentity)
    XCTAssertEqual(draft.workspaceRevision, observedRevision)
    XCTAssertEqual(draft.workspaceFileScopesDigest, expectedScopes)
    XCTAssertEqual(draft.capability.exactBindingRevision, nil)
    XCTAssertEqual(
      draft.capability.operationScope.map(\.reference),
      ["workspace.build-openharmony@1"])
    XCTAssertEqual(
      draft.capability.inputConstraints["projectRef"],
      .exactString("TestProject"))
    XCTAssertEqual(
      draft.capability.inputConstraints["expectedWorkspaceRevision"],
      .exactString(observedRevision))
    let installedCapabilities = try await capabilityStore.list()
    let jobs = await engine.listJobs()
    XCTAssertTrue(installedCapabilities.isEmpty)
    XCTAssertTrue(jobs.isEmpty)
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("Sources/App.txt")),
      Data("old\n".utf8),
      "drafting materializes the plan but dispatches no workspace process")

    let encoded = try JSONEncoder().encode(draft)
    let fields = try JSONDecoder().decode([String: JSONValue].self, from: encoded)
    XCTAssertNil(fields["bindingRevision"])
    XCTAssertNil(fields["stableIdentitySHA256"])
    XCTAssertEqual(fields["workspaceIdentitySHA256"], .string(expectedIdentity))
    XCTAssertEqual(fields["workspaceRevision"], .string(observedRevision))
    XCTAssertEqual(fields["workspaceFileScopesDigest"], .string(expectedScopes))
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
    guard case .verified(let summary) = try provider.verify(
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
    let forbidden = root.appendingPathComponent("Forbidden.txt")
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
    let outside = root.appendingPathComponent("App.txt")
    try Data("old\n".utf8).write(to: outside)
    let patch = """
      --- Sources/App.txt
      +++ Sources/App.txt
      @@ -1 +1 @@
      -old
      +new

      """
    let patchURL = state.appendingPathComponent("prefix-bypass.patch")
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
      try Data(contentsOf: root.appendingPathComponent("Sources/App.txt")),
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
      guard case .verified(let summary) = try provider.verify(
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
        rootURL: state.appendingPathComponent("failure-attempts")),
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
    guard case .failed(let code, _) = try failureProvider.verify(
      receipt: receipt, action: action, context: executionContext())
    else {
      return XCTFail("a non-zero build must not become verified")
    }
    XCTAssertEqual(code, "workspace.buildFailed")

    let stderrProfile = try profileWithFailingBuildAndStderr()
    let stderrProvider = WorkspaceOperationsProvider(
      profile: stderrProfile,
      attemptStore: try WorkspacePatchAttemptStore(
        rootURL: state.appendingPathComponent("stderr-attempts")),
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
    guard case .failed(let truncatedCode, _) = try stderrProvider.verify(
      receipt: truncated, action: stderrAction, context: executionContext())
    else {
      return XCTFail("a truncated diagnostic stream must fail closed")
    }
    XCTAssertEqual(truncatedCode, "workspace.outputTruncated")
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
        rootURL: state.appendingPathComponent("unavailable-attempts")),
      nowUTC: { "2026-07-31T00:00:00Z" })
    XCTAssertEqual(
      unavailable.runtimeAvailability(for: symbolDescriptor),
      .unavailable(reason: "workspace.presetUnavailable"))

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
      directoryURL: state.appendingPathComponent("unavailable-capabilities"))
    let artifactStore = try RuntimeArtifactStore(
      rootURL: state.appendingPathComponent("unavailable-artifacts"),
      nowUTC: { "2026-07-31T00:00:00Z" })
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state.appendingPathComponent("unavailable-engine")),
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
    let jobs = await engine.listJobs()
    let capabilities = try await capabilityStore.list()
    XCTAssertTrue(jobs.isEmpty)
    XCTAssertTrue(capabilities.isEmpty)
  }

  func testMaterializedPlanDigestBindsSemanticArgumentZero() async throws {
    var digests: [String] = []
    for (index, argumentZero) in [nil, "profile-owned-printf"] .enumerated() {
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
          rootURL: state.appendingPathComponent("digest-attempts-\(index)")),
        nowUTC: { "2026-07-31T00:00:00Z" })
      let variantDispatcher = DescriptorBoundProcessDispatcher(
        resolver: WorkspaceActionExecutableResolver(profile: variant))
      let engineRoot = state.appendingPathComponent("digest-engine-\(index)")
      // The variant profile is a *different* tree, so its grant must be
      // issued against that identity — a capability for one workspace does
      // not authorize another (CHG-2026-055, TASK-HFA-009 r2).
      let variantGrants = try RuntimeCapabilityStore(
        directoryURL: state.appendingPathComponent("digest-capabilities-\(index)"))
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
          rootURL: state.appendingPathComponent("digest-artifacts-\(index)"),
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
        from: engineRoot.appendingPathComponent(
          "jobs/\(acceptance.jobID)", isDirectory: true))
      digests.append(try XCTUnwrap(record.materializedPlanDigest))
    }
    XCTAssertNotEqual(digests[0], digests[1])
  }

  func testCatalogToRuntimeBuildSpawnsAndPublishesExactArtifact() async throws {
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: state.appendingPathComponent("runtime-capabilities"))
    let artifactStore = try RuntimeArtifactStore(
      rootURL: state.appendingPathComponent("runtime-artifacts"),
      nowUTC: { "2026-07-31T00:00:00Z" })
    try await installWorkspaceGrant(
      into: capabilityStore, operations: ["workspace.build-openharmony"])
    let engineRoot = state.appendingPathComponent("runtime-engine")
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
      from: engineRoot.appendingPathComponent(
        "jobs/\(acceptance.jobID)", isDirectory: true))
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

  func testWorkspaceIsUnavailableWithoutArtifactStoreBeforeAdmission() async throws {
    let grantStore2 = try RuntimeCapabilityStore(
      directoryURL: state.appendingPathComponent("workspace-grant-2"))
    try await installWorkspaceGrant(into: grantStore2, operations: ["workspace.apply-patch", "workspace.build-openharmony", "workspace.revert-patch", "workspace.run-tests", "workspace.create-checkpoint"])
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state.appendingPathComponent("missing-artifact-engine")),
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
    let jobs = await engine.listJobs()
    XCTAssertTrue(jobs.isEmpty)
  }

  func testRuntimePublishesFailedBuildLogWithoutFabricatingSuccess() async throws {
    let failureProfile = try profileWithFailingBuildAndStderr()
    let failureProvider = WorkspaceOperationsProvider(
      profile: failureProfile,
      attemptStore: try WorkspacePatchAttemptStore(
        rootURL: state.appendingPathComponent("runtime-failure-attempts")),
      nowUTC: { "2026-07-31T00:00:00Z" })
    let failureDispatcher = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: failureProfile))
    let artifactStore = try RuntimeArtifactStore(
      rootURL: state.appendingPathComponent("runtime-failure-artifacts"),
      nowUTC: { "2026-07-31T00:00:00Z" })
    let grantStore3 = try RuntimeCapabilityStore(
      directoryURL: state.appendingPathComponent("workspace-grant-3"))
    try await installWorkspaceGrant(into: grantStore3, operations: ["workspace.apply-patch", "workspace.build-openharmony", "workspace.revert-patch", "workspace.run-tests", "workspace.create-checkpoint"])
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state.appendingPathComponent("runtime-failure-engine")),
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
    authorization: RuntimeCapabilityReference? = workspaceGrantReference
  ) throws -> RuntimeOperationRequest {
    try RuntimeOperationRequest(
      requestID: requestID,
      idempotencyKey: idempotencyKey,
      target: DurableTargetReference(
        targetID: "workspace-test"),
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
    let url = state.appendingPathComponent("\(UUID().uuidString).patch")
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

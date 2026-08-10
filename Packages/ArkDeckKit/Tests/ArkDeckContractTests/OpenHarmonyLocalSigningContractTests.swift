import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class OpenHarmonyLocalSigningContractTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "arkdeck-local-signing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  func testPresetInstallStatusDriftAndRemovalArePrivateAndReversible() throws {
    let fixture = try makeFixture(mode: "success")
    let receipt = try fixture.store.install(
      configuration: fixture.configuration,
      keystorePassword: Data("keystore-secret".utf8),
      keyPassword: Data("key-secret".utf8))

    let status = fixture.store.status()
    XCTAssertTrue(status.installed)
    XCTAssertTrue(status.ready, status.diagnostics.joined(separator: " | "))
    XCTAssertTrue(status.keystorePasswordPresent)
    XCTAssertTrue(status.keyPasswordPresent)
    XCTAssertEqual(status.javaSHA256, receipt.javaExecutable.sha256)
    XCTAssertEqual(status.signerJARSHA256, receipt.signerJAR.sha256)
    XCTAssertEqual(status.keystoreSHA256, receipt.keystore.sha256)
    XCTAssertEqual(status.appCertificateSHA256, receipt.appCertificate.sha256)
    XCTAssertEqual(status.signedProfileSHA256, receipt.signedProfile.sha256)
    let receiptBytes = try Data(contentsOf: URL(fileURLWithPath: status.receiptPath))
    XCTAssertFalse(receiptBytes.contains(Data("keystore-secret".utf8)))
    XCTAssertFalse(receiptBytes.contains(Data("key-secret".utf8)))
    XCTAssertEqual(try permissions(status.receiptPath) & 0o777, 0o600)
    XCTAssertEqual(try permissions(root.appendingPathComponent("preset").path) & 0o777, 0o700)

    try Data("drifted".utf8).write(to: URL(fileURLWithPath: receipt.signerJAR.path))
    let drifted = fixture.store.status()
    XCTAssertFalse(drifted.ready)
    XCTAssertTrue(drifted.diagnostics.joined().contains("drift"))

    let removal = try fixture.store.remove()
    XCTAssertTrue(removal.removedReceipt)
    XCTAssertTrue(removal.removedKeystorePassword)
    XCTAssertTrue(removal.removedKeyPassword)
    for path in removal.preservedSourcePaths {
      XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
    XCTAssertFalse(fixture.store.status().installed)
  }

  func testPresetRejectsSymlinkAndPermissionWideningAndReceiptFieldDrift() throws {
    let symlinkFixture = try makeFixture(mode: "success")
    let linkedJAR = root.appendingPathComponent("linked-signer.jar")
    try FileManager.default.createSymbolicLink(
      at: linkedJAR, withDestinationURL: symlinkFixture.configuration.signerJAR)
    let linkedConfiguration = OpenHarmonySigningPresetConfiguration(
      javaExecutable: symlinkFixture.configuration.javaExecutable,
      signerJAR: linkedJAR,
      keystore: symlinkFixture.configuration.keystore,
      appCertificate: symlinkFixture.configuration.appCertificate,
      signedProfile: symlinkFixture.configuration.signedProfile,
      keyAlias: symlinkFixture.configuration.keyAlias)
    XCTAssertThrowsError(
      try symlinkFixture.store.install(
        configuration: linkedConfiguration,
        keystorePassword: Data("keystore-secret".utf8),
        keyPassword: Data("key-secret".utf8)))

    let fixture = try makeFixture(mode: "success")
    _ = try fixture.store.install(
      configuration: fixture.configuration,
      keystorePassword: Data("keystore-secret".utf8),
      keyPassword: Data("key-secret".utf8))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: fixture.configuration.keystore.path)
    XCTAssertFalse(fixture.store.status().ready)

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: fixture.configuration.keystore.path)
    let receiptURL = URL(fileURLWithPath: fixture.store.receiptPath)
    var receipt = try JSONSerialization.jsonObject(
      with: Data(contentsOf: receiptURL)) as! [String: Any]
    receipt["signingAlgorithm"] = "caller-selected-algorithm"
    try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(
      to: receiptURL)
    XCTAssertFalse(fixture.store.status().ready)
  }

  func testPresetUpdateRestoresExistingKeychainSecretsWhenReceiptReplacementFails() throws {
    let fixture = try makeFixture(mode: "success")
    let receipt = try fixture.store.install(
      configuration: fixture.configuration,
      keystorePassword: Data("old-keystore-secret".utf8),
      keyPassword: Data("old-key-secret".utf8))
    let receiptURL = URL(fileURLWithPath: fixture.store.receiptPath)
    try FileManager.default.removeItem(at: receiptURL)
    try FileManager.default.createDirectory(at: receiptURL, withIntermediateDirectories: false)

    XCTAssertThrowsError(
      try fixture.store.install(
        configuration: fixture.configuration,
        keystorePassword: Data("replacement-keystore-secret".utf8),
        keyPassword: Data("replacement-key-secret".utf8)))
    XCTAssertEqual(
      try fixture.secrets.read(account: receipt.keystorePasswordAccount),
      Data("old-keystore-secret".utf8))
    XCTAssertEqual(
      try fixture.secrets.read(account: receipt.keyPasswordAccount),
      Data("old-key-secret".utf8))
  }

  func testJARDriftAfterPlanMaterializationRefusesBeforeSpawn() async throws {
    let fixture = try makeFixture(mode: "success")
    try installSecrets(in: fixture)
    let attempts = try OpenHarmonySigningAttemptStore(
      rootURL: root.appendingPathComponent("jar-drift-attempts"))
    let provider = try makeProvider(store: fixture.store, attemptStore: attempts)
    let input = root.appendingPathComponent("jar-drift-input.hap")
    let bytes = Data([0x50, 0x4b, 0x03, 0x04]) + Data("input".utf8)
    try bytes.write(to: input)
    let context = ProviderExecutionContext(
      jobID: "job-jar-drift", stepID: "sign-workspace-hap",
      targetID: "TGT-SIGN", bindingRevision: nil,
      nowUTC: "2026-08-10T00:00:00Z",
      resolvedInputArtifact: ProviderResolvedInputArtifact(
        artifactID: "ART-INPUT", fileURL: input,
        sha256: sha256(bytes), byteCount: bytes.count))
    let action = try signingAction(provider: provider.provider, context: context)
    let plan = try provider.provider.lower(action: action, context: context)
    try Data("drift-after-materialization".utf8).write(
      to: fixture.configuration.signerJAR)
    let generic = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: provider.profile))
    let dispatcher = OpenHarmonySigningWorkspaceDispatcher(
      fallback: generic, presetStore: fixture.store)
    do {
      _ = try await dispatcher.dispatch(plan)
      XCTFail("JAR drift must refuse before the signer process")
    } catch {
      XCTAssertTrue("\(error)".contains("before dispatch"), "\(error)")
    }
    let paths = attempts.paths(jobID: context.jobID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.directory))
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.signedHAP))
  }

  func testSigningIsUnavailableBeforeAdmissionWithoutRuntimeArtifactStore() async throws {
    let fixture = try makeFixture(mode: "success")
    try installSecrets(in: fixture)
    let provider = try makeProvider(
      store: fixture.store,
      attemptStore: try OpenHarmonySigningAttemptStore(
        rootURL: root.appendingPathComponent("missing-artifact-store-attempts")))
    let generic = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: provider.profile))
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: root.appendingPathComponent("missing-artifact-engine")),
      providers: DeviceProviderRegistry(providers: [provider.provider]),
      dispatcher: RuntimeProcessDispatcherRouter(
        hdc: generic, rockchip: generic,
        workspace: OpenHarmonySigningWorkspaceDispatcher(
          fallback: generic, presetStore: fixture.store)),
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: root.appendingPathComponent("missing-artifact-capabilities")),
      nowUTC: { "2026-08-10T00:00:00Z" })
    let availabilities = await engine.operationAvailability()
    let availability = try XCTUnwrap(
      availabilities.first {
        $0.reference == OpenHarmonyLocalSigning.operationReference
      })
    XCTAssertEqual(availability.state, .unavailable)
    XCTAssertTrue(availability.reasons.contains("runtime.artifactStoreUnavailable"))

    let request = try RuntimeOperationRequest(
      requestID: "request-no-artifact-store",
      idempotencyKey: "idempotency-no-artifact-store",
      target: DurableTargetReference(targetID: "TGT-SIGN"),
      operation: RuntimeOperationReference(
        id: "workspace.sign-openharmony-hap", version: 1),
      inputs: [
        "projectRef": .string(OpenHarmonyLocalSigning.defaultProjectRef),
        "signingPresetRef": .string(OpenHarmonyLocalSigning.defaultPresetID),
        "unsignedHapArtifactLease": .string("lease-v1:missing:artifact"),
      ])
    do {
      _ = try await engine.submit(try JSONEncoder().encode(request))
      XCTFail("signing must refuse before Job admission without an Artifact store")
    } catch {
      XCTAssertTrue("\(error)".contains("runtime.artifactStoreUnavailable"), "\(error)")
    }
  }

  func testPromptAndVerifyFaultsNeverProduceAVerifiedResult() async throws {
    for mode in ["unknown-prompt", "repeat-prompt", "verify-failure", "empty-profile"] {
      let fixture = try makeFixture(mode: mode)
      try installSecrets(in: fixture)
      let attempts = try OpenHarmonySigningAttemptStore(
        rootURL: root.appendingPathComponent("fault-attempts-\(mode)"))
      let provider = try makeProvider(store: fixture.store, attemptStore: attempts)
      let input = root.appendingPathComponent("fault-input-\(mode).hap")
      let bytes = Data([0x50, 0x4b, 0x03, 0x04]) + Data("input".utf8)
      try bytes.write(to: input)
      let context = ProviderExecutionContext(
        jobID: "job-fault-\(mode)", stepID: "sign-workspace-hap",
        targetID: "TGT-SIGN", bindingRevision: nil,
        nowUTC: "2026-08-10T00:00:00Z",
        resolvedInputArtifact: ProviderResolvedInputArtifact(
          artifactID: "ART-INPUT", fileURL: input,
          sha256: sha256(bytes), byteCount: bytes.count))
      let action = try signingAction(provider: provider.provider, context: context)
      let generic = DescriptorBoundProcessDispatcher(
        resolver: WorkspaceActionExecutableResolver(profile: provider.profile))
      let dispatcher = OpenHarmonySigningWorkspaceDispatcher(
        fallback: generic, presetStore: fixture.store)
      do {
        _ = try await dispatcher.dispatch(
          try provider.provider.lower(action: action, context: context))
        XCTFail("\(mode) must not verify")
      } catch {
        let message = "\(error)"
        XCTAssertTrue(
          message.contains("requires readback") || message.contains("requires recovery"),
          "\(mode): \(error)")
      }
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: attempts.paths(jobID: context.jobID).resultRecord), mode)
    }
  }

  func testTypedRuntimeSignsPublishesReportAndPreservesSourceBindingWithoutSecrets()
    async throws
  {
    let fixture = try makeFixture(mode: "success")
    try installSecrets(in: fixture)
    let artifacts = try RuntimeArtifactStore(
      rootURL: root.appendingPathComponent("artifacts"),
      nowUTC: { "2026-08-10T00:00:00Z" })
    let sourceURL = root.appendingPathComponent("unsigned.hap")
    let sourceBytes = Data([0x50, 0x4b, 0x03, 0x04]) + Data("unsigned-body".utf8)
    try sourceBytes.write(to: sourceURL)
    let sourceSHA = sha256(sourceBytes)
    let source = try await artifacts.publishFile(
      RuntimeArtifactFilePublicationRequest(
        jobID: "import-job", sessionID: "import-session", stepID: "import-hap",
        name: "unsigned.hap", mediaType: "application/vnd.openharmony.hap",
        privacy: .standard, retentionClass: .pinnedUntilVerified,
        sourceOperation: "artifact.import-hap", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-SIGN", bindingRevision: 7,
          stableIdentitySHA256: String(repeating: "a", count: 64)),
        sourceFileURL: sourceURL, expectedByteCount: sourceBytes.count,
        expectedSHA256: sourceSHA))
    let sourceLease = try await artifacts.leaseReference(
      jobID: source.jobID, artifactID: source.artifactID)

    let attempts = try OpenHarmonySigningAttemptStore(
      rootURL: root.appendingPathComponent("signing-attempts"))
    let provider = try makeProvider(
      store: fixture.store, attemptStore: attempts)
    let generic = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: provider.profile))
    let signing = OpenHarmonySigningWorkspaceDispatcher(
      fallback: generic, presetStore: fixture.store)
    let engineState = root.appendingPathComponent("engine")
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: engineState),
      providers: DeviceProviderRegistry(providers: [provider.provider]),
      dispatcher: RuntimeProcessDispatcherRouter(
        hdc: generic, rockchip: generic, workspace: signing),
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: root.appendingPathComponent("capabilities")),
      artifactStore: artifacts,
      nowUTC: { "2026-08-10T00:00:00Z" })
    let request = try RuntimeOperationRequest(
      requestID: "request-sign", idempotencyKey: "idempotency-sign",
      target: DurableTargetReference(targetID: "TGT-SIGN"),
      operation: RuntimeOperationReference(
        id: "workspace.sign-openharmony-hap", version: 1),
      inputs: [
        "projectRef": .string(OpenHarmonyLocalSigning.defaultProjectRef),
        "signingPresetRef": .string(OpenHarmonyLocalSigning.defaultPresetID),
        "unsignedHapArtifactLease": .string(sourceLease),
      ])
    let accepted = try await engine.submit(try JSONEncoder().encode(request))
    let status = try await engine.run(jobID: accepted.jobID)
    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))

    let published = try await artifacts.list(jobID: accepted.jobID)
    let signed = try XCTUnwrap(published.first { $0.name == "signed.hap" })
    let report = try XCTUnwrap(published.first { $0.name == "signing-report.json" })
    XCTAssertTrue(signed.status.isPublished)
    XCTAssertTrue(report.status.isPublished)
    XCTAssertEqual(signed.bindingSnapshot, source.bindingSnapshot)
    XCTAssertEqual(report.bindingSnapshot, source.bindingSnapshot)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: attempts.paths(jobID: accepted.jobID).directory),
      "a known terminal must remove its bounded provider-owned signing directory")
    let signedLease = try await artifacts.leaseReference(
      jobID: signed.jobID, artifactID: signed.artifactID)
    let resolvedSigned = try await artifacts.resolveLease(signedLease)
    XCTAssertTrue(
      try Data(contentsOf: resolvedSigned.fileURL).starts(with: [0x50, 0x4b, 0x03, 0x04]))

    let durableFiles = try regularFiles(below: root)
    for url in durableFiles {
      let bytes = (try? Data(contentsOf: url)) ?? Data()
      XCTAssertFalse(bytes.contains(Data("keystore-secret".utf8)), url.path)
      XCTAssertFalse(bytes.contains(Data("key-secret".utf8)), url.path)
    }

    let wrongTarget = try RuntimeOperationRequest(
      requestID: "request-sign-wrong-target",
      idempotencyKey: "idempotency-sign-wrong-target",
      target: DurableTargetReference(targetID: "TGT-OTHER"),
      operation: RuntimeOperationReference(
        id: "workspace.sign-openharmony-hap", version: 1),
      inputs: request.inputs)
    do {
      _ = try await engine.submit(try JSONEncoder().encode(wrongTarget))
      XCTFail("a source Artifact from another target must be rejected")
    } catch {
      XCTAssertTrue("\(error)".contains("target/binding/identity"), "\(error)")
    }
  }

  func testPTYSecretEchoFailsClosedWithoutSignedOutputOrResult() async throws {
    let fixture = try makeFixture(mode: "echo-secret")
    try installSecrets(in: fixture)
    let attempts = try OpenHarmonySigningAttemptStore(
      rootURL: root.appendingPathComponent("echo-attempts"))
    let provider = try makeProvider(store: fixture.store, attemptStore: attempts)
    let input = root.appendingPathComponent("echo-input.hap")
    let bytes = Data([0x50, 0x4b, 0x03, 0x04]) + Data("input".utf8)
    try bytes.write(to: input)
    let context = ProviderExecutionContext(
      jobID: "job-secret-echo", stepID: "sign-workspace-hap",
      targetID: "TGT-SIGN", bindingRevision: nil,
      nowUTC: "2026-08-10T00:00:00Z",
      resolvedInputArtifact: ProviderResolvedInputArtifact(
        artifactID: "ART-INPUT", fileURL: input,
        sha256: sha256(bytes), byteCount: bytes.count))
    let action = try signingAction(provider: provider.provider, context: context)
    let plan = try provider.provider.lower(action: action, context: context)
    let generic = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: provider.profile))
    let dispatcher = OpenHarmonySigningWorkspaceDispatcher(
      fallback: generic, presetStore: fixture.store)
    do {
      _ = try await dispatcher.dispatch(plan)
      XCTFail("a signer that echoes a secret must fail closed")
    } catch {
      XCTAssertTrue("\(error)".contains("privacyFailure"), "\(error)")
    }
    let paths = attempts.paths(jobID: context.jobID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.signedHAP))
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.resultRecord))
  }

  func testRecoveryVerifiesExistingOutputWithoutReplayingSign() async throws {
    let fixture = try makeFixture(mode: "success")
    try installSecrets(in: fixture)
    let attempts = try OpenHarmonySigningAttemptStore(
      rootURL: root.appendingPathComponent("recovery-attempts"))
    let provider = try makeProvider(store: fixture.store, attemptStore: attempts)
    let input = root.appendingPathComponent("recovery-input.hap")
    let bytes = Data([0x50, 0x4b, 0x03, 0x04]) + Data("input".utf8)
    try bytes.write(to: input)
    let context = ProviderExecutionContext(
      jobID: "job-recovery", stepID: "sign-workspace-hap",
      targetID: "TGT-SIGN", bindingRevision: nil,
      nowUTC: "2026-08-10T00:00:00Z",
      resolvedInputArtifact: ProviderResolvedInputArtifact(
        artifactID: "ART-INPUT", fileURL: input,
        sha256: sha256(bytes), byteCount: bytes.count))
    let action = try signingAction(provider: provider.provider, context: context)
    let generic = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: provider.profile))
    let dispatcher = OpenHarmonySigningWorkspaceDispatcher(
      fallback: generic, presetStore: fixture.store)
    _ = try await dispatcher.dispatch(
      try provider.provider.lower(action: action, context: context))
    guard case .workspace(.signOpenHarmonyHap(let signingAction)) = action else {
      return XCTFail("expected signing action")
    }
    let original = try Data(contentsOf: URL(fileURLWithPath: signingAction.output.signedHAP))
    try FileManager.default.removeItem(atPath: signingAction.output.resultRecord)
    let recovered = try await provider.provider.reconcile(
      intent: ProviderDurableIntentReference(
        jobID: context.jobID, stepID: context.stepID,
        intentEventID: "intent-recovery", action: action),
      context: context)
    guard case .confirmedCompleted(let summary) = recovered else {
      return XCTFail("verified existing output should recover: \(recovered)")
    }
    XCTAssertEqual(summary["verification"], "verified")
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: signingAction.output.signedHAP)), original)
    XCTAssertTrue(FileManager.default.fileExists(atPath: signingAction.output.resultRecord))
  }

  func testRuntimeRecoveryPublishesVerifiedOutputThenResumesWithoutReplay() async throws {
    let marker = root.appendingPathComponent("verify-failed-once")
    let fixture = try makeFixture(mode: "verify-once:\(marker.path)")
    try installSecrets(in: fixture)
    let artifacts = try RuntimeArtifactStore(
      rootURL: root.appendingPathComponent("recovery-artifacts"),
      nowUTC: { "2026-08-10T00:00:00Z" })
    let sourceURL = root.appendingPathComponent("runtime-recovery-unsigned.hap")
    let sourceBytes = Data([0x50, 0x4b, 0x03, 0x04]) + Data("unsigned-body".utf8)
    try sourceBytes.write(to: sourceURL)
    let source = try await artifacts.publishFile(
      RuntimeArtifactFilePublicationRequest(
        jobID: "recovery-import", sessionID: "recovery-import-session",
        stepID: "import-hap", name: "unsigned.hap",
        mediaType: "application/vnd.openharmony.hap", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "artifact.import-hap", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-RECOVERY", bindingRevision: 9,
          stableIdentitySHA256: String(repeating: "b", count: 64)),
        sourceFileURL: sourceURL, expectedByteCount: sourceBytes.count,
        expectedSHA256: sha256(sourceBytes)))
    let sourceLease = try await artifacts.leaseReference(
      jobID: source.jobID, artifactID: source.artifactID)
    let attempts = try OpenHarmonySigningAttemptStore(
      rootURL: root.appendingPathComponent("runtime-recovery-attempts"))
    let provider = try makeProvider(store: fixture.store, attemptStore: attempts)
    let generic = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: provider.profile))
    let signing = OpenHarmonySigningWorkspaceDispatcher(
      fallback: generic, presetStore: fixture.store)
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: root.appendingPathComponent("recovery-engine")),
      providers: DeviceProviderRegistry(providers: [provider.provider]),
      dispatcher: RuntimeProcessDispatcherRouter(
        hdc: generic, rockchip: generic, workspace: signing),
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: root.appendingPathComponent("recovery-capabilities")),
      artifactStore: artifacts,
      nowUTC: { "2026-08-10T00:00:00Z" })
    let request = try RuntimeOperationRequest(
      requestID: "request-runtime-recovery",
      idempotencyKey: "idempotency-runtime-recovery",
      target: DurableTargetReference(targetID: "TGT-RECOVERY"),
      operation: RuntimeOperationReference(
        id: "workspace.sign-openharmony-hap", version: 1),
      inputs: [
        "projectRef": .string(OpenHarmonyLocalSigning.defaultProjectRef),
        "signingPresetRef": .string(OpenHarmonyLocalSigning.defaultPresetID),
        "unsignedHapArtifactLease": .string(sourceLease),
      ])
    let accepted = try await engine.submit(try JSONEncoder().encode(request))
    let first = try await engine.run(jobID: accepted.jobID)
    XCTAssertEqual(first.state, "waitingForRecovery")
    XCTAssertTrue(first.outcomeUnknown)
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: attempts.paths(jobID: accepted.jobID).signedHAP))
    let beforeRecoveryArtifacts = try await artifacts.list(jobID: accepted.jobID)
    XCTAssertTrue(beforeRecoveryArtifacts.isEmpty)

    let reconciled = try await engine.reconcile(jobID: accepted.jobID)
    XCTAssertEqual(reconciled.state, "resumeAtConfirmedSafeBoundary")
    XCTAssertFalse(reconciled.outcomeUnknown)
    let recoveredArtifacts = try await artifacts.list(jobID: accepted.jobID)
    XCTAssertEqual(Set(recoveredArtifacts.map(\.name)), ["signed.hap", "signing-report.json"])
    XCTAssertTrue(recoveredArtifacts.allSatisfy { $0.bindingSnapshot == source.bindingSnapshot })

    let terminal = try await engine.run(jobID: accepted.jobID)
    XCTAssertEqual(terminal.state, "succeeded", terminal.timeline.joined(separator: " | "))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: attempts.paths(jobID: accepted.jobID).directory))
  }

  private struct SigningFixture {
    let store: OpenHarmonySigningPresetStore
    let secrets: MemorySigningSecretStore
    let configuration: OpenHarmonySigningPresetConfiguration
  }

  private struct SigningProvider {
    let profile: WorkspaceProjectProfile
    let provider: WorkspaceOperationsProvider
  }

  private func makeFixture(mode: String) throws -> SigningFixture {
    let materials = root.appendingPathComponent("materials-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
    let jar = materials.appendingPathComponent("hap-sign-tool.jar")
    let keystore = materials.appendingPathComponent("release.p12")
    let certificate = materials.appendingPathComponent("release.cer")
    let profile = materials.appendingPathComponent("release.p7b")
    try Data(mode.utf8).write(to: jar)
    try Data("keystore-fixture".utf8).write(to: keystore)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: keystore.path)
    try Data("certificate-fixture".utf8).write(to: certificate)
    try Data("profile-fixture".utf8).write(to: profile)
    let secrets = MemorySigningSecretStore()
    let store = OpenHarmonySigningPresetStore(
      rootURL: root.appendingPathComponent("preset"),
      secrets: secrets,
      nowUTC: { "2026-08-10T00:00:00Z" })
    return SigningFixture(
      store: store, secrets: secrets,
      configuration: OpenHarmonySigningPresetConfiguration(
        javaExecutable: productsDirectory.appendingPathComponent(
          "ArkDeckFakeHapSignerFixture").resolvingSymlinksInPath(),
        signerJAR: jar, keystore: keystore,
        appCertificate: certificate, signedProfile: profile,
        keyAlias: "test-key"))
  }

  private func installSecrets(in fixture: SigningFixture) throws {
    _ = try fixture.store.install(
      configuration: fixture.configuration,
      keystorePassword: Data("keystore-secret".utf8),
      keyPassword: Data("key-secret".utf8))
  }

  private func makeProvider(
    store: OpenHarmonySigningPresetStore,
    attemptStore: OpenHarmonySigningAttemptStore
  ) throws -> SigningProvider {
    let workspace = root.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let tool = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/printf")
    let inspection = try WorkspaceCommandPreset(
      presetID: "inspect", executable: tool, fixedArguments: [], timeoutSeconds: 10)
    let patch = try WorkspaceCommandPreset(
      presetID: "patch", executable: tool, fixedArguments: [], timeoutSeconds: 10)
    let profile = try WorkspaceProjectProfile(
      profileID: "signing-test@1",
      projectRef: OpenHarmonyLocalSigning.defaultProjectRef,
      projectRoot: workspace.path, allowedFileGlobs: ["Sources/**"],
      inspectionPreset: inspection, patchPreset: patch,
      buildPresets: [:], testPresets: [:], symbolPresets: [:])
    return SigningProvider(
      profile: profile,
      provider: WorkspaceOperationsProvider(
        profile: profile,
        attemptStore: try WorkspacePatchAttemptStore(
          rootURL: root.appendingPathComponent("patch-attempts-\(UUID().uuidString)")),
        signingPresetStore: store, signingAttemptStore: attemptStore,
        nowUTC: { "2026-08-10T00:00:00Z" }))
  }

  private func signingAction(
    provider: WorkspaceOperationsProvider,
    context: ProviderExecutionContext
  ) throws -> TypedProviderAction {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(
        reference: OpenHarmonyLocalSigning.operationReference))
    return try provider.action(
      for: try XCTUnwrap(descriptor.steps.first), operation: descriptor,
      inputs: [
        "projectRef": .string(OpenHarmonyLocalSigning.defaultProjectRef),
        "signingPresetRef": .string(OpenHarmonyLocalSigning.defaultPresetID),
        "unsignedHapArtifactLease": .string("lease-v1:test:input"),
      ], context: context)
  }

  private func permissions(_ path: String) throws -> mode_t {
    var info = stat()
    guard path.withCString({ lstat($0, &info) }) == 0 else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    return info.st_mode
  }

  private func regularFiles(below root: URL) throws -> [URL] {
    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: keys)
    else { return [] }
    return try enumerator.compactMap { item in
      guard let url = item as? URL,
        try url.resourceValues(forKeys: Set(keys)).isRegularFile == true
      else { return nil }
      return url
    }
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private var productsDirectory: URL {
    #if os(macOS)
      for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        return bundle.bundleURL.deletingLastPathComponent()
      }
    #endif
    return Bundle.main.bundleURL
  }
}

private final class MemorySigningSecretStore: OpenHarmonySigningSecretStoring,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var values: [String: Data] = [:]

  func set(_ data: Data, account: String) throws {
    lock.withLock { values[account] = data }
  }

  func read(account: String) throws -> Data {
    try lock.withLock {
      guard let value = values[account] else {
        throw OpenHarmonySigningError.secretUnavailable("missing test secret")
      }
      return value
    }
  }

  func contains(account: String) -> Bool {
    lock.withLock { values[account] != nil }
  }

  @discardableResult
  func remove(account: String) throws -> Bool {
    lock.withLock { values.removeValue(forKey: account) != nil }
  }
}

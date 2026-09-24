// Shared Swift oracle for the Rust port of `workspace.sign-openharmony-hap@1`
// (TASK-XPA-015, M3): every signing Job the production control plane answers
// for a registered signing preset — plan, submit, run, reconcile and result,
// in order — then what the Runtime keeps afterwards: the published signed
// HAPs and signing reports, the signing credential owner's ledger, and the
// durable record of each Job whose outcome was once unknown.
//
// The sequence covers an unregistered preset and an input that is not a ZIP
// container (both refused before admission), a HAP signed, verified, recorded
// and published with its source's binding, a signer that rejects the
// password (parked, then reconciled as not executed: no product was written),
// a signer that echoes a password (the same, as a privacy failure), and a
// verification that fails once after the signer ran (parked, reconciled by
// reading the product back and verifying it again — never by signing again —
// then resumed to success).
//
// The job.* corpora carry no frame of this operation. Host-local only: no
// device, no daemon process, no Keychain, no real signer. `hap-signer.sh`
// stands in for the Java launcher the preset pins and reads its mode from
// the input HAP; both passwords are fixed fakes held in memory, answered on
// the signer's terminal, and asserted absent from every file the Runtime
// keeps. The receipt, the Keychain account it names and every path are
// fixed, so every identity repeats on every host. Record with
// `ARKDECK_RUST_WORKSPACE_SIGN_RECORD=/private/tmp/<new directory>`.
import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentComposition
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// The oracle's Keychain: fixed fake passwords held in memory.
private final class OracleSigningSecrets: OpenHarmonySigningSecretStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Data] = [:]

  func set(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }

  func read(account: String) throws -> Data {
    try lock.withLock {
      guard let value = values[account] else {
        throw OpenHarmonySigningError.secretUnavailable("missing oracle secret")
      }
      return value
    }
  }

  func contains(account: String) -> Bool { lock.withLock { values[account] != nil } }

  func presence(of account: String) -> OpenHarmonySigningSecretPresence {
    contains(account: account) ? .present : .absent
  }

  func trustedDaemonApplicationSHA256() throws -> String? { nil }

  @discardableResult
  func remove(account: String) throws -> Bool {
    lock.withLock { values.removeValue(forKey: account) != nil }
  }
}

/// Swift's secret envelope, as `OpenHarmonySigningPresetStore` encodes it.
private struct OracleSecretEnvelope: Codable {
  let schemaVersion: String
  let keystorePassword: Data
  let keyPassword: Data
}

final class WorkspaceSignOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/workspace-sign-oracle", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_WORKSPACE_SIGN_RECORD"
  /// The recording's fixed root, and Foundation's spelling of it, which the
  /// receipt, the attempt store and the lowered argv name.
  private static let oracleRoot = URL(
    filePath: "/private/tmp/arkdeck-workspace-sign-oracle", directoryHint: .isDirectory)
  private static let foundationRoot = "/tmp/arkdeck-workspace-sign-oracle"
  private static let timestamp = "2026-09-25T00:00:00Z"
  private static let project = "SignOracleProject"
  private static let profileID = "workspace-sign-oracle@1"
  private static let signingPreset = "preset-signing-oracle"
  private static let envelopeAccount =
    "openharmony-release@1|secret-envelope-5d3c1f0e-7a2b-4c9d-8e6f-0a1b2c3d4e5f"
  /// Fake passwords: nothing they unlock exists anywhere.
  static let keystoreSecret = "oracle-keystore-password-7f3a"
  static let keySecret = "oracle-key-password-2c9e"
  private static let inputJob = "job-input-hap"
  private var root: URL?

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  private struct Stack {
    let handler: RuntimeControlPlaneHandler
    let artifacts: RuntimeArtifactStore
  }

  private func write(_ bytes: Data, to path: String, mode: Int) throws {
    let url = URL(filePath: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
  }

  /// The installed signing preset: the stand-in signer as its Java launcher,
  /// the closed material, the receipt naming them, and the envelope holding
  /// both fake passwords under the receipt's Keychain account.
  private func installPreset(
    secrets: OracleSigningSecrets
  ) throws -> OpenHarmonySigningPresetStore {
    let base = Self.foundationRoot
    try write(
      Data(contentsOf: Self.oracle.appending(path: "hap-signer.sh")),
      to: "\(base)/tools/java", mode: 0o755)
    try write(Data("oracle hap-sign-tool\n".utf8), to: "\(base)/material/hap-sign-tool.jar", mode: 0o644)
    try write(Data("oracle keystore\n".utf8), to: "\(base)/material/release.p12", mode: 0o600)
    try write(Data("oracle certificate\n".utf8), to: "\(base)/material/release.cer", mode: 0o644)
    try write(Data("oracle profile\n".utf8), to: "\(base)/material/release.p7b", mode: 0o644)
    let measure = { (name: String, role: String, executable: Bool, owner: Bool) in
      try OpenHarmonySigningPresetStore.measure(
        URL(filePath: "\(base)/\(name)"), role: role, mustBeExecutable: executable,
        ownerPrivate: owner)
    }
    let receipt = OpenHarmonySigningPresetReceipt(
      schemaVersion: "arkdeck-openharmony-signing/v1", installedAtUTC: Self.timestamp,
      presetID: OpenHarmonyLocalSigning.defaultPresetID, projectRef: Self.project,
      javaExecutable: try measure("tools/java", "java", true, false),
      signerJAR: try measure("material/hap-sign-tool.jar", "signer JAR", false, false),
      keystore: try measure("material/release.p12", "keystore", false, true),
      appCertificate: try measure("material/release.cer", "app certificate", false, false),
      signedProfile: try measure("material/release.p7b", "signed profile", false, false),
      keyAlias: "oracle-key", signingAlgorithm: "SHA256withECDSA",
      keystorePasswordAccount: "openharmony-release@1|keystore",
      keyPasswordAccount: "openharmony-release@1|key",
      secretEnvelopeAccount: Self.envelopeAccount,
      keychainAccessSchema: "data-protection-access-group-v1")
    let presetRoot = "\(base)/preset"
    try FileManager.default.createDirectory(
      atPath: presetRoot, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    try write(try encoder.encode(receipt), to: "\(presetRoot)/preset-v1.json", mode: 0o600)
    try secrets.set(
      try JSONEncoder().encode(
        OracleSecretEnvelope(
          schemaVersion: "arkdeck-openharmony-signing-secret/v1",
          keystorePassword: Data(Self.keystoreSecret.utf8),
          keyPassword: Data(Self.keySecret.utf8))),
      account: Self.envelopeAccount)
    return OpenHarmonySigningPresetStore(
      rootURL: URL(filePath: presetRoot, directoryHint: .isDirectory), secrets: secrets,
      nowUTC: { Self.timestamp })
  }

  private func stack(in root: URL) throws -> Stack {
    self.root = root
    try? FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let base = Self.foundationRoot
    try write(Data("struct Index {}\n".utf8), to: "\(base)/source/entry/src/main/ets/pages/Index.ets", mode: 0o644)
    let secrets = OracleSigningSecrets()
    let store = try installPreset(secrets: secrets)
    // The workspace preset owns the one credential, as `workspace preset
    // register --kind signing` leaves it.
    let owner = OpenHarmonySigningCredentialOwner(store: store)
    let credential = try owner.current().credentialRef
    try owner.acquire(credential, owner: Self.signingPreset)
    let tool = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/grep")
    let preset = { (id: String) in
      try WorkspaceCommandPreset(
        presetID: id, executable: tool, fixedArguments: [], timeoutSeconds: 10)
    }
    let signing = try WorkspaceSigningPreset(
      presetID: Self.signingPreset, credentialRef: credential, timeoutSeconds: 600)
    let profile = try WorkspaceProjectProfile(
      profileID: Self.profileID, projectRef: Self.project,
      projectRoot: "\(base)/source", allowedFileGlobs: ["entry/src/main/ets/**"],
      inspectionPreset: try preset("inspect"), patchPreset: try preset("patch"),
      buildPresets: [:], testPresets: [:], symbolPresets: [:],
      signingPresets: [signing.presetID: signing],
      allowsLegacySigningPresetFallback: false)
    let attempts = try OpenHarmonySigningAttemptStore(
      rootURL: URL(filePath: "\(base)/signing-attempts", directoryHint: .isDirectory))
    let provider = WorkspaceOperationsProvider(
      profile: profile,
      attemptStore: try WorkspacePatchAttemptStore(
        rootURL: root.appending(path: "workspace-patch-attempts", directoryHint: .isDirectory)),
      signingPresetStore: store, signingCredentialOwner: owner,
      signingAttemptStore: attempts, nowUTC: { Self.timestamp })
    let dispatcher = OpenHarmonySigningWorkspaceDispatcher(
      fallback: DescriptorBoundProcessDispatcher(
        resolver: WorkspaceActionExecutableResolver(profile: profile)),
      presetStore: store)
    let capabilities = try RuntimeCapabilityStore(
      directoryURL: root.appending(path: "capabilities", directoryHint: .isDirectory))
    let artifacts = try RuntimeArtifactStore(
      rootURL: root.appending(path: "artifacts", directoryHint: .isDirectory),
      nowUTC: { Self.timestamp })
    let providers = DeviceProviderRegistry(providers: [provider])
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: root.appending(path: "engine", directoryHint: .isDirectory)),
      providers: providers,
      dispatcher: RuntimeProcessDispatcherRouter(
        hdc: dispatcher, rockchip: dispatcher, workspace: dispatcher),
      capabilityStore: capabilities, artifactStore: artifacts,
      workspaceProjectStore: nil, nowUTC: { Self.timestamp })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities,
      providerIDs: providers.registeredProviderIDs, nowUTC: { Self.timestamp },
      targetStore: nil, bootstrap: nil, targetObservations: nil,
      hdcRuntimeDiagnostics: nil, artifactStore: artifacts, historyFilterStore: nil,
      flashBundleImportDirectory: root.appending(
        path: "flash-bundle-imports", directoryHint: .isDirectory),
      flashBundleImportPolicy: .production,
      flashPrerequisiteObserver: nil, flashLanePlanPreviewer: nil,
      rockchipBootloaderStatusObserver: nil, rockchipDeviceAccessObserver: nil,
      rockchipLoaderBindingCoordinator: nil, rockchipPostFlashAliasReconciler: nil,
      workspaceProjects: [], methodObserver: nil)
    return Stack(handler: handler, artifacts: artifacts)
  }

  /// Publishes one unsigned HAP under the input Job, bound to the host target
  /// the signing Jobs name, and returns its lease.
  private func publishInput(
    _ store: RuntimeArtifactStore, name: String, contents: Data
  ) async throws -> String {
    let staging = "\(Self.foundationRoot)/inputs/\(name)"
    try write(contents, to: staging, mode: 0o600)
    let metadata = try await store.publishFile(
      RuntimeArtifactFilePublicationRequest(
        jobID: Self.inputJob, sessionID: "session-input-hap", stepID: "import-hap",
        name: name, mediaType: "application/vnd.openharmony.hap", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "artifact.import-hap", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "workspace-host", bindingRevision: nil, stableIdentitySHA256: nil),
        sourceFileURL: URL(filePath: staging), expectedByteCount: contents.count,
        expectedSHA256: SHA256Hex.string(of: contents)))
    return try await store.leaseReference(jobID: metadata.jobID, artifactID: metadata.artifactID)
  }

  /// A ZIP-headed unsigned HAP the stand-in signer handles in `mode`.
  private static func hap(_ mode: String) -> Data {
    Data([0x50, 0x4b, 0x03, 0x04]) + Data("\nmode=\(mode)\nunsigned-body\n".utf8)
  }

  private static func requestJSON(
    _ label: String, preset: String = WorkspaceSignOracleContractTests.signingPreset,
    lease: String
  ) throws -> [String: JSONValue] {
    let document = try RuntimeOperationRequest(
      requestID: "request-\(label)", idempotencyKey: "idempotency-\(label)",
      target: DurableTargetReference(targetID: "workspace-host"),
      operation: RuntimeOperationReference(id: "workspace.sign-openharmony-hap", version: 1),
      inputs: [
        "projectRef": .string(Self.project), "signingPresetRef": .string(preset),
        "unsignedHapArtifactLease": .string(lease),
      ])
    return [
      "requestJson": .string(
        String(decoding: try CanonicalJSONEncoders.canonical().encode(document), as: UTF8.self))
    ]
  }

  private final class Frames: @unchecked Sendable {
    var lines: [Data] = []
  }

  private func send(
    _ handler: RuntimeControlPlaneHandler, _ frames: Frames, _ method: String,
    _ params: [String: JSONValue]
  ) async throws -> AgentWireProtocol.Response {
    let request = AgentWireProtocol.Request(
      id: UUID().uuidString, method: method, params: params)
    let response = await handler.handleFrame(try JSONEncoder().encode(request))
    frames.lines.append(
      try ControlFrameRecord(request: request, response: response).encodedLine())
    return response
  }

  private static func jobID(_ response: AgentWireProtocol.Response) throws -> String {
    guard case .object(let accepted)? = response.result,
      case .string(let jobID)? = accepted["jobId"]
    else {
      throw NSError(
        domain: "WorkspaceSignOracle", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "no Job: \(String(describing: response.error))"])
    }
    return jobID
  }

  private static func state(_ response: AgentWireProtocol.Response) -> JSONValue? {
    guard case .object(let fields)? = response.result else { return nil }
    return fields["state"]
  }

  /// Every regular file below `root`.
  private static func regularFiles(below root: URL) -> [URL] {
    let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.isRegularFileKey])
    var files: [URL] = []
    while let url = enumerator?.nextObject() as? URL {
      if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        files.append(url)
      }
    }
    return files
  }

  // MARK: The recording

  func testTheControlPlaneSignsWithARegisteredPresetAsRecorded() async throws {
    let root = Self.oracleRoot
    let stack = try stack(in: root)
    let frames = Frames()
    let good = try await publishInput(stack.artifacts, name: "good.hap", contents: Self.hap("success"))
    let rejected = try await publishInput(
      stack.artifacts, name: "rejected.hap", contents: Self.hap("sign-failure"))
    let echo = try await publishInput(
      stack.artifacts, name: "echo.hap", contents: Self.hap("echo-secret"))
    let verifyOnce = try await publishInput(
      stack.artifacts, name: "verify-once.hap",
      contents: Self.hap("verify-once:\(Self.foundationRoot)/verify-once.marker"))
    let notZip = try await publishInput(
      stack.artifacts, name: "not-zip.hap", contents: Data("mode=success\nnot a zip\n".utf8))

    // 1. A preset the project has not registered: refused before admission.
    let unregistered = try await send(
      stack.handler, frames, "job.plan",
      try Self.requestJSON("unregistered", preset: "preset-unregistered", lease: good))
    XCTAssertFalse(unregistered.ok)
    // 2. An input that is not a bounded ZIP container: refused before
    // admission.
    let wrong = try await send(
      stack.handler, frames, "job.plan", try Self.requestJSON("not-zip", lease: notZip))
    XCTAssertFalse(wrong.ok)

    // 3. Signed, verified, recorded and published with its source's binding.
    let sign = try Self.requestJSON("sign", lease: good)
    let planned = try await send(stack.handler, frames, "job.plan", sign)
    XCTAssertTrue(planned.ok, "sign plan: \(String(describing: planned.error))")
    let signJob = try Self.jobID(try await send(stack.handler, frames, "job.submit", sign))
    let signed = try await send(stack.handler, frames, "job.run", ["jobId": .string(signJob)])
    XCTAssertEqual(Self.state(signed), .string("succeeded"))
    _ = try await send(stack.handler, frames, "job.result", ["jobId": .string(signJob)])

    // 4. The signer rejects the password: parked, then reconciled as not
    // executed, since it wrote nothing.
    let rejectedJob = try Self.jobID(
      try await send(
        stack.handler, frames, "job.submit", try Self.requestJSON("rejected", lease: rejected)))
    let parkedRejected = try await send(
      stack.handler, frames, "job.run", ["jobId": .string(rejectedJob)])
    XCTAssertEqual(Self.state(parkedRejected), .string("waitingForRecovery"))
    let rejectedRecord = try Data(
      contentsOf: root.appending(path: "engine/jobs/\(rejectedJob)/job-record.json"))
    let settled = try await send(
      stack.handler, frames, "job.reconcile", ["jobId": .string(rejectedJob)])
    XCTAssertEqual(Self.state(settled), .string("failed"))
    _ = try await send(stack.handler, frames, "job.result", ["jobId": .string(rejectedJob)])

    // 5. The signer echoes a password: a privacy failure, parked, then
    // reconciled as not executed.
    let echoJob = try Self.jobID(
      try await send(
        stack.handler, frames, "job.submit", try Self.requestJSON("echo", lease: echo)))
    let parkedEcho = try await send(
      stack.handler, frames, "job.run", ["jobId": .string(echoJob)])
    XCTAssertEqual(Self.state(parkedEcho), .string("waitingForRecovery"))
    _ = try await send(stack.handler, frames, "job.reconcile", ["jobId": .string(echoJob)])
    _ = try await send(stack.handler, frames, "job.result", ["jobId": .string(echoJob)])

    // 6. Verification fails once after the signer ran: parked with the
    // product on disk, reconciled by verifying it again — never by signing
    // again — then resumed to success.
    let onceJob = try Self.jobID(
      try await send(
        stack.handler, frames, "job.submit", try Self.requestJSON("verify-once", lease: verifyOnce)))
    let parkedOnce = try await send(
      stack.handler, frames, "job.run", ["jobId": .string(onceJob)])
    XCTAssertEqual(Self.state(parkedOnce), .string("waitingForRecovery"))
    let onceRecord = try Data(
      contentsOf: root.appending(path: "engine/jobs/\(onceJob)/job-record.json"))
    let recovered = try await send(
      stack.handler, frames, "job.reconcile", ["jobId": .string(onceJob)])
    XCTAssertEqual(Self.state(recovered), .string("resumeAtConfirmedSafeBoundary"))
    let resumed = try await send(stack.handler, frames, "job.run", ["jobId": .string(onceJob)])
    XCTAssertEqual(Self.state(resumed), .string("succeeded"))
    _ = try await send(stack.handler, frames, "job.result", ["jobId": .string(onceJob)])

    // No password reached any file the Runtime keeps.
    for url in Self.regularFiles(below: root) {
      let bytes = (try? Data(contentsOf: url)) ?? Data()
      XCTAssertNil(bytes.range(of: Data(Self.keystoreSecret.utf8)), url.path)
      XCTAssertNil(bytes.range(of: Data(Self.keySecret.utf8)), url.path)
    }
    // Every attempt directory is gone once its Job is terminal.
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: "\(Self.foundationRoot)/signing-attempts"),
      [])

    var durable: [String: Data] = [
      "frames.jsonl": frames.lines.reduce(into: Data()) { $0 += $1 + Data("\n".utf8) },
      "rejected-parked-record.json": rejectedRecord,
      "verify-once-parked-record.json": onceRecord,
      "credential-owner-v1.json": try Data(
        contentsOf: URL(filePath: "\(Self.foundationRoot)/preset/credential-owner-v1.json")),
      "preset-v1.json": try Data(
        contentsOf: URL(filePath: "\(Self.foundationRoot)/preset/preset-v1.json")),
    ]
    // The published products' bytes; their metadata carries observation
    // windows read off the host clock, so only the payloads are kept.
    for job in [signJob, onceJob] {
      let directory = root.appending(path: "artifacts/\(job)", directoryHint: .isDirectory)
      for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
      where name.hasPrefix("ART-") {
        durable["artifacts/\(job)/\(name)"] = try Data(
          contentsOf: directory.appending(path: name))
      }
    }
    let inputs = root.appending(path: "artifacts/\(Self.inputJob)", directoryHint: .isDirectory)
    for name in try FileManager.default.contentsOfDirectory(atPath: inputs.path).sorted()
    where !name.hasPrefix(".") {
      durable["artifacts/\(Self.inputJob)/\(name)"] = try Data(
        contentsOf: inputs.appending(path: name))
    }

    if let output = ProcessInfo.processInfo.environment[Self.recordVariable] {
      let directory = URL(filePath: output, directoryHint: .isDirectory)
      for (name, bytes) in durable {
        let url = directory.appending(path: name)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
      }
      return
    }

    for (name, bytes) in durable.sorted(by: { $0.key < $1.key }) {
      let recorded = try Data(contentsOf: Self.oracle.appending(path: name))
      if name == "frames.jsonl" {
        let expected = recorded.split(separator: UInt8(ascii: "\n"))
        let actual = bytes.split(separator: UInt8(ascii: "\n"))
        XCTAssertEqual(expected.count, actual.count, "frame count")
        for (index, (lhs, rhs)) in zip(expected, actual).enumerated() {
          XCTAssertEqual(
            String(decoding: lhs, as: UTF8.self), String(decoding: rhs, as: UTF8.self),
            "frame \(index)")
        }
      } else {
        XCTAssertEqual(recorded, bytes, name)
      }
    }
  }
}

// Shared Swift oracle for the Rust `deploy.native-library.app-owned@1` engine
// (CHG-2026-074, TASK-XPA-014).

import Darwin
import XCTest
@testable import ArkDeckClientKit

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift `deploy.native-library.app-owned@1` with the runbook's GJ-3 input
/// (§4: restart the ability, verify hash, process and loader maps, roll back
/// automatically) over the shared fake HDC (`HDCOracleFake`), the operation
/// of Golden Journey 3 and the second M2 oracle. One device is adopted and
/// the synthetic signed arm64 ELF of `NativeLibraryTestFixture` is published
/// under one input Job as an Artifact lease; each case then plans a request
/// for the device, and a case with a mode also admits it under the runtime's
/// default policy capability and runs its Job while the fake answers in that
/// mode, so the Jobs run in order over one store: one stages, backs up,
/// publishes, restarts, verifies the loaded library and cleans up, one finds
/// the loader never mapped the published library and rolls back to the
/// backup, one finds no app-owned library directory and fails before any
/// mutation, one replaces a library the platform never attested, and one
/// cannot remove its staging and backup paths and records the residue. The
/// other cases are refused before admission: a stale binding revision, a
/// lease the store does not hold, an ELF of another ABI than the request
/// names and a logical name the Catalog rejects. A second run of the
/// deployed Job is refused, every Job's result, evidence and Artifact list
/// are read, the cleanup debt is listed, continued and listed again, and the
/// capability store is read last. What the oracle keeps and how it is
/// composed is `HDCOracleHarness`. The bundled code-sign helper's host path
/// reaches the materialized plan and so its digest, and this machine's build
/// decides where the bundle is; the oracle therefore keeps a copy of the
/// helper at a fixed path under the root and composes the provider over it,
/// so that the plan digest, the automatic capability and every record
/// derived from them are the same on every machine.
///
/// Record a new oracle with
/// `ARKDECK_RUST_NATIVE_LIBRARY_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class NativeLibraryOracleContractTests: XCTestCase {
  private struct Case {
    let name: String
    /// The fake's mode while this case's Job runs; a case without one only
    /// plans its request.
    var mode: String?
    /// The state the run ends in.
    var ends: String?
    /// The binding revision the request expects.
    var bindingRevision = 1
    /// A lease other than the published library's.
    var lease: String?
    var abi = "arm64-v8a"
    var logicalName = "libexample.so"
  }

  private static let cases: [Case] = [
    Case(name: "deployed", mode: "normal", ends: "succeeded"),
    Case(name: "loaderFailure", mode: "loaderFailure", ends: "failed"),
    Case(name: "targetAbsent", mode: "targetAbsent", ends: "failed"),
    Case(name: "unattested", mode: "unattested", ends: "succeeded"),
    Case(name: "cleanupFailure", mode: "cleanupFailure", ends: "succeeded"),
    Case(name: "staleBinding", bindingRevision: 2),
    Case(
      name: "unknownLease",
      lease: "lease-v1:job-input-native-library:ART-00000000000000000000000000000000"),
    Case(name: "otherABI", abi: "armeabi-v7a"),
    Case(name: "badLogicalName", logicalName: "example.so"),
  ]

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/deploy-native-library", directoryHint: .isDirectory)
  private static let settings = HDCOracleHarness.Settings(
    root: HDCOracleFake.root,
    nowUTC: "2026-09-14T00:00:00Z",
    nowPreciseUTC: "2026-09-14T00:00:00.000Z",
    home: "/private/tmp/arkdeck-hdc-oracle/home",
    quotaBytes: 8 * 1024 * 1024 * 1024)
  private static let connectKey = String(repeating: "a", count: 32)
  private static let bundleName = "com.example.demo"
  private static let library = NativeLibraryTestFixture.arm64ELF()
  /// The attestation digest the fake's helper reports for the library the
  /// deployment replaces, and so for its backup and for the replacement.
  private static let replacedDigest = String(repeating: "0123456789abcdef", count: 4)
  /// Where the oracle keeps its copy of the bundled code-sign helper.
  private static let codeSignHelperPath = HDCOracleFake.root.appending(
    path: "host/arkdeck-code-sign-enable")

  /// The fake keeps the device's state between calls in marker files beside
  /// its log: whether the ability runs and whether the new library is
  /// published (cleared before every Job), and which provider-owned remote
  /// paths exist (each Job's own, kept, so that the residue a Job leaves is
  /// what its cleanup debt continuation finds).
  private static let applicationState = ["device-running", "device-published"]

  /// What `deploy.native-library.app-owned@1` asks with the GJ-3 input,
  /// answered as `NativeLibraryDeploymentContractTests`' scripted dispatcher
  /// answers it — the app-owned files have the identity `-rw------- 20010050
  /// 20010050`, the target hashes to the replaced library until the helper
  /// publishes and to the leased ELF after, the helper attests both with the
  /// replaced library's digest, the ability answers `pidof` with 4321 while
  /// it runs, and the loader maps the library — by mode: `loaderFailure`
  /// finds no map of the published library, `targetAbsent` has no app-owned
  /// directory, `unattested` has a helper that finds no fs-verity on the
  /// replaced library and publishes without enabling any, and
  /// `cleanupFailure` removes nothing.
  private static let answers = #"""
    # deploy.native-library.app-owned@1 answers of the scripted dispatcher of NativeLibraryDeploymentContractTests, by mode.
    key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    bundle=com.example.demo
    directory=/data/app/el1/bundle/public/$bundle/libs/arm
    target=$directory/libexample.so
    loader=/data/storage/el1/bundle/libs/arm/libexample.so
    replaced=\#(replacedDigest)
    library=\#(NativeLibraryTestFixture.sha256(library))
    helper=\#(codeSignHelperDigest)
    running=$root/device-running
    published=$root/device-published
    marker() { printf '%s/device-path-%s' "$root" "$(printf '%s' "$1" | tr / _)"; }
    listed() {
      case "$1" in
      */arkdeck-native/*/*)
        printf '%s 1 20010050 20010050 256 2026-09-14 00:00 %s\n' -rw------- "$1" ;;
      "$directory"|*/libs|*/arkdeck-native/*)
        printf '%s 2 20010050 20010050 3452 2026-09-14 00:00 %s\n' drwx------ "$1" ;;
      *)
        printf '%s 1 20010050 20010050 256 2026-09-14 00:00 %s\n' -rw------- "$1" ;;
      esac
    }
    present() {
      case "$1" in
      "$directory"|"$target"|*/libs) [ "$mode" != targetAbsent ] ;;
      *) [ -e "$(marker "$1")" ] ;;
      esac
    }
    case "$*" in
    "-t $key shell mkdir -p "*)
      : > "$(marker "$6")" ;;
    "-t $key file send "*)
      : > "$(marker "$6")"
      printf 'FileTransfer finish\n' ;;
    "-t $key shell chmod 700 "*)
      ;;
    "-t $key shell sha256sum "*)
      if ! present "$5"; then
        printf 'sha256sum: %s: No such file or directory\n' "$5"
        exit 0
      fi
      case "$5" in
      *.staging) printf '%s  %s\n' "$library" "$5" ;;
      */arkdeck-code-sign-enable) printf '%s  %s\n' "$helper" "$5" ;;
      "$target") if [ -e "$published" ]; then printf '%s  %s\n' "$library" "$5"; else printf '%s  %s\n' "$replaced" "$5"; fi ;;
      *) printf '%s  %s\n' "$replaced" "$5" ;;
      esac ;;
    "-t $key shell ls -la "*)
      if present "$6"; then printf 'total 4\n'; listed "$6/arm"; else printf 'ls: %s: No such file or directory\n' "$6"; fi ;;
    "-t $key shell ls -l "*|"-t $key shell ls -ld "*|"-t $key shell ls -ln "*)
      if present "$6"; then listed "$6"; else printf 'ls: %s: No such file or directory\n' "$6"; fi ;;
    "-t $key shell rm -f "*)
      [ "$mode" = cleanupFailure ] || rm -f "$(marker "$6")" ;;
    "-t $key shell rmdir "*)
      [ "$mode" = cleanupFailure ] || rm -f "$(marker "$5")" ;;
    "-t $key shell ln "*)
      : > "$(marker "$6")" ;;
    "-t $key shell mv -f "*)
      rm -f "$(marker "$6")" "$published" ;;
    "-t $key shell "*"/arkdeck-code-sign-enable verify "*)
      if [ "$mode" = unattested ]; then
        printf 'ARKDECK_CODE_SIGN_ERROR stage=verify code=30 errno=61\n'
      else
        printf 'ARKDECK_CODE_SIGN_VERIFIED sha256:%s\n' "$replaced"
      fi ;;
    "-t $key shell "*"/arkdeck-code-sign-enable publish "*)
      : > "$published"
      if [ "$mode" = unattested ]; then
        printf 'ARKDECK_CODE_SIGN_PUBLISHED_UNATTESTED replaced-file-had-none\n'
      else
        printf 'ARKDECK_CODE_SIGN_PUBLISHED sha256:%s\n' "$replaced"
      fi ;;
    "-t $key shell aa force-stop $bundle")
      rm -f "$running" ;;
    "-t $key shell aa start -b $bundle -a EntryAbility")
      : > "$running" ;;
    "-t $key shell pidof $bundle")
      [ -e "$running" ] || exit 1
      printf '4321\n' ;;
    "-t $key shell sleep 2")
      ;;
    "-t $key shell grep -F $loader /proc/*/maps")
      if [ "$mode" = loaderFailure ] && [ -e "$published" ]; then exit 1; fi
      printf '/proc/4321/maps:7f000 %s\n' "$loader" ;;
    *)
      printf 'unregistered fixture output\n' >&2
      exit 23 ;;
    esac

    """#

  /// The bundled arm64 code-sign helper the provider sends beside the
  /// library: its digest is the fake's answer to `sha256sum`.
  private static let bundledCodeSignHelper = try! HDCNativeCodeSignHelperArtifact.bundled()
  private static var codeSignHelperDigest: String { bundledCodeSignHelper.facts.sha256 }

  /// The bundled helper's bytes at the oracle's fixed path, verified again as
  /// the provider would verify the bundle.
  private static func installCodeSignHelper() throws -> HDCNativeCodeSignHelperArtifact {
    let manager = FileManager.default
    try manager.createDirectory(
      at: codeSignHelperPath.deletingLastPathComponent(), withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    try Data(contentsOf: bundledCodeSignHelper.fileURL).write(to: codeSignHelperPath)
    guard chmod(codeSignHelperPath.path, 0o700) == 0 else { throw POSIXError(.EPERM) }
    let facts = try NativeLibraryArtifactValidator.validate(
      try Data(contentsOf: codeSignHelperPath), expectedABI: .arm64)
    XCTAssertEqual(facts.sha256, bundledCodeSignHelper.facts.sha256)
    return HDCNativeCodeSignHelperArtifact(
      fileURL: codeSignHelperPath,
      facts: HDCNativeCodeSignHelperFacts(
        abi: facts.abi, buildID: facts.buildID, sha256: facts.sha256, byteCount: facts.byteCount))
  }

  func testSwiftDeploysANativeLibraryOnTheSharedFakeDevice() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_NATIVE_LIBRARY_RECORD",
      oracle: Self.oracle)
  }

  private static func requestJSON(_ item: Case, target: String, lease: String) throws -> String {
    let document = JSONValue.object([
      "documentType": .string("runtime-operation-request"),
      "schemaVersion": .string("1.0.0"),
      "requestId": .string("req-native-\(item.name)"),
      "idempotencyKey": .string("idem-native-\(item.name)"),
      "target": .object([
        "targetId": .string(target),
        "expectedBindingRevision": .integer(Int64(item.bindingRevision)),
      ]),
      "operation": .object([
        "id": .string("deploy.native-library.app-owned"), "version": .integer(1),
      ]),
      "inputs": .object([
        "libraryArtifactLease": .string(item.lease ?? lease),
        "targetBundle": .string(bundleName),
        "libraryLogicalName": .string(item.logicalName),
        "expectedABI": .string(item.abi),
        "restartProfile": .string("restartAbility"),
        "verificationProfile": .string("hashProcessAndMaps"),
        "rollbackPolicy": .string("autoRollback"),
      ]),
    ])
    return String(decoding: try CanonicalJSONEncoders.canonical().encode(document), as: UTF8.self)
  }

  private static func send(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    try await HDCOracleHarness.send(handler, method, params, frameID: "native-library-oracle")
  }

  private static func resetApplication() {
    for name in applicationState {
      try? FileManager.default.removeItem(at: HDCOracleFake.root.appending(path: name))
    }
  }

  private func oracleFiles() async throws -> [String: Data] {
    let manager = FileManager.default
    let hdc = try HDCOracleFake.install(answers: Self.answers)
    defer { try? manager.removeItem(at: Self.settings.root) }
    let targets = Self.settings.root.appending(path: "targets-state", directoryHint: .isDirectory)
    let targetStore = try RuntimeTargetStore(directoryURL: targets)
    let adopted = try targetStore.adopt(
      stableIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(
        connectKey: Self.connectKey),
      connectKey: Self.connectKey, toolVersion: "3.2.0d", nowUTC: Self.settings.nowUTC
    ).record
    let codeSignHelper = try Self.installCodeSignHelper()
    let composition = try HDCOracleHarness.composition(
      hdc: hdc, targetStore: targetStore, targets: targets, settings: Self.settings,
      nativeCodeSignHelper: codeSignHelper)
    let published = try await composition.artifactStore.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-input-native-library", sessionID: "session-input-native-library",
        stepID: "publish-native-library", name: "libexample.so",
        mediaType: "application/x-elf", privacy: .standard,
        retentionClass: .pinnedUntilVerified, sourceOperation: "artifact.import-native-library",
        providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: adopted.targetID, bindingRevision: adopted.bindingRevision,
          stableIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(
            connectKey: Self.connectKey)),
        contents: Self.library))
    let lease = try await composition.artifactStore.leaseReference(
      jobID: published.jobID, artifactID: published.artifactID)

    var exchanges: [JSONValue] = []
    var jobs: [(name: String, job: String)] = []
    for item in Self.cases {
      let params: [String: JSONValue] = [
        "requestJson": .string(try Self.requestJSON(item, target: adopted.targetID, lease: lease))
      ]
      let plan = try await Self.send(composition.handler, "job.plan", params)
      exchanges.append(HDCOracleHarness.exchange("\(item.name).plan", "job.plan", params, plan))
      guard let mode = item.mode else { continue }
      let submitted = try await Self.send(composition.handler, "job.submit", params)
      exchanges.append(
        HDCOracleHarness.exchange("\(item.name).submit", "job.submit", params, submitted))
      guard case .object(let fields) = submitted, case .object(let result)? = fields["result"],
        case .string(let job)? = result["jobId"]
      else {
        XCTFail("\(item.name): the admission was refused: \(submitted)")
        continue
      }
      jobs.append((item.name, job))
      Self.resetApplication()
      try HDCOracleFake.setMode(mode)
      let run = try await Self.send(composition.handler, "job.run", ["jobId": .string(job)])
      exchanges.append(
        HDCOracleHarness.exchange(
          "\(item.name).run", "job.run", ["jobId": .string(job)], run, mode: mode))
      guard case .object(let answer) = run, case .object(let status)? = answer["result"] else {
        XCTFail("\(item.name): the run was refused: \(run)")
        continue
      }
      XCTAssertEqual(status["state"], item.ends.map(JSONValue.string), item.name)
    }
    let deployed = ["jobId": JSONValue.string(jobs[0].job)]
    exchanges.append(
      HDCOracleHarness.exchange(
        "deployed.rerun", "job.run", deployed,
        try await Self.send(composition.handler, "job.run", deployed)))
    for (name, job) in jobs {
      let reads: [(String, String, [String: JSONValue])] = [
        ("result", "job.result", ["jobId": .string(job)]),
        ("evidence", "job.evidence", ["jobId": .string(job)]),
        (
          "artifacts", "artifact.list",
          [
            "owner": .object(["kind": .string("job"), "id": .string(job)]),
            "pageSize": .integer(1000),
          ]
        ),
      ]
      for (read, method, params) in reads {
        let answer = try await Self.send(composition.handler, method, params)
        exchanges.append(HDCOracleHarness.exchange("\(name).\(read)", method, params, answer))
      }
    }
    // The residue `cleanupFailure` left: its staging path, continued while
    // the fake answers normally, so it is found present, removed and read
    // absent.
    guard let cleanupFailure = jobs.first(where: { $0.name == "cleanupFailure" })?.job else {
      throw CocoaError(.coderInvalidValue)
    }
    try HDCOracleFake.setMode("normal")
    let staging =
      "/data/app/el2/100/base/\(Self.bundleName)/haps/entry/files/arkdeck-native/"
      + "\(cleanupFailure)/libexample.so.staging"
    let continuations: [(String, [String: JSONValue])] = [
      ("debt.list", [:]),
      ("debt.continuePath", ["jobId": .string(cleanupFailure), "remotePath": .string(staging)]),
      ("debt.listAfter", [:]),
    ]
    for (name, params) in continuations {
      let method = params.isEmpty ? "cleanupDebt.list" : "cleanupDebt.continue"
      let answer = try await Self.send(composition.handler, method, params)
      exchanges.append(HDCOracleHarness.exchange(name, method, params, answer, mode: "normal"))
    }
    let capabilities = try await Self.send(composition.handler, "capability.list", [:])
    exchanges.append(
      HDCOracleHarness.exchange("capabilities.list", "capability.list", [:], capabilities))
    guard case .object(let listed) = capabilities, case .array(let items)? = listed["result"]
    else { throw CocoaError(.coderInvalidValue) }
    for (index, item) in items.enumerated() {
      guard case .object(let fields) = item, case .string(let id)? = fields["capabilityId"]
      else { throw CocoaError(.coderInvalidValue) }
      let params: [String: JSONValue] = ["capabilityId": .string(id)]
      exchanges.append(
        HDCOracleHarness.exchange(
          "capabilities.inspect\(index)", "capability.inspect", params,
          try await Self.send(composition.handler, "capability.inspect", params)))
    }
    return try HDCOracleHarness.files(
      composition, target: adopted,
      cases: .object([
        "target": .object([
          "targetId": .string(adopted.targetID),
          "bindingRevision": .integer(Int64(adopted.bindingRevision)),
          "connectKey": .string(adopted.connectKey),
          "toolVersion": .string(adopted.toolVersion),
        ]),
        "lease": .string(lease),
        "library": .object([
          "sha256": .string(NativeLibraryTestFixture.sha256(Self.library)),
          "byteCount": .integer(Int64(Self.library.count)),
          "buildId": .string(NativeLibraryTestFixture.buildID),
        ]),
        "codeSignHelper": .object([
          "sha256": .string(codeSignHelper.facts.sha256),
          "byteCount": .integer(Int64(codeSignHelper.facts.byteCount)),
          "buildId": .string(codeSignHelper.facts.buildID),
          "path": .string(codeSignHelper.fileURL.path),
        ]),
        "jobs": .object(
          Dictionary(uniqueKeysWithValues: jobs.map { ($0.name, JSONValue.string($0.job)) })),
        "exchanges": .array(exchanges),
      ]),
      answers: Self.answers,
      producer: "NativeLibraryOracleContractTests.testSwiftDeploysANativeLibraryOnTheSharedFakeDevice",
      settings: Self.settings)
  }
}

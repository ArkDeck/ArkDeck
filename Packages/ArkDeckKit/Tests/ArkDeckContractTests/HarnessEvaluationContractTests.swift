// Evaluation contract tests (CHG-2026-054, TASK-HTP-002).
//
// Registered acceptance: HTP-AC-5 (only the evaluator may declare success),
// HTP-AC-6 (INCONCLUSIVE is never success), HTP-AC-7 (observations come from
// bytes the harness verified, and absent/corrupt evidence fails closed).
//
// The hilog fixtures are host-authored in the documented OpenHarmony
// cppcrash shape, and the run record says so: validating the scan against
// bytes a real device produced belongs to the hardware task. What is proven
// here is everything that does not need a device - verification before
// measurement, the sample gate, and who is allowed to say "fixed".

import CryptoKit
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckHarness
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func applicationLivenessJSON(
  jobID: String,
  state: String,
  reasonCode: String,
  processState: String,
  pidObserved: Bool,
  bindingRevision: Int = 7,
  deployedDigest: String? = nil
) -> String {
  let digest = deployedDigest.map { #", "deployedArtifactDigest":"\#($0)""# } ?? ""
  return #"{"documentType":"arkdeck-application-liveness","schemaVersion":"1.0.0","applicationRef":"\#(String(repeating: "a", count: 64))","state":"\#(state)","reasonCode":"\#(reasonCode)","abilityState":"UNKNOWN","processState":"\#(processState)","pidObserved":\#(pidObserved),"targetBindingRevision":\#(bindingRevision)\#(digest),"sourceRuntimeJobId":"\#(jobID)","sourceOperationRef":"capture.diagnostics@1","observationWindow":{"startedAtUtc":"2026-08-01T00:00:00Z","endedAtUtc":"2026-08-01T00:00:00Z"},"observedAtUtc":"2026-08-01T00:00:00Z"}"#
}

private enum HilogFixture {
  /// One matching fault (the declared WaterFlow signature) and one unrelated
  /// fatal, so "matching" and "new fatal" cannot be conflated.
  static let twoFaults = """
    07-30 12:00:01.100  1201  1201 I A03d00/Ace: WaterFlow layout pass begin
    07-30 12:00:02.310  1201  1201 E C03f00/Cppcrash: Pid:1201 Uid:20010043
    Process name:com.example.waterflow
    Reason:Signal:SIGABRT(SI_TKILL)@0x0000000000000004
    Fault thread info:
    Tid:1201, Name:e.example.water
    #00 pc 00000000000a1b2c /system/lib64/libc.so(abort+164)
    #01 pc 00000000000d4e5f /system/lib64/libace_compatible.z.so(OHOS::Ace::NG::WaterFlowPattern::RecoverBack()+72)
    #02 pc 00000000000d9a11 /system/lib64/libace_compatible.z.so(OHOS::Ace::NG::ScrollablePattern::OnScrollEnd()+40)
    07-30 12:00:05.900  1330  1330 E C03f00/Cppcrash: Pid:1330 Uid:20010044
    Process name:com.example.other
    Reason:Signal:SIGSEGV(SEGV_MAPERR)@0x0000000000000010
    Fault thread info:
    #00 pc 0000000000012345 /system/lib64/libunrelated.z.so(OtherModule::Boom()+16)
    """

  static let clean = """
    07-30 12:10:01.100  1401  1401 I A03d00/Ace: WaterFlow layout pass begin
    07-30 12:10:01.480  1401  1401 I A03d00/Ace: WaterFlow reached end of content
    07-30 12:10:02.010  1401  1401 I A03d00/Ace: scroll settled, no recovery needed
    """

  static let declaredSignature = "SIGABRT+WaterFlowPattern::RecoverBack"
}

/// Faultlogger bytes (CHG-2026-055, TASK-HFA-001).
///
/// Provenance is marked per fixture and matters: TASK-HTP-002 shipped
/// hand-written hilog fixtures in the documented shape, and a real device
/// then disproved the shape they encoded. So the index and the jscrash body
/// below are **real DAYU200 bytes** (OpenHarmony 3.2 / Build 7.0.0.36,
/// read read-only on 2026-07-31; device fingerprint and the process unique
/// id masked, and the entry's trailing `HiLog:` section truncated because
/// it duplicates `hilog.txt`). The cppcrash and appfreeze bodies are
/// **hand-written to the documented shape** - the device carries only the
/// one jscrash entry, so nothing here may claim device coverage for them.
private enum LedgerFixture {
  /// Real bytes. `hidumper -s 1201 -a "-p Faultlogger -l"`.
  static let oneEntryIndex = """

    -------------------------------[ability]-------------------------------


    ----------------------------------HiviewService----------------------------------
    Fault log list:
    ******
    jscrash-com.example.waterflowdemo-20010057-20260731162134
    ******
    """

  /// Real bytes, empty form: the device answered and has nothing.
  static let emptyIndex = """

    -------------------------------[ability]-------------------------------


    ----------------------------------HiviewService----------------------------------
    No fault log exist.
    Fault log list:
    ******
    ******
    """

  /// A later entry for the same bundle, used to prove the watermark counts
  /// what appeared *after* the mark. Shape copied from the real listing.
  static let twoEntryIndex = """

    ----------------------------------HiviewService----------------------------------
    Fault log list:
    ******
    jscrash-com.example.waterflowdemo-20010057-20260731162134
    cppcrash-com.example.waterflowdemo-20010057-20260731170000
    ******
    """

  static let entryName = "jscrash-com.example.waterflowdemo-20010057-20260731162134"
  static let laterEntryName = "cppcrash-com.example.waterflowdemo-20010057-20260731170000"
  static let baselineWatermark = "20260731162134"

  /// Real bytes. `hidumper -s 1201 -a "-p Faultlogger -f <entry>"`, with the
  /// fingerprint and unique id masked and the `HiLog:` tail truncated.
  static let jsCrashBody = """

    ----------------------------------HiviewService----------------------------------
    Generated by HiviewDFX@OpenHarmony
    ================================================================
    Device info:OpenHarmony 3.2
    Build info:OpenHarmony 7.0.0.36
    DeviceDebuggable:Yes
    Fingerprint:<masked>
    Timestamp:2026-07-31 16:21:34.4146710440
    Module name:com.example.waterflowdemo
    ReleaseType:debug
    Version:1.0.0
    VersionCode:1000000
    IsSystemApp:No
    PreInstalled:No
    Foreground:Yes
    Pid:1846
    Uid:20010057
    Process name:com.example.waterflowdemo
    App running unique id:<masked>
    Process life time:208s
    Page switch history:
      16:21:22.726 :enters foreground
    Reason:TypeError
    Error name:TypeError
    Error message:Cannot read property triggerNativeCrash of undefined
    Stacktrace:
        at anonymous entry (entry/src/main/ets/crashprobe/CrashProbe.ets:36:16)
    NativeModuleErrorInfo:
    There are a total of 4 SO loading failure messages, and 4 of them are displayed here.
    #1 ModuleName:file.bfs Reason:module not found
    #4 ModuleName:crashprobe Reason:app lib path not registered in namespace 'default'

    HiLog:
    07-31 16:21:22.628  1846  1846 I A00000/testTag: Ability onCreate
    """

  /// Hand-written to the documented cppcrash shape. Not device-measured.
  static let cppCrashBody = """
    Generated by HiviewDFX@OpenHarmony
    ================================================================
    Device info:OpenHarmony 3.2
    Timestamp:2026-07-31 17:00:00.000
    Module name:com.example.waterflowdemo
    Pid:1901
    Uid:20010057
    Process name:com.example.waterflowdemo
    Reason:Signal:SIGABRT(SI_TKILL)@0x0000000000000004
    Fault thread info:
    Tid:1901, Name:e.example.water
    #00 pc 00000000000a1b2c /system/lib64/libc.so(abort+164)
    #01 pc 00000000000d4e5f /system/lib64/libace_compatible.z.so(OHOS::Ace::NG::WaterFlowPattern::RecoverBack()+72)
    """

  /// Hand-written to the documented appfreeze shape. Not device-measured.
  /// An appfreeze has no signal, which is the point of keeping it here.
  static let appFreezeBody = """
    Generated by HiviewDFX@OpenHarmony
    ================================================================
    Device info:OpenHarmony 3.2
    Timestamp:2026-07-31 17:05:00.000
    Module name:com.example.waterflowdemo
    Pid:1955
    Process name:com.example.waterflowdemo
    Reason:THREAD_BLOCK_6S
    """

  static let declaredSignature = "TypeError+CrashProbe.ets"
}

private struct StagedArtifact {
  let descriptor: HarnessArtifactDescriptor
  let bytes: Data
}

private final class StagingArtifactPort: HarnessArtifactPort, @unchecked Sendable {
  private let lock = NSLock()
  private var staged: [String: [StagedArtifact]] = [:]
  private var reads: [String] = []
  var inventoryFailure: String?
  private var leasesEnabled = false

  var readArtifactIDs: [String] { lock.withLock { reads } }

  func enableLeases() { lock.withLock { leasesEnabled = true } }

  func stage(
    jobID: String,
    name: String,
    text: String? = nil,
    bytes: Data? = nil,
    published: Bool = true,
    sensitive: Bool = false,
    sha256Override: String? = nil,
    byteCountOverride: Int? = nil,
    missingReason: String? = nil,
    mediaType: String = "text/plain"
  ) {
    let data = bytes ?? Data((text ?? "").utf8)
    let descriptor = HarnessArtifactDescriptor(
      artifactID: "ART-\(jobID)-\(name)",
      name: name,
      mediaType: mediaType,
      byteCount: byteCountOverride ?? data.count,
      sha256: sha256Override ?? sha256Hex(data),
      published: published,
      sensitive: sensitive,
      missingReason: missingReason)
    lock.withLock { staged[jobID, default: []].append(StagedArtifact(descriptor: descriptor, bytes: data)) }
  }

  func inventory(jobID: String) async throws -> [HarnessArtifactDescriptor] {
    try lock.withLock {
      if let inventoryFailure {
        throw HarnessArtifactPortError.unavailable(inventoryFailure)
      }
      return (staged[jobID] ?? []).map(\.descriptor)
    }
  }

  func read(jobID: String, artifactID: String, maximumBytes: Int) async throws -> Data {
    try lock.withLock {
      guard let match = (staged[jobID] ?? []).first(where: { $0.descriptor.artifactID == artifactID })
      else { throw HarnessArtifactPortError.unreadable(artifactID) }
      reads.append(artifactID)
      return match.bytes.prefix(maximumBytes)
    }
  }

  func leaseReference(jobID: String, artifactID: String) async throws -> String {
    try lock.withLock {
      guard leasesEnabled else {
        throw HarnessArtifactPortError.unavailable(
          "artifact leases are unavailable in this composition")
      }
      guard (staged[jobID] ?? []).contains(where: {
        $0.descriptor.artifactID == artifactID && $0.descriptor.published
      }) else { throw HarnessArtifactPortError.unreadable(artifactID) }
      return "lease-v1:\(jobID):\(artifactID)"
    }
  }

  func descriptor(jobID: String, name: String) -> HarnessArtifactDescriptor? {
    lock.withLock {
      (staged[jobID] ?? []).first { $0.descriptor.name == name }?.descriptor
    }
  }
}

private final class ScriptedJobPort: HarnessRuntimeJobPort, @unchecked Sendable {
  private let lock = NSLock()
  private var observations: [String: HarnessJobObservation] = [:]
  private var submissions: [String] = []
  private var requests: [RuntimeOperationRequest] = []
  private var nextOrdinal = 1

  var submittedOperations: [String] { lock.withLock { submissions } }
  var submittedRequests: [RuntimeOperationRequest] { lock.withLock { requests } }

  func submit(requestJSON: Data) async throws -> HarnessJobAcceptance {
    let request = try JSONDecoder().decode(RuntimeOperationRequest.self, from: requestJSON)
    return lock.withLock {
      let jobID = "JOB-\(nextOrdinal)"
      nextOrdinal += 1
      submissions.append(request.operation.reference)
      requests.append(request)
      observations[jobID] = HarnessJobObservation(
        jobID: jobID, state: "running", isTerminal: false, succeeded: false,
        outcomeUnknown: false, waitingForHuman: false, timeline: ["queued", "running"])
      return HarnessJobAcceptance(jobID: jobID, deduplicated: false)
    }
  }

  func startRun(jobID: String) async throws {}

  func observe(jobID: String) async throws -> HarnessJobObservation {
    try lock.withLock {
      guard let observation = observations[jobID] else {
        throw HarnessJobPortError.unknownJob(jobID)
      }
      return observation
    }
  }

  func requestCancel(jobID: String) async throws {}

  func finish(_ jobID: String, state: String = "succeeded") {
    lock.withLock {
      observations[jobID] = HarnessJobObservation(
        jobID: jobID, state: state, isTerminal: true, succeeded: state == "succeeded",
        outcomeUnknown: false, waitingForHuman: false,
        timeline: ["queued", "running", state])
    }
  }
}

final class HarnessEvaluationContractTests: XCTestCase {
  private var rootURL: URL!

  override func setUpWithError() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-harness-eval-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
  }

  // MARK: - HTP-AC-7: observations come from verified bytes

  func testSensitiveEvidenceLeaseRequiresTheSameExplicitOptInAsReading() async throws {
    let store = try RuntimeArtifactStore(
      rootURL: rootURL.appendingPathComponent("artifacts", isDirectory: true),
      nowUTC: { "2026-07-31T00:00:00Z" })
    let published = try await store.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "JOB-sensitive", sessionID: "SESSION-sensitive", stepID: "capture",
        name: "crash-index.txt", mediaType: "text/plain", privacy: .sensitive,
        retentionClass: .pinnedUntilVerified, sourceOperation: "capture.diagnostics@1",
        providerID: "hdc",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-1", bindingRevision: 1,
          stableIdentitySHA256: String(repeating: "a", count: 64)),
        contents: Data(LedgerFixture.oneEntryIndex.utf8)))

    let closed = RuntimeArtifactStoreHarnessPort(store: store)
    do {
      _ = try await closed.leaseReference(
        jobID: published.jobID, artifactID: published.artifactID)
      XCTFail("sensitive evidence lease must remain closed without an explicit opt-in")
    } catch {
      XCTAssertEqual(
        error as? HarnessArtifactPortError,
        .unavailable("sensitive analyzer source is not opted in: crash-index.txt"))
    }

    let optedIn = RuntimeArtifactStoreHarnessPort(
      store: store, sensitiveEvidenceAllowList: ["crash-index.txt"])
    let lease = try await optedIn.leaseReference(
      jobID: published.jobID, artifactID: published.artifactID)
    XCTAssertTrue(lease.hasPrefix("lease-v1:"))
    XCTAssertFalse(lease.contains(rootURL.path))
  }

  func testMeasurementsComeFromVerifiedBytes() async throws {
    let port = StagingArtifactPort()
    port.stage(jobID: "JOB-1", name: "crash-index.txt", text: LedgerFixture.twoEntryIndex)
    port.stage(jobID: "JOB-1", name: "crash-log.txt", text: LedgerFixture.cppCrashBody)
    port.stage(jobID: "JOB-1", name: "hilog.txt", text: HilogFixture.clean)
    port.stage(jobID: "JOB-1", name: "ui-dump.json", text: "{\"windows\":[]}")
    let builder = HarnessObservationBuilder(artifacts: port)

    // Watermark set at the first entry, so only the later one is this
    // task's to count.
    let observation = try await builder.observe(
      round: 2, jobID: "JOB-1", declaredCrashSignature: "SIGABRT+WaterFlowPattern::RecoverBack",
      requiredEvidence: ["crash-index.txt"],
      crashLedgerWatermark: LedgerFixture.baselineWatermark)

    XCTAssertEqual(observation.measurements["matchingCrashCount"], .integer(1))
    XCTAssertEqual(observation.measurements["newFatalSignatureCount"], .integer(0))
    XCTAssertNil(observation.measurements["verificationRunCount"])
    XCTAssertNil(
      observation.measurements["applicationLiveness"],
      "a crash and unrelated HiLog cannot invent an application-state readback")
    XCTAssertEqual(
      observation.measurements["latestCrashEntryName"], .string(LedgerFixture.laterEntryName))
    if case .string(let signature)? = observation.measurements["latestCrashSignature"] {
      XCTAssertTrue(signature.hasPrefix("cppcrash:SIGABRT"), "got \(signature)")
    } else {
      XCTFail("a ledger entry with a body must yield a signature")
    }
    XCTAssertEqual(observation.measurements["crashLedgerWatermark"], .string("20260731170000"))
    XCTAssertEqual(observation.integrityBlockers, [])
    XCTAssertEqual(observation.collectionBlockers, [])
    XCTAssertEqual(observation.sampleContribution["matchingCrashCount"], 1)
  }

  /// The regression for r6: hilog carrying fault blocks must not add crash
  /// counts, or the same crash would be counted from two sources.
  func testHilogNeverContributesCrashCountsAnyMore() async throws {
    let port = StagingArtifactPort()
    port.stage(jobID: "JOB-1", name: "hilog.txt", text: HilogFixture.twoFaults)
    let builder = HarnessObservationBuilder(artifacts: port)

    let observation = try await builder.observe(
      round: 2, jobID: "JOB-1", declaredCrashSignature: HilogFixture.declaredSignature,
      requiredEvidence: ["hilog.txt"])

    XCTAssertNil(observation.measurements["matchingCrashCount"])
    XCTAssertNil(observation.measurements["newFatalSignatureCount"])
    XCTAssertNil(observation.measurements["latestCrashSignature"])
    XCTAssertNil(
      observation.measurements["applicationLiveness"],
      "HiLog is diagnostic context only, even when it contains application-looking lines")
  }

  func testEmptyLedgerIsPositiveEvidenceOfNoCrash() async throws {
    let port = StagingArtifactPort()
    port.stage(jobID: "JOB-1", name: "crash-index.txt", text: LedgerFixture.emptyIndex)
    port.stage(jobID: "JOB-1", name: "hilog.txt", text: HilogFixture.clean)
    let builder = HarnessObservationBuilder(artifacts: port)

    // An empty ledger still baselines on the first round: with no mark, no
    // round can say what appeared "since".
    let baseline = try await builder.observe(
      round: 1, jobID: "JOB-1", declaredCrashSignature: LedgerFixture.declaredSignature,
      requiredEvidence: ["crash-index.txt"])
    XCTAssertNil(baseline.measurements["matchingCrashCount"])
    XCTAssertEqual(baseline.measurements["crashLedgerWatermark"], .string(""))
    XCTAssertEqual(baseline.integrityBlockers, [])

    let counted = try await builder.observe(
      round: 2, jobID: "JOB-1", declaredCrashSignature: LedgerFixture.declaredSignature,
      requiredEvidence: ["crash-index.txt"], crashLedgerWatermark: "")
    XCTAssertEqual(counted.measurements["matchingCrashCount"], .integer(0))
    XCTAssertEqual(counted.measurements["newFatalSignatureCount"], .integer(0))
    XCTAssertNil(counted.measurements["applicationLiveness"])
    XCTAssertNil(counted.measurements["latestCrashSignature"])
  }

  func testApplicationLivenessComesOnlyFromCurrentTypedReadback() async throws {
    let digest = String(repeating: "d", count: 64)
    let port = StagingArtifactPort()
    port.stage(jobID: "JOB-1", name: "hilog.txt", text: HilogFixture.clean)
    port.stage(
      jobID: "JOB-1", name: "application-liveness.json",
      text: applicationLivenessJSON(
        jobID: "JOB-1", state: "HEALTHY", reasonCode: "targetProcessRunning",
        processState: "RUNNING", pidObserved: true, deployedDigest: digest))
    let builder = HarnessObservationBuilder(artifacts: port)

    let observation = try await builder.observe(
      round: 3, jobID: "JOB-1", declaredCrashSignature: nil,
      requiredEvidence: ["application-liveness.json"], expectedBindingRevision: 7,
      expectedDeployedArtifactDigest: digest)

    XCTAssertEqual(observation.measurements["applicationLiveness"], .string("healthy"))
    XCTAssertEqual(observation.sampleContribution["applicationLiveness"], 1)
    XCTAssertEqual(observation.integrityBlockers, [])
    XCTAssertEqual(observation.collectionBlockers, [])
  }

  func testStoppedApplicationCannotBeMadeHealthyBySystemHiLog() async throws {
    let port = StagingArtifactPort()
    port.stage(jobID: "JOB-1", name: "hilog.txt", text: HilogFixture.clean)
    port.stage(
      jobID: "JOB-1", name: "application-liveness.json",
      text: applicationLivenessJSON(
        jobID: "JOB-1", state: "UNHEALTHY", reasonCode: "targetProcessNotRunning",
        processState: "STOPPED", pidObserved: false))
    let observation = try await HarnessObservationBuilder(artifacts: port).observe(
      round: 1, jobID: "JOB-1", declaredCrashSignature: nil,
      requiredEvidence: ["application-liveness.json"], expectedBindingRevision: 7)

    XCTAssertEqual(observation.measurements["applicationLiveness"], .string("unhealthy"))
    XCTAssertEqual(observation.sampleContribution["applicationLiveness"], 1)
  }

  func testUnknownAndRevisionDriftContributeNoLivenessSample() async throws {
    let digest = String(repeating: "d", count: 64)
    let port = StagingArtifactPort()
    port.stage(
      jobID: "JOB-unknown", name: "application-liveness.json",
      text: applicationLivenessJSON(
        jobID: "JOB-unknown", state: "UNKNOWN", reasonCode: "processReadbackAmbiguous",
        processState: "UNKNOWN", pidObserved: false, deployedDigest: digest))
    let builder = HarnessObservationBuilder(artifacts: port)
    let unknown = try await builder.observe(
      round: 1, jobID: "JOB-unknown", declaredCrashSignature: nil,
      requiredEvidence: ["application-liveness.json"], expectedBindingRevision: 7,
      expectedDeployedArtifactDigest: digest)
    XCTAssertNil(unknown.measurements["applicationLiveness"])
    XCTAssertNil(unknown.sampleContribution["applicationLiveness"])
    XCTAssertEqual(
      unknown.collectionBlockers,
      ["applicationLivenessUnknown:processReadbackAmbiguous"])

    let stale = try await builder.observe(
      round: 2, jobID: "JOB-unknown", declaredCrashSignature: nil,
      requiredEvidence: ["application-liveness.json"], expectedBindingRevision: 8,
      expectedDeployedArtifactDigest: digest)
    XCTAssertNil(stale.measurements["applicationLiveness"])
    XCTAssertEqual(stale.collectionBlockers, ["applicationLivenessBindingRevisionChanged"])

    let differentDeployment = try await builder.observe(
      round: 3, jobID: "JOB-unknown", declaredCrashSignature: nil,
      requiredEvidence: ["application-liveness.json"], expectedBindingRevision: 7,
      expectedDeployedArtifactDigest: String(repeating: "e", count: 64))
    XCTAssertNil(differentDeployment.measurements["applicationLiveness"])
    XCTAssertEqual(
      differentDeployment.collectionBlockers,
      ["applicationLivenessDeployedArtifactChanged"])
  }

  func testApplicationLivenessHashMismatchIsAnErrorNotANewSample() async throws {
    let port = StagingArtifactPort()
    port.stage(
      jobID: "JOB-1", name: "application-liveness.json",
      text: applicationLivenessJSON(
        jobID: "JOB-1", state: "HEALTHY", reasonCode: "targetProcessRunning",
        processState: "RUNNING", pidObserved: true),
      sha256Override: String(repeating: "0", count: 64))
    let observation = try await HarnessObservationBuilder(artifacts: port).observe(
      round: 1, jobID: "JOB-1", declaredCrashSignature: nil,
      requiredEvidence: ["application-liveness.json"], expectedBindingRevision: 7)

    XCTAssertEqual(
      observation.integrityBlockers,
      ["artifactHashMismatch:application-liveness.json"])
    XCTAssertNil(observation.measurements["applicationLiveness"])
    XCTAssertNil(observation.sampleContribution["applicationLiveness"])
  }

  func testCrashStillFailsWhenTheApplicationHasAlreadyRestartedHealthy() async throws {
    let port = StagingArtifactPort()
    port.stage(jobID: "JOB-1", name: "crash-index.txt", text: LedgerFixture.twoEntryIndex)
    port.stage(jobID: "JOB-1", name: "crash-log.txt", text: LedgerFixture.cppCrashBody)
    port.stage(
      jobID: "JOB-1", name: "application-liveness.json",
      text: applicationLivenessJSON(
        jobID: "JOB-1", state: "HEALTHY", reasonCode: "targetProcessRunning",
        processState: "RUNNING", pidObserved: true))
    let observation = try await HarnessObservationBuilder(artifacts: port).observe(
      round: 2, jobID: "JOB-1",
      declaredCrashSignature: "SIGABRT+WaterFlowPattern::RecoverBack",
      requiredEvidence: ["crash-index.txt", "application-liveness.json"],
      crashLedgerWatermark: LedgerFixture.baselineWatermark,
      expectedBindingRevision: 7)

    XCTAssertEqual(observation.measurements["matchingCrashCount"], .integer(1))
    XCTAssertEqual(observation.measurements["applicationLiveness"], .string("healthy"))
    XCTAssertEqual(observation.sampleContribution["matchingCrashCount"], 1)
    XCTAssertEqual(observation.sampleContribution["applicationLiveness"], 1)
  }

  func testHashMismatchIsAnIntegrityBlockerAndYieldsNoMeasurement() async throws {
    let port = StagingArtifactPort()
    port.stage(
      jobID: "JOB-1", name: "hilog.txt", text: HilogFixture.clean,
      sha256Override: String(repeating: "0", count: 64))
    let builder = HarnessObservationBuilder(artifacts: port)

    let observation = try await builder.observe(
      round: 1, jobID: "JOB-1", declaredCrashSignature: nil, requiredEvidence: ["hilog.txt"])
    XCTAssertEqual(observation.integrityBlockers, ["artifactHashMismatch:hilog.txt"])
    XCTAssertTrue(
      observation.measurements.isEmpty,
      "bytes that did not verify must not produce a measurement in either direction")
    XCTAssertEqual(observation.evidence.first?.verified, false)
  }

  func testAbsentEmptyOversizeAndSensitiveEvidenceAreCollectionBlockers() async throws {
    let port = StagingArtifactPort()
    port.stage(
      jobID: "JOB-1", name: "hilog.txt", text: "", published: false,
      missingReason: "upstreamCaptureFailed")
    port.stage(jobID: "JOB-2", name: "hilog.txt", text: "")
    port.stage(jobID: "JOB-3", name: "hilog.txt", text: HilogFixture.clean)
    port.stage(jobID: "JOB-4", name: "hilog.txt", text: HilogFixture.clean, sensitive: true)
    let builder = HarnessObservationBuilder(artifacts: port, maximumEvaluationBytes: 16)

    let missing = try await builder.observe(
      round: 1, jobID: "JOB-1", declaredCrashSignature: nil, requiredEvidence: ["hilog.txt"])
    XCTAssertEqual(
      missing.collectionBlockers, ["artifactMissing:hilog.txt:upstreamCaptureFailed"])

    let empty = try await builder.observe(
      round: 1, jobID: "JOB-2", declaredCrashSignature: nil, requiredEvidence: ["hilog.txt"])
    XCTAssertEqual(empty.collectionBlockers, ["artifactEmpty:hilog.txt"])

    let oversize = try await builder.observe(
      round: 1, jobID: "JOB-3", declaredCrashSignature: nil, requiredEvidence: ["hilog.txt"])
    XCTAssertEqual(oversize.collectionBlockers.count, 1)
    XCTAssertTrue(
      oversize.collectionBlockers[0].hasPrefix("artifactExceedsEvaluationBound:hilog.txt"),
      "a hash over a truncated prefix proves nothing, so oversize evidence is a blocker")
    XCTAssertTrue(oversize.measurements.isEmpty)

    let sensitive = try await builder.observe(
      round: 1, jobID: "JOB-4", declaredCrashSignature: nil, requiredEvidence: ["hilog.txt"])
    XCTAssertEqual(sensitive.collectionBlockers, ["artifactSensitiveNotOptedIn:hilog.txt"])
    XCTAssertEqual(port.readArtifactIDs.filter { $0.contains("JOB-4") }, [])
  }

  func testRequiredEvidenceThatWasNeverCollectedIsABlocker() async throws {
    let port = StagingArtifactPort()
    port.stage(jobID: "JOB-1", name: "ui-dump.json", text: "{\"windows\":[]}")
    let builder = HarnessObservationBuilder(artifacts: port)

    let observation = try await builder.observe(
      round: 1, jobID: "JOB-1", declaredCrashSignature: nil, requiredEvidence: ["hilog.txt"])
    XCTAssertEqual(observation.collectionBlockers, ["artifactNotCollected:hilog.txt"])
  }

  func testUnavailableInventoryIsABlockerNotAnEmptyObservation() async throws {
    let port = StagingArtifactPort()
    port.inventoryFailure = "artifact store unavailable"
    let builder = HarnessObservationBuilder(artifacts: port)

    let observation = try await builder.observe(
      round: 1, jobID: "JOB-1", declaredCrashSignature: nil, requiredEvidence: ["hilog.txt"])
    XCTAssertEqual(observation.collectionBlockers, ["artifactInventoryUnavailable:JOB-1"])
    XCTAssertTrue(observation.measurements.isEmpty)
  }

  // MARK: - Evaluator semantics (HTP-AC-5, HTP-AC-6)

  private func criterion(
    _ id: String,
    metric: String,
    comparator: HarnessCriterionComparator = .equalTo,
    expected: JSONValue,
    mandatory: Bool = true,
    minimumSamples: Int = 1,
    evidence: [String] = ["crash-index.txt"],
    policy: HarnessInconclusivePolicy = .collectMoreEvidence
  ) -> HarnessSuccessCriterion {
    HarnessSuccessCriterion(
      criterionID: id, metric: metric, comparator: comparator, expected: expected,
      mandatory: mandatory, minimumSamples: minimumSamples, evidenceRequirements: evidence,
      inconclusivePolicy: policy)
  }

  func testNoMandatoryCriterionIsInconclusiveNotPass() {
    let observation = HarnessRoundObservation(
      round: 1,
      evidence: [
        HarnessEvidenceRecord(
          artifactID: "ART-1", name: "crash-index.txt", byteCount: 10, sha256: "abc",
          verified: true)
      ])
    let evaluation = HarnessCriteriaEvaluator.evaluate(
      criteria: [
        criterion("OPT-1", metric: "matchingCrashCount", expected: .integer(0), mandatory: false)
      ],
      observed: HarnessObservedState(
        measurements: ["matchingCrashCount": .integer(0)], samples: ["matchingCrashCount": 9]),
      round: observation, evaluationID: "EVAL-000000000001", htaskID: "HTASK-0123456789AB",
      nowUTC: "2026-07-30T00:00:00Z")
    XCTAssertEqual(
      evaluation.verdict, .inconclusive,
      "nothing mandatory to check is not a fix")
  }

  func testSampleGateAndIntegrityDominateTheVerdict() {
    let verified = HarnessRoundObservation(
      round: 1,
      evidence: [
        HarnessEvidenceRecord(
          artifactID: "ART-1", name: "crash-index.txt", byteCount: 10, sha256: "abc",
          verified: true)
      ])
    let criteria = [criterion("DC-1", metric: "matchingCrashCount", expected: .integer(0), minimumSamples: 5)]

    let short = HarnessCriteriaEvaluator.evaluate(
      criteria: criteria,
      observed: HarnessObservedState(
        measurements: ["matchingCrashCount": .integer(0)], samples: ["matchingCrashCount": 2]),
      round: verified, evaluationID: "EVAL-000000000002", htaskID: "HTASK-0123456789AB",
      nowUTC: "2026-07-30T00:00:00Z")
    XCTAssertEqual(short.verdict, .inconclusive)
    XCTAssertEqual(short.criterionResults[0].blockers, ["insufficientSamples:2/5"])

    let enough = HarnessCriteriaEvaluator.evaluate(
      criteria: criteria,
      observed: HarnessObservedState(
        measurements: ["matchingCrashCount": .integer(0)], samples: ["matchingCrashCount": 5]),
      round: verified, evaluationID: "EVAL-000000000003", htaskID: "HTASK-0123456789AB",
      nowUTC: "2026-07-30T00:00:00Z")
    XCTAssertEqual(enough.verdict, .pass)

    let corrupt = HarnessRoundObservation(
      round: 1,
      evidence: [
        HarnessEvidenceRecord(
          artifactID: "ART-1", name: "crash-index.txt", byteCount: 10, sha256: "abc",
          verified: false, blocker: "artifactHashMismatch:crash-index.txt")
      ],
      integrityBlockers: ["artifactHashMismatch:crash-index.txt"])
    let unverifiable = HarnessCriteriaEvaluator.evaluate(
      criteria: criteria,
      observed: HarnessObservedState(
        measurements: ["matchingCrashCount": .integer(0)], samples: ["matchingCrashCount": 5]),
      round: corrupt, evaluationID: "EVAL-000000000004", htaskID: "HTASK-0123456789AB",
      nowUTC: "2026-07-30T00:00:00Z")
    XCTAssertEqual(
      unverifiable.verdict, .error,
      "a hash mismatch is 'we cannot tell', never 'the criteria passed'")
  }

  func testComparatorsAndEscalationSelection() {
    let verified = HarnessRoundObservation(
      round: 1,
      evidence: [
        HarnessEvidenceRecord(
          artifactID: "ART-1", name: "crash-index.txt", byteCount: 10, sha256: "abc",
          verified: true)
      ])
    let observed = HarnessObservedState(
      measurements: [
        "frameTimeP95": .number(21.5),
        "fps": .integer(58),
        "latestCrashSignature": .string("SIGABRT+WaterFlowPattern::RecoverBack"),
        "newFatalSignatureCount": .integer(0),
      ],
      samples: [
        "frameTimeP95": 3, "fps": 3, "latestCrashSignature": 1, "newFatalSignatureCount": 1,
      ])
    let evaluation = HarnessCriteriaEvaluator.evaluate(
      criteria: [
        criterion("C-atMost", metric: "frameTimeP95", comparator: .atMost, expected: .number(24)),
        criterion("C-atLeast", metric: "fps", comparator: .atLeast, expected: .integer(55)),
        criterion(
          "C-matches", metric: "latestCrashSignature", comparator: .matches,
          expected: .string("RecoverBack")),
        criterion(
          "C-absent", metric: "newFatalSignatureCount", comparator: .absent, expected: .null),
      ],
      observed: observed, round: verified, evaluationID: "EVAL-000000000005",
      htaskID: "HTASK-0123456789AB", nowUTC: "2026-07-30T00:00:00Z")
    XCTAssertEqual(evaluation.verdict, .pass)

    let mixed = HarnessCriteriaEvaluator.evaluate(
      criteria: [
        criterion(
          "C-human", metric: "unobserved", expected: .integer(0), policy: .requestHuman),
        criterion(
          "C-collect", metric: "alsoUnobserved", expected: .integer(0),
          policy: .collectMoreEvidence),
      ],
      observed: observed, round: verified, evaluationID: "EVAL-000000000006",
      htaskID: "HTASK-0123456789AB", nowUTC: "2026-07-30T00:00:00Z")
    XCTAssertEqual(mixed.verdict, .inconclusive)
    XCTAssertEqual(
      HarnessCriteriaEvaluator.escalation(
        for: mixed,
        criteria: [
          criterion("C-human", metric: "unobserved", expected: .integer(0), policy: .requestHuman),
          criterion(
            "C-collect", metric: "alsoUnobserved", expected: .integer(0),
            policy: .collectMoreEvidence),
        ]),
      .requestHuman,
      "one criterion needing a human is not diluted by another that wants more evidence")
  }

  func testObservedStateAccumulatesCountersAndReplacesLatestValues() {
    var state = HarnessObservedState()
    state = state.merging(
      HarnessRoundObservation(
        round: 1,
        measurements: [
          "matchingCrashCount": .integer(1), "applicationLiveness": .string("unhealthy"),
        ],
        sampleContribution: ["matchingCrashCount": 1, "applicationLiveness": 1]))
    state = state.merging(
      HarnessRoundObservation(
        round: 2,
        measurements: [
          "matchingCrashCount": .integer(2), "applicationLiveness": .string("healthy"),
        ],
        sampleContribution: ["matchingCrashCount": 1, "applicationLiveness": 1]))
    XCTAssertEqual(state.measurements["matchingCrashCount"], .integer(3))
    XCTAssertEqual(state.measurements["applicationLiveness"], .string("healthy"))
    XCTAssertEqual(state.samples["matchingCrashCount"], 2)
    // Round trip through the snapshot's free-form observed state.
    XCTAssertEqual(HarnessObservedState(json: state.asJSON), state)
  }

  func testObservedStateCannotBeWrittenWithoutEvidence() throws {
    let snapshot = HarnessTaskSnapshot(
      htaskID: "HTASK-0123456789AB", type: .debugCrash, intakeDescription: nil, projectRef: nil,
      target: HarnessTaskTargetReference(targetID: "TGT-1"),
      goal: HarnessTaskGoal(summary: "goal"), successCriteria: [],
      budgets: HarnessTaskBudgets(
        maxRounds: 4, maxWallClockSeconds: 60, maxArtifactBytes: 1024, maxE1Mutations: 0),
      policy: HarnessTaskPolicy(allowedOperations: ["observe.device@1"]),
      createdAtUTC: "2026-07-30T00:00:00Z", updatedAtUTC: "2026-07-30T00:00:00Z",
      status: .humanRequired, phase: .collecting)
    XCTAssertThrowsError(
      try HarnessTaskStateReducer.apply(
        HarnessTaskTransition(
          causation: .humanResolved, reasonCode: "operator says it is fixed", status: .running,
          phase: .collecting, activeRound: 0, activeJobID: nil,
          consumedBudget: HarnessConsumedBudget(),
          observedState: ["measurements": .object(["matchingCrashCount": .integer(0)])],
          atUTC: "2026-07-30T00:01:00Z"),
        to: snapshot)
    ) { error in
      XCTAssertEqual(
        error as? HarnessTaskTransitionError,
        .observedStateRequiresEvidence(.humanResolved))
    }
  }

  // MARK: - End to end through the coordinator

  private func makeStack(
    artifacts: StagingArtifactPort,
    jobs: ScriptedJobPort,
    maxRounds: Int = 8,
    minimumSamples: Int = 2,
    includeCrashFixture: Bool = false
  ) throws -> (HarnessTaskCoordinator, HarnessTaskStore, HarnessTaskSubmission) {
    let store = try HarnessTaskStore(rootURL: rootURL)
    let coordinator = HarnessTaskCoordinator(
      store: store, jobPort: jobs, artifactPort: artifacts,
      nowUTC: { "2026-07-30T00:00:00Z" })
    var desiredState: [String: JSONValue] = [
      "crashSignature": .string(LedgerFixture.declaredSignature)
    ]
    if includeCrashFixture {
      desiredState["bundleName"] = .string("com.example.waterflowdemo")
      desiredState["abilityName"] = .string("EntryAbility")
      desiredState["baselineHapArtifactLease"] =
        .string("lease-v1:input-hap:ART-crash-fixture")
    }
    let submission = HarnessTaskSubmission(
      type: .debugCrash,
      target: HarnessTaskTargetReference(
        targetID: "TGT-958780b2ffb7",
        expectedBindingRevision: includeCrashFixture ? 1 : nil),
      goal: HarnessTaskGoal(
        summary: "No WaterFlow SIGABRT across runs",
        desiredState: desiredState),
      successCriteria: [
        criterion(
          "DC-1", metric: "matchingCrashCount", expected: .integer(0),
          minimumSamples: minimumSamples),
        criterion("DC-2", metric: "newFatalSignatureCount", expected: .integer(0)),
      ],
      budgets: HarnessTaskBudgets(
        maxRounds: maxRounds, maxWallClockSeconds: 900, maxArtifactBytes: 1 << 20,
        maxE1Mutations: includeCrashFixture ? 7 : 0),
      policy: HarnessTaskCoordinator.defaultPolicy(for: .debugCrash))
    return (coordinator, store, submission)
  }

  func testSuccessIsReachableOnlyThroughAPassingEvaluation() async throws {
    let artifacts = StagingArtifactPort()
    let jobs = ScriptedJobPort()
    let (coordinator, store, submission) = try makeStack(artifacts: artifacts, jobs: jobs)
    let task = try await coordinator.submit(submission)

    // Round 1: observe.device publishes no hilog, so nothing is decidable.
    _ = try await coordinator.reconcile(task.htaskID)
    jobs.finish("JOB-1")
    let afterObserve = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(afterObserve.action, .dispatched)
    XCTAssertEqual(afterObserve.snapshot.observed.latestVerdict, .inconclusive)

    // Round 2: the first readable ledger is the *baseline*. It sets the
    // watermark and deliberately contributes no sample, because "nothing
    // new since we last looked" has no meaning on the first look.
    artifacts.stage(jobID: "JOB-2", name: "crash-index.txt", text: LedgerFixture.oneEntryIndex)
    jobs.finish("JOB-2")
    let baseline = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(baseline.action, .dispatched, "an inconclusive verdict buys another round")
    XCTAssertEqual(baseline.snapshot.lifecycle, .waiting)
    XCTAssertEqual(baseline.snapshot.waitReason, .activeJob)
    XCTAssertNil(baseline.snapshot.observed.samples["matchingCrashCount"])
    XCTAssertEqual(
      baseline.snapshot.observed.measurements["crashLedgerWatermark"],
      .string(LedgerFixture.baselineWatermark),
      "the entry that predates the task is marked, not counted")

    // Round 3: the same ledger, now read against the mark - one sample,
    // still short of the two required.
    artifacts.stage(jobID: "JOB-3", name: "crash-index.txt", text: LedgerFixture.oneEntryIndex)
    jobs.finish("JOB-3")
    let firstSample = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(firstSample.action, .dispatched)
    XCTAssertEqual(firstSample.snapshot.observed.samples["matchingCrashCount"], 1)

    // Round 4: the second clean sample satisfies both criteria.
    artifacts.stage(jobID: "JOB-4", name: "crash-index.txt", text: LedgerFixture.oneEntryIndex)
    jobs.finish("JOB-4")
    let succeeded = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(succeeded.action, .evaluatedSucceeded)
    XCTAssertEqual(succeeded.snapshot.status, .succeeded)
    let evaluationID = try XCTUnwrap(succeeded.snapshot.latestEvaluationID)
    XCTAssertEqual(succeeded.snapshot.result?.evaluationID, evaluationID)
    XCTAssertEqual(succeeded.snapshot.result?.reasonCode, "criteriaPassed")

    // The verdict is a durable record, not a phrase in a summary.
    let loaded = try await store.evaluation(task.htaskID, evaluationID: evaluationID)
    let stored = try XCTUnwrap(loaded)
    XCTAssertEqual(stored.verdict, .pass)
    XCTAssertEqual(stored.criterionResults.map(\.verdict), [.pass, .pass])
    XCTAssertTrue(stored.evidence.contains { $0.name == "crash-index.txt" && $0.verified })

    // Only an evaluation causation may carry the task into succeeded.
    let events = try await coordinator.events(task.htaskID)
    let terminal = try XCTUnwrap(events.last)
    XCTAssertEqual(terminal.causation, .evaluation)
    XCTAssertEqual(terminal.toStatus, .succeeded)
    XCTAssertEqual(terminal.evaluationID, evaluationID)
    XCTAssertEqual(
      events.filter { $0.toStatus == .succeeded }.map(\.causation), [.evaluation],
      "no other causation ever reaches succeeded")
  }

  func testProductionCaptureDispatchesPinnedAnalyzerAndConsumesItsDerivedArtifact()
    async throws
  {
    let artifacts = StagingArtifactPort()
    artifacts.enableLeases()
    let jobs = ScriptedJobPort()
    let (coordinator, _, submission) = try makeStack(
      artifacts: artifacts, jobs: jobs, minimumSamples: 1,
      includeCrashFixture: true)
    let task = try await coordinator.submit(submission)

    _ = try await coordinator.reconcile(task.htaskID)  // observe.device
    jobs.finish("JOB-1")
    _ = try await coordinator.reconcile(task.htaskID)  // capture.diagnostics

    artifacts.stage(
      jobID: "JOB-2", name: HarnessObservationBuilder.crashIndexArtifact,
      text: LedgerFixture.emptyIndex)
    jobs.finish("JOB-2")
    let analysisDispatch = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(analysisDispatch.action, .dispatched)
    XCTAssertEqual(
      jobs.submittedOperations,
      [
        DebugCrashTaskHandler.observeDevice, DebugCrashTaskHandler.captureDiagnostics,
        DebugCrashTaskHandler.analyzeCrashLedger,
      ])
    let analyzerRequest = try XCTUnwrap(jobs.submittedRequests.last)
    XCTAssertNil(
      analyzerRequest.target.expectedBindingRevision,
      "a host-only analyzer request must not masquerade as device-bound")
    guard case .string(let sourceLease)? = analyzerRequest.inputs["sourceArtifactRef"] else {
      return XCTFail("the analyzer must receive the exact ID-only source lease")
    }
    XCTAssertTrue(sourceLease.hasPrefix("lease-v1:JOB-2:ART-JOB-2-crash-index.txt"))

    let source = try XCTUnwrap(
      artifacts.descriptor(
        jobID: "JOB-2", name: HarnessObservationBuilder.crashIndexArtifact))
    let analyzerOutput = try HarnessCrashLedgerDerivedAnalyzer.analyze(
      Data(LedgerFixture.emptyIndex.utf8))
    let envelope = HarnessCrashLedgerDerivedArtifact(
      analyzerRef: HarnessCrashLedgerAnalysis.analyzerRef,
      analyzerVersion: HarnessCrashLedgerAnalysis.analyzerVersion,
      sourceArtifactID: source.artifactID, sourceSHA256: source.sha256,
      sourceByteCount: source.byteCount,
      analyzerOutputSHA256: sha256Hex(analyzerOutput),
      analyzerOutputByteCount: analyzerOutput.count,
      result: try JSONDecoder().decode(
        HarnessCrashLedgerAnalysis.self, from: analyzerOutput))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    artifacts.stage(
      jobID: "JOB-3", name: "crash-signature.json",
      bytes: try encoder.encode(envelope), mediaType: "application/json")
    jobs.finish("JOB-3")

    let evaluated = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(
      evaluated.action, .stoppedForHuman,
      "this test composition has no E1 authorization port, so the fixture stops at its gate")
    XCTAssertEqual(evaluated.snapshot.phase, .collecting)
    XCTAssertEqual(
      DebugCrashTaskHandler().plan(
        for: evaluated.snapshot, decisionID: "dec-after-analysis",
        nowUTC: "2026-07-30T00:00:00Z").decision.operationReference,
      DebugCrashTaskHandler.deployHAP,
      "the analyzed baseline must return to collecting and select the fixture deployment")
    XCTAssertEqual(
      evaluated.snapshot.observed.measurements[HarnessObservationBuilder.watermarkMetric],
      .string(""))
    XCTAssertTrue(evaluated.snapshot.artifactRefs.contains(source.artifactID))
    XCTAssertTrue(
      evaluated.snapshot.artifactRefs.contains("ART-JOB-3-crash-signature.json"))
    XCTAssertNil(
      evaluated.snapshot.observedState[DebugCrashTaskHandler.pendingAnalysisSourceLeaseKey],
      "a consumed source lease must not schedule the analyzer twice")
  }

  func testDerivedAnalyzerResultMustMatchItsRecordedOutputDigest() async throws {
    let artifacts = StagingArtifactPort()
    artifacts.stage(
      jobID: "JOB-source", name: HarnessObservationBuilder.crashIndexArtifact,
      text: LedgerFixture.emptyIndex)
    let source = try XCTUnwrap(
      artifacts.descriptor(
        jobID: "JOB-source", name: HarnessObservationBuilder.crashIndexArtifact))
    let originalOutput = try HarnessCrashLedgerDerivedAnalyzer.analyze(
      Data(LedgerFixture.emptyIndex.utf8))
    let tamperedResult = HarnessCrashLedgerAnalysis(
      status: .answered,
      entries: [try XCTUnwrap(HarnessFaultLogLedger.parse(entryName: LedgerFixture.entryName))])
    let envelope = HarnessCrashLedgerDerivedArtifact(
      analyzerRef: HarnessCrashLedgerAnalysis.analyzerRef,
      analyzerVersion: HarnessCrashLedgerAnalysis.analyzerVersion,
      sourceArtifactID: source.artifactID, sourceSHA256: source.sha256,
      sourceByteCount: source.byteCount,
      analyzerOutputSHA256: sha256Hex(originalOutput),
      analyzerOutputByteCount: originalOutput.count,
      result: tamperedResult)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    artifacts.stage(
      jobID: "JOB-derived", name: "crash-signature.json",
      bytes: try encoder.encode(envelope), mediaType: "application/json")

    let observed = try await HarnessObservationBuilder(artifacts: artifacts).observe(
      round: 1, jobID: "JOB-derived", declaredCrashSignature: LedgerFixture.declaredSignature,
      requiredEvidence: [HarnessObservationBuilder.crashIndexArtifact],
      sourceEvidenceJobID: "JOB-source", expectedSourceArtifactID: source.artifactID)
    XCTAssertTrue(
      observed.integrityBlockers.contains("crashLedgerDerivedArtifactProvenanceMismatch"))
    XCTAssertNil(observed.measurements[HarnessObservationBuilder.watermarkMetric])
  }

  func testAFailingCriterionHandsTheVerdictToAHumanAndNeverSucceeds() async throws {
    let artifacts = StagingArtifactPort()
    let jobs = ScriptedJobPort()
    let (coordinator, store, submission) = try makeStack(
      artifacts: artifacts, jobs: jobs, minimumSamples: 1)
    let task = try await coordinator.submit(submission)

    _ = try await coordinator.reconcile(task.htaskID)
    jobs.finish("JOB-1")
    _ = try await coordinator.reconcile(task.htaskID)
    // Round 2 baselines on an empty ledger: nothing had crashed yet.
    artifacts.stage(jobID: "JOB-2", name: "crash-index.txt", text: LedgerFixture.emptyIndex)
    jobs.finish("JOB-2")
    _ = try await coordinator.reconcile(task.htaskID)

    // Round 3: the declared crash appears *after* the mark, so it is this
    // task's crash and the mandatory criterion genuinely fails.
    artifacts.stage(jobID: "JOB-3", name: "crash-index.txt", text: LedgerFixture.oneEntryIndex)
    artifacts.stage(jobID: "JOB-3", name: "crash-log.txt", text: LedgerFixture.jsCrashBody)
    jobs.finish("JOB-3")

    let failed = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(failed.snapshot.observed.latestVerdict, .fail)
    XCTAssertEqual(failed.snapshot.observed.measurements["matchingCrashCount"], .integer(1))
    XCTAssertEqual(failed.action, .stoppedForHuman)
    XCTAssertEqual(failed.reasonCode, "patchProposalRequired")
    XCTAssertEqual(failed.snapshot.status, .humanRequired)
    XCTAssertNotEqual(failed.snapshot.status, .succeeded)

    let evaluations = try await store.evaluations(task.htaskID)
    XCTAssertEqual(evaluations.last?.verdict, .fail)
  }

  func testInconclusiveNeverSucceedsAndTheBudgetStopsTheLoop() async throws {
    let artifacts = StagingArtifactPort()
    let jobs = ScriptedJobPort()
    // Five samples required, three rounds of budget: the loop must stop
    // without ever calling this a success.
    let (coordinator, _, submission) = try makeStack(
      artifacts: artifacts, jobs: jobs, maxRounds: 3, minimumSamples: 5)
    let task = try await coordinator.submit(submission)

    var finalOutcome: HarnessReconcileOutcome?
    for round in 1...6 {
      let outcome = try await coordinator.reconcile(task.htaskID)
      finalOutcome = outcome
      if outcome.snapshot.status.isTerminal || outcome.action == .stoppedForHuman { break }
      artifacts.stage(jobID: "JOB-\(round)", name: "hilog.txt", text: HilogFixture.clean)
      jobs.finish("JOB-\(round)")
    }
    let outcome = try XCTUnwrap(finalOutcome)
    XCTAssertEqual(outcome.action, .stoppedBudgetExhausted)
    XCTAssertEqual(outcome.snapshot.status, .failed)
    XCTAssertEqual(outcome.reasonCode, "maxRoundsExhausted")
    XCTAssertEqual(outcome.snapshot.observed.latestVerdict, .inconclusive)
    XCTAssertLessThan(outcome.snapshot.observed.samples["matchingCrashCount"] ?? 0, 5)
  }

  func testEvidenceIntegrityFailureStopsForAHumanWithoutAnotherCapture() async throws {
    let artifacts = StagingArtifactPort()
    let jobs = ScriptedJobPort()
    let (coordinator, _, submission) = try makeStack(
      artifacts: artifacts, jobs: jobs, minimumSamples: 1)
    let task = try await coordinator.submit(submission)

    _ = try await coordinator.reconcile(task.htaskID)
    jobs.finish("JOB-1")
    _ = try await coordinator.reconcile(task.htaskID)
    artifacts.stage(
      jobID: "JOB-2", name: "crash-index.txt", text: LedgerFixture.emptyIndex,
      sha256Override: String(repeating: "f", count: 64))
    jobs.finish("JOB-2")

    let blocked = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(blocked.action, .stoppedEvidenceIntegrity)
    XCTAssertEqual(blocked.snapshot.status, .humanRequired)
    XCTAssertTrue(blocked.reasonCode.hasPrefix("evidenceIntegrity:artifactHashMismatch"))
    let submittedBefore = jobs.submittedOperations.count
    let again = try await coordinator.reconcile(task.htaskID)
    XCTAssertEqual(again.action, .awaitingHuman)
    XCTAssertEqual(
      jobs.submittedOperations.count, submittedBefore,
      "unverifiable evidence must not trigger another capture on its own")
  }
}

// MARK: - HFA-AC-1 / HFA-AC-2: the crash ledger is the source, and it fails closed

extension HarnessEvaluationContractTests {
  /// HFA-AC-1 on real bytes: the fields a jscrash entry actually carries.
  func testRealJsCrashEntryYieldsItsReasonAndSourceLocation() async throws {
    let port = StagingArtifactPort()
    port.stage(jobID: "JOB-1", name: "crash-index.txt", text: LedgerFixture.oneEntryIndex)
    port.stage(jobID: "JOB-1", name: "crash-log.txt", text: LedgerFixture.jsCrashBody)
    let builder = HarnessObservationBuilder(artifacts: port)

    let observation = try await builder.observe(
      round: 2, jobID: "JOB-1", declaredCrashSignature: LedgerFixture.declaredSignature,
      requiredEvidence: ["crash-index.txt"], crashLedgerWatermark: "20260731000000")

    XCTAssertEqual(
      observation.measurements["matchingCrashCount"], .integer(1),
      "the declared TypeError+CrashProbe.ets tokens are both in this entry")
    XCTAssertEqual(observation.measurements["newFatalSignatureCount"], .integer(0))
    XCTAssertEqual(
      observation.measurements["latestCrashEntryName"], .string(LedgerFixture.entryName))
    XCTAssertEqual(
      observation.measurements["latestCrashSignature"],
      .string("jscrash:TypeError+entry/src/main/ets/crashprobe/CrashProbe.ets:36:16"))
  }

  /// A mandatory criterion cannot pass while the ledger shows a match.
  func testAMatchingLedgerEntryKeepsTheMandatoryCriterionFromPassing() async throws {
    let port = StagingArtifactPort()
    port.stage(jobID: "JOB-1", name: "crash-index.txt", text: LedgerFixture.oneEntryIndex)
    port.stage(jobID: "JOB-1", name: "crash-log.txt", text: LedgerFixture.jsCrashBody)
    let builder = HarnessObservationBuilder(artifacts: port)
    let observation = try await builder.observe(
      round: 2, jobID: "JOB-1", declaredCrashSignature: LedgerFixture.declaredSignature,
      requiredEvidence: ["crash-index.txt"], crashLedgerWatermark: "20260731000000")

    let criterion = HarnessSuccessCriterion(
      criterionID: "DC-1-crash-signature-absent", metric: "matchingCrashCount",
      comparator: .equalTo, expected: .integer(0), mandatory: true, minimumSamples: 1,
      evidenceRequirements: ["crash-index.txt"], inconclusivePolicy: .collectMoreEvidence)
    let evaluation = HarnessCriteriaEvaluator.evaluate(
      criteria: [criterion], observed: HarnessObservedState().merging(observation),
      round: observation, evaluationID: "EVAL-1", htaskID: "HTASK-1",
      nowUTC: "2026-07-31T09:00:00Z")
    XCTAssertEqual(evaluation.verdict, .fail)
  }

  /// Negative ①: the declared crash evidence never arrived. Inconclusive,
  /// never a pass - "we did not look" must not read as "nothing there".
  func testAbsentLedgerIsInconclusiveAndNeverPasses() async throws {
    let port = StagingArtifactPort()
    port.stage(jobID: "JOB-1", name: "hilog.txt", text: HilogFixture.clean)
    let builder = HarnessObservationBuilder(artifacts: port)

    let observation = try await builder.observe(
      round: 2, jobID: "JOB-1", declaredCrashSignature: LedgerFixture.declaredSignature,
      requiredEvidence: ["crash-index.txt"], crashLedgerWatermark: "20260731000000")

    XCTAssertEqual(observation.collectionBlockers, ["artifactNotCollected:crash-index.txt"])
    XCTAssertNil(observation.measurements["matchingCrashCount"])

    let criterion = HarnessSuccessCriterion(
      criterionID: "DC-1-crash-signature-absent", metric: "matchingCrashCount",
      comparator: .equalTo, expected: .integer(0), mandatory: true, minimumSamples: 1,
      evidenceRequirements: ["crash-index.txt"], inconclusivePolicy: .collectMoreEvidence)
    let evaluation = HarnessCriteriaEvaluator.evaluate(
      criteria: [criterion], observed: HarnessObservedState().merging(observation),
      round: observation, evaluationID: "EVAL-1", htaskID: "HTASK-1",
      nowUTC: "2026-07-31T09:00:00Z")
    XCTAssertEqual(evaluation.verdict, .inconclusive)
  }

  /// Negative ②: an *empty* ledger and a *missing* one must be
  /// distinguishable - only the first may support "no matching crash".
  func testEmptyLedgerAndMissingLedgerAreDifferentAnswers() async throws {
    let port = StagingArtifactPort()
    port.stage(jobID: "EMPTY", name: "crash-index.txt", text: LedgerFixture.emptyIndex)
    port.stage(
      jobID: "MISSING", name: "crash-index.txt", text: "", published: false,
      missingReason: "upstreamCaptureFailed")
    let builder = HarnessObservationBuilder(artifacts: port)

    let empty = try await builder.observe(
      round: 2, jobID: "EMPTY", declaredCrashSignature: LedgerFixture.declaredSignature,
      requiredEvidence: ["crash-index.txt"], crashLedgerWatermark: "")
    XCTAssertEqual(empty.measurements["matchingCrashCount"], .integer(0))
    XCTAssertEqual(empty.collectionBlockers, [])

    let missing = try await builder.observe(
      round: 2, jobID: "MISSING", declaredCrashSignature: LedgerFixture.declaredSignature,
      requiredEvidence: ["crash-index.txt"], crashLedgerWatermark: "")
    XCTAssertEqual(
      missing.collectionBlockers, ["artifactMissing:crash-index.txt:upstreamCaptureFailed"])
    XCTAssertNil(missing.measurements["matchingCrashCount"])
  }

  /// Negative ③: bytes that are not a ledger are an integrity blocker, which
  /// the evaluator turns into ERROR and a human stop.
  func testUnreadableLedgerIsAnIntegrityBlockerNotAnEmptyLedger() async throws {
    let port = StagingArtifactPort()
    port.stage(jobID: "JOB-1", name: "crash-index.txt", text: "hidumper: unknown service 1201")
    port.stage(jobID: "JOB-2", name: "crash-index.txt", text: """
      Fault log list:
      ******
      not-a-valid-entry-name
      ******
      """)
    let builder = HarnessObservationBuilder(artifacts: port)

    let garbage = try await builder.observe(
      round: 2, jobID: "JOB-1", declaredCrashSignature: nil,
      requiredEvidence: ["crash-index.txt"], crashLedgerWatermark: "")
    XCTAssertEqual(
      garbage.integrityBlockers, ["crashLedgerUnreadable:crash-index.txt:ledgerHeaderAbsent"])
    XCTAssertNil(garbage.measurements["matchingCrashCount"])

    let badName = try await builder.observe(
      round: 2, jobID: "JOB-2", declaredCrashSignature: nil,
      requiredEvidence: ["crash-index.txt"], crashLedgerWatermark: "")
    XCTAssertEqual(
      badName.integrityBlockers, ["crashLedgerUnreadable:crash-index.txt:entryNameUnparseable"])
    XCTAssertNil(badName.measurements["matchingCrashCount"])
  }

  /// The watermark: history on the device is not this task's crash, and one
  /// entry is counted once however many rounds look at it.
  func testHistoricEntriesAreNotCountedAndFreshOnesAreCountedOnce() async throws {
    let port = StagingArtifactPort()
    port.stage(jobID: "JOB-1", name: "crash-index.txt", text: LedgerFixture.oneEntryIndex)
    let builder = HarnessObservationBuilder(artifacts: port)

    // Baseline: a mark, no count, no sample.
    let baseline = try await builder.observe(
      round: 1, jobID: "JOB-1", declaredCrashSignature: LedgerFixture.declaredSignature,
      requiredEvidence: ["crash-index.txt"])
    XCTAssertEqual(
      baseline.measurements["crashLedgerWatermark"], .string(LedgerFixture.baselineWatermark))
    XCTAssertNil(baseline.measurements["matchingCrashCount"])
    XCTAssertNil(baseline.sampleContribution["matchingCrashCount"])

    // The pre-existing entry never becomes this task's crash, however many
    // rounds run. Without this the criterion could never reach zero.
    var observed = HarnessObservedState().merging(baseline)
    for _ in 0..<5 {
      let round = try await builder.observe(
        round: 2, jobID: "JOB-1", declaredCrashSignature: LedgerFixture.declaredSignature,
        requiredEvidence: ["crash-index.txt"],
        crashLedgerWatermark: LedgerFixture.baselineWatermark)
      observed = observed.merging(round)
    }
    XCTAssertEqual(observed.measurements["matchingCrashCount"], .integer(0))
    XCTAssertEqual(observed.samples["matchingCrashCount"], 5)

    // A newer entry counts exactly once, then the advanced mark retires it.
    port.stage(jobID: "JOB-2", name: "crash-index.txt", text: LedgerFixture.twoEntryIndex)
    let fresh = try await builder.observe(
      round: 7, jobID: "JOB-2", declaredCrashSignature: LedgerFixture.declaredSignature,
      requiredEvidence: ["crash-index.txt"],
      crashLedgerWatermark: LedgerFixture.baselineWatermark)
    XCTAssertEqual(fresh.measurements["newFatalSignatureCount"], .integer(1))
    XCTAssertEqual(fresh.measurements["crashLedgerWatermark"], .string("20260731170000"))

    let again = try await builder.observe(
      round: 8, jobID: "JOB-2", declaredCrashSignature: LedgerFixture.declaredSignature,
      requiredEvidence: ["crash-index.txt"], crashLedgerWatermark: "20260731170000")
    XCTAssertEqual(again.measurements["newFatalSignatureCount"], .integer(0))
  }

  /// Kind dispatch: an appfreeze has no signal and must not be given one.
  func testAppFreezeYieldsNoFabricatedSignal() throws {
    let signature = try XCTUnwrap(
      HarnessFaultLogLedger.detail(inEntryBody: LedgerFixture.appFreezeBody, kind: "appfreeze"))
    XCTAssertEqual(signature.kind, "appfreeze")
    XCTAssertEqual(signature.signal, "THREAD_BLOCK_6S")
    XCTAssertNil(signature.topFrame)
    XCTAssertFalse(
      HarnessFaultLogLedger.fatalSignals.contains(where: { signature.rendered.contains($0) }),
      "an appfreeze must never render as a signal crash")
  }

  /// The entry name decomposes from the right, so a bundle keeps its dots.
  func testEntryNameDecomposition() throws {
    let entry = try XCTUnwrap(HarnessFaultLogLedger.parse(entryName: LedgerFixture.entryName))
    XCTAssertEqual(entry.kind, "jscrash")
    XCTAssertEqual(entry.bundle, "com.example.waterflowdemo")
    XCTAssertEqual(entry.uid, "20010057")
    XCTAssertEqual(entry.timestamp, "20260731162134")
    XCTAssertNil(HarnessFaultLogLedger.parse(entryName: "jscrash-com.example-20010057"))
    XCTAssertNil(
      HarnessFaultLogLedger.parse(entryName: "jscrash-com.example-20010057-2026073116"))
  }
}

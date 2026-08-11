// Observed state from real bytes (CHG-2026-054, TASK-HTP-002).
//
// Every measurement here comes from bytes the harness read and hashed. The
// order is deliberate: verify first, measure second. An artifact that is
// absent, empty, larger than the evaluation read bound, or whose SHA-256
// does not match what the store recorded produces a *blocker*, never a
// measurement - so "we could not read the evidence" can never look like
// "the evidence says it is fixed" (CHG-2026-049's lesson, where a failed
// capture still published a complete-looking downstream artifact).
//
// Integrity blockers (hash mismatch, unreadable) and collection blockers
// (absent, empty, oversize) are kept apart because they escalate
// differently: the first is an ERROR that needs a human, the second is
// INCONCLUSIVE that another round may fix.
//
// Crashes are judged from the device's Faultlogger ledger, not from hilog
// (CHG-2026-055, TASK-HFA-001). TASK-HTP-002 scanned `hilog.txt` for
// cppcrash fault blocks against the documented OpenHarmony shape, with
// fixtures hand-written to that shape and labelled as such. TASK-HTP-006's
// r6 window disproved it on real hardware: after a real crash, 887 KB of
// `hilog -x` carried zero fault blocks, because the detail is in
// Faultlogger. HiLog is diagnostic context only; the typed application
// readback owns liveness and the ledger owns crash counting - one source
// per question, so one crash cannot be counted twice.

import ArkDeckCore
import ArkDeckRuntime
import CryptoKit
import Foundation

private struct HarnessVerifiedArtifact {
  let jobID: String
  let descriptor: HarnessArtifactDescriptor
  let data: Data

  var name: String { descriptor.name }
  var mediaType: String { descriptor.mediaType }
}

private struct HarnessApplicationLivenessArtifact: Decodable {
  struct ObservationWindow: Decodable {
    let startedAtUTC: String
    let endedAtUTC: String

    enum CodingKeys: String, CodingKey {
      case startedAtUTC = "startedAtUtc"
      case endedAtUTC = "endedAtUtc"
    }
  }

  let documentType: String
  let schemaVersion: String
  let applicationRef: String
  let state: String
  let reasonCode: String
  let processState: String
  let pidObserved: Bool
  let targetBindingRevision: Int?
  let deployedArtifactDigest: String?
  let sourceRuntimeJobID: String
  let sourceOperationRef: String
  let observedAtUTC: String
  let observationWindow: ObservationWindow

  enum CodingKeys: String, CodingKey {
    case documentType, schemaVersion, applicationRef, state, reasonCode, processState
    case pidObserved, targetBindingRevision, deployedArtifactDigest, sourceOperationRef
    case observationWindow
    case sourceRuntimeJobID = "sourceRuntimeJobId"
    case observedAtUTC = "observedAtUtc"
  }
}

package struct HarnessCrashSignature: Equatable, Sendable {
  /// The ledger entry's kind (`cppcrash`, `jscrash`, `appfreeze`, …). Kept
  /// because the kinds carry different judging fields, and because a
  /// signature rendered without it reads as a native crash whatever it was.
  public let kind: String
  /// The fault's reason token: a signal for `cppcrash`, an error name for
  /// `jscrash`. Never fabricated - an entry with no reason yields no
  /// signature at all.
  package let signal: String
  package let topFrame: String?
  package let blockText: String

  public init(kind: String, signal: String, topFrame: String?, blockText: String) {
    self.kind = kind
    self.signal = signal
    self.topFrame = topFrame
    self.blockText = blockText
  }

  public var rendered: String {
    guard let topFrame else { return "\(kind):\(signal)" }
    return "\(kind):\(signal)+\(topFrame)"
  }
}

package struct HarnessObservationBuilder: Sendable {
  /// Read bound per artifact. Bigger evidence is not silently truncated: it
  /// becomes a blocker, because a hash over a prefix proves nothing.
  package static let defaultEvaluationReadBytes = 1 << 20

  private let artifacts: any HarnessArtifactPort
  private let maximumEvaluationBytes: Int
  /// Artifact *names* an operator has allowed this composition to measure
  /// even though the catalog marks them privacy-sensitive. Empty by default,
  /// which is the only safe default: the evaluator cannot decide to look.
  ///
  /// Why a list rather than a flag: `capture.diagnostics@1` declares
  /// `hilog.txt` both required evidence *and* sensitive, so with no opt-in the
  /// three crash criteria can never be judged and a debug task can only ever
  /// burn its rounds and stop. An operator naming `hilog.txt` says which
  /// evidence may be measured on this host - it does not widen what leaves
  /// it: only digests, byte counts and metrics are recorded, and the decision
  /// context still carries artifact identity without content
  /// (TASK-HTP-004).
  private let sensitiveEvidenceAllowList: Set<String>

  public init(
    artifacts: any HarnessArtifactPort,
    maximumEvaluationBytes: Int = HarnessObservationBuilder.defaultEvaluationReadBytes,
    sensitiveEvidenceAllowList: Set<String> = []
  ) {
    self.artifacts = artifacts
    self.maximumEvaluationBytes = maximumEvaluationBytes
    self.sensitiveEvidenceAllowList = sensitiveEvidenceAllowList
  }

  /// Artifact names `capture.diagnostics@1` publishes for the crash ledger.
  package static let crashIndexArtifact = "crash-index.txt"
  package static let crashLogArtifact = "crash-log.txt"
  package static let applicationLivenessArtifact = "application-liveness.json"
  /// Measurement key carrying the device-local timestamp this task has
  /// already accounted for. See `measureCrashLedger` for why it exists.
  package static let watermarkMetric = "crashLedgerWatermark"
  /// Measurement key carrying the newest un-accounted entry's name, which
  /// is what the next round passes as `crashLogName` to fetch its body.
  package static let latestEntryMetric = "latestCrashEntryName"

  package func observe(
    round: Int,
    jobID: String,
    declaredCrashSignature: String?,
    requiredEvidence: Set<String>,
    crashLedgerWatermark: String? = nil,
    sourceEvidenceJobID: String? = nil,
    expectedSourceArtifactID: String? = nil,
    expectedBindingRevision: Int? = nil,
    expectedDeployedArtifactDigest: String? = nil
  ) async throws -> HarnessRoundObservation {
    var jobIDs = [jobID]
    if let sourceEvidenceJobID, sourceEvidenceJobID != jobID {
      jobIDs.insert(sourceEvidenceJobID, at: 0)
    }
    var inventory: [(jobID: String, descriptor: HarnessArtifactDescriptor)] = []
    for candidate in jobIDs {
      do {
        inventory.append(
          contentsOf: try await artifacts.inventory(jobID: candidate).map { (candidate, $0) })
      } catch {
        return HarnessRoundObservation(
          round: round, collectionBlockers: ["artifactInventoryUnavailable:\(candidate)"])
      }
    }

    var evidence: [HarnessEvidenceRecord] = []
    var integrityBlockers: [String] = []
    var collectionBlockers: [String] = []
    var verifiedBytes: [HarnessVerifiedArtifact] = []

    for item in inventory {
      let descriptor = item.descriptor
      if !descriptor.published {
        let blocker = "artifactMissing:\(descriptor.name):\(descriptor.missingReason ?? "unknown")"
        collectionBlockers.append(blocker)
        evidence.append(record(descriptor, verified: false, blocker: blocker))
        continue
      }
      let sensitiveOptIn = descriptor.sensitive
        && sensitiveEvidenceAllowList.contains(descriptor.name)
      if descriptor.sensitive, !sensitiveOptIn {
        // No operator named this artifact, so the evaluator does not look:
        // report it rather than pretend the evidence was considered.
        let blocker = "artifactSensitiveNotOptedIn:\(descriptor.name)"
        collectionBlockers.append(blocker)
        evidence.append(record(descriptor, verified: false, blocker: blocker))
        continue
      }
      if descriptor.byteCount == 0 {
        let blocker = "artifactEmpty:\(descriptor.name)"
        collectionBlockers.append(blocker)
        evidence.append(
          record(descriptor, verified: false, blocker: blocker, sensitiveOptIn: sensitiveOptIn))
        continue
      }
      if descriptor.byteCount > maximumEvaluationBytes {
        let blocker =
          "artifactExceedsEvaluationBound:\(descriptor.name):"
          + "\(descriptor.byteCount)>\(maximumEvaluationBytes)"
        collectionBlockers.append(blocker)
        evidence.append(
          record(descriptor, verified: false, blocker: blocker, sensitiveOptIn: sensitiveOptIn))
        continue
      }
      let data: Data
      do {
        data = try await artifacts.read(
          jobID: item.jobID, artifactID: descriptor.artifactID,
          maximumBytes: maximumEvaluationBytes)
      } catch {
        let blocker = "artifactUnreadable:\(descriptor.name)"
        integrityBlockers.append(blocker)
        evidence.append(
          record(descriptor, verified: false, blocker: blocker, sensitiveOptIn: sensitiveOptIn))
        continue
      }
      let digest = SHA256Hex.string(of: data)
      guard data.count == descriptor.byteCount, digest == descriptor.sha256 else {
        let blocker = "artifactHashMismatch:\(descriptor.name)"
        integrityBlockers.append(blocker)
        evidence.append(
          record(descriptor, verified: false, blocker: blocker, sensitiveOptIn: sensitiveOptIn))
        continue
      }
      evidence.append(
        record(
          descriptor, verified: true, blocker: nil, sensitiveOptIn: sensitiveOptIn,
          jobID: item.jobID))
      verifiedBytes.append(
        HarnessVerifiedArtifact(jobID: item.jobID, descriptor: descriptor, data: data))
    }

    let inventoryNames = Set(inventory.map(\.descriptor.name))
    for required in requiredEvidence.subtracting(inventoryNames).sorted() {
      collectionBlockers.append("artifactNotCollected:\(required)")
    }

    let evidenceJobID = sourceEvidenceJobID ?? jobID
    var (measurements, samples, livenessIntegrity, livenessCollection) =
      measureApplicationLiveness(
        verifiedBytes, evidenceJobID: evidenceJobID,
        expectedBindingRevision: expectedBindingRevision,
        expectedDeployedArtifactDigest: expectedDeployedArtifactDigest)
    integrityBlockers.append(contentsOf: livenessIntegrity)
    collectionBlockers.append(contentsOf: livenessCollection)
    let ledger = measureCrashLedger(
      verifiedBytes, declaredCrashSignature: declaredCrashSignature,
      watermark: crashLedgerWatermark,
      expectedSourceArtifactID: expectedSourceArtifactID)
    measurements.merge(ledger.measurements) { _, new in new }
    samples.merge(ledger.samples) { _, new in new }
    integrityBlockers.append(contentsOf: ledger.integrityBlockers)

    return HarnessRoundObservation(
      round: round,
      measurements: measurements,
      sampleContribution: samples,
      evidence: evidence,
      integrityBlockers: integrityBlockers,
      collectionBlockers: collectionBlockers)
  }

  private func record(
    _ descriptor: HarnessArtifactDescriptor,
    verified: Bool,
    blocker: String?,
    sensitiveOptIn: Bool = false,
    jobID: String? = nil
  ) -> HarnessEvidenceRecord {
    HarnessEvidenceRecord(
      artifactID: descriptor.artifactID, name: descriptor.name,
      byteCount: descriptor.byteCount, sha256: descriptor.sha256, verified: verified,
      blocker: blocker, sensitiveOptIn: sensitiveOptIn, jobID: jobID)
  }

  // MARK: - Measurement

  private func measureApplicationLiveness(
    _ verified: [HarnessVerifiedArtifact],
    evidenceJobID: String,
    expectedBindingRevision: Int?,
    expectedDeployedArtifactDigest: String?
  ) -> (
    measurements: [String: JSONValue], samples: [String: Int],
    integrityBlockers: [String], collectionBlockers: [String]
  ) {
    guard let artifact = verified.first(where: {
      $0.jobID == evidenceJobID && $0.name == Self.applicationLivenessArtifact
    }) else { return ([:], [:], [], []) }
    guard let envelope = try? JSONDecoder().decode(
      HarnessApplicationLivenessArtifact.self, from: artifact.data),
      envelope.documentType == "arkdeck-application-liveness",
      envelope.schemaVersion == "1.0.0",
      envelope.sourceRuntimeJobID == evidenceJobID,
      envelope.sourceOperationRef == "capture.diagnostics@1",
      envelope.applicationRef.utf8.count == 64,
      envelope.applicationRef.utf8.allSatisfy({
        (48...57).contains($0) || (97...102).contains($0)
      }),
      Self.isValidObservationWindow(envelope)
    else {
      return ([:], [:], ["applicationLivenessProvenanceMismatch"], [])
    }
    if let expectedBindingRevision,
      envelope.targetBindingRevision != expectedBindingRevision
    {
      return (
        [:], [:], [],
        ["applicationLivenessBindingRevisionChanged"])
    }
    if let expectedDeployedArtifactDigest,
      envelope.deployedArtifactDigest != expectedDeployedArtifactDigest
    {
      return (
        [:], [:], [],
        ["applicationLivenessDeployedArtifactChanged"])
    }
    switch envelope.state {
    case "HEALTHY":
      guard envelope.processState == "RUNNING", envelope.pidObserved else {
        return ([:], [:], ["applicationLivenessStateContradiction"], [])
      }
      return (
        [
          "verificationRunCount": .integer(1),
          "applicationLiveness": .string("healthy"),
        ],
        ["verificationRunCount": 1, "applicationLiveness": 1], [], [])
    case "UNHEALTHY":
      return (
        [
          "verificationRunCount": .integer(1),
          "applicationLiveness": .string("unhealthy"),
        ],
        ["verificationRunCount": 1, "applicationLiveness": 1], [], [])
    case "UNKNOWN":
      return (
        [:], [:], [],
        ["applicationLivenessUnknown:\(envelope.reasonCode)"])
    default:
      return ([:], [:], ["applicationLivenessStateInvalid"], [])
    }
  }

  private static func isValidObservationWindow(
    _ envelope: HarnessApplicationLivenessArtifact
  ) -> Bool {
    let formatter = ISO8601DateFormatter()
    guard let started = formatter.date(from: envelope.observationWindow.startedAtUTC),
      let ended = formatter.date(from: envelope.observationWindow.endedAtUTC),
      let observed = formatter.date(from: envelope.observedAtUTC)
    else { return false }
    return started <= observed && observed <= ended
  }

  /// Crash counting from the Faultlogger ledger.
  ///
  /// The watermark is the whole design. The ledger is cumulative device
  /// state: a crash from last week is still listed, and a task that counted
  /// the listing directly would report it every round, so
  /// `matchingCrashCount == 0` could never pass and no fix could ever be
  /// confirmed. So the first round with a readable ledger *sets* a
  /// watermark and deliberately contributes no count and no sample - at
  /// that point "since we last looked" has no meaning yet, and reporting
  /// zero would be a claim this round has not earned. Later rounds count
  /// only entries newer than the mark.
  ///
  /// The comparison is device-timestamp against device-timestamp. Entry
  /// timestamps are device-local (`20260731162134` while the host clock
  /// read 08:21 UTC), so seeding the mark from a host clock would be wrong
  /// by whatever the device's offset happens to be.
  private func measureCrashLedger(
    _ verified: [HarnessVerifiedArtifact],
    declaredCrashSignature: String?,
    watermark: String?,
    expectedSourceArtifactID: String?
  ) -> (measurements: [String: JSONValue], samples: [String: Int], integrityBlockers: [String]) {
    guard let index = verified.first(where: { $0.name == Self.crashIndexArtifact }) else {
      // Not collected. The criteria name this artifact, so its absence is
      // already an `artifactNotCollected` blocker upstream and the verdict
      // is inconclusive; measuring zero here would overwrite that with a
      // clean bill of health.
      return ([:], [:], [])
    }
    let entries: [HarnessFaultLogEntry]
    if let derived = verified.first(where: { $0.name == "crash-signature.json" }) {
      guard let envelope = try? JSONDecoder().decode(
        HarnessCrashLedgerDerivedArtifact.self, from: derived.data),
        let analyzerOutput = try? HarnessCrashLedgerDerivedAnalyzer.canonicalData(
          envelope.result),
        envelope.schemaVersion == HarnessCrashLedgerAnalysis.schemaVersion,
        envelope.analyzerRef == HarnessCrashLedgerAnalysis.analyzerRef,
        envelope.analyzerVersion == HarnessCrashLedgerAnalysis.analyzerVersion,
        envelope.result.schemaVersion == HarnessCrashLedgerAnalysis.schemaVersion,
        envelope.result.analyzerRef == envelope.analyzerRef,
        envelope.result.analyzerVersion == envelope.analyzerVersion,
        envelope.sourceArtifactID == index.descriptor.artifactID,
        envelope.sourceSHA256 == index.descriptor.sha256,
        envelope.sourceByteCount == index.descriptor.byteCount,
        envelope.analyzerOutputByteCount == analyzerOutput.count,
        envelope.analyzerOutputSHA256
          == SHA256Hex.string(of: analyzerOutput),
        expectedSourceArtifactID == nil
          || envelope.sourceArtifactID == expectedSourceArtifactID
      else {
        return ([:], [:], ["crashLedgerDerivedArtifactProvenanceMismatch"])
      }
      guard envelope.result.status == .answered else {
        return (
          [:], [:],
          [
            "crashLedgerUnreadable:\(Self.crashIndexArtifact):"
              + (envelope.result.unreadableReason ?? "analyzerUnreadable")
          ])
      }
      entries = envelope.result.entries
    } else {
      // Forward-readable fallback for tasks captured before the analyzer was
      // connected. New production captures always take the branch above.
      guard let text = String(data: index.data, encoding: .utf8) else {
        return ([:], [:], ["crashLedgerUnreadable:\(Self.crashIndexArtifact):invalidEncoding"])
      }
      switch HarnessFaultLogLedger.readIndex(text) {
      case .unreadable(let reason):
        return ([:], [:], ["crashLedgerUnreadable:\(Self.crashIndexArtifact):\(reason)"])
      case .answered(let read):
        entries = read
      }
    }

    let newest = entries.map(\.timestamp).max()
    guard let watermark else {
      var measurements: [String: JSONValue] = [
        "crashLedgerBaselineEntryCount": .integer(Int64(entries.count))
      ]
      // An empty ledger still needs a mark, or the next round would read
      // this one as its baseline too and never start counting.
      measurements[Self.watermarkMetric] = .string(newest ?? "")
      return (measurements, [:], [])
    }

    let fresh = entries.filter { $0.timestamp > watermark }
    // The body of one entry, when the previous round named it. Without it
    // matching falls back to the entry name, which carries kind and bundle
    // but no frames - a coarser answer, never a more permissive one, since
    // an unmatched fresh entry still fails `newFatalSignatureCount == 0`.
    var detail: HarnessCrashSignature?
    if let body = verified.first(where: { $0.name == Self.crashLogArtifact }),
      let bodyText = String(data: body.data, encoding: .utf8),
      let named = fresh.max(by: { $0.timestamp < $1.timestamp })
    {
      detail = HarnessFaultLogLedger.detail(inEntryBody: bodyText, kind: named.kind)
    }

    let newestFresh = fresh.max(by: { $0.timestamp < $1.timestamp })
    var matching = 0
    if let declaredCrashSignature {
      for entry in fresh {
        // The fetched body belongs to the newest fresh entry, so only that
        // one may be judged on frames; the rest are judged on their names.
        let signature =
          entry.name == newestFresh?.name
          ? (detail ?? Self.nameOnlySignature(entry)) : Self.nameOnlySignature(entry)
        if Self.matches(declared: declaredCrashSignature, signature: signature) { matching += 1 }
      }
    }

    var measurements: [String: JSONValue] = [
      "matchingCrashCount": .integer(Int64(matching)),
      "newFatalSignatureCount": .integer(Int64(fresh.count - matching)),
      Self.watermarkMetric: .string(max(watermark, newest ?? watermark)),
    ]
    let samples: [String: Int] = [
      "matchingCrashCount": 1,
      "newFatalSignatureCount": 1,
    ]
    if let latest = newestFresh {
      measurements[Self.latestEntryMetric] = .string(latest.name)
      measurements["latestCrashSignature"] = .string(
        detail?.rendered ?? Self.nameOnlySignature(latest).rendered)
    }
    return (measurements, samples, [])
  }

  /// What an entry can say about itself from its listing line alone: its
  /// kind and the bundle it belongs to, and no frames. Deliberately not a
  /// fabricated signal - an entry whose body was never fetched must not
  /// read downstream as a native crash with a known fault address.
  private static func nameOnlySignature(_ entry: HarnessFaultLogEntry) -> HarnessCrashSignature {
    HarnessCrashSignature(
      kind: entry.kind, signal: entry.bundle, topFrame: nil, blockText: entry.name)
  }

  /// Token containment, not equality: a declared signature such as
  /// `SIGABRT+WaterFlowPattern::RecoverBack` matches a fault block that
  /// mentions every one of its `+`-separated tokens. Equality on a formatted
  /// signature string would break on any frame-offset or library-path
  /// difference between runs.
  public static func matches(declared: String, signature: HarnessCrashSignature) -> Bool {
    let haystack = (signature.rendered + "\n" + signature.blockText).lowercased()
    let tokens = declared.split(separator: "+").map {
      $0.trimmingCharacters(in: .whitespaces).lowercased()
    }.filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return false }
    return tokens.allSatisfy { haystack.contains($0) }
  }

}

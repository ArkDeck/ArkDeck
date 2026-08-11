// Evaluation model: the only path to success (CHG-2026-054, TASK-HTP-002).
//
// A task becomes `succeeded` when, and only when, an evaluation says every
// mandatory criterion passed on evidence the harness verified byte for byte.
// Three consequences are deliberate:
//
//   * a task with no mandatory criteria evaluates to INCONCLUSIVE, never
//     PASS. "Nothing to check" is not a fix;
//   * INCONCLUSIVE is never success. It buys another round if the budget
//     allows, or it stops for a human;
//   * an evidence integrity problem (hash mismatch, unreadable bytes) is
//     ERROR, not FAIL - "we could not tell" and "it is broken" are
//     different answers and only one of them is about the product.
//
// Everything here is pure. Reading artifacts is the port's job
// (HarnessArtifactPort); deriving measurements is the observation
// builder's; this file only says what the numbers mean.

import ArkDeckCore
import Foundation

package enum HarnessEvaluationVerdict: String, CaseIterable, Codable, Sendable {
  case pass
  case fail
  case inconclusive
  case error
}

package enum HarnessInconclusivePolicy: String, CaseIterable, Codable, Sendable {
  /// Spend another round collecting evidence, budget permitting.
  case collectMoreEvidence
  /// Stop and ask a human; more of the same evidence will not decide it.
  case requestHuman
  /// Treat as a failed task.
  case failTask
}

/// How a metric accumulates across rounds. Declared per metric so the
/// merge is a table, not a guess at the call site.
package enum HarnessMetricKind: String, CaseIterable, Codable, Sendable {
  /// Summed across rounds: crash counts, fatal counts.
  case counter
  /// Replaced by the newest observation: liveness, latest signature.
  case latest
}

package struct HarnessCriterionResult: Equatable, Sendable, Codable {
  package let criterionID: String
  public let verdict: HarnessEvaluationVerdict
  package let metric: String
  public let observed: JSONValue?
  public let expected: JSONValue
  package let samples: Int
  package let requiredSamples: Int
  public let blockers: [String]

  enum CodingKeys: String, CodingKey {
    case criterionID = "criterionId"
    case verdict
    case metric
    case observed
    case expected
    case samples
    case requiredSamples
    case blockers
  }

  public init(
    criterionID: String,
    verdict: HarnessEvaluationVerdict,
    metric: String,
    observed: JSONValue?,
    expected: JSONValue,
    samples: Int,
    requiredSamples: Int,
    blockers: [String]
  ) {
    self.criterionID = criterionID
    self.verdict = verdict
    self.metric = metric
    self.observed = observed
    self.expected = expected
    self.samples = samples
    self.requiredSamples = requiredSamples
    self.blockers = blockers
  }
}

/// One verified artifact as the evaluator sees it. `verified` means the
/// bytes were read in full and their SHA-256 matched what the artifact
/// store recorded - not that a file exists.
package struct HarnessEvidenceRecord: Equatable, Sendable, Codable {
  public let artifactID: String
  public let name: String
  public let byteCount: Int
  public let sha256: String
  public let verified: Bool
  public let blocker: String?
  /// True when this artifact is privacy-sensitive and was measured only
  /// because an operator named it in the run's opt-in. It is recorded so a
  /// maintainer can tell "the evaluator never saw these bytes" from "an
  /// operator allowed the evaluator to measure them", which are different
  /// claims about the same digest.
  package let sensitiveOptIn: Bool
  /// The job whose artifact store holds these bytes. Recorded so a later
  /// reader — the decision context, which must show a model the evidence it
  /// is reasoning about — can address the artifact without guessing which
  /// round produced it.
  public let jobID: String?

  enum CodingKeys: String, CodingKey {
    case artifactID = "artifactId"
    case name
    case byteCount
    case sha256
    case verified
    case blocker
    case sensitiveOptIn
    case jobID = "jobId"
  }

  public init(
    artifactID: String,
    name: String,
    byteCount: Int,
    sha256: String,
    verified: Bool,
    blocker: String? = nil,
    sensitiveOptIn: Bool = false,
    jobID: String? = nil
  ) {
    self.artifactID = artifactID
    self.name = name
    self.byteCount = byteCount
    self.sha256 = sha256
    self.verified = verified
    self.blocker = blocker
    self.sensitiveOptIn = sensitiveOptIn
    self.jobID = jobID
  }

  /// Records written before the opt-in existed carry no flag; decoding them
  /// as "not opted in" is the truthful reading, since at the time nothing
  /// could be.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    artifactID = try container.decode(String.self, forKey: .artifactID)
    name = try container.decode(String.self, forKey: .name)
    byteCount = try container.decode(Int.self, forKey: .byteCount)
    sha256 = try container.decode(String.self, forKey: .sha256)
    verified = try container.decode(Bool.self, forKey: .verified)
    blocker = try container.decodeIfPresent(String.self, forKey: .blocker)
    sensitiveOptIn =
      try container.decodeIfPresent(Bool.self, forKey: .sensitiveOptIn) ?? false
    jobID = try container.decodeIfPresent(String.self, forKey: .jobID)
  }
}

/// What one round observed. `sampleContribution` is how many samples this
/// round adds per metric: a round whose evidence failed verification
/// contributes none, which is why a corrupt capture cannot help a
/// minimum-samples criterion pass.
package struct HarnessRoundObservation: Equatable, Sendable, Codable {
  public let round: Int
  package let measurements: [String: JSONValue]
  package let sampleContribution: [String: Int]
  public let evidence: [HarnessEvidenceRecord]
  package let integrityBlockers: [String]
  package let collectionBlockers: [String]

  public init(
    round: Int,
    measurements: [String: JSONValue] = [:],
    sampleContribution: [String: Int] = [:],
    evidence: [HarnessEvidenceRecord] = [],
    integrityBlockers: [String] = [],
    collectionBlockers: [String] = []
  ) {
    self.round = round
    self.measurements = measurements
    self.sampleContribution = sampleContribution
    self.evidence = evidence
    self.integrityBlockers = integrityBlockers
    self.collectionBlockers = collectionBlockers
  }

  package var verifiedEvidenceNames: Set<String> {
    Set(evidence.filter(\.verified).map(\.name))
  }
}

/// Cumulative observed state, and the only writer of it is an observation
/// or an evaluation (enforced by the reducer). A decision cannot describe
/// the world into existence.
package struct HarnessObservedState: Equatable, Sendable, Codable {
  package static let measurementsKey = "measurements"
  package static let samplesKey = "samples"
  package static let verdictKey = "latestVerdict"
  package static let blockersKey = "blockers"
  package static let evidenceNamesKey = "latestVerifiedEvidence"

  package let measurements: [String: JSONValue]
  package let samples: [String: Int]
  package let latestVerdict: HarnessEvaluationVerdict?
  public let blockers: [String]
  package let latestVerifiedEvidence: [String]

  public init(
    measurements: [String: JSONValue] = [:],
    samples: [String: Int] = [:],
    latestVerdict: HarnessEvaluationVerdict? = nil,
    blockers: [String] = [],
    latestVerifiedEvidence: [String] = []
  ) {
    self.measurements = measurements
    self.samples = samples
    self.latestVerdict = latestVerdict
    self.blockers = blockers
    self.latestVerifiedEvidence = latestVerifiedEvidence
  }

  /// Metric accumulation table. Anything not listed is `latest`: adding a
  /// metric never silently turns into summation.
  public static func kind(of metric: String) -> HarnessMetricKind {
    switch metric {
    case "matchingCrashCount", "newFatalSignatureCount", "verificationRunCount":
      return .counter
    default:
      return .latest
    }
  }

  package func merging(_ observation: HarnessRoundObservation) -> HarnessObservedState {
    var mergedMeasurements = measurements
    for (metric, value) in observation.measurements {
      switch Self.kind(of: metric) {
      case .counter:
        let previous = Self.integer(measurements[metric]) ?? 0
        let increment = Self.integer(value) ?? 0
        mergedMeasurements[metric] = .integer(Int64(previous + increment))
      case .latest:
        mergedMeasurements[metric] = value
      }
    }
    var mergedSamples = samples
    for (metric, contribution) in observation.sampleContribution where contribution > 0 {
      mergedSamples[metric] = (samples[metric] ?? 0) + contribution
    }
    return HarnessObservedState(
      measurements: mergedMeasurements,
      samples: mergedSamples,
      latestVerdict: latestVerdict,
      blockers: observation.integrityBlockers + observation.collectionBlockers,
      latestVerifiedEvidence: observation.verifiedEvidenceNames.sorted())
  }

  package func recording(verdict: HarnessEvaluationVerdict, blockers: [String]) -> HarnessObservedState
  {
    HarnessObservedState(
      measurements: measurements, samples: samples, latestVerdict: verdict,
      blockers: blockers, latestVerifiedEvidence: latestVerifiedEvidence)
  }

  static func integer(_ value: JSONValue?) -> Int? {
    switch value {
    case .integer(let number): return Int(number)
    case .unsignedInteger(let number): return Int(number)
    case .number(let number): return Int(number)
    default: return nil
    }
  }

  /// Projection into the task snapshot's free-form observed state. Keeping
  /// one encoder here means the wire shape cannot drift between writer and
  /// reader.
  package var asJSON: [String: JSONValue] {
    var fields: [String: JSONValue] = [
      Self.measurementsKey: .object(measurements),
      Self.samplesKey: .object(samples.mapValues { .integer(Int64($0)) }),
      Self.blockersKey: .array(blockers.map(JSONValue.string)),
      Self.evidenceNamesKey: .array(latestVerifiedEvidence.map(JSONValue.string)),
    ]
    if let latestVerdict {
      fields[Self.verdictKey] = .string(latestVerdict.rawValue)
    }
    return fields
  }

  public init(json: [String: JSONValue]) {
    var measurements: [String: JSONValue] = [:]
    if case .object(let fields)? = json[Self.measurementsKey] { measurements = fields }
    var samples: [String: Int] = [:]
    if case .object(let fields)? = json[Self.samplesKey] {
      for (metric, value) in fields {
        if let count = HarnessObservedState.integer(value) { samples[metric] = count }
      }
    }
    var verdict: HarnessEvaluationVerdict?
    if case .string(let raw)? = json[Self.verdictKey] {
      verdict = HarnessEvaluationVerdict(rawValue: raw)
    }
    var blockers: [String] = []
    if case .array(let entries)? = json[Self.blockersKey] {
      blockers = entries.compactMap { if case .string(let text) = $0 { return text } else { return nil } }
    }
    var evidence: [String] = []
    if case .array(let entries)? = json[Self.evidenceNamesKey] {
      evidence = entries.compactMap { if case .string(let text) = $0 { return text } else { return nil } }
    }
    self.init(
      measurements: measurements, samples: samples, latestVerdict: verdict, blockers: blockers,
      latestVerifiedEvidence: evidence)
  }
}

package struct HarnessEvaluation: Equatable, Sendable, Codable {
  public static let documentType = "harness-evaluation"
  public static let schemaVersion = "1.0.0"

  public let documentType: String
  public let schemaVersion: String
  package let evaluationID: String
  package let htaskID: String
  public let round: Int
  public let verdict: HarnessEvaluationVerdict
  package let criterionResults: [HarnessCriterionResult]
  package let measurements: [String: JSONValue]
  package let samples: [String: Int]
  public let evidence: [HarnessEvidenceRecord]
  public let blockers: [String]
  public let createdAtUTC: String

  enum CodingKeys: String, CodingKey {
    case documentType
    case schemaVersion
    case evaluationID = "evaluationId"
    case htaskID = "htaskId"
    case round
    case verdict
    case criterionResults
    case measurements
    case samples
    case evidence
    case blockers
    case createdAtUTC = "createdAtUtc"
  }

  public init(
    evaluationID: String,
    htaskID: String,
    round: Int,
    verdict: HarnessEvaluationVerdict,
    criterionResults: [HarnessCriterionResult],
    measurements: [String: JSONValue],
    samples: [String: Int],
    evidence: [HarnessEvidenceRecord],
    blockers: [String],
    createdAtUTC: String
  ) {
    self.documentType = Self.documentType
    self.schemaVersion = Self.schemaVersion
    self.evaluationID = evaluationID
    self.htaskID = htaskID
    self.round = round
    self.verdict = verdict
    self.criterionResults = criterionResults
    self.measurements = measurements
    self.samples = samples
    self.evidence = evidence
    self.blockers = blockers
    self.createdAtUTC = createdAtUTC
  }
}

/// The criteria evaluator. Pure: criteria plus observed state in, verdict
/// out. No clock, no store, no port - so a replay of the same evidence
/// always produces the same answer.
package enum HarnessCriteriaEvaluator {
  public static func evaluate(
    criteria: [HarnessSuccessCriterion],
    observed: HarnessObservedState,
    round: HarnessRoundObservation,
    evaluationID: String,
    htaskID: String,
    nowUTC: String
  ) -> HarnessEvaluation {
    var results: [HarnessCriterionResult] = []
    for criterion in criteria {
      results.append(
        result(for: criterion, observed: observed, round: round))
    }
    let mandatory = results.enumerated().filter { criteria[$0.offset].mandatory }.map(\.element)
    let verdict: HarnessEvaluationVerdict
    if mandatory.isEmpty {
      // Nothing mandatory to check is not a pass. A task must declare what
      // "fixed" means before the harness can ever say it.
      verdict = .inconclusive
    } else if mandatory.contains(where: { $0.verdict == .error }) {
      verdict = .error
    } else if mandatory.contains(where: { $0.verdict == .fail }) {
      verdict = .fail
    } else if mandatory.contains(where: { $0.verdict == .inconclusive }) {
      verdict = .inconclusive
    } else {
      verdict = .pass
    }
    return HarnessEvaluation(
      evaluationID: evaluationID,
      htaskID: htaskID,
      round: round.round,
      verdict: verdict,
      criterionResults: results,
      measurements: observed.measurements,
      samples: observed.samples,
      evidence: round.evidence,
      blockers: round.integrityBlockers + round.collectionBlockers,
      createdAtUTC: nowUTC)
  }

  /// The strictest inconclusive policy among criteria that came back
  /// inconclusive; nil when nothing was inconclusive.
  package static func escalation(
    for evaluation: HarnessEvaluation,
    criteria: [HarnessSuccessCriterion]
  ) -> HarnessInconclusivePolicy? {
    let inconclusiveIDs = Set(
      evaluation.criterionResults.filter { $0.verdict == .inconclusive }.map(\.criterionID))
    let policies = criteria.filter { inconclusiveIDs.contains($0.criterionID) }
      .map(\.inconclusivePolicy)
    if policies.contains(.failTask) { return .failTask }
    if policies.contains(.requestHuman) { return .requestHuman }
    if policies.contains(.collectMoreEvidence) { return .collectMoreEvidence }
    return nil
  }

  private static func result(
    for criterion: HarnessSuccessCriterion,
    observed: HarnessObservedState,
    round: HarnessRoundObservation
  ) -> HarnessCriterionResult {
    var blockers: [String] = []
    let value = observed.measurements[criterion.metric]
    let samples = observed.samples[criterion.metric] ?? 0

    // Integrity first: bytes that did not verify cannot support any verdict
    // about the product, in either direction.
    let integrity = round.integrityBlockers.filter { blocker in
      criterion.evidenceRequirements.contains { blocker.contains($0) }
    }
    if !integrity.isEmpty {
      return HarnessCriterionResult(
        criterionID: criterion.criterionID, verdict: .error, metric: criterion.metric,
        observed: value, expected: criterion.expected, samples: samples,
        requiredSamples: criterion.minimumSamples, blockers: integrity)
    }

    let missingEvidence = criterion.evidenceRequirements.filter {
      !round.verifiedEvidenceNames.contains($0)
    }
    if !missingEvidence.isEmpty {
      blockers.append("missingVerifiedEvidence:\(missingEvidence.sorted().joined(separator: ","))")
    }
    if samples < criterion.minimumSamples {
      blockers.append("insufficientSamples:\(samples)/\(criterion.minimumSamples)")
    }
    if value == nil {
      blockers.append("metricNotObserved:\(criterion.metric)")
    }
    if !blockers.isEmpty {
      return HarnessCriterionResult(
        criterionID: criterion.criterionID, verdict: .inconclusive, metric: criterion.metric,
        observed: value, expected: criterion.expected, samples: samples,
        requiredSamples: criterion.minimumSamples, blockers: blockers)
    }

    let matched = compare(value!, criterion.comparator, criterion.expected)
    return HarnessCriterionResult(
      criterionID: criterion.criterionID, verdict: matched ? .pass : .fail,
      metric: criterion.metric, observed: value, expected: criterion.expected,
      samples: samples, requiredSamples: criterion.minimumSamples, blockers: [])
  }

  private static func compare(
    _ observed: JSONValue,
    _ comparator: HarnessCriterionComparator,
    _ expected: JSONValue
  ) -> Bool {
    switch comparator {
    case .equalTo:
      return observed == expected
    case .atMost:
      guard let left = numeric(observed), let right = numeric(expected) else { return false }
      return left <= right
    case .atLeast:
      guard let left = numeric(observed), let right = numeric(expected) else { return false }
      return left >= right
    case .absent:
      if case .null = observed { return true }
      if case .array(let entries) = observed { return entries.isEmpty }
      if case .string(let text) = observed { return text.isEmpty }
      if let count = numeric(observed) { return count == 0 }
      return false
    case .matches:
      guard case .string(let text) = observed, case .string(let pattern) = expected else {
        return false
      }
      return text.contains(pattern)
    }
  }

  private static func numeric(_ value: JSONValue) -> Double? {
    switch value {
    case .integer(let number): return Double(number)
    case .unsignedInteger(let number): return Double(number)
    case .number(let number): return number
    default: return nil
    }
  }
}

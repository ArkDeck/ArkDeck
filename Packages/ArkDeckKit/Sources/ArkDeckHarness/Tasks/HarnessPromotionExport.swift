// Promotion export projection (TASK-AIN-019).
//
// A recorded HarnessPromotionCandidate is READY_FOR_NORMAL_PR documentation:
// the maintainer, not the harness, turns it into a normal PR. This file
// renders that document bundle from persisted facts alone, so `task.promotion`
// can serve it without a second copy of any fact. It is a read-only
// projection - nothing here can push a branch, create a commit or merge
// anything, and the disposition it exports never changes
// (docs/ArchitectureRules.md §3: promotion artifacts are documents, never a
// merge claim).

import ArkDeckCore
import Foundation

public enum HarnessPromotionExportError: Error, Equatable, Sendable {
  /// The task has no recorded promotion candidate to export.
  case promotionNotRecorded(String)
  /// Persisted facts no longer agree with each other. Export refuses to
  /// guess which side is true.
  case inconsistentFacts(String)
  /// The immutable diff the candidate metadata names is absent or no longer
  /// hashes to `diffDigest`. A bundle without the exact candidate bytes is
  /// not the promotion.
  case diffUnavailable(String)
}

package struct HarnessPromotionExportFile: Equatable, Sendable {
  package let name: String
  package let contents: String
}

package struct HarnessPromotionExportBundle: Equatable, Sendable {
  package let htaskID: String
  package let attemptID: String
  package let promotion: HarnessPromotionCandidate
  package let candidate: HarnessCandidatePatch
  package let evaluation: HarnessEvaluation
  package let unifiedDiff: String
  package let files: [HarnessPromotionExportFile]
}

package enum HarnessPromotionExport {
  package static let summaryFileName = "PROMOTION.md"
  package static let patchFileName = "final.patch"
  package static let promotionFileName = "promotion-candidate.json"
  package static let candidateFileName = "candidate-patch.json"
  package static let evaluationFileName = "evaluation.json"
  package static let manifestFileName = "artifacts.json"

  package static func assemble(
    snapshot: HarnessTaskSnapshot,
    attempts: [HarnessAttempt],
    evaluations: [HarnessEvaluation]
  ) throws -> HarnessPromotionExportBundle {
    let promoted = attempts.filter { $0.promotionCandidate != nil }
    guard promoted.count <= 1 else {
      throw HarnessPromotionExportError.inconsistentFacts("multiplePromotionCandidates")
    }
    guard let attempt = promoted.first, let promotion = attempt.promotionCandidate else {
      throw HarnessPromotionExportError.promotionNotRecorded(snapshot.htaskID)
    }
    guard promotion.htaskID == snapshot.htaskID, attempt.htaskID == snapshot.htaskID,
      promotion.attemptID == attempt.attemptID
    else { throw HarnessPromotionExportError.inconsistentFacts("promotionIdentity") }
    guard let candidate = attempt.candidatePatch,
      candidate.candidatePatchID == promotion.candidatePatchID,
      candidate.htaskID == snapshot.htaskID,
      candidate.attemptID == attempt.attemptID,
      candidate.baseRevision == promotion.baseRevision
    else { throw HarnessPromotionExportError.inconsistentFacts("candidatePatch") }
    guard
      let evaluation = evaluations.first(where: {
        $0.evaluationID == promotion.evaluationID
      }),
      evaluation.htaskID == snapshot.htaskID,
      evaluation.verdict == .pass
    else { throw HarnessPromotionExportError.inconsistentFacts("evaluation") }
    // The exact candidate bytes are carried by the live repair attempt and
    // named by the candidate metadata digest. Absence or a mismatch is an
    // integrity stop, never an export with substitute bytes.
    guard let unifiedDiff = snapshot.repairAttempt?.proposal.unifiedDiff,
      candidate.namesDiff(unifiedDiff)
    else {
      throw HarnessPromotionExportError.diffUnavailable(
        "the immutable diff named by candidate \(candidate.candidatePatchID) "
          + "(sha256 \(candidate.diffDigest)) is not available to export")
    }

    let files = [
      HarnessPromotionExportFile(
        name: summaryFileName,
        contents: summaryMarkdown(
          snapshot: snapshot, attempt: attempt, promotion: promotion,
          candidate: candidate, evaluation: evaluation)),
      HarnessPromotionExportFile(name: patchFileName, contents: unifiedDiff),
      HarnessPromotionExportFile(
        name: promotionFileName, contents: try prettyJSON(promotion)),
      HarnessPromotionExportFile(
        name: candidateFileName, contents: try prettyJSON(candidate)),
      HarnessPromotionExportFile(
        name: evaluationFileName, contents: try prettyJSON(evaluation)),
      HarnessPromotionExportFile(
        name: manifestFileName,
        contents: try prettyJSON(
          artifactManifest(
            promotion: promotion, candidate: candidate, attempt: attempt,
            evaluation: evaluation))),
    ]
    return HarnessPromotionExportBundle(
      htaskID: snapshot.htaskID, attemptID: attempt.attemptID, promotion: promotion,
      candidate: candidate, evaluation: evaluation,
      unifiedDiff: unifiedDiff, files: files)
  }

  /// Reference manifest for every Artifact the promotion names. Bytes stay
  /// in the daemon Artifact store; entries carry the roles the harness can
  /// prove and, where the evaluation measured the Artifact, the recorded
  /// name, size and digest.
  static func artifactManifest(
    promotion: HarnessPromotionCandidate,
    candidate: HarnessCandidatePatch,
    attempt: HarnessAttempt,
    evaluation: HarnessEvaluation
  ) -> JSONValue {
    let entries = promotion.artifactIDs.map { artifactID -> JSONValue in
      var roles: [String] = []
      if artifactID == candidate.diffArtifactID { roles.append("diff") }
      if artifactID == candidate.metadataArtifactID { roles.append("candidateMetadata") }
      if attempt.buildArtifactIDs.contains(artifactID) { roles.append("build") }
      if attempt.runtimeArtifactIDs.contains(artifactID) { roles.append("runtimeEvidence") }
      if roles.isEmpty { roles = ["taskReference"] }
      var entry: [String: JSONValue] = [
        "artifactId": .string(artifactID),
        "roles": .array(roles.map(JSONValue.string)),
      ]
      if let evidence = evaluation.evidence.first(where: { $0.artifactID == artifactID }) {
        entry["name"] = .string(evidence.name)
        entry["byteCount"] = .integer(Int64(evidence.byteCount))
        entry["sha256"] = .string(evidence.sha256)
        entry["verified"] = .bool(evidence.verified)
        entry["sensitiveOptIn"] = .bool(evidence.sensitiveOptIn)
      }
      return .object(entry)
    }
    return .object([
      "documentType": .string("harness-promotion-artifact-manifest"),
      "schemaVersion": .string("1.0.0"),
      "htaskId": .string(promotion.htaskID),
      "promotionCandidateId": .string(promotion.promotionCandidateID),
      "artifacts": .array(entries),
    ])
  }

  // MARK: - Rendering

  private static func summaryMarkdown(
    snapshot: HarnessTaskSnapshot,
    attempt: HarnessAttempt,
    promotion: HarnessPromotionCandidate,
    candidate: HarnessCandidatePatch,
    evaluation: HarnessEvaluation
  ) -> String {
    var lines: [String] = []
    lines.append("# Promotion candidate \(promotion.promotionCandidateID)")
    lines.append("")
    lines.append(
      "Harness task `\(snapshot.htaskID)` closed with a promotion candidate: scope,")
    lines.append(
      "build, tests, device verification and evaluation all")
    lines.append("passed on attempt `\(attempt.attemptID)`.")
    lines.append("")
    lines.append("- Disposition: `\(promotion.disposition)`")
    lines.append(
      "- This bundle is documentation for a maintainer-authored PR. Promotion is")
    lines.append(
      "  never a merge claim; nothing in it can push a branch, create a commit or")
    lines.append("  merge code (docs/ArchitectureRules.md §3).")
    lines.append("- Goal: \(cell(snapshot.goal.summary))")
    lines.append("- Target: `\(snapshot.target.targetID)`")
    lines.append("- Project: `\(snapshot.projectRef ?? "-")`")
    lines.append("- Recorded (UTC): \(promotion.createdAtUTC)")
    lines.append("")
    lines.append("## Patch")
    lines.append("")
    lines.append("- Apply `\(patchFileName)` (sha256 `\(candidate.diffDigest)`) onto base")
    lines.append("  revision `\(promotion.baseRevision)`; the verified workspace revision")
    lines.append("  after the patch was `\(promotion.workspaceRevision)`.")
    lines.append("- Created by: \(candidate.createdBy.rawValue)")
    lines.append(
      "- Changed lines: \(candidate.changedLines) across "
        + "\(candidate.files.count) file(s):")
    for file in candidate.files {
      lines.append("  - `\(file)`")
    }
    lines.append(
      "- Diff Artifact: `\(candidate.diffArtifactID)`; candidate metadata Artifact:")
    lines.append(
      "  `\(candidate.metadataArtifactID ?? "-")` (document: `\(candidateFileName)`)")
    lines.append("")
    lines.append("## Evaluation")
    lines.append("")
    lines.append(
      "`\(evaluation.evaluationID)` (round \(evaluation.round)) verdict: "
        + "**\(evaluation.verdict.rawValue)**")
    lines.append("")
    lines.append("| Criterion | Verdict | Metric | Observed | Expected | Samples |")
    lines.append("|---|---|---|---|---|---|")
    for result in evaluation.criterionResults {
      lines.append(
        "| \(cell(result.criterionID)) | \(result.verdict.rawValue) "
          + "| \(cell(result.metric)) | \(cell(compactJSON(result.observed))) "
          + "| \(cell(compactJSON(result.expected))) "
          + "| \(result.samples)/\(result.requiredSamples) |")
    }
    lines.append("")
    lines.append("Verified evidence:")
    lines.append("")
    lines.append("| Artifact | Name | Bytes | SHA-256 | Verified |")
    lines.append("|---|---|---|---|---|")
    for evidence in evaluation.evidence {
      lines.append(
        "| `\(cell(evidence.artifactID))` | \(cell(evidence.name)) "
          + "| \(evidence.byteCount) | `\(cell(evidence.sha256))` "
          + "| \(evidence.verified) |")
    }
    lines.append("")
    lines.append("## Artifact references")
    lines.append("")
    lines.append(
      "\(promotion.artifactIDs.count) Artifact reference(s) travel with this")
    lines.append(
      "candidate; bytes stay in the daemon Artifact store. `\(manifestFileName)`")
    lines.append("carries the machine-readable manifest.")
    lines.append("")
    for artifactID in promotion.artifactIDs {
      lines.append("- `\(artifactID)`")
    }
    lines.append("")
    return lines.joined(separator: "\n")
  }

  /// Markdown table cells stay one-line and never open a column boundary.
  private static func cell(_ value: String) -> String {
    value
      .replacingOccurrences(of: "|", with: "\\|")
      .replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
  }

  private static func compactJSON(_ value: JSONValue?) -> String {
    guard let value else { return "-" }
    let encoder = CanonicalJSONEncoders.canonical()
    guard let data = try? encoder.encode(value) else { return "-" }
    return String(decoding: data, as: UTF8.self)
  }

  private static func prettyJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = CanonicalJSONEncoders.canonicalPretty()
    return String(decoding: try encoder.encode(value), as: UTF8.self) + "\n"
  }
}

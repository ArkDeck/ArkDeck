// The Codex-CLI adversarial reviewer for the Harness Evolution path.
//
// This is the production conformer of `HarnessAdversarialReviewing` — the
// independent second AI role the promotion gate requires. Like the Rockchip
// campaign adapters next to it, it lives in the composition target because it
// speaks to a model through a process transport; the protocol and every
// verdict consumer stay in ArkDeckHarness. The reviewer holds no workspace,
// Runtime, device, repair or authority port: it reads the immutable diff and
// evidence in the request and can only answer with a closed verdict document.

import ArkDeckCore
import ArkDeckHarness
import CryptoKit
import Foundation

public enum HarnessCLIAdversarialReviewError: Error, Equatable, Sendable {
  case reviewerConfiguration
  case diffTooLarge(actual: Int, limit: Int)
  /// The request's diff text does not hash to the candidate's `diffDigest`:
  /// whatever this reviewer would have read is not the reviewed artifact.
  case requestIntegrity
  case responseShape
  case issueShape
  case verdictIssueConsistency
}

/// Source-compatible spelling from before the reviewer grew a second CLI
/// vendor; both adapters throw the same closed error set.
public typealias CodexHarnessAdversarialReviewError = HarnessCLIAdversarialReviewError

/// The vendor-independent half of a CLI adversarial reviewer: the bounded
/// prompt, the closed verdict parse and the request-integrity gates. Both CLI
/// adapters use exactly these, so a verdict can never mean something
/// different depending on which vendor produced it.
enum HarnessCLIAdversarialReviewSupport {
  /// Upper bound for the reviewed diff text, matching the candidate
  /// pipeline's review-diff bound: a diff too large to show a reviewer is
  /// too large to claim it was reviewed.
  static let maximumReviewDiffBytes = 512 * 1024

  static func validateRequest(_ request: HarnessAdversarialReviewRequest) throws {
    guard request.unifiedDiff.utf8.count <= maximumReviewDiffBytes else {
      throw HarnessCLIAdversarialReviewError.diffTooLarge(
        actual: request.unifiedDiff.utf8.count, limit: maximumReviewDiffBytes)
    }
    guard request.candidatePatch.namesDiff(request.unifiedDiff) else {
      throw HarnessCLIAdversarialReviewError.requestIntegrity
    }
  }

  static func prompt(for request: HarnessAdversarialReviewRequest) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let candidate = (try? encoder.encode(request.candidatePatch)).map {
      String(decoding: $0, as: UTF8.self)
    }
    let criteria = request.evaluation.criterionResults.map { result in
      "\(result.criterionID):\(result.verdict.rawValue):metric=\(result.metric):"
        + "samples=\(result.samples)/\(result.requiredSamples)"
    }.joined(separator: "\n")
    let history = request.attemptHistory.suffix(12).map { attempt in
      "\(attempt.ordinal):\(attempt.strategy.hypothesisClass):\(attempt.outcome.rawValue):"
        + "verdict=\(attempt.latestEvaluationVerdict?.rawValue ?? "-"):"
        + "failure=\(attempt.failureFingerprint ?? "-")"
    }.joined(separator: "\n")
    return """
      You are the independent read-only adversarial reviewer for one Evolution candidate
      patch. You have no workspace, Runtime, device, repair or authority port; a promotion
      gate consumes your verdict and a human remains the final fallback. Attack the patch:
      look for regressions, scope creep beyond the listed files, unsafe or destructive
      behavior, security issues, and evidence that does not actually support the claimed
      fix. Answer exactly one JSON object with these two keys and no prose or code fences:
      {"result":"PASS|REJECT|COMMENT","issues":[{"severity":"LOW|MEDIUM|HIGH|CRITICAL","description":"..."}]}
      PASS is legal only with zero issues and means the candidate may be promoted to a
      normal pull request. REJECT means the evolution loop must try another strategy.
      COMMENT stops for a human. Every REJECT or COMMENT needs at least one issue.
      problem=\(request.originalProblem)
      candidate=\(candidate ?? "-")
      evaluation=\(request.evaluation.verdict.rawValue)
      criteria:\n\(criteria)
      attemptHistory:\n\(history)
      evidenceArtifactIds=\(request.artifactIDs.joined(separator: ","))
      immutableDiff:\n\(request.unifiedDiff)
      """
  }

  static func parseVerdict(
    _ response: Data
  ) throws -> (HarnessAdversarialReviewVerdict, [HarnessReviewIssue]) {
    guard let root = try? JSONDecoder().decode(JSONValue.self, from: response),
      case .object(let object) = root, Set(object.keys) == ["result", "issues"],
      case .string(let resultText)? = object["result"],
      let result = HarnessAdversarialReviewVerdict(rawValue: resultText),
      case .array(let issueValues)? = object["issues"], issueValues.count <= 128
    else { throw HarnessCLIAdversarialReviewError.responseShape }
    let issues = try issueValues.map { value -> HarnessReviewIssue in
      guard case .object(let fields) = value, Set(fields.keys) == ["severity", "description"],
        case .string(let severityText)? = fields["severity"],
        let severity = HarnessReviewIssueSeverity(rawValue: severityText),
        case .string(let description)? = fields["description"],
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        description.utf8.count <= 2_048
      else { throw HarnessCLIAdversarialReviewError.issueShape }
      return HarnessReviewIssue(severity: severity, description: description)
    }
    guard result == .pass ? issues.isEmpty : !issues.isEmpty else {
      throw HarnessCLIAdversarialReviewError.verdictIssueConsistency
    }
    return (result, issues)
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Shared executable/working-directory admission for a CLI reviewer role.
  static func validateConfiguration(
    executablePath: String, workingDirectory: String, modelName: String
  ) throws {
    let executableURL = URL(fileURLWithPath: executablePath)
      .resolvingSymlinksInPath().standardizedFileURL
    let workingURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL
    var isDirectory: ObjCBool = false
    guard executablePath.hasPrefix("/"), executableURL.path == executablePath,
      FileManager.default.isExecutableFile(atPath: executablePath),
      workingDirectory.hasPrefix("/"), workingURL.path == workingDirectory,
      FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
      isDirectory.boolValue,
      !modelName.isEmpty, modelName.utf8.count <= 200,
      modelName.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._:-".contains($0)) })
    else { throw HarnessCLIAdversarialReviewError.reviewerConfiguration }
  }
}

public struct CodexHarnessAdversarialReviewer: HarnessAdversarialReviewing {
  /// Upper bound for the reviewed diff text; see
  /// `HarnessCLIAdversarialReviewSupport.maximumReviewDiffBytes`.
  public static let maximumReviewDiffBytes =
    HarnessCLIAdversarialReviewSupport.maximumReviewDiffBytes

  public let reviewerID: String
  private let executablePath: String
  private let executableSHA256: String
  private let modelName: String
  private let workingDirectory: String
  private let transport: any HarnessCodexTransport
  private let nowUTC: @Sendable () -> String

  public init(
    executablePath: String,
    modelName: String,
    workingDirectory: String,
    transport: any HarnessCodexTransport = CodexCLIProcessTransport(),
    nowUTC: @escaping @Sendable () -> String = {
      ISO8601DateFormatter().string(from: Date())
    }
  ) throws {
    try HarnessCLIAdversarialReviewSupport.validateConfiguration(
      executablePath: executablePath, workingDirectory: workingDirectory,
      modelName: modelName)
    self.executablePath = executablePath
    executableSHA256 = HarnessCLIAdversarialReviewSupport.sha256(
      try Data(contentsOf: URL(fileURLWithPath: executablePath)))
    self.modelName = modelName
    self.workingDirectory = workingDirectory
    self.transport = transport
    self.nowUTC = nowUTC
    reviewerID =
      "codex-harness-adversarial-reviewer@1:"
      + String(
        HarnessCLIAdversarialReviewSupport.sha256(
          Data("\(executableSHA256)|\(modelName)".utf8)
        ).prefix(16))
  }

  public func review(_ request: HarnessAdversarialReviewRequest) async throws
    -> HarnessAdversarialReview
  {
    try HarnessCLIAdversarialReviewSupport.validateRequest(request)
    let response = try await transport.send(
      HarnessCodexProcessRequest(
        executablePath: executablePath, executableSHA256: executableSHA256,
        arguments: [
          "exec", "--ephemeral", "--ignore-user-config", "--ignore-rules",
          "--sandbox", "read-only", "--skip-git-repo-check", "-C", workingDirectory,
          "--color", "never", "--model", modelName,
          HarnessCLIAdversarialReviewSupport.prompt(for: request),
        ], workingDirectory: workingDirectory, timeoutSeconds: 300))
    let (result, issues) = try HarnessCLIAdversarialReviewSupport.parseVerdict(response)
    // Identity fields come from the request, never from model output: the
    // verdict names exactly the candidate and evaluation it was asked about.
    return HarnessAdversarialReview(
      reviewID:
        "HREVIEW-\(HarnessCLIAdversarialReviewSupport.sha256(response).prefix(24).uppercased())",
      reviewerID: reviewerID,
      candidatePatchID: request.candidatePatch.candidatePatchID,
      evaluationID: request.evaluation.evaluationID,
      result: result, issues: issues, createdAtUTC: nowUTC())
  }

}

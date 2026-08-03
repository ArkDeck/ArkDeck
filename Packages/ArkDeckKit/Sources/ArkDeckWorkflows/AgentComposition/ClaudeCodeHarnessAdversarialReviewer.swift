// The Claude Code CLI adversarial reviewer for the Harness Evolution path.
//
// Second production conformer of `HarnessAdversarialReviewing`, next to the
// Codex adapter: a signed-in ArkDeck host may have Claude Code but no Codex
// CLI (or want the reviewer role on a different vendor than the builder,
// which strengthens review independence). The prompt, the closed verdict
// shape and every integrity gate are the shared
// `HarnessCLIAdversarialReviewSupport` pieces — a verdict means exactly the
// same thing whichever CLI produced it.
//
// Read-only posture: the CLI runs in non-interactive print mode
// (`--print`), where a tool that needs permission is denied instead of
// prompted, from an operator-owned empty working directory, and with
// `--max-turns 1` — a single turn structurally cannot run a tool and still
// return a verdict, so a run that tries anything but answering fails the
// closed parse and stops the task for a human instead of promoting.

import ArkDeckCore
import ArkDeckHarness
import Foundation

public struct ClaudeCodeHarnessAdversarialReviewer: HarnessAdversarialReviewing {
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
      "claude-code-harness-adversarial-reviewer@1:"
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
          "--print", "--output-format", "text", "--max-turns", "1",
          "--model", modelName,
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

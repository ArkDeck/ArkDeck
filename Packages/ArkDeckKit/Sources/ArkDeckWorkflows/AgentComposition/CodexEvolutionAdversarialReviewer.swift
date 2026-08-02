// The Codex-CLI adapters for Rockchip evolution campaigns: the adversarial
// reviewer and the strategy repairer.
//
// Extracted from EvolutionCandidatePipeline.swift: these adapters are the
// pieces of the campaign pipeline that speak to an LLM, so they live in the
// composition target (ArkDeckAgentComposition) together with the Codex CLI
// transport, keeping ArkDeckWorkflows free of model prompts and of any
// dependency on the harness plane. The protocols they implement
// (RockchipEvolutionAdversarialReviewing, RockchipEvolutionStrategyRepairing)
// and the campaign pipeline remain in ArkDeckWorkflows.

import ArkDeckCore
import ArkDeckWorkflows
import Foundation


/// The repair model has no workspace, Runtime, authority or device port. It receives only a
/// normalized failure code and prior closed strategies, then returns timing/mode values that the
/// isolated candidate executable and merged broker both validate. The first attempt is the
/// protected-main baseline and never needs a model call.
public struct CodexRockchipEvolutionStrategyRepairer: RockchipEvolutionStrategyRepairing {
  public let repairerID: String
  private let executablePath: String
  private let executableSHA256: String
  private let modelName: String
  private let workingDirectory: String
  private let transport: any HarnessCodexTransport

  public init(
    executablePath: String,
    modelName: String,
    workingDirectory: String,
    transport: any HarnessCodexTransport = CodexCLIProcessTransport()
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
    else { throw RockchipEvolutionCampaignError.candidateRejected("repairerConfiguration") }
    self.executablePath = executablePath
    executableSHA256 = RockchipEvolutionCampaignConfirmationAssertion.sha256(
      try Data(contentsOf: executableURL))
    self.modelName = modelName
    self.workingDirectory = workingDirectory
    self.transport = transport
    repairerID =
      "codex-evolution-strategy-repairer@1:"
      + String(
        RockchipEvolutionCampaignConfirmationAssertion.sha256(
          Data("\(executableSHA256)|\(modelName)".utf8)
        ).prefix(16))
  }

  public func propose(
    assertion: RockchipEvolutionCampaignConfirmationAssertion,
    observation: RockchipEvolutionFailureObservation?,
    priorCandidates: [RockchipEvolutionCandidatePin]
  ) async throws -> RockchipEvolutionTypedStrategy {
    if observation == nil {
      return try Self.strategy(
        assertion: assertion, modes: [.hdcNormal, .loader],
        loaderTimeout: RockchipEvolutionTypedStrategy.defaultLoaderDiscoveryTimeoutSeconds,
        pollMilliseconds: RockchipEvolutionTypedStrategy.defaultLoaderPollIntervalMilliseconds,
        hdcTimeout: RockchipEvolutionTypedStrategy.defaultHDCCommandTimeoutSeconds,
        readOnlyTimeout: RockchipEvolutionTypedStrategy.defaultReadOnlyCommandTimeoutSeconds)
    }
    let prior = priorCandidates.suffix(8).map { candidate in
      let strategy = candidate.strategy
      return "\(strategy.digestSHA256):modes=\(strategy.allowedStartingModes.map(\.rawValue).joined(separator: ",")):loader=\(strategy.loaderDiscoveryTimeoutSeconds):poll=\(strategy.loaderPollIntervalMilliseconds):hdc=\(strategy.hdcCommandTimeoutSeconds):read=\(strategy.readOnlyCommandTimeoutSeconds)"
    }.joined(separator: "\n")
    let prompt = """
      You are a bounded firmware-campaign strategy repairer. You have no filesystem, shell,
      Runtime, device, USB/HDC/RockUSB, network configuration, or authority port. A merged broker
      owns every device action. Select a NEW closed strategy for the normalized safe-to-retry
      failure below. Do not invent commands, paths, steps, partitions, retries, or authorization.
      Answer exactly one JSON object with these keys and no prose:
      {"allowedStartingModes":["hdcNormal","loader"],"loaderDiscoveryTimeoutSeconds":45,"loaderPollIntervalMilliseconds":500,"hdcCommandTimeoutSeconds":20,"readOnlyCommandTimeoutSeconds":15}
      Constraints: modes is a non-empty subset of hdcNormal|loader; loader timeout 15...120;
      poll 100...2000; HDC timeout 5...60; read-only timeout 5...60. The result must differ
      from every prior strategy.
      failure=\(observation!.failureCode)
      attempt=\(observation!.attemptOrdinal)
      prior:\n\(prior)
      """
    let response = try await transport.send(
      HarnessCodexProcessRequest(
        executablePath: executablePath, executableSHA256: executableSHA256,
        arguments: [
          "exec", "--ephemeral", "--ignore-user-config", "--ignore-rules",
          "--sandbox", "read-only", "--skip-git-repo-check", "-C", workingDirectory,
          "--color", "never", "--model", modelName, prompt,
        ], workingDirectory: workingDirectory, timeoutSeconds: 300))
    guard let root = try? JSONDecoder().decode(JSONValue.self, from: response),
      case .object(let fields) = root,
      Set(fields.keys) == [
        "allowedStartingModes", "loaderDiscoveryTimeoutSeconds",
        "loaderPollIntervalMilliseconds", "hdcCommandTimeoutSeconds",
        "readOnlyCommandTimeoutSeconds",
      ],
      case .array(let modeValues)? = fields["allowedStartingModes"],
      case .integer(let loaderTimeout)? = fields["loaderDiscoveryTimeoutSeconds"],
      case .integer(let pollMilliseconds)? = fields["loaderPollIntervalMilliseconds"],
      case .integer(let hdcTimeout)? = fields["hdcCommandTimeoutSeconds"],
      case .integer(let readOnlyTimeout)? = fields["readOnlyCommandTimeoutSeconds"]
    else { throw RockchipEvolutionCampaignError.candidateRejected("repairResponseShape") }
    let modes = try modeValues.map { value -> RockchipEvolutionStartingMode in
      guard case .string(let raw) = value, let mode = RockchipEvolutionStartingMode(rawValue: raw)
      else { throw RockchipEvolutionCampaignError.candidateRejected("repairStartingMode") }
      return mode
    }
    guard [loaderTimeout, pollMilliseconds, hdcTimeout, readOnlyTimeout].allSatisfy({
      $0 >= Int64(Int.min) && $0 <= Int64(Int.max)
    }) else { throw RockchipEvolutionCampaignError.candidateRejected("repairInteger") }
    let proposed = try Self.strategy(
      assertion: assertion, modes: modes, loaderTimeout: Int(loaderTimeout),
      pollMilliseconds: Int(pollMilliseconds), hdcTimeout: Int(hdcTimeout),
      readOnlyTimeout: Int(readOnlyTimeout))
    guard !priorCandidates.contains(where: { $0.strategy.digestSHA256 == proposed.digestSHA256 })
    else { throw RockchipEvolutionCampaignError.candidateRejected("repeatedStrategy") }
    return proposed
  }

  private static func strategy(
    assertion: RockchipEvolutionCampaignConfirmationAssertion,
    modes: [RockchipEvolutionStartingMode],
    loaderTimeout: Int,
    pollMilliseconds: Int,
    hdcTimeout: Int,
    readOnlyTimeout: Int
  ) throws -> RockchipEvolutionTypedStrategy {
    try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200@2",
      archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: modes,
      loaderDiscoveryTimeoutSeconds: loaderTimeout,
      loaderPollIntervalMilliseconds: pollMilliseconds,
      hdcCommandTimeoutSeconds: hdcTimeout,
      readOnlyCommandTimeoutSeconds: readOnlyTimeout,
      userdataImpact: assertion.userdataImpact)
  }
}

/// Codex runs in its existing read-only ephemeral mode and sees only the
/// immutable candidate diff/pins and bounded attempt history.  This adapter
/// has no Runtime, device, repair or authority dependency.
public struct CodexRockchipEvolutionAdversarialReviewer:
  RockchipEvolutionAdversarialReviewing
{
  public let reviewerID: String
  private let executablePath: String
  private let executableSHA256: String
  private let modelName: String
  private let workingDirectory: String
  private let transport: any HarnessCodexTransport

  public init(
    executablePath: String,
    modelName: String,
    workingDirectory: String,
    transport: any HarnessCodexTransport = CodexCLIProcessTransport()
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
    else { throw RockchipEvolutionCampaignError.reviewRejected("reviewerConfiguration") }
    self.executablePath = executablePath
    executableSHA256 = RockchipEvolutionCampaignConfirmationAssertion.sha256(
      try Data(contentsOf: executableURL))
    self.modelName = modelName
    self.workingDirectory = workingDirectory
    self.transport = transport
    reviewerID =
      "codex-evolution-reviewer@1:"
      + String(
        RockchipEvolutionCampaignConfirmationAssertion.sha256(
          Data("\(executableSHA256)|\(modelName)".utf8)
        ).prefix(16))
  }

  public func review(_ request: RockchipEvolutionAdversarialReviewRequest) async throws
    -> RockchipEvolutionReviewReceipt
  {
    guard
      request.immutableDiff.count
        <= ProductRockchipEvolutionCandidateBuilder
        .maximumReviewDiffBytes
    else { throw RockchipEvolutionCampaignError.reviewRejected("diffBytes") }
    let candidateData = try JSONEncoder.sorted.encode(request.candidate)
    let history = request.priorAttempts.suffix(24).map { event in
      "\(event.sequence):\(event.kind.rawValue):\(event.ordinal.map(String.init) ?? "-"):"
        + "\(event.disposition?.rawValue ?? "-")"
    }.joined(separator: "\n")
    let prompt = """
      You are the independent read-only adversarial reviewer for one bounded E2 firmware
      campaign candidate. You have no repair, Runtime, device or authority port. Review only
      the immutable diff and pins below. Reject any attempt to add network, USB/HDC/RockUSB,
      raw shell, arbitrary executable/argv/path, authorization access, Catalog/profile/broker
      changes, target/budget widening, or unbounded behavior. Answer one JSON object only:
      {"result":"PASS|REJECT","issues":[{"severity":"LOW|MEDIUM|HIGH|CRITICAL","code":"UPPER_CODE"}]}
      PASS is legal only with zero HIGH/CRITICAL issues.
      planDigest=\(request.assertion.planDigestSHA256)
      archiveDigest=\(request.assertion.archiveDigestSHA256)
      stepSetDigest=\(request.assertion.stepSetDigestSHA256)
      candidate=\(String(decoding: candidateData, as: UTF8.self))
      history:\n\(history)
      immutableDiff:\n\(String(decoding: request.immutableDiff, as: UTF8.self))
      """
    let response = try await transport.send(
      HarnessCodexProcessRequest(
        executablePath: executablePath, executableSHA256: executableSHA256,
        arguments: [
          "exec", "--ephemeral", "--ignore-user-config", "--ignore-rules",
          "--sandbox", "read-only", "--skip-git-repo-check", "-C", workingDirectory,
          "--color", "never", "--model", modelName, prompt,
        ], workingDirectory: workingDirectory, timeoutSeconds: 300))
    guard let root = try? JSONDecoder().decode(JSONValue.self, from: response),
      case .object(let object) = root, Set(object.keys) == ["result", "issues"],
      case .string(let resultText)? = object["result"],
      let result = RockchipEvolutionReviewVerdict(rawValue: resultText),
      case .array(let issueValues)? = object["issues"]
    else { throw RockchipEvolutionCampaignError.reviewRejected("responseShape") }
    let issues = try issueValues.map { value -> RockchipEvolutionReviewIssue in
      guard case .object(let fields) = value, Set(fields.keys) == ["severity", "code"],
        case .string(let severityText)? = fields["severity"],
        let severity = RockchipEvolutionReviewSeverity(rawValue: severityText),
        case .string(let code)? = fields["code"]
      else { throw RockchipEvolutionCampaignError.reviewRejected("issueShape") }
      return try RockchipEvolutionReviewIssue(severity: severity, code: code)
    }
    let responseDigest = RockchipEvolutionCampaignConfirmationAssertion.sha256(response)
    let receipt = try RockchipEvolutionReviewReceipt(
      reviewID: "EREVIEW-\(responseDigest.prefix(24).uppercased())",
      reviewerID: reviewerID, candidateID: request.candidate.candidateID,
      candidateExecutableDigestSHA256: request.candidate.executableDigestSHA256,
      planDigestSHA256: request.assertion.planDigestSHA256,
      result: result, issues: issues, createdAt: ISO8601DateFormatter().string(from: Date()))
    try receipt.validate(candidate: request.candidate)
    return receipt
  }
}

extension JSONEncoder {
  fileprivate static var sorted: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}

// The local agent-CLI adapter for Rockchip evolution campaign strategy repair.
//
// Extracted from EvolutionCandidatePipeline.swift: these adapters are the
// pieces of the campaign pipeline that speak to an LLM, so they live in the
// composition target (ArkDeckAgentComposition) together with the agent CLI
// transport, keeping ArkDeckWorkflows free of model prompts and of any
// dependency on the harness plane. Its protocol and the campaign pipeline
// remain in ArkDeckWorkflows.
//
// Which CLI answers is a `HarnessLocalAgentCLIProfile`, so this lane is not
// tied to any one vendor's binary either.

import ArkDeckCore
import ArkDeckWorkflows
import Foundation


/// The repair model has no workspace, Runtime, authority or device port. It receives only a
/// normalized failure code and prior closed strategies, then returns timing/mode values that the
/// isolated candidate executable and merged broker both validate. The first attempt is the
/// protected-main baseline and never needs a model call.
public struct LocalAgentRockchipEvolutionStrategyRepairer: RockchipEvolutionStrategyRepairing {
  public let repairerID: String
  private let executablePath: String
  private let executableSHA256: String
  private let modelName: String
  private let workingDirectory: String
  private let profile: HarnessLocalAgentCLIProfile
  private let transport: any HarnessLocalAgentCLITransport

  public init(
    profile: HarnessLocalAgentCLIProfile,
    executablePath: String,
    modelName: String,
    workingDirectory: String,
    transport: any HarnessLocalAgentCLITransport = LocalAgentCLIProcessTransport()
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
    self.profile = profile
    self.transport = transport
    repairerID =
      "\(profile.profileID)-evolution-strategy-repairer@1:"
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
      {"allowedStartingModes":["hdcNormal","loader"],"loaderDiscoveryTimeoutSeconds":120,"loaderPollIntervalMilliseconds":500,"hdcCommandTimeoutSeconds":20,"readOnlyCommandTimeoutSeconds":15}
      Constraints: modes is a non-empty subset of hdcNormal|loader; loader timeout 15...120;
      poll 100...2000; HDC timeout 5...60; read-only timeout 5...60. The result must differ
      from every prior strategy. If failure starts with flash.startingModeNotAllowed:, the mode
      after that colon is an observed live mode and MUST appear in allowedStartingModes.
      failure=\(observation!.failureCode)
      attempt=\(observation!.attemptOrdinal)
      prior:\n\(prior)
      """
    let response = try await transport.send(
      HarnessLocalAgentCLIRequest(
        executablePath: executablePath, executableSHA256: executableSHA256,
        profile: profile, modelName: modelName, prompt: prompt,
        workingDirectory: workingDirectory, timeoutSeconds: 300))
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

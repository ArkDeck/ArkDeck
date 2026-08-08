// App-facing Flash planning and typed execution over Runtime's XPC door.
//
// The production provider reads operation availability and adopted target
// facts from the daemon, materializes an exact Rockchip plan in-process from a
// user-selected archive, imports that archive, and submits the published
// `flash.dayu200@1` typed operation. Runtime owns capability creation and all
// target/plan/artifact admission; the App cannot supply or administer one.

import ArkDeckCore
import ArkDeckRuntime
import Foundation
import os

public enum FlashOperationAvailability: Sendable, Equatable {
  case checking
  case available
  case unavailable(reasons: [String])
}

public struct FlashTargetPresentation: Sendable, Equatable, Identifiable {
  public let id: String
  public let bindingRevision: Int
  public let toolVersion: String
  public let adoptedAtUTC: String

  public init(id: String, bindingRevision: Int, toolVersion: String, adoptedAtUTC: String) {
    self.id = id
    self.bindingRevision = bindingRevision
    self.toolVersion = toolVersion
    self.adoptedAtUTC = adoptedAtUTC
  }
}

public struct FlashWorkspacePresentation: Sendable, Equatable {
  public let availability: FlashOperationAvailability
  public let targets: [FlashTargetPresentation]
  public let targetLoadFailure: String?

  public init(
    availability: FlashOperationAvailability,
    targets: [FlashTargetPresentation],
    targetLoadFailure: String? = nil
  ) {
    self.availability = availability
    self.targets = targets
    self.targetLoadFailure = targetLoadFailure
  }

  public static let loading = FlashWorkspacePresentation(
    availability: .checking, targets: [])
}

public enum FlashPlanEffect: String, Sendable, Equatable {
  case hostOnly
  case readOnly
  case deviceMutation
  case destructive
}

public enum FlashPlanStepDisposition: String, Sendable, Equatable {
  case planned
  case simulatedPreview
  case executionLocked
}

public struct FlashPlanStepPresentation: Sendable, Equatable, Identifiable {
  public let id: String
  public let kind: String
  public let argumentSummary: String
  public let effect: FlashPlanEffect
  public let disposition: FlashPlanStepDisposition

  public init(
    id: String,
    kind: String,
    argumentSummary: String,
    effect: FlashPlanEffect,
    disposition: FlashPlanStepDisposition
  ) {
    self.id = id
    self.kind = kind
    self.argumentSummary = argumentSummary
    self.effect = effect
    self.disposition = disposition
  }
}

public enum FlashDataImpactPresentation: Sendable, Equatable {
  case mappedPartitionsOverwritten(count: Int)
  case userDataDestroyed
  case forbiddenAreasPreserved
}

public struct FlashPartitionPresentation: Sendable, Equatable, Identifiable {
  public let writeOrder: Int
  public let partitionName: String
  public let imageMemberName: String
  public let imageSizeBytes: Int64
  public let imageSHA256: String

  public var id: String { partitionName }

  public init(
    writeOrder: Int,
    partitionName: String,
    imageMemberName: String,
    imageSizeBytes: Int64,
    imageSHA256: String
  ) {
    self.writeOrder = writeOrder
    self.partitionName = partitionName
    self.imageMemberName = imageMemberName
    self.imageSizeBytes = imageSizeBytes
    self.imageSHA256 = imageSHA256
  }
}

public struct FlashPrerequisitePresentation: Sendable, Equatable, Identifiable {
  public let identifier: RockchipPrerequisiteIdentifier
  public let requirement: RockchipPrerequisiteRequirement

  public var id: RockchipPrerequisiteIdentifier { identifier }

  public init(
    identifier: RockchipPrerequisiteIdentifier,
    requirement: RockchipPrerequisiteRequirement
  ) {
    self.identifier = identifier
    self.requirement = requirement
  }
}

public struct FlashExactPlanPresentation: Sendable, Equatable {
  public let mode: RockchipFlashExecutionMode
  public let target: FlashTargetPresentation?
  public let profileReference: String
  public let toolchainFingerprint: String
  public let imageFileName: String
  public let runtimeBuildVersion: String
  public let archiveSizeBytes: Int64
  public let archiveSHA256: String
  public let mappedPartitionCount: Int
  public let planDigestSHA256: String
  public let stepSetDigestSHA256: String
  public let steps: [FlashPlanStepPresentation]
  public let dataImpact: [FlashDataImpactPresentation]
  public let partitions: [FlashPartitionPresentation]
  public let writeForbiddenMemberNames: [String]
  public let prerequisites: [FlashPrerequisitePresentation]

  public init(
    mode: RockchipFlashExecutionMode,
    target: FlashTargetPresentation?,
    profileReference: String,
    toolchainFingerprint: String,
    imageFileName: String,
    runtimeBuildVersion: String,
    archiveSizeBytes: Int64,
    archiveSHA256: String,
    mappedPartitionCount: Int,
    planDigestSHA256: String,
    stepSetDigestSHA256: String,
    steps: [FlashPlanStepPresentation],
    dataImpact: [FlashDataImpactPresentation],
    partitions: [FlashPartitionPresentation],
    writeForbiddenMemberNames: [String],
    prerequisites: [FlashPrerequisitePresentation]
  ) {
    self.mode = mode
    self.target = target
    self.profileReference = profileReference
    self.toolchainFingerprint = toolchainFingerprint
    self.imageFileName = imageFileName
    self.runtimeBuildVersion = runtimeBuildVersion
    self.archiveSizeBytes = archiveSizeBytes
    self.archiveSHA256 = archiveSHA256
    self.mappedPartitionCount = mappedPartitionCount
    self.planDigestSHA256 = planDigestSHA256
    self.stepSetDigestSHA256 = stepSetDigestSHA256
    self.steps = steps
    self.dataImpact = dataImpact
    self.partitions = partitions
    self.writeForbiddenMemberNames = writeForbiddenMemberNames
    self.prerequisites = prerequisites
  }
}

public enum FlashPlanFailureCode: String, Sendable, Equatable {
  case fileAccessDenied
  case unreadableArchive
  case invalidArchive
  case unsupportedBundle
  case planMaterializationFailed
}

public enum FlashPlanPreparationResult: Sendable, Equatable {
  case ready(FlashExactPlanPresentation)
  case failed(code: FlashPlanFailureCode, detail: String?)
}

public struct FlashSubmissionPresentation: Sendable, Equatable {
  public let jobID: String
  public let state: String
  public let outcomeUnknown: Bool
  public let timeline: [String]

  public init(jobID: String, state: String, outcomeUnknown: Bool, timeline: [String]) {
    self.jobID = jobID
    self.state = state
    self.outcomeUnknown = outcomeUnknown
    self.timeline = timeline
  }
}

public enum FlashSubmissionResult: Sendable, Equatable {
  case completed(FlashSubmissionPresentation)
  case failed(String)
}

/// An in-memory record that a human reviewed one exact execute-plan snapshot.
///
/// This is deliberately not a Runtime authority, capability, reservation or
/// Job request. Producing this value always has zero device dispatch; the
/// separate submit action still enters the full Runtime admission gate.
public struct FlashHumanHandoffPresentation: Sendable, Equatable {
  public let confirmedAtUTC: String
  public let target: FlashTargetPresentation
  public let profileReference: String
  public let imageFileName: String
  public let archiveSHA256: String
  public let planDigestSHA256: String
  public let stepSetDigestSHA256: String
  public let destructiveConfirmationPhrase: String
  public let deviceMutationDispatchCount: Int

  public init(
    confirmedAtUTC: String,
    target: FlashTargetPresentation,
    profileReference: String,
    imageFileName: String,
    archiveSHA256: String,
    planDigestSHA256: String,
    stepSetDigestSHA256: String,
    destructiveConfirmationPhrase: String,
    deviceMutationDispatchCount: Int
  ) {
    self.confirmedAtUTC = confirmedAtUTC
    self.target = target
    self.profileReference = profileReference
    self.imageFileName = imageFileName
    self.archiveSHA256 = archiveSHA256
    self.planDigestSHA256 = planDigestSHA256
    self.stepSetDigestSHA256 = stepSetDigestSHA256
    self.destructiveConfirmationPhrase = destructiveConfirmationPhrase
    self.deviceMutationDispatchCount = deviceMutationDispatchCount
  }
}

public enum FlashManualConfirmationFailure: String, Sendable, Equatable {
  case notExecutePlan
  case missingOrStaleTarget
  case stalePlan
  case destructivePhraseMismatch
  case userdataPhraseMismatch
}

public enum FlashManualConfirmationResult: Sendable, Equatable {
  case accepted(FlashHumanHandoffPresentation)
  case rejected(FlashManualConfirmationFailure)
}

/// Validates the two human confirmation phrases against an immutable plan
/// snapshot. It can only produce a presentation-only handoff record.
public enum FlashManualConfirmationValidator {
  public static let userdataPhrase = "ERASE-USERDATA"

  public static func destructivePhrase(for plan: FlashExactPlanPresentation) -> String {
    "FLASH \(plan.planDigestSHA256.prefix(12))"
  }

  public static func confirm(
    currentPlan: FlashExactPlanPresentation?,
    reviewedPlan: FlashExactPlanPresentation,
    currentTarget: FlashTargetPresentation?,
    destructivePhrase: String,
    userdataPhrase: String,
    confirmedAtUTC: String
  ) -> FlashManualConfirmationResult {
    guard reviewedPlan.mode == .execute else { return .rejected(.notExecutePlan) }
    guard let reviewedTarget = reviewedPlan.target,
      currentTarget == reviewedTarget
    else {
      return .rejected(.missingOrStaleTarget)
    }
    guard currentPlan == reviewedPlan else { return .rejected(.stalePlan) }
    let expectedDestructive = self.destructivePhrase(for: reviewedPlan)
    guard destructivePhrase == expectedDestructive else {
      return .rejected(.destructivePhraseMismatch)
    }
    guard userdataPhrase == self.userdataPhrase else {
      return .rejected(.userdataPhraseMismatch)
    }
    return .accepted(
      FlashHumanHandoffPresentation(
        confirmedAtUTC: confirmedAtUTC,
        target: reviewedTarget,
        profileReference: reviewedPlan.profileReference,
        imageFileName: reviewedPlan.imageFileName,
        archiveSHA256: reviewedPlan.archiveSHA256,
        planDigestSHA256: reviewedPlan.planDigestSHA256,
        stepSetDigestSHA256: reviewedPlan.stepSetDigestSHA256,
        destructiveConfirmationPhrase: expectedDestructive,
        deviceMutationDispatchCount: 0))
  }
}

public protocol FlashApplicationProviding: Sendable {
  func refreshWorkspace() async -> FlashWorkspacePresentation
  func preparePlan(
    archiveURL: URL,
    profileReference: String,
    mode: RockchipFlashExecutionMode,
    target: FlashTargetPresentation?
  ) async -> FlashPlanPreparationResult
  func submit(
    archiveURL: URL,
    plan: FlashExactPlanPresentation
  ) async -> FlashSubmissionResult
}

public enum FlashApplicationFacade {
  public static let profileReferences = RockchipFlashProfile.supportedDAYU200Profiles.map(
    \.catalogReference)

  public static func make(
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> any FlashApplicationProviding {
    if arguments.contains("--ui-test-flash") || arguments.contains("--ui-test-flash-plan") {
      return FlashFixtureApplicationProvider()
    }
    return FlashProductionApplicationProvider()
  }
}

private actor FlashProductionApplicationProvider: FlashApplicationProviding {
  func refreshWorkspace() async -> FlashWorkspacePresentation {
    async let operations = FlashXPCTransport.request(method: "operation.list")
    async let targets = FlashXPCTransport.request(method: "target.list")
    return FlashWorkspaceResponseDecoding.presentation(
      operationResponse: await operations,
      targetResponse: await targets)
  }

  func preparePlan(
    archiveURL: URL,
    profileReference: String,
    mode: RockchipFlashExecutionMode,
    target: FlashTargetPresentation?
  ) async -> FlashPlanPreparationResult {
    let gainedScope = archiveURL.startAccessingSecurityScopedResource()
    defer {
      if gainedScope { archiveURL.stopAccessingSecurityScopedResource() }
    }
    return await Task.detached(priority: .userInitiated) {
      FlashPlanPresentationBuilder.prepare(
        archiveURL: archiveURL,
        profileReference: profileReference,
        mode: mode,
        target: target)
    }.value
  }

  func submit(
    archiveURL: URL,
    plan: FlashExactPlanPresentation
  ) async -> FlashSubmissionResult {
    guard plan.mode == .execute, let target = plan.target else {
      return .failed("Only a bound execute plan can be submitted")
    }
    let gainedScope = archiveURL.startAccessingSecurityScopedResource()
    defer {
      if gainedScope { archiveURL.stopAccessingSecurityScopedResource() }
    }
    do {
      let begin = try await FlashXPCResponseDecoding.resultObject(
        await FlashXPCTransport.request(
          method: "artifact.importFlashBundle.begin",
          params: FlashRuntimeSubmissionRequest.importBeginParams(
            target: target, plan: plan)))
      guard let uploadID = begin["uploadId"] as? String,
        let maximumChunkBytes = begin["maximumChunkBytes"] as? Int,
        maximumChunkBytes > 0
      else {
        return .failed("Runtime returned incomplete Flash import facts")
      }
      do {
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }
        var offset = 0
        while true {
          guard !Task.isCancelled else { throw CancellationError() }
          let chunk = try handle.read(upToCount: maximumChunkBytes) ?? Data()
          if chunk.isEmpty { break }
          let appended = try await FlashXPCResponseDecoding.resultObject(
            await FlashXPCTransport.request(
              method: "artifact.importFlashBundle.append",
              params: [
                "uploadId": .string(uploadID),
                "offset": .integer(Int64(offset)),
                "base64": .string(chunk.base64EncodedString()),
              ]))
          guard let nextOffset = appended["nextOffset"] as? Int,
            nextOffset == offset + chunk.count
          else {
            throw FlashResponseFailure(message: "Runtime Flash import offset drifted")
          }
          offset = nextOffset
        }
        guard Int64(offset) == plan.archiveSizeBytes else {
          throw FlashResponseFailure(message: "Selected archive changed while it was imported")
        }
      } catch {
        _ = await FlashXPCTransport.request(
          method: "artifact.importFlashBundle.abort",
          params: ["uploadId": .string(uploadID)])
        throw error
      }

      let imported = try await FlashXPCResponseDecoding.resultObject(
        await FlashXPCTransport.request(
          method: "artifact.importFlashBundle.commit",
          params: ["uploadId": .string(uploadID)]))
      guard let lease = imported["lease"] as? String,
        imported["targetId"] as? String == target.id,
        imported["bindingRevision"] as? Int == target.bindingRevision,
        imported["sha256"] as? String == plan.archiveSHA256
      else {
        return .failed("Runtime import facts no longer match the reviewed target and archive")
      }

      let nonce = UUID().uuidString.lowercased()
      let request = try RuntimeOperationRequest(
        requestID: "flash-ui-\(nonce)",
        idempotencyKey: "flash-ui-\(nonce)",
        target: DurableTargetReference(
          targetID: target.id,
          expectedBindingRevision: target.bindingRevision),
        operation: RuntimeOperationReference(id: "flash.dayu200", version: 1),
        inputs: [
          "imageBundleLease": .string(lease),
          "deviceProfile": .string(plan.profileReference),
          "partitionPlan": .array(
            plan.partitions.sorted { $0.writeOrder < $1.writeOrder }
              .map { .string($0.partitionName) }),
          "postFlashVerification": .string("full"),
        ],
        requestedOutputs: [.rawArtifacts, .derivedArtifacts, .hardwareEvidence],
        clientContext: RuntimeClientContext(clientName: "ArkDeckApp.FlashWorkspace"))
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let requestData = try encoder.encode(request)
      guard let requestJSON = String(data: requestData, encoding: .utf8) else {
        return .failed("Could not encode the typed Flash request")
      }
      let submitted = try await FlashXPCResponseDecoding.resultObject(
        await FlashXPCTransport.request(
          method: "job.submit", params: ["requestJson": .string(requestJSON)]))
      guard let jobID = submitted["jobId"] as? String else {
        return .failed("Runtime accepted Flash without returning a Job ID")
      }
      let terminal = try await FlashXPCResponseDecoding.resultObject(
        await FlashXPCTransport.request(
          method: "job.run", params: ["jobId": .string(jobID)]))
      guard let returnedJobID = terminal["jobId"] as? String,
        returnedJobID == jobID,
        let state = terminal["state"] as? String,
        let outcomeUnknown = terminal["outcomeUnknown"] as? Bool,
        let timeline = terminal["timeline"] as? [String]
      else {
        return .failed("Runtime returned an incomplete terminal Flash status")
      }
      return .completed(
        FlashSubmissionPresentation(
          jobID: jobID, state: state, outcomeUnknown: outcomeUnknown, timeline: timeline))
    } catch let failure as FlashResponseFailure {
      return .failed(failure.message)
    } catch {
      return .failed(String(describing: error))
    }
  }
}

enum FlashRuntimeSubmissionRequest {
  /// The Runtime import contract names the logical DAYU200 bundle, not the
  /// operator's local download filename. The latter remains presentation
  /// metadata and may include daily-build prefixes and timestamps.
  static let canonicalArchiveName = "images.tar.gz"

  static func importBeginParams(
    target: FlashTargetPresentation,
    plan: FlashExactPlanPresentation
  ) -> [String: JSONValue] {
    [
      "targetId": .string(target.id),
      "name": .string(canonicalArchiveName),
      "byteCount": .integer(plan.archiveSizeBytes),
      "sha256": .string(plan.archiveSHA256),
    ]
  }
}

private actor FlashFixtureApplicationProvider: FlashApplicationProviding {
  func refreshWorkspace() async -> FlashWorkspacePresentation {
    FlashWorkspacePresentation(
      availability: .available,
      targets: [
        FlashTargetPresentation(
          id: "target-fixture-dayu200",
          bindingRevision: 7,
          toolVersion: "3.2.0f",
          adoptedAtUTC: "2026-08-06T08:00:00Z")
      ])
  }

  func preparePlan(
    archiveURL: URL,
    profileReference: String,
    mode: RockchipFlashExecutionMode,
    target: FlashTargetPresentation?
  ) async -> FlashPlanPreparationResult {
    guard let board = RockchipFlashProfile.board(reference: profileReference) else {
      return .failed(code: .unsupportedBundle, detail: profileReference)
    }
    let provider = RockchipRockUSBFlashProvider(profile: board)
    do {
      let plan = try provider.makePlan(
        mode: mode, archiveValidation: .valid, planNonce: "ui-fixture")
      return .ready(
        FlashPlanPresentationBuilder.presentation(
          plan: plan,
          profile: board,
          target: target,
          imageFileName: archiveURL.lastPathComponent))
    } catch {
      return .failed(code: .planMaterializationFailed, detail: String(describing: error))
    }
  }

  func submit(
    archiveURL _: URL,
    plan _: FlashExactPlanPresentation
  ) async -> FlashSubmissionResult {
    .completed(
      FlashSubmissionPresentation(
        jobID: "job-ui-fixture-flash", state: "succeeded", outcomeUnknown: false,
        timeline: ["jobCreated", "finalized"]))
  }
}

enum FlashWorkspaceResponseDecoding {
  static func presentation(
    operationResponse: Result<Data, FlashXPCReadFailure>,
    targetResponse: Result<Data, FlashXPCReadFailure>
  ) -> FlashWorkspacePresentation {
    let availability = decodeAvailability(operationResponse)
    switch targetResponse {
    case .failure(let failure):
      return FlashWorkspacePresentation(
        availability: availability,
        targets: [],
        targetLoadFailure: failure.message)
    case .success(let data):
      switch decodeResultArray(data) {
      case .failure(let failure):
        return FlashWorkspacePresentation(
          availability: availability,
          targets: [],
          targetLoadFailure: failure.message)
      case .success(let entries):
        var targets: [FlashTargetPresentation] = []
        for entry in entries {
          guard
            let id = entry["targetId"] as? String,
            let revision = entry["bindingRevision"] as? Int,
            let toolVersion = entry["toolVersion"] as? String,
            let adoptedAtUTC = entry["adoptedAtUtc"] as? String
          else {
            return FlashWorkspacePresentation(
              availability: availability,
              targets: [],
              targetLoadFailure: "Runtime returned a target without complete binding facts")
          }
          targets.append(
            FlashTargetPresentation(
              id: id,
              bindingRevision: revision,
              toolVersion: toolVersion,
              adoptedAtUTC: adoptedAtUTC))
        }
        return FlashWorkspacePresentation(availability: availability, targets: targets)
      }
    }
  }

  private static func decodeAvailability(
    _ response: Result<Data, FlashXPCReadFailure>
  ) -> FlashOperationAvailability {
    switch response {
    case .failure(let failure):
      return .unavailable(reasons: [failure.message])
    case .success(let data):
      switch decodeResultArray(data) {
      case .failure(let failure):
        return .unavailable(reasons: [failure.message])
      case .success(let entries):
        guard
          let flash = entries.first(where: { $0["reference"] as? String == "flash.dayu200@1" }),
          let state = flash["availability"] as? String
        else {
          return .unavailable(reasons: ["flash.dayu200@1 is not published by this Runtime"])
        }
        let reasons = flash["reasons"] as? [String] ?? []
        return state == "available"
          ? .available
          : .unavailable(
            reasons: reasons.isEmpty ? ["Runtime did not report an availability reason"] : reasons)
      }
    }
  }

  private static func decodeResultArray(
    _ data: Data
  ) -> Result<[[String: Any]], FlashResponseFailure> {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .failure(FlashResponseFailure(message: "Runtime returned an unreadable response"))
    }
    if let error = object["error"] as? [String: Any] {
      let code = error["code"] as? String ?? "unknown"
      let message = error["message"] as? String ?? "no message"
      return .failure(
        FlashResponseFailure(message: "Runtime refused the request: \(code) — \(message)"))
    }
    guard object["ok"] as? Bool == true, let result = object["result"] as? [[String: Any]] else {
      return .failure(FlashResponseFailure(message: "Runtime returned no result list"))
    }
    return .success(result)
  }
}

private struct FlashResponseFailure: Error {
  let message: String
}

private enum FlashXPCResponseDecoding {
  static func resultObject(
    _ response: Result<Data, FlashXPCReadFailure>
  ) async throws -> [String: Any] {
    let data: Data
    switch response {
    case .success(let value): data = value
    case .failure(let failure): throw FlashResponseFailure(message: failure.message)
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw FlashResponseFailure(message: "Runtime returned an unreadable response")
    }
    if let error = object["error"] as? [String: Any] {
      let code = error["code"] as? String ?? "unknown"
      let message = error["message"] as? String ?? "no message"
      throw FlashResponseFailure(message: "Runtime refused the request: \(code) — \(message)")
    }
    guard object["ok"] as? Bool == true,
      let result = object["result"] as? [String: Any]
    else {
      throw FlashResponseFailure(message: "Runtime returned no result object")
    }
    return result
  }
}

enum FlashPlanPresentationBuilder {
  static func prepare(
    archiveURL: URL,
    profileReference: String,
    mode: RockchipFlashExecutionMode,
    target: FlashTargetPresentation?
  ) -> FlashPlanPreparationResult {
    guard FileManager.default.isReadableFile(atPath: archiveURL.path) else {
      return .failed(code: .fileAccessDenied, detail: nil)
    }
    guard let board = RockchipFlashProfile.board(reference: profileReference) else {
      return .failed(code: .unsupportedBundle, detail: profileReference)
    }
    do {
      let profile = try board.forArchive(at: archiveURL)
      let observation = RockchipImagesArchiveObservation(
        archiveSizeBytes: profile.archiveSizeBytes,
        archiveSHA256: profile.archiveSHA256,
        members: profile.members.map {
          RockchipArchiveMemberObservation(
            name: $0.name, sizeBytes: $0.sizeBytes, sha256: $0.sha256)
        })
      let provider = RockchipRockUSBFlashProvider(profile: profile)
      let plan = try materializePlan(
        provider: provider,
        mode: mode,
        archiveValidation: profile.validate(observation))
      return .ready(
        presentation(
          plan: plan,
          profile: profile,
          target: target,
          imageFileName: archiveURL.lastPathComponent))
    } catch let failure as GzipTarArchiveReaderError {
      switch failure {
      case .unreadableFile:
        return .failed(code: .unreadableArchive, detail: nil)
      case .notGzip, .unsupportedCompressionMethod, .corruptGzipHeader,
        .decompressionFailed, .truncatedArchive, .corruptTarHeader:
        return .failed(code: .invalidArchive, detail: String(describing: failure))
      }
    } catch let failure as RockchipArchiveIntrospectionFailure {
      return .failed(code: .unsupportedBundle, detail: String(describing: failure))
    } catch {
      return .failed(code: .planMaterializationFailed, detail: String(describing: error))
    }
  }

  /// Execute review must materialize the same canonical plan used by the
  /// protected campaign path. Preview-only modes retain a separate nonce so
  /// their step identities cannot be mistaken for executable facts.
  static func materializePlan(
    provider: RockchipRockUSBFlashProvider,
    mode: RockchipFlashExecutionMode,
    archiveValidation: RockchipArchiveValidationVerdict
  ) throws -> RockchipFlashPlan {
    switch mode {
    case .execute:
      return try provider.makePlan(mode: mode, archiveValidation: archiveValidation)
    case .planOnly, .simulated:
      return try provider.makePlan(
        mode: mode,
        archiveValidation: archiveValidation,
        planNonce: "app-preview")
    }
  }

  static func presentation(
    plan: RockchipFlashPlan,
    profile: RockchipFlashProfile,
    target: FlashTargetPresentation?,
    imageFileName: String
  ) -> FlashExactPlanPresentation {
    let disposition: FlashPlanStepDisposition
    switch plan.executionMode {
    case .execute: disposition = .executionLocked
    case .planOnly: disposition = .planned
    case .simulated: disposition = .simulatedPreview
    }
    return FlashExactPlanPresentation(
      mode: plan.executionMode,
      target: target,
      profileReference: profile.catalogReference,
      toolchainFingerprint: RockchipFlashProfile.pinnedToolchainFingerprint,
      imageFileName: imageFileName,
      runtimeBuildVersion: profile.runtimeBuildVersion,
      archiveSizeBytes: profile.archiveSizeBytes,
      archiveSHA256: plan.archiveSHA256,
      mappedPartitionCount: profile.mappedPartitions.count,
      planDigestSHA256: plan.planDigestSHA256,
      stepSetDigestSHA256: plan.stepSetDigestSHA256,
      steps: plan.steps.map { step in
        FlashPlanStepPresentation(
          id: step.id,
          kind: step.kind.rawValue,
          argumentSummary: argumentSummary(step.arguments),
          effect: FlashPlanEffect(rawValue: step.effect.rawValue) ?? .hostOnly,
          disposition: disposition)
      },
      dataImpact: [
        .mappedPartitionsOverwritten(count: profile.mappedPartitions.count),
        .userDataDestroyed,
        .forbiddenAreasPreserved,
      ],
      partitions: profile.mappedPartitions.map { mapped in
        guard let member = profile.member(named: mapped.imageMemberName) else {
          preconditionFailure("validated profile is missing mapped member \(mapped.imageMemberName)")
        }
        return FlashPartitionPresentation(
          writeOrder: mapped.writeOrder,
          partitionName: mapped.partitionName,
          imageMemberName: mapped.imageMemberName,
          imageSizeBytes: member.sizeBytes,
          imageSHA256: member.sha256)
      },
      writeForbiddenMemberNames: profile.writeForbiddenMemberNames.sorted(),
      prerequisites: RockchipPrerequisiteIdentifier.allCases.compactMap { identifier in
        profile.prerequisites[identifier].map {
          FlashPrerequisitePresentation(identifier: identifier, requirement: $0)
        }
      })
  }

  private static func argumentSummary(_ arguments: [String: JSONValue]) -> String {
    let preferredKeys = [
      "partition", "imageArtifactId", "imageSize", "probeId", "targetMode", "expectedMode",
      "riskClass",
    ]
    let values = preferredKeys.compactMap { key -> String? in
      guard let value = arguments[key] else { return nil }
      return "\(key)=\(display(value))"
    }
    return values.isEmpty ? "—" : values.joined(separator: " · ")
  }

  private static func display(_ value: JSONValue) -> String {
    switch value {
    case .null: "null"
    case .bool(let value): value ? "true" : "false"
    case .integer(let value): String(value)
    case .unsignedInteger(let value): String(value)
    case .number(let value): String(value)
    case .string(let value): value
    case .array(let values): "[\(values.map(display).joined(separator: ", "))]"
    case .object: "{…}"
    }
  }
}

enum FlashXPCReadFailure: Error, Sendable, Equatable {
  case transport(String)

  var message: String {
    switch self {
    case .transport(let message): message
    }
  }
}

private enum FlashXPCTransport {
  static func request(
    method: String,
    params: [String: JSONValue]? = nil
  ) async -> Result<Data, FlashXPCReadFailure> {
    let frame: Data
    do {
      frame = try ArkDeckAgentXPC.requestFrame(method: method, params: params)
    } catch {
      return .failure(.transport("Could not compose a Runtime request"))
    }
    return await withCheckedContinuation { continuation in
      let box = FlashXPCConnectionBox(
        NSXPCConnection(machServiceName: ArkDeckAgentXPC.machServiceName, options: []))
      let connection = box.connection
      connection.remoteObjectInterface = NSXPCInterface(with: ArkDeckAgentXPCProtocol.self)
      connection.resume()
      let answered = OSAllocatedUnfairLock(initialState: false)
      @Sendable func finish(_ result: Result<Data, FlashXPCReadFailure>) {
        let alreadyAnswered = answered.withLock { state -> Bool in
          if state { return true }
          state = true
          return false
        }
        guard !alreadyAnswered else { return }
        box.connection.invalidate()
        continuation.resume(returning: result)
      }
      let proxy =
        connection.remoteObjectProxyWithErrorHandler { error in
          finish(.failure(.transport("ArkDeck Runtime is not reachable: \(error.localizedDescription)")))
        } as? ArkDeckAgentXPCProtocol
      guard let proxy else {
        finish(.failure(.transport("ArkDeck Runtime is not reachable")))
        return
      }
      proxy.sendRequestFrame(frame) { data, refusal in
        if let refusal {
          finish(.failure(.transport("Runtime transport refused this request: \(refusal)")))
        } else if let data {
          finish(.success(data))
        } else {
          finish(.failure(.transport("Runtime returned neither a response nor a reason")))
        }
      }
    }
  }
}

/// NSXPCConnection is thread-safe by contract but predates `Sendable`.
private final class FlashXPCConnectionBox: @unchecked Sendable {
  let connection: NSXPCConnection
  init(_ connection: NSXPCConnection) { self.connection = connection }
}

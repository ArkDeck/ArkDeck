// App-facing Flash planning and typed execution over Runtime's XPC door.
//
// The production provider reads operation availability and adopted target
// facts from the daemon, materializes an exact Rockchip plan in-process from a
// user-selected archive, imports that archive, and submits the published
// `flash.dayu200` typed operation. Runtime owns capability creation and all
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
  public let bootloaderStatus: RockchipBootloaderStatus
  public let targetLoadFailure: String?

  public init(
    availability: FlashOperationAvailability,
    targets: [FlashTargetPresentation],
    bootloaderStatus: RockchipBootloaderStatus = RockchipBootloaderStatus(
      disposition: .absent, observationCount: 0, mode: nil,
      targetID: nil, bindingRevision: nil),
    targetLoadFailure: String? = nil
  ) {
    self.availability = availability
    self.targets = targets
    self.bootloaderStatus = bootloaderStatus
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

public enum FlashPlanCancellation: String, Sendable, Equatable {
  case immediate
  case atSafeBoundary
  case criticalNonInterruptible
}

public struct FlashPlanStepPresentation: Sendable, Equatable, Identifiable {
  public let id: String
  public let kind: String
  public let argumentSummary: String
  public let effect: FlashPlanEffect
  public let cancellation: FlashPlanCancellation
  public let disposition: FlashPlanStepDisposition

  public init(
    id: String,
    kind: String,
    argumentSummary: String,
    effect: FlashPlanEffect,
    cancellation: FlashPlanCancellation,
    disposition: FlashPlanStepDisposition
  ) {
    self.id = id
    self.kind = kind
    self.argumentSummary = argumentSummary
    self.effect = effect
    self.cancellation = cancellation
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
  public let status: RockchipPrerequisiteStatus

  public var id: RockchipPrerequisiteIdentifier { identifier }

  public init(
    identifier: RockchipPrerequisiteIdentifier,
    requirement: RockchipPrerequisiteRequirement,
    status: RockchipPrerequisiteStatus = .unknown
  ) {
    self.identifier = identifier
    self.requirement = requirement
    self.status = status
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

  /// Required profile facts which the latest Runtime portrait did not prove.
  /// Unknown is a blocker just like an explicit negative: the one-click UI
  /// removes redundant confirmation ceremony, not the pre-effect fact gate.
  public var blockingRequiredPrerequisites: [FlashPrerequisitePresentation] {
    prerequisites.filter {
      $0.requirement == .required && $0.status != .satisfied
    }
  }

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

  func withPrerequisiteObservations(
    _ observations: [RockchipPrerequisiteObservation]
  ) -> FlashExactPlanPresentation {
    let statuses = Dictionary(
      observations.map { ($0.identifier, $0.status) },
      uniquingKeysWith: { existing, incoming in
        existing == .satisfied ? incoming : existing
      })
    return FlashExactPlanPresentation(
      mode: mode, target: target, profileReference: profileReference,
      toolchainFingerprint: toolchainFingerprint, imageFileName: imageFileName,
      runtimeBuildVersion: runtimeBuildVersion,
      archiveSizeBytes: archiveSizeBytes, archiveSHA256: archiveSHA256,
      mappedPartitionCount: mappedPartitionCount,
      planDigestSHA256: planDigestSHA256, stepSetDigestSHA256: stepSetDigestSHA256,
      steps: steps, dataImpact: dataImpact, partitions: partitions,
      writeForbiddenMemberNames: writeForbiddenMemberNames,
      prerequisites: prerequisites.map {
        FlashPrerequisitePresentation(
          identifier: $0.identifier, requirement: $0.requirement,
          status: statuses[$0.identifier] ?? .unknown)
      })
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

public struct FlashPostflightBindingPresentation: Sendable, Equatable {
  public let expected: String
  public let observed: String
  public let matches: Bool

  public init(expected: String, observed: String, matches: Bool) {
    self.expected = expected
    self.observed = observed
    self.matches = matches
  }
}

public enum FlashPostflightPresentationBuilder {
  /// A Loader activation may advance the target binding before the exact plan
  /// is submitted. Once submitted, Flash remains pinned to that materialized
  /// revision while the verified post-flash HDC route is associated with it.
  /// Treating every successful Flash as another revision advance makes a
  /// confirmed Runtime success appear as a UI failure.
  public static func binding(
    plannedRevision: Int,
    observedRevision: Int
  ) -> FlashPostflightBindingPresentation {
    FlashPostflightBindingPresentation(
      expected: "r\(plannedRevision) → r\(plannedRevision)",
      observed: "r\(plannedRevision) → r\(observedRevision)",
      matches: observedRevision == plannedRevision)
  }
}

public enum FlashSubmissionResult: Sendable, Equatable {
  case accepted(jobID: String)
  case failed(String)
}

public enum FlashRunResult: Sendable, Equatable {
  case completed(FlashSubmissionPresentation)
  case failed(String)
}

public enum FlashLoaderBindingResult: Sendable, Equatable {
  case bound(FlashTargetPresentation)
  case failed(String)
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
  func run(jobID: String) async -> FlashRunResult
  func bindCurrentLoader(target: FlashTargetPresentation) async -> FlashLoaderBindingResult
  func cancel(jobID: String) async -> Bool
}

public enum FlashApplicationFacade {
  public static let profileReferences = [RockchipFlashProfile.dayu200.catalogReference]

  public static func make(
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> any FlashApplicationProviding {
    if arguments.contains("--ui-test-flash") || arguments.contains("--ui-test-flash-plan") {
      return FlashFixtureApplicationProvider(arguments: arguments)
    }
    return FlashProductionApplicationProvider()
  }
}

private actor FlashProductionApplicationProvider: FlashApplicationProviding {
  func refreshWorkspace() async -> FlashWorkspacePresentation {
    async let operations = FlashXPCTransport.request(method: "operation.list")
    async let targets = FlashXPCTransport.request(method: "target.list")
    async let bootloader = FlashXPCTransport.request(method: "flash.bootloader-status")
    return FlashWorkspaceResponseDecoding.presentation(
      operationResponse: await operations,
      targetResponse: await targets,
      bootloaderResponse: await bootloader)
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
    let local = await Task.detached(priority: .userInitiated) {
      FlashPlanPresentationBuilder.prepare(
        archiveURL: archiveURL,
        profileReference: profileReference,
        mode: mode,
        target: target)
    }.value
    guard mode == .execute, let target, case .ready(let plan) = local else {
      return local
    }
    let response = await FlashXPCTransport.request(
      method: "flash.prerequisites",
      params: [
        "targetId": .string(target.id),
        "profileReference": .string(profileReference),
      ])
    switch FlashPrerequisiteResponseDecoding.observations(
      response, target: target, profileReference: profileReference)
    {
    case .success(let observations):
      return .ready(plan.withPrerequisiteObservations(observations))
    case .failure:
      // The exact plan remains reviewable, but every unobserved prerequisite
      // stays unknown. Runtime performs the authoritative probe before write.
      return local
    }
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
          params: [
            "targetId": .string(target.id),
            "name": .string(archiveURL.lastPathComponent),
            "byteCount": .integer(plan.archiveSizeBytes),
            "sha256": .string(plan.archiveSHA256),
          ]))
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
        operation: RuntimeOperationReference(id: "flash.dayu200"),
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
      return .accepted(jobID: jobID)
    } catch let failure as FlashResponseFailure {
      return .failed(failure.message)
    } catch {
      return .failed(String(describing: error))
    }
  }

  func run(jobID: String) async -> FlashRunResult {
    do {
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

  func cancel(jobID: String) async -> Bool {
    guard let result = try? await FlashXPCResponseDecoding.resultObject(
      await FlashXPCTransport.request(
        method: "job.cancel", params: ["jobId": .string(jobID)]))
    else { return false }
    return result["cancelRequested"] as? Bool == true
  }

  func bindCurrentLoader(
    target: FlashTargetPresentation
  ) async -> FlashLoaderBindingResult {
    do {
      let result = try await FlashXPCResponseDecoding.resultObject(
        await FlashXPCTransport.request(
          method: "flash.bind-current-loader",
          params: [
            "targetId": .string(target.id),
            "expectedBindingRevision": .integer(Int64(target.bindingRevision)),
          ]))
      guard result["targetId"] as? String == target.id,
        result["previousBindingRevision"] as? Int == target.bindingRevision,
        let revision = result["bindingRevision"] as? Int,
        revision == target.bindingRevision || revision == target.bindingRevision + 1,
        let evidence = result["selectionEvidenceSha256"] as? String,
        evidence.count == 64,
        evidence.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) })
      else {
        return .failed("Runtime returned incomplete Loader binding facts")
      }
      return .bound(
        FlashTargetPresentation(
          id: target.id,
          bindingRevision: revision,
          toolVersion: target.toolVersion,
          adoptedAtUTC: target.adoptedAtUTC))
    } catch let failure as FlashResponseFailure {
      return .failed(failure.message)
    } catch {
      return .failed(String(describing: error))
    }
  }
}

private actor FlashFixtureApplicationProvider: FlashApplicationProviding {
  private let fixtureStateURL: URL?

  init(arguments: [String]) {
    if let index = arguments.firstIndex(of: "--ui-test-fixture-state"),
      arguments.indices.contains(index + 1)
    {
      fixtureStateURL = URL(fileURLWithPath: arguments[index + 1])
    } else {
      fixtureStateURL = nil
    }
  }

  func refreshWorkspace() async -> FlashWorkspacePresentation {
    let fixtureState = fixtureStateURL.flatMap {
      try? String(contentsOf: $0, encoding: .utf8)
    } ?? ""
    let loaderIsUnbound = fixtureState.contains("--ui-test-flash-loader-unbound")
    return FlashWorkspacePresentation(
      availability: .available,
      targets: [
        FlashTargetPresentation(
          id: "target-fixture-dayu200",
          bindingRevision: 7,
          toolVersion: "3.2.0f",
          adoptedAtUTC: "2026-08-06T08:00:00Z")
      ],
      bootloaderStatus: RockchipBootloaderStatus(
        disposition: loaderIsUnbound ? .unbound : .exactBoundTarget,
        observationCount: 1,
        mode: "loader",
        targetID: loaderIsUnbound ? nil : "target-fixture-dayu200",
        bindingRevision: loaderIsUnbound ? nil : 7))
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
      let presentation = FlashPlanPresentationBuilder.presentation(
          plan: plan,
          profile: board,
          target: target,
          imageFileName: archiveURL.lastPathComponent)
      let observations = RockchipPrerequisiteIdentifier.allCases.map {
        RockchipPrerequisiteObservation(
          identifier: $0,
          status: $0 == .stablePower ? .unknown : .satisfied)
      }
      return .ready(presentation.withPrerequisiteObservations(observations))
    } catch {
      return .failed(code: .planMaterializationFailed, detail: String(describing: error))
    }
  }

  func submit(
    archiveURL _: URL,
    plan _: FlashExactPlanPresentation
  ) async -> FlashSubmissionResult {
    .accepted(jobID: "job-ui-fixture-flash")
  }

  func run(jobID _: String) async -> FlashRunResult {
    .completed(
      FlashSubmissionPresentation(
        jobID: "job-ui-fixture-flash", state: "succeeded", outcomeUnknown: false,
        timeline: ["jobCreated", "finalized"]))
  }

  func bindCurrentLoader(target: FlashTargetPresentation) async -> FlashLoaderBindingResult {
    .bound(
      FlashTargetPresentation(
        id: target.id,
        bindingRevision: target.bindingRevision + 1,
        toolVersion: target.toolVersion,
        adoptedAtUTC: target.adoptedAtUTC))
  }

  func cancel(jobID _: String) async -> Bool { true }
}

enum FlashWorkspaceResponseDecoding {
  static func presentation(
    operationResponse: Result<Data, FlashXPCReadFailure>,
    targetResponse: Result<Data, FlashXPCReadFailure>,
    bootloaderResponse: Result<Data, FlashXPCReadFailure> = .failure(
      .transport("Bootloader status was not requested"))
  ) -> FlashWorkspacePresentation {
    let availability = decodeAvailability(operationResponse)
    let bootloaderStatus = decodeBootloaderStatus(bootloaderResponse)
    switch targetResponse {
    case .failure(let failure):
      return FlashWorkspacePresentation(
        availability: availability,
        targets: [],
        bootloaderStatus: bootloaderStatus,
        targetLoadFailure: failure.message)
    case .success(let data):
      switch decodeResultArray(data) {
      case .failure(let failure):
        return FlashWorkspacePresentation(
          availability: availability,
          targets: [],
          bootloaderStatus: bootloaderStatus,
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
              bootloaderStatus: bootloaderStatus,
              targetLoadFailure: "Runtime returned a target without complete binding facts")
          }
          targets.append(
            FlashTargetPresentation(
              id: id,
              bindingRevision: revision,
              toolVersion: toolVersion,
              adoptedAtUTC: adoptedAtUTC))
        }
        return FlashWorkspacePresentation(
          availability: availability, targets: targets,
          bootloaderStatus: bootloaderStatus)
      }
    }
  }

  private static func decodeBootloaderStatus(
    _ response: Result<Data, FlashXPCReadFailure>
  ) -> RockchipBootloaderStatus {
    guard case .success(let data) = response,
      let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      envelope["ok"] as? Bool == true,
      let result = envelope["result"] as? [String: Any],
      let dispositionText = result["disposition"] as? String,
      let disposition = RockchipBootloaderBindingDisposition(rawValue: dispositionText),
      let count = result["observationCount"] as? Int
    else {
      return RockchipBootloaderStatus(
        disposition: .absent, observationCount: 0, mode: nil,
        targetID: nil, bindingRevision: nil)
    }
    return RockchipBootloaderStatus(
      disposition: disposition,
      observationCount: count,
      mode: result["mode"] as? String,
      targetID: result["targetId"] as? String,
      bindingRevision: result["bindingRevision"] as? Int)
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
          let flash = entries.first(where: { $0["reference"] as? String == "flash.dayu200" }),
          let state = flash["availability"] as? String
        else {
          return .unavailable(reasons: ["flash.dayu200 is not published by this Runtime"])
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

enum FlashPrerequisiteResponseDecoding {
  static func observations(
    _ response: Result<Data, FlashXPCReadFailure>,
    target: FlashTargetPresentation,
    profileReference: String
  ) -> Result<[RockchipPrerequisiteObservation], FlashResponseFailure> {
    let data: Data
    switch response {
    case .success(let value): data = value
    case .failure(let failure):
      return .failure(FlashResponseFailure(message: failure.message))
    }
    guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return .failure(FlashResponseFailure(message: "Runtime returned an unreadable response"))
    }
    if let error = envelope["error"] as? [String: Any] {
      let code = error["code"] as? String ?? "unknown"
      let message = error["message"] as? String ?? "no message"
      return .failure(
        FlashResponseFailure(message: "Runtime refused the request: \(code) — \(message)"))
    }
    guard envelope["ok"] as? Bool == true,
      let result = envelope["result"] as? [String: Any],
      result["targetId"] as? String == target.id,
      result["bindingRevision"] as? Int == target.bindingRevision,
      result["profileReference"] as? String == profileReference,
      let rows = result["observations"] as? [[String: Any]]
    else {
      return .failure(
        FlashResponseFailure(message: "Runtime returned mismatched prerequisite facts"))
    }
    var seen: Set<RockchipPrerequisiteIdentifier> = []
    var observations: [RockchipPrerequisiteObservation] = []
    for row in rows {
      guard let identifierText = row["identifier"] as? String,
        let identifier = RockchipPrerequisiteIdentifier(rawValue: identifierText),
        !seen.contains(identifier),
        let statusText = row["status"] as? String,
        let status = RockchipPrerequisiteStatus(rawValue: statusText)
      else {
        return .failure(
          FlashResponseFailure(message: "Runtime returned malformed prerequisite facts"))
      }
      seen.insert(identifier)
      observations.append(
        RockchipPrerequisiteObservation(identifier: identifier, status: status))
    }
    guard seen == Set(RockchipPrerequisiteIdentifier.allCases) else {
      return .failure(
        FlashResponseFailure(message: "Runtime omitted a prerequisite fact"))
    }
    return .success(observations)
  }
}

struct FlashResponseFailure: Error {
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
          cancellation: FlashPlanCancellation(rawValue: step.cancellation.rawValue) ?? .immediate,
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

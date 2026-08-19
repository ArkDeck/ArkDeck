import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

final class FlashApplicationFacadeContractTests: XCTestCase {
  func testFlashImageArchiveSelectionPolicyAllowsOnlySupportedFilenameSuffixes() {
    for filename in [
      "dayu200-images.tar.gz",
      "dayu200-images.TAR.GZ",
      "dayu200-images.zip",
      "dayu200-images.ZIP",
      "dayu200-images.7z",
      "dayu200-images.7Z",
    ] {
      XCTAssertTrue(
        FlashImageArchiveSelectionPolicy.allows(URL(filePath: "/tmp/\(filename)")),
        filename)
    }

    for filename in [
      "dayu200-images.gz",
      "dayu200-images.tar",
      "dayu200-images.dmg",
      "dayu200-images.zip.txt",
      ".zip",
    ] {
      XCTAssertFalse(
        FlashImageArchiveSelectionPolicy.allows(URL(filePath: "/tmp/\(filename)")),
        filename)
    }
  }

  func testFlashImageArchiveSelectionPolicyAcceptsContentAddressedRuntimeArtifacts() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "flash-artifact-selection-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    for (name, magic) in [
      ("ART-gzip", [UInt8](arrayLiteral: 0x1F, 0x8B, 0x08)),
      ("ART-zip", [UInt8](arrayLiteral: 0x50, 0x4B, 0x03, 0x04)),
      ("ART-7z", [UInt8](arrayLiteral: 0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C)),
    ] {
      let artifact = root.appending(path: name)
      try Data(magic).write(to: artifact)
      XCTAssertTrue(FlashImageArchiveSelectionPolicy.allows(artifact), name)
    }

    let unknown = root.appending(path: "ART-unknown")
    try Data("not an archive".utf8).write(to: unknown)
    XCTAssertFalse(FlashImageArchiveSelectionPolicy.allows(unknown))
  }

  func testPostflightBindingKeepsTheSubmittedPlanRevision() {
    let confirmed = FlashPostflightPresentationBuilder.binding(
      plannedRevision: 3,
      observedRevision: 3)

    XCTAssertEqual(confirmed.expected, "r3 → r3")
    XCTAssertEqual(confirmed.observed, "r3 → r3")
    XCTAssertTrue(confirmed.matches)

    let drifted = FlashPostflightPresentationBuilder.binding(
      plannedRevision: 3,
      observedRevision: 4)
    XCTAssertEqual(drifted.observed, "r3 → r4")
    XCTAssertFalse(drifted.matches)
  }

  func testLiveProgressProjectsBootloaderExtractionAndCurrentPartition() throws {
    let target = FlashTargetPresentation(
      id: "target-dayu200-a", bindingRevision: 4, toolVersion: "3.2.0f",
      adoptedAtUTC: "2026-08-06T08:00:00Z")
    let plan = try executePresentation(target: target)

    let entering = FlashLiveProgressProjector.project(
      status: FlashSubmissionPresentation(
        jobID: "job-live", state: "running", outcomeUnknown: false,
        timeline: ["intent enter-loader-mode"]),
      partitions: plan.partitions)
    XCTAssertEqual(entering.phase, .enteringBootloader)
    XCTAssertNil(entering.writePercentCompleted)

    let extracting = FlashLiveProgressProjector.project(
      status: FlashSubmissionPresentation(
        jobID: "job-live", state: "running", outcomeUnknown: false,
        timeline: [
          "intent flash-partitions"
        ],
        processProgress: RuntimeJobProcessProgress(
          stepID: "flash-partitions", phase: .staging,
          completedUnitCount: 0, totalUnitCount: 9)),
      partitions: plan.partitions)
    XCTAssertEqual(extracting.phase, .extractingImage)

    let writing = FlashLiveProgressProjector.project(
      status: FlashSubmissionPresentation(
        jobID: "job-live", state: "running", outcomeUnknown: false,
        timeline: [
          "intent flash-partitions"
        ],
        processProgress: RuntimeJobProcessProgress(
          stepID: "flash-partitions", phase: .writing, unitName: "system",
          completedUnitCount: 4, totalUnitCount: 9, currentUnitPercent: 35)),
      partitions: plan.partitions)
    XCTAssertEqual(writing.phase, .writingPartition)
    XCTAssertEqual(writing.partitionName, "system")
    XCTAssertEqual(writing.completedPartitionCount, 4)
    XCTAssertEqual(writing.currentPartitionPercent, 35)
    let ordered = plan.partitions.sorted { $0.writeOrder < $1.writeOrder }
    let expectedBytes =
      Double(ordered.prefix(4).reduce(Int64(0)) { $0 + $1.imageSizeBytes })
      + Double(ordered[4].imageSizeBytes) * 0.35
    let totalBytes = Double(ordered.reduce(Int64(0)) { $0 + $1.imageSizeBytes })
    XCTAssertEqual(
      try XCTUnwrap(writing.writeFractionCompleted),
      expectedBytes / totalBytes,
      accuracy: 0.000_001)
  }

  func testLiveProgressMovesPastACompletedFlashStep() {
    let projected = FlashLiveProgressProjector.project(
      status: FlashSubmissionPresentation(
        jobID: "job-live", state: "running", outcomeUnknown: false,
        timeline: [
          "progress flash-partitions phase=writing completed=9 total=9 unit=userdata percent=100",
          "verified flash-partitions []",
          "intent verify-flash-readback",
        ]),
      partitions: [])

    XCTAssertEqual(projected.phase, .verifyingPartitions)
    XCTAssertNil(projected.writeFractionCompleted)
  }

  func testLiveProgressNeverInterpretsTimelineTextAsProviderProgress() {
    let projected = FlashLiveProgressProjector.project(
      status: FlashSubmissionPresentation(
        jobID: "job-live", state: "running", outcomeUnknown: false,
        timeline: [
          "intent flash-partitions",
          "progress flash-partitions phase=writing completed=4 total=9 unit=system percent=99",
        ]),
      partitions: [])

    XCTAssertEqual(projected.phase, .extractingImage)
    XCTAssertNil(projected.partitionName)
    XCTAssertNil(projected.currentPartitionPercent)
  }

  func testFlashStatusDecoderAcceptsTypedProgressAndRejectsMalformedProgress() throws {
    let fields: [String: Any] = [
      "jobId": "job-live",
      "state": "running",
      "outcomeUnknown": false,
      "timeline": ["intent flash-partitions"],
      "processProgress": [
        "stepId": "flash-partitions",
        "phase": "writing",
        "unitName": "system",
        "completedUnitCount": 4,
        "totalUnitCount": 9,
        "currentUnitPercent": 35,
      ],
    ]
    let decoded = try XCTUnwrap(
      FlashJobStatusResponseDecoding.presentation(fields, expectedJobID: "job-live"))
    XCTAssertEqual(
      decoded.processProgress,
      RuntimeJobProcessProgress(
        stepID: "flash-partitions", phase: .writing, unitName: "system",
        completedUnitCount: 4, totalUnitCount: 9, currentUnitPercent: 35))

    var malformed = fields
    malformed["processProgress"] = [
      "stepId": "flash-partitions",
      "phase": "writing",
      "completedUnitCount": 10,
      "totalUnitCount": 9,
    ]
    XCTAssertNil(
      FlashJobStatusResponseDecoding.presentation(malformed, expectedJobID: "job-live"))
  }

  func testRuntimeAvailabilityAndTargetFactsDecodeWithoutInventingDefaults() throws {
    let operations = try response([
      [
        "reference": "flash.dayu200",
        "availability": "available",
        "reasons": [],
      ]
    ])
    let targets = try response([
      [
        "targetId": "target-dayu200-a",
        "bindingRevision": 4,
        "toolVersion": "3.2.0f",
        "adoptedAtUtc": "2026-08-06T08:00:00Z",
      ]
    ])

    let presentation = FlashWorkspaceResponseDecoding.presentation(
      operationResponse: .success(operations),
      targetResponse: .success(targets))

    XCTAssertEqual(presentation.availability, .available)
    XCTAssertEqual(
      presentation.targets,
      [
        FlashTargetPresentation(
          id: "target-dayu200-a",
          bindingRevision: 4,
          toolVersion: "3.2.0f",
          adoptedAtUTC: "2026-08-06T08:00:00Z")
      ])
    XCTAssertNil(presentation.targetLoadFailure)
  }

  func testUnavailableOperationKeepsRuntimeReasonsVisible() throws {
    let operations = try response([
      [
        "reference": "flash.dayu200",
        "availability": "unavailable",
        "reasons": ["provider_not_registered", "target facts are incomplete"],
      ]
    ])
    let presentation = FlashWorkspaceResponseDecoding.presentation(
      operationResponse: .success(operations),
      targetResponse: .success(try response([])))

    XCTAssertEqual(
      presentation.availability,
      .unavailable(reasons: ["provider_not_registered", "target facts are incomplete"]))
    XCTAssertTrue(presentation.targets.isEmpty)
  }

  func testMalformedTargetFailsClosedInsteadOfRenderingAnUnboundChoice() throws {
    let presentation = FlashWorkspaceResponseDecoding.presentation(
      operationResponse: .success(
        try response([
          ["reference": "flash.dayu200", "availability": "available", "reasons": []]
        ])),
      targetResponse: .success(
        try response([
          ["targetId": "target-without-binding-revision"]
        ])))

    XCTAssertEqual(presentation.availability, .available)
    XCTAssertTrue(presentation.targets.isEmpty)
    XCTAssertEqual(
      presentation.targetLoadFailure,
      "Runtime returned a target without complete binding facts")
  }

  func testBootloaderStatusProjectsUnboundLoaderWithoutRawIdentityFacts() throws {
    let bootloader = try JSONSerialization.data(withJSONObject: [
      "id": "bootloader", "ok": true,
      "result": [
        "disposition": "unbound",
        "observationCount": 1,
        "mode": "loader",
        "targetId": NSNull(),
        "bindingRevision": NSNull(),
      ],
    ])
    let presentation = FlashWorkspaceResponseDecoding.presentation(
      operationResponse: .success(
        try response([
          ["reference": "flash.dayu200", "availability": "available", "reasons": []]
        ])),
      targetResponse: .success(try response([])),
      bootloaderResponse: .success(bootloader))

    XCTAssertEqual(
      presentation.bootloaderStatus,
      RockchipBootloaderStatus(
        disposition: .unbound,
        observationCount: 1,
        mode: "loader",
        targetID: nil,
        bindingRevision: nil))
  }

  func testBootloaderStatusProjectsSelectedTargetThatNeedsFreshAttestation() throws {
    let bootloader = try JSONSerialization.data(withJSONObject: [
      "id": "bootloader", "ok": true,
      "result": [
        "disposition": "targetBindingUnprepared",
        "observationCount": 1,
        "mode": "loader",
        "targetId": "target-dayu200-a",
        "bindingRevision": 2,
      ],
    ])
    let presentation = FlashWorkspaceResponseDecoding.presentation(
      operationResponse: .success(
        try response([
          ["reference": "flash.dayu200", "availability": "available", "reasons": []]
        ])),
      targetResponse: .success(
        try response([
          [
            "targetId": "target-dayu200-a",
            "bindingRevision": 2,
            "toolVersion": "3.2.0f",
            "adoptedAtUtc": "2026-08-06T08:00:00Z",
          ]
        ])),
      bootloaderResponse: .success(bootloader))

    XCTAssertEqual(
      presentation.bootloaderStatus,
      RockchipBootloaderStatus(
        disposition: .targetBindingUnprepared,
        observationCount: 1,
        mode: "loader",
        targetID: "target-dayu200-a",
        bindingRevision: 2))
  }

  func testPlanPresentationPreservesEveryTypedStepAndMarksPlanOnlyAsNotExecuted() throws {
    let profile = RockchipFlashProfile.dayu200
    let review = try XCTUnwrap(FlashPlanPresentationBuilder.reviewSteps(mode: .planOnly))
    let target = FlashTargetPresentation(
      id: "target-dayu200-a",
      bindingRevision: 4,
      toolVersion: "3.2.0f",
      adoptedAtUTC: "2026-08-06T08:00:00Z")

    let presentation = FlashPlanPresentationBuilder.presentation(
      mode: .planOnly,
      profile: profile,
      target: target,
      imageFileName: "dayu200_img.tar.gz")

    XCTAssertEqual(presentation.steps.count, review.steps.count)
    XCTAssertEqual(presentation.steps.map(\.id), review.steps.map(\.id))
    XCTAssertTrue(presentation.steps.allSatisfy { $0.disposition == .planned })
    XCTAssertTrue(presentation.steps.contains { $0.effect == .destructive })
    XCTAssertEqual(presentation.target, target)
    XCTAssertEqual(presentation.profileReference, profile.catalogReference)
    XCTAssertEqual(presentation.archiveSHA256, profile.archiveSHA256)
    // No fabricated digest before submission (CHG-2026-066): the engine
    // materializes the executed plan at job.submit.
    XCTAssertNil(presentation.planDigestSHA256)
    XCTAssertEqual(
      presentation.dataImpact,
      [
        .mappedPartitionsOverwritten(count: 9),
        .userDataDestroyed,
        .forbiddenAreasPreserved,
      ])
    XCTAssertEqual(presentation.partitions.count, profile.mappedPartitions.count)
    XCTAssertEqual(
      presentation.partitions.map(\.partitionName),
      profile.mappedPartitions.map(\.partitionName))
    XCTAssertEqual(
      presentation.writeForbiddenMemberNames,
      profile.writeForbiddenMemberNames.sorted())
    XCTAssertEqual(
      Set(presentation.prerequisites.map(\.identifier)),
      Set(profile.prerequisites.keys))
    XCTAssertTrue(presentation.prerequisites.allSatisfy { $0.status == .unknown })
    XCTAssertEqual(
      Set(presentation.blockingRequiredPrerequisites.map(\.identifier)),
      Set([.loader, .recoveryPath, .unlocked]))

    let ready = presentation.withPrerequisiteObservations(
      RockchipPrerequisiteIdentifier.allCases.map {
        RockchipPrerequisiteObservation(
          identifier: $0,
          status: $0 == .stablePower ? .unknown : .satisfied)
      })
    XCTAssertTrue(ready.blockingRequiredPrerequisites.isEmpty)
  }

  func testExecutePresentationRemainsReviewOnlyUntilRuntimeSubmission() throws {
    let presentation = FlashPlanPresentationBuilder.presentation(
      mode: .execute,
      profile: RockchipFlashProfile.dayu200,
      target: nil,
      imageFileName: "dayu200_img.tar.gz")

    XCTAssertFalse(presentation.steps.isEmpty)
    XCTAssertTrue(presentation.steps.allSatisfy { $0.disposition == .executionLocked })
    XCTAssertNil(presentation.planDigestSHA256)
  }

  /// CHG-2026-066: the review presents the runtime's own facts — the step
  /// sequence is the catalog descriptor filtered by the engine's selection
  /// rule, and the step-set digest is the engine's own algorithm, i.e. the
  /// value the RuntimeCapability correlation pins.
  func testExecuteReviewPresentsTheEnginesOwnStepFacts() throws {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "flash.dayu200"))
    let review = try XCTUnwrap(FlashPlanPresentationBuilder.reviewSteps(mode: .execute))
    let selected = descriptor.steps.filter {
      RuntimeJobEngine.stepIsRequested(
        $0, descriptor: descriptor,
        inputs: FlashPlanPresentationBuilder.reviewSelectionInputs)
    }

    XCTAssertEqual(review.steps.map(\.id), selected.map(\.stepID))
    XCTAssertEqual(review.steps.map(\.kind), selected.map(\.kind.rawValue))
    XCTAssertEqual(
      review.steps.map(\.effect.rawValue), selected.map(\.effect.rawValue))
    XCTAssertEqual(
      review.steps.map(\.cancellation.rawValue),
      selected.map(\.cancellation.rawValue))
    XCTAssertEqual(
      review.stepSetDigestSHA256,
      RuntimeJobEngine.stepSetDigest(
        descriptor: descriptor,
        inputs: FlashPlanPresentationBuilder.reviewSelectionInputs))
    // The exact value the bench job records pinned into the RuntimeCapability
    // correlation for the default full-verification request (measured on
    // job-a4b7d539… and job-b00e006a…, 2026-08-18/19). If the catalog
    // legitimately evolves, re-pin this against a fresh job record — the
    // point of the constant is that review and authorization move together.
    XCTAssertEqual(
      review.stepSetDigestSHA256,
      "c1ab01f8c7c24649080d109c481f9c034ffb73edcc62033684ac8a59875e0b12")
  }

  func testAllReviewModesPresentTheSameCatalogStepIdentities() throws {
    let execute = try XCTUnwrap(FlashPlanPresentationBuilder.reviewSteps(mode: .execute))
    for mode in [RockchipFlashExecutionMode.planOnly, .simulated] {
      let preview = try XCTUnwrap(FlashPlanPresentationBuilder.reviewSteps(mode: mode))
      // There is one truth now: previews show the same catalog identities the
      // engine will select, distinguished by disposition, not by fabricated
      // nonce step ids (retired with the provider plan model).
      XCTAssertEqual(preview.steps.map(\.id), execute.steps.map(\.id))
      XCTAssertEqual(preview.stepSetDigestSHA256, execute.stepSetDigestSHA256)
      XCTAssertNotEqual(
        preview.steps.map(\.disposition), execute.steps.map(\.disposition))
    }
    for step in execute.steps {
      XCTAssertFalse(step.id.hasPrefix("rk-"), step.id)
      XCTAssertFalse(step.id.contains("wlx"), step.id)
    }
  }

  func testPlanPresentationPreservesCriticalCancellationSemantics() throws {
    let target = FlashTargetPresentation(
      id: "target-dayu200-a",
      bindingRevision: 4,
      toolVersion: "3.2.0f",
      adoptedAtUTC: "2026-08-06T08:00:00Z")
    let presentation = try executePresentation(target: target)

    XCTAssertEqual(
      presentation.steps.first(where: { $0.kind == "flashPartition" })?.cancellation,
      .criticalNonInterruptible)
  }

  func testPrerequisiteResponsePinsTargetBindingProfileAndClosedVocabulary() throws {
    let target = FlashTargetPresentation(
      id: "target-dayu200-a", bindingRevision: 4, toolVersion: "3.2.0f",
      adoptedAtUTC: "2026-08-06T08:00:00Z")
    let rows = RockchipPrerequisiteIdentifier.allCases.map {
      ["identifier": $0.rawValue, "status": "satisfied"]
    }
    let data = try JSONSerialization.data(withJSONObject: [
      "id": "test", "ok": true,
      "result": [
        "targetId": target.id,
        "bindingRevision": target.bindingRevision,
        "profileReference": "dayu200",
        "observations": rows,
      ],
    ])

    let decoded = FlashPrerequisiteResponseDecoding.observations(
      .success(data), target: target, profileReference: "dayu200")
    guard case .success(let observations) = decoded else {
      return XCTFail("matching Runtime prerequisite facts must decode")
    }
    XCTAssertEqual(
      Set(observations.map(\.identifier)), Set(RockchipPrerequisiteIdentifier.allCases))

    let wrongBinding = FlashTargetPresentation(
      id: target.id, bindingRevision: 5, toolVersion: target.toolVersion,
      adoptedAtUTC: target.adoptedAtUTC)
    guard
      case .failure = FlashPrerequisiteResponseDecoding.observations(
        .success(data), target: wrongBinding, profileReference: "dayu200")
    else { return XCTFail("stale binding facts must fail closed") }
  }

  private func executePresentation(
    target: FlashTargetPresentation
  ) throws -> FlashExactPlanPresentation {
    FlashPlanPresentationBuilder.presentation(
      mode: .execute,
      profile: RockchipFlashProfile.dayu200,
      target: target,
      imageFileName: "dayu200_img.tar.gz")
  }

  private func response(_ result: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["id": "test", "ok": true, "result": result])
  }
}

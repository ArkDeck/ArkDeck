import Foundation
import XCTest

@testable import ArkDeckCore

final class WorkflowStepContractTests: XCTestCase {
  // TEST-AC-WF-001-01 / workflowSchemaContract
  func testTEST_AC_WF_001_01_UnregisteredHostCommandIsRejectedBeforeDispatch() throws {
    let data = Data(
      #"""
      {
        "id": "illegal-step",
        "kind": "hostCommand",
        "effect": "hostOnly",
        "cancellation": "immediate",
        "bindingRequirement": "none",
        "arguments": {"command": "rm -rf /"},
        "compensationDescriptors": []
      }
      """#.utf8
    )
    XCTAssertThrowsError(try WorkflowStepDecoder.decodeProfileStep(data)) { error in
      XCTAssertEqual(
        error as? WorkflowStepValidationError,
        .unsupportedKind(rawKind: "hostCommand", assumedEffect: .destructive)
      )
    }
  }

  func testTEST_AC_WF_001_01_RegisteredStepCannotHideAShellSurfaceInOptions() {
    let data = Data(
      #"""
      {
        "id": "remote-read",
        "kind": "runApprovedRemoteRead",
        "effect": "readOnly",
        "cancellation": "immediate",
        "bindingRequirement": "confirmedDevice",
        "arguments": {
          "catalogId": "arkdeck-remote-operations",
          "actionId": "deviceSummary",
          "parameters": {"command": "echo unsafe"},
          "artifactId": "artifact-1"
        },
        "compensationDescriptors": []
      }
      """#.utf8
    )

    XCTAssertThrowsError(try WorkflowStepDecoder.decodeProfileStep(data)) { error in
      XCTAssertEqual(
        error as? WorkflowStepValidationError,
        .unsafeArgumentKey(path: "arguments.parameters.command")
      )
    }
  }

  // TEST-AC-WF-002-01 / effectLatticeProperty
  func testTEST_AC_WF_002_01_EraseCannotBeDowngradedByProfileClassification() throws {
    let data = Data(
      #"""
      {
        "id": "erase-userdata",
        "kind": "erasePartition",
        "effect": "readOnly",
        "cancellation": "immediate",
        "bindingRequirement": "none",
        "arguments": {
          "providerOperationId": "erase.userdata",
          "partition": "userdata",
          "confirmationId": "confirm-1",
          "safeBoundaryId": "boundary-1"
        },
        "compensationDescriptors": []
      }
      """#.utf8
    )

    let step = try WorkflowStepDecoder.decodeProfileStep(data)

    XCTAssertEqual(step.kind, .erasePartition)
    XCTAssertEqual(step.effect, .destructive)
    XCTAssertEqual(step.cancellation, .criticalNonInterruptible)
    XCTAssertEqual(step.bindingRequirement, .confirmedDevice)
  }

  func testTEST_AC_WF_002_01_EveryClosedRegistryEntryEnforcesItsCoreMinimums() throws {
    XCTAssertEqual(
      Set(WorkflowStepKind.allCases.map(\.rawValue)).count, WorkflowStepKind.allCases.count)

    for kind in WorkflowStepKind.allCases {
      let resolution = WorkflowStepRegistry.resolve(rawKind: kind.rawValue)
      guard case .supported(let resolvedKind, let metadata) = resolution else {
        return XCTFail("registered kind unexpectedly unsupported: \(kind.rawValue)")
      }
      XCTAssertEqual(resolvedKind, kind)

      let step = try WorkflowStep(
        id: "step-\(kind.rawValue)",
        kind: kind,
        declaredEffect: .hostOnly,
        declaredCancellation: .immediate,
        declaredBindingRequirement: .none,
        arguments: validArguments(for: kind)
      )

      XCTAssertGreaterThanOrEqual(step.effect, metadata.minimumEffect, kind.rawValue)
      XCTAssertGreaterThanOrEqual(step.cancellation, metadata.minimumCancellation, kind.rawValue)
      XCTAssertGreaterThanOrEqual(
        step.bindingRequirement,
        metadata.minimumBindingRequirement,
        kind.rawValue
      )
    }
  }

  func testClosedRegistryKindsExactlyMatchTheLockedWorkflowStepContract() throws {
    let contract = try loadContract(named: "workflow-step.schema.json")
    let definitions = try XCTUnwrap(contract["$defs"] as? [String: Any])
    let kindDefinition = try XCTUnwrap(definitions["kind"] as? [String: Any])
    let contractKinds = try XCTUnwrap(kindDefinition["enum"] as? [String])

    XCTAssertEqual(WorkflowStepKind.allCases.map(\.rawValue), contractKinds)
    XCTAssertEqual(WorkflowStepRegistry.schemaIdentifier, contract["$id"] as? String)
  }

  func testRegistryMetadataExactlyMatchesTheLockedRegistry() throws {
    let records = try loadInlineYAMLRecords(named: "workflow-step-registry.yaml")
    XCTAssertEqual(records.count, WorkflowStepKind.allCases.count)

    for record in records {
      let kind = try XCTUnwrap(WorkflowStepKind(rawValue: try XCTUnwrap(record["kind"])))
      let metadata = WorkflowStepRegistry.metadata(for: kind)
      XCTAssertEqual(metadata.minimumEffect.rawValue, record["minimum_effect"], kind.rawValue)
      XCTAssertEqual(metadata.minimumCancellation.rawValue, record["cancellation"], kind.rawValue)
      XCTAssertEqual(
        metadata.minimumBindingRequirement.rawValue, record["binding"], kind.rawValue)
      XCTAssertEqual(
        metadata.profileExposable, record["profile_exposable"] == "true", kind.rawValue)
      XCTAssertEqual(metadata.bindingIsExact, record["binding_exact"] == "true", kind.rawValue)
    }
  }

  func testProfileExposureAndExactBindingRulesFailClosed() throws {
    let internalStep = try WorkflowStep(
      id: "probe-host",
      kind: .probeHostTool,
      declaredEffect: .hostOnly,
      declaredCancellation: .immediate,
      declaredBindingRequirement: .none,
      arguments: validArguments(for: .probeHostTool)
    )
    let internalData = try JSONEncoder().encode(internalStep)
    XCTAssertThrowsError(try WorkflowStepDecoder.decodeProfileStep(internalData)) { error in
      XCTAssertEqual(
        error as? WorkflowStepValidationError, .kindNotProfileExposable(.probeHostTool))
    }
    let trustedStep = try WorkflowStepDecoder.decodeCoreOrProviderStep(internalData)
    XCTAssertEqual(trustedStep.kind, .probeHostTool)

    let exposedStep = try WorkflowStep(
      id: "capture",
      kind: .captureRemoteStdout,
      declaredEffect: .readOnly,
      declaredCancellation: .immediate,
      declaredBindingRequirement: .confirmedDevice,
      arguments: validArguments(for: .captureRemoteStdout)
    )
    XCTAssertNoThrow(
      try WorkflowStepDecoder.decodeProfileStep(try JSONEncoder().encode(exposedStep)))

    XCTAssertThrowsError(
      try WorkflowStep(
        id: "server-lifecycle",
        kind: .mutateHDCServerLifecycle,
        declaredEffect: .destructive,
        declaredCancellation: .atSafeBoundary,
        declaredBindingRequirement: .confirmedDevice,
        arguments: validArguments(for: .mutateHDCServerLifecycle)
      )
    ) { error in
      XCTAssertEqual(
        error as? WorkflowStepValidationError,
        .exactBindingMismatch(
          kind: .mutateHDCServerLifecycle, declared: .confirmedDevice, required: .none)
      )
    }
  }

  func testProfileExposureCoversEveryCompensationDescriptor() throws {
    let internalCompensationKinds: [WorkflowStepKind] = [
      .stopRemoteCapture, .restoreParameter, .cleanupOwnedRemotePath,
    ]

    for kind in internalCompensationKinds {
      let compensation = try makeCompensationDescriptor(kind: kind)
      let root = try makeProfileStep(compensationDescriptors: [compensation])
      let data = try JSONEncoder().encode(root)

      do {
        _ = try WorkflowStepDecoder.decodeProfileStep(data)
        XCTFail("Profile decoded internal compensation kind \(kind.rawValue)")
      } catch {
        XCTAssertEqual(
          error as? WorkflowStepValidationError,
          .kindNotProfileExposable(kind)
        )
      }

      let trusted = try WorkflowStepDecoder.decodeCoreOrProviderStep(data)
      let trustedCompensation = try XCTUnwrap(trusted.compensationDescriptors.first)
      let metadata = WorkflowStepRegistry.metadata(for: kind)
      XCTAssertEqual(trustedCompensation.kind, kind)
      XCTAssertGreaterThanOrEqual(trustedCompensation.effect, metadata.minimumEffect)
      XCTAssertGreaterThanOrEqual(
        trustedCompensation.cancellation, metadata.minimumCancellation)
      XCTAssertGreaterThanOrEqual(
        trustedCompensation.bindingRequirement, metadata.minimumBindingRequirement)
    }
    let exposedCompensation = try makeCompensationDescriptor(kind: .stopApplication)
    let legalProfile = try makeProfileStep(compensationDescriptors: [exposedCompensation])
    XCTAssertNoThrow(
      try WorkflowStepDecoder.decodeProfileStep(try JSONEncoder().encode(legalProfile)))
  }

  func testStrictDecoderRejectsDuplicateMemberNamesAtEveryObjectDepth() {
    let fixtures: [(name: String, path: String, data: Data)] = [
      (
        "escaped duplicate kind",
        "$.kind",
        Data(
          #"""
          {
            "id": "erase-userdata",
            "kind": "erasePartition",
            "\u006b\u0069\u006e\u0064": "erasePartition",
            "effect": "destructive",
            "cancellation": "criticalNonInterruptible",
            "bindingRequirement": "confirmedDevice",
            "arguments": {
              "providerOperationId": "erase.userdata",
              "partition": "userdata",
              "confirmationId": "confirm-1",
              "safeBoundaryId": "boundary-1"
            },
            "compensationDescriptors": []
          }
          """#.utf8)
      ),
      (
        "duplicate effect",
        "$.effect",
        Data(
          #"""
          {
            "id": "erase-userdata",
            "kind": "erasePartition",
            "effect": "readOnly",
            "effect": "destructive",
            "cancellation": "criticalNonInterruptible",
            "bindingRequirement": "confirmedDevice",
            "arguments": {
              "providerOperationId": "erase.userdata",
              "partition": "userdata",
              "confirmationId": "confirm-1",
              "safeBoundaryId": "boundary-1"
            },
            "compensationDescriptors": []
          }
          """#.utf8)
      ),
      (
        "duplicate arguments",
        "$.arguments",
        Data(
          #"""
          {
            "id": "erase-userdata",
            "kind": "erasePartition",
            "effect": "destructive",
            "cancellation": "criticalNonInterruptible",
            "bindingRequirement": "confirmedDevice",
            "arguments": {
              "providerOperationId": "erase.userdata",
              "partition": "userdata",
              "confirmationId": "confirm-1",
              "safeBoundaryId": "boundary-1"
            },
            "arguments": {
              "providerOperationId": "erase.userdata",
              "partition": "userdata",
              "confirmationId": "confirm-1",
              "safeBoundaryId": "boundary-1"
            },
            "compensationDescriptors": []
          }
          """#.utf8)
      ),
      (
        "duplicate nested confirmationId",
        "$.arguments.confirmationId",
        Data(
          #"""
          {
            "id": "erase-userdata",
            "kind": "erasePartition",
            "effect": "destructive",
            "cancellation": "criticalNonInterruptible",
            "bindingRequirement": "confirmedDevice",
            "arguments": {
              "providerOperationId": "erase.userdata",
              "partition": "userdata",
              "confirmationId": "confirm-1",
              "confirmationId": "confirm-2",
              "safeBoundaryId": "boundary-1"
            },
            "compensationDescriptors": []
          }
          """#.utf8)
      ),
      (
        "duplicate parameters member",
        "$.arguments.parameters.filter",
        Data(
          #"""
          {
            "id": "capture",
            "kind": "captureRemoteStdout",
            "effect": "readOnly",
            "cancellation": "immediate",
            "bindingRequirement": "confirmedDevice",
            "arguments": {
              "catalogId": "arkui-ui-dump",
              "actionId": "nodeSummary",
              "parameters": {"filter": "one", "filter": "two"},
              "artifactId": "artifact-1"
            },
            "compensationDescriptors": []
          }
          """#.utf8)
      ),
      (
        "duplicate compensation kind",
        "$.compensationDescriptors[0].kind",
        Data(
          #"""
          {
            "id": "capture",
            "kind": "captureRemoteStdout",
            "effect": "readOnly",
            "cancellation": "immediate",
            "bindingRequirement": "confirmedDevice",
            "arguments": {
              "catalogId": "arkui-ui-dump",
              "actionId": "nodeSummary",
              "parameters": {},
              "artifactId": "artifact-1"
            },
            "compensationDescriptors": [{
              "id": "stop-capture",
              "kind": "stopRemoteCapture",
              "kind": "stopRemoteCapture",
              "effect": "deviceMutation",
              "cancellation": "atSafeBoundary",
              "bindingRequirement": "confirmedDevice",
              "trigger": "onFailure",
              "arguments": {"captureStepId": "capture", "stopPolicy": "graceful"},
              "argumentsHash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            }]
          }
          """#.utf8)
      ),
      (
        "duplicate compensation argumentsHash",
        "$.compensationDescriptors[0].argumentsHash",
        Data(
          #"""
          {
            "id": "capture",
            "kind": "captureRemoteStdout",
            "effect": "readOnly",
            "cancellation": "immediate",
            "bindingRequirement": "confirmedDevice",
            "arguments": {
              "catalogId": "arkui-ui-dump",
              "actionId": "nodeSummary",
              "parameters": {},
              "artifactId": "artifact-1"
            },
            "compensationDescriptors": [{
              "id": "stop-capture",
              "kind": "stopRemoteCapture",
              "effect": "deviceMutation",
              "cancellation": "atSafeBoundary",
              "bindingRequirement": "confirmedDevice",
              "trigger": "onFailure",
              "arguments": {"captureStepId": "capture", "stopPolicy": "graceful"},
              "argumentsHash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "argumentsHash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            }]
          }
          """#.utf8)
      ),
    ]

    for fixture in fixtures {
      do {
        _ = try WorkflowStepDecoder.decodeCoreOrProviderStep(fixture.data)
        XCTFail("decoded duplicate JSON member fixture: \(fixture.name)")
      } catch {
        XCTAssertEqual(
          error as? WorkflowStepValidationError,
          .duplicateJSONMemberName(path: fixture.path),
          fixture.name
        )
      }
    }
  }

  func testJSONMemberNamesRemainCaseSensitiveBeforeReservedKeyValidation() {
    let data = Data(
      #"""
      {
        "id": "capture",
        "kind": "captureRemoteStdout",
        "effect": "readOnly",
        "cancellation": "immediate",
        "bindingRequirement": "confirmedDevice",
        "arguments": {
          "catalogId": "arkui-ui-dump",
          "actionId": "nodeSummary",
          "parameters": {"Command": "one", "command": "two"},
          "artifactId": "artifact-1"
        },
        "compensationDescriptors": []
      }
      """#.utf8
    )

    XCTAssertThrowsError(try WorkflowStepDecoder.decodeProfileStep(data)) { error in
      guard case .unsafeArgumentKey(let path) = error as? WorkflowStepValidationError else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(path.lowercased(), "arguments.parameters.command")
    }
  }

  func testWorkflowStepDecodeRejectsUnknownTopLevelAndArgumentFields() {
    let unknownTopLevel = Data(
      #"""
      {
        "id": "probe-1",
        "kind": "probeDevice",
        "effect": "readOnly",
        "cancellation": "immediate",
        "bindingRequirement": "confirmedDevice",
        "arguments": {"evidencePolicy": "default"},
        "compensationDescriptors": [],
        "executable": "/bin/sh"
      }
      """#.utf8
    )
    XCTAssertThrowsError(try WorkflowStepDecoder.decodeCoreOrProviderStep(unknownTopLevel)) {
      error in
      XCTAssertEqual(error as? WorkflowStepValidationError, .unexpectedFields(["executable"]))
    }

    let unknownArgument = Data(
      #"""
      {
        "id": "probe-1",
        "kind": "probeDevice",
        "effect": "readOnly",
        "cancellation": "immediate",
        "bindingRequirement": "confirmedDevice",
        "arguments": {"evidencePolicy": "default", "script": "echo unsafe"},
        "compensationDescriptors": []
      }
      """#.utf8
    )
    XCTAssertThrowsError(try WorkflowStepDecoder.decodeCoreOrProviderStep(unknownArgument)) {
      error in
      XCTAssertEqual(
        error as? WorkflowStepValidationError,
        .unexpectedArgumentFields(kind: .probeDevice, fields: ["script"])
      )
    }
  }

  func testTypedArgumentsRejectWrongTypesAndUnknownCatalogActionPairs() {
    let wrongType = Data(
      #"""
      {
        "id": "probe-1",
        "kind": "probeDevice",
        "effect": "readOnly",
        "cancellation": "immediate",
        "bindingRequirement": "confirmedDevice",
        "arguments": {"evidencePolicy": 42},
        "compensationDescriptors": []
      }
      """#.utf8
    )
    XCTAssertThrowsError(try WorkflowStepDecoder.decodeCoreOrProviderStep(wrongType)) { error in
      guard
        case .invalidArgument(kind: .probeDevice, path: "arguments.evidencePolicy", _) =
          error as? WorkflowStepValidationError
      else {
        return XCTFail("unexpected error: \(error)")
      }
    }

    let mismatchedCatalogPair = Data(
      #"""
      {
        "id": "capture-1",
        "kind": "captureRemoteStdout",
        "effect": "readOnly",
        "cancellation": "immediate",
        "bindingRequirement": "confirmedDevice",
        "arguments": {
          "catalogId": "trace-presets",
          "actionId": "custom",
          "parameters": {},
          "artifactId": "artifact-1"
        },
        "compensationDescriptors": []
      }
      """#.utf8
    )
    XCTAssertThrowsError(try WorkflowStepDecoder.decodeProfileStep(mismatchedCatalogPair)) {
      error in
      guard
        case .invalidArgument(kind: .captureRemoteStdout, path: "arguments.catalogId", _) =
          error as? WorkflowStepValidationError
      else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  private func validArguments(for kind: WorkflowStepKind) -> [String: JSONValue] {
    let metadata = WorkflowStepRegistry.metadata(for: kind)
    let integerKeys: Set<String> = [
      "deadlineMilliseconds", "requiredBytes", "metadataHeadroomBytes", "sizeBytes",
      "rotationBytes", "retainedSegments", "reconnectDeadlineMilliseconds", "imageSize",
      "packageSize",
    ]
    var arguments = Dictionary(
      uniqueKeysWithValues: metadata.requiredArgumentKeys.map { key -> (String, JSONValue) in
        if key == "parameters" { return (key, .object([:])) }
        if key == "inputArtifactIds" { return (key, .array([.string("artifact-1")])) }
        if key == "localRelativePath" { return (key, .string("artifacts/output.bin")) }
        if key.lowercased().contains("remotepath") || key == "remotePath" {
          return (key, .string("/data/local/tmp/arkdeck"))
        }
        if key.lowercased().contains("sha256") || key.lowercased().hasSuffix("hash") {
          return (key, .string(String(repeating: "a", count: 64)))
        }
        if integerKeys.contains(key) { return (key, .integer(1)) }
        return (key, .string("fixture"))
      }
    )

    switch kind {
    case .mutateHDCServerLifecycle:
      arguments["action"] = .string("startManaged")
      arguments["expectedGeneration"] = .null
      arguments["expectedOwnership"] = .string("absent")
      arguments["confirmationId"] = .null
    case .captureRemoteStdout:
      arguments["catalogId"] = .string("arkui-ui-dump")
      arguments["actionId"] = .string("nodeSummary")
    case .captureRemoteFile:
      arguments["catalogId"] = .string("trace-presets")
      arguments["actionId"] = .string("custom")
    case .setParameter:
      arguments["readbackPolicy"] = .string("required")
    case .restoreParameter:
      arguments["restorePolicy"] = .string("restoreKnownValue")
    case .preflightHostStorage:
      arguments["writerClass"] = .string("light")
    case .requestConfirmation:
      arguments["riskClass"] = .string("deviceMutation")
    case .installPackage:
      arguments["replacePolicy"] = .string("forbid")
    case .resizeLogBuffer:
      arguments["restorePolicy"] = .string("restoreSnapshot")
    case .runApprovedRemoteRead:
      arguments["catalogId"] = .string("arkdeck-remote-operations")
      arguments["actionId"] = .string("deviceSummary")
    case .runApprovedRemoteMutation:
      arguments["catalogId"] = .string("arkdeck-remote-operations")
      arguments["actionId"] = .string("requestRootMode")
    case .rebootDevice:
      arguments["targetMode"] = .string("normal")
    case .finalizeSession:
      arguments["publicationPolicy"] = .string("atomicAfterValidation")
    default:
      break
    }
    return arguments
  }

  private func makeProfileStep(
    compensationDescriptors: [CompensationDescriptor]
  ) throws -> WorkflowStep {
    try WorkflowStep(
      id: "profile-capture",
      kind: .captureRemoteStdout,
      declaredEffect: .readOnly,
      declaredCancellation: .immediate,
      declaredBindingRequirement: .confirmedDevice,
      arguments: validArguments(for: .captureRemoteStdout),
      compensationDescriptors: compensationDescriptors
    )
  }

  private func makeCompensationDescriptor(
    kind: WorkflowStepKind
  ) throws -> CompensationDescriptor {
    try CompensationDescriptor(
      id: "compensation-\(kind.rawValue)",
      kind: kind,
      declaredEffect: .hostOnly,
      declaredCancellation: .immediate,
      declaredBindingRequirement: .none,
      trigger: .onFailure,
      arguments: validArguments(for: kind),
      argumentsHash: String(repeating: "a", count: 64)
    )
  }

  private func loadContract(named name: String) throws -> [String: Any] {
    let repositoryRoot = repositoryRoot()
    let data = try Data(contentsOf: repositoryRoot.appending(path: "openspec/contracts/\(name)"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func loadInlineYAMLRecords(named name: String) throws -> [[String: String]] {
    let url = repositoryRoot().appending(path: "openspec/contracts/\(name)")
    let text = try String(contentsOf: url, encoding: .utf8)
    return text.split(separator: "\n").compactMap { line in
      guard line.contains("- { kind:"),
        let openingBrace = line.firstIndex(of: "{"),
        let closingBrace = line.lastIndex(of: "}")
      else { return nil }
      let body = line[line.index(after: openingBrace)..<closingBrace]
      return Dictionary(
        uniqueKeysWithValues: body.split(separator: ",").compactMap { field in
          let pair = field.split(separator: ":", maxSplits: 1)
          guard pair.count == 2 else { return nil }
          return (
            pair[0].trimmingCharacters(in: .whitespaces),
            pair[1].trimmingCharacters(in: .whitespaces)
          )
        })
    }
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

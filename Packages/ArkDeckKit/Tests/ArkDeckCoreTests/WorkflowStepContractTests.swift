import Foundation
import Testing

@testable import ArkDeckCore

struct WorkflowStepContractTests {
  // TEST-AC-WF-001-01 / workflowSchemaContract
  @Test func TEST_AC_WF_001_01_UnregisteredHostCommandIsRejectedBeforeDispatch() throws {
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
    #expect(
      throws: WorkflowStepValidationError.unsupportedKind(
        rawKind: "hostCommand", assumedEffect: .destructive)
    ) {
      try WorkflowStepDecoder.decodeProfileStep(data)
    }
  }

  @Test func TEST_AC_WF_001_01_RegisteredStepCannotHideAShellSurfaceInOptions() {
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

    #expect(
      throws: WorkflowStepValidationError.unsafeArgumentKey(path: "arguments.parameters.command")
    ) {
      try WorkflowStepDecoder.decodeProfileStep(data)
    }
  }

  // TEST-AC-WF-002-01 / effectLatticeProperty
  @Test func TEST_AC_WF_002_01_EraseCannotBeDowngradedByProfileClassification() throws {
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

    #expect(step.kind == .erasePartition)
    #expect(step.effect == .destructive)
    #expect(step.cancellation == .criticalNonInterruptible)
    #expect(step.bindingRequirement == .confirmedDevice)
  }

  @Test func TEST_AC_WF_002_01_EveryClosedRegistryEntryEnforcesItsCoreMinimums() throws {
    #expect(
      Set(WorkflowStepKind.allCases.map(\.rawValue)).count == WorkflowStepKind.allCases.count)

    for kind in WorkflowStepKind.allCases {
      let resolution = WorkflowStepRegistry.resolve(rawKind: kind.rawValue)
      guard case .supported(let resolvedKind, let metadata) = resolution else {
        Issue.record("registered kind unexpectedly unsupported: \(kind.rawValue)")
        return
      }
      #expect(resolvedKind == kind)

      let step = try WorkflowStep(
        id: "step-\(kind.rawValue)",
        kind: kind,
        declaredEffect: .hostOnly,
        declaredCancellation: .immediate,
        declaredBindingRequirement: .none,
        arguments: validArguments(for: kind)
      )

      #expect(step.effect >= metadata.minimumEffect, "\(kind.rawValue)")
      #expect(step.cancellation >= metadata.minimumCancellation, "\(kind.rawValue)")
      #expect(
        step.bindingRequirement >= metadata.minimumBindingRequirement,
        "\(kind.rawValue)"
      )
    }
  }

  @Test func closedRegistryKindsExactlyMatchTheLockedWorkflowStepContract() throws {
    let contract = try loadContract(named: "workflow-step.schema.json")
    let definitions = try #require(contract["$defs"] as? [String: Any])
    let kindDefinition = try #require(definitions["kind"] as? [String: Any])
    let contractKinds = try #require(kindDefinition["enum"] as? [String])

    #expect(WorkflowStepKind.allCases.map(\.rawValue) == contractKinds)
    #expect(WorkflowStepRegistry.schemaIdentifier == contract["$id"] as? String)
  }

  /// The locked contract and the code that enforces it must agree on what
  /// each step's arguments are.
  ///
  /// Two comparisons already existed — the kind vocabulary, and the registry's
  /// effect/cancellation/binding rows — and neither reached the part that is
  /// three thousand lines of the contract: the per-kind argument objects. A
  /// new step kind writes its required keys twice, once in
  /// `WorkflowStepRegistry` and once in `$defs.<kind>Arguments`, and until now
  /// nothing compared them. Measured before writing this, they agreed
  /// everywhere; the exposure was structural rather than realised, and this
  /// keeps it that way.
  ///
  /// `WorkflowStepMetadata` is the right side to compare against because it is
  /// the enforcement point: `WorkflowStepValidator.validate(arguments:for:)`
  /// reads `requiredArgumentKeys` and `allowedArgumentKeys` directly, so this
  /// asserts the document against the executor rather than against a third
  /// transcription of the same list.
  @Test func everyStepKindsArgumentContractMatchesTheRegistryItIsEnforcedBy() throws {
    let contract = try loadContract(named: "workflow-step.schema.json")
    let definitions = try #require(contract["$defs"] as? [String: Any])
    let chain = try #require(
      (definitions["typedArgumentsByKind"] as? [String: Any])?["allOf"] as? [[String: Any]])

    // The chain maps kinds to argument objects two ways — one kind by `const`,
    // a group of kinds sharing an object by `enum` — and then refines: a kind
    // may additionally require a key, or be forbidden one the shared object
    // allows. All three shapes have to be read, or the comparison silently
    // covers only part of the vocabulary.
    var referenced: [String: String] = [:]
    var additionalRequired: [String: Set<String>] = [:]
    var forbidden: [String: Set<String>] = [:]
    for entry in chain {
      let condition =
        ((entry["if"] as? [String: Any])?["properties"] as? [String: Any])?["kind"]
        as? [String: Any]
      let kinds: [String]
      if let single = condition?["const"] as? String {
        kinds = [single]
      } else if let group = condition?["enum"] as? [String] {
        kinds = group
      } else {
        continue
      }
      guard
        let arguments =
          ((entry["then"] as? [String: Any])?["properties"] as? [String: Any])?["arguments"]
          as? [String: Any]
      else { continue }
      if let reference = arguments["$ref"] as? String {
        for kind in kinds { referenced[kind] = String(reference.split(separator: "/").last ?? "") }
      } else if let required = arguments["required"] as? [String] {
        for kind in kinds { additionalRequired[kind, default: []].formUnion(required) }
      } else if let absent = (arguments["not"] as? [String: Any])?["required"] as? [String] {
        for kind in kinds { forbidden[kind, default: []].formUnion(absent) }
      }
    }

    for kind in WorkflowStepKind.allCases {
      let raw = kind.rawValue
      let name = try #require(referenced[raw], "\(raw): the contract maps it to no arguments object")
      let object = try #require(definitions[name] as? [String: Any], "\(name)")
      let metadata = WorkflowStepRegistry.metadata(for: kind)

      let contractRequired =
        Set(object["required"] as? [String] ?? []).union(additionalRequired[raw] ?? [])
      #expect(
        contractRequired == metadata.requiredArgumentKeys,
        "\(raw): the contract and the validator disagree on which arguments are required")

      let contractAllowed =
        Set((object["properties"] as? [String: Any])?.keys ?? [:].keys)
        .subtracting(forbidden[raw] ?? [])
      #expect(
        contractAllowed == metadata.allowedArgumentKeys,
        "\(raw): the contract and the validator disagree on which arguments are accepted")

      #expect(
        object["additionalProperties"] as? Bool == false,
        "\(raw): the arguments object must be closed, as the validator is")
    }
  }

  @Test func registryMetadataExactlyMatchesTheLockedRegistry() throws {
    let records = try loadInlineYAMLRecords(named: "workflow-step-registry.yaml")
    #expect(records.count == WorkflowStepKind.allCases.count)

    for record in records {
      // Swift Testing rejects a #require nested in another #require.
      let rawKind = try #require(record["kind"])
      let kind = try #require(WorkflowStepKind(rawValue: rawKind))
      let metadata = WorkflowStepRegistry.metadata(for: kind)
      #expect(metadata.minimumEffect.rawValue == record["minimum_effect"], "\(kind.rawValue)")
      #expect(
        metadata.minimumCancellation.rawValue == record["cancellation"], "\(kind.rawValue)")
      #expect(
        metadata.minimumBindingRequirement.rawValue == record["binding"], "\(kind.rawValue)")
      #expect(
        metadata.profileExposable == (record["profile_exposable"] == "true"),
        "\(kind.rawValue)")
      #expect(
        metadata.bindingIsExact == (record["binding_exact"] == "true"), "\(kind.rawValue)")
    }
  }

  @Test func profileExposureAndExactBindingRulesFailClosed() throws {
    let internalStep = try WorkflowStep(
      id: "probe-host",
      kind: .probeHostTool,
      declaredEffect: .hostOnly,
      declaredCancellation: .immediate,
      declaredBindingRequirement: .none,
      arguments: validArguments(for: .probeHostTool)
    )
    let internalData = try JSONEncoder().encode(internalStep)
    #expect(throws: WorkflowStepValidationError.kindNotProfileExposable(.probeHostTool)) {
      try WorkflowStepDecoder.decodeProfileStep(internalData)
    }
    let trustedStep = try WorkflowStepDecoder.decodeCoreOrProviderStep(internalData)
    #expect(trustedStep.kind == .probeHostTool)

    let exposedStep = try WorkflowStep(
      id: "capture",
      kind: .captureRemoteStdout,
      declaredEffect: .readOnly,
      declaredCancellation: .immediate,
      declaredBindingRequirement: .confirmedDevice,
      arguments: validArguments(for: .captureRemoteStdout)
    )
    #expect(throws: Never.self) {
      _ = try WorkflowStepDecoder.decodeProfileStep(try JSONEncoder().encode(exposedStep))
    }

    #expect(
      throws: WorkflowStepValidationError.exactBindingMismatch(
        kind: .mutateHDCServerLifecycle, declared: .confirmedDevice, required: .none)
    ) {
      try WorkflowStep(
        id: "server-lifecycle",
        kind: .mutateHDCServerLifecycle,
        declaredEffect: .destructive,
        declaredCancellation: .atSafeBoundary,
        declaredBindingRequirement: .confirmedDevice,
        arguments: validArguments(for: .mutateHDCServerLifecycle)
      )
    }
  }

  @Test func profileExposureCoversEveryCompensationDescriptor() throws {
    let internalCompensationKinds: [WorkflowStepKind] = [
      .stopRemoteCapture, .restoreParameter, .cleanupOwnedRemotePath,
    ]

    for kind in internalCompensationKinds {
      let compensation = try makeCompensationDescriptor(kind: kind)
      let root = try makeProfileStep(compensationDescriptors: [compensation])
      let data = try JSONEncoder().encode(root)

      do {
        _ = try WorkflowStepDecoder.decodeProfileStep(data)
        Issue.record("Profile decoded internal compensation kind \(kind.rawValue)")
      } catch {
        #expect(
          error as? WorkflowStepValidationError
            == .kindNotProfileExposable(kind)
        )
      }

      let trusted = try WorkflowStepDecoder.decodeCoreOrProviderStep(data)
      let trustedCompensation = try #require(trusted.compensationDescriptors.first)
      let metadata = WorkflowStepRegistry.metadata(for: kind)
      #expect(trustedCompensation.kind == kind)
      #expect(trustedCompensation.effect >= metadata.minimumEffect)
      #expect(
        trustedCompensation.cancellation >= metadata.minimumCancellation)
      #expect(
        trustedCompensation.bindingRequirement >= metadata.minimumBindingRequirement)
    }
    let exposedCompensation = try makeCompensationDescriptor(kind: .stopApplication)
    let legalProfile = try makeProfileStep(compensationDescriptors: [exposedCompensation])
    #expect(throws: Never.self) {
      _ = try WorkflowStepDecoder.decodeProfileStep(try JSONEncoder().encode(legalProfile))
    }
  }

  @Test func strictDecoderRejectsDuplicateMemberNamesAtEveryObjectDepth() {
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
        Issue.record("decoded duplicate JSON member fixture: \(fixture.name)")
      } catch {
        #expect(
          error as? WorkflowStepValidationError
            == .duplicateJSONMemberName(path: fixture.path),
          "\(fixture.name)"
        )
      }
    }
  }

  @Test func jsonMemberNamesRemainCaseSensitiveBeforeReservedKeyValidation() {
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

    let error = #expect(throws: WorkflowStepValidationError.self) {
      try WorkflowStepDecoder.decodeProfileStep(data)
    }
    // A missing or foreign error is already recorded by #expect(throws:).
    guard let error else { return }
    guard case .unsafeArgumentKey(let path) = error else {
      Issue.record("unexpected error: \(error)")
      return
    }
    #expect(path.lowercased() == "arguments.parameters.command")
  }

  @Test func workflowStepDecodeRejectsUnknownTopLevelAndArgumentFields() {
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
    #expect(throws: WorkflowStepValidationError.unexpectedFields(["executable"])) {
      try WorkflowStepDecoder.decodeCoreOrProviderStep(unknownTopLevel)
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
    #expect(
      throws: WorkflowStepValidationError.unexpectedArgumentFields(
        kind: .probeDevice, fields: ["script"])
    ) {
      try WorkflowStepDecoder.decodeCoreOrProviderStep(unknownArgument)
    }
  }

  @Test func typedArgumentsRejectWrongTypesAndUnknownCatalogActionPairs() {
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
    let wrongTypeError = #expect(throws: WorkflowStepValidationError.self) {
      try WorkflowStepDecoder.decodeCoreOrProviderStep(wrongType)
    }
    // A missing or foreign error is already recorded by #expect(throws:).
    if let wrongTypeError {
      switch wrongTypeError {
      case .invalidArgument(kind: .probeDevice, path: "arguments.evidencePolicy", _):
        break
      default:
        Issue.record("unexpected error: \(wrongTypeError)")
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
    let mismatchedPairError = #expect(throws: WorkflowStepValidationError.self) {
      try WorkflowStepDecoder.decodeProfileStep(mismatchedCatalogPair)
    }
    if let mismatchedPairError {
      switch mismatchedPairError {
      case .invalidArgument(kind: .captureRemoteStdout, path: "arguments.catalogId", _):
        break
      default:
        Issue.record("unexpected error: \(mismatchedPairError)")
      }
    }
  }

  private func validArguments(for kind: WorkflowStepKind) -> [String: JSONValue] {
    let metadata = WorkflowStepRegistry.metadata(for: kind)
    let integerKeys: Set<String> = [
      "deadlineMilliseconds", "requiredBytes", "metadataHeadroomBytes", "sizeBytes",
      "rotationBytes", "retainedSegments", "reconnectDeadlineMilliseconds", "imageSize",
      "packageSize", "lineStart", "lineEnd",
    ]
    var arguments = Dictionary(
      uniqueKeysWithValues: metadata.requiredArgumentKeys.map { key -> (String, JSONValue) in
        if key == "parameters" { return (key, .object([:])) }
        if key == "inputArtifactIds" { return (key, .array([.string("artifact-1")])) }
        if key == "allowedFileGlobs" { return (key, .array([.string("Sources/**")])) }
        if key == "analyzerRef" { return (key, .string("crash-signature@1")) }
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
    case .injectPointerInput:
      arguments["gesture"] = .string("tap")
      arguments["pointerX"] = .integer(640)
      arguments["pointerY"] = .integer(1500)
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
    case .signWorkspaceOpenHarmonyHap:
      arguments["signingPresetRef"] = .string("openharmony-release@1")
    case .prepareWorkspaceIsolation:
      arguments["expectedWorkspaceRevision"] = .string(String(repeating: "a", count: 64))
      arguments["workspaceRevision"] = .string(String(repeating: "b", count: 64))
      arguments["allowedFileScopesDigest"] = .string(String(repeating: "c", count: 64))
    case .sweepWorkspaceIsolation:
      arguments["retainLatestCount"] = .integer(2)
      arguments["minimumQuiescentSeconds"] = .integer(3_600)
      arguments["dryRun"] = .string("true")
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
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
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
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

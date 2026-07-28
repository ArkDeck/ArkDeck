import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckStorage

final class AgentDeviceOperationContractTests: XCTestCase {
  private struct Registry: Decodable {
    let schemaVersion: String
    let registryId: String
    let workflowStepSchemaId: String
    let unknownOperationDisposition: String
    let unknownProfileDisposition: String
    let unknownStepDisposition: String
    let effectOrder: [String]
    let cancellationOrder: [String]
    let bindingOrder: [String]
    let operations: [Operation]
    let humanBlockerRules: [HumanBlockerRule]
  }

  private struct Operation: Decodable {
    let id: String
    let minimumEffect: String
    let permittedEffects: [String]
    let minimumCancellation: String
    let bindingRequirement: String
    let permittedStepKinds: [String]
    let profilePolicy: String
    let escalationPolicy: String
    let authorityByEffect: [String: String]
    let profiles: [Profile]
  }

  private struct Profile: Decodable {
    let id: String
    let configurationId: String
    let configurationSha256: String
    let declaredEffect: String
    let declaredCancellation: String
    let declaredBindingRequirement: String
    let emittedStepKinds: [String]
  }

  private struct HumanBlockerRule: Decodable {
    let category: String
    let resumeProbeOperationId: String
    let requiredProhibitedAutomation: [String]
  }

  private struct SchemaFacts {
    let operationIDs: Set<String>
    let jobStates: Set<String>
    let terminalJobStates: Set<String>
    let requestRequired: Set<String>
    let requestAllowed: Set<String>
    let operationRequired: Set<String>
    let operationAllowed: Set<String>
    let humanRequired: Set<String>
    let humanAllowed: Set<String>
    let humanCategories: Set<String>
    let prohibitedAutomation: Set<String>
    let resumeProbes: Set<String>
  }

  private static let repositoryRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 {
      url.deleteLastPathComponent()
    }
    return url
  }()

  private static let changeRoot =
    repositoryRoot
    .appendingPathComponent("openspec/changes/chg-2026-025-ai-native-unattended-device-ops")
  private static let contractRoot = changeRoot.appendingPathComponent("contracts")
  private static let runRoot =
    changeRoot
    .appendingPathComponent("evidence/runs/TASK-AIN-009")

  func testSchemaIdentityClosedObjectsAndCoreEnumsAreFrozen() throws {
    let agent = try loadJSONObject(
      Self.contractRoot.appendingPathComponent("agent-device-operation.schema.v1-draft.json"))
    let human = try loadJSONObject(
      Self.contractRoot.appendingPathComponent("human-action-required.schema.v1-draft.json"))
    let registry = try loadJSONObject(
      Self.contractRoot.appendingPathComponent(
        "agent-device-operation-registry.schema.v1-draft.json"))

    XCTAssertEqual(
      agent["$id"] as? String,
      "https://arkdeck.dev/schemas/agent-device-operation-1.0.0.json")
    XCTAssertEqual(
      human["$id"] as? String,
      "https://arkdeck.dev/schemas/human-action-required-1.0.0.json")
    XCTAssertEqual(
      registry["$id"] as? String,
      "https://arkdeck.dev/schemas/agent-device-operation-registry-1.0.0.json")
    for schema in [agent, human, registry] {
      XCTAssertEqual(
        schema["$schema"] as? String, "https://json-schema.org/draft/2020-12/schema")
      try assertClosedObjects(schema, path: "$")
    }

    let facts = try schemaFacts(agent: agent, human: human)
    XCTAssertEqual(facts.jobStates, Set(JobState.allCases.map(\.rawValue)))
    XCTAssertEqual(
      facts.terminalJobStates,
      Set(JobState.allCases.filter(\.isTerminal).map(\.rawValue)))
    XCTAssertEqual(facts.operationIDs.count, 15)
    XCTAssertEqual(facts.humanCategories.count, 8)
    XCTAssertEqual(facts.prohibitedAutomation.count, 9)
    XCTAssertEqual(facts.resumeProbes.count, 5)
  }

  func testRegistryProfilesStrengthenCoreWorkflowMetadata() throws {
    let registry = try loadRegistry()
    let (agent, human, facts) = try loadSchemasAndFacts()

    XCTAssertEqual(registry.schemaVersion, "1.0.0")
    XCTAssertEqual(registry.registryId, "arkdeck-agent-device-operations")
    XCTAssertEqual(registry.workflowStepSchemaId, WorkflowStepRegistry.schemaIdentifier)
    XCTAssertEqual(registry.unknownOperationDisposition, "rejectAsDestructiveUnsupported")
    XCTAssertEqual(registry.unknownProfileDisposition, "rejectAsDestructiveUnsupported")
    XCTAssertEqual(registry.unknownStepDisposition, "rejectAsDestructiveUnsupported")
    XCTAssertEqual(registry.effectOrder, WorkflowEffect.allCases.map(\.rawValue))
    XCTAssertEqual(
      registry.cancellationOrder, WorkflowCancellationPolicy.allCases.map(\.rawValue))
    XCTAssertEqual(
      registry.bindingOrder, WorkflowBindingRequirement.allCases.map(\.rawValue))
    XCTAssertEqual(Set(registry.operations.map(\.id)), facts.operationIDs)
    XCTAssertEqual(registry.operations.count, facts.operationIDs.count)

    XCTAssertNil(
      validateRegistry(registry, facts: facts),
      "accepted registry must be a closed strengthening of Core metadata")
    let allProfiles = registry.operations.flatMap(\.profiles)
    XCTAssertEqual(allProfiles.count, 21)
    XCTAssertEqual(Set(allProfiles.map(\.id)).count, allProfiles.count)

    let humanDefinitions = try requiredDictionary(human, "$defs")
    let expectedCategories = try enumSet(humanDefinitions, "category")
    let expectedProhibited = try enumSet(humanDefinitions, "prohibitedAutomation")
    XCTAssertEqual(Set(registry.humanBlockerRules.map(\.category)), expectedCategories)
    XCTAssertEqual(
      Set(registry.humanBlockerRules.flatMap(\.requiredProhibitedAutomation)),
      expectedProhibited)

    let agentDefinitions = try requiredDictionary(agent, "$defs")
    XCTAssertEqual(try enumSet(agentDefinitions, "operationId"), facts.operationIDs)
  }

  func testPositiveAndSingleFactNegativeVectors() throws {
    let registry = try loadRegistry()
    let (_, _, facts) = try loadSchemasAndFacts()
    let corpus = try loadJSONObject(Self.runRoot.appendingPathComponent("vectors.json"))
    let requests = try requiredDictionary(corpus, "requests")
    let results = try requiredDictionary(corpus, "results")
    let humanActions = try requiredArray(corpus, "humanActions")
    let mutations = try requiredArray(corpus, "negativeMutations")
    let profiles = profileLookup(registry)
    let blockerRules = Dictionary(
      uniqueKeysWithValues: registry.humanBlockerRules.map { ($0.category, $0) })

    XCTAssertEqual(Set(requests.keys), ["e0", "e1", "e2"])
    XCTAssertEqual(Set(results.keys), ["e0", "e1", "e2", "human"])
    XCTAssertEqual(humanActions.count, 8)
    for request in requests.values {
      XCTAssertNil(validateRequest(request, facts: facts, profiles: profiles))
    }
    for result in results.values {
      XCTAssertNil(validateResult(result, facts: facts))
    }
    for action in humanActions {
      XCTAssertNil(
        validateHumanAction(
          action, facts: facts, blockerRules: blockerRules))
    }
    XCTAssertNil(
      validateHumanCrossReference(
        try XCTUnwrap(results["human"]), humanActions: humanActions))

    let forbiddenNames = Set(
      mutations.compactMap { mutation -> String? in
        guard
          let vector = mutation as? [String: Any],
          (vector["id"] as? String)?.hasPrefix("request-forbidden-") == true,
          let path = vector["path"] as? [String],
          path.count == 1
        else {
          return nil
        }
        return path[0].lowercased()
      })
    XCTAssertEqual(forbiddenNames, Self.forbiddenRequestFields)

    var rejected = 0
    for rawMutation in mutations {
      let mutation = try XCTUnwrap(rawMutation as? [String: Any])
      let identifier = try XCTUnwrap(mutation["id"] as? String)
      let expected = try XCTUnwrap(mutation["reasonCode"] as? String)
      let base = try XCTUnwrap(mutation["base"] as? String)
      let candidate = try applyMutation(
        mutation,
        base: try mutationBase(
          base, corpus: corpus,
          registryURL: Self.contractRoot.appendingPathComponent(
            "agent-device-operation-registry.v1-draft.json")))

      let actual: String?
      if base.hasPrefix("request:") {
        actual = validateRequest(candidate, facts: facts, profiles: profiles)
      } else if base.hasPrefix("result:") {
        actual =
          validateResult(candidate, facts: facts)
          ?? validateHumanCrossReference(candidate, humanActions: humanActions)
      } else if base.hasPrefix("human:") {
        actual = validateHumanAction(
          candidate, facts: facts, blockerRules: blockerRules)
      } else if base == "registry" {
        do {
          let bytes = try JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys])
          let mutatedRegistry = try JSONDecoder().decode(Registry.self, from: bytes)
          actual = validateRegistry(mutatedRegistry, facts: facts)
        } catch {
          actual = "REGISTRY_SHAPE"
        }
      } else {
        return XCTFail("unknown vector base \(base)")
      }
      XCTAssertEqual(actual, expected, identifier)
      rejected += 1
    }
    XCTAssertEqual(rejected, 49)

    print(
      "TEST-AIN-OP-CONTRACT-001 PASS requests=3 results=4 operations=15 profiles=21 "
        + "human_blockers=8 negatives=\(rejected) process_dispatch=0 device_dispatch=0 "
        + "hdc_dispatch=0 network=0")
  }

  func testDuplicateMembersIncludingEscapedNamesFailClosed() throws {
    for name in ["duplicate-request.json", "duplicate-request-escaped.json"] {
      let data = try Data(contentsOf: Self.runRoot.appendingPathComponent(name))
      var validator = StrictJSONDuplicateValidator(data: data)
      XCTAssertThrowsError(try validator.validate(), name) { error in
        guard case StrictJSONError.duplicateMemberName(let path) = error else {
          return XCTFail("\(name): unexpected error \(error)")
        }
        XCTAssertEqual(path, "$.requestId")
      }
    }
  }

  private func loadSchemasAndFacts() throws
    -> ([String: Any], [String: Any], SchemaFacts)
  {
    let agent = try loadJSONObject(
      Self.contractRoot.appendingPathComponent("agent-device-operation.schema.v1-draft.json"))
    let human = try loadJSONObject(
      Self.contractRoot.appendingPathComponent("human-action-required.schema.v1-draft.json"))
    return (agent, human, try schemaFacts(agent: agent, human: human))
  }

  private func loadRegistry() throws -> Registry {
    let url = Self.contractRoot.appendingPathComponent(
      "agent-device-operation-registry.v1-draft.json")
    let data = try Data(contentsOf: url)
    var duplicateValidator = StrictJSONDuplicateValidator(data: data)
    try duplicateValidator.validate()
    return try JSONDecoder().decode(Registry.self, from: data)
  }

  private func loadJSONObject(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    var duplicateValidator = StrictJSONDuplicateValidator(data: data)
    try duplicateValidator.validate()
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
  }

  private func schemaFacts(agent: [String: Any], human: [String: Any]) throws -> SchemaFacts {
    let agentDefinitions = try requiredDictionary(agent, "$defs")
    let request = try requiredDictionary(agentDefinitions, "request")
    let requestProperties = try requiredDictionary(request, "properties")
    let operation = try requiredDictionary(agentDefinitions, "operation")
    let operationProperties = try requiredDictionary(operation, "properties")
    let humanProperties = try requiredDictionary(human, "properties")
    let humanDefinitions = try requiredDictionary(human, "$defs")
    return SchemaFacts(
      operationIDs: try enumSet(agentDefinitions, "operationId"),
      jobStates: try enumSet(agentDefinitions, "jobState"),
      terminalJobStates: try enumSet(agentDefinitions, "terminalJobState"),
      requestRequired: Set(try requiredArray(request, "required").compactMap { $0 as? String }),
      requestAllowed: Set(requestProperties.keys),
      operationRequired: Set(
        try requiredArray(operation, "required").compactMap { $0 as? String }),
      operationAllowed: Set(operationProperties.keys),
      humanRequired: Set(
        try requiredArray(human, "required").compactMap { $0 as? String }),
      humanAllowed: Set(humanProperties.keys),
      humanCategories: try enumSet(humanDefinitions, "category"),
      prohibitedAutomation: try enumSet(humanDefinitions, "prohibitedAutomation"),
      resumeProbes: try enumSet(humanDefinitions, "resumeProbeOperationId"))
  }

  private func requiredDictionary(_ object: [String: Any], _ key: String) throws
    -> [String: Any]
  {
    try XCTUnwrap(object[key] as? [String: Any], key)
  }

  private func requiredArray(_ object: [String: Any], _ key: String) throws -> [Any] {
    try XCTUnwrap(object[key] as? [Any], key)
  }

  private func enumSet(_ definitions: [String: Any], _ name: String) throws -> Set<String> {
    let definition = try requiredDictionary(definitions, name)
    return Set(try requiredArray(definition, "enum").compactMap { $0 as? String })
  }

  private func assertClosedObjects(_ value: Any, path: String) throws {
    if let object = value as? [String: Any] {
      if object["type"] as? String == "object" {
        XCTAssertEqual(object["additionalProperties"] as? Bool, false, path)
      }
      for (key, nested) in object {
        try assertClosedObjects(nested, path: "\(path).\(key)")
      }
    } else if let array = value as? [Any] {
      for (index, nested) in array.enumerated() {
        try assertClosedObjects(nested, path: "\(path)[\(index)]")
      }
    }
  }

  private func profileLookup(_ registry: Registry) -> [String: (String, String, String)] {
    Dictionary(
      uniqueKeysWithValues: registry.operations.flatMap { operation in
        operation.profiles.map {
          ($0.id, (operation.id, $0.configurationId, $0.configurationSha256))
        }
      })
  }

  private func validateRegistry(_ registry: Registry, facts: SchemaFacts) -> String? {
    let operationIDs = registry.operations.map(\.id)
    guard
      operationIDs.count == facts.operationIDs.count,
      Set(operationIDs).count == operationIDs.count,
      Set(operationIDs) == facts.operationIDs
    else {
      return "REGISTRY_OPERATION_CLOSURE"
    }
    for operation in registry.operations {
      guard
        let floorEffect = WorkflowEffect(rawValue: operation.minimumEffect),
        let floorCancellation = WorkflowCancellationPolicy(
          rawValue: operation.minimumCancellation),
        let floorBinding = WorkflowBindingRequirement(rawValue: operation.bindingRequirement)
      else {
        return "REGISTRY_OPERATION_SHAPE"
      }
      let permittedEffects = Set(operation.permittedEffects)
      guard permittedEffects.contains(operation.minimumEffect) else {
        return "REGISTRY_EFFECT_DOWNGRADE"
      }
      let expectedAuthority = Dictionary(
        uniqueKeysWithValues: operation.permittedEffects.map { effect in
          (
            effect,
            [
              "readOnly": "readyTask",
              "deviceMutation": "deviceCapability",
              "destructive": "standingAuthorization",
            ][effect] ?? ""
          )
        })
      guard operation.authorityByEffect == expectedAuthority else {
        return "REGISTRY_AUTHORITY_MAPPING"
      }
      let profileIDs = operation.profiles.map(\.id)
      guard Set(profileIDs).count == profileIDs.count else {
        return "REGISTRY_DUPLICATE_PROFILE"
      }
      for profile in operation.profiles {
        guard
          let declaredEffect = WorkflowEffect(rawValue: profile.declaredEffect),
          let declaredCancellation = WorkflowCancellationPolicy(
            rawValue: profile.declaredCancellation),
          let declaredBinding = WorkflowBindingRequirement(
            rawValue: profile.declaredBindingRequirement)
        else {
          return "REGISTRY_PROFILE_SHAPE"
        }
        var requiredEffect = floorEffect
        var requiredCancellation = floorCancellation
        var requiredBinding = floorBinding
        for rawKind in profile.emittedStepKinds {
          guard operation.permittedStepKinds.contains(rawKind) else {
            if case .unsupported = WorkflowStepRegistry.resolve(rawKind: rawKind) {
              return "REGISTRY_UNKNOWN_STEP"
            }
            return "REGISTRY_STEP_NOT_PERMITTED"
          }
          switch WorkflowStepRegistry.resolve(rawKind: rawKind) {
          case .supported(_, let metadata):
            requiredEffect = max(requiredEffect, metadata.minimumEffect)
            requiredCancellation = max(
              requiredCancellation, metadata.minimumCancellation)
            requiredBinding = max(
              requiredBinding, metadata.minimumBindingRequirement)
          case .unsupported:
            return "REGISTRY_UNKNOWN_STEP"
          }
        }
        guard declaredEffect >= floorEffect else {
          return "REGISTRY_EFFECT_DOWNGRADE"
        }
        guard permittedEffects.contains(declaredEffect.rawValue) else {
          return "REGISTRY_ILLEGAL_ELEVATION"
        }
        if operation.escalationPolicy == "noElevation", declaredEffect != floorEffect {
          return "REGISTRY_ILLEGAL_ELEVATION"
        }
        if operation.escalationPolicy == "destructiveOnly",
          declaredEffect != .destructive
        {
          return "REGISTRY_EFFECT_DOWNGRADE"
        }
        guard declaredEffect >= requiredEffect else {
          return "REGISTRY_EFFECT_DOWNGRADE"
        }
        guard declaredCancellation >= requiredCancellation else {
          return "REGISTRY_CANCELLATION_DOWNGRADE"
        }
        guard declaredBinding >= requiredBinding else {
          return "REGISTRY_BINDING_DOWNGRADE"
        }
        guard (try? profileConfigurationDigest(profile)) == profile.configurationSha256 else {
          return "REGISTRY_CONFIGURATION_DIGEST"
        }
      }
    }
    return nil
  }

  private func profileConfigurationDigest(_ profile: Profile) throws -> String {
    let configuration: [String: Any] = [
      "configurationId": profile.configurationId,
      "declaredBindingRequirement": profile.declaredBindingRequirement,
      "declaredCancellation": profile.declaredCancellation,
      "declaredEffect": profile.declaredEffect,
      "emittedStepKinds": profile.emittedStepKinds,
    ]
    let data = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func validateRequest(
    _ value: Any,
    facts: SchemaFacts,
    profiles: [String: (String, String, String)]
  ) -> String? {
    if findForbiddenRequestField(value) != nil {
      return "REQUEST_FORBIDDEN_FIELD"
    }
    guard let request = value as? [String: Any] else {
      return "REQUEST_SHAPE"
    }
    let keys = Set(request.keys)
    guard facts.requestRequired.isSubset(of: keys), keys.isSubset(of: facts.requestAllowed)
    else {
      return "REQUEST_SHAPE"
    }
    guard request["documentType"] as? String == "request" else {
      return "REQUEST_SHAPE"
    }
    guard request["schemaVersion"] as? String == "1.0.0" else {
      return "UNKNOWN_SCHEMA_VERSION"
    }
    guard
      let operation = request["operation"] as? [String: Any],
      facts.operationRequired.isSubset(of: Set(operation.keys)),
      Set(operation.keys).isSubset(of: facts.operationAllowed)
    else {
      return "REQUEST_SHAPE"
    }
    guard
      let operationID = operation["id"] as? String,
      facts.operationIDs.contains(operationID)
    else {
      return "UNKNOWN_OPERATION"
    }
    guard
      let profileID = operation["profileId"] as? String,
      let profile = profiles[profileID],
      profile.0 == operationID
    else {
      return "UNKNOWN_PROFILE"
    }
    guard operation["configurationId"] as? String == profile.1 else {
      return "CONFIGURATION_ID_MISMATCH"
    }
    guard operation["configurationSha256"] as? String == profile.2 else {
      return "CONFIGURATION_DIGEST_MISMATCH"
    }
    return nil
  }

  private func validateResult(_ value: Any, facts: SchemaFacts) -> String? {
    guard let result = value as? [String: Any] else {
      return "RESULT_SHAPE"
    }
    guard result["schemaVersion"] as? String == "1.0.0" else {
      return "UNKNOWN_SCHEMA_VERSION"
    }
    guard
      let mode = result["executionMode"] as? String,
      let state = result["jobState"] as? String,
      facts.jobStates.contains(state),
      let disposition = result["disposition"] as? String,
      let certainty = result["outcomeCertainty"] as? String,
      let effect = result["resolvedEffect"] as? String
    else {
      return "RESULT_SHAPE"
    }
    if disposition == "policyBlocked", result["authorizationRef"] != nil {
      return "RESULT_POLICY_BLOCKED_AUTHORITY"
    }
    if mode != "execute", result["authorizationRef"] != nil {
      return "RESULT_NON_EXECUTE_AUTHORITY"
    }
    if let authorization = result["authorizationRef"] as? [String: Any],
      let kind = authorization["kind"] as? String
    {
      let expectedEffect = [
        "readyTask": "readOnly",
        "deviceCapability": "deviceMutation",
        "standingAuthorization": "destructive",
      ][kind]
      guard expectedEffect == effect else {
        return "RESULT_AUTHORITY_EFFECT_MISMATCH"
      }
    }
    if disposition == "terminal" {
      guard facts.terminalJobStates.contains(state) else {
        return "RESULT_DISPOSITION_STATE_MISMATCH"
      }
    } else if facts.terminalJobStates.contains(state) {
      return "RESULT_DISPOSITION_STATE_MISMATCH"
    }
    if disposition == "humanActionRequired" {
      guard result["humanActionId"] != nil, result["blockerCode"] != nil else {
        return "RESULT_HUMAN_REFERENCE"
      }
    } else if result["humanActionId"] != nil || result["blockerCode"] != nil {
      return "RESULT_HUMAN_REFERENCE"
    }
    if ["active", "policyBlocked", "humanActionRequired"].contains(disposition) {
      guard certainty == "notApplicable" else {
        return "RESULT_CERTAINTY_MISMATCH"
      }
    } else if state == "planned" {
      guard certainty == "notApplicable" else {
        return "RESULT_CERTAINTY_MISMATCH"
      }
    } else if ["succeeded", "failed", "cancelled"].contains(state) {
      guard certainty == "confirmed" else {
        return "RESULT_CERTAINTY_MISMATCH"
      }
    }
    return nil
  }

  private func validateHumanAction(
    _ value: Any,
    facts: SchemaFacts,
    blockerRules: [String: HumanBlockerRule]
  ) -> String? {
    guard let action = value as? [String: Any] else {
      return "HUMAN_SHAPE"
    }
    let keys = Set(action.keys)
    guard facts.humanRequired.isSubset(of: keys), keys.isSubset(of: facts.humanAllowed)
    else {
      return "HUMAN_SHAPE"
    }
    guard action["schemaVersion"] as? String == "1.0.0" else {
      return "UNKNOWN_SCHEMA_VERSION"
    }
    guard
      let minimumActionKey = action["minimumActionKey"] as? String,
      minimumActionKey.range(
        of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$",
        options: .regularExpression) != nil
    else {
      return "HUMAN_MINIMUM_ACTION_KEY_INVALID"
    }
    guard
      let category = action["category"] as? String,
      facts.humanCategories.contains(category),
      let rule = blockerRules[category]
    else {
      return "HUMAN_UNKNOWN_CATEGORY"
    }
    guard
      let prohibited = action["prohibitedAutomation"] as? [String],
      Set(prohibited).isSubset(of: facts.prohibitedAutomation)
    else {
      return "HUMAN_UNKNOWN_PROHIBITED_AUTOMATION"
    }
    guard Set(rule.requiredProhibitedAutomation).isSubset(of: Set(prohibited)) else {
      return "HUMAN_REQUIRED_PROHIBITION_MISSING"
    }
    guard action["resumeProbeOperationId"] as? String == rule.resumeProbeOperationId else {
      return "HUMAN_RESUME_PROBE_MISMATCH"
    }
    if action["status"] as? String == "resolvedByFreshProbe" {
      guard let resolution = action["resolution"] as? [String: Any] else {
        return "HUMAN_FRESH_PROBE_REQUIRED"
      }
      guard
        resolution["probeOperationId"] as? String
          == action["resumeProbeOperationId"] as? String
      else {
        return "HUMAN_FRESH_PROBE_MISMATCH"
      }
    } else if action["resolution"] != nil {
      return "HUMAN_FRESH_PROBE_STATUS"
    }
    return nil
  }

  private func validateHumanCrossReference(
    _ value: Any, humanActions: [Any]
  ) -> String? {
    guard
      let result = value as? [String: Any],
      result["disposition"] as? String == "humanActionRequired"
    else {
      return nil
    }
    guard let actionID = result["humanActionId"] as? String else {
      return "HUMAN_CROSS_REFERENCE_MISMATCH"
    }
    let matches = humanActions.compactMap { $0 as? [String: Any] }.filter {
      $0["actionId"] as? String == actionID
    }
    guard
      matches.count == 1,
      matches[0]["jobId"] as? String == result["jobId"] as? String,
      matches[0]["reasonCode"] as? String == result["blockerCode"] as? String
    else {
      return "HUMAN_CROSS_REFERENCE_MISMATCH"
    }
    return nil
  }

  private func findForbiddenRequestField(_ value: Any) -> String? {
    if let object = value as? [String: Any] {
      for (key, nested) in object {
        if Self.forbiddenRequestFields.contains(key.lowercased()) {
          return key
        }
        if let found = findForbiddenRequestField(nested) {
          return found
        }
      }
    } else if let array = value as? [Any] {
      for nested in array {
        if let found = findForbiddenRequestField(nested) {
          return found
        }
      }
    }
    return nil
  }

  private func mutationBase(
    _ base: String, corpus: [String: Any], registryURL: URL
  ) throws -> Any {
    if base == "registry" {
      return try loadJSONObject(registryURL)
    }
    let components = base.split(separator: ":", maxSplits: 1).map(String.init)
    guard components.count == 2 else {
      throw CocoaError(.coderInvalidValue)
    }
    if components[0] == "request" {
      return try XCTUnwrap(
        (try requiredDictionary(corpus, "requests"))[components[1]])
    }
    if components[0] == "result" {
      return try XCTUnwrap(
        (try requiredDictionary(corpus, "results"))[components[1]])
    }
    if components[0] == "human" {
      let actions = try requiredArray(corpus, "humanActions")
      return try XCTUnwrap(
        actions.first {
          ($0 as? [String: Any])?["category"] as? String == components[1]
        })
    }
    throw CocoaError(.coderInvalidValue)
  }

  private func applyMutation(_ mutation: [String: Any], base: Any) throws -> Any {
    let operation = try XCTUnwrap(mutation["operation"] as? String)
    let path = try XCTUnwrap(mutation["path"] as? [String])
    switch operation {
    case "set":
      return try replacing(
        base, path: ArraySlice(path), value: try XCTUnwrap(mutation["value"]))
    case "remove":
      return try removing(base, path: ArraySlice(path))
    case "appendCopy":
      let copyFrom = try XCTUnwrap(mutation["copyFrom"] as? [String])
      let value = try valueAt(base, path: ArraySlice(copyFrom))
      return try appending(base, path: ArraySlice(path), value: value)
    default:
      throw CocoaError(.coderInvalidValue)
    }
  }

  private func replacing(_ root: Any, path: ArraySlice<String>, value: Any) throws -> Any {
    guard let component = path.first else {
      return value
    }
    if var object = root as? [String: Any] {
      if path.count == 1 {
        object[component] = value
      } else {
        object[component] = try replacing(
          try XCTUnwrap(object[component]), path: path.dropFirst(), value: value)
      }
      return object
    }
    if var array = root as? [Any], let index = Int(component), array.indices.contains(index) {
      if path.count == 1 {
        array[index] = value
      } else {
        array[index] = try replacing(
          array[index], path: path.dropFirst(), value: value)
      }
      return array
    }
    throw CocoaError(.coderInvalidValue)
  }

  private func removing(_ root: Any, path: ArraySlice<String>) throws -> Any {
    guard let component = path.first else {
      throw CocoaError(.coderInvalidValue)
    }
    if var object = root as? [String: Any] {
      if path.count == 1 {
        object.removeValue(forKey: component)
      } else {
        object[component] = try removing(
          try XCTUnwrap(object[component]), path: path.dropFirst())
      }
      return object
    }
    if var array = root as? [Any], let index = Int(component), array.indices.contains(index) {
      if path.count == 1 {
        array.remove(at: index)
      } else {
        array[index] = try removing(array[index], path: path.dropFirst())
      }
      return array
    }
    throw CocoaError(.coderInvalidValue)
  }

  private func appending(_ root: Any, path: ArraySlice<String>, value: Any) throws -> Any {
    guard let component = path.first else {
      guard var array = root as? [Any] else {
        throw CocoaError(.coderInvalidValue)
      }
      array.append(value)
      return array
    }
    if var object = root as? [String: Any] {
      object[component] = try appending(
        try XCTUnwrap(object[component]), path: path.dropFirst(), value: value)
      return object
    }
    if var array = root as? [Any], let index = Int(component), array.indices.contains(index) {
      array[index] = try appending(
        array[index], path: path.dropFirst(), value: value)
      return array
    }
    throw CocoaError(.coderInvalidValue)
  }

  private func valueAt(_ root: Any, path: ArraySlice<String>) throws -> Any {
    guard let component = path.first else {
      return root
    }
    if let object = root as? [String: Any] {
      return try valueAt(
        try XCTUnwrap(object[component]), path: path.dropFirst())
    }
    if let array = root as? [Any], let index = Int(component), array.indices.contains(index) {
      return try valueAt(array[index], path: path.dropFirst())
    }
    throw CocoaError(.coderInvalidValue)
  }

  private static let forbiddenRequestFields: Set<String> = [
    "submittedby",
    "executor",
    "executable",
    "argv",
    "shell",
    "command",
    "remotepath",
    "sessionroot",
    "authorizationbytes",
    "authorizationpath",
    "authorizationref",
    "capability",
    "bindingrevision",
    "readback",
    "prerequisites",
    "usage",
    "effect",
    "resolvedeffect",
    "outcome",
    "success",
  ]
}

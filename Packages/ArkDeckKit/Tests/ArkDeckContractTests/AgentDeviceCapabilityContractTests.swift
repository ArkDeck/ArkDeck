import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckStorage

final class AgentDeviceCapabilityContractTests: XCTestCase {
  private struct Registry: Decodable {
    let operations: [Operation]
  }

  private struct Operation: Decodable {
    let id: String
    let profiles: [Profile]
  }

  private struct Profile: Decodable {
    let id: String
    let configurationId: String
    let configurationSha256: String
    let declaredEffect: String
    let emittedStepKinds: [String]
  }

  private struct ScopeContract {
    let operationId: String
    let dataImpact: String
    let namespaceKind: String
    let namespaceFamily: String?
    let recoveryStrategy: String
    let requiredStepKinds: [String]
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
    changeRoot.appendingPathComponent("evidence/runs/TASK-AIN-009R")

  private static let schemaFiles = [
    "agent-device-capability.schema.v1-draft.json":
      "https://arkdeck.dev/schemas/agent-device-capability-1.0.0.json",
    "agent-execution-authority.schema.v1-draft.json":
      "https://arkdeck.dev/schemas/agent-execution-authority-1.0.0.json",
    "agent-authority-usage.schema.v1-draft.json":
      "https://arkdeck.dev/schemas/agent-authority-usage-1.0.0.json",
    "journal-event.schema.v2.2-draft.json":
      "https://arkdeck.dev/schemas/journal-event-2.2.0-draft.json",
    "manifest.schema.v2.2-draft.json":
      "https://arkdeck.dev/schemas/session-manifest-2.2.0-draft.json",
  ]

  func testSchemaIdentityClosedObjectsAndAuthorityUnionMatchAIN009() throws {
    var schemas: [String: [String: Any]] = [:]
    for (name, identifier) in Self.schemaFiles {
      let schema = try loadJSONObject(Self.contractRoot.appendingPathComponent(name))
      schemas[name] = schema
      XCTAssertEqual(
        schema["$schema"] as? String,
        "https://json-schema.org/draft/2020-12/schema",
        name)
      XCTAssertEqual(schema["$id"] as? String, identifier, name)
      try assertClosedObjects(schema, path: name)
      try assertRefsAreOfflineOrPinned(schema, path: name)
    }

    let capability = try XCTUnwrap(
      schemas["agent-device-capability.schema.v1-draft.json"])
    XCTAssertEqual(
      Set(try requiredArray(capability, "required").compactMap { $0 as? String }),
      Self.capabilityRootKeys)
    let capabilityProperties = try requiredDictionary(capability, "properties")
    XCTAssertEqual(Set(capabilityProperties.keys), Self.capabilityRootKeys)

    let newAuthority = try XCTUnwrap(
      schemas["agent-execution-authority.schema.v1-draft.json"])
    let oldOperation = try loadJSONObject(
      Self.contractRoot.appendingPathComponent(
        "agent-device-operation.schema.v1-draft.json"))
    let newDefinitions = try requiredDictionary(newAuthority, "$defs")
    let oldDefinitions = try requiredDictionary(oldOperation, "$defs")
    for definitionName in [
      "readyTaskAuthorizationRef",
      "deviceCapabilityAuthorizationRef",
      "standingAuthorizationRef",
    ] {
      let newDefinition = try requiredDictionary(newDefinitions, definitionName)
      let oldDefinition = try requiredDictionary(oldDefinitions, definitionName)
      XCTAssertEqual(
        Set(try requiredArray(newDefinition, "required").compactMap { $0 as? String }),
        Set(try requiredArray(oldDefinition, "required").compactMap { $0 as? String }),
        definitionName)
      XCTAssertEqual(
        Set(try requiredDictionary(newDefinition, "properties").keys),
        Set(try requiredDictionary(oldDefinition, "properties").keys),
        definitionName)
      let newKind = try requiredDictionary(
        try requiredDictionary(newDefinition, "properties"), "kind")
      let oldKind = try requiredDictionary(
        try requiredDictionary(oldDefinition, "properties"), "kind")
      XCTAssertEqual(newKind["const"] as? String, oldKind["const"] as? String)
    }
    XCTAssertEqual(
      newAuthority["x-arkdeck-authority-effect"] as? [String: String],
      [
        "readyTask": "readOnly",
        "deviceCapability": "deviceMutation",
        "standingAuthorization": "destructive",
      ])

    let journal = try XCTUnwrap(schemas["journal-event.schema.v2.2-draft.json"])
    let manifest = try XCTUnwrap(schemas["manifest.schema.v2.2-draft.json"])
    XCTAssertEqual(
      try constant(at: ["properties", "schemaVersion"], in: journal), "2.2.0")
    XCTAssertEqual(
      try constant(at: ["properties", "schemaVersion"], in: manifest), "2.2.0")
  }

  func testCapabilityProfilesNamespacesAndSingleFactNegatives() throws {
    let corpus = try loadCorpus()
    let capability = try requiredDictionary(corpus, "capability")
    let provenance = try requiredDictionary(corpus, "provenance")
    let profiles = try registryProfiles()

    XCTAssertNil(validateCapability(capability, provenance: provenance, profiles: profiles))
    let scopes = try requiredArray(capability, "operationScopes")
    XCTAssertEqual(scopes.count, 11)
    XCTAssertEqual(
      Set(scopes.compactMap { ($0 as? [String: Any])?["profileId"] as? String }),
      Set(Self.scopeContracts.keys))
    XCTAssertEqual(
      Set(
        scopes.compactMap {
          (($0 as? [String: Any])?["namespace"] as? [String: Any])?["kind"] as? String
        }),
      ["captureOwned", "bundle", "jobOwnedRemote", "portForward", "deviceMode"])

    let workflowKinds = Set(WorkflowStepKind.allCases.map(\.rawValue))
    for contract in Self.scopeContracts.values {
      XCTAssertTrue(
        Set(contract.requiredStepKinds).isSubset(of: workflowKinds),
        "\(contract.operationId) recovery Step closure")
    }

    let capabilitySchema = try loadJSONObject(
      Self.contractRoot.appendingPathComponent(
        "agent-device-capability.schema.v1-draft.json"))
    let definitions = try requiredDictionary(capabilitySchema, "$defs")
    let operationScope = try requiredDictionary(definitions, "operationScope")
    let branches = try requiredArray(operationScope, "oneOf")
    XCTAssertEqual(branches.count, 11)
    var schemaProfiles: Set<String> = []
    for rawBranch in branches {
      let branch = try XCTUnwrap(rawBranch as? [String: Any])
      let properties = try requiredDictionary(branch, "properties")
      let profileId = try XCTUnwrap(
        (try requiredDictionary(properties, "profileId"))["const"] as? String)
      let configurationId = try XCTUnwrap(
        (try requiredDictionary(properties, "configurationId"))["const"] as? String)
      let configurationSha256 = try XCTUnwrap(
        (try requiredDictionary(properties, "configurationSha256"))["const"] as? String)
      let registryProfile = try XCTUnwrap(profiles[profileId])
      XCTAssertEqual(configurationId, registryProfile.configurationId, profileId)
      XCTAssertEqual(configurationSha256, registryProfile.configurationSha256, profileId)
      schemaProfiles.insert(profileId)
    }
    XCTAssertEqual(schemaProfiles, Set(Self.scopeContracts.keys))

    var negativeCount = 0
    for key in Self.capabilityRootKeys {
      let candidate = try removing(capability, path: [key][...])
      XCTAssertEqual(
        validateCapability(candidate, provenance: provenance, profiles: profiles),
        "CAPABILITY_SHAPE",
        "missing root \(key)")
      negativeCount += 1
    }
    for forbidden in [
      "approvedBy", "carrier", "path", "argv", "readback", "usage", "outcome",
      "connectKey", "serial",
    ] {
      let candidate = try replacing(
        capability, path: [forbidden][...], value: "forged")
      XCTAssertEqual(
        validateCapability(candidate, provenance: provenance, profiles: profiles),
        "CAPABILITY_FORBIDDEN_FIELD",
        forbidden)
      negativeCount += 1
    }
    for key in Self.targetKeys {
      let candidate = try removing(capability, path: ["target", key][...])
      XCTAssertEqual(
        validateCapability(candidate, provenance: provenance, profiles: profiles),
        "TARGET_SHAPE",
        "missing target \(key)")
      negativeCount += 1
    }
    for key in Self.toolKeys {
      let candidate = try removing(capability, path: ["tool", key][...])
      XCTAssertEqual(
        validateCapability(candidate, provenance: provenance, profiles: profiles),
        "TOOL_SHAPE",
        "missing tool \(key)")
      negativeCount += 1
    }
    for key in Self.scopeKeys {
      let candidate = try removing(
        capability, path: ["operationScopes", "0", key][...])
      XCTAssertNotNil(
        validateCapability(candidate, provenance: provenance, profiles: profiles),
        "missing scope \(key)")
      negativeCount += 1
    }
    for key in Self.limitKeys {
      let candidate = try removing(capability, path: ["limits", key][...])
      XCTAssertEqual(
        validateCapability(candidate, provenance: provenance, profiles: profiles),
        "LIMITS",
        "missing limit \(key)")
      negativeCount += 1
    }
    for key in Self.privilegeKeys {
      let candidate = try removing(
        capability, path: ["privilegeRequirements", key][...])
      XCTAssertEqual(
        validateCapability(candidate, provenance: provenance, profiles: profiles),
        "PRIVILEGE_SHAPE",
        "missing privilege \(key)")
      negativeCount += 1
    }
    for key in ["effects", "operations", "profiles", "stepKinds"] {
      let candidate = try removing(
        capability, path: ["prohibitedAdjacency", key][...])
      XCTAssertEqual(
        validateCapability(candidate, provenance: provenance, profiles: profiles),
        "PROHIBITED_ADJACENCY",
        "missing prohibited adjacency \(key)")
      negativeCount += 1
    }
    let scalarMutations: [([String], Any, String)] = [
      (["schemaVersion"], "2.0.0", "CAPABILITY_VERSION"),
      (["capabilityId"], "AUTH-FORGED", "CAPABILITY_ID"),
      (["target", "stableIdentitySHA256"], String(repeating: "A", count: 64), "TARGET_DIGEST"),
      (["target", "transport"], "bluetooth", "TARGET_TRANSPORT"),
      (["target", "acceptedBindingRevision"], 0, "TARGET_REVISION"),
      (["tool", "kind"], "shell", "TOOL_IDENTITY"),
      (["tool", "executableSHA256"], "caller-path", "TOOL_IDENTITY"),
      (["limits", "maximumJobDurationSeconds"], 0, "LIMITS"),
      (["limits", "maximumJobDurationSeconds"], 86_401, "LIMITS"),
      (["limits", "maximumConcurrentJobs"], 2, "LIMITS"),
      (["limits", "maximumUses"], 0, "LIMITS"),
      (["limits", "maximumUses"], 33, "LIMITS"),
      (["limits", "compensationGraceSeconds"], 0, "LIMITS"),
      (["limits", "compensationGraceSeconds"], 1_801, "LIMITS"),
      (["limits", "maximumDataImpact"], "ephemeralOwnedState", "LIMIT_IMPACT"),
      (["privilegeRequirements", "root"], "required", "PRIVILEGE_ROOT"),
      (["privilegeRequirements", "maximumAgeSeconds"], 31, "PRIVILEGE_FRESHNESS"),
      (["privilegeRequirements", "freshProbeProfileId"], "caller.probe", "PRIVILEGE_FRESHNESS"),
      (["validUntil"], "2026-07-28T14:19:53Z", "CAPABILITY_EXPIRY"),
      (["validUntil"], "2026-09-01T00:00:00Z", "CAPABILITY_EXPIRY"),
      (["validUntil"], "2026-08-15T16:19:53+02:00", "CAPABILITY_EXPIRY"),
      (["operationScopes", "0", "effect"], "readOnly", "SCOPE_EFFECT"),
      (
        ["operationScopes", "0", "configurationSha256"], String(repeating: "0", count: 64),
        "SCOPE_CONFIGURATION"
      ),
      (["operationScopes", "0", "namespace", "family"], "trace", "SCOPE_NAMESPACE"),
      (
        ["operationScopes", "0", "recoveryPolicy", "strategy"], "resumeProbeOnly", "SCOPE_RECOVERY"
      ),
      (["prohibitedAdjacency", "effects", "0"], "deviceMutation", "PROHIBITED_ADJACENCY"),
      (["prohibitedAdjacency", "operations", "0"], "captureHilog", "PROHIBITED_ADJACENCY"),
      (["prohibitedAdjacency", "profiles", "0"], "caller.profile", "PROHIBITED_ADJACENCY"),
      (["prohibitedAdjacency", "stepKinds", "0"], "probeDevice", "PROHIBITED_ADJACENCY"),
    ]
    for (path, value, expected) in scalarMutations {
      let candidate = try replacing(capability, path: path[...], value: value)
      XCTAssertEqual(
        validateCapability(candidate, provenance: provenance, profiles: profiles),
        expected,
        path.joined(separator: "."))
      negativeCount += 1
    }
    for index in 0..<11 {
      let candidate = try replacing(
        capability,
        path: ["operationScopes", String(index), "profileId"][...],
        value: "unknown.profile.v1")
      XCTAssertEqual(
        validateCapability(candidate, provenance: provenance, profiles: profiles),
        "SCOPE_PROFILE",
        "profile \(index)")
      negativeCount += 1
    }
    let duplicatedEvidence = try appending(
      capability,
      path: ["evidenceRefs"][...],
      value: try XCTUnwrap(
        (try requiredArray(capability, "evidenceRefs")).first))
    XCTAssertEqual(
      validateCapability(duplicatedEvidence, provenance: provenance, profiles: profiles),
      "CAPABILITY_EVIDENCE")
    negativeCount += 1
    let duplicatedScope = try appending(
      capability,
      path: ["operationScopes"][...],
      value: try XCTUnwrap(scopes.first))
    XCTAssertEqual(
      validateCapability(duplicatedScope, provenance: provenance, profiles: profiles),
      "SCOPE_COUNT")
    negativeCount += 1
    XCTAssertEqual(negativeCount, 99)
  }

  func testAuthorityUsageLeaseAndProtectedMainProvenanceFailClosed() throws {
    let corpus = try loadCorpus()
    let refs = try requiredDictionary(corpus, "authorityRefs")
    let provenance = try requiredDictionary(corpus, "provenance")
    let usage = try requiredDictionary(corpus, "usage")
    let capability = try requiredDictionary(corpus, "capability")
    let requestDeadline = try XCTUnwrap(corpus["leaseRequestDeadline"] as? String)

    XCTAssertEqual(Set(refs.keys), ["e0", "e1", "e2"])
    for ref in refs.values {
      XCTAssertNil(validateAuthorityRef(ref))
    }
    XCTAssertNil(validateProvenance(provenance, capability: capability))
    XCTAssertNil(
      validateUsage(
        usage,
        capability: capability,
        requestDeadline: requestDeadline))

    var negativeCount = 0
    for (name, rawRef) in refs {
      let ref = try XCTUnwrap(rawRef as? [String: Any])
      let wrongKind = try replacing(ref, path: ["kind"][...], value: "unknown")
      XCTAssertEqual(validateAuthorityRef(wrongKind), "AUTHORITY_KIND", name)
      negativeCount += 1
      let extra = try replacing(ref, path: ["path"][...], value: "/tmp/forged")
      XCTAssertEqual(validateAuthorityRef(extra), "AUTHORITY_SHAPE", name)
      negativeCount += 1
    }
    let crossKind = try replacing(
      try XCTUnwrap(refs["e1"] as? [String: Any]),
      path: ["kind"][...],
      value: "standingAuthorization")
    XCTAssertEqual(validateAuthorityRef(crossKind), "AUTHORITY_SHAPE")
    negativeCount += 1

    let provenanceMutations: [([String], Any, String)] = [
      (["repository"], "fork/ArkDeck", "PROVENANCE_REPOSITORY"),
      (["branch"], "feature", "PROVENANCE_BRANCH"),
      (["registryPath"], "../CAP-E1-ARKDECK-001.json", "PROVENANCE_PATH"),
      (["currentMainCapabilityBlobOID"], String(repeating: "0", count: 40), "PROVENANCE_BLOB"),
      (["headCapabilityBlobOID"], String(repeating: "1", count: 40), "PROVENANCE_BLOB"),
      (["mergeCapabilityBlobOID"], String(repeating: "2", count: 40), "PROVENANCE_BLOB"),
      (["codeownersBlobOID"], String(repeating: "3", count: 40), "PROVENANCE_CODEOWNERS"),
      (["networkAvailable"], false, "PROVENANCE_NETWORK"),
      (["offlineCacheUsed"], true, "PROVENANCE_CACHE"),
      (["acceptancePR", "state"], "OPEN", "PROVENANCE_PR"),
      (["acceptancePR", "baseRefName"], "release", "PROVENANCE_PR"),
      (["acceptancePR", "author"], "agent", "PROVENANCE_AUTHOR"),
      (["acceptancePR", "reviewer"], "other", "PROVENANCE_REVIEW"),
      (["acceptancePR", "reviewState"], "COMMENTED", "PROVENANCE_REVIEW"),
      (
        ["acceptancePR", "reviewCommitOID"], String(repeating: "0", count: 40),
        "PROVENANCE_EXACT_HEAD"
      ),
      (["acceptancePR", "merger"], "other", "PROVENANCE_MERGER"),
      (["acceptancePR", "mergeCommitIsCurrentMainAncestor"], false, "PROVENANCE_ANCESTRY"),
      (["acceptancePR", "mergedAt"], "2026-07-28T16:19:53+02:00", "PROVENANCE_PR"),
    ]
    for (path, value, expected) in provenanceMutations {
      let candidate = try replacing(provenance, path: path[...], value: value)
      XCTAssertEqual(
        validateProvenance(candidate, capability: capability),
        expected,
        path.joined(separator: "."))
      negativeCount += 1
    }
    for key in Self.provenanceKeys {
      let candidate = try removing(provenance, path: [key][...])
      XCTAssertNotNil(
        validateProvenance(candidate, capability: capability),
        "missing provenance \(key)")
      negativeCount += 1
    }
    for key in Self.acceptancePRKeys {
      let candidate = try removing(
        provenance, path: ["acceptancePR", key][...])
      XCTAssertNotNil(
        validateProvenance(candidate, capability: capability),
        "missing acceptance PR \(key)")
      negativeCount += 1
    }

    let usageMutations: [([String], Any, String)] = [
      (["documentType"], "authorizationUsage", "USAGE_SHAPE"),
      (["schemaVersion"], "2.0.0", "USAGE_SHAPE"),
      (
        ["reservations", "0", "authorizationRef", "kind"], "standingAuthorization",
        "USAGE_AUTHORITY"
      ),
      (["reservations", "0", "ordinal"], 0, "USAGE_ORDINAL"),
      (["reservations", "0", "ordinal"], 5, "USAGE_ORDINAL"),
      (["reservations", "0", "maximumUses"], 33, "USAGE_LIMIT"),
      (["reservations", "0", "maximumConcurrentJobs"], 2, "USAGE_CONCURRENCY"),
      (
        ["reservations", "0", "forwardLeaseExpiresAt"], "2026-07-28T16:01:00Z",
        "USAGE_FORWARD_LEASE"
      ),
      (
        ["reservations", "0", "compensationLeaseExpiresAt"], "2026-07-28T16:11:00Z",
        "USAGE_COMPENSATION_LEASE"
      ),
      (["reservations", "0", "operationDigestSHA256"], "forged", "USAGE_DIGEST"),
      (["reservations", "0", "terminal", "status"], "unknown", "USAGE_TERMINAL"),
      (
        ["reservations", "0", "reservedAt"], "2026-07-28T17:00:00+02:00",
        "USAGE_LEASE_SHAPE"
      ),
    ]
    for (path, value, expected) in usageMutations {
      let candidate = try replacing(usage, path: path[...], value: value)
      XCTAssertEqual(
        validateUsage(
          candidate,
          capability: capability,
          requestDeadline: requestDeadline),
        expected,
        path.joined(separator: "."))
      negativeCount += 1
    }
    for key in Self.reservationKeys {
      let candidate = try removing(
        usage, path: ["reservations", "0", key][...])
      XCTAssertNotNil(
        validateUsage(
          candidate,
          capability: capability,
          requestDeadline: requestDeadline),
        "missing reservation \(key)")
      negativeCount += 1
    }
    XCTAssertEqual(negativeCount, 72)
  }

  func testJournalManifestCorrelationAndCrashVectors() throws {
    let corpus = try loadCorpus()
    let sessions = try requiredDictionary(corpus, "sessions")
    XCTAssertEqual(Set(sessions.keys), ["e0", "e1", "e2"])
    for (name, rawSession) in sessions {
      XCTAssertNil(
        validateSession(try XCTUnwrap(rawSession as? [String: Any])),
        name)
    }

    let e1 = try XCTUnwrap(sessions["e1"] as? [String: Any])
    var outcomeUnknown = e1
    outcomeUnknown =
      try removing(
        outcomeUnknown, path: ["journal", "4"][...]) as! [String: Any]
    outcomeUnknown =
      try replacing(
        outcomeUnknown,
        path: ["manifest", "outcomeCertainty"][...],
        value: "outcomeUnknown") as! [String: Any]
    XCTAssertNil(validateSession(outcomeUnknown))

    let persistenceMutations: [([String], Any?, String)] = [
      (["journal", "0", "payload", "executionMode"], "simulated", "SESSION_EXECUTION_MODE"),
      (["journal", "0", "payload", "usageReservationId"], NSNull(), "SESSION_USAGE"),
      (["journal", "1", "payload", "authorizationRef", "kind"], "readyTask", "SESSION_AUTHORITY"),
      (["journal", "1", "payload", "usageReservationId"], "other", "SESSION_USAGE"),
      (
        ["journal", "2", "payload", "authorizationRef", "capabilityBlobOID"],
        String(repeating: "0", count: 40), "SESSION_AUTHORITY"
      ),
      (["journal", "2", "payload", "correlatesToIntentEventId"], "ghost", "SESSION_CORRELATION"),
      (
        ["journal", "3", "payload", "authorizationRef", "capabilityId"], "CAP-E1-OTHER",
        "SESSION_AUTHORITY"
      ),
      (
        ["journal", "4", "payload", "correlatesToIntentEventId"], "e1-intent", "SESSION_CORRELATION"
      ),
      (["manifest", "authorization", "usageReservationId"], "other", "MANIFEST_USAGE"),
      (["manifest", "authorization", "externalIntentEventIds", "0"], "ghost", "MANIFEST_INTENTS"),
      (
        ["manifest", "confirmations", "0", "authorizationRef", "mainCommitOID"],
        String(repeating: "0", count: 40), "CONFIRMATION_AUTHORITY"
      ),
      (["journal", "1", "schemaVersion"], "2.1.0", "SESSION_MIXED_VERSION"),
      (["journal", "1", "timestamp"], "2026-07-28T17:00:01+02:00", "SESSION_TIMESTAMP"),
      (["manifest", "createdAt"], "2026-07-28T15:00:00.000Z", "SESSION_TIMESTAMP"),
    ]
    var negativeCount = 0
    for (path, value, expected) in persistenceMutations {
      let candidate: Any
      if let value {
        candidate = try replacing(e1, path: path[...], value: value)
      } else {
        candidate = try removing(e1, path: path[...])
      }
      XCTAssertEqual(
        validateSession(try XCTUnwrap(candidate as? [String: Any])),
        expected,
        path.joined(separator: "."))
      negativeCount += 1
    }
    let duplicateIntent = try appending(
      e1,
      path: ["journal"][...],
      value: try valueAt(e1, path: ["journal", "1"][...]))
    XCTAssertEqual(
      validateSession(try XCTUnwrap(duplicateIntent as? [String: Any])),
      "SESSION_EVENT_IDS")
    negativeCount += 1
    let confirmedMissingOutcome = try removing(e1, path: ["journal", "4"][...])
    XCTAssertEqual(
      validateSession(try XCTUnwrap(confirmedMissingOutcome as? [String: Any])),
      "SESSION_OUTSTANDING_INTENT")
    negativeCount += 1
    XCTAssertEqual(negativeCount, 16)

    print(
      "TEST-AIN-CAP-CONTRACT-001 PASS e1_profiles=11 namespaces=5 "
        + "authority_kinds=3 legacy_versions=3 process_dispatch=0 device_dispatch=0 "
        + "hdc_dispatch=0 network=0")
  }

  func testLegacySchemasRemainBytePinnedAndReadOnly() throws {
    let corpus = try loadCorpus()
    let legacy = try requiredArray(corpus, "legacyVersions")
    XCTAssertEqual(legacy.count, 3)
    var versions: Set<String> = []
    for raw in legacy {
      let vector = try XCTUnwrap(raw as? [String: Any])
      let version = try XCTUnwrap(vector["version"] as? String)
      versions.insert(version)
      for pair in [
        ("journalSchema", "journalSHA256"),
        ("manifestSchema", "manifestSHA256"),
      ] {
        let relativePath = try XCTUnwrap(vector[pair.0] as? String)
        let expectedHash = try XCTUnwrap(vector[pair.1] as? String)
        let url = Self.repositoryRoot.appendingPathComponent(relativePath)
        XCTAssertTrue(
          url.standardizedFileURL.path.hasPrefix(Self.repositoryRoot.standardizedFileURL.path))
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(sha256(bytes), expectedHash, "\(version) \(pair.0)")
        var duplicateValidator = ArkDeckCore.StrictJSONDuplicateValidator(data: bytes)
        try duplicateValidator.validate()
        let parsed = try XCTUnwrap(
          JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNotNil(parsed["$id"], "\(version) \(pair.0)")
      }
      XCTAssertEqual(
        vector["writeRule"] as? String,
        "preserveDeclaredVersionAndBytes")
      if version == "1.x" {
        XCTAssertEqual(vector["authorityMeaning"] as? String, "none")
      } else {
        XCTAssertEqual(
          vector["authorityMeaning"] as? String,
          "standingAuthorization")
      }
      let roundTrip = try JSONSerialization.data(
        withJSONObject: vector, options: [.sortedKeys])
      let decoded = try XCTUnwrap(
        JSONSerialization.jsonObject(with: roundTrip) as? [String: Any])
      XCTAssertEqual(try canonicalData(decoded), try canonicalData(vector))
    }
    XCTAssertEqual(versions, ["1.x", "2.0.0", "2.1.0"])

    let existingE2Usage = try Data(
      contentsOf: Self.contractRoot.appendingPathComponent(
        "authorization-usage.schema.v1-draft.json"))
    XCTAssertEqual(
      gitBlobSHA1(existingE2Usage),
      "b232db49d2d76fc2eb96fed6b7d0230455d99345")
  }

  func testDuplicateMembersIncludingUnicodeEscapesFailClosed() throws {
    for name in ["duplicate-capability.json", "duplicate-capability-escaped.json"] {
      let data = try Data(contentsOf: Self.runRoot.appendingPathComponent(name))
      var validator = ArkDeckCore.StrictJSONDuplicateValidator(data: data)
      XCTAssertThrowsError(try validator.validate(), name) { error in
        guard case ArkDeckCore.StrictJSONError.duplicateMemberName(let path) = error else {
          return XCTFail("\(name): unexpected error \(error)")
        }
        XCTAssertEqual(path, "$.capabilityId")
      }
    }
  }

  private func loadCorpus() throws -> [String: Any] {
    try loadJSONObject(Self.runRoot.appendingPathComponent("vectors.json"))
  }

  private func loadJSONObject(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    var duplicateValidator = ArkDeckCore.StrictJSONDuplicateValidator(data: data)
    try duplicateValidator.validate()
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
  }

  private func registryProfiles() throws -> [String: Profile] {
    let data = try Data(
      contentsOf: Self.contractRoot.appendingPathComponent(
        "agent-device-operation-registry.v1-draft.json"))
    var duplicateValidator = ArkDeckCore.StrictJSONDuplicateValidator(data: data)
    try duplicateValidator.validate()
    let registry = try JSONDecoder().decode(Registry.self, from: data)
    let profiles = registry.operations.flatMap { operation in
      operation.profiles
        .filter { $0.declaredEffect == "deviceMutation" }
        .map { profile in (profile.id, profile) }
    }
    XCTAssertEqual(profiles.count, 11)
    XCTAssertEqual(Set(profiles.map(\.0)), Set(Self.scopeContracts.keys))
    for (profileId, profile) in profiles {
      XCTAssertEqual(
        Self.scopeContracts[profileId]?.operationId,
        registry.operations.first(where: { operation in
          operation.profiles.contains(where: { $0.id == profileId })
        })?.id)
      XCTAssertFalse(profile.emittedStepKinds.isEmpty)
    }
    return Dictionary(uniqueKeysWithValues: profiles)
  }

  private func validateCapability(
    _ value: Any,
    provenance: [String: Any],
    profiles: [String: Profile]
  ) -> String? {
    if findForbiddenCarrierField(value) != nil {
      return "CAPABILITY_FORBIDDEN_FIELD"
    }
    guard let capability = value as? [String: Any] else {
      return "CAPABILITY_SHAPE"
    }
    guard Set(capability.keys) == Self.capabilityRootKeys else {
      return "CAPABILITY_SHAPE"
    }
    guard capability["documentType"] as? String == "agentDeviceCapability" else {
      return "CAPABILITY_SHAPE"
    }
    guard capability["schemaVersion"] as? String == "1.0.0" else {
      return "CAPABILITY_VERSION"
    }
    guard
      let capabilityId = capability["capabilityId"] as? String,
      matches(capabilityId, "^CAP-E1-[A-Z0-9]+(?:-[A-Z0-9]+)*$")
    else {
      return "CAPABILITY_ID"
    }
    guard
      let changeId = capability["changeId"] as? String,
      matches(changeId, "^CHG-[0-9]{4}-[0-9]{3}$"),
      let taskId = capability["taskId"] as? String,
      matches(taskId, "^TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?$")
    else {
      return "CAPABILITY_SHAPE"
    }
    guard
      let evidence = capability["evidenceRefs"] as? [String],
      (1...32).contains(evidence.count),
      Set(evidence).count == evidence.count,
      evidence.allSatisfy({ !$0.isEmpty && $0.count <= 512 })
    else {
      return "CAPABILITY_EVIDENCE"
    }
    guard let target = capability["target"] as? [String: Any] else {
      return "TARGET_SHAPE"
    }
    guard Set(target.keys) == Self.targetKeys else {
      return "TARGET_SHAPE"
    }
    guard
      target["durableTargetId"] is String,
      target["model"] is String,
      let revision = target["acceptedBindingRevision"] as? Int,
      revision >= 1
    else {
      return "TARGET_REVISION"
    }
    for digestKey in [
      "stableIdentitySHA256", "originalTargetSHA256", "firmwareFingerprintSHA256",
    ] {
      guard
        let digest = target[digestKey] as? String,
        matches(digest, "^[0-9a-f]{64}$")
      else {
        return "TARGET_DIGEST"
      }
    }
    guard
      let transport = target["transport"] as? String,
      ["usb", "tcp", "uart"].contains(transport)
    else {
      return "TARGET_TRANSPORT"
    }
    guard
      let modes = target["allowedDeviceModes"] as? [String],
      (1...3).contains(modes.count),
      Set(modes).count == modes.count,
      Set(modes).isSubset(of: ["normal", "recovery", "updater"])
    else {
      return "TARGET_MODES"
    }

    guard let tool = capability["tool"] as? [String: Any] else {
      return "TOOL_SHAPE"
    }
    guard Set(tool.keys) == Self.toolKeys else {
      return "TOOL_SHAPE"
    }
    guard
      tool["kind"] as? String == "hdc",
      tool["profileId"] is String,
      tool["reportedVersion"] is String,
      let executable = tool["executableSHA256"] as? String,
      matches(executable, "^[0-9a-f]{64}$")
    else {
      return "TOOL_IDENTITY"
    }

    guard
      let scopes = capability["operationScopes"] as? [[String: Any]],
      (1...11).contains(scopes.count)
    else {
      return "SCOPE_COUNT"
    }
    let profileIds = scopes.compactMap { $0["profileId"] as? String }
    guard profileIds.count == scopes.count, Set(profileIds).count == scopes.count else {
      return "SCOPE_COUNT"
    }
    var maximumScopeImpact = 0
    for scope in scopes {
      guard Set(scope.keys) == Self.scopeKeys else {
        return "SCOPE_SHAPE"
      }
      guard scope["effect"] as? String == "deviceMutation" else {
        return "SCOPE_EFFECT"
      }
      guard
        let profileId = scope["profileId"] as? String,
        let contract = Self.scopeContracts[profileId],
        let profile = profiles[profileId],
        scope["operationId"] as? String == contract.operationId
      else {
        return "SCOPE_PROFILE"
      }
      guard
        scope["configurationId"] as? String == profile.configurationId,
        scope["configurationSha256"] as? String == profile.configurationSha256
      else {
        return "SCOPE_CONFIGURATION"
      }
      guard
        let impact = scope["dataImpact"] as? String,
        impact == contract.dataImpact,
        let impactRank = Self.dataImpactOrder.firstIndex(of: impact)
      else {
        return "SCOPE_IMPACT"
      }
      maximumScopeImpact = max(maximumScopeImpact, impactRank)
      guard
        let namespace = scope["namespace"] as? [String: Any],
        namespace["kind"] as? String == contract.namespaceKind
      else {
        return "SCOPE_NAMESPACE"
      }
      if contract.namespaceKind == "captureOwned" {
        guard
          Set(namespace.keys) == ["kind", "family", "rootPolicyId"],
          namespace["family"] as? String == contract.namespaceFamily,
          namespace["rootPolicyId"] as? String == "jobOwnedRemoteV1"
        else {
          return "SCOPE_NAMESPACE"
        }
      } else if contract.namespaceKind == "bundle" {
        guard
          Set(namespace.keys) == ["kind", "bundleId"],
          namespace["bundleId"] is String
        else {
          return "SCOPE_NAMESPACE"
        }
      } else if contract.namespaceKind == "jobOwnedRemote" {
        guard
          Set(namespace.keys) == ["kind", "rootPolicyId"],
          namespace["rootPolicyId"] as? String == "jobOwnedRemoteV1"
        else {
          return "SCOPE_NAMESPACE"
        }
      } else if contract.namespaceKind == "portForward" {
        guard
          Set(namespace.keys) == ["kind", "pairs"],
          let pairs = namespace["pairs"] as? [[String: Any]],
          (1...32).contains(pairs.count)
        else {
          return "SCOPE_NAMESPACE"
        }
        for pair in pairs {
          guard
            Set(pair.keys) == ["protocol", "hostPort", "devicePort"],
            pair["protocol"] as? String == "tcp",
            let hostPort = pair["hostPort"] as? Int,
            let devicePort = pair["devicePort"] as? Int,
            (1...65_535).contains(hostPort),
            (1...65_535).contains(devicePort)
          else {
            return "SCOPE_NAMESPACE"
          }
        }
      } else {
        guard
          Set(namespace.keys) == ["kind", "allowedTargetModes"],
          let namespaceModes = namespace["allowedTargetModes"] as? [String],
          !namespaceModes.isEmpty,
          Set(namespaceModes).isSubset(of: ["normal", "recovery", "updater"])
        else {
          return "SCOPE_NAMESPACE"
        }
      }
      guard
        let recovery = scope["recoveryPolicy"] as? [String: Any],
        Set(recovery.keys) == [
          "strategy", "requiredStepKinds", "resumeProbeProfileId",
        ],
        recovery["strategy"] as? String == contract.recoveryStrategy,
        recovery["requiredStepKinds"] as? [String] == contract.requiredStepKinds,
        recovery["resumeProbeProfileId"] as? String
          == "observe-device.read-only.v1"
      else {
        return "SCOPE_RECOVERY"
      }
    }

    guard
      let limits = capability["limits"] as? [String: Any],
      Set(limits.keys) == Self.limitKeys,
      let maximumImpact = limits["maximumDataImpact"] as? String,
      let maximumImpactRank = Self.dataImpactOrder.firstIndex(of: maximumImpact),
      let duration = limits["maximumJobDurationSeconds"] as? Int,
      (1...86_400).contains(duration),
      limits["maximumConcurrentJobs"] as? Int == 1,
      let maximumUses = limits["maximumUses"] as? Int,
      (1...32).contains(maximumUses),
      let grace = limits["compensationGraceSeconds"] as? Int,
      (1...1_800).contains(grace)
    else {
      return "LIMITS"
    }
    guard maximumImpactRank >= maximumScopeImpact else {
      return "LIMIT_IMPACT"
    }
    guard
      let privilege = capability["privilegeRequirements"] as? [String: Any],
      Set(privilege.keys) == Self.privilegeKeys,
      ["required", "notRequired"].contains(privilege["developerMode"] as? String),
      ["required", "notRequired"].contains(privilege["packageDebuggable"] as? String)
    else {
      return "PRIVILEGE_SHAPE"
    }
    guard privilege["root"] as? String == "forbidden" else {
      return "PRIVILEGE_ROOT"
    }
    guard
      privilege["freshProbeProfileId"] as? String == "observe-device.read-only.v1",
      let maximumAge = privilege["maximumAgeSeconds"] as? Int,
      (1...30).contains(maximumAge)
    else {
      return "PRIVILEGE_FRESHNESS"
    }
    guard
      let adjacency = capability["prohibitedAdjacency"] as? [String: Any],
      Set(adjacency.keys) == ["effects", "operations", "profiles", "stepKinds"],
      adjacency["effects"] as? [String] == ["destructive"],
      adjacency["operations"] as? [String] == ["flash", "uninstallHAP"],
      adjacency["profiles"] as? [String] == Self.prohibitedProfiles,
      adjacency["stepKinds"] as? [String] == Self.prohibitedStepKinds
    else {
      return "PROHIBITED_ADJACENCY"
    }
    guard
      let validUntilRaw = capability["validUntil"] as? String,
      let validUntil = canonicalDate(validUntilRaw),
      let acceptancePR = provenance["acceptancePR"] as? [String: Any],
      let mergedAtRaw = acceptancePR["mergedAt"] as? String,
      let mergedAt = canonicalDate(mergedAtRaw),
      validUntil > mergedAt,
      validUntil <= mergedAt.addingTimeInterval(31 * 24 * 60 * 60)
    else {
      return "CAPABILITY_EXPIRY"
    }
    return nil
  }

  private func validateAuthorityRef(_ value: Any) -> String? {
    guard let ref = value as? [String: Any], let kind = ref["kind"] as? String else {
      return "AUTHORITY_SHAPE"
    }
    let expectedKeys: Set<String>
    switch kind {
    case "readyTask":
      expectedKeys = [
        "kind", "changeId", "taskId", "mainCommitOID", "taskBlobOID",
        "approvalPRNumber",
      ]
    case "deviceCapability":
      expectedKeys = [
        "kind", "capabilityId", "mainCommitOID", "capabilityBlobOID",
        "approvalPRNumber",
      ]
    case "standingAuthorization":
      expectedKeys = [
        "kind", "authorizationId", "mainCommitOID", "authorizationBlobOID",
        "approvalPRNumber",
      ]
    default:
      return "AUTHORITY_KIND"
    }
    guard Set(ref.keys) == expectedKeys else {
      return "AUTHORITY_SHAPE"
    }
    guard
      let main = ref["mainCommitOID"] as? String,
      matches(main, "^[0-9a-f]{40}$"),
      let approvalPR = ref["approvalPRNumber"] as? Int,
      approvalPR >= 1
    else {
      return "AUTHORITY_SHAPE"
    }
    if kind == "readyTask" {
      guard
        let changeId = ref["changeId"] as? String,
        matches(changeId, "^CHG-[0-9]{4}-[0-9]{3}$"),
        let taskId = ref["taskId"] as? String,
        matches(taskId, "^TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?$"),
        let blob = ref["taskBlobOID"] as? String,
        matches(blob, "^[0-9a-f]{40}$")
      else {
        return "AUTHORITY_SHAPE"
      }
    } else if kind == "deviceCapability" {
      guard
        let identifier = ref["capabilityId"] as? String,
        matches(identifier, "^CAP-E1-[A-Z0-9]+(?:-[A-Z0-9]+)*$"),
        let blob = ref["capabilityBlobOID"] as? String,
        matches(blob, "^[0-9a-f]{40}$")
      else {
        return "AUTHORITY_SHAPE"
      }
    } else {
      guard
        let identifier = ref["authorizationId"] as? String,
        matches(identifier, "^AUTH-[A-Z0-9]+(?:-[A-Z0-9]+)*$"),
        let blob = ref["authorizationBlobOID"] as? String,
        matches(blob, "^[0-9a-f]{40}$")
      else {
        return "AUTHORITY_SHAPE"
      }
    }
    return nil
  }

  private func validateProvenance(
    _ value: Any,
    capability: [String: Any]
  ) -> String? {
    guard let provenance = value as? [String: Any] else {
      return "PROVENANCE_SHAPE"
    }
    guard Set(provenance.keys) == Self.provenanceKeys else {
      return "PROVENANCE_SHAPE"
    }
    guard provenance["repository"] as? String == "ArkDeck/ArkDeck" else {
      return "PROVENANCE_REPOSITORY"
    }
    guard provenance["branch"] as? String == "main" else {
      return "PROVENANCE_BRANCH"
    }
    guard let capabilityId = capability["capabilityId"] as? String else {
      return "PROVENANCE_PATH"
    }
    let expectedPath =
      "openspec/changes/chg-2026-025-ai-native-unattended-device-ops/"
      + "evidence/capabilities/\(capabilityId).json"
    guard provenance["registryPath"] as? String == expectedPath else {
      return "PROVENANCE_PATH"
    }
    guard
      let currentMain = provenance["currentMainCommitOID"] as? String,
      matches(currentMain, "^[0-9a-f]{40}$"),
      let currentBlob = provenance["currentMainCapabilityBlobOID"] as? String,
      provenance["headCapabilityBlobOID"] as? String == currentBlob,
      provenance["mergeCapabilityBlobOID"] as? String == currentBlob,
      matches(currentBlob, "^[0-9a-f]{40}$")
    else {
      return "PROVENANCE_BLOB"
    }
    guard
      provenance["codeownersBlobOID"] as? String
        == "f4edd22f87965efcfc27ea512283a0c2252bf0fb"
    else {
      return "PROVENANCE_CODEOWNERS"
    }
    guard provenance["networkAvailable"] as? Bool == true else {
      return "PROVENANCE_NETWORK"
    }
    guard provenance["offlineCacheUsed"] as? Bool == false else {
      return "PROVENANCE_CACHE"
    }
    guard let pr = provenance["acceptancePR"] as? [String: Any] else {
      return "PROVENANCE_PR"
    }
    guard Set(pr.keys) == Self.acceptancePRKeys else {
      return "PROVENANCE_PR"
    }
    guard
      let number = pr["number"] as? Int,
      number >= 1,
      let headCommit = pr["headCommitOID"] as? String,
      matches(headCommit, "^[0-9a-f]{40}$"),
      let mergeCommit = pr["mergeCommitOID"] as? String,
      matches(mergeCommit, "^[0-9a-f]{40}$"),
      canonicalDate(pr["mergedAt"]) != nil
    else {
      return "PROVENANCE_PR"
    }
    guard pr["state"] as? String == "MERGED", pr["baseRefName"] as? String == "main"
    else {
      return "PROVENANCE_PR"
    }
    guard pr["author"] as? String == "github-actions[bot]" else {
      return "PROVENANCE_AUTHOR"
    }
    guard
      pr["reviewer"] as? String == "lvye",
      pr["reviewState"] as? String == "APPROVED"
    else {
      return "PROVENANCE_REVIEW"
    }
    guard
      headCommit == pr["reviewCommitOID"] as? String
    else {
      return "PROVENANCE_EXACT_HEAD"
    }
    guard pr["merger"] as? String == "lvye" else {
      return "PROVENANCE_MERGER"
    }
    guard pr["mergeCommitIsCurrentMainAncestor"] as? Bool == true else {
      return "PROVENANCE_ANCESTRY"
    }
    return nil
  }

  private func validateUsage(
    _ value: Any,
    capability: [String: Any],
    requestDeadline: String
  ) -> String? {
    guard
      let usage = value as? [String: Any],
      Set(usage.keys) == ["documentType", "schemaVersion", "reservations"],
      usage["documentType"] as? String == "agentAuthorityUsage",
      usage["schemaVersion"] as? String == "1.0.0",
      let reservations = usage["reservations"] as? [[String: Any]]
    else {
      return "USAGE_SHAPE"
    }
    var ordinals: Set<Int> = []
    var reservationIds: Set<String> = []
    for reservation in reservations {
      guard Set(reservation.keys) == Self.reservationKeys else {
        return "USAGE_SHAPE"
      }
      guard
        let ref = reservation["authorizationRef"] as? [String: Any],
        validateAuthorityRef(ref) == nil,
        ref["kind"] as? String == "deviceCapability"
      else {
        return "USAGE_AUTHORITY"
      }
      guard
        let reservationId = reservation["reservationId"] as? String,
        reservationIds.insert(reservationId).inserted,
        let maximumUses = reservation["maximumUses"] as? Int,
        (1...32).contains(maximumUses)
      else {
        return "USAGE_LIMIT"
      }
      guard
        let ordinal = reservation["ordinal"] as? Int,
        ordinal >= 1,
        ordinal <= maximumUses,
        ordinals.insert(ordinal).inserted
      else {
        return "USAGE_ORDINAL"
      }
      guard reservation["maximumConcurrentJobs"] as? Int == 1 else {
        return "USAGE_CONCURRENCY"
      }
      for digestKey in ["operationDigestSHA256", "targetDigestSHA256"] {
        guard
          let digest = reservation[digestKey] as? String,
          matches(digest, "^[0-9a-f]{64}$")
        else {
          return "USAGE_DIGEST"
        }
      }
      guard
        let limits = capability["limits"] as? [String: Any],
        let duration = limits["maximumJobDurationSeconds"] as? Int,
        let grace = limits["compensationGraceSeconds"] as? Int,
        let validUntil = canonicalDate(capability["validUntil"] as? String),
        let reservedAt = canonicalDate(reservation["reservedAt"] as? String),
        let deadline = canonicalDate(requestDeadline),
        let actualForward = canonicalDate(
          reservation["forwardLeaseExpiresAt"] as? String),
        let actualCompensation = canonicalDate(
          reservation["compensationLeaseExpiresAt"] as? String)
      else {
        return "USAGE_LEASE_SHAPE"
      }
      let expectedForward = min(
        deadline,
        min(validUntil, reservedAt.addingTimeInterval(TimeInterval(duration))))
      guard actualForward == expectedForward else {
        return "USAGE_FORWARD_LEASE"
      }
      let expectedCompensation = min(
        validUntil.addingTimeInterval(TimeInterval(grace)),
        expectedForward.addingTimeInterval(TimeInterval(grace)))
      guard actualCompensation == expectedCompensation else {
        return "USAGE_COMPENSATION_LEASE"
      }
      if !(reservation["terminal"] is NSNull) {
        guard
          let terminal = reservation["terminal"] as? [String: Any],
          Set(terminal.keys) == ["status", "closedAt", "externalIntentEventIds"],
          let status = terminal["status"] as? String,
          [
            "succeeded", "failed", "cancelled", "interrupted", "outcomeUnknown",
          ].contains(status),
          canonicalDate(terminal["closedAt"] as? String) != nil,
          terminal["externalIntentEventIds"] is [String]
        else {
          return "USAGE_TERMINAL"
        }
      }
    }
    if !ordinals.isEmpty {
      guard ordinals == Set(1...ordinals.count) else {
        return "USAGE_ORDINAL"
      }
    }
    return nil
  }

  private func validateSession(_ value: Any) -> String? {
    guard
      let session = value as? [String: Any],
      let expectedEffect = session["effect"] as? String,
      let journal = session["journal"] as? [[String: Any]],
      !journal.isEmpty,
      let manifest = session["manifest"] as? [String: Any]
    else {
      return "SESSION_SHAPE"
    }
    guard
      journal.allSatisfy({ $0["schemaVersion"] as? String == "2.2.0" }),
      manifest["schemaVersion"] as? String == "2.2.0"
    else {
      return "SESSION_MIXED_VERSION"
    }
    guard
      journal.allSatisfy({ canonicalDate($0["timestamp"]) != nil }),
      canonicalDate(manifest["createdAt"]) != nil,
      canonicalDate(manifest["completedAt"]) != nil
    else {
      return "SESSION_TIMESTAMP"
    }
    let eventIds = journal.compactMap { $0["eventId"] as? String }
    guard eventIds.count == journal.count, Set(eventIds).count == journal.count else {
      return "SESSION_EVENT_IDS"
    }
    let sequences = journal.compactMap { $0["sequence"] as? Int }
    guard sequences == Array(0..<journal.count) else {
      return "SESSION_SEQUENCE"
    }
    guard
      let created = journal.first,
      created["kind"] as? String == "jobCreated",
      let createdPayload = created["payload"] as? [String: Any],
      createdPayload["executionAuthority"] as? String == "authorizedAgent",
      createdPayload["executionMode"] as? String == "execute"
    else {
      return "SESSION_EXECUTION_MODE"
    }
    guard
      let authority = createdPayload["authorizationRef"] as? [String: Any],
      validateAuthorityRef(authority) == nil,
      Self.effectAuthority[expectedEffect] == authority["kind"] as? String
    else {
      return "SESSION_AUTHORITY"
    }
    let expectedUsage =
      session["usageReservationId"] is NSNull
      ? nil : session["usageReservationId"] as? String
    if authority["kind"] as? String == "readyTask" {
      guard expectedUsage == nil, createdPayload["usageReservationId"] == nil else {
        return "SESSION_USAGE"
      }
    } else {
      guard
        let expectedUsage,
        createdPayload["usageReservationId"] as? String == expectedUsage
      else {
        return "SESSION_USAGE"
      }
    }

    var intents: [String: [String: Any]] = [:]
    var correlatedIntentIds: Set<String> = []
    for event in journal.dropFirst() {
      guard
        event["sessionId"] as? String == created["sessionId"] as? String,
        event["jobId"] as? String == created["jobId"] as? String,
        let kind = event["kind"] as? String,
        let payload = event["payload"] as? [String: Any]
      else {
        return "SESSION_SHAPE"
      }
      if kind == "stepIntent" || kind == "compensationIntent" {
        guard let eventId = event["eventId"] as? String else {
          return "SESSION_SHAPE"
        }
        let externalEffect: String?
        if kind == "stepIntent" {
          externalEffect =
            (payload["step"] as? [String: Any])?["effect"] as? String
        } else {
          externalEffect =
            (payload["descriptor"] as? [String: Any])?["effect"] as? String
        }
        guard let externalEffect else {
          return "SESSION_SHAPE"
        }
        if externalEffect == "hostOnly" {
          guard
            payload["authorizationRef"] == nil,
            payload["usageReservationId"] == nil
          else {
            return "SESSION_HOST_ONLY_AUTHORITY"
          }
          continue
        }
        guard
          canonicalDataIfPossible(payload["authorizationRef"])
            == canonicalDataIfPossible(authority)
        else {
          return "SESSION_AUTHORITY"
        }
        if expectedUsage == nil {
          guard payload["usageReservationId"] == nil else {
            return "SESSION_USAGE"
          }
        } else {
          guard payload["usageReservationId"] as? String == expectedUsage else {
            return "SESSION_USAGE"
          }
        }
        guard
          Self.effectAuthority[externalEffect] == authority["kind"] as? String,
          event["bindingRevision"] is Int,
          payload["target"] is [String: Any]
        else {
          return "SESSION_AUTHORITY"
        }
        intents[eventId] = event
      } else if kind == "stepOutcome" || kind == "compensationOutcome" {
        guard
          let correlation = payload["correlatesToIntentEventId"] as? String,
          let intent = intents[correlation],
          correlatedIntentIds.insert(correlation).inserted,
          intent["stepId"] as? String == event["stepId"] as? String,
          intent["attempt"] as? Int == event["attempt"] as? Int
        else {
          return "SESSION_CORRELATION"
        }
        guard
          canonicalDataIfPossible(payload["authorizationRef"])
            == canonicalDataIfPossible(authority)
        else {
          return "SESSION_AUTHORITY"
        }
        if expectedUsage == nil {
          guard payload["usageReservationId"] == nil else {
            return "SESSION_USAGE"
          }
        } else {
          guard payload["usageReservationId"] as? String == expectedUsage else {
            return "SESSION_USAGE"
          }
        }
        if kind == "compensationOutcome" {
          guard
            let intentPayload = intent["payload"] as? [String: Any],
            payload["compensationOfStepId"] as? String
              == intentPayload["compensationOfStepId"] as? String,
            payload["descriptorId"] as? String
              == (intentPayload["descriptor"] as? [String: Any])?["id"] as? String
          else {
            return "SESSION_CORRELATION"
          }
        }
      }
    }

    guard
      manifest["executionAuthority"] as? String == "authorizedAgent",
      manifest["executionMode"] as? String == "execute",
      let manifestAuthorization = manifest["authorization"] as? [String: Any],
      canonicalDataIfPossible(manifestAuthorization["authorizationRef"])
        == canonicalDataIfPossible(authority)
    else {
      return "MANIFEST_AUTHORITY"
    }
    if expectedUsage == nil {
      guard manifestAuthorization["usageReservationId"] is NSNull else {
        return "MANIFEST_USAGE"
      }
    } else {
      guard
        manifestAuthorization["usageReservationId"] as? String == expectedUsage
      else {
        return "MANIFEST_USAGE"
      }
    }
    guard
      let manifestIntentIds = manifestAuthorization["externalIntentEventIds"] as? [String],
      Set(manifestIntentIds) == Set(intents.keys),
      manifestIntentIds.count == Set(manifestIntentIds).count
    else {
      return "MANIFEST_INTENTS"
    }
    let outstanding = Set(intents.keys).subtracting(correlatedIntentIds)
    if !outstanding.isEmpty {
      guard
        ["outcomeUnknown", "mixed"].contains(
          manifest["outcomeCertainty"] as? String)
      else {
        return "SESSION_OUTSTANDING_INTENT"
      }
    }
    if let confirmations = manifest["confirmations"] as? [[String: Any]] {
      for actor in confirmations where actor["kind"] as? String == "authorizedAgent" {
        guard
          canonicalDataIfPossible(actor["authorizationRef"])
            == canonicalDataIfPossible(authority)
        else {
          return "CONFIRMATION_AUTHORITY"
        }
      }
    }
    return nil
  }

  private func requiredDictionary(_ object: [String: Any], _ key: String) throws
    -> [String: Any]
  {
    try XCTUnwrap(object[key] as? [String: Any], key)
  }

  private func requiredArray(_ object: [String: Any], _ key: String) throws -> [Any] {
    try XCTUnwrap(object[key] as? [Any], key)
  }

  private func constant(at path: [String], in root: [String: Any]) throws -> String {
    let value = try valueAt(root, path: path[...])
    let object = try XCTUnwrap(value as? [String: Any])
    return try XCTUnwrap(object["const"] as? String)
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

  private func assertRefsAreOfflineOrPinned(_ value: Any, path: String) throws {
    if let object = value as? [String: Any] {
      if let reference = object["$ref"] as? String, reference.hasPrefix("http") {
        XCTAssertTrue(
          reference.hasPrefix(
            "https://arkdeck.dev/schemas/workflow-step-1.0.0.json#")
            || reference.hasPrefix(
              "https://arkdeck.dev/schemas/agent-execution-authority-1.0.0.json"),
          "\(path): \(reference)")
      }
      for (key, nested) in object {
        try assertRefsAreOfflineOrPinned(nested, path: "\(path).\(key)")
      }
    } else if let array = value as? [Any] {
      for (index, nested) in array.enumerated() {
        try assertRefsAreOfflineOrPinned(nested, path: "\(path)[\(index)]")
      }
    }
  }

  private func findForbiddenCarrierField(_ value: Any) -> String? {
    if let object = value as? [String: Any] {
      for (key, nested) in object {
        if Self.forbiddenCarrierFields.contains(key.lowercased()) {
          return key
        }
        if let nested = findForbiddenCarrierField(nested) {
          return nested
        }
      }
    } else if let array = value as? [Any] {
      for nested in array {
        if let nested = findForbiddenCarrierField(nested) {
          return nested
        }
      }
    }
    return nil
  }

  private func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) != nil
  }

  private func canonicalDate(_ value: Any?) -> Date? {
    guard
      let string = value as? String,
      matches(string, "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
    else {
      return nil
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
  }

  private func canonicalData(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }

  private func canonicalDataIfPossible(_ value: Any?) -> Data? {
    guard let value else {
      return nil
    }
    return try? canonicalData(value)
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func gitBlobSHA1(_ data: Data) -> String {
    var framed = Data("blob \(data.count)\u{0}".utf8)
    framed.append(data)
    return Insecure.SHA1.hash(data: framed)
      .map { String(format: "%02x", $0) }.joined()
  }

  private func replacing(
    _ root: Any, path: ArraySlice<String>, value: Any
  ) throws -> Any {
    guard let component = path.first else {
      return value
    }
    if var object = root as? [String: Any] {
      if path.count == 1 {
        object[component] = value
      } else {
        object[component] = try replacing(
          try XCTUnwrap(object[component]),
          path: path.dropFirst(),
          value: value)
      }
      return object
    }
    if var array = root as? [Any], let index = Int(component),
      array.indices.contains(index)
    {
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
    if var array = root as? [Any], let index = Int(component),
      array.indices.contains(index)
    {
      if path.count == 1 {
        array.remove(at: index)
      } else {
        array[index] = try removing(
          array[index], path: path.dropFirst())
      }
      return array
    }
    throw CocoaError(.coderInvalidValue)
  }

  private func appending(
    _ root: Any, path: ArraySlice<String>, value: Any
  ) throws -> Any {
    guard let component = path.first else {
      guard var array = root as? [Any] else {
        throw CocoaError(.coderInvalidValue)
      }
      array.append(value)
      return array
    }
    if var object = root as? [String: Any] {
      object[component] = try appending(
        try XCTUnwrap(object[component]),
        path: path.dropFirst(),
        value: value)
      return object
    }
    if var array = root as? [Any], let index = Int(component),
      array.indices.contains(index)
    {
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
    if let array = root as? [Any], let index = Int(component),
      array.indices.contains(index)
    {
      return try valueAt(array[index], path: path.dropFirst())
    }
    throw CocoaError(.coderInvalidValue)
  }

  private static let capabilityRootKeys: Set<String> = [
    "documentType", "schemaVersion", "capabilityId", "changeId", "taskId",
    "evidenceRefs", "target", "tool", "operationScopes", "limits",
    "privilegeRequirements", "prohibitedAdjacency", "validUntil",
  ]

  private static let targetKeys: Set<String> = [
    "durableTargetId", "model", "stableIdentitySHA256", "originalTargetSHA256",
    "acceptedBindingRevision", "transport", "firmwareBuild",
    "firmwareFingerprintSHA256", "allowedDeviceModes",
  ]

  private static let toolKeys: Set<String> = [
    "kind", "profileId", "reportedVersion", "executableSHA256",
  ]

  private static let scopeKeys: Set<String> = [
    "operationId", "profileId", "configurationId", "configurationSha256",
    "effect", "dataImpact", "namespace", "recoveryPolicy",
  ]

  private static let limitKeys: Set<String> = [
    "maximumDataImpact", "maximumJobDurationSeconds", "maximumConcurrentJobs",
    "maximumUses", "compensationGraceSeconds",
  ]

  private static let privilegeKeys: Set<String> = [
    "developerMode", "root", "packageDebuggable", "freshProbeProfileId",
    "maximumAgeSeconds",
  ]

  private static let reservationKeys: Set<String> = [
    "reservationId", "authorizationRef", "ordinal", "maximumUses",
    "maximumConcurrentJobs", "jobId", "operationDigestSHA256",
    "targetDigestSHA256", "reservedAt", "forwardLeaseExpiresAt",
    "compensationLeaseExpiresAt", "terminal",
  ]

  private static let provenanceKeys: Set<String> = [
    "repository", "branch", "registryPath", "currentMainCommitOID",
    "currentMainCapabilityBlobOID", "headCapabilityBlobOID",
    "mergeCapabilityBlobOID", "codeownersBlobOID", "networkAvailable",
    "offlineCacheUsed", "acceptancePR",
  ]

  private static let acceptancePRKeys: Set<String> = [
    "number", "state", "baseRefName", "author", "headCommitOID",
    "mergeCommitOID", "mergeCommitIsCurrentMainAncestor", "reviewer",
    "reviewState", "reviewCommitOID", "merger", "mergedAt",
  ]

  private static let dataImpactOrder = [
    "ephemeralOwnedState",
    "reversibleDeviceConfiguration",
    "applicationDataPreserving",
  ]

  private static let prohibitedProfiles = [
    "hilog.global-persist.v1",
    "hap.install-data-impact.v1",
    "hap.uninstall.v1",
    "native-library.system-publish.v1",
    "flash.rockchip-authorized.v1",
  ]

  private static let prohibitedStepKinds = [
    "mutateHDCServerLifecycle",
    "runApprovedRemoteMutation",
    "uninstallPackage",
    "enterUpdater",
    "flashPartition",
    "updatePackage",
    "erasePartition",
    "formatPartition",
    "unlockDevice",
  ]

  private static let forbiddenCarrierFields: Set<String> = [
    "approvedby", "carrier", "path", "argv", "readback", "usage", "outcome",
    "serial", "connectkey", "authorizationbytes", "authorizationpath",
    "capabilitybytes", "capabilitypath", "bookmark", "descriptor",
  ]

  private static let effectAuthority = [
    "readOnly": "readyTask",
    "deviceMutation": "deviceCapability",
    "destructive": "standingAuthorization",
  ]

  private static let scopeContracts: [String: ScopeContract] = [
    "hilog.device-persist-restored.v1": ScopeContract(
      operationId: "captureHilog",
      dataImpact: "reversibleDeviceConfiguration",
      namespaceKind: "captureOwned",
      namespaceFamily: "hilog",
      recoveryStrategy: "typedCompensation",
      requiredStepKinds: [
        "stopRemoteCapture", "resizeLogBuffer", "cleanupOwnedRemotePath",
      ]),
    "ui-dump.owned-sidecar.v1": ScopeContract(
      operationId: "captureUIDump",
      dataImpact: "reversibleDeviceConfiguration",
      namespaceKind: "captureOwned",
      namespaceFamily: "uiDump",
      recoveryStrategy: "typedCompensation",
      requiredStepKinds: ["restoreParameter", "cleanupOwnedRemotePath"]),
    "trace.owned-capture.v1": ScopeContract(
      operationId: "captureTrace",
      dataImpact: "reversibleDeviceConfiguration",
      namespaceKind: "captureOwned",
      namespaceFamily: "trace",
      recoveryStrategy: "typedCompensation",
      requiredStepKinds: [
        "stopRemoteCapture", "restoreParameter", "cleanupOwnedRemotePath",
      ]),
    "hap.install-preserve-data.v1": ScopeContract(
      operationId: "installHAP",
      dataImpact: "applicationDataPreserving",
      namespaceKind: "bundle",
      namespaceFamily: nil,
      recoveryStrategy: "verifiedRollback",
      requiredStepKinds: []),
    "native-library.app-owned-atomic.v1": ScopeContract(
      operationId: "deployNativeLibrary",
      dataImpact: "applicationDataPreserving",
      namespaceKind: "bundle",
      namespaceFamily: nil,
      recoveryStrategy: "verifiedRollback",
      requiredStepKinds: []),
    "application.start.v1": ScopeContract(
      operationId: "startApplication",
      dataImpact: "ephemeralOwnedState",
      namespaceKind: "bundle",
      namespaceFamily: nil,
      recoveryStrategy: "typedCompensation",
      requiredStepKinds: ["stopApplication"]),
    "application.stop.v1": ScopeContract(
      operationId: "stopApplication",
      dataImpact: "ephemeralOwnedState",
      namespaceKind: "bundle",
      namespaceFamily: nil,
      recoveryStrategy: "typedCompensation",
      requiredStepKinds: ["startApplication"]),
    "owned-file.send.v1": ScopeContract(
      operationId: "sendOwnedFile",
      dataImpact: "ephemeralOwnedState",
      namespaceKind: "jobOwnedRemote",
      namespaceFamily: nil,
      recoveryStrategy: "typedCompensation",
      requiredStepKinds: ["cleanupOwnedRemotePath"]),
    "port-forward.create.v1": ScopeContract(
      operationId: "createPortForward",
      dataImpact: "ephemeralOwnedState",
      namespaceKind: "portForward",
      namespaceFamily: nil,
      recoveryStrategy: "typedCompensation",
      requiredStepKinds: ["removePortForward"]),
    "port-forward.remove.v1": ScopeContract(
      operationId: "removePortForward",
      dataImpact: "ephemeralOwnedState",
      namespaceKind: "portForward",
      namespaceFamily: nil,
      recoveryStrategy: "typedCompensation",
      requiredStepKinds: ["createPortForward"]),
    "device.reboot.v1": ScopeContract(
      operationId: "rebootDevice",
      dataImpact: "reversibleDeviceConfiguration",
      namespaceKind: "deviceMode",
      namespaceFamily: nil,
      recoveryStrategy: "resumeProbeOnly",
      requiredStepKinds: []),
  ]
}

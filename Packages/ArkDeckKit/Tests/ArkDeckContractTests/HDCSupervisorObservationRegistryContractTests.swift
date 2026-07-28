import CryptoKit
import Foundation
import XCTest

/// TASK-HSO-001 registers data only. This suite reads repository/bundled resources and synthetic
/// controls; it never invokes HDC, scans host processes/sockets, accesses a device, or dispatches
/// lifecycle/mutation work.
final class HDCSupervisorObservationRegistryContractTests: XCTestCase {
  private static let registryID = "OPENHARMONY-HDC-SUPERVISOR-OBSERVATION-PROBES"
  private static let registryVersion = "1.0.0"
  private static let profile = "OPENHARMONY-TOOLS@0.6.0"
  private static let lock = "INTEGRATION-PROFILES-0.7.0"
  private static let toolVersion = "3.2.0f"
  private static let toolSHA256 =
    "05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83"
  private static let endpoint = "127.0.0.1:8710"
  private static let registrySHA256 =
    "f1691f748da10f1bb7753167d71ff3b764a347676f97d5ec70a1e97ac35c9763"
  private static let resourcesSHA256 =
    "6bf09cabfc762b1e632d6dba2528b04b33173f6e53f2f1669d26ef8d72a4ab3d"
  private static let receiptSHA256 =
    "2edb677d25849eef8c0dede8c639a9ca21649578c7184b343870c5b79ecf1350"
  private static let sourceSHA256 =
    "ef3372dadc19c4a0e84f6f15f3ac616751d0351cfc2372fa9cf943952275318e"
  private static let acceptedHeads = [
    "48de853d984e5781510c3d38ddc473d0d36e8373",
    "76ef464bf18f536ea304076768a85391fc9d7b5e",
  ]
  private static let acceptedMerges = [
    "af6d64d67af98c94e1f03581de6f52ecdb8a6bb2",
    "6df25c25d0088238ce2700db07c4db6fbd92cc34",
  ]
  private static let zeroEffectKeys: Set<String> = [
    "hdcChild", "serverStart", "serverStop", "serverRestart", "serverAdoption",
    "subserverLifecycle", "deviceMigration", "deviceMutation", "bindingMutation", "destructive",
  ]

  private struct Registry: Decodable {
    struct ToolContext: Decodable {
      let platform: String
      let reportedVersion: String
      let executableSHA256: String
      let endpoint: String
      let divergenceNote: String
    }

    struct Entry: Decodable {
      struct ExecutableIdentityPolicy: Decodable {
        let required: Bool
        let sha256: String
        let pathSource: String
        let verifyBytesBeforePreScan: Bool
        let verifyBytesAfterPostScan: Bool
        let replacementInvalidatesReceipt: Bool
      }

      struct EndpointPolicy: Decodable {
        let requiresExactEndpoint: Bool
        let endpoint: String
        let existingServerRequired: Bool
        let serverAbsentDisposition: String
        let multipleOrAmbiguousDisposition: String
        let fallbackAllowed: Bool
      }

      struct ObservationContract: Decodable {
        let requiredListenerCount: Int
        let listenerMustBeOwnedByObservedProcess: Bool
        let boundedPrePostScanRequired: Bool
        let prePostEqualityFields: [String]
        let listenerNormalization: [String]
        let portOnlyMatchAllowed: Bool
      }

      struct InputContract: Decodable {
        let rawFamily: String
        let stream: String
        let exitCode: Int?
        let receiptId: String
        let receiptPath: String
        let receiptSHA256: String
        let receiptIsReusableProductionAuthority: Bool
      }

      struct SemanticMapping: Decodable {
        let input: String
        let result: String
      }

      struct GenerationPolicy: Decodable {
        let mintedOnlyFromCurrentPlatformObserverReceipt: Bool
        let callerReceiptAllowed: Bool
        let callerGenerationAllowed: Bool
        let persistedReceiptMayMint: Bool
        let deviceSnapshotMayMint: Bool
        let failedObservationRetainsExternalClaim: Bool
      }

      struct AuthorityLimit: Decodable {
        let mayEstablish: [String]
        let mustMatch: [String]
        let neverEstablish: [String]
      }

      struct Timeout: Decodable {
        let milliseconds: Int
        let resultOnExpiry: String
      }

      struct Cancellation: Decodable {
        let result: String
        let mayTerminateOwnedObservation: Bool
        let mayKillHDCServer: Bool
        let cleanup: String
      }

      struct Provenance: Decodable {
        struct Deviation: Decodable {
          let id: String
          let disposition: String
        }

        let evidenceClass: String
        let sourceChange: String
        let sourceEvidence: String
        let sourceSHA256: String
        let acceptedHeads: [String]
        let acceptedMerges: [String]
        let acceptedBy: String
        let deviation: Deviation
        let repositoryGoldenFixture: Bool
      }

      let id: String
      let family: String
      let status: String
      let probeKind: String
      let platform: String
      let toolReportedVersion: String
      let executableIdentityPolicy: ExecutableIdentityPolicy
      let exactArgv: [String]
      let invocationAllowed: Bool
      let preconditions: [String]
      let endpointPolicy: EndpointPolicy
      let observationContract: ObservationContract
      let inputContract: InputContract
      let semanticMappings: [SemanticMapping]
      let generationPolicy: GenerationPolicy
      let effectClassification: String
      let forbiddenEffects: [String]
      let authorityLimit: AuthorityLimit
      let timeout: Timeout
      let cancellation: Cancellation
      let provenance: Provenance
    }

    let schemaVersion: String
    let serializationFormat: String
    let registryId: String
    let registryVersion: String
    let integrationProfile: String
    let registeredBy: String
    let unknownFamilyDisposition: String
    let toolContext: ToolContext
    let entries: [Entry]
  }

  private struct Resources: Decodable {
    struct Resource: Decodable {
      let id: String?
      let file: String
      let bytes: Int
      let sha256: String
      let evidenceClass: String
    }

    struct Provenance: Decodable {
      let sourceChange: String
      let sourceEvidence: String
      let sourceSHA256: String
      let acceptedMerges: [String]
      let deviation: String
    }

    let schemaVersion: String
    let packVersion: String
    let registryId: String
    let registryVersion: String
    let integrationProfile: String
    let canonicalRegistryPath: String
    let registryCopy: Resource
    let receipt: Resource
    let controls: Resource
    let attributes: Resource
    let provenance: Provenance
    let boundary: String
  }

  private struct Receipt: Decodable {
    struct Candidate: Decodable {
      let platform: String
      let reportedVersion: String
      let executableSHA256: String
      let resolvedPathToken: String
    }

    struct Observation: Decodable, Equatable {
      let pidToken: String
      let startSecondsToken: String
      let startMicrosecondsToken: String
      let resolvedExecutablePathToken: String
      let executableSHA256: String
      let normalizedEndpoint: String
      let listenerOwnerToken: String
      let listenerCount: Int
    }

    let schemaVersion: String
    let id: String
    let family: String
    let evidenceClass: String
    let boundary: String
    let selectedCandidate: Candidate
    let endpoint: String
    let preObservation: Observation
    let postObservation: Observation
    let candidateByteVerification: [String]
    let expectedDisposition: String
    let dispatchCounters: [String: Int]
  }

  private struct Controls: Decodable {
    struct Case: Decodable {
      let id: String
      let mutations: [String]
      let expectedDisposition: String
      let mayMintGeneration: Bool
      let fallbackAllowed: Bool
    }

    let schemaVersion: String
    let evidenceClass: String
    let boundary: String
    let cases: [Case]
    let expectedDispatchCounters: [String: Int]
  }

  private enum ValidationError: Error {
    case invalidRegistry
  }

  private var repoRoot: URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 {
      url.deleteLastPathComponent()
    }
    return url
  }

  private func packURL() throws -> URL {
    let probes = try XCTUnwrap(
      Bundle.module.url(forResource: "Probes", withExtension: nil),
      "SwiftPM must copy the whole Probes resource tree")
    return probes.appendingPathComponent("SupervisorObservation/1.0.0", isDirectory: true)
  }

  private func packData(_ path: String) throws -> Data {
    try Data(contentsOf: try packURL().appendingPathComponent(path))
  }

  private func repositoryData(_ path: String) throws -> Data {
    try Data(contentsOf: repoRoot.appendingPathComponent(path))
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func registry() throws -> Registry {
    try JSONDecoder().decode(Registry.self, from: try packData("registry.yaml"))
  }

  private func resources() throws -> Resources {
    try JSONDecoder().decode(Resources.self, from: try packData("resources.json"))
  }

  private func receipt() throws -> Receipt {
    try JSONDecoder().decode(
      Receipt.self, from: try packData("receipts/server-identity-generation.json"))
  }

  private func controls() throws -> Controls {
    try JSONDecoder().decode(
      Controls.self, from: try packData("controls/fail-closed-vectors.json"))
  }

  func testCanonicalRegistryAndPackAreHashClosed() throws {
    let manifest = try resources()
    let bundledRegistry = try packData(manifest.registryCopy.file)
    let canonicalRegistry = try repositoryData(manifest.canonicalRegistryPath)
    XCTAssertEqual(bundledRegistry, canonicalRegistry)
    XCTAssertEqual(digest(bundledRegistry), Self.registrySHA256)
    XCTAssertEqual(manifest.registryCopy.sha256, Self.registrySHA256)
    XCTAssertEqual(manifest.registryCopy.bytes, bundledRegistry.count)
    XCTAssertEqual(digest(try packData(manifest.receipt.file)), manifest.receipt.sha256)
    XCTAssertEqual(try packData(manifest.receipt.file).count, manifest.receipt.bytes)
    XCTAssertEqual(digest(try packData(manifest.controls.file)), manifest.controls.sha256)
    XCTAssertEqual(try packData(manifest.controls.file).count, manifest.controls.bytes)
    XCTAssertEqual(digest(try packData(manifest.attributes.file)), manifest.attributes.sha256)
    XCTAssertEqual(try packData(manifest.attributes.file).count, manifest.attributes.bytes)
    XCTAssertEqual(digest(try packData("resources.json")), Self.resourcesSHA256)

    let root = try packURL()
    let listed = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { relative in
      var isDirectory: ObjCBool = false
      _ = FileManager.default.fileExists(
        atPath: root.appendingPathComponent(relative).path, isDirectory: &isDirectory)
      return !isDirectory.boolValue
    }
    XCTAssertEqual(
      Set(listed),
      Set([
        ".gitattributes", "registry.yaml", "resources.json",
        "receipts/server-identity-generation.json", "controls/fail-closed-vectors.json",
      ]))
  }

  func testExactCommandlessAuthorityIsClosed() throws {
    let value = try registry()
    XCTAssertEqual(value.schemaVersion, "1.0.0")
    XCTAssertEqual(value.serializationFormat, "json-compatible-yaml-1.2")
    XCTAssertEqual(value.registryId, Self.registryID)
    XCTAssertEqual(value.registryVersion, Self.registryVersion)
    XCTAssertEqual(value.integrationProfile, Self.profile)
    XCTAssertEqual(value.unknownFamilyDisposition, "unsupported")
    XCTAssertEqual(value.toolContext.platform, "macos")
    XCTAssertEqual(value.toolContext.reportedVersion, Self.toolVersion)
    XCTAssertEqual(value.toolContext.executableSHA256, Self.toolSHA256)
    XCTAssertEqual(value.toolContext.endpoint, Self.endpoint)
    XCTAssertTrue(value.toolContext.divergenceNote.contains("3.2.0d"))

    let entry = try XCTUnwrap(value.entries.only)
    XCTAssertEqual(entry.family, "serverIdentityGeneration")
    XCTAssertEqual(entry.status, "supported")
    XCTAssertEqual(entry.probeKind, "platformProcessObservation")
    XCTAssertEqual(entry.platform, "macos")
    XCTAssertEqual(entry.toolReportedVersion, Self.toolVersion)
    XCTAssertEqual(entry.executableIdentityPolicy.sha256, Self.toolSHA256)
    XCTAssertTrue(entry.executableIdentityPolicy.verifyBytesBeforePreScan)
    XCTAssertTrue(entry.executableIdentityPolicy.verifyBytesAfterPostScan)
    XCTAssertEqual(entry.exactArgv, [])
    XCTAssertFalse(entry.invocationAllowed)
    XCTAssertEqual(entry.endpointPolicy.endpoint, Self.endpoint)
    XCTAssertTrue(entry.endpointPolicy.existingServerRequired)
    XCTAssertFalse(entry.endpointPolicy.fallbackAllowed)
    XCTAssertEqual(entry.observationContract.requiredListenerCount, 1)
    XCTAssertTrue(entry.observationContract.listenerMustBeOwnedByObservedProcess)
    XCTAssertTrue(entry.observationContract.boundedPrePostScanRequired)
    XCTAssertFalse(entry.observationContract.portOnlyMatchAllowed)
    XCTAssertEqual(
      Set(entry.observationContract.prePostEqualityFields),
      Set([
        "pid", "startSeconds", "startMicroseconds", "resolvedExecutablePath",
        "executableSHA256", "normalizedEndpoint", "listenerOwner",
      ]))
    XCTAssertEqual(entry.inputContract.stream, "none")
    XCTAssertNil(entry.inputContract.exitCode)
    XCTAssertEqual(entry.inputContract.receiptSHA256, Self.receiptSHA256)
    XCTAssertFalse(entry.inputContract.receiptIsReusableProductionAuthority)
  }

  func testGenerationCannotBeForgedAndEffectsAreClosed() throws {
    let entry = try XCTUnwrap(try registry().entries.only)
    XCTAssertTrue(entry.generationPolicy.mintedOnlyFromCurrentPlatformObserverReceipt)
    XCTAssertFalse(entry.generationPolicy.callerReceiptAllowed)
    XCTAssertFalse(entry.generationPolicy.callerGenerationAllowed)
    XCTAssertFalse(entry.generationPolicy.persistedReceiptMayMint)
    XCTAssertFalse(entry.generationPolicy.deviceSnapshotMayMint)
    XCTAssertFalse(entry.generationPolicy.failedObservationRetainsExternalClaim)
    XCTAssertEqual(entry.effectClassification, "readOnly")
    XCTAssertEqual(Set(entry.forbiddenEffects), Self.zeroEffectKeys)
    XCTAssertFalse(entry.cancellation.mayKillHDCServer)
    XCTAssertGreaterThan(entry.timeout.milliseconds, 0)

    let never = entry.authorityLimit.neverEstablish.joined(separator: " ")
    for term in [
      "external origin", "four-evidence", "health", "client version", "server version",
      "daemon version", "checkserver", "lifecycle", "device", "binding", "destructive",
      "caller-provided", "fallback",
    ] {
      XCTAssertTrue(never.contains(term), "missing authority boundary \(term)")
    }
  }

  func testProvenanceIsExactArchiveStableAndDisclosesDEV1() throws {
    let provenance = try XCTUnwrap(try registry().entries.only).provenance
    XCTAssertEqual(provenance.evidenceClass, "controlledHumanCapture")
    XCTAssertEqual(provenance.sourceChange, "CHG-2026-024-hdc-device-snapshot-registration")
    XCTAssertEqual(provenance.sourceEvidence, "evidence/runs/TASK-I24-001/run.md")
    XCTAssertFalse(provenance.sourceEvidence.hasPrefix("/"))
    XCTAssertFalse(provenance.sourceEvidence.contains("openspec/changes/"))
    XCTAssertEqual(provenance.sourceSHA256, Self.sourceSHA256)
    XCTAssertEqual(provenance.acceptedHeads, Self.acceptedHeads)
    XCTAssertEqual(provenance.acceptedMerges, Self.acceptedMerges)
    XCTAssertTrue(provenance.acceptedBy.contains("lvye"))
    XCTAssertEqual(provenance.deviation.id, "DEV-1")
    XCTAssertTrue(provenance.deviation.disposition.contains("commandless"))
    XCTAssertTrue(provenance.deviation.disposition.contains("no HDC command output"))
    XCTAssertFalse(provenance.repositoryGoldenFixture)

    let manifest = try resources()
    XCTAssertEqual(manifest.provenance.sourceChange, provenance.sourceChange)
    XCTAssertEqual(manifest.provenance.sourceEvidence, provenance.sourceEvidence)
    XCTAssertEqual(manifest.provenance.sourceSHA256, provenance.sourceSHA256)
    XCTAssertEqual(manifest.provenance.acceptedMerges, provenance.acceptedMerges)
    XCTAssertTrue(manifest.provenance.deviation.contains("DEV-1"))
  }

  func testRedactedReceiptIsStableAndCarriesNoEffects() throws {
    let value = try receipt()
    XCTAssertEqual(value.evidenceClass, "controlledCaptureRedactedStructure")
    XCTAssertTrue(value.boundary.contains("not a reusable production receipt"))
    XCTAssertEqual(value.selectedCandidate.platform, "macos")
    XCTAssertEqual(value.selectedCandidate.reportedVersion, Self.toolVersion)
    XCTAssertEqual(value.selectedCandidate.executableSHA256, Self.toolSHA256)
    XCTAssertEqual(value.endpoint, Self.endpoint)
    XCTAssertEqual(value.preObservation, value.postObservation)
    XCTAssertEqual(value.preObservation.listenerCount, 1)
    XCTAssertEqual(value.preObservation.listenerOwnerToken, value.preObservation.pidToken)
    XCTAssertEqual(value.preObservation.normalizedEndpoint, Self.endpoint)
    XCTAssertEqual(
      Set(value.candidateByteVerification), Set(["beforePreScan", "afterPostScan"]))
    XCTAssertEqual(value.expectedDisposition, "observed.generation")
    XCTAssertEqual(Set(value.dispatchCounters.keys), Self.zeroEffectKeys)
    XCTAssertTrue(value.dispatchCounters.values.allSatisfy { $0 == 0 })

    let text = String(decoding: try packData("receipts/server-identity-generation.json"), as: UTF8.self)
    for forbidden in ["/Users/", "fuhanfeng", "22677", "80306", "connectKey", "serialNumber"] {
      XCTAssertFalse(text.contains(forbidden), "redacted receipt leaks \(forbidden)")
    }
  }

  func testFailClosedMatrixCoversEveryRequiredHazardWithZeroEffects() throws {
    let value = try controls()
    let expectedIDs: Set<String> = [
      "wrong-tool-version", "wrong-tool-sha256", "wrong-endpoint", "missing-provenance",
      "changed-accepted-merge", "argv-added", "invocation-enabled", "no-listener",
      "multiple-listeners", "listener-wrong-owner", "pid-drift", "start-drift",
      "path-drift", "hash-drift", "endpoint-drift", "timeout", "cancellation", "scan-error",
      "caller-supplied-receipt", "caller-supplied-generation",
      "cross-version-fallback-3.2.0d",
    ]
    XCTAssertEqual(Set(value.cases.map(\.id)), expectedIDs)
    XCTAssertTrue(value.cases.allSatisfy { !$0.mayMintGeneration && !$0.fallbackAllowed })
    XCTAssertTrue(
      value.cases.allSatisfy {
        ["unsupported", "unavailable", "unknown", "timedOut", "cancelled"]
          .contains($0.expectedDisposition)
      })
    XCTAssertEqual(Set(value.expectedDispatchCounters.keys), Self.zeroEffectKeys)
    XCTAssertTrue(value.expectedDispatchCounters.values.allSatisfy { $0 == 0 })
    XCTAssertEqual(
      value.cases.first(where: { $0.id == "cross-version-fallback-3.2.0d" })?
        .expectedDisposition,
      "unsupported")
    XCTAssertEqual(
      value.cases.first(where: { $0.id == "no-listener" })?.expectedDisposition,
      "unavailable")
  }

  func testIndependentMutationMatrixRejectsAuthorityDrift() throws {
    let clean = try packData("registry.yaml")
    XCTAssertNoThrow(try validateRegistry(clean))

    let mutations: [(String, (inout [String: Any], inout [String: Any]) -> Void)] = [
      ("profile", { root, _ in root["integrationProfile"] = "OPENHARMONY-TOOLS@0.5.0" }),
      ("registry-id", { root, _ in root["registryId"] = "OPENHARMONY-HDC-READONLY-PROBES" }),
      ("tool-version", { root, _ in
        var tool = root["toolContext"] as! [String: Any]
        tool["reportedVersion"] = "3.2.0d"
        root["toolContext"] = tool
      }),
      ("tool-hash", { root, _ in
        var tool = root["toolContext"] as! [String: Any]
        tool["executableSHA256"] = String(repeating: "0", count: 64)
        root["toolContext"] = tool
      }),
      ("endpoint", { root, _ in
        var tool = root["toolContext"] as! [String: Any]
        tool["endpoint"] = "127.0.0.1:8711"
        root["toolContext"] = tool
      }),
      ("argv", { _, entry in entry["exactArgv"] = ["checkserver"] }),
      ("invocation", { _, entry in entry["invocationAllowed"] = true }),
      ("effect", { _, entry in entry["effectClassification"] = "hdcCommand" }),
      ("fallback", { _, entry in
        var policy = entry["endpointPolicy"] as! [String: Any]
        policy["fallbackAllowed"] = true
        entry["endpointPolicy"] = policy
      }),
      ("receipt-hash", { _, entry in
        var input = entry["inputContract"] as! [String: Any]
        input["receiptSHA256"] = String(repeating: "0", count: 64)
        entry["inputContract"] = input
      }),
      ("accepted-merges", { _, entry in
        var provenance = entry["provenance"] as! [String: Any]
        provenance["acceptedMerges"] = [Self.acceptedMerges[0]]
        entry["provenance"] = provenance
      }),
      ("dev-1", { _, entry in
        var provenance = entry["provenance"] as! [String: Any]
        provenance["deviation"] = ["id": "NONE", "disposition": "none"]
        entry["provenance"] = provenance
      }),
      ("forbidden-effects", { _, entry in
        entry["forbiddenEffects"] = ["serverStart", "serverStop", "destructive"]
      }),
    ]

    for (name, mutation) in mutations {
      let data = try mutatedRegistry(mutation)
      XCTAssertThrowsError(try validateRegistry(data), "mutation \(name) must turn red")
    }
  }

  func testProfileLockAndMacOSMappingCloseOnExactHashes() throws {
    let profile = String(
      decoding: try repositoryData("openspec/integrations/openharmony/profile.md"), as: UTF8.self)
    let lock = String(
      decoding: try repositoryData("openspec/integrations/INTEGRATION-PROFILES.lock.yaml"),
      as: UTF8.self)
    let macOS = String(
      decoding: try repositoryData("openspec/platforms/macos/profile.md"), as: UTF8.self)

    XCTAssertEqual(profile.components(separatedBy: "> Version：0.6.0").count - 1, 1)
    XCTAssertTrue(profile.contains(Self.registryID))
    XCTAssertTrue(profile.contains(Self.registrySHA256))
    XCTAssertTrue(profile.contains(Self.resourcesSHA256))
    XCTAssertTrue(profile.contains(Self.lock))

    XCTAssertTrue(lock.contains("lock: \(Self.lock)"))
    XCTAssertTrue(lock.contains("version: 0.6.0"))
    XCTAssertTrue(lock.contains("profile: \(Self.profile)"))
    XCTAssertTrue(lock.contains(Self.registryID))
    XCTAssertTrue(lock.contains(Self.registrySHA256))
    XCTAssertTrue(lock.contains(Self.resourcesSHA256))

    XCTAssertTrue(macOS.contains(Self.registryID))
    XCTAssertTrue(macOS.contains(Self.profile))
    XCTAssertTrue(macOS.contains(Self.lock))
    XCTAssertTrue(macOS.contains(Self.registrySHA256))
    XCTAssertTrue(macOS.contains(Self.resourcesSHA256))
  }

  func testReadonlyAndDeviceRegistryResourceClosuresRemainPinned() throws {
    let pins: [(String, String)] = [
      (
        "openspec/integrations/openharmony/readonly-probes.yaml",
        "b0ac1564109b8138c7a73cbb83684400967633f6e6b04701175a22d314d88da6"
      ),
      (
        "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/1.0.0/resources.json",
        "e91e38dfa9a01132062865837844cf77494644488fba9527ce52c5a68c593bf6"
      ),
      (
        "openspec/integrations/openharmony/device-observation-probes.yaml",
        "79814e45901ab7e4d9f9a271645cad62b0053a50534cba884cdff0c2e50b9d49"
      ),
      (
        "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/DeviceObservation/1.0.0/resources.json",
        "5192f30d9e38d869ab5f87ae1f0c53b68b66205f6421b9a0b613e5863e33f4d2"
      ),
    ]
    for (path, expected) in pins {
      XCTAssertEqual(digest(try repositoryData(path)), expected, "\(path) drifted")
    }
  }

  private func mutatedRegistry(
    _ mutation: (inout [String: Any], inout [String: Any]) -> Void
  ) throws -> Data {
    var root = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: packData("registry.yaml")) as? [String: Any])
    var entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
    var entry = try XCTUnwrap(entries.first)
    mutation(&root, &entry)
    entries[0] = entry
    root["entries"] = entries
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
  }

  private func validateRegistry(_ data: Data) throws {
    let root = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [String: Any])
    guard root["registryId"] as? String == Self.registryID,
      root["registryVersion"] as? String == Self.registryVersion,
      root["integrationProfile"] as? String == Self.profile,
      root["unknownFamilyDisposition"] as? String == "unsupported",
      let tool = root["toolContext"] as? [String: Any],
      tool["platform"] as? String == "macos",
      tool["reportedVersion"] as? String == Self.toolVersion,
      tool["executableSHA256"] as? String == Self.toolSHA256,
      tool["endpoint"] as? String == Self.endpoint,
      let entries = root["entries"] as? [[String: Any]], entries.count == 1,
      let entry = entries.first,
      entry["family"] as? String == "serverIdentityGeneration",
      entry["probeKind"] as? String == "platformProcessObservation",
      entry["toolReportedVersion"] as? String == Self.toolVersion,
      (entry["exactArgv"] as? [String]) == [],
      entry["invocationAllowed"] as? Bool == false,
      entry["effectClassification"] as? String == "readOnly",
      let executable = entry["executableIdentityPolicy"] as? [String: Any],
      executable["sha256"] as? String == Self.toolSHA256,
      executable["verifyBytesBeforePreScan"] as? Bool == true,
      executable["verifyBytesAfterPostScan"] as? Bool == true,
      let endpoint = entry["endpointPolicy"] as? [String: Any],
      endpoint["endpoint"] as? String == Self.endpoint,
      endpoint["fallbackAllowed"] as? Bool == false,
      let observation = entry["observationContract"] as? [String: Any],
      observation["requiredListenerCount"] as? Int == 1,
      observation["boundedPrePostScanRequired"] as? Bool == true,
      observation["portOnlyMatchAllowed"] as? Bool == false,
      let input = entry["inputContract"] as? [String: Any],
      input["receiptSHA256"] as? String == Self.receiptSHA256,
      input["receiptIsReusableProductionAuthority"] as? Bool == false,
      Set(entry["forbiddenEffects"] as? [String] ?? []) == Self.zeroEffectKeys,
      let provenance = entry["provenance"] as? [String: Any],
      provenance["sourceChange"] as? String
        == "CHG-2026-024-hdc-device-snapshot-registration",
      provenance["sourceEvidence"] as? String == "evidence/runs/TASK-I24-001/run.md",
      provenance["sourceSHA256"] as? String == Self.sourceSHA256,
      provenance["acceptedHeads"] as? [String] == Self.acceptedHeads,
      provenance["acceptedMerges"] as? [String] == Self.acceptedMerges,
      let deviation = provenance["deviation"] as? [String: Any],
      deviation["id"] as? String == "DEV-1",
      (deviation["disposition"] as? String)?.contains("commandless") == true
    else {
      throw ValidationError.invalidRegistry
    }
  }
}

private extension Array {
  var only: Element? {
    count == 1 ? first : nil
  }
}

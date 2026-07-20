import CryptoKit
import Foundation
import XCTest

/// TASK-I15-001 (CHG-2026-015): the production probe registry is a closed, versioned allowlist.
/// These tests consume only bundled repository resources and fake control vectors. They never
/// invoke an installed HDC, access a device, open a network connection, or mutate server state.
final class HDCProbeRegistryContractTests: XCTestCase {
  private struct ProbeRegistry: Decodable {
    let schemaVersion: String
    let serializationFormat: String
    let registryId: String
    let registryVersion: String
    let integrationProfile: String
    let registeredBy: String
    let unknownFamilyDisposition: String
    let toolContext: ToolContext
    let entries: [Entry]

    struct ToolContext: Decodable {
      let platform: String
      let reportedVersion: String
      let executableSHA256: String
    }

    struct Entry: Decodable {
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
      let effectClassification: String
      let forbiddenEffects: [String]
      let inputContract: InputContract
      let semanticMappings: [SemanticMapping]
      let authorityLimit: AuthorityLimit
      let timeout: Timeout
      let cancellation: Cancellation
      let provenance: Provenance
      let unsupportedReason: String?
    }

    struct ExecutableIdentityPolicy: Decodable {
      let required: Bool
      let sha256: String
      let pathSource: String
      let replacementInvalidatesReceipt: Bool
    }

    struct EndpointPolicy: Decodable {
      let requiresExactEndpoint: Bool
      let existingServerRequired: Bool
      let serverAbsentDisposition: String
    }

    struct InputContract: Decodable {
      let rawFamily: String
      let stream: String
      let exitCode: Int?
      let rawSHA256: String?
      let rawStorage: String?
      let receiptId: String
      let receiptPath: String
      let receiptSHA256: String
    }

    struct SemanticMapping: Decodable {
      let input: String
      let result: String
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
      let evidenceClass: String
      let sourcePath: String
      let sourceSHA256: String
      let acceptedBy: String
    }
  }

  private struct ResourceManifest: Decodable {
    let schemaVersion: String
    let packVersion: String
    let registrySerializationFormat: String
    let registryId: String
    let registryVersion: String
    let integrationProfile: String
    let registeredBy: String
    let entries: [Entry]
    let resources: [Resource]

    struct Entry: Decodable {
      let id: String
      let family: String
      let status: String
      let effectClassification: String
      let receiptId: String
    }

    struct Resource: Decodable {
      let id: String
      let path: String
      let sha256: String
      let sizeBytes: Int
      let evidenceClass: String
    }
  }

  private struct ReceiptHeader: Decodable {
    let schemaVersion: String
    let id: String
    let version: String
    let family: String
    let evidenceClass: String
    let source: Source
    let dispatchCounters: [String: Int]?

    struct Source: Decodable {
      let path: String
      let sha256: String
      let acceptedBy: String
    }
  }

  private struct ControlPack: Decodable {
    let schemaVersion: String
    let evidenceClass: String
    let boundary: String
    let vectors: [Vector]
    let expectedDispatchCounters: [String: Int]

    struct Vector: Decodable {
      let id: String
      let family: String
      let registryKnown: Bool
      let provenanceValid: Bool
      let preconditionValid: Bool
      let identityMatches: Bool
      let bindingMatches: Bool
      let authorityPresent: Bool
      let rawFamilyKnown: Bool
      let deniedObservation: Bool?
      let effectProven: Bool
      let cancelled: Bool
      let timedOut: Bool
      let mutationName: Bool
      let expectedDisposition: String
    }
  }

  private enum RegistryValidationError: Error, Equatable {
    case invalidHeader
    case incompleteFamilySet
    case duplicateEntry
    case unknownFamily
    case unknownStatus
    case unknownProbeKind
    case invalidSupportedEntry
    case invalidUnsupportedEntry
    case invalidSafetyContract
    case invalidProvenance
  }

  private let expectedFamilies: Set<String> = [
    "serverIdentityGeneration",
    "selectedDeviceAuthorizationBinding",
    "keyAccessDiagnostics",
    "subserverCapability",
  ]

  private let alwaysForbiddenEffects: Set<String> = [
    "serverStart",
    "serverStop",
    "serverRestart",
    "deviceMutation",
    "destructive",
  ]

  private func probesRoot() throws -> URL {
    try XCTUnwrap(
      Bundle.module.url(forResource: "Probes", withExtension: nil),
      "Probes resource tree must be packaged via the SwiftPM .copy declaration")
  }

  private func resourceURL(_ path: String) throws -> URL {
    try probesRoot().appending(path: path)
  }

  private func loadRegistry() throws -> ProbeRegistry {
    let data = try Data(contentsOf: resourceURL("1.0.0/registry.yaml"))
    return try JSONDecoder().decode(ProbeRegistry.self, from: data)
  }

  private func loadResourceManifest() throws -> ResourceManifest {
    let data = try Data(contentsOf: resourceURL("1.0.0/resources.json"))
    return try JSONDecoder().decode(ResourceManifest.self, from: data)
  }

  private func loadControlPack() throws -> ControlPack {
    let data = try Data(contentsOf: resourceURL("1.0.0/controls/fail-closed-vectors.json"))
    return try JSONDecoder().decode(ControlPack.self, from: data)
  }

  private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func validate(_ registry: ProbeRegistry) throws {
    guard registry.schemaVersion == "1.0.0",
      registry.serializationFormat == "json-compatible-yaml-1.2",
      registry.registryId == "OPENHARMONY-HDC-READONLY-PROBES",
      registry.registryVersion == "1.0.0",
      registry.integrationProfile == "OPENHARMONY-TOOLS@0.3.0",
      registry.unknownFamilyDisposition == "unsupported"
    else {
      throw RegistryValidationError.invalidHeader
    }

    guard registry.entries.count == expectedFamilies.count else {
      throw RegistryValidationError.incompleteFamilySet
    }
    let ids = Set(registry.entries.map(\.id))
    let families = Set(registry.entries.map(\.family))
    guard ids.count == registry.entries.count, families.count == registry.entries.count else {
      throw RegistryValidationError.duplicateEntry
    }
    guard families == expectedFamilies else {
      throw families.isSubset(of: expectedFamilies)
        ? RegistryValidationError.incompleteFamilySet
        : RegistryValidationError.unknownFamily
    }

    for entry in registry.entries {
      guard ["supported", "unsupported"].contains(entry.status) else {
        throw RegistryValidationError.unknownStatus
      }
      guard
        ["hdcCommand", "platformProcessObservation", "platformFileAccess"]
          .contains(entry.probeKind)
      else {
        throw RegistryValidationError.unknownProbeKind
      }
      guard entry.executableIdentityPolicy.required,
        entry.executableIdentityPolicy.replacementInvalidatesReceipt,
        entry.executableIdentityPolicy.sha256 == registry.toolContext.executableSHA256,
        entry.toolReportedVersion == registry.toolContext.reportedVersion,
        !entry.preconditions.isEmpty,
        !entry.semanticMappings.isEmpty,
        !entry.authorityLimit.neverEstablish.isEmpty,
        entry.cancellation.mayKillHDCServer == false,
        alwaysForbiddenEffects.isSubset(of: Set(entry.forbiddenEffects))
      else {
        throw RegistryValidationError.invalidSafetyContract
      }
      guard entry.provenance.evidenceClass != "fakeControlOnly",
        entry.provenance.sourceSHA256.count == 64,
        entry.provenance.sourcePath.hasPrefix("openspec/changes/"),
        !entry.provenance.acceptedBy.isEmpty
      else {
        throw RegistryValidationError.invalidProvenance
      }

      if entry.status == "supported" {
        guard entry.unsupportedReason == nil,
          entry.effectClassification.hasPrefix("readOnly"),
          entry.timeout.milliseconds > 0
        else {
          throw RegistryValidationError.invalidSupportedEntry
        }
        if entry.probeKind == "hdcCommand" {
          guard entry.invocationAllowed, !entry.exactArgv.isEmpty,
            entry.endpointPolicy.existingServerRequired,
            entry.endpointPolicy.serverAbsentDisposition == "unavailable"
          else {
            throw RegistryValidationError.invalidSupportedEntry
          }
        } else {
          guard entry.invocationAllowed == false, entry.exactArgv.isEmpty else {
            throw RegistryValidationError.invalidSupportedEntry
          }
        }
      } else {
        guard entry.invocationAllowed == false,
          entry.exactArgv.isEmpty,
          entry.effectClassification == "noneUnsupported",
          entry.timeout.milliseconds == 0,
          entry.unsupportedReason?.isEmpty == false,
          entry.semanticMappings.allSatisfy({ $0.result == "unsupported" })
        else {
          throw RegistryValidationError.invalidUnsupportedEntry
        }
      }
    }
  }

  private func disposition(
    for vector: ControlPack.Vector, registryByFamily: [String: ProbeRegistry.Entry]
  ) -> String {
    guard vector.registryKnown, let entry = registryByFamily[vector.family] else {
      return "unsupported"
    }
    guard entry.status == "supported", vector.mutationName == false else {
      return "unsupported"
    }
    if vector.cancelled { return "cancelled" }
    if vector.timedOut { return "timedOut" }
    guard vector.preconditionValid, vector.authorityPresent else { return "unavailable" }
    if vector.deniedObservation == true { return "unknown" }
    guard vector.provenanceValid, vector.effectProven, vector.rawFamilyKnown,
      vector.identityMatches, vector.bindingMatches
    else {
      return "unknown"
    }
    return "observed"
  }

  private func mutatedRegistry(
    _ mutation: (inout [[String: Any]]) throws -> Void
  ) throws -> ProbeRegistry {
    let data = try Data(contentsOf: resourceURL("1.0.0/registry.yaml"))
    var object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [String: Any])
    var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
    try mutation(&entries)
    object["entries"] = entries
    let mutated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return try JSONDecoder().decode(ProbeRegistry.self, from: mutated)
  }

  func testPackContainsExactPinnedResourceSetAndHashes() throws {
    let manifest = try loadResourceManifest()
    XCTAssertEqual(manifest.schemaVersion, "1.0.0")
    XCTAssertEqual(manifest.packVersion, "1.0.0")
    XCTAssertEqual(manifest.registrySerializationFormat, "json-compatible-yaml-1.2")
    XCTAssertEqual(manifest.integrationProfile, "OPENHARMONY-TOOLS@0.3.0")
    XCTAssertEqual(Set(manifest.resources.map(\.id)).count, manifest.resources.count)
    XCTAssertEqual(Set(manifest.resources.map(\.path)).count, manifest.resources.count)

    let root = try probesRoot()
    let enumerator = try XCTUnwrap(
      FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
    var packagedFiles: Set<String> = []
    for case let url as URL in enumerator {
      guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
        continue
      }
      packagedFiles.insert(url.path.replacingOccurrences(of: root.path + "/", with: ""))
    }
    let expectedFiles = Set(manifest.resources.map(\.path)).union(["1.0.0/resources.json"])
    XCTAssertEqual(packagedFiles, expectedFiles)

    for resource in manifest.resources {
      let bytes = try Data(contentsOf: resourceURL(resource.path))
      XCTAssertEqual(bytes.count, resource.sizeBytes, resource.id)
      XCTAssertEqual(sha256Hex(bytes), resource.sha256, resource.id)
      XCTAssertFalse(resource.evidenceClass.isEmpty, resource.id)
    }
  }

  func testRegistryIsClosedCompleteAndMatchesResourceManifest() throws {
    let registry = try loadRegistry()
    try validate(registry)
    let manifest = try loadResourceManifest()

    XCTAssertEqual(registry.registryId, manifest.registryId)
    XCTAssertEqual(registry.registryVersion, manifest.registryVersion)
    XCTAssertEqual(registry.integrationProfile, manifest.integrationProfile)
    XCTAssertEqual(registry.registeredBy, manifest.registeredBy)
    XCTAssertEqual(manifest.entries.count, registry.entries.count)
    XCTAssertEqual(Set(manifest.entries.map(\.id)), Set(registry.entries.map(\.id)))

    let registryByID = Dictionary(uniqueKeysWithValues: registry.entries.map { ($0.id, $0) })
    let manifestByID = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.id, $0) })
    let resourcesByID = Dictionary(uniqueKeysWithValues: manifest.resources.map { ($0.id, $0) })
    for entry in registry.entries {
      let summary = try XCTUnwrap(manifestByID[entry.id])
      XCTAssertEqual(registryByID[summary.id]?.id, entry.id)
      XCTAssertEqual(entry.family, summary.family)
      XCTAssertEqual(entry.status, summary.status)
      XCTAssertEqual(entry.effectClassification, summary.effectClassification)
      XCTAssertEqual(entry.inputContract.receiptId, summary.receiptId)

      let receiptResource = try XCTUnwrap(resourcesByID[entry.inputContract.receiptId])
      XCTAssertEqual(receiptResource.path, entry.inputContract.receiptPath)
      XCTAssertEqual(receiptResource.sha256, entry.inputContract.receiptSHA256)
      let receiptData = try Data(contentsOf: resourceURL(receiptResource.path))
      let receipt = try JSONDecoder().decode(ReceiptHeader.self, from: receiptData)
      XCTAssertEqual(receipt.id, entry.inputContract.receiptId)
      XCTAssertEqual(receipt.family, entry.family)
      XCTAssertEqual(receipt.source.path, entry.provenance.sourcePath)
      XCTAssertEqual(receipt.source.sha256, entry.provenance.sourceSHA256)
      XCTAssertEqual(receipt.source.acceptedBy, entry.provenance.acceptedBy)
      if receipt.family == "keyAccessDiagnostics" {
        XCTAssertNil(receipt.dispatchCounters)
      } else {
        let counters = try XCTUnwrap(receipt.dispatchCounters)
        XCTAssertEqual(
          Set(counters.keys),
          [
            "serverStart", "serverStop", "serverRestart", "serverAdoption",
            "subserverLifecycle", "deviceMigration", "deviceMutation", "destructive",
          ])
        XCTAssertTrue(counters.values.allSatisfy { $0 == 0 })
      }
    }
  }

  func testSupportedEntriesHaveExactAuthorityAndExistingServerBoundaries() throws {
    let registry = try loadRegistry()
    let byFamily = Dictionary(uniqueKeysWithValues: registry.entries.map { ($0.family, $0) })

    let server = try XCTUnwrap(byFamily["serverIdentityGeneration"])
    XCTAssertEqual(server.status, "supported")
    XCTAssertEqual(server.probeKind, "platformProcessObservation")
    XCTAssertFalse(server.invocationAllowed)
    XCTAssertTrue(server.exactArgv.isEmpty)
    XCTAssertTrue(server.endpointPolicy.existingServerRequired)
    XCTAssertTrue(server.preconditions.contains("exactlyOneExistingServerProcess"))
    XCTAssertTrue(server.preconditions.contains("listenerOwnedByObservedProcess"))
    XCTAssertTrue(server.authorityLimit.neverEstablish.joined().contains("checkserver"))
    XCTAssertTrue(server.authorityLimit.neverEstablish.joined().contains("caller-provided"))

    let authorization = try XCTUnwrap(byFamily["selectedDeviceAuthorizationBinding"])
    XCTAssertEqual(authorization.status, "supported")
    XCTAssertEqual(authorization.exactArgv, ["list", "targets", "-v"])
    XCTAssertFalse(authorization.exactArgv.contains("-t"))
    XCTAssertTrue(authorization.endpointPolicy.existingServerRequired)
    XCTAssertTrue(authorization.preconditions.contains("validServerIdentityGenerationReceipt"))
    XCTAssertTrue(
      authorization.preconditions.contains("durableBindingIdentityAndRevisionProvided"))
    XCTAssertTrue(authorization.authorityLimit.neverEstablish.contains("channel protection"))
    XCTAssertTrue(
      authorization.authorityLimit.neverEstablish.contains("creation or revision of a binding"))
  }

  func testUnsupportedEntriesCannotDispatchOrCreateAuthority() throws {
    let registry = try loadRegistry()
    let byFamily = Dictionary(uniqueKeysWithValues: registry.entries.map { ($0.family, $0) })

    let key = try XCTUnwrap(byFamily["keyAccessDiagnostics"])
    XCTAssertEqual(key.status, "unsupported")
    XCTAssertFalse(key.invocationAllowed)
    XCTAssertTrue(key.exactArgv.isEmpty)
    XCTAssertTrue(key.authorityLimit.mayEstablish.isEmpty)
    XCTAssertTrue(key.forbiddenEffects.contains("privateKeyRead"))
    XCTAssertTrue(key.forbiddenEffects.contains("privateKeyHash"))
    XCTAssertTrue(key.forbiddenEffects.contains("rawKeyOrPathLogging"))
    XCTAssertTrue(key.unsupportedReason?.contains("configured or user-approved") == true)

    let subserver = try XCTUnwrap(byFamily["subserverCapability"])
    XCTAssertEqual(subserver.status, "unsupported")
    XCTAssertFalse(subserver.invocationAllowed)
    XCTAssertTrue(subserver.exactArgv.isEmpty)
    XCTAssertTrue(subserver.authorityLimit.mayEstablish.isEmpty)
    XCTAssertTrue(subserver.forbiddenEffects.contains("subserverLifecycle"))
    XCTAssertTrue(subserver.forbiddenEffects.contains("deviceMigration"))
    XCTAssertTrue(subserver.unsupportedReason?.contains("3.2.0d") == true)
  }

  func testPartialDuplicateAndUnknownRegistriesFailValidation() throws {
    let partial = try mutatedRegistry { $0.removeLast() }
    XCTAssertThrowsError(try validate(partial)) { error in
      XCTAssertEqual(error as? RegistryValidationError, .incompleteFamilySet)
    }

    let duplicate = try mutatedRegistry { entries in
      entries[entries.count - 1] = try XCTUnwrap(entries.first)
    }
    XCTAssertThrowsError(try validate(duplicate)) { error in
      XCTAssertEqual(error as? RegistryValidationError, .duplicateEntry)
    }

    let unknown = try mutatedRegistry { entries in
      entries[0]["family"] = "futureUnregisteredFamily"
    }
    XCTAssertThrowsError(try validate(unknown)) { error in
      XCTAssertEqual(error as? RegistryValidationError, .unknownFamily)
    }

    let unknownProbeKind = try mutatedRegistry { entries in
      entries[0]["probeKind"] = "arbitraryCommand"
    }
    XCTAssertThrowsError(try validate(unknownProbeKind)) { error in
      XCTAssertEqual(error as? RegistryValidationError, .unknownProbeKind)
    }
  }

  func testControlVectorsFailClosedWithZeroExternalDispatch() throws {
    let registry = try loadRegistry()
    let byFamily = Dictionary(uniqueKeysWithValues: registry.entries.map { ($0.family, $0) })
    let controls = try loadControlPack()
    XCTAssertEqual(controls.schemaVersion, "1.0.0")
    XCTAssertEqual(controls.evidenceClass, "fakeControlOnly")
    XCTAssertTrue(controls.boundary.contains("not production provenance"))
    XCTAssertEqual(Set(controls.vectors.map(\.id)).count, controls.vectors.count)
    let vectorsByID = Dictionary(uniqueKeysWithValues: controls.vectors.map { ($0.id, $0) })
    XCTAssertNil(vectorsByID["authorization-unknown-output"]?.deniedObservation)
    XCTAssertEqual(
      vectorsByID["authorization-denied-output-unregistered"]?.deniedObservation, true)

    for vector in controls.vectors {
      XCTAssertEqual(
        disposition(for: vector, registryByFamily: byFamily), vector.expectedDisposition,
        vector.id)
    }
    XCTAssertFalse(controls.expectedDispatchCounters.isEmpty)
    for (counter, value) in controls.expectedDispatchCounters {
      XCTAssertEqual(value, 0, counter)
    }

    let requiredVectors: Set<String> = [
      "server-absent",
      "server-executable-substitution",
      "server-caller-generation",
      "authorization-stale-binding",
      "authorization-unknown-output",
      "authorization-denied-output-unregistered",
      "authorization-timeout",
      "authorization-cancelled",
      "key-missing",
      "key-denied",
      "key-public-readable-private-denied",
      "key-missing-authority",
      "subserver-version-only",
      "subserver-spawn-name",
      "unknown-family",
    ]
    XCTAssertTrue(requiredVectors.isSubset(of: Set(controls.vectors.map(\.id))))
  }

  func testResourcesContainNoRawSensitiveMaterial() throws {
    let manifest = try loadResourceManifest()
    let forbiddenFragments = [
      "/Users/",
      "-----BEGIN PRIVATE KEY-----",
      "-----BEGIN OPENSSH PRIVATE KEY-----",
      "\"connectKey\"",
      "\"serial\"",
    ]
    for resource in manifest.resources {
      let data = try Data(contentsOf: resourceURL(resource.path))
      let text = try XCTUnwrap(String(data: data, encoding: .utf8), resource.id)
      for fragment in forbiddenFragments {
        XCTAssertFalse(text.contains(fragment), "\(resource.id) contains \(fragment)")
      }
    }
  }
}

// Runtime API v2 wire models (CHG-2026-046, T02).
//
// The runtime request carries exactly what device execution needs - target,
// operation, typed inputs, idempotency, optional capability - and
// structurally excludes repository governance identity. Where the v1 model
// made changeId/taskId mandatory, v2 rejects their very presence with a
// stable error code: an old caller keeps a loud, actionable failure instead
// of a silently ignored field. Repository provenance survives only as the
// optional build-source block of PublishedOperationBundleManifest.
//
// Versioning: major 2 is required (unknown majors fail closed); unknown
// top-level keys under major 2 are tolerated for forward compatibility,
// while duplicate JSON keys stay rejected.

import ArkDeckCore
import Foundation

public enum RuntimeOperationErrorCode: String, Codable, Sendable, CaseIterable {
  case invalidRequest
  case unknownOperation
  case invalidInput
  case targetNotFound
  case authorizationRequired
  case conflict
  case unsupportedProfile
  case unsupportedVersion
  case governanceFieldRejected
  case requestTooLarge
}

public struct RuntimeOperationRequestRejection: Error, Equatable, Sendable {
  public let code: RuntimeOperationErrorCode
  public let path: String
  public let message: String

  public init(code: RuntimeOperationErrorCode, path: String, message: String) {
    self.code = code
    self.path = path
    self.message = message
  }
}

public struct DurableTargetReference: Equatable, Sendable, Codable {
  public let targetID: String
  /// When present, execution must observe exactly this binding revision;
  /// any other current revision is a conflict, never a silent rebind.
  public let expectedBindingRevision: Int?

  enum CodingKeys: String, CodingKey {
    case targetID = "targetId"
    case expectedBindingRevision
  }

  public init(targetID: String, expectedBindingRevision: Int? = nil) {
    self.targetID = targetID
    self.expectedBindingRevision = expectedBindingRevision
  }

  func validate() throws {
    try RuntimeWireValidation.identifier(targetID, path: "$.target.targetId")
    if let revision = expectedBindingRevision, revision < 1 {
      throw RuntimeOperationRequestRejection(
        code: .invalidRequest,
        path: "$.target.expectedBindingRevision",
        message: "binding revision must be >= 1")
    }
  }
}

public struct RuntimeOperationReference: Equatable, Sendable, Codable {
  public let id: String
  public let version: Int?

  public init(id: String, version: Int? = nil) {
    self.id = id
    self.version = version
  }

  public var reference: String { version.map { "\(id)@\($0)" } ?? id }

  func validate() throws {
    guard
      !id.isEmpty, id.count <= 64,
      id.first.map({ $0.isLowercase && $0.isLetter }) == true,
      id.allSatisfy({ character in
        character.isASCII
          && (character.isLowercase || character.isNumber || character == "."
            || character == "-")
      })
    else {
      throw RuntimeOperationRequestRejection(
        code: .unknownOperation,
        path: "$.operation.id",
        message: "malformed operation id")
    }
    if let version, version < 1 {
        throw RuntimeOperationRequestRejection(
          code: .unknownOperation,
          path: "$.operation.version",
          message: "operation version must be >= 1")
    }
  }
}

public enum RuntimeRequestedOutput: String, Codable, Sendable, CaseIterable {
  case rawArtifacts
  case derivedArtifacts
  case analysisReport
  case hardwareEvidence
}

/// Historical wire field retained only so persisted requests can be decoded
/// and exported. Runtime rejects any new request that contains it.
public struct RuntimeCampaignReservationReference: Equatable, Sendable, Codable {
  public let reservationID: String

  enum CodingKeys: String, CodingKey {
    case reservationID = "reservationId"
  }

  init(reservationID: String) {
    self.reservationID = reservationID
  }

  func validate() throws {
    guard !reservationID.isEmpty, reservationID.count <= 128,
      reservationID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
    else {
      throw RuntimeOperationRequestRejection(
        code: .authorizationRequired,
        path: "$.campaignReservation.reservationId",
        message: "campaign reservation must name a ledger reservation identifier")
    }
  }
}

public struct RuntimeCapabilityReference: Equatable, Sendable, Codable {
  public let capabilityID: String

  enum CodingKeys: String, CodingKey {
    case capabilityID = "capabilityId"
  }

  public init(capabilityID: String) {
    self.capabilityID = capabilityID
  }

  func validate() throws {
    guard capabilityID.hasPrefix("CAP-RT-"), capabilityID.count > 7, capabilityID.count <= 128
    else {
      throw RuntimeOperationRequestRejection(
        code: .authorizationRequired,
        path: "$.authorization.capabilityId",
        message: "authorization must reference a runtime capability (CAP-RT-...)")
    }
  }
}

public struct RuntimeClientContext: Equatable, Sendable, Codable {
  /// Reserved provenance key naming the run-grouping thread a caller filed
  /// this request under, so History can show consecutive work on one device
  /// as one line instead of N unrelated rows.
  ///
  /// It lives in provenance precisely because provenance grants nothing: this
  /// is a display and audit label, and no admission decision, capability,
  /// materialized plan, storage layout or audit identity may read it. In
  /// particular it is NOT `RuntimeJobRecord.sessionID`, which is one Job's
  /// own durable storage identity and its session directory name.
  public static let threadProvenanceKey = "arkdeck.threadId"

  public let clientName: String?
  /// Display/audit annotations only. The runtime never derives authority,
  /// scope or identity from provenance entries.
  public let provenance: [String: String]?

  /// The run-grouping thread this request declared, when it declared one.
  public var threadID: String? { provenance?[Self.threadProvenanceKey] }

  public init(clientName: String? = nil, provenance: [String: String]? = nil) {
    self.clientName = clientName
    self.provenance = provenance
  }

  /// Files the request under a run-grouping thread. Any other provenance the
  /// caller supplies is preserved; a caller cannot smuggle a second thread in
  /// through `provenance` because the reserved key is written last.
  public init(
    clientName: String?,
    threadID: String,
    provenance: [String: String] = [:]
  ) {
    var entries = provenance
    entries[Self.threadProvenanceKey] = threadID
    self.clientName = clientName
    self.provenance = entries
  }

  func validate() throws {
    if let clientName, clientName.isEmpty || clientName.count > 128 {
      throw RuntimeOperationRequestRejection(
        code: .invalidRequest,
        path: "$.clientContext.clientName",
        message: "client name must be 1..128 characters")
    }
    if let provenance {
      guard provenance.count <= 16 else {
        throw RuntimeOperationRequestRejection(
          code: .invalidRequest,
          path: "$.clientContext.provenance",
          message: "at most 16 provenance entries")
      }
      for (key, value) in provenance {
        guard !key.isEmpty, key.count <= 64, value.count <= 400 else {
          throw RuntimeOperationRequestRejection(
            code: .invalidRequest,
            path: "$.clientContext.provenance.\(key)",
            message: "malformed provenance entry")
        }
      }
      // The thread label is free-form to the runtime but not unbounded: a
      // decoded request naming a malformed thread is refused here rather than
      // reaching History as an un-renderable grouping key.
      if let thread = provenance[Self.threadProvenanceKey] {
        guard
          thread.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#,
            options: .regularExpression
          ) == thread.startIndex..<thread.endIndex
        else {
          throw RuntimeOperationRequestRejection(
            code: .invalidRequest,
            path: "$.clientContext.provenance.\(Self.threadProvenanceKey)",
            message: "thread id must be 1..64 characters of [A-Za-z0-9._-]")
        }
      }
    }
  }
}

public struct RuntimeOperationRequest: Equatable, Sendable, Codable {
  public static let documentType = "runtime-operation-request"
  public static let schemaVersion = "2.0.0"
  public static let requiredMajorVersion = 2

  public let requestID: String
  public let idempotencyKey: String
  public let target: DurableTargetReference
  public let operation: RuntimeOperationReference
  public let inputs: [String: JSONValue]
  public let requestedOutputs: [RuntimeRequestedOutput]
  public let authorization: RuntimeCapabilityReference?
  /// Decode/export-only schema 2.x field. New callers cannot construct it
  /// through the typed initializer, and Runtime refuses decoded requests that
  /// carry it before default read-only or capability admission.
  public let campaignReservation: RuntimeCampaignReservationReference?
  public let clientContext: RuntimeClientContext?

  enum CodingKeys: String, CodingKey {
    case documentType
    case schemaVersion
    case requestID = "requestId"
    case idempotencyKey
    case target
    case operation
    case inputs
    case requestedOutputs
    case authorization
    case campaignReservation
    case clientContext
  }

  public init(
    requestID: String,
    idempotencyKey: String,
    target: DurableTargetReference,
    operation: RuntimeOperationReference,
    inputs: [String: JSONValue] = [:],
    requestedOutputs: [RuntimeRequestedOutput] = [.derivedArtifacts],
    authorization: RuntimeCapabilityReference? = nil,
    clientContext: RuntimeClientContext? = nil
  ) throws {
    self.requestID = requestID
    self.idempotencyKey = idempotencyKey
    self.target = target
    self.operation = operation
    self.inputs = inputs
    self.requestedOutputs = requestedOutputs
    self.authorization = authorization
    self.campaignReservation = nil
    self.clientContext = clientContext
    try validate()
  }

  /// The document an operator's flag-form submit builds
  /// (`arkdeck job submit --target … --operation …`).
  ///
  /// It exists because the CLI hand-wrote this JSON and left the binding
  /// revision out, which made the documented flag form unusable for every
  /// device-bound operation in the catalog: admission requires a pinned
  /// revision, so each attempt came back as a generic
  /// `evidenceIncomplete: target/binding/routing/tool facts are absent or
  /// mismatched` after a full round trip - measured on the 2026-07-31 GJ-5
  /// window, on the first leg. The rule is enforced here instead, before
  /// anything is submitted, and it names the missing flag.
  ///
  /// A host-only operation must *not* carry a revision: there is no binding to
  /// pin, and the engine refuses a host-only request that pins one
  /// (CHG-2026-054 HTP-AC-20).
  /// The envelope an operator or agent would otherwise hand-write.
  ///
  /// `inputs` is the parameter that makes this usable for more than the two
  /// operations that take none. Without it the flag form could express only
  /// target and operation, so anything with typed inputs — which is nearly
  /// everything — had to be submitted as a full v2 document, and the envelope
  /// around those inputs was the caller's problem to get right.
  public static func operatorFlagForm(
    targetID: String,
    expectedBindingRevision: Int?,
    operationID: String,
    version: Int?,
    inputs: [String: JSONValue] = [:],
    requestID: String,
    idempotencyKey: String
  ) throws -> RuntimeOperationRequest {
    let reference = RuntimeOperationReference(id: operationID, version: version).reference
    let descriptor = RuntimeOperationCatalog.descriptor(reference: reference)
    if descriptor?.binding == .confirmedDevice, expectedBindingRevision == nil {
      throw RuntimeOperationRequestRejection(
        code: .invalidRequest,
        path: "$.target.expectedBindingRevision",
        message:
          "\(reference) is device-bound: pass --expected-binding-revision <n> "
          + "(the revision `arkdeck device list` reports for this target)")
    }
    if descriptor?.binding == WorkflowBindingRequirement.none, expectedBindingRevision != nil {
      throw RuntimeOperationRequestRejection(
        code: .invalidRequest,
        path: "$.target.expectedBindingRevision",
        message: "\(reference) is host-only: it has no binding revision to pin")
    }
    return try RuntimeOperationRequest(
      requestID: requestID,
      idempotencyKey: idempotencyKey,
      target: DurableTargetReference(
        targetID: targetID, expectedBindingRevision: expectedBindingRevision),
      operation: RuntimeOperationReference(id: operationID, version: version),
      inputs: inputs)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let documentType = try container.decodeIfPresent(String.self, forKey: .documentType)
    if let documentType, documentType != Self.documentType {
      throw RuntimeOperationRequestRejection(
        code: .invalidRequest,
        path: "$.documentType",
        message: "expected \(Self.documentType)")
    }
    // A missing or wrong-typed required key used to escape as a Swift
    // `DecodingError`, which the codec reported at `path: "$"` with the
    // reflected description as its message. A caller reading `path` to learn
    // what to fix learned nothing, and one reading `message` got Swift's
    // internal spelling of the problem rather than a contract. Each required
    // key now answers for itself, at its own path.
    func required<Value: Decodable>(
      _ type: Value.Type, _ key: CodingKeys, path: String, shape: String
    ) throws -> Value {
      do {
        guard let value = try container.decodeIfPresent(type, forKey: key) else {
          throw RuntimeOperationRequestRejection(
            code: .invalidRequest, path: path, message: "\(path) is required (\(shape))")
        }
        return value
      } catch let rejection as RuntimeOperationRequestRejection {
        // A nested model that rejected its own content already named the
        // exact field; reporting it as this key's problem would be less
        // precise, not more.
        throw rejection
      } catch {
        throw RuntimeOperationRequestRejection(
          code: .invalidRequest, path: path, message: "\(path) is malformed (\(shape))")
      }
    }

    self.requestID = try required(
      String.self, .requestID, path: "$.requestId", shape: "an identifier string")
    self.idempotencyKey = try required(
      String.self, .idempotencyKey, path: "$.idempotencyKey",
      shape: "an identifier string of at least 8 characters")
    self.target = try required(
      DurableTargetReference.self, .target, path: "$.target",
      shape: "an object carrying targetId")
    self.operation = try required(
      RuntimeOperationReference.self, .operation, path: "$.operation",
      shape: "an object carrying id and an optional version")
    self.inputs =
      try container.decodeIfPresent([String: JSONValue].self, forKey: .inputs) ?? [:]
    self.requestedOutputs =
      try container.decodeIfPresent([RuntimeRequestedOutput].self, forKey: .requestedOutputs)
      ?? [.derivedArtifacts]
    self.authorization = try container.decodeIfPresent(
      RuntimeCapabilityReference.self, forKey: .authorization)
    self.campaignReservation = try container.decodeIfPresent(
      RuntimeCampaignReservationReference.self, forKey: .campaignReservation)
    self.clientContext = try container.decodeIfPresent(
      RuntimeClientContext.self, forKey: .clientContext)
    try validate()
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.documentType, forKey: .documentType)
    try container.encode(Self.schemaVersion, forKey: .schemaVersion)
    try container.encode(requestID, forKey: .requestID)
    try container.encode(idempotencyKey, forKey: .idempotencyKey)
    try container.encode(target, forKey: .target)
    try container.encode(operation, forKey: .operation)
    try container.encode(inputs, forKey: .inputs)
    try container.encode(requestedOutputs, forKey: .requestedOutputs)
    try container.encodeIfPresent(authorization, forKey: .authorization)
    try container.encodeIfPresent(campaignReservation, forKey: .campaignReservation)
    try container.encodeIfPresent(clientContext, forKey: .clientContext)
  }

  private func validate() throws {
    try RuntimeWireValidation.identifier(requestID, path: "$.requestId")
    guard idempotencyKey.count >= 8 else {
      throw RuntimeOperationRequestRejection(
        code: .invalidRequest,
        path: "$.idempotencyKey",
        message: "idempotency key must be at least 8 characters")
    }
    try RuntimeWireValidation.identifier(idempotencyKey, path: "$.idempotencyKey")
    try target.validate()
    try operation.validate()
    try authorization?.validate()
    try campaignReservation?.validate()
    if authorization != nil, campaignReservation != nil {
      throw RuntimeOperationRequestRejection(
        code: .authorizationRequired,
        path: "$.campaignReservation",
        message: "a request carries exactly one E2 authority kind, not both")
    }
    try clientContext?.validate()
    guard requestedOutputs.count <= 8,
      Set(requestedOutputs).count == requestedOutputs.count
    else {
      throw RuntimeOperationRequestRejection(
        code: .invalidRequest,
        path: "$.requestedOutputs",
        message: "requested outputs must be unique, at most 8")
    }
    guard inputs.count <= 64 else {
      throw RuntimeOperationRequestRejection(
        code: .invalidInput,
        path: "$.inputs",
        message: "at most 64 typed inputs")
    }
    for key in inputs.keys {
      guard !key.isEmpty, key.count <= 64,
        key.first.map({ $0.isLowercase && $0.isLetter }) == true,
        key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
      else {
        throw RuntimeOperationRequestRejection(
          code: .invalidInput,
          path: "$.inputs.\(key)",
          message: "input keys must be lowerCamelCase ASCII")
      }
      guard !RuntimeWireValidation.forbiddenInputKeys.contains(key.lowercased()) else {
        throw RuntimeOperationRequestRejection(
          code: .invalidInput,
          path: "$.inputs.\(key)",
          message: "input key would carry an executable surface")
      }
    }
  }
}

/// Optional repository provenance of a *published* operation bundle. This is
/// the only place where change/task identity may appear in the runtime
/// plane, every field is optional, and nothing in execution reads it.
package struct PublishedOperationBundleManifest: Equatable, Sendable, Codable {
  public static let documentType = "published-operation-bundle-manifest"
  public static let schemaVersion = "2.0.0"

  public let operation: RuntimeOperationReference
  public let catalogDigest: String
  package let sourceRevision: String?
  package let sourceChangeID: String?
  package let sourceTaskID: String?

  enum CodingKeys: String, CodingKey {
    case documentType
    case schemaVersion
    case operation
    case catalogDigest
    case sourceRevision
    case sourceChangeID = "sourceChangeId"
    case sourceTaskID = "sourceTaskId"
  }

  public init(
    operation: RuntimeOperationReference,
    catalogDigest: String,
    sourceRevision: String? = nil,
    sourceChangeID: String? = nil,
    sourceTaskID: String? = nil
  ) throws {
    self.operation = operation
    self.catalogDigest = catalogDigest
    self.sourceRevision = sourceRevision
    self.sourceChangeID = sourceChangeID
    self.sourceTaskID = sourceTaskID
    try validate()
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.operation = try container.decode(RuntimeOperationReference.self, forKey: .operation)
    self.catalogDigest = try container.decode(String.self, forKey: .catalogDigest)
    self.sourceRevision = try container.decodeIfPresent(String.self, forKey: .sourceRevision)
    self.sourceChangeID = try container.decodeIfPresent(String.self, forKey: .sourceChangeID)
    self.sourceTaskID = try container.decodeIfPresent(String.self, forKey: .sourceTaskID)
    try validate()
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.documentType, forKey: .documentType)
    try container.encode(Self.schemaVersion, forKey: .schemaVersion)
    try container.encode(operation, forKey: .operation)
    try container.encode(catalogDigest, forKey: .catalogDigest)
    try container.encodeIfPresent(sourceRevision, forKey: .sourceRevision)
    try container.encodeIfPresent(sourceChangeID, forKey: .sourceChangeID)
    try container.encodeIfPresent(sourceTaskID, forKey: .sourceTaskID)
  }

  private func validate() throws {
    try operation.validate()
    guard catalogDigest.count == 64,
      catalogDigest.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })
    else {
      throw RuntimeOperationRequestRejection(
        code: .invalidRequest,
        path: "$.catalogDigest",
        message: "catalog digest must be 64 lowercase hex characters")
    }
    for (value, path) in [
      (sourceRevision, "$.sourceRevision"),
      (sourceChangeID, "$.sourceChangeId"),
      (sourceTaskID, "$.sourceTaskId"),
    ] {
      if let value, value.isEmpty || value.count > 128 {
        throw RuntimeOperationRequestRejection(
          code: .invalidRequest, path: path, message: "provenance value must be 1..128 characters")
      }
    }
  }
}

enum RuntimeWireValidation {
  static let forbiddenInputKeys: Set<String> = [
    "argv", "shell", "exec", "command", "runhdc", "rawcommand", "executable",
  ]

  /// Governance keys whose very presence at the top level of a v2 request is
  /// rejected. Normalized: lowercased, underscores removed - so change_id,
  /// changeId and ChangeID are all the same forbidden key.
  static let forbiddenGovernanceKeys: Set<String> = [
    "changeid", "taskid", "approvalprnumber", "maincommitoid",
    "authorizationbloboid", "prnumber", "pullrequestnumber", "sourcetaskid",
    "sourcechangeid",
  ]

  static func identifier(_ value: String, path: String) throws {
    guard
      !value.isEmpty, value.count <= 128,
      value.first.map({ $0.isLetter || $0.isNumber }) == true,
      value.allSatisfy({ character in
        character.isASCII
          && (character.isLetter || character.isNumber || character == "."
            || character == "_" || character == "-")
      })
    else {
      throw RuntimeOperationRequestRejection(
        code: .invalidRequest,
        path: path,
        message: "identifier must be 1..128 ASCII [A-Za-z0-9._-] starting alphanumeric")
    }
  }

  static func normalizedKey(_ key: String) -> String {
    key.lowercased().replacingOccurrences(of: "_", with: "")
  }
}

package enum RuntimeOperationCodec {
  package static let maximumRequestBytes = 1 << 20

  package static func decodeRequest(_ data: Data) throws -> RuntimeOperationRequest {
    guard data.count <= maximumRequestBytes else {
      throw RuntimeOperationRequestRejection(
        code: .requestTooLarge,
        path: "$",
        message: "request exceeds \(maximumRequestBytes) bytes")
    }
    var validator = StrictJSONDuplicateValidator(data: data)
    do {
      try validator.validate()
    } catch {
      throw RuntimeOperationRequestRejection(
        code: .invalidRequest,
        path: "$",
        message: "malformed or duplicate-key JSON")
    }
    let topLevel: [String: JSONValue]
    do {
      topLevel = try JSONDecoder().decode([String: JSONValue].self, from: data)
    } catch {
      throw RuntimeOperationRequestRejection(
        code: .invalidRequest,
        path: "$",
        message: "request document must be a JSON object")
    }
    // Governance identity is rejected before anything else: an old caller
    // must learn the contract changed, not have its fields silently eaten.
    for key in topLevel.keys {
      if RuntimeWireValidation.forbiddenGovernanceKeys.contains(
        RuntimeWireValidation.normalizedKey(key))
      {
        throw RuntimeOperationRequestRejection(
          code: .governanceFieldRejected,
          path: "$.\(key)",
          message:
            "repository governance fields are not runtime fields; "
            + "use PublishedOperationBundleManifest for build provenance")
      }
    }
    guard case .string(let version)? = topLevel["schemaVersion"] else {
      // Naming the accepted value here is the whole point. Answering only
      // "required" sends the caller back to guess one, and the obvious guess
      // is "1.0.0", which then costs a second round trip to learn that major
      // 2 is the one. Interpolated rather than spelled so this cannot drift
      // from the value the gate below enforces.
      throw RuntimeOperationRequestRejection(
        code: .unsupportedVersion,
        path: "$.schemaVersion",
        message: "schemaVersion is required; this runtime accepts "
          + "\"\(RuntimeOperationRequest.schemaVersion)\"")
    }
    let majorText = version.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
    guard let major = Int(majorText) else {
      throw RuntimeOperationRequestRejection(
        code: .unsupportedVersion,
        path: "$.schemaVersion",
        message: "malformed schemaVersion \(version); this runtime accepts "
          + "\"\(RuntimeOperationRequest.schemaVersion)\"")
    }
    guard major == RuntimeOperationRequest.requiredMajorVersion else {
      throw RuntimeOperationRequestRejection(
        code: .unsupportedVersion,
        path: "$.schemaVersion",
        message: "unsupported major version \(major); this runtime accepts major "
          + "\(RuntimeOperationRequest.requiredMajorVersion), for example "
          + "\"\(RuntimeOperationRequest.schemaVersion)\"")
    }
    do {
      // JSONDecoder ignores unknown keys: minor-version additions stay
      // forward compatible under the major-2 gate above.
      return try JSONDecoder().decode(RuntimeOperationRequest.self, from: data)
    } catch let rejection as RuntimeOperationRequestRejection {
      throw rejection
    } catch {
      throw RuntimeOperationRequestRejection(
        code: .invalidRequest,
        path: "$",
        message: "undecodable v2 request: \(error)")
    }
  }

  package static func encodeRequest(_ request: RuntimeOperationRequest) throws -> Data {
    let encoder = CanonicalJSONEncoders.canonical()
    return try encoder.encode(request)
  }

  package static func decodeBundleManifest(_ data: Data) throws -> PublishedOperationBundleManifest {
    guard data.count <= maximumRequestBytes else {
      throw RuntimeOperationRequestRejection(
        code: .requestTooLarge, path: "$", message: "manifest exceeds size cap")
    }
    var validator = StrictJSONDuplicateValidator(data: data)
    do {
      try validator.validate()
    } catch {
      throw RuntimeOperationRequestRejection(
        code: .invalidRequest, path: "$", message: "malformed or duplicate-key JSON")
    }
    do {
      return try JSONDecoder().decode(PublishedOperationBundleManifest.self, from: data)
    } catch let rejection as RuntimeOperationRequestRejection {
      throw rejection
    } catch {
      throw RuntimeOperationRequestRejection(
        code: .invalidRequest, path: "$", message: "undecodable bundle manifest: \(error)")
    }
  }

  package static func encodeBundleManifest(
    _ manifest: PublishedOperationBundleManifest
  ) throws -> Data {
    let encoder = CanonicalJSONEncoders.canonical()
    return try encoder.encode(manifest)
  }
}

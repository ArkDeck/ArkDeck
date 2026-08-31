import Foundation

package struct AgentExecutionControlFailure: Error, Equatable, Sendable {
  package let code: String
  package let message: String
  package var details: [String: JSONValue]

  package init(_ code: String, _ message: String, details: [String: JSONValue] = [:]) {
    self.code = code
    self.message = message
    self.details = details
  }
}

/// Original caller intent. Resolved targets, fresh facts, HAR and Jobs never
/// enter this value, so discovery cannot change its idempotency identity.
package struct AgentExecutionIntent: Equatable, Sendable, Codable {
  package static let schemaVersion = "arkdeck.agent-execution-request/1"
  package let executionID: String
  package let operationReference: String
  package let inputs: [String: JSONValue]
  package let targetID: String?
  package let expectedBindingRevision: Int?
  package let capabilityReference: String?
  package let maximumWaitMilliseconds: Int
  package let reviewedPlanDigest: String?
  package let requestID: String?
  package let idempotencyKey: String?
  package let requestedOutputs: [String]?
  package let clientContext: JSONValue?

  package init(_ fields: [String: JSONValue]) throws {
    try self.init(fields, requirePublishedOperation: true)
  }

  private init(_ fields: [String: JSONValue], requirePublishedOperation: Bool) throws {
    func invalid(_ message: String) -> AgentExecutionControlFailure {
      AgentExecutionControlFailure("invalidInput", message)
    }
    guard Set(fields.keys).isSubset(of: [
      "schemaVersion", "executionId", "operation", "inputs", "target", "capabilityReference",
      "maximumWaitMilliseconds", "reviewedPlanDigest", "requestId", "idempotencyKey",
      "requestedOutputs", "clientContext",
    ]), fields["schemaVersion"] == .string(Self.schemaVersion),
      case .string(let id)? = fields["executionId"], Self.validIdentifier(id),
      case .string(let operation)? = fields["operation"], (1...128).contains(operation.utf8.count),
      case .object(let input)? = fields["inputs"],
      case .string(let budgetText)? = fields["maximumWaitMilliseconds"],
      let budget = Int(budgetText), String(budget) == budgetText, (1...86_400_000).contains(budget)
    else { throw invalid("an exact published operation, executionId, inputs and bounded orchestration budget are required") }
    let descriptor = RuntimeOperationCatalog.descriptor(reference: operation)
    if requirePublishedOperation {
      guard let descriptor, operation == descriptor.reference else {
        throw invalid("operation must be an exact token published by the current Catalog")
      }
    }
    executionID = id
    operationReference = operation
    inputs = input
    maximumWaitMilliseconds = budget
    func optionalIdentity(_ key: String) throws -> String? {
      guard let value = fields[key] else { return nil }
      guard case .string(let text) = value, Self.validIdentifier(text) else {
        throw invalid("\(key) must be a bounded identity")
      }
      return text
    }
    requestID = try optionalIdentity("requestId")
    idempotencyKey = try optionalIdentity("idempotencyKey")
    if let idempotencyKey, idempotencyKey.count < 8 { throw invalid("idempotencyKey must contain at least 8 characters") }
    if let value = fields["requestedOutputs"] {
      guard case .array(let values) = value, values.count <= 4 else {
        throw invalid("requestedOutputs must be a bounded typed list")
      }
      requestedOutputs = try values.map {
        guard case .string(let value) = $0,
          ["rawArtifacts", "derivedArtifacts", "analysisReport", "hardwareEvidence"].contains(value) else {
          throw invalid("requestedOutputs contains an unpublished value")
        }
        return value
      }
      guard Set(requestedOutputs ?? []).count == values.count else { throw invalid("requestedOutputs must be unique") }
    } else { requestedOutputs = nil }
    if let value = fields["clientContext"] {
      guard case .object(let context) = value, Set(context.keys).isSubset(of: ["clientName", "provenance"]) else {
        throw invalid("clientContext must contain only display/audit annotations")
      }
      if let name = context["clientName"] {
        guard case .string(let text) = name, (1...128).contains(text.count) else { throw invalid("invalid clientName") }
      }
      if let annotations = context["provenance"] {
        guard case .object(let pairs) = annotations, pairs.count <= 16,
          pairs.allSatisfy({ key, value in
            guard (1...64).contains(key.count), case .string(let text) = value else { return false }
            return text.count <= 400
          }) else { throw invalid("invalid provenance annotations") }
        if case .string(let thread)? = pairs["arkdeck.threadId"] {
          guard thread.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) == thread.startIndex..<thread.endIndex else {
            throw invalid("invalid thread provenance identity")
          }
        }
      }
      clientContext = value
    } else { clientContext = nil }
    if let target = fields["target"] {
      guard case .object(let object) = target,
        Set(object.keys).isSubset(of: ["targetId", "expectedBindingRevision"]),
        case .string(let targetID)? = object["targetId"], Self.validIdentifier(targetID)
      else { throw invalid("target must be an exact durable target reference") }
      self.targetID = targetID
      if let revision = object["expectedBindingRevision"] {
        guard case .integer(let value) = revision, value > 0, let parsed = Int(exactly: value),
          descriptor?.binding != .some(.none)
        else { throw invalid("expectedBindingRevision must be positive and device-bound") }
        expectedBindingRevision = parsed
      } else { expectedBindingRevision = nil }
    } else {
      targetID = nil
      expectedBindingRevision = nil
    }
    if let capability = fields["capabilityReference"] {
      guard case .string(let reference) = capability, Self.validIdentifier(reference) else {
        throw invalid("capability must be a reference, never an authority document")
      }
      capabilityReference = reference
    } else { capabilityReference = nil }
    if let digest = fields["reviewedPlanDigest"] {
      guard case .string(let value) = digest, value.utf8.count == 64,
        value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else { throw invalid("reviewedPlanDigest must be an exact lowercase SHA-256") }
      reviewedPlanDigest = value
    } else { reviewedPlanDigest = nil }
    let canonical: Data
    do { canonical = try PortableCanonicalJSON.canonicalBytes(.object(fields)) }
    catch { throw invalid("execution intent must be representable as canonical I-JSON") }
    guard canonical.count <= 3_145_728 else {
      throw AgentExecutionControlFailure("inputTooLarge", "execution intent exceeds its document bound")
    }
  }

  package static func validIdentifier(_ value: String) -> Bool {
    (1...128).contains(value.utf8.count)
      && value.utf8.first.map { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) } == true
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || [45, 46, 95].contains($0)
      }
  }

  package var fields: [String: JSONValue] {
    var fields: [String: JSONValue] = [
      "schemaVersion": .string(Self.schemaVersion), "executionId": .string(executionID),
      "operation": .string(operationReference), "inputs": .object(inputs),
      "maximumWaitMilliseconds": .string(String(maximumWaitMilliseconds)),
    ]
    if let targetID {
      var target: [String: JSONValue] = ["targetId": .string(targetID)]
      if let expectedBindingRevision { target["expectedBindingRevision"] = .integer(Int64(expectedBindingRevision)) }
      fields["target"] = .object(target)
    }
    if let capabilityReference { fields["capabilityReference"] = .string(capabilityReference) }
    if let reviewedPlanDigest { fields["reviewedPlanDigest"] = .string(reviewedPlanDigest) }
    if let requestID { fields["requestId"] = .string(requestID) }
    if let idempotencyKey { fields["idempotencyKey"] = .string(idempotencyKey) }
    if let requestedOutputs { fields["requestedOutputs"] = .array(requestedOutputs.map(JSONValue.string)) }
    if let clientContext { fields["clientContext"] = clientContext }
    return fields
  }

  /// Only this new execution fingerprint uses JCS. Catalog, plan, capability
  /// and Artifact digests retain their own accepted canonicalization.
  package var canonicalIntent: Data {
    get throws {
      var intent = fields
      intent.removeValue(forKey: "executionId")
      intent.removeValue(forKey: "reviewedPlanDigest")
      return try PortableCanonicalJSON.canonicalBytes(.object(intent))
    }
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    // Historical executions remain readable after a Catalog upgrade. The
    // owner separately requires the pinned Catalog before any new progress.
    try self.init(container.decode([String: JSONValue].self), requirePublishedOperation: false)
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(fields)
  }
}

package enum AgentExecutionState: String, Codable, Sendable {
  case orchestrating, waitingForHuman, creatingJob, jobOwned
  case completed, failed, abandoned, budgetExpired, clockUntrusted

  package var isTerminal: Bool {
    switch self {
    case .completed, .failed, .abandoned, .budgetExpired, .clockUntrusted: true
    default: false
    }
  }
}

package enum AgentPhysicalActionKind: String, Codable, Sendable {
  case connectDevice, trustDevice, selectDevice

  package var category: String {
    switch self {
    case .connectDevice: "physicalConnection"
    case .trustDevice: "deviceTrustPrompt"
    case .selectDevice: "ambiguousIdentity"
    }
  }

  package var reasonCode: String {
    switch self {
    case .connectDevice: "device.notObserved"
    case .trustDevice: "device.trustPending"
    case .selectDevice: "device.identityAmbiguous"
    }
  }

  package var minimumAction: String {
    switch self {
    case .connectDevice: "human.connectOrPowerDevice"
    case .trustDevice: "human.acceptDeviceTrustPrompt"
    case .selectDevice: "human.confirmDeviceIdentity"
    }
  }
}

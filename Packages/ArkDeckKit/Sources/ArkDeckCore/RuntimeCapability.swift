// Runtime Capability model (CHG-2026-046, T03).
//
// Replaces per-task (changeId/taskId) authorization for the Device Agent
// Runtime Plane. A capability is a durable, revocable, scope/expiry/use
// bounded credential:
//   E0 needs no capability (default read-only policy, still bounded);
//   E1 needs a standing capability (deviceMutation ceiling);
//   E2 needs a one-shot capability pinned to an exact plan digest.
// Every check in this file fails closed: an uncertain or missing condition
// is a denial, never a pass. Issuance authority is unchanged from the
// existing trust root - the only carrier for creating/modifying/revoking a
// destructive-ceiling capability is a maintainer-merged PR.

public enum RuntimeCapabilityValidationError: Error, Equatable, Sendable {
  case malformedCapabilityID(String)
  case unsupportedEffectCeiling(WorkflowEffect)
  case emptyOperationScope
  case malformedOperationReference(String)
  case malformedStableIdentity(String)
  case destructiveRequiresStableIdentityTarget
  case destructiveRequiresExactPlanDigest
  case destructiveRequiresSingleUse
  case exactPlanDigestOnlyForDestructive
  case malformedPlanDigest(String)
  case malformedTimestamp(String)
  case expiryNotAfterIssue
  case invalidMaximumUses(Int)
  case malformedIssuerReference(String)
  case forbiddenInputConstraintKey(String)
  case emptyInputConstraint(String)
}

public enum RuntimeCapabilityDenialReason: String, Codable, Equatable, Sendable {
  case revoked
  case expired
  case notYetValid
  case exhausted
  case targetScopeMismatch
  case operationScopeMismatch
  case effectAboveCeiling
  case planDigestRequired
  case planDigestMismatch
  case inputConstraintViolated
  case targetIdentityRequired
}

public struct RuntimeCapabilityDenial: Error, Equatable, Sendable {
  public let reason: RuntimeCapabilityDenialReason
  public let detail: String

  public init(reason: RuntimeCapabilityDenialReason, detail: String) {
    self.reason = reason
    self.detail = detail
  }
}

public enum RuntimeCapabilityTargetScope: Equatable, Sendable, Codable {
  /// Any bound target. Never legal for a destructive ceiling.
  case anyTarget
  /// Exactly one physical device, addressed by its stable physical
  /// identity digest (see `DeviceIdentitySnapshot.stablePhysicalIdentitySha256`).
  case stablePhysicalIdentity(sha256: String)

  enum CodingKeys: String, CodingKey {
    case kind
    case sha256
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)
    switch kind {
    case "anyTarget":
      self = .anyTarget
    case "stablePhysicalIdentity":
      self = .stablePhysicalIdentity(sha256: try container.decode(String.self, forKey: .sha256))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: container, debugDescription: "unknown target scope kind \(kind)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .anyTarget:
      try container.encode("anyTarget", forKey: .kind)
    case .stablePhysicalIdentity(let sha256):
      try container.encode("stablePhysicalIdentity", forKey: .kind)
      try container.encode(sha256, forKey: .sha256)
    }
  }
}

public struct RuntimeCapabilityOperationScope: Equatable, Sendable, Codable {
  /// Exact catalog operation id, e.g. "debug.hap".
  public let operationID: String
  /// Exact catalog operation version. Ranges are deliberately not
  /// expressible: a new operation version is a new authorization decision.
  public let version: Int

  public init(operationID: String, version: Int) {
    self.operationID = operationID
    self.version = version
  }

  public var reference: String { "\(operationID)@\(version)" }
}

/// Closed input-constraint vocabulary. A constraint narrows what a request
/// may pass for one typed input; it can never widen the catalog's own
/// input schema.
public enum RuntimeCapabilityInputConstraint: Equatable, Sendable, Codable {
  case exactString(String)
  case oneOfStrings([String])
  case integerRange(minimum: Int, maximum: Int)

  enum CodingKeys: String, CodingKey {
    case kind
    case value
    case values
    case minimum
    case maximum
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)
    switch kind {
    case "exactString":
      self = .exactString(try container.decode(String.self, forKey: .value))
    case "oneOfStrings":
      self = .oneOfStrings(try container.decode([String].self, forKey: .values))
    case "integerRange":
      self = .integerRange(
        minimum: try container.decode(Int.self, forKey: .minimum),
        maximum: try container.decode(Int.self, forKey: .maximum))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: container, debugDescription: "unknown constraint kind \(kind)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .exactString(let value):
      try container.encode("exactString", forKey: .kind)
      try container.encode(value, forKey: .value)
    case .oneOfStrings(let values):
      try container.encode("oneOfStrings", forKey: .kind)
      try container.encode(values, forKey: .values)
    case .integerRange(let minimum, let maximum):
      try container.encode("integerRange", forKey: .kind)
      try container.encode(minimum, forKey: .minimum)
      try container.encode(maximum, forKey: .maximum)
    }
  }

  func permits(_ value: JSONValue) -> Bool {
    switch (self, value) {
    case (.exactString(let expected), .string(let actual)):
      return expected == actual
    case (.oneOfStrings(let allowed), .string(let actual)):
      return allowed.contains(actual)
    case (.integerRange, _):
      guard let integer = Self.integerValue(of: value) else { return false }
      guard case .integerRange(let minimum, let maximum) = self else { return false }
      return integer >= minimum && integer <= maximum
    default:
      return false
    }
  }

  private static func integerValue(of value: JSONValue) -> Int? {
    switch value {
    case .integer(let raw):
      return Int(exactly: raw)
    case .unsignedInteger(let raw):
      return Int(exactly: raw)
    case .number(let raw):
      guard raw.truncatingRemainder(dividingBy: 1) == 0 else { return nil }
      return Int(exactly: raw)
    default:
      return nil
    }
  }
}

public struct RuntimeCapabilityIssuer: Equatable, Sendable, Codable {
  public enum Kind: String, Codable, Sendable {
    /// The only kind: the capability document was accepted through a
    /// maintainer-merged PR (git history is the audit ledger).
    case maintainerMergedPR
  }

  public let kind: Kind
  /// Human-auditable provenance, e.g. "PR#802 2f0c53e2...". Free-form but
  /// mandatory and non-empty.
  public let reference: String

  public init(kind: Kind, reference: String) {
    self.kind = kind
    self.reference = reference
  }
}

public enum RuntimeCapabilityRevocation: Equatable, Sendable, Codable {
  case active
  case revoked(atUTC: String, reason: String)

  enum CodingKeys: String, CodingKey {
    case state
    case atUTC
    case reason
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let state = try container.decode(String.self, forKey: .state)
    switch state {
    case "active":
      self = .active
    case "revoked":
      self = .revoked(
        atUTC: try container.decode(String.self, forKey: .atUTC),
        reason: try container.decode(String.self, forKey: .reason))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .state, in: container, debugDescription: "unknown revocation state \(state)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .active:
      try container.encode("active", forKey: .state)
    case .revoked(let atUTC, let reason):
      try container.encode("revoked", forKey: .state)
      try container.encode(atUTC, forKey: .atUTC)
      try container.encode(reason, forKey: .reason)
    }
  }
}

/// One authorization question posed to a capability: may `operation` run at
/// `effect` against `target` with `inputs` (and, for E2, exactly `planDigest`)?
public struct RuntimeCapabilityAuthorizationQuery: Sendable {
  public let operationID: String
  public let operationVersion: Int
  public let effect: WorkflowEffect
  public let targetStableIdentitySHA256: String?
  public let targetBindingRevision: Int?
  public let planDigest: String?
  public let inputs: [String: JSONValue]

  public init(
    operationID: String,
    operationVersion: Int,
    effect: WorkflowEffect,
    targetStableIdentitySHA256: String?,
    targetBindingRevision: Int?,
    planDigest: String?,
    inputs: [String: JSONValue]
  ) {
    self.operationID = operationID
    self.operationVersion = operationVersion
    self.effect = effect
    self.targetStableIdentitySHA256 = targetStableIdentitySHA256
    self.targetBindingRevision = targetBindingRevision
    self.planDigest = planDigest
    self.inputs = inputs
  }
}

public struct RuntimeCapability: Equatable, Sendable, Codable {
  public let capabilityID: String
  public let targetScope: RuntimeCapabilityTargetScope
  public let operationScope: [RuntimeCapabilityOperationScope]
  public let effectCeiling: WorkflowEffect
  public let inputConstraints: [String: RuntimeCapabilityInputConstraint]
  public let issuedAtUTC: String
  public let expiresAtUTC: String
  public let maximumUses: Int
  public let issuer: RuntimeCapabilityIssuer
  public let exactPlanDigest: String?
  public let revocation: RuntimeCapabilityRevocation

  public init(
    capabilityID: String,
    targetScope: RuntimeCapabilityTargetScope,
    operationScope: [RuntimeCapabilityOperationScope],
    effectCeiling: WorkflowEffect,
    inputConstraints: [String: RuntimeCapabilityInputConstraint] = [:],
    issuedAtUTC: String,
    expiresAtUTC: String,
    maximumUses: Int,
    issuer: RuntimeCapabilityIssuer,
    exactPlanDigest: String? = nil,
    revocation: RuntimeCapabilityRevocation = .active
  ) throws {
    self.capabilityID = capabilityID
    self.targetScope = targetScope
    self.operationScope = operationScope
    self.effectCeiling = effectCeiling
    self.inputConstraints = inputConstraints
    self.issuedAtUTC = issuedAtUTC
    self.expiresAtUTC = expiresAtUTC
    self.maximumUses = maximumUses
    self.issuer = issuer
    self.exactPlanDigest = exactPlanDigest
    self.revocation = revocation
    try validate()
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.capabilityID = try container.decode(String.self, forKey: .capabilityID)
    self.targetScope = try container.decode(RuntimeCapabilityTargetScope.self, forKey: .targetScope)
    self.operationScope = try container.decode(
      [RuntimeCapabilityOperationScope].self, forKey: .operationScope)
    self.effectCeiling = try container.decode(WorkflowEffect.self, forKey: .effectCeiling)
    self.inputConstraints = try container.decode(
      [String: RuntimeCapabilityInputConstraint].self, forKey: .inputConstraints)
    self.issuedAtUTC = try container.decode(String.self, forKey: .issuedAtUTC)
    self.expiresAtUTC = try container.decode(String.self, forKey: .expiresAtUTC)
    self.maximumUses = try container.decode(Int.self, forKey: .maximumUses)
    self.issuer = try container.decode(RuntimeCapabilityIssuer.self, forKey: .issuer)
    self.exactPlanDigest = try container.decodeIfPresent(String.self, forKey: .exactPlanDigest)
    self.revocation = try container.decode(RuntimeCapabilityRevocation.self, forKey: .revocation)
    do {
      try validate()
    } catch {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "capability violates model invariants: \(error)"))
    }
  }

  private static let capabilityIDPattern = "CAP-RT-"
  private static let sha256Length = 64

  private static func isFixedFormatUTC(_ value: String) -> Bool {
    // Exactly "YYYY-MM-DDTHH:MM:SSZ". Fixed width makes lexicographic
    // comparison chronologically sound, which is all the model needs.
    guard value.count == 20, value.hasSuffix("Z") else { return false }
    let characters = Array(value)
    for (index, character) in characters.enumerated() {
      switch index {
      case 4, 7: if character != "-" { return false }
      case 10: if character != "T" { return false }
      case 13, 16: if character != ":" { return false }
      case 19: if character != "Z" { return false }
      default: if !character.isASCII || !character.isNumber { return false }
      }
    }
    return true
  }

  private static func isHexDigest(_ value: String) -> Bool {
    value.count == sha256Length
      && value.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
  }

  private func validate() throws {
    guard
      capabilityID.hasPrefix(Self.capabilityIDPattern),
      capabilityID.count > Self.capabilityIDPattern.count,
      capabilityID.dropFirst(Self.capabilityIDPattern.count).allSatisfy({
        $0.isASCII && ($0.isNumber || ($0.isUppercase && $0.isLetter) || $0 == "-")
      })
    else {
      throw RuntimeCapabilityValidationError.malformedCapabilityID(capabilityID)
    }
    guard effectCeiling == .deviceMutation || effectCeiling == .destructive else {
      // E0 runs under the default read-only policy; a capability below
      // deviceMutation would only blur that line.
      throw RuntimeCapabilityValidationError.unsupportedEffectCeiling(effectCeiling)
    }
    guard !operationScope.isEmpty else {
      throw RuntimeCapabilityValidationError.emptyOperationScope
    }
    for scope in operationScope {
      guard
        !scope.operationID.isEmpty, scope.version >= 1,
        scope.operationID.allSatisfy({
          $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "." || $0 == "-")
        })
      else {
        throw RuntimeCapabilityValidationError.malformedOperationReference(scope.reference)
      }
    }
    if case .stablePhysicalIdentity(let sha256) = targetScope,
      !Self.isHexDigest(sha256)
    {
      throw RuntimeCapabilityValidationError.malformedStableIdentity(sha256)
    }
    if effectCeiling == .destructive {
      guard case .stablePhysicalIdentity = targetScope else {
        throw RuntimeCapabilityValidationError.destructiveRequiresStableIdentityTarget
      }
      guard exactPlanDigest != nil else {
        throw RuntimeCapabilityValidationError.destructiveRequiresExactPlanDigest
      }
      guard maximumUses == 1 else {
        throw RuntimeCapabilityValidationError.destructiveRequiresSingleUse
      }
    } else if exactPlanDigest != nil {
      throw RuntimeCapabilityValidationError.exactPlanDigestOnlyForDestructive
    }
    if let digest = exactPlanDigest, !Self.isHexDigest(digest) {
      throw RuntimeCapabilityValidationError.malformedPlanDigest(digest)
    }
    guard Self.isFixedFormatUTC(issuedAtUTC) else {
      throw RuntimeCapabilityValidationError.malformedTimestamp(issuedAtUTC)
    }
    guard Self.isFixedFormatUTC(expiresAtUTC) else {
      throw RuntimeCapabilityValidationError.malformedTimestamp(expiresAtUTC)
    }
    guard expiresAtUTC > issuedAtUTC else {
      throw RuntimeCapabilityValidationError.expiryNotAfterIssue
    }
    guard (1...10_000).contains(maximumUses) else {
      throw RuntimeCapabilityValidationError.invalidMaximumUses(maximumUses)
    }
    guard !issuer.reference.isEmpty, issuer.reference.count <= 200 else {
      throw RuntimeCapabilityValidationError.malformedIssuerReference(issuer.reference)
    }
    for (key, constraint) in inputConstraints {
      guard !key.isEmpty, key.first!.isLowercase, key.allSatisfy({ $0.isASCII && $0.isAlphanumeric })
      else {
        throw RuntimeCapabilityValidationError.forbiddenInputConstraintKey(key)
      }
      if case .oneOfStrings(let values) = constraint, values.isEmpty {
        throw RuntimeCapabilityValidationError.emptyInputConstraint(key)
      }
      if case .integerRange(let minimum, let maximum) = constraint, minimum > maximum {
        throw RuntimeCapabilityValidationError.emptyInputConstraint(key)
      }
    }
  }

  /// Pure authorization check. `remainingUses` and `nowUTC` come from the
  /// durable store; the model never consults a wall clock itself.
  public func authorizes(
    _ query: RuntimeCapabilityAuthorizationQuery,
    nowUTC: String,
    remainingUses: Int
  ) -> Result<Void, RuntimeCapabilityDenial> {
    if case .revoked(let atUTC, let reason) = revocation {
      return .failure(
        .init(reason: .revoked, detail: "revoked at \(atUTC): \(reason)"))
    }
    guard Self.isFixedFormatUTC(nowUTC) else {
      return .failure(.init(reason: .expired, detail: "unverifiable clock value \(nowUTC)"))
    }
    if nowUTC < issuedAtUTC {
      return .failure(.init(reason: .notYetValid, detail: "issued at \(issuedAtUTC)"))
    }
    if nowUTC >= expiresAtUTC {
      return .failure(.init(reason: .expired, detail: "expired at \(expiresAtUTC)"))
    }
    guard remainingUses > 0 else {
      return .failure(.init(reason: .exhausted, detail: "maximumUses \(maximumUses) consumed"))
    }
    guard query.effect <= effectCeiling else {
      return .failure(
        .init(
          reason: .effectAboveCeiling,
          detail: "requested \(query.effect.rawValue) above ceiling \(effectCeiling.rawValue)"))
    }
    let scopeMatch = operationScope.contains {
      $0.operationID == query.operationID && $0.version == query.operationVersion
    }
    guard scopeMatch else {
      return .failure(
        .init(
          reason: .operationScopeMismatch,
          detail: "\(query.operationID)@\(query.operationVersion) not in scope"))
    }
    switch targetScope {
    case .anyTarget:
      break
    case .stablePhysicalIdentity(let expected):
      guard let actual = query.targetStableIdentitySHA256 else {
        return .failure(
          .init(reason: .targetIdentityRequired, detail: "query carries no stable identity"))
      }
      guard actual == expected else {
        return .failure(
          .init(reason: .targetScopeMismatch, detail: "stable identity does not match scope"))
      }
    }
    if effectCeiling == .destructive {
      guard let expected = exactPlanDigest else {
        return .failure(.init(reason: .planDigestRequired, detail: "capability carries no plan digest"))
      }
      guard let actual = query.planDigest else {
        return .failure(.init(reason: .planDigestRequired, detail: "query carries no plan digest"))
      }
      guard actual == expected else {
        return .failure(.init(reason: .planDigestMismatch, detail: "plan digest differs"))
      }
    }
    for (key, constraint) in inputConstraints {
      guard let value = query.inputs[key] else {
        return .failure(
          .init(reason: .inputConstraintViolated, detail: "constrained input \(key) is absent"))
      }
      guard constraint.permits(value) else {
        return .failure(
          .init(reason: .inputConstraintViolated, detail: "input \(key) violates constraint"))
      }
    }
    return .success(())
  }
}

extension Character {
  fileprivate var isAlphanumeric: Bool { isLetter || isNumber }
}

/// The bounded default policy that admits E0 work without any capability.
/// It can only ever say yes to read-only effects inside fixed budgets.
public struct RuntimeDefaultReadOnlyPolicy: Sendable {
  public let maximumTimeoutSeconds: Int
  public let maximumOutputByteBudget: Int

  public init(maximumTimeoutSeconds: Int = 900, maximumOutputByteBudget: Int = 1 << 29) {
    self.maximumTimeoutSeconds = maximumTimeoutSeconds
    self.maximumOutputByteBudget = maximumOutputByteBudget
  }

  public enum Decision: Equatable, Sendable {
    case allowed
    case deniedEffectRequiresCapability(WorkflowEffect)
    case deniedTimeoutAboveLimit(requested: Int, limit: Int)
    case deniedBudgetAboveLimit(requested: Int, limit: Int)
  }

  public func evaluate(
    effect: WorkflowEffect,
    timeoutSeconds: Int,
    outputByteBudget: Int
  ) -> Decision {
    guard effect <= .readOnly else {
      return .deniedEffectRequiresCapability(effect)
    }
    guard timeoutSeconds <= maximumTimeoutSeconds else {
      return .deniedTimeoutAboveLimit(requested: timeoutSeconds, limit: maximumTimeoutSeconds)
    }
    guard outputByteBudget <= maximumOutputByteBudget else {
      return .deniedBudgetAboveLimit(requested: outputByteBudget, limit: maximumOutputByteBudget)
    }
    return .allowed
  }
}

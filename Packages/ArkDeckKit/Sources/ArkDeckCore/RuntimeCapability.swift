// Runtime Capability model (CHG-2026-046, T03).
//
// Replaces per-task (changeId/taskId) authorization for the Device Agent
// Runtime Plane. A capability is a durable, revocable, scope/expiry/use
// bounded credential:
//   read-only needs no capability (default read-only policy, still bounded);
//   mutation/destructive execution uses a Runtime-owned capability;
//   destructive capabilities are single-use and pin an exact plan digest.
// Every check in this file fails closed: an uncertain or missing condition
// is a denial, never a pass. Published Catalog policy may issue mutation or
// destructive capabilities automatically after complete plan materialization.
// Callers can neither create nor install the capability consumed by the
// protected Runtime.

public enum RuntimeCapabilityValidationError: Error, Equatable, Sendable {
  case malformedCapabilityID(String)
  case unsupportedEffectCeiling(WorkflowEffect)
  case emptyOperationScope
  case malformedOperationReference(String)
  case malformedStableIdentity(String)
  case destructiveRequiresStableIdentityTarget
  case destructiveRequiresExactPlanDigest
  case destructiveRequiresSingleUse
  case destructiveRequiresMaintainerIssuer
  case runtimePolicyRequiresExactInputs
  case runtimePolicyRequiresExactArtifactFacts
  case exactPlanDigestOnlyForDestructive
  case malformedPlanDigest(String)
  case malformedBindingRevision(Int)
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
  /// Exactly one workspace, at exactly one revision, for exactly one set of
  /// writable scopes (CHG-2026-055, TASK-HFA-009 r2). All three belong to the
  /// identity: an authorization to change *this tree as it stands* must not
  /// survive the tree moving, and must not silently widen to files the grant
  /// never named.
  case workspaceIdentity(
    sha256: String, expectedWorkspaceRevision: String, allowedFileScopesDigest: String)

  enum CodingKeys: String, CodingKey {
    case kind
    case sha256
    case expectedWorkspaceRevision
    case allowedFileScopesDigest
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)
    switch kind {
    case "anyTarget":
      self = .anyTarget
    case "stablePhysicalIdentity":
      self = .stablePhysicalIdentity(sha256: try container.decode(String.self, forKey: .sha256))
    case "workspaceIdentity":
      self = .workspaceIdentity(
        sha256: try container.decode(String.self, forKey: .sha256),
        expectedWorkspaceRevision: try container.decode(
          String.self, forKey: .expectedWorkspaceRevision),
        allowedFileScopesDigest: try container.decode(
          String.self, forKey: .allowedFileScopesDigest))
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
    case .workspaceIdentity(let sha256, let revision, let scopes):
      try container.encode("workspaceIdentity", forKey: .kind)
      try container.encode(sha256, forKey: .sha256)
      try container.encode(revision, forKey: .expectedWorkspaceRevision)
      try container.encode(scopes, forKey: .allowedFileScopesDigest)
    }
  }
}

public struct RuntimeCapabilityOperationScope: Equatable, Sendable, Codable {
  /// Exact catalog operation id, e.g. "debug.hap".
  public let operationID: String
  /// Exact catalog operation version when the operation publishes one.
  /// Ranges are deliberately not expressible.
  public let version: Int?

  public init(operationID: String, version: Int? = nil) {
    self.operationID = operationID
    self.version = version
  }

  public var reference: String { version.map { "\(operationID)@\($0)" } ?? operationID }
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

  public func permits(_ value: JSONValue) -> Bool {
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
    /// Historical externally supplied capability. It remains decodable, but
    /// new Runtime-owned admission rejects it.
    case maintainerMergedPR
    /// A capability deterministically issued by the production runtime from a
    /// published Catalog policy after target and plan materialization.
    case runtimeDefaultPolicy
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
/// `effect` against `target` with `inputs` and any exact materialization
/// pins carried by the capability?
public struct RuntimeCapabilityAuthorizationQuery: Sendable {
  public let operationID: String
  public let operationVersion: Int?
  public let effect: WorkflowEffect
  public let targetStableIdentitySHA256: String?
  public let targetBindingRevision: Int?
  public let planDigest: String?
  public let inputs: [String: JSONValue]
  /// Runtime-resolved Artifact IDs and content digests. Caller lease strings
  /// alone are not trusted enough for a destructive envelope.
  public let artifactFacts: [String: String]
  /// Workspace facts, present only for a host-bound workspace plan. A device
  /// query leaves them absent, so a workspace-scoped capability fails closed
  /// against it instead of matching by omission.
  public let workspaceIdentitySHA256: String?
  public let workspaceRevision: String?
  public let workspaceFileScopesDigest: String?
  /// Whether that workspace is a task-owned isolated copy. It decides who may
  /// authorize a change to it, not what the change may be: the scope, the
  /// revision and the exact inputs are pinned identically either way.
  public let workspaceIsIsolatedTaskCopy: Bool

  public init(
    operationID: String,
    operationVersion: Int? = nil,
    effect: WorkflowEffect,
    targetStableIdentitySHA256: String?,
    targetBindingRevision: Int?,
    planDigest: String?,
    inputs: [String: JSONValue],
    artifactFacts: [String: String] = [:],
    workspaceIdentitySHA256: String? = nil,
    workspaceRevision: String? = nil,
    workspaceFileScopesDigest: String? = nil,
    workspaceIsIsolatedTaskCopy: Bool = false
  ) {
    self.operationID = operationID
    self.operationVersion = operationVersion
    self.effect = effect
    self.targetStableIdentitySHA256 = targetStableIdentitySHA256
    self.targetBindingRevision = targetBindingRevision
    self.planDigest = planDigest
    self.inputs = inputs
    self.artifactFacts = artifactFacts
    self.workspaceIdentitySHA256 = workspaceIdentitySHA256
    self.workspaceRevision = workspaceRevision
    self.workspaceFileScopesDigest = workspaceFileScopesDigest
    self.workspaceIsIsolatedTaskCopy = workspaceIsIsolatedTaskCopy
  }

  public var operationReference: String {
    operationVersion.map { "\(operationID)@\($0)" } ?? operationID
  }
}

public struct RuntimeCapability: Equatable, Sendable, Codable {
  public let capabilityID: String
  public let targetScope: RuntimeCapabilityTargetScope
  public let operationScope: [RuntimeCapabilityOperationScope]
  public let effectCeiling: WorkflowEffect
  public let inputConstraints: [String: RuntimeCapabilityInputConstraint]
  /// Exact typed-input map for a runtime-issued E1 envelope. This also binds
  /// optional-field absence, which per-field constraints cannot express.
  public let exactInputs: [String: JSONValue]?
  /// Exact Runtime-resolved Artifact identity/content pins. Optional for
  /// historical and non-artifact capabilities; required for a newly issued
  /// destructive Runtime policy capability.
  public let exactArtifactFacts: [String: String]?
  public let issuedAtUTC: String
  public let expiresAtUTC: String
  public let maximumUses: Int
  public let issuer: RuntimeCapabilityIssuer
  public let exactPlanDigest: String?
  public let exactBindingRevision: Int?
  public let revocation: RuntimeCapabilityRevocation

  public init(
    capabilityID: String,
    targetScope: RuntimeCapabilityTargetScope,
    operationScope: [RuntimeCapabilityOperationScope],
    effectCeiling: WorkflowEffect,
    inputConstraints: [String: RuntimeCapabilityInputConstraint] = [:],
    exactInputs: [String: JSONValue]? = nil,
    exactArtifactFacts: [String: String]? = nil,
    issuedAtUTC: String,
    expiresAtUTC: String,
    maximumUses: Int,
    issuer: RuntimeCapabilityIssuer,
    exactPlanDigest: String? = nil,
    exactBindingRevision: Int? = nil,
    revocation: RuntimeCapabilityRevocation = .active
  ) throws {
    self.capabilityID = capabilityID
    self.targetScope = targetScope
    self.operationScope = operationScope
    self.effectCeiling = effectCeiling
    self.inputConstraints = inputConstraints
    self.exactInputs = exactInputs
    self.exactArtifactFacts = exactArtifactFacts
    self.issuedAtUTC = issuedAtUTC
    self.expiresAtUTC = expiresAtUTC
    self.maximumUses = maximumUses
    self.issuer = issuer
    self.exactPlanDigest = exactPlanDigest
    self.exactBindingRevision = exactBindingRevision
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
    self.exactInputs = try container.decodeIfPresent(
      [String: JSONValue].self, forKey: .exactInputs)
    self.exactArtifactFacts = try container.decodeIfPresent(
      [String: String].self, forKey: .exactArtifactFacts)
    self.issuedAtUTC = try container.decode(String.self, forKey: .issuedAtUTC)
    self.expiresAtUTC = try container.decode(String.self, forKey: .expiresAtUTC)
    self.maximumUses = try container.decode(Int.self, forKey: .maximumUses)
    self.issuer = try container.decode(RuntimeCapabilityIssuer.self, forKey: .issuer)
    self.exactPlanDigest = try container.decodeIfPresent(String.self, forKey: .exactPlanDigest)
    self.exactBindingRevision = try container.decodeIfPresent(
      Int.self, forKey: .exactBindingRevision)
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
        !scope.operationID.isEmpty, scope.version.map({ $0 >= 1 }) ?? true,
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
      // Historical maintainer-issued envelopes remain decodable. New
      // destructive admission accepts only the runtimeDefaultPolicy issuer;
      // that new-use rule is enforced by RuntimeJobEngine, not by the value
      // decoder, so old bytes retain decode/export compatibility.
      guard issuer.kind == .runtimeDefaultPolicy || issuer.kind == .maintainerMergedPR else {
        throw RuntimeCapabilityValidationError.destructiveRequiresMaintainerIssuer
      }
      guard case .stablePhysicalIdentity = targetScope else {
        throw RuntimeCapabilityValidationError.destructiveRequiresStableIdentityTarget
      }
      guard exactPlanDigest != nil else {
        throw RuntimeCapabilityValidationError.destructiveRequiresExactPlanDigest
      }
      guard maximumUses == 1 else {
        throw RuntimeCapabilityValidationError.destructiveRequiresSingleUse
      }
    }
    if issuer.kind == .runtimeDefaultPolicy, exactInputs == nil {
      throw RuntimeCapabilityValidationError.runtimePolicyRequiresExactInputs
    }
    if effectCeiling == .destructive, issuer.kind == .runtimeDefaultPolicy,
      exactArtifactFacts?.isEmpty != false
    {
      throw RuntimeCapabilityValidationError.runtimePolicyRequiresExactArtifactFacts
    }
    if let exactArtifactFacts,
      exactArtifactFacts.contains(where: { key, value in
        key.isEmpty || value.isEmpty || key.count > 80 || value.count > 256
      })
    {
      throw RuntimeCapabilityValidationError.runtimePolicyRequiresExactArtifactFacts
    }
    if let digest = exactPlanDigest, !Self.isHexDigest(digest) {
      throw RuntimeCapabilityValidationError.malformedPlanDigest(digest)
    }
    if let bindingRevision = exactBindingRevision, bindingRevision < 1 {
      throw RuntimeCapabilityValidationError.malformedBindingRevision(bindingRevision)
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
          detail: "\(query.operationReference) not in scope"))
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
    case .workspaceIdentity(let expectedIdentity, let expectedRevision, let expectedScopes):
      // Three equalities, each closing a way the grant could otherwise outlive
      // what it authorized: a different tree, the same tree after it moved, or
      // the same tree with a wider write scope than the one granted.
      guard let identity = query.workspaceIdentitySHA256,
        let revision = query.workspaceRevision,
        let scopes = query.workspaceFileScopesDigest
      else {
        return .failure(
          .init(
            reason: .targetIdentityRequired,
            detail: "query carries no workspace identity, revision or scope digest"))
      }
      guard identity == expectedIdentity else {
        return .failure(
          .init(reason: .targetScopeMismatch, detail: "workspace identity does not match scope"))
      }
      // An empty expected revision is a standing grant: it says "this tree,
      // these scopes", not "this tree at this instant". Pinning a revision
      // makes the grant single-use by construction — patch, build, test and
      // revert each move the revision, so a pinned standing capability would
      // need four grants whose values nobody can know in advance. When the
      // issuer does pin one, it is enforced exactly.
      //
      // The per-request binding from r1 still applies either way: a caller
      // that states the revision it decided against is refused if the tree
      // moved (`workspace.revisionConflict`).
      guard expectedRevision.isEmpty || revision == expectedRevision else {
        return .failure(
          .init(
            reason: .targetScopeMismatch,
            detail: "workspace revision moved since this capability was issued"))
      }
      guard scopes == expectedScopes else {
        return .failure(
          .init(
            reason: .targetScopeMismatch,
            detail: "workspace writable scopes differ from the authorized set"))
      }
    }
    if let expectedBindingRevision = exactBindingRevision {
      guard let actualBindingRevision = query.targetBindingRevision else {
        return .failure(
          .init(
            reason: .targetScopeMismatch,
            detail: "query carries no target binding revision"))
      }
      guard actualBindingRevision == expectedBindingRevision else {
        return .failure(
          .init(
            reason: .targetScopeMismatch,
            detail: "target binding revision differs"))
      }
    }
    if let expected = exactPlanDigest {
      guard let actual = query.planDigest else {
        return .failure(.init(reason: .planDigestRequired, detail: "query carries no plan digest"))
      }
      guard actual == expected else {
        return .failure(.init(reason: .planDigestMismatch, detail: "plan digest differs"))
      }
    }
    if let exactInputs, query.inputs != exactInputs {
      return .failure(
        .init(
          reason: .inputConstraintViolated,
          detail: "typed inputs differ from the runtime-issued envelope"))
    }
    if let exactArtifactFacts, query.artifactFacts != exactArtifactFacts {
      return .failure(
        .init(
          reason: .inputConstraintViolated,
          detail: "Runtime-resolved Artifact identity or content digest differs"))
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

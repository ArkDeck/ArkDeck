// Operation Catalog value types (CHG-2026-046, T04).
//
// The catalog data itself lives in Catalog/operations/*.json and is compiled
// into `RuntimeOperationCatalogGenerated.swift` by scripts/catalog_gen.
// These types are hand-written so the generator only ever emits literals.
// Every type is a frozen value: the runtime consults the catalog, it never
// mutates it, and nothing here can carry an executable, argv or shell string.

public enum CatalogProvider: String, CaseIterable, Codable, Sendable {
  case hdc
  case rockchip
  /// Host-only provider: source inspection, patching and builds on this
  /// machine. It has no device target and no connect key by construction.
  case workspace
  /// Host-only provider: deterministic, versioned analysis of artifacts that
  /// already exist (CHG-2026-055, TASK-HFA-007). It reads one artifact and
  /// publishes a derived one; it never touches a device and never writes to
  /// the workspace.
  case analyzer
}

public enum RuntimeOperationAuthorizationPolicy: String, CaseIterable, Codable, Sendable {
  case defaultReadOnly
  case standingCapability
  case runtimeCapability
}

public enum CatalogConcurrencyKey: String, CaseIterable, Codable, Sendable {
  case deviceExclusive
  case deviceSharedReadOnly
  /// Serialises host-only work against the same workspace; it says nothing
  /// about any device and never reserves one.
  case hostExclusive
}

public enum CatalogStepCompensation: String, CaseIterable, Codable, Sendable {
  case none
  case bestEffortCleanup
  case rollbackPublished
}

public struct CatalogActionReference: Equatable, Sendable {
  public let catalogID: String
  public let actionID: String

  public init(catalogID: String, actionID: String) {
    self.catalogID = catalogID
    self.actionID = actionID
  }
}

public enum CatalogFieldType: String, CaseIterable, Codable, Sendable {
  case string
  case integer
  case boolean
  case stringArray
  case artifactLease
  case artifactLeaseArray
  case artifactReference
}

public enum CatalogArtifactRole: String, CaseIterable, Codable, Sendable {
  case raw
  case derived
  case log
  case plan
  case diagnostic
}

public enum CatalogArtifactPrivacy: String, CaseIterable, Codable, Sendable {
  case standard
  case sensitive
}

public enum CatalogArtifactRetentionClass: String, CaseIterable, Codable, Sendable {
  case `default`
  case pinnedUntilVerified
  case shortLived
}

public struct CatalogFieldDescriptor: Equatable, Sendable {
  public let name: String
  public let type: CatalogFieldType
  public let isRequired: Bool
  public let enumValues: [String]?
  public let pattern: String?
  public let minimum: Int?
  public let maximum: Int?
  public let maxLength: Int?
  public let maxItems: Int?

  public init(
    name: String,
    type: CatalogFieldType,
    isRequired: Bool,
    enumValues: [String]? = nil,
    pattern: String? = nil,
    minimum: Int? = nil,
    maximum: Int? = nil,
    maxLength: Int? = nil,
    maxItems: Int? = nil
  ) {
    self.name = name
    self.type = type
    self.isRequired = isRequired
    self.enumValues = enumValues
    self.pattern = pattern
    self.minimum = minimum
    self.maximum = maximum
    self.maxLength = maxLength
    self.maxItems = maxItems
  }
}

public struct CatalogStepDescriptor: Equatable, Sendable {
  public let stepID: String
  public let kind: WorkflowStepKind
  public let effect: WorkflowEffect
  public let cancellation: WorkflowCancellationPolicy
  public let binding: WorkflowBindingRequirement
  public let isOptional: Bool
  public let compensation: CatalogStepCompensation
  public let actionReference: CatalogActionReference?

  public init(
    stepID: String,
    kind: WorkflowStepKind,
    effect: WorkflowEffect,
    cancellation: WorkflowCancellationPolicy,
    binding: WorkflowBindingRequirement,
    isOptional: Bool,
    compensation: CatalogStepCompensation,
    actionReference: CatalogActionReference? = nil
  ) {
    self.stepID = stepID
    self.kind = kind
    self.effect = effect
    self.cancellation = cancellation
    self.binding = binding
    self.isOptional = isOptional
    self.compensation = compensation
    self.actionReference = actionReference
  }
}

public struct CatalogArtifactDescriptor: Equatable, Sendable {
  public let name: String
  public let role: CatalogArtifactRole
  public let mediaType: String
  public let privacy: CatalogArtifactPrivacy
  public let isRequired: Bool
  public let retentionClass: CatalogArtifactRetentionClass

  public init(
    name: String,
    role: CatalogArtifactRole,
    mediaType: String,
    privacy: CatalogArtifactPrivacy,
    isRequired: Bool,
    retentionClass: CatalogArtifactRetentionClass
  ) {
    self.name = name
    self.role = role
    self.mediaType = mediaType
    self.privacy = privacy
    self.isRequired = isRequired
    self.retentionClass = retentionClass
  }
}

/// A reviewed declaration that one exact operation/profile pair can replace
/// every possible effect of an earlier uncertain destructive epoch. The
/// declaration describes semantic coverage only; it carries no executable,
/// argv, target, Artifact or caller-controlled proof surface.
public struct CatalogCompleteOverwriteRecoveryProfileDescriptor: Equatable, Sendable {
  public let reference: String
  public let coveredEffects: [String]

  public init(reference: String, coveredEffects: [String]) {
    self.reference = reference
    self.coveredEffects = coveredEffects
  }
}

public struct CatalogCompleteOverwriteRecoveryDescriptor: Equatable, Sendable {
  public let contractVersion: String
  public let profiles: [CatalogCompleteOverwriteRecoveryProfileDescriptor]
  public let overwriteStepID: String
  public let verificationStepIDs: [String]

  public init(
    contractVersion: String,
    profiles: [CatalogCompleteOverwriteRecoveryProfileDescriptor],
    overwriteStepID: String,
    verificationStepIDs: [String]
  ) {
    self.contractVersion = contractVersion
    self.profiles = profiles
    self.overwriteStepID = overwriteStepID
    self.verificationStepIDs = verificationStepIDs
  }

  public func profile(
    reference: String
  ) -> CatalogCompleteOverwriteRecoveryProfileDescriptor? {
    profiles.first { $0.reference == reference }
  }
}

public struct CatalogOperationDescriptor: Equatable, Sendable {
  public let id: String
  public let version: Int
  public let title: String
  public let provider: CatalogProvider
  public let minimumEffect: WorkflowEffect
  public let permittedEffects: [WorkflowEffect]
  public let authorization: [WorkflowEffect: RuntimeOperationAuthorizationPolicy]
  public let defaultPolicyIssuanceEnabled: Bool
  public let binding: WorkflowBindingRequirement
  public let concurrencyKey: CatalogConcurrencyKey
  public let inputs: [CatalogFieldDescriptor]
  public let outputs: [CatalogFieldDescriptor]
  public let steps: [CatalogStepDescriptor]
  public let timeoutSeconds: Int
  public let outputByteBudget: Int
  public let preflightAttempts: Int
  public let artifacts: [CatalogArtifactDescriptor]
  public let profiles: [String]
  public let completeOverwriteRecovery: CatalogCompleteOverwriteRecoveryDescriptor?

  public init(
    id: String,
    version: Int,
    title: String,
    provider: CatalogProvider,
    minimumEffect: WorkflowEffect,
    permittedEffects: [WorkflowEffect],
    authorization: [WorkflowEffect: RuntimeOperationAuthorizationPolicy],
    defaultPolicyIssuanceEnabled: Bool,
    binding: WorkflowBindingRequirement,
    concurrencyKey: CatalogConcurrencyKey,
    inputs: [CatalogFieldDescriptor],
    outputs: [CatalogFieldDescriptor],
    steps: [CatalogStepDescriptor],
    timeoutSeconds: Int,
    outputByteBudget: Int,
    preflightAttempts: Int,
    artifacts: [CatalogArtifactDescriptor],
    profiles: [String],
    completeOverwriteRecovery: CatalogCompleteOverwriteRecoveryDescriptor? = nil
  ) {
    self.id = id
    self.version = version
    self.title = title
    self.provider = provider
    self.minimumEffect = minimumEffect
    self.permittedEffects = permittedEffects
    self.authorization = authorization
    self.defaultPolicyIssuanceEnabled = defaultPolicyIssuanceEnabled
    self.binding = binding
    self.concurrencyKey = concurrencyKey
    self.inputs = inputs
    self.outputs = outputs
    self.steps = steps
    self.timeoutSeconds = timeoutSeconds
    self.outputByteBudget = outputByteBudget
    self.preflightAttempts = preflightAttempts
    self.artifacts = artifacts
    self.profiles = profiles
    self.completeOverwriteRecovery = completeOverwriteRecovery
  }

  /// Canonical `id@version` reference string.
  public var reference: String { "\(id)@\(version)" }
}

/// The compiled operation catalog. Data is generated from Catalog/ and lives
/// in `RuntimeOperationCatalogGenerated.swift`; drift between the two is a
/// check-sdd error.
public enum RuntimeOperationCatalog {
  /// Looks up a descriptor by exact `id` + `version`. Unknown references
  /// return nil; callers must fail closed (unknown operation), never guess.
  public static func descriptor(id: String, version: Int) -> CatalogOperationDescriptor? {
    operations.first { $0.id == id && $0.version == version }
  }

  public static func descriptor(reference: String) -> CatalogOperationDescriptor? {
    let parts = reference.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, let version = Int(parts[1]), version > 0 else { return nil }
    return descriptor(id: String(parts[0]), version: version)
  }
}

/// Resolves the effect of the exact typed request the runtime will
/// materialize. Keeping this rule in `ArkDeckCore` gives authorization,
/// execution and higher-level bounded-budget accounting one source of truth.
public enum CatalogOperationEffectResolver {
  /// The maximum effect over the steps selected by these exact inputs.
  /// Optional steps that will not run do not raise the result.
  public static func effectiveEffect(
    descriptor: CatalogOperationDescriptor, inputs: [String: JSONValue]
  ) -> WorkflowEffect {
    var effect = descriptor.minimumEffect
    for step in descriptor.steps where stepIsSelected(step, descriptor: descriptor, inputs: inputs) {
      if step.effect > effect { effect = step.effect }
    }
    return effect
  }

  /// Whether a catalog step participates in the exact materialized plan.
  /// A step can be mandatory when selected yet switched off by a typed input;
  /// that is distinct from an optional step whose failure may be tolerated.
  public static func stepIsSelected(
    _ step: CatalogStepDescriptor,
    descriptor: CatalogOperationDescriptor,
    inputs: [String: JSONValue]
  ) -> Bool {
    if step.isOptional {
      return optionalStepIsSelected(step, descriptor: descriptor, inputs: inputs)
    }
    switch step.stepID {
    case "stop-ability":
      if case .string(let state)? = inputs["postRunAbilityState"] {
        return state == "stopped"
      }
      return true
    default:
      return true
    }
  }

  /// Typed selection rules for published optional steps. Defaults mirror the
  /// catalog operation's input defaults and therefore fail closed with the
  /// same plan the runtime will execute.
  public static func optionalStepIsSelected(
    _ step: CatalogStepDescriptor,
    descriptor: CatalogOperationDescriptor,
    inputs: [String: JSONValue]
  ) -> Bool {
    switch step.stepID {
    case "capture-trace", "receive-trace-artifact", "cleanup-remote-temp":
      if case .array(let categories)? = inputs["traceCategories"] {
        return !categories.isEmpty
      }
      return false
    case "capture-ui-dump":
      if case .bool(let enabled)? = inputs["uiDump"] { return enabled }
      return true
    case "capture-crash-index":
      if case .bool(let enabled)? = inputs["crashLogs"] { return enabled }
      return false
    case "capture-crash-log":
      if case .string(let name)? = inputs["crashLogName"] { return !name.isEmpty }
      return false
    case "observe-application-liveness":
      if case .string(let bundleName)? = inputs["bundleName"] {
        return !bundleName.isEmpty
      }
      return false
    case "capture-screenshot", "receive-screenshot", "cleanup-screenshot-temp":
      if case .bool(let enabled)? = inputs["uiScreenshot"] { return enabled }
      return false
    case "capture-ui-tree", "receive-ui-tree", "cleanup-ui-tree-temp":
      if case .bool(let enabled)? = inputs["uiComponentTree"] { return enabled }
      return false
    case "capture-diagnostics":
      if case .bool(let enabled)? = inputs["captureDiagnostics"] { return enabled }
      return true
    case "cleanup-uninstall":
      if case .string(let policy)? = inputs["cleanupPolicy"] {
        return policy == "uninstall"
      }
      return true
    case "capture-post-flash-diagnostics":
      if case .string(let profile)? = inputs["postFlashVerification"] {
        return profile == "full"
      }
      return true
    default:
      return true
    }
  }
}

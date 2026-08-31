import ArkDeckCore
import Foundation

/// Exactly what §7.9 lets `workspace project/preset list/show` publish.
///
/// This is a projection rather than the profile itself, and that is the point.
/// `WorkspaceProjectProfile` holds the host root, the resolved executable
/// identities and their fixed argv; §7.9 forbids publishing any of them —
/// "不暴露 host root、executable、argv 或秘密". Handing the daemon a value that
/// cannot carry those makes the rule a property of the type instead of
/// something every projection site has to remember, which is the difference
/// between a guarantee and a convention.
///
/// It is also why the daemon does not receive the registry: a port that could
/// reach the root would have to be trusted not to.
public struct WorkspaceProjectPublication: Sendable, Equatable {

  /// A preset reference, kind-tagged as §7.9 requires so a caller can map it
  /// onto the descriptor's `buildPresetRef` / `testPresetRef` /
  /// `signingPresetRef` / `symbolPresetRef` without guessing.
  public struct Preset: Sendable, Equatable {
    public let presetRef: String
    public let kind: String
    /// A typed constraint a caller can plan against. The executable and its
    /// arguments are deliberately absent.
    public let timeoutSeconds: Int

    public init(presetRef: String, kind: String, timeoutSeconds: Int) {
      self.presetRef = presetRef
      self.kind = kind
      self.timeoutSeconds = timeoutSeconds
    }
  }

  /// Whether one published operation can run in this project right now, and
  /// when it cannot, why. §7.9: "已知但当前不可用返回带 reason 的 availability，
  /// 不使用 host path 作为临时逃生参数."
  public struct OperationAvailability: Sendable, Equatable {
    public let reference: String
    public let available: Bool
    public let reasonCode: String?
    public let reason: String?

    public init(reference: String, available: Bool, reasonCode: String?, reason: String?) {
      self.reference = reference
      self.available = available
      self.reasonCode = reasonCode
      self.reason = reason
    }
  }

  public let projectRef: String
  /// `primary` or `evolution`; absent when the project never resolved.
  public let kind: String?
  public let available: Bool
  public let reasonCode: String?
  public let reason: String?
  /// Relative path patterns the project's operations are scoped to. Safe to
  /// publish and useful for planning: they say what may be touched without
  /// saying where the project lives.
  public let allowedFileGlobs: [String]
  public let presets: [Preset]
  public let operations: [OperationAvailability]

  public init(
    projectRef: String,
    kind: String?,
    available: Bool,
    reasonCode: String?,
    reason: String?,
    allowedFileGlobs: [String],
    presets: [Preset],
    operations: [OperationAvailability]
  ) {
    self.projectRef = projectRef
    self.kind = kind
    self.available = available
    self.reasonCode = reasonCode
    self.reason = reason
    self.allowedFileGlobs = allowedFileGlobs
    self.presets = presets
    self.operations = operations
  }

  /// A project the daemon was configured with and could not resolve.
  ///
  /// It is published rather than omitted because an empty list would mean two
  /// different things — nothing configured, and configured but unusable — and
  /// the second is the one an operator needs to see. The ref is a name the
  /// operator chose; no path travels with it.
  public static func unresolved(projectRef: String, reason: String) -> Self {
    WorkspaceProjectPublication(
      projectRef: projectRef,
      kind: nil,
      available: false,
      reasonCode: "workspace_project_profile_unavailable",
      reason: reason,
      allowedFileGlobs: [],
      presets: [],
      operations: [])
  }
}

extension WorkspaceProjectPublication {

  /// Builds the publication for one resolved project.
  ///
  /// Availability is asked of the provider rather than re-derived here. The
  /// provider already decides, per operation, whether the presets and pinned
  /// tool identities it needs are present — re-implementing that test would
  /// create a second answer that drifts from the one admission actually uses,
  /// and discovery that disagrees with admission is worse than no discovery.
  package static func make(
    profile: WorkspaceProjectProfile,
    availability: (CatalogOperationDescriptor) -> ProviderOperationAvailability
  ) -> Self {
    var presets: [Preset] = []
    for (kind, table) in [
      ("build", profile.buildPresets), ("test", profile.testPresets),
      ("symbol", profile.symbolPresets),
    ] {
      for (_, preset) in table {
        presets.append(
          Preset(
            presetRef: preset.presetID, kind: kind, timeoutSeconds: preset.timeoutSeconds))
      }
    }
    // Sorted so two reads of an unchanged configuration agree byte for byte.
    presets.sort { ($0.kind, $0.presetRef) < ($1.kind, $1.presetRef) }

    var operations: [OperationAvailability] = []
    for descriptor in RuntimeOperationCatalog.operations
    where descriptor.provider == .workspace {
      switch availability(descriptor) {
      case .available:
        operations.append(
          OperationAvailability(
            reference: descriptor.reference, available: true, reasonCode: nil, reason: nil))
      case .unavailable(let code, let reason):
        operations.append(
          OperationAvailability(
            reference: descriptor.reference, available: false,
            reasonCode: code.rawValue, reason: reason))
      }
    }
    operations.sort { $0.reference < $1.reference }

    // A project is available when something can actually be done in it.
    // Reporting `available` for a resolved profile whose every operation is
    // refused would be true of the record and false of the product.
    let usable = operations.contains { $0.available }
    return WorkspaceProjectPublication(
      projectRef: profile.projectRef,
      kind: profile.kind.rawValue,
      available: usable,
      reasonCode: usable ? nil : "workspace_project_has_no_available_operation",
      reason: usable
        ? nil : "the project resolved but no published workspace operation can run in it",
      allowedFileGlobs: profile.allowedFileGlobs.sorted(),
      presets: presets,
      operations: operations)
  }
}

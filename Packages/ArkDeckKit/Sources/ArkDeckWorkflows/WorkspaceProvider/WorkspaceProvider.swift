// The first host-only provider (CHG-2026-054, TASK-HTP-007).
//
// It serves exactly one operation, `workspace.inspect-source@1`, and it is the
// consumer that makes the engine's host-only admission path testable and real.
// Four properties are the point:
//
//   * it has no device. `resolveFacts` throws rather than synthesising a
//     connect key or an identity digest - the engine's host-only branch never
//     calls it, and a caller that does gets a refusal instead of a fiction;
//   * a caller supplies a project reference and a glob, never a path. The
//     provider resolves the root from its own registry and joins the glob to
//     it, so no request input can address the filesystem;
//   * argv is built here, in full, and the descriptor-bound dispatcher spawns
//     exactly that array. There is no shell and no string concatenation;
//   * with no inspector executable configured the operation reports
//     `UNAVAILABLE` with a machine-readable reason, so nothing is admitted and
//     no capability is consumed (PRODUCT-LOOP §8).
//
// It conforms to `DeviceProvider` because that protocol is the runtime's
// provider seam, not because anything here touches a device; the host-only
// members below are the ones that say so.

import ArkDeckCore
import Foundation

public enum WorkspaceProviderError: Error, Equatable, Sendable {
  case unknownProject(String)
  case malformedScope(String)
  case noDeviceFacts
}

/// Declared source workspaces this host may read. Registration is explicit:
/// an unknown project reference is a refusal, never a guessed path.
public struct WorkspaceProjectRegistry: Sendable, Equatable {
  private let roots: [String: String]

  public init(roots: [String: String] = [:]) {
    self.roots = roots
  }

  public var projectRefs: [String] { roots.keys.sorted() }

  public func root(for projectRef: String) throws -> String {
    guard let root = roots[projectRef] else {
      throw WorkspaceProviderError.unknownProject(projectRef)
    }
    return root
  }
}

public struct WorkspaceInspectorTool: Sendable, Equatable {
  public let executablePath: String
  public let executableSHA256: String

  public init(executablePath: String, executableSHA256: String) {
    self.executablePath = executablePath
    self.executableSHA256 = executableSHA256
  }
}

public struct WorkspaceProvider: DeviceProvider {
  public static let inspectSourceReference = "workspace.inspect-source@1"

  private let registry: WorkspaceProjectRegistry
  /// Absent means the host has no configured inspector: the operation reports
  /// unavailable rather than degrading to something else.
  private let tool: WorkspaceInspectorTool?
  private let operations: (any DeviceProvider)?

  public init(registry: WorkspaceProjectRegistry, tool: WorkspaceInspectorTool? = nil) {
    self.registry = registry
    self.tool = tool
    self.operations = nil
  }

  package init(
    registry: WorkspaceProjectRegistry,
    tool: WorkspaceInspectorTool? = nil,
    operations: any DeviceProvider
  ) {
    self.registry = registry
    self.tool = tool
    self.operations = operations
  }

  public var providerID: String { CatalogProvider.workspace.rawValue }

  public func runtimeAvailability(
    for operation: CatalogOperationDescriptor
  ) -> ProviderOperationAvailability {
    guard operation.reference == Self.inspectSourceReference else {
      return operations?.runtimeAvailability(for: operation)
        ?? .unavailable(
          reason: "workspace provider has no production typed plan for \(operation.reference)")
    }
    guard tool != nil else {
      return .unavailable(reason: "no_workspace_inspector_configured")
    }
    guard !registry.projectRefs.isEmpty else {
      return .unavailable(reason: "no_workspace_project_registered")
    }
    return .available
  }

  /// A host-only provider has no device facts. Throwing is the honest answer:
  /// the engine's host-only admission never asks, and anything that does must
  /// fail rather than receive invented routing.
  public func resolveFacts(targetID: String) async throws -> ProviderFacts {
    throw DeviceProviderError.factsUnavailable(
      "workspace provider is host-only: it has no device facts for \(targetID)")
  }

  /// Forwarded: the ProjectProfile that owns the tree lives in the operations
  /// provider, so it is the only thing that can answer.
  public func workspaceAuthorizationFacts(
    for operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue]
  ) throws -> WorkspaceAuthorizationFacts? {
    try operations?.workspaceAuthorizationFacts(for: operation, inputs: inputs)
  }

  package func action(
    for step: CatalogStepDescriptor,
    operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue]
  ) throws -> TypedProviderAction {
    try action(
      for: step, operation: operation, inputs: inputs,
      context: ProviderExecutionContext(
        jobID: "unbound", stepID: step.stepID, targetID: "unbound", bindingRevision: nil,
        nowUTC: "1970-01-01T00:00:00Z"))
  }

  package func action(
    for step: CatalogStepDescriptor,
    operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue],
    context: ProviderExecutionContext
  ) throws -> TypedProviderAction {
    guard operation.reference == Self.inspectSourceReference else {
      guard let operations else {
        throw DeviceProviderError.unsupportedAction(
          "workspace provider does not implement \(operation.reference)/\(step.stepID)")
      }
      return try operations.action(
        for: step, operation: operation, inputs: inputs, context: context)
    }
    guard step.kind == .inspectWorkspaceSource else {
      throw DeviceProviderError.unsupportedAction(
        "workspace provider does not implement \(operation.reference)/\(step.stepID)")
    }
    guard case .string(let projectRef)? = inputs["projectRef"],
      case .string(let symbol)? = inputs["symbol"],
      case .string(let fileScope)? = inputs["fileScope"]
    else {
      throw DeviceProviderError.unsupportedAction(
        "\(step.stepID) requires typed projectRef, symbol and fileScope inputs")
    }
    let root = try registry.root(for: projectRef)
    try Self.validateScope(fileScope)
    try Self.validateSymbol(symbol)
    return .workspace(
      .inspectSource(
        WorkspaceSourceInspection(
          projectRef: projectRef, projectRoot: root, symbol: symbol, fileScope: fileScope)))
  }

  package func lower(
    action: TypedProviderAction,
    context: ProviderExecutionContext
  ) throws -> TypedProcessPlan {
    guard case .workspace(let workspaceAction) = action else {
      throw DeviceProviderError.unsupportedAction(
        "non-workspace action given to workspace provider")
    }
    switch workspaceAction {
    case .inspectSource(let inspection):
      guard let tool else {
        throw DeviceProviderError.unsupportedAction("no_workspace_inspector_configured")
      }
      // Exactly the argv the dispatcher spawns. `--` terminates options so a
      // symbol that begins with a dash can never become one, and the root is
      // the last element so the search cannot escape it.
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: tool.executableSHA256,
          argumentSummary: [
            "-r", "-n", "--include", inspection.fileScope, "--", inspection.symbol,
            inspection.projectRoot,
          ],
          timeoutSeconds: 120))
    case .applyPatch, .buildOpenHarmony, .runTests, .symbolizeCrash, .revertPatch,
      .inspectGitStatus, .inspectDiff, .readSourceRange, .createCheckpoint,
      .createArchiveCheckpoint, .signOpenHarmonyHap:
      guard let operations else {
        throw DeviceProviderError.unsupportedAction(
          "workspace operation presets are unavailable")
      }
      return try operations.lower(action: action, context: context)
    }
  }

  package func verify(
    receipt: ProviderProcessReceipt,
    action: TypedProviderAction,
    context: ProviderExecutionContext
  ) throws -> ProviderSemanticOutcome {
    guard case .workspace(let workspaceAction) = action else {
      throw DeviceProviderError.unsupportedAction(
        "non-workspace action given to workspace provider")
    }
    switch workspaceAction {
    case .inspectSource(let inspection):
      let matched = receipt.stdout.isEmpty ? "0" : "1+"
      switch receipt.exitStatus {
      case 0:
        return .verified(
          summary: [
            "projectRef": inspection.projectRef,
            "fileScope": inspection.fileScope,
            "matches": matched,
            "truncated": receipt.stdoutTruncated ? "true" : "false",
          ])
      case 1:
        // "No occurrences" is a real, useful observation, not a failure: the
        // evaluator needs to be able to tell absence from a broken run.
        return .verified(
          summary: [
            "projectRef": inspection.projectRef,
            "fileScope": inspection.fileScope,
            "matches": "0",
            "truncated": receipt.stdoutTruncated ? "true" : "false",
          ])
      default:
        return .failed(
          code:
            "inspectorExit\(receipt.exitStatus.map(String.init) ?? "missing")",
          detail: "workspace inspector failed for \(inspection.projectRef)")
      }
    case .applyPatch, .buildOpenHarmony, .runTests, .symbolizeCrash, .revertPatch,
      .inspectGitStatus, .inspectDiff, .readSourceRange, .createCheckpoint,
      .createArchiveCheckpoint, .signOpenHarmonyHap:
      guard let operations else {
        return .unsupported(reason: "workspace operation presets are unavailable")
      }
      return try operations.verify(
        receipt: receipt, action: action, context: context)
    }
  }

  /// A read that writes nothing leaves no external effect behind, so recovery
  /// has nothing to confirm: re-running it is safe and cannot double anything.
  public func reconcile(
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) async throws -> ProviderReconcileOutcome {
    guard case .workspace(let action) = intent.action else {
      return .stillUnknown(reason: "workspace reconcile received a foreign action")
    }
    switch action {
    case .inspectSource:
      return .confirmedNotExecuted
    case .applyPatch, .buildOpenHarmony, .runTests, .symbolizeCrash, .revertPatch,
      .inspectGitStatus, .inspectDiff, .readSourceRange, .createCheckpoint,
      .createArchiveCheckpoint, .signOpenHarmonyHap:
      guard let operations else {
        return .stillUnknown(reason: "workspace operation presets are unavailable")
      }
      return try await operations.reconcile(intent: intent, context: context)
    }
  }

  package func cleanupTerminalJob(jobID: String) {
    operations?.cleanupTerminalJob(jobID: jobID)
  }

  /// No readback plan: there is no device state to read back, and inventing a
  /// probe here is exactly what CHG-2026-054 §15 forbids.
  public func reconciliationReadback(
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) throws -> TypedProcessPlan? {
    nil
  }

  public func verifyReconciliationReadback(
    receipt: ProviderProcessReceipt,
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) throws -> ProviderReconcileOutcome {
    .stillUnknown(reason: "workspace provider publishes no readback plan")
  }

  // MARK: - Input screening

  static func validateScope(_ scope: String) throws {
    guard !scope.isEmpty, scope.count <= 120,
      !scope.contains("/"), !scope.contains(".."), !scope.hasPrefix("-"),
      scope.allSatisfy({
        $0.isASCII && ($0.isLetter || $0.isNumber || "*?.-_[]".contains($0))
      })
    else {
      // A glob, never a path: no separators, no parent traversal, no option.
      throw WorkspaceProviderError.malformedScope(scope)
    }
  }

  static func validateSymbol(_ symbol: String) throws {
    guard !symbol.isEmpty, symbol.count <= 200,
      !symbol.contains("\u{0}"), !symbol.contains("\n")
    else {
      throw WorkspaceProviderError.malformedScope(symbol)
    }
  }
}

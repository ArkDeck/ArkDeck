import XCTest

@testable import ArkDeckCore

/// Semantic invariants over the generated catalog data. Byte-level parity
/// with Catalog/ JSON is owned by scripts/catalog_gen + check-sdd family 11;
/// these tests pin the Swift-side guarantees the runtime will rely on.
final class RuntimeOperationCatalogTests: XCTestCase {
  func testCatalogContainsExactlyThePublishedOperations() {
    XCTAssertEqual(
      RuntimeOperationCatalog.operations.map(\.reference).sorted(),
      [
        "analyzer.extract-crash-signature@1",
        "analyzer.summarize-hilog@1",
        "analyzer.summarize-trace@1",
        "capture.diagnostics@1",
        "debug.hap@1",
        "deploy.native-library.app-owned@1",
        "deploy.native-library.system@1",
        "flash.dayu200@1",
        "observe.device@1",
        "workspace.apply-patch@1",
        "workspace.build-openharmony@1",
        "workspace.create-checkpoint@1",
        "workspace.inspect-diff@1",
        "workspace.inspect-git-status@1",
        "workspace.inspect-source@1",
        "workspace.read-source-range@1",
        "workspace.revert-patch@1",
        "workspace.run-tests@1",
        "workspace.symbolize-crash@1",
      ])
    XCTAssertRegularExpression(
      RuntimeOperationCatalog.catalogDigest, pattern: "^[0-9a-f]{64}$")
  }

  func testDescriptorLookupIsExactAndFailClosed() {
    XCTAssertNotNil(RuntimeOperationCatalog.descriptor(id: "observe.device", version: 1))
    XCTAssertNil(RuntimeOperationCatalog.descriptor(id: "observe.device", version: 2))
    XCTAssertNil(RuntimeOperationCatalog.descriptor(id: "observe.devices", version: 1))
    XCTAssertNotNil(RuntimeOperationCatalog.descriptor(reference: "debug.hap@1"))
    XCTAssertNil(RuntimeOperationCatalog.descriptor(reference: "debug.hap@0"))
    XCTAssertNil(RuntimeOperationCatalog.descriptor(reference: "debug.hap"))
    XCTAssertNil(RuntimeOperationCatalog.descriptor(reference: "debug.hap@x"))
  }

  func testEveryStepRespectsWorkflowStepRegistryMinimums() {
    for operation in RuntimeOperationCatalog.operations {
      for step in operation.steps {
        let metadata = WorkflowStepRegistry.metadata(for: step.kind)
        XCTAssertGreaterThanOrEqual(
          step.effect, metadata.minimumEffect,
          "\(operation.reference)/\(step.stepID) effect below registry minimum")
        XCTAssertGreaterThanOrEqual(
          step.cancellation, metadata.minimumCancellation,
          "\(operation.reference)/\(step.stepID) cancellation below registry minimum")
        XCTAssertGreaterThanOrEqual(
          step.binding, metadata.minimumBindingRequirement,
          "\(operation.reference)/\(step.stepID) binding below registry minimum")
      }
    }
  }

  func testEffectEnvelopeIsConsistentPerOperation(){
    for operation in RuntimeOperationCatalog.operations {
      let stepMax = operation.steps.map(\.effect).max() ?? .hostOnly
      let requiredMax =
        operation.steps.filter { !$0.isOptional }.map(\.effect).max() ?? .hostOnly
      XCTAssertEqual(
        operation.minimumEffect, requiredMax,
        "\(operation.reference): minimum effect must equal max required-step effect")
      XCTAssertTrue(
        operation.permittedEffects.contains(stepMax),
        "\(operation.reference): max step effect must be permitted")
      let permittedMax = operation.permittedEffects.max() ?? .hostOnly
      XCTAssertEqual(
        permittedMax, stepMax,
        "\(operation.reference): permitted max must be reachable by steps")
    }
  }

  /// Every permitted effect names its gate, host-only included. The earlier
  /// rule excluded `hostOnly` while the contract also demanded a non-empty
  /// authorization map, which made a purely host-only operation impossible to
  /// express - the same contract/implementation gap as operation-level
  /// `binding: none` (CHG-2026-054 TASK-HTP-007).
  func testAuthorizationCoversEveryPermittedEffect() {
    for operation in RuntimeOperationCatalog.operations {
      let expected = Set(operation.permittedEffects)
      XCTAssertEqual(
        Set(operation.authorization.keys), expected,
        "\(operation.reference): authorization keys must cover permitted effects")
      if let policy = operation.authorization[.destructive] {
        XCTAssertEqual(
          policy, .runtimeCapability,
          "\(operation.reference): destructive must use Runtime-owned capability admission")
      }
      for (effect, policy) in operation.authorization where policy == .defaultReadOnly {
        XCTAssertLessThanOrEqual(
          effect, .readOnly,
          "\(operation.reference): defaultReadOnly may not gate a mutation")
      }
    }
  }

  func testDestructiveOperationsRemainPinnedAndRuntimeIssuable() throws {
    let system = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(id: "deploy.native-library.system", version: 1))
    XCTAssertEqual(system.permittedEffects, [.destructive])
    XCTAssertTrue(system.defaultPolicyIssuanceEnabled)
    let flash = try XCTUnwrap(RuntimeOperationCatalog.descriptor(id: "flash.dayu200", version: 1))
    XCTAssertEqual(flash.permittedEffects, [.destructive])
    XCTAssertEqual(flash.provider, .rockchip)
    XCTAssertTrue(flash.defaultPolicyIssuanceEnabled)
    XCTAssertTrue(flash.steps.contains { $0.kind == .flashPartition })
  }

  /// Restated, not relaxed (CHG-2026-055, TASK-HFA-009 r2).
  ///
  /// What this test was written to forbid is a mutation that reaches a device
  /// without a confirmed binding, and that is asserted below exactly as
  /// before. What it also assumed — that every E1 effect *is* a device effect
  /// — stopped being true when workspace mutations became E1: they change a
  /// tree on this host, have no device to bind to, and are gated by a
  /// workspace-scoped capability instead.
  ///
  /// So the rule splits by subject, and each half must be complete on its own
  /// terms. Deleting the workspace half, or widening the device half to admit
  /// an unbound device mutation, would give back exactly the protection this
  /// test exists for.
  func testMutatingOperationsCarryTheGuardsOfTheirOwnSubject() {
    for operation in RuntimeOperationCatalog.operations
    where operation.permittedEffects.contains(where: { $0 >= .deviceMutation }) {
      if operation.provider == .workspace {
        // A workspace mutation: no device, serialized against the tree, and
        // unreachable without a grant a maintainer issued for that tree.
        XCTAssertEqual(
          operation.concurrencyKey, .hostExclusive,
          "\(operation.reference): a workspace mutation is serialized on the host")
        XCTAssertEqual(
          operation.binding, WorkflowBindingRequirement.none,
          "\(operation.reference): a workspace mutation has no device to bind")
        XCTAssertEqual(
          operation.authorization[.deviceMutation], .standingCapability,
          "\(operation.reference): a workspace mutation must require a capability")
        XCTAssertFalse(
          operation.defaultPolicyIssuanceEnabled,
          "\(operation.reference): the runtime must not issue its own workspace grant")
        XCTAssertFalse(
          operation.steps.contains { $0.binding == .confirmedDevice },
          "\(operation.reference): an unbound operation must contain no device step")
      } else {
        XCTAssertEqual(
          operation.concurrencyKey, .deviceExclusive,
          "\(operation.reference): mutating operations must be device-exclusive")
        XCTAssertEqual(
          operation.binding, .confirmedDevice,
          "\(operation.reference): mutating operations require a confirmed binding")
      }
    }
  }

  /// The half that would otherwise be easy to lose: nothing outside the
  /// workspace provider may mutate without a device binding.
  func testOnlyWorkspaceMutationsMayBeUnbound() {
    for operation in RuntimeOperationCatalog.operations
    where operation.permittedEffects.contains(where: { $0 >= .deviceMutation })
      && operation.binding == WorkflowBindingRequirement.none
    {
      XCTAssertEqual(
        operation.provider, .workspace,
        "\(operation.reference): only a workspace mutation may be unbound")
    }
  }

  func testNoInputFieldCarriesAnExecutableSurface() {
    let forbidden: Set<String> = [
      "argv", "shell", "exec", "command", "runhdc", "rawcommand", "executable",
    ]
    for operation in RuntimeOperationCatalog.operations {
      for field in operation.inputs {
        XCTAssertFalse(
          forbidden.contains(field.name.lowercased()),
          "\(operation.reference): input \(field.name) is a forbidden executable surface")
      }
    }
  }

  func testBudgetsAndTimeoutsArePresentAndBounded() {
    for operation in RuntimeOperationCatalog.operations {
      XCTAssertTrue(
        (1...7200).contains(operation.timeoutSeconds), operation.reference)
      XCTAssertTrue(
        (1024...(1 << 30)).contains(operation.outputByteBudget), operation.reference)
      XCTAssertTrue((1...3).contains(operation.preflightAttempts), operation.reference)
    }
  }
}

private func XCTAssertRegularExpression(
  _ value: String, pattern: String, file: StaticString = #filePath, line: UInt = #line
) {
  XCTAssertNotNil(
    value.range(of: pattern, options: .regularExpression),
    "\(value) does not match \(pattern)", file: file, line: line)
}

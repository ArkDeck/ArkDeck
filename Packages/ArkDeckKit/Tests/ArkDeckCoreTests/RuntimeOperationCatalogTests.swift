import Foundation
import Testing

@testable import ArkDeckCore

/// Semantic invariants over the generated catalog data. Byte-level parity
/// with Catalog/ JSON is owned by scripts/catalog_gen + check-sdd family 11;
/// these tests pin the Swift-side guarantees the runtime will rely on.
struct RuntimeOperationCatalogTests {
  @Test func catalogContainsExactlyThePublishedOperations() {
    #expect(
      RuntimeOperationCatalog.operations.map(\.reference).sorted() == [
        "analyzer.analyze-trace@1",
        "analyzer.extract-crash-signature@1",
        "analyzer.summarize-hilog@1",
        "analyzer.summarize-trace@1",
        "capture.diagnostic-session@1",
        "capture.diagnostics@1",
        "capture.screen-sequence@1",
        "debug.hap@1",
        "debug.template@1",
        "deploy.native-library.app-owned@1",
        "flash.dayu200",
        "flash.full-restore@1",
        "input.keyboard@1",
        "input.long-press@1",
        "input.swipe@1",
        "input.tap@1",
        "observe.device@1",
        "port-forward.create@1",
        "port-forward.remove@1",
        "workspace.apply-patch@1",
        "workspace.build-openharmony@1",
        "workspace.create-checkpoint@1",
        "workspace.inspect-diff@1",
        "workspace.inspect-git-status@1",
        "workspace.inspect-source@1",
        "workspace.prepare-isolated-copy@1",
        "workspace.read-source-range@1",
        "workspace.revert-patch@1",
        "workspace.run-tests@1",
        "workspace.sign-openharmony-hap@1",
        "workspace.sweep-isolated-copies@1",
        "workspace.symbolize-crash@1",
      ])
    expectRegularExpression(
      RuntimeOperationCatalog.catalogDigest, pattern: "^[0-9a-f]{64}$")
  }

  @Test func publishedEnumsContainOnlyExecutableValues() throws {
    func field(
      _ operation: String, _ name: String
    ) throws -> CatalogFieldDescriptor {
      let descriptor = try #require(
        RuntimeOperationCatalog.descriptor(reference: operation), "\(operation)")
      return try #require(
        descriptor.inputs.first { $0.name == name }, "\(operation).\(name)")
    }

    #expect(
      try field("debug.hap@1", "installPolicy").enumValues
        == ["installOrReplace"])
    #expect(
      try field("debug.hap@1", "cleanupPolicy").enumValues
        == ["uninstall", "retain"])
    #expect(
      try field("debug.hap@1", "portForwardProfile").enumValues
        == ["none"])
    #expect(
      try field("deploy.native-library.app-owned@1", "restartProfile").enumValues
        == ["restartAbility"])
    #expect(
      try field("capture.diagnostics@1", "redactionProfile").enumValues
        == ["standard"])

    for (operation, name) in [
      ("debug.hap@1", "installPolicy"),
      ("debug.hap@1", "portForwardProfile"),
      ("deploy.native-library.app-owned@1", "restartProfile"),
      ("capture.diagnostics@1", "redactionProfile"),
    ] {
      let summary = try #require(try field(operation, name).summary)
      #expect(
        summary.contains("currently has one executable value"),
        "\(operation).\(name) must explain why its single-value enum remains published")
    }
  }

  /// Field semantics have to survive the generator, not just the catalog.
  ///
  /// `description` and `default` were validated as legal catalog keys and then
  /// dropped on the way to Swift, so the runtime knew every field's shape and
  /// nothing about its meaning or its omitted value. Anything talking to an
  /// installed daemon could only recover them by reading this repository.
  @Test func publishedFieldsCarryTheirCatalogMeaningAndDefault() throws {
    let debugHAP = try #require(
      RuntimeOperationCatalog.descriptor(reference: "debug.hap@1"))
    func input(_ name: String) throws -> CatalogFieldDescriptor {
      try #require(debugHAP.inputs.first { $0.name == name }, "\(name)")
    }

    // The pair that has to be discovered together: observing a delayed crash
    // needs the ability left running *and* the package retained, and neither
    // field's shape says so.
    #expect(try input("postRunAbilityState").defaultValue == .string("stopped"))
    #expect(try input("cleanupPolicy").defaultValue == .string("uninstall"))
    let postRun = try #require(try input("postRunAbilityState").summary)
    #expect(
      postRun.contains("running"),
      "the description must name the value that changes the behaviour: \(postRun)")

    // Defaults are typed, not stringly.
    #expect(try input("captureDiagnostics").defaultValue == .bool(true))
    #expect(try input("diagnosticsDurationSeconds").defaultValue == .integer(30))

    // A required field has no default, and that is expressed as absence rather
    // than as some empty value a caller might send.
    #expect(try input("bundleName").defaultValue == nil)

    // Every default the catalog declares reaches the runtime, for every
    // published operation — the count is what makes this fail if the generator
    // silently drops the branch again rather than only for debug.hap.
    let withDefaults = RuntimeOperationCatalog.operations
      .flatMap(\.inputs)
      .filter { $0.defaultValue != nil }
    #expect(
      withDefaults.count == 29,
      "the catalog declares twenty-nine input defaults; the runtime must see all of them")
  }

  /// Every published input says what it is for.
  ///
  /// Forty-seven did not, and the silence was not evenly spread: all three
  /// inputs of `workspace.symbolize-crash@1` were mute, so the only way to
  /// learn that `symbolPresetRef` accepts exactly `arkts-sourcemap` was to
  /// read this repository — not a surface a caller talking to an installed
  /// daemon has.
  ///
  /// Asserted as coverage rather than as a count, so the next input added
  /// without a description fails here instead of shipping mute.
  @Test func everyPublishedInputCarriesADescription() {
    var silent: [String] = []
    for descriptor in RuntimeOperationCatalog.operations {
      for field in descriptor.inputs where field.summary?.isEmpty != false {
        silent.append("\(descriptor.reference).\(field.name)")
      }
    }
    #expect(
      silent.sorted() == [],
      """
      these published inputs carry no description, so the only way to fill them \
      correctly is to read the catalog source: \(silent.sorted().joined(separator: ", "))
      """)
  }

  /// Omitting an input and passing the catalog's own default for it must
  /// select the same plan.
  ///
  /// The selection rules used to restate each default themselves — an absent
  /// `cleanupPolicy` fell through to "run cleanup-uninstall" because the
  /// declared default happens to be `uninstall`. Nothing compared the two, so
  /// editing the catalog default moved the document and left the behaviour
  /// where it was, and the effect admission charges is computed from these
  /// same rules.
  ///
  /// This holds the property rather than the values: it reads each default out
  /// of the catalog and requires the two paths to agree, for every published
  /// operation and every step it declares.
  @Test func omittingAnInputSelectsTheSamePlanAsPassingItsCatalogDefault() {
    var checked = 0
    for descriptor in RuntimeOperationCatalog.operations {
      for field in descriptor.inputs {
        guard let declared = field.defaultValue else { continue }
        checked += 1
        let explicit: [String: JSONValue] = [field.name: declared]
        for step in descriptor.steps {
          #expect(
            CatalogOperationEffectResolver.stepIsSelected(
              step, descriptor: descriptor, inputs: [:])
              == CatalogOperationEffectResolver.stepIsSelected(
                step, descriptor: descriptor, inputs: explicit),
            """
            \(descriptor.reference) step \(step.stepID): omitting \(field.name) selects a \
            different plan than passing its declared default \(declared) — the rule restates \
            a default instead of reading it
            """)
        }
        #expect(
          CatalogOperationEffectResolver.effectiveEffect(descriptor: descriptor, inputs: [:])
            == CatalogOperationEffectResolver.effectiveEffect(
              descriptor: descriptor, inputs: explicit),
          "\(descriptor.reference): \(field.name)'s default changes the charged effect")
      }
    }
    #expect(
      checked == 29,
      "the catalog declares twenty-nine input defaults; all of them must be exercised here")
  }

  @Test func viewerCanOmitHilogWithoutChangingTheDefaultDiagnosticsPlan() throws {
    let descriptor = try #require(
      RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    let hilog = try #require(descriptor.steps.first { $0.stepID == "capture-hilog" })
    let hilogArtifact = try #require(descriptor.artifacts.first { $0.name == "hilog.txt" })

    #expect(hilog.isOptional)
    #expect(
      !hilogArtifact.isRequired,
      "A Viewer capture can deliberately omit HiLog, so its artifact cannot make an otherwise verified UI snapshot incomplete")
    #expect(
      CatalogOperationEffectResolver.stepIsSelected(
        hilog, descriptor: descriptor, inputs: [:])
        == true)
    #expect(
      CatalogOperationEffectResolver.stepIsSelected(
        hilog, descriptor: descriptor, inputs: ["captureHilog": .bool(false)])
        == false)
  }

  @Test func descriptorLookupIsExactAndFailClosed() {
    #expect(RuntimeOperationCatalog.descriptor(id: "observe.device", version: 1) != nil)
    #expect(RuntimeOperationCatalog.descriptor(id: "observe.device", version: 2) == nil)
    #expect(RuntimeOperationCatalog.descriptor(id: "observe.devices", version: 1) == nil)
    #expect(RuntimeOperationCatalog.descriptor(reference: "debug.hap@1") != nil)
    #expect(RuntimeOperationCatalog.descriptor(reference: "debug.hap@0") == nil)
    #expect(RuntimeOperationCatalog.descriptor(reference: "debug.hap") == nil)
    #expect(RuntimeOperationCatalog.descriptor(reference: "debug.hap@x") == nil)
    #expect(RuntimeOperationCatalog.descriptor(reference: "flash.dayu200") != nil)
    #expect(RuntimeOperationCatalog.descriptor(reference: "flash.dayu200@1") == nil)
    #expect(!ArkForgeFlashOperation.contains("flash.dayu200@1"))
    #expect(
      ArkForgeFlashOperation.containsDurableRecordReference("flash.dayu200@1"))
    #expect(RuntimeOperationCatalog.descriptor(reference: "flash.full-restore@1") != nil)
    #expect(RuntimeOperationCatalog.descriptor(reference: "flash.full-restore") == nil)
  }

  @Test func everyStepRespectsWorkflowStepRegistryMinimums() {
    for operation in RuntimeOperationCatalog.operations {
      for step in operation.steps {
        let metadata = WorkflowStepRegistry.metadata(for: step.kind)
        #expect(
          step.effect >= metadata.minimumEffect,
          "\(operation.reference)/\(step.stepID) effect below registry minimum")
        #expect(
          step.cancellation >= metadata.minimumCancellation,
          "\(operation.reference)/\(step.stepID) cancellation below registry minimum")
        #expect(
          step.binding >= metadata.minimumBindingRequirement,
          "\(operation.reference)/\(step.stepID) binding below registry minimum")
      }
    }
  }

  @Test func effectEnvelopeIsConsistentPerOperation() {
    for operation in RuntimeOperationCatalog.operations {
      let stepMax = operation.steps.map(\.effect).max() ?? .hostOnly
      let requiredMax =
        operation.steps.filter { !$0.isOptional }.map(\.effect).max() ?? .hostOnly
      #expect(
        operation.minimumEffect == requiredMax,
        "\(operation.reference): minimum effect must equal max required-step effect")
      #expect(
        operation.permittedEffects.contains(stepMax),
        "\(operation.reference): max step effect must be permitted")
      let permittedMax = operation.permittedEffects.max() ?? .hostOnly
      #expect(
        permittedMax == stepMax,
        "\(operation.reference): permitted max must be reachable by steps")
    }
  }

  /// Every permitted effect names its gate, host-only included. The earlier
  /// rule excluded `hostOnly` while the contract also demanded a non-empty
  /// authorization map, which made a purely host-only operation impossible to
  /// express - the same contract/implementation gap as operation-level
  /// `binding: none` (CHG-2026-054 TASK-HTP-007).
  @Test func authorizationCoversEveryPermittedEffect() {
    for operation in RuntimeOperationCatalog.operations {
      let expected = Set(operation.permittedEffects)
      #expect(
        Set(operation.authorization.keys) == expected,
        "\(operation.reference): authorization keys must cover permitted effects")
      if let policy = operation.authorization[.destructive] {
        #expect(
          policy == .runtimeCapability,
          "\(operation.reference): destructive must use Runtime-owned capability admission")
      }
      for (effect, policy) in operation.authorization where policy == .defaultReadOnly {
        #expect(
          effect <= .readOnly,
          "\(operation.reference): defaultReadOnly may not gate a mutation")
      }
    }
  }

  @Test func publishedDestructiveFlashHasOneCanonicalOperationAndOneAlias() throws {
    let canonical = try #require(
      RuntimeOperationCatalog.descriptor(reference: ArkForgeFlashOperation.canonicalReference))
    let alias = try #require(
      RuntimeOperationCatalog.descriptor(reference: "flash.dayu200"))
    #expect(canonical.permittedEffects == [.destructive])
    #expect(canonical.provider == .arkforge)
    #expect(canonical.aliasFor == nil)
    #expect(canonical.defaultPolicyIssuanceEnabled)
    #expect(canonical.steps.contains { $0.kind == .flashPartition })
    #expect(alias.provider == .arkforge)
    #expect(alias.aliasFor == canonical.reference)
    #expect(alias.steps == canonical.steps)
    #expect(alias.authorization == canonical.authorization)
    #expect(alias.completeOverwriteRecovery == canonical.completeOverwriteRecovery)
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
  @Test func mutatingOperationsCarryTheGuardsOfTheirOwnSubject() {
    for operation in RuntimeOperationCatalog.operations
    where operation.permittedEffects.contains(where: { $0 >= .deviceMutation }) {
      if operation.provider == .workspace {
        // A workspace mutation: no device and serialized against the tree.
        // The checkpoint is the one source-preserving safety primitive: the
        // Runtime issues an exact policy envelope only after materialization.
        // Source-changing operations still require a maintainer grant.
        #expect(
          operation.concurrencyKey == .hostExclusive,
          "\(operation.reference): a workspace mutation is serialized on the host")
        #expect(
          operation.binding == WorkflowBindingRequirement.none,
          "\(operation.reference): a workspace mutation has no device to bind")
        if operation.reference == "workspace.create-checkpoint@1" {
          #expect(operation.authorization[.deviceMutation] == .runtimeCapability)
          #expect(operation.defaultPolicyIssuanceEnabled)
        } else {
          #expect(
            operation.authorization[.deviceMutation] == .standingCapability,
            "\(operation.reference): a source-changing mutation must require a grant")
          #expect(
            !operation.defaultPolicyIssuanceEnabled,
            "\(operation.reference): the runtime must not issue its own workspace grant")
        }
        #expect(
          !operation.steps.contains { $0.binding == .confirmedDevice },
          "\(operation.reference): an unbound operation must contain no device step")
      } else {
        #expect(
          operation.concurrencyKey == .deviceExclusive,
          "\(operation.reference): mutating operations must be device-exclusive")
        #expect(
          operation.binding == .confirmedDevice,
          "\(operation.reference): mutating operations require a confirmed binding")
      }
    }
  }

  /// The half that would otherwise be easy to lose: nothing outside the
  /// workspace provider may mutate without a device binding.
  @Test func onlyWorkspaceMutationsMayBeUnbound() {
    for operation in RuntimeOperationCatalog.operations
    where operation.permittedEffects.contains(where: { $0 >= .deviceMutation })
      && operation.binding == WorkflowBindingRequirement.none
    {
      #expect(
        operation.provider == .workspace,
        "\(operation.reference): only a workspace mutation may be unbound")
    }
  }

  @Test func noInputFieldCarriesAnExecutableSurface() {
    let forbidden: Set<String> = [
      "argv", "shell", "exec", "command", "runhdc", "rawcommand", "executable",
    ]
    for operation in RuntimeOperationCatalog.operations {
      for field in operation.inputs {
        #expect(
          !forbidden.contains(field.name.lowercased()),
          "\(operation.reference): input \(field.name) is a forbidden executable surface")
      }
    }
  }

  @Test func budgetsAndTimeoutsArePresentAndBounded() {
    for operation in RuntimeOperationCatalog.operations {
      #expect(
        (1...7200).contains(operation.timeoutSeconds), "\(operation.reference)")
      #expect(
        (1024...(1 << 30)).contains(operation.outputByteBudget), "\(operation.reference)")
      #expect((1...3).contains(operation.preflightAttempts), "\(operation.reference)")
    }
  }
}

private func expectRegularExpression(
  _ value: String, pattern: String, sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(
    value.range(of: pattern, options: .regularExpression) != nil,
    "\(value) does not match \(pattern)", sourceLocation: sourceLocation)
}

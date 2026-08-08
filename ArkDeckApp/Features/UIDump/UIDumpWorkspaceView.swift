import ArkDeckWorkflows
import Combine
import SwiftUI

/// ArkUI UI Dump's single, leading-edge workflow.
///
/// The current App transport can read production Runtime facts but cannot
/// submit a diagnostics job. The complete form is still useful for reviewing
/// exact target, recipe candidates, policy and artifact separation; its final
/// action stays fail-closed until the published operation carries the accepted
/// window-scoped inputs and a reviewed App submission path exists.
struct UIDumpWorkspaceView: View {
  @ObservedObject var model: UIDumpWorkspaceViewModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        availability
        relatedJobs
        workflowSection(
          number: 1,
          title: string("uiDump.window.title"),
          subtitle: string("uiDump.window.subtitle")
        ) {
          targetAndWindow
        }
        workflowSection(
          number: 2,
          title: string("uiDump.recipe.title"),
          subtitle: string("uiDump.recipe.subtitle")
        ) {
          recipeSelection
        }
        workflowSection(
          number: 3,
          title: string("uiDump.policy.title"),
          subtitle: string("uiDump.policy.subtitle")
        ) {
          policySelection
        }
        workflowSection(
          number: 4,
          title: string("uiDump.review.title"),
          subtitle: string("uiDump.review.subtitle")
        ) {
          review
        }
        scopeNote
      }
      .frame(maxWidth: 960, alignment: .topLeading)
      .padding(20)
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          model.refresh()
        } label: {
          Label(string("uiDump.action.refreshFacts"), systemImage: "arrow.clockwise")
        }
        .accessibilityIdentifier("uiDump.refreshFacts")
        .disabled(model.isRefreshing)
      }
    }
  }

  private var availability: some View {
    GroupBox(string("uiDump.availability.title")) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          availabilityLabel
          Spacer(minLength: 12)
          Text(model.workspace.operation.reference)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }

        HStack(spacing: 16) {
          capability(
            string("uiDump.availability.inventory"),
            supported: model.workspace.operation.supportsWindowInventory)
          capability(
            string("uiDump.availability.screenTree"),
            supported: model.workspace.operation.supportsScreenComponentTree)
          capability(
            string("uiDump.availability.windowRecipes"),
            supported: model.workspace.operation.supportsCanonicalWindowRecipes)
        }

        if !model.workspace.operation.supportsCanonicalWindowRecipes {
          notice(
            string("uiDump.availability.recipeGap"),
            systemImage: "exclamationmark.lock",
            color: .orange,
            identifier: "uiDump.availability.recipeGap")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
  }

  @ViewBuilder
  private var availabilityLabel: some View {
    switch model.workspace.operation.availability {
    case .checking:
      Label(string("uiDump.availability.checking"), systemImage: "hourglass")
        .accessibilityIdentifier("uiDump.availability.status")
    case .available:
      Label(string("uiDump.availability.available"), systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .accessibilityIdentifier("uiDump.availability.status")
    case .unavailable(let reasons):
      VStack(alignment: .leading, spacing: 4) {
        Label(string("uiDump.availability.unavailable"), systemImage: "xmark.octagon.fill")
          .foregroundStyle(.red)
          .accessibilityIdentifier("uiDump.availability.status")
        ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
          Text(reason)
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
      }
    }
  }

  @ViewBuilder
  private var relatedJobs: some View {
    if let failure = model.workspace.jobLoadFailure {
      notice(
        failure,
        systemImage: "exclamationmark.triangle",
        color: .orange,
        identifier: "uiDump.jobs.failure")
    } else if !model.workspace.relatedJobs.isEmpty {
      GroupBox(string("uiDump.jobs.title")) {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(model.workspace.relatedJobs.prefix(3)) { job in
            HStack(spacing: 8) {
              Image(systemName: job.needsAttention ? "exclamationmark.triangle.fill" : "clock")
                .foregroundStyle(job.needsAttention ? .orange : .secondary)
              Text(job.id).font(.callout.monospaced())
              Spacer(minLength: 12)
              Text(job.state).font(.callout)
              Text(job.targetID).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
          }
          Text(string("uiDump.jobs.readOnly"))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
      }
    }
  }

  private var targetAndWindow: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 6) {
        Text(string("uiDump.target.label"))
          .font(.subheadline.weight(.semibold))
        if model.workspace.targets.isEmpty {
          notice(
            model.workspace.targetLoadFailure ?? string("uiDump.target.empty"),
            systemImage: "externaldrive.badge.questionmark",
            color: .secondary,
            identifier: "uiDump.target.empty")
        } else {
          Picker(string("uiDump.target.label"), selection: targetBinding) {
            ForEach(model.workspace.targets) { target in
              Text(target.id).tag(target.id)
            }
          }
          .labelsHidden()
          .frame(maxWidth: 420, alignment: .leading)
          .accessibilityLabel(string("uiDump.target.label"))
          .accessibilityIdentifier("uiDump.target.picker")
        }

        if let target = model.selectedTarget {
          Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
            reviewRow(
              string("uiDump.target.binding"), String(target.bindingRevision), monospaced: true)
            reviewRow(string("uiDump.target.tool"), target.toolVersion, monospaced: true)
            reviewRow(string("uiDump.target.adopted"), target.adoptedAtUTC, monospaced: true)
          }
        }
      }

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(string("uiDump.inventory.title"))
              .font(.subheadline.weight(.semibold))
            Text(string("uiDump.inventory.description"))
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 12)
          Button(string("uiDump.inventory.refresh")) {}
            .accessibilityIdentifier("uiDump.inventory.refresh")
            .disabled(true)
            .help(string("uiDump.inventory.refreshBlocked"))
        }

        HStack(spacing: 10) {
          Image(systemName: "rectangle.on.rectangle.slash")
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 2) {
            Text(string("uiDump.inventory.notLoaded"))
              .font(.callout.weight(.medium))
            Text(string("uiDump.inventory.refreshBlocked"))
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

        DisclosureGroup(string("uiDump.inventory.raw.title")) {
          Text(string("uiDump.inventory.raw.empty"))
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
        .accessibilityIdentifier("uiDump.inventory.raw")
      }

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        Text(string("uiDump.window.manual.label"))
          .font(.subheadline.weight(.semibold))
        TextField(string("uiDump.window.manual.placeholder"), text: windowIDBinding)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 300)
          .accessibilityLabel(string("uiDump.window.manual.label"))
          .accessibilityHint(string("uiDump.window.manual.hint"))
          .accessibilityIdentifier("uiDump.window.manual")
        Text(windowValidationMessage)
          .font(.footnote)
          .foregroundStyle(windowIDIsValid ? Color.secondary : Color.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("uiDump.window.validation")
      }
    }
  }

  private var recipeSelection: some View {
    VStack(alignment: .leading, spacing: 10) {
      // The section's live echo: the exact hidumper arguments the current
      // recipe and window id resolve to, updated as either changes.
      HStack {
        Spacer(minLength: 12)
        Text(
          model.selectedRecipe.displayArguments(
            windowID: model.manualWindowID, componentID: model.componentID)
        )
        .font(.callout.monospaced())
        .foregroundStyle(Color.accentColor)
        .textSelection(.enabled)
        .accessibilityIdentifier("uiDump.recipe.liveArguments")
      }
      ForEach(UIDumpRecipeCatalog.definitions) { definition in
        recipeRow(definition)
      }
      notice(
        string("uiDump.recipe.candidateNote"),
        systemImage: "info.circle",
        color: .secondary,
        identifier: "uiDump.recipe.candidateNote")

      if model.selectedRecipe.requiresComponentID {
        VStack(alignment: .leading, spacing: 6) {
          Text(string("uiDump.component.label"))
            .font(.subheadline.weight(.semibold))
          TextField(string("uiDump.component.placeholder"), text: componentIDBinding)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 300)
            .accessibilityLabel(string("uiDump.component.label"))
            .accessibilityHint(string("uiDump.component.hint"))
            .accessibilityIdentifier("uiDump.component.input")
          Text(componentValidationMessage)
            .font(.footnote)
            .foregroundStyle(componentIDIsValid ? Color.secondary : Color.red)
            .accessibilityIdentifier("uiDump.component.validation")
        }
        .padding(.top, 4)
      }
    }
  }

  private var policySelection: some View {
    VStack(alignment: .leading, spacing: 10) {
      policyRow(.unchanged)
      policyRow(.temporaryRestore)
      policyRow(.persistentlyEnabled)

      // The second confirmation is an answer, not an acknowledgement gate:
      // a danger callout stating the cost, then Cancel or an explicit
      // destructive-styled confirm. No checkbox stands between them.
      if model.debugPolicy == .persistentlyEnabled {
        if model.persistentEnableConfirmed {
          Label(
            string("uiDump.policy.persist.confirmed"),
            systemImage: "checkmark.circle.fill"
          )
          .font(.callout)
          .foregroundStyle(.orange)
          .padding(.leading, 28)
          .accessibilityIdentifier("uiDump.policy.persist.confirmed")
        } else {
          VStack(alignment: .leading, spacing: 10) {
            notice(
              string("uiDump.policy.persist.callout"),
              systemImage: "exclamationmark.triangle.fill",
              color: .red,
              identifier: "uiDump.policy.persist.callout")
            HStack(spacing: 10) {
              Button(string("uiDump.policy.persist.cancel")) {
                model.setDebugPolicy(.unchanged)
              }
              .accessibilityIdentifier("uiDump.policy.persist.cancel")
              Button(role: .destructive) {
                model.setPersistentEnableConfirmed(true)
              } label: {
                Text(string("uiDump.policy.persist.confirm"))
              }
              .accessibilityIdentifier("uiDump.policy.persist.confirm")
            }
          }
          .padding(.leading, 28)
        }
      }

      notice(
        string("uiDump.policy.originalUnknown"),
        systemImage: "lock.trianglebadge.exclamationmark",
        color: .orange,
        identifier: "uiDump.policy.originalUnknown")
    }
  }

  private var review: some View {
    VStack(alignment: .leading, spacing: 14) {
      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
        reviewRow(
          string("uiDump.review.target"),
          model.selectedTarget?.id ?? string("uiDump.value.notSelected"),
          monospaced: model.selectedTarget != nil)
        reviewRow(
          string("uiDump.review.binding"),
          model.selectedTarget.map { String($0.bindingRevision) } ?? string("uiDump.value.pending"),
          monospaced: model.selectedTarget != nil)
        reviewRow(string("uiDump.review.recipe"), recipeName(model.selectedRecipe.id))
        reviewRow(
          string("uiDump.review.arguments"),
          model.selectedRecipe.displayArguments(
            windowID: model.manualWindowID, componentID: model.componentID),
          monospaced: true)
        reviewRow(string("uiDump.review.policy"), policyName(model.debugPolicy))
        reviewRow(
          string("uiDump.review.effect"),
          "\(model.workspace.operation.minimumEffect) (\(string("uiDump.review.catalogFloor")))",
          monospaced: true)
      }

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        Text(string("uiDump.artifacts.title"))
          .font(.subheadline.weight(.semibold))
        Text(string("uiDump.artifacts.description"))
          .font(.footnote)
          .foregroundStyle(.secondary)
        if model.runtimeArtifacts.isEmpty {
          Table(artifactExpectations) {
            TableColumn(string("uiDump.artifacts.name")) { artifact in
              Text(artifact.name).font(.callout.monospaced())
            }
            TableColumn(string("uiDump.artifacts.role")) { artifact in
              Text(artifact.role)
            }
            TableColumn(string("uiDump.artifacts.origin")) { artifact in
              Text(artifact.origin)
            }
          }
          .frame(minHeight: 145)
          .accessibilityIdentifier("uiDump.artifacts.table")
          if let failure = model.runtimeArtifactFailures.first {
            notice(
              failure,
              systemImage: "exclamationmark.triangle",
              color: .orange,
              identifier: "uiDump.artifacts.runtimeFailure")
          }
        } else {
          Table(model.runtimeArtifacts) {
            TableColumn(string("uiDump.artifacts.name")) { artifact in
              Text(artifact.name).font(.callout.monospaced())
            }
            TableColumn(string("uiDump.artifacts.role")) { artifact in
              Text(artifact.role ?? "—")
            }
            TableColumn(string("uiDump.artifacts.size")) { artifact in
              Text(ByteCountFormatter.string(fromByteCount: artifact.byteCount, countStyle: .file))
                .monospacedDigit()
            }
            TableColumn(string("uiDump.artifacts.sha256")) { artifact in
              Text(artifact.sha256)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .help(artifact.sha256)
            }
            TableColumn(string("uiDump.artifacts.privacy")) { artifact in
              Text(artifact.privacy)
            }
            TableColumn(string("uiDump.artifacts.status")) { artifact in
              Text(artifact.status)
            }
          }
          .frame(minHeight: 145)
          .accessibilityIdentifier("uiDump.artifacts.table")
        }
        Text(string("uiDump.artifacts.sensitivityNote"))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("uiDump.artifacts.sensitivityNote")
      }

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        if blockers.isEmpty {
          notice(
            string("uiDump.review.ready"),
            systemImage: "checkmark.circle.fill",
            color: .green,
            identifier: "uiDump.review.ready")
        } else {
          Text(string("uiDump.review.blockers"))
            .font(.subheadline.weight(.semibold))
          ForEach(Array(blockers.enumerated()), id: \.offset) { _, blocker in
            Label(blocker, systemImage: "xmark.circle")
              .font(.callout)
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        HStack {
          Spacer()
          Button(string("uiDump.action.run")) {}
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("uiDump.run")
            .disabled(true)
            .help(blockers.joined(separator: "\n"))
        }
        Text(string("uiDump.review.noDispatch"))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
  }

  // A hard boundary, not a roadmap: one fixed sentence at the page footer.
  // Greyed rows for Fault/Crash and system snapshots would read as disabled
  // entries — as if the capabilities existed and were merely switched off.
  private var scopeNote: some View {
    Text(string("uiDump.scope.note"))
      .font(.footnote)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("uiDump.scope.note")
  }

  private var blockers: [String] {
    var values: [String] = []
    switch model.workspace.operation.availability {
    case .checking:
      values.append(string("uiDump.blocker.checking"))
    case .unavailable(let reasons):
      values.append(string("uiDump.blocker.unavailable"))
      values.append(contentsOf: reasons)
    case .available:
      break
    }
    if model.selectedTarget == nil {
      values.append(string("uiDump.blocker.target"))
    }
    if !windowIDIsValid {
      values.append(string("uiDump.blocker.window"))
    }
    if model.selectedRecipe.requiresComponentID, !componentIDIsValid {
      values.append(string("uiDump.blocker.component"))
    }
    if model.debugPolicy == .persistentlyEnabled, !model.persistentEnableConfirmed {
      values.append(string("uiDump.blocker.persistConfirmation"))
    }
    if !model.workspace.operation.supportsCanonicalWindowRecipes {
      values.append(string("uiDump.blocker.recipeInputs"))
    }
    values.append(string("uiDump.blocker.readOnlyTransport"))
    return values
  }

  private var artifactExpectations: [UIDumpExpectedArtifact] {
    [
      UIDumpExpectedArtifact(
        id: "stdout",
        name: string("uiDump.artifacts.stdout.name"),
        role: string("uiDump.artifacts.raw"),
        origin: string("uiDump.artifacts.stdout.origin")),
      UIDumpExpectedArtifact(
        id: "sidecar",
        name: string("uiDump.artifacts.sidecar.name"),
        role: string("uiDump.artifacts.raw"),
        origin: string("uiDump.artifacts.sidecar.origin")),
      UIDumpExpectedArtifact(
        id: "merged",
        name: string("uiDump.artifacts.merged.name"),
        role: string("uiDump.artifacts.derived"),
        origin: string("uiDump.artifacts.merged.origin")),
    ]
  }

  private var targetBinding: Binding<String> {
    Binding(get: { model.selectedTargetID }, set: { model.setTargetID($0) })
  }

  private var windowIDBinding: Binding<String> {
    Binding(get: { model.manualWindowID }, set: { model.setManualWindowID($0) })
  }

  private var componentIDBinding: Binding<String> {
    Binding(get: { model.componentID }, set: { model.setComponentID($0) })
  }

  private var windowIDIsValid: Bool {
    if case .valid = UIDumpIdentifierValidator.validate(model.manualWindowID) { return true }
    return false
  }

  private var componentIDIsValid: Bool {
    if case .valid = UIDumpIdentifierValidator.validate(model.componentID) { return true }
    return false
  }

  private var windowValidationMessage: String {
    validationMessage(
      UIDumpIdentifierValidator.validate(model.manualWindowID),
      validKey: "uiDump.window.manual.valid")
  }

  private var componentValidationMessage: String {
    validationMessage(
      UIDumpIdentifierValidator.validate(model.componentID),
      validKey: "uiDump.component.valid")
  }

  private func validationMessage(
    _ validation: UIDumpIdentifierValidation,
    validKey: String
  ) -> String {
    switch validation {
    case .valid:
      string(validKey)
    case .invalid(.missing):
      string("uiDump.validation.missing")
    case .invalid(.notDecimal):
      string("uiDump.validation.decimal")
    case .invalid(.tooLong):
      string("uiDump.validation.tooLong")
    }
  }

  private func workflowSection<Content: View>(
    number: Int,
    title: String,
    subtitle: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Text(String(number))
        .font(.headline.monospacedDigit())
        .foregroundStyle(.white)
        .frame(width: 28, height: 28)
        .background(Color.accentColor, in: Circle())
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.title3.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
          Text(subtitle)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
      .background(.background, in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .stroke(.separator.opacity(0.6), lineWidth: 1)
      }
    }
  }

  private func capability(_ title: String, supported: Bool) -> some View {
    Label(title, systemImage: supported ? "checkmark.circle.fill" : "xmark.circle.fill")
      .font(.callout)
      .foregroundStyle(supported ? .green : .secondary)
      .accessibilityValue(
        supported ? string("uiDump.value.supported") : string("uiDump.value.unavailable"))
  }

  private func recipeRow(_ definition: UIDumpRecipeDefinition) -> some View {
    let selected = model.selectedRecipeID == definition.id
    return Button {
      model.setRecipe(definition.id)
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(selected ? Color.accentColor : Color.secondary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(recipeName(definition.id))
            .font(.callout.weight(.semibold))
          Text(recipeDescription(definition.id))
            .font(.footnote)
            .foregroundStyle(.secondary)
          Text(
            definition.displayArguments(
              windowID: model.manualWindowID, componentID: model.componentID)
          )
          .font(.callout.monospaced())
          .textSelection(.enabled)
        }
        Spacer(minLength: 8)
        Text(string("uiDump.recipe.candidate"))
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.orange)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(.orange.opacity(0.12), in: Capsule())
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(selected ? Color.accentColor.opacity(0.08) : Color.clear)
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(recipeName(definition.id))
    .accessibilityValue(
      selected ? string("uiDump.value.selected") : string("uiDump.value.notSelected")
    )
    .accessibilityHint(definition.displayArguments(windowID: nil, componentID: nil))
    .accessibilityIdentifier("uiDump.recipe.\(definition.id.rawValue)")
  }

  private func policyRow(_ policy: UIDumpDebugParameterPolicy) -> some View {
    let selected = model.debugPolicy == policy
    let enabled = policy != .temporaryRestore || model.canUseTemporaryRestore
    return Button {
      model.setDebugPolicy(policy)
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(selected ? Color.accentColor : Color.secondary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(policyName(policy)).font(.callout.weight(.semibold))
          Text(policyDescription(policy))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        Text(
          policy.requiresMutation
            ? string("uiDump.policy.mutation") : string("uiDump.policy.readOnly")
        )
        .font(.caption2.weight(.semibold))
        .foregroundStyle(policy.requiresMutation ? .orange : .green)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(selected ? Color.accentColor.opacity(0.08) : Color.clear)
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .accessibilityLabel(policyName(policy))
    .accessibilityValue(
      selected ? string("uiDump.value.selected") : string("uiDump.value.notSelected")
    )
    .accessibilityIdentifier("uiDump.policy.\(policy.rawValue)")
  }

  private func notice(
    _ text: String,
    systemImage: String,
    color: Color,
    identifier: String
  ) -> some View {
    Label {
      Text(text).fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: systemImage).foregroundStyle(color)
    }
    .font(.callout)
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityIdentifier(identifier)
  }

  private func reviewRow(
    _ label: String,
    _ value: String,
    monospaced: Bool = false
  ) -> some View {
    GridRow(alignment: .firstTextBaseline) {
      Text(label)
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.trailing)
      Text(value)
        .font(monospaced ? .body.monospaced() : .body)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .gridColumnAlignment(.leading)
    }
  }

  private func recipeName(_ recipe: UIDumpRecipeID) -> String {
    string("uiDump.recipe.\(recipe.rawValue).name")
  }

  private func recipeDescription(_ recipe: UIDumpRecipeID) -> String {
    string("uiDump.recipe.\(recipe.rawValue).description")
  }

  private func policyName(_ policy: UIDumpDebugParameterPolicy) -> String {
    string("uiDump.policy.\(policy.rawValue).name")
  }

  private func policyDescription(_ policy: UIDumpDebugParameterPolicy) -> String {
    string("uiDump.policy.\(policy.rawValue).description")
  }

  private func string(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "UIDumpLocalizable")
  }
}

@MainActor
final class UIDumpWorkspaceViewModel: ObservableObject {
  @Published private(set) var workspace = UIDumpWorkspacePresentation.loading
  @Published private(set) var selectedTargetID = ""
  @Published private(set) var manualWindowID = ""
  @Published private(set) var selectedRecipeID = UIDumpRecipeID.elementTree
  @Published private(set) var componentID = ""
  @Published private(set) var debugPolicy = UIDumpDebugParameterPolicy.unchanged
  @Published private(set) var persistentEnableConfirmed = false
  @Published private(set) var isRefreshing = false
  @Published private(set) var artifactsByJobID: [String: [RuntimeArtifactPresentation]] = [:]
  @Published private(set) var artifactFailuresByJobID: [String: String] = [:]

  let canUseTemporaryRestore = false
  private let provider: any UIDumpApplicationProviding
  private let detailProvider: any RuntimeJobDetailApplicationProviding

  init(
    provider: any UIDumpApplicationProviding,
    detailProvider: (any RuntimeJobDetailApplicationProviding)? = nil
  ) {
    self.provider = provider
    self.detailProvider = detailProvider ?? RuntimeJobDetailApplicationFacade.make()
  }

  var selectedTarget: UIDumpTargetPresentation? {
    workspace.targets.first { $0.id == selectedTargetID }
  }

  var runtimeArtifacts: [RuntimeArtifactPresentation] {
    workspace.relatedJobs
      .filter { selectedTargetID.isEmpty || $0.targetID == selectedTargetID }
      .flatMap { artifactsByJobID[$0.id] ?? [] }
  }

  var runtimeArtifactFailures: [String] {
    workspace.relatedJobs
      .filter { selectedTargetID.isEmpty || $0.targetID == selectedTargetID }
      .compactMap { artifactFailuresByJobID[$0.id] }
  }

  var selectedRecipe: UIDumpRecipeDefinition {
    UIDumpRecipeCatalog.definition(selectedRecipeID)
  }

  func refresh() {
    guard !isRefreshing else { return }
    isRefreshing = true
    let provider = provider
    let detailProvider = detailProvider
    Task { [weak self] in
      let next = await provider.refreshWorkspace()
      guard let self else { return }
      defer { self.isRefreshing = false }
      guard !Task.isCancelled else { return }
      let previousTarget = self.selectedTarget
      let nextTargetID =
        next.targets.contains(where: { $0.id == self.selectedTargetID })
        ? self.selectedTargetID
        : next.targets.first?.id ?? ""
      self.workspace = next
      self.selectedTargetID = nextTargetID
      var artifacts: [String: [RuntimeArtifactPresentation]] = [:]
      var failures: [String: String] = [:]
      for job in next.relatedJobs.prefix(3) {
        let detail = await detailProvider.loadJobDetail(
          jobID: job.id,
          operationReference: UIDumpApplicationFacade.operationReference)
        switch detail.artifactAvailability {
        case .available:
          artifacts[job.id] = detail.artifacts
        case .unavailable(let reason):
          failures[job.id] = reason
        }
      }
      guard !Task.isCancelled else { return }
      self.artifactsByJobID = artifacts
      self.artifactFailuresByJobID = failures
      if previousTarget != self.selectedTarget {
        self.clearTargetScopedInput()
      }
    }
  }

  func setTargetID(_ targetID: String) {
    guard selectedTargetID != targetID else { return }
    selectedTargetID = targetID
    clearTargetScopedInput()
  }

  func setManualWindowID(_ value: String) {
    manualWindowID = value
  }

  func setRecipe(_ recipe: UIDumpRecipeID) {
    guard selectedRecipeID != recipe else { return }
    selectedRecipeID = recipe
    if !selectedRecipe.requiresComponentID {
      componentID = ""
    }
  }

  func setComponentID(_ value: String) {
    componentID = value
  }

  func setDebugPolicy(_ policy: UIDumpDebugParameterPolicy) {
    guard policy != .temporaryRestore || canUseTemporaryRestore else { return }
    guard debugPolicy != policy else { return }
    debugPolicy = policy
    persistentEnableConfirmed = false
  }

  func setPersistentEnableConfirmed(_ confirmed: Bool) {
    guard debugPolicy == .persistentlyEnabled else { return }
    persistentEnableConfirmed = confirmed
  }

  private func clearTargetScopedInput() {
    manualWindowID = ""
    componentID = ""
    persistentEnableConfirmed = false
  }
}

private struct UIDumpExpectedArtifact: Identifiable {
  let id: String
  let name: String
  let role: String
  let origin: String
}

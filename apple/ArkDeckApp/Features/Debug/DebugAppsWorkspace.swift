import AppKit
import ArkDeckClientKit
import ArkDeckCore
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct DebugAppsWorkspace: View {
  var model: DebugWorkspaceViewModel
  let operation: DebugOperationPresentation?
  let target: DebugTargetPresentation?
  let relatedJobs: [DebugJobPresentation]
  let runtimeProbe: DebugRuntimeProbeSnapshot?
  let probeFailure: String?
  let runtimeArtifacts: [DebugRuntimeArtifactRow]

  @State private var isImporterPresented = false
  @State private var selectedHAPURL: URL?
  @State private var isSelectingAdditionalHAP = false
  @State private var additionalHAPURLs: [URL] = []
  @State private var selectionError: String?
  @State private var bundleName = ""
  @State private var abilityName = ""
  private let installPolicy = "installOrReplace"
  @State private var cleanupPolicy = "uninstall"
  @State private var postRunState = "stopped"
  @State private var captureDiagnostics = true
  @State private var diagnosticsDuration = 30
  @State private var isPlanRequestExpanded = false

  private var feedbackMatchesTarget: Bool {
    model.hapFeedbackMatches(target: target)
  }

  private var scopedActiveJobID: String? {
    feedbackMatchesTarget ? model.activeHAPJobID : nil
  }

  private var scopedTerminal: DebugLogJobTerminalPresentation? {
    feedbackMatchesTarget ? model.hapTerminal : nil
  }

  private var currentRuntimeProbe: DebugRuntimeProbeSnapshot? {
    guard let target, let runtimeProbe,
      runtimeProbe.targetID == target.id,
      runtimeProbe.bindingRevision == target.bindingRevision
    else { return nil }
    return runtimeProbe
  }

  var body: some View {
    WorkspacePage(maximumWidth: WorkspaceMetrics.pageMaxWidth) {
      WorkspaceColumns(
        spacing: WorkspaceMetrics.sectionGap,
        leadingRatio: WorkspaceMetrics.splitLeadingColumnRatio
      ) {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
          packageSection
          identitySection
        }
        .accessibilityElement(children: .contain)
      } trailing: {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
          lifecycleSection
          planSection
        }
        // Keep the warning in its lifecycle column. Otherwise macOS merges
        // nearby static text from both columns and drops the notice identity.
        .accessibilityElement(children: .contain)
      }
      inventorySection
      if !runtimeArtifacts.isEmpty { artifactsSection }
      DebugRecentJobsSection(model: model, jobs: relatedJobs)
    }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: (isSelectingAdditionalHAP ? ["hap", "hsp"] : ["hap"])
        .map { UTType(filenameExtension: $0) ?? .data },
      allowsMultipleSelection: isSelectingAdditionalHAP
    ) { result in
      if isSelectingAdditionalHAP {
        handleAdditionalHAPSelection(result)
      } else {
        handleHAPSelection(result)
      }
    }
  }

  private var packageSection: some View {
    WorkspaceSection(
      Text(DebugL10n.text("debug.apps.package.title")),
      accessory: { DebugAvailabilityStatus(operation: operation) }
    ) {
      DebugAvailabilityNotice(operation: operation)
      LabeledContent(DebugL10n.text("debug.apps.target")) {
        Text(target?.id ?? DebugL10n.text("debug.target.none"))
          .font(WorkspaceFont.monospacedValue)
      }
      Button {
        isSelectingAdditionalHAP = false
        isImporterPresented = true
      } label: {
        Label(DebugL10n.text("debug.apps.chooseHAP"), systemImage: "doc.badge.plus")
      }
      .disabled(model.isSubmittingHAP)
      .accessibilityIdentifier("debug.apps.entry.choose")
      Text(selectedHAPURL?.lastPathComponent ?? DebugL10n.text("debug.apps.noHAP"))
        .font(WorkspaceFont.monospacedValue)
        .foregroundStyle(selectedHAPURL == nil ? .secondary : .primary)
        .textSelection(.enabled)
        .help(selectedHAPURL?.path ?? "")
        // Keep the selected filename separate from the following package
        // instructions when macOS coalesces adjacent static text.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(
          selectedHAPURL?.lastPathComponent ?? DebugL10n.text("debug.apps.noHAP"))
        .accessibilityIdentifier("debug.apps.entry.name")
      additionalPackages
      if selectedHAPURL != nil {
        Button(DebugL10n.text("debug.apps.clearSelection")) {
          selectedHAPURL = nil
          additionalHAPURLs = []
          selectionError = nil
        }
        .disabled(model.isSubmittingHAP)
        .accessibilityIdentifier("debug.apps.packages.clear")
      }
      if let selectionError {
        WorkspaceNotice(tone: .danger, identifier: "debug.apps.selection.error") {
          Text(selectionError)
        }
      }
      Text(DebugL10n.text("debug.apps.localOnly"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var additionalPackages: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
      Text(DebugL10n.text("debug.apps.additional.title"))
        .font(WorkspaceFont.label)
      Text(DebugL10n.text("debug.apps.additional.note"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(additionalHAPURLs.enumerated(), id: \.element) { index, url in
        HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.contentGap) {
          Text(url.lastPathComponent)
            .font(WorkspaceFont.monospacedValue)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(url.path)
            .accessibilityIdentifier("debug.apps.additional.file.\(index)")
          Spacer(minLength: 0)
          Button {
            additionalHAPURLs.removeAll { $0 == url }
            selectionError = nil
          } label: {
            Label(DebugL10n.text("debug.apps.additional.remove"), systemImage: "minus.circle")
          }
          .disabled(model.isSubmittingHAP)
          .accessibilityLabel(
            String(
              localized: LocalizedStringResource.DebugLocalizable.debugAppsAdditionalRemoveNamed(
                url.lastPathComponent))
          )
          .accessibilityIdentifier("debug.apps.additional.remove.\(index)")
        }
        .accessibilityElement(children: .contain)
      }
      Button(DebugL10n.text("debug.apps.additional.add")) {
        isSelectingAdditionalHAP = true
        isImporterPresented = true
      }
      .disabled(
        selectedHAPURL == nil || model.isSubmittingHAP
          || additionalHAPURLs.count >= DebugHAPPackageSelection.maximumAdditionalPackages
      )
      .accessibilityIdentifier("debug.apps.additional.add")
    }
    .accessibilityElement(children: .contain)
  }

  private var identitySection: some View {
    WorkspaceSection(Text(DebugL10n.text("debug.apps.identity.title"))) {
      LabeledContent(DebugL10n.text("debug.apps.bundle")) {
        TextField(
          DebugL10n.text("debug.apps.bundle"), text: $bundleName,
          prompt: Text("com.example.app")
        )
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("debug.apps.bundle")
      }
      LabeledContent(DebugL10n.text("debug.apps.ability")) {
        TextField(
          DebugL10n.text("debug.apps.ability"), text: $abilityName,
          prompt: Text("EntryAbility")
        )
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("debug.apps.ability")
      }
      // The note below promises schema validation; these two fields are the
      // argv-adjacent inputs on this tab, so the gate is applied here, not
      // deferred to a future submit path.
      if let invalid = invalidIdentityFieldNames {
        WorkspaceNotice(tone: .danger, identifier: "debug.apps.identity.invalid") {
          Text(
            String(
              localized: LocalizedStringResource.DebugLocalizable.debugTypedInvalidIdentifier(
                invalid)))
        }
      }
      Text(DebugL10n.text("debug.apps.identity.note"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var lifecycleSection: some View {
    WorkspaceSection(Text(DebugL10n.text("debug.apps.lifecycle.title"))) {
      LabeledContent(DebugL10n.text("debug.apps.installPolicy")) {
        Text(DebugL10n.text("debug.apps.install.replace"))
      }
      Picker(DebugL10n.text("debug.apps.cleanupPolicy"), selection: $cleanupPolicy) {
        Text(DebugL10n.text("debug.apps.cleanup.uninstall")).tag("uninstall")
        Text(DebugL10n.text("debug.apps.cleanup.retain")).tag("retain")
      }
      .accessibilityIdentifier("debug.apps.cleanupPolicy")
      Picker(DebugL10n.text("debug.apps.postRun"), selection: $postRunState) {
        Text(DebugL10n.text("debug.apps.postRun.stopped")).tag("stopped")
        Text(DebugL10n.text("debug.apps.postRun.running")).tag("running")
      }
      .accessibilityIdentifier("debug.apps.postRun")
      if cleanupPolicy == "uninstall", postRunState == "running" {
        WorkspaceNotice(tone: .warning, identifier: "debug.apps.runningCleanupHint") {
          Text(DebugL10n.text("debug.apps.runningCleanupHint"))
        }
      }
      Toggle(DebugL10n.text("debug.apps.captureDiagnostics"), isOn: $captureDiagnostics)
      if captureDiagnostics {
        Stepper(
          String(
            localized: LocalizedStringResource.DebugLocalizable.debugAppsDiagnosticsDuration(
              Int32(clamping: diagnosticsDuration))),
          value: $diagnosticsDuration, in: 1...300)
      }
      // What this tab changes on the device is a warning, not a paragraph of
      // body text: the notice carries symbol, tone and wording together the
      // way spec §4.4 asks.
      WorkspaceNotice(
        tone: .warning, symbol: "exclamationmark.shield",
        identifier: "debug.apps.mutationScope"
      ) {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
          Text(DebugL10n.text("debug.apps.mutationScope"))
            .font(WorkspaceFont.secondary.weight(.medium))
          Text(DebugL10n.text("debug.apps.mutationDetail"))
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var planSection: some View {
    WorkspaceSection(Text(DebugL10n.text("debug.apps.plan.title"))) {
      planRequestDisclosure
      if let operation {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
          ForEach(operation.steps) { step in
            planStepRow(step, isLast: step.id == operation.steps.last?.id)
          }
        }
      }
      planActionRow
      planStatus
    }
  }

  /// The lifecycle controls above already state each policy in words; the
  /// exact typed inputs stay available but no longer repeat the whole form as
  /// a mono key/value list above the plan itself.
  private var planRequestDisclosure: some View {
    DisclosureGroup(isExpanded: $isPlanRequestExpanded) {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
        DebugCodeRow(
          label: DebugL10n.text("debug.availability.operation"),
          value: DebugApplicationFacade.debugHAPReference)
        DebugCodeRow(
          label: DebugL10n.text("debug.apps.package.title"),
          value: selectedHAPURL?.lastPathComponent ?? "—")
        DebugCodeRow(
          label: DebugL10n.text("debug.apps.additional.title"),
          value: additionalHAPURLs.isEmpty
            ? "—"
            : additionalHAPURLs.map(\.lastPathComponent).joined(separator: "\n"))
        DebugCodeRow(label: "bundleName", value: bundleName.isEmpty ? "—" : bundleName)
        DebugCodeRow(label: "abilityName", value: abilityName.isEmpty ? "—" : abilityName)
        DebugCodeRow(label: "installPolicy", value: installPolicy)
        DebugCodeRow(label: "cleanupPolicy", value: cleanupPolicy)
        DebugCodeRow(label: "postRunAbilityState", value: postRunState)
        DebugCodeRow(label: "captureDiagnostics", value: String(captureDiagnostics))
        DebugCodeRow(label: "diagnosticsDurationSeconds", value: String(diagnosticsDuration))
        DebugCodeRow(label: "portForwardProfile", value: "none")
      }
      .padding(.top, WorkspaceMetrics.rowGap)
    } label: {
      Text(DebugL10n.text("debug.logs.request.title"))
        .font(WorkspaceFont.label)
        .foregroundStyle(.secondary)
    }
    .accessibilityIdentifier("debug.apps.request")
  }

  private func planStepRow(_ step: DebugStepPresentation, isLast: Bool) -> some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
      HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.contentGap) {
        Image(systemName: effectSymbol(step.effect))
          .frame(width: 18)
          .foregroundStyle(effectColor(step.effect))
        VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
          Text(step.id).font(.callout.monospaced().weight(.medium))
          Text("\(step.kind) · \(step.effect)")
            .font(WorkspaceFont.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        if step.isOptional {
          Text(DebugL10n.text("debug.optional"))
            .font(WorkspaceFont.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary, in: .capsule)
        }
      }
      if !isLast { Divider() }
    }
  }

  private var planActionRow: some View {
    HStack(spacing: WorkspaceMetrics.contentGap) {
      if feedbackMatchesTarget && model.isSubmittingHAP {
        ProgressView().controlSize(.small)
        Text(
          DebugL10n.text(
            scopedActiveJobID == nil
              ? "debug.apps.importing" : "debug.apps.running")
        )
        .font(WorkspaceFont.secondary)
        if let jobID = scopedActiveJobID {
          Text(jobID)
            .font(WorkspaceFont.monospacedDense)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 0)
          Button(DebugL10n.text("debug.action.cancel")) { model.cancelHAP() }
            .disabled(model.isCancellingHAP)
            .accessibilityIdentifier("debug.apps.cancel")
        }
      } else {
        Button(DebugL10n.text("debug.apps.run")) {
          guard let target, let selectedHAPURL else { return }
          model.submitHAP(
            target: target,
            fileURL: selectedHAPURL,
            additionalFileURLs: additionalHAPURLs,
            bundleName: bundleName,
            abilityName: abilityName,
            installPolicy: installPolicy,
            cleanupPolicy: cleanupPolicy,
            postRunAbilityState: postRunState,
            captureDiagnostics: captureDiagnostics,
            diagnosticsDurationSeconds: diagnosticsDuration)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSubmit)
        .accessibilityIdentifier("debug.apps.run")
        Spacer(minLength: 0)
      }
    }
  }

  @ViewBuilder
  private var planStatus: some View {
    if feedbackMatchesTarget, let failure = model.hapFailure {
      Label(failure, systemImage: "xmark.octagon")
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
    if let terminal = scopedTerminal {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
        Label(
          "\(terminal.state) · \(terminal.jobID)",
          systemImage: terminal.state == "succeeded"
            ? "checkmark.circle.fill" : "exclamationmark.circle"
        )
        if let failure = terminal.operationFailure {
          Text(DebugL10n.text("debug.failure.\(failure.code.rawValue)"))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("debug.apps.typedFailure")
        }
      }
      .font(WorkspaceFont.secondary)
      .foregroundStyle(terminal.state == "succeeded" ? .green : .orange)
    }
  }

  private var inventorySection: some View {
    WorkspaceSection(Text(DebugL10n.text("debug.apps.inventory.title"))) {
      HStack {
        Text(DebugL10n.text("debug.apps.inventory.package"))
        Spacer()
        Text(DebugL10n.text("debug.apps.inventory.pid"))
          .frame(width: 72, alignment: .trailing)
        Text(DebugL10n.text("debug.apps.inventory.debuggable"))
          .frame(width: 100, alignment: .trailing)
      }
      .font(WorkspaceFont.label)
      .foregroundStyle(.secondary)
      Divider()
      if let currentRuntimeProbe, !currentRuntimeProbe.packages.isEmpty {
        ForEach(currentRuntimeProbe.packages, id: \.self) { package in
          HStack {
            Text(package).font(WorkspaceFont.monospacedValue).textSelection(.enabled)
            Spacer()
            Text(DebugL10n.text("debug.availability.unavailable"))
              .font(WorkspaceFont.tabularSecondary)
              .frame(width: 72, alignment: .trailing)
              .foregroundStyle(.secondary)
            Text(DebugL10n.text("debug.availability.unavailable"))
              .font(WorkspaceFont.body)
              .frame(width: 100, alignment: .trailing)
              .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
        }
      } else {
        ContentUnavailableView {
          Label(DebugL10n.text("debug.apps.inventory.empty"), systemImage: "app.dashed")
        } description: {
          Text(probeFailure ?? DebugL10n.text("debug.apps.inventory.empty.detail"))
        }
        .frame(minHeight: 120)
      }
      if let warnings = currentRuntimeProbe?.warnings, !warnings.isEmpty {
        Text(warnings.joined(separator: " · "))
          .font(WorkspaceFont.monospacedDense)
          .foregroundStyle(.orange)
          .textSelection(.enabled)
      }
      inventoryActions
    }
  }

  /// Per-package start / stop / uninstall are drawn because the design defines
  /// them, but no published operation exposes them. They stay in one row with
  /// the reason they cannot run, rather than three bare disabled buttons that
  /// read as a broken build.
  private var inventoryActions: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
      HStack {
        Button(DebugL10n.text("debug.apps.action.start")) {}.disabled(true)
        Button(DebugL10n.text("debug.apps.action.stop")) {}.disabled(true)
        Spacer()
        Button(DebugL10n.text("debug.apps.action.uninstall"), role: .destructive) {}
          .disabled(true)
      }
      DebugBlockedReason(text: DebugL10n.text("debug.blocked.packageLifecycle"))
    }
  }

  private var artifactsSection: some View {
    WorkspaceSection(
      Text(DebugL10n.text("debug.apps.artifacts.title")),
      spacing: WorkspaceMetrics.tightGap
    ) {
      ForEach(runtimeArtifacts) { row in
        HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.contentGap) {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
            Text(row.artifact.name).font(WorkspaceFont.monospacedValue)
            Text("\(row.artifact.status) · \(row.artifact.privacy) · \(row.jobID)")
              .font(WorkspaceFont.caption)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: WorkspaceMetrics.contentGap)
          Text(
            ByteCountFormatter.string(
              fromByteCount: row.artifact.byteCount, countStyle: .file)
          )
          .font(WorkspaceFont.monospacedDense.monospacedDigit())
          Text(String(row.artifact.sha256.prefix(12)))
            .font(WorkspaceFont.monospacedDense)
            .help(row.artifact.sha256)
        }
        .accessibilityElement(children: .combine)
      }
    }
  }

  private var operationIsAvailable: Bool {
    guard let operation else { return false }
    if case .available = operation.availability { return true }
    return false
  }

  private var canSubmit: Bool {
    target != nil && selectedHAPURL != nil && operationIsAvailable
      && invalidIdentityFieldNames == nil && !bundleName.isEmpty && !abilityName.isEmpty
      && selectionError == nil && !model.isSubmittingHAP
  }

  private var invalidIdentityFieldNames: String? {
    let invalid = [
      (
        DebugL10n.text("debug.apps.bundle"), bundleName,
        DebugTypedValueValidator.isValidBundleName(bundleName)
      ),
      (
        DebugL10n.text("debug.apps.ability"), abilityName,
        DebugTypedValueValidator.isValidAbilityName(abilityName)
      ),
    ]
    .filter { !$0.1.isEmpty && !$0.2 }
    .map(\.0)
    return invalid.isEmpty ? nil : invalid.joined(separator: ", ")
  }

  private func handleHAPSelection(_ result: Result<[URL], Error>) {
    switch result {
    case .failure:
      selectionError = DebugL10n.text("debug.apps.selection.failed")
    case .success(let urls):
      guard urls.count == 1, let url = urls.first else {
        selectionError = DebugL10n.text("debug.apps.selection.invalid")
        return
      }
      validatePackageSelection(entry: url, additional: additionalHAPURLs)
    }
  }

  private func handleAdditionalHAPSelection(_ result: Result<[URL], Error>) {
    switch result {
    case .failure:
      selectionError = DebugL10n.text("debug.apps.selection.failed")
    case .success(let urls):
      guard let entry = selectedHAPURL else { return }
      validatePackageSelection(entry: entry, additional: additionalHAPURLs + urls)
    }
  }

  private func validatePackageSelection(entry: URL, additional: [URL]) {
    do {
      try DebugHAPPackageSelection.validate(entry: entry, additional: additional)
      selectedHAPURL = entry
      additionalHAPURLs = additional
      selectionError = nil
    } catch let error as DebugHAPPackageSelection.Failure {
      selectionError = DebugL10n.text("debug.apps.selection.\(error.rawValue)")
    } catch {
      selectionError = DebugL10n.text("debug.apps.selection.failed")
    }
  }
}


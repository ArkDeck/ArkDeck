import AppKit
import ArkDeckClientKit
import ArkDeckCore
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct DebugCommandsWorkspace: View {
  var model: DebugWorkspaceViewModel
  let operation: DebugOperationPresentation?
  let target: DebugTargetPresentation?
  let relatedJobs: [DebugJobPresentation]
  let runtimeArtifacts: [DebugRuntimeArtifactRow]

  @State private var selectedTemplateID =
    DebugApplicationFacade.approvedCommandTemplates.first?.id
  @State private var pendingExport: DebugRuntimeArtifactRow?
  @State private var isExportPreviewPresented = false

  private var selectedTemplate: DebugCommandTemplatePresentation? {
    DebugApplicationFacade.approvedCommandTemplates.first { $0.id == selectedTemplateID }
  }

  private var feedbackMatchesSelection: Bool {
    model.commandFeedbackMatches(target: target, templateID: selectedTemplateID)
  }

  private var operationIsAvailable: Bool {
    guard let operation else { return false }
    if case .available = operation.availability { return true }
    return false
  }

  private var scopedActiveJobID: String? {
    feedbackMatchesSelection ? model.activeCommandJobID : nil
  }

  private var scopedTerminal: DebugLogJobTerminalPresentation? {
    feedbackMatchesSelection ? model.commandTerminal : nil
  }

  private var currentAccessibilityStatus: DebugAccessibilityStatus? {
    if feedbackMatchesSelection, let failure = model.commandFailure {
      return DebugAccessibilityStatus(message: failure, isUrgent: true)
    }
    if let jobID = scopedActiveJobID {
      return DebugAccessibilityStatus(
        message: DebugL10n.text("debug.commands.job.running") + " " + jobID,
        isUrgent: false)
    }
    if let terminal = scopedTerminal {
      return DebugAccessibilityStatus(
        message: "\(terminal.state) · \(terminal.jobID)",
        isUrgent: terminal.outcomeUnknown)
    }
    return nil
  }

  var body: some View {
    WorkspacePage(maximumWidth: WorkspaceMetrics.pageMaxWidth) {
      // The whole tab's contract, stated before any template is chosen: a
      // closed template set with schema-defined inputs, admitted and executed
      // through the same durable Runtime Job path as every device workflow.
      WorkspaceNotice(
        tone: .warning, symbol: "exclamationmark.shield",
        identifier: "debug.commands.typedOnly"
      ) {
        Text(DebugL10n.text("debug.commands.calloutTyped"))
      }
      WorkspaceColumns(
        spacing: WorkspaceMetrics.sectionGap,
        leadingRatio: WorkspaceMetrics.splitLeadingColumnRatio
      ) {
        templatesSection
      } trailing: {
        templateDetail
      }
      Text(DebugL10n.text("debug.commands.footerNoFreeText"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("debug.commands.footer")
      artifactsSection
      DebugRecentJobsSection(model: model, jobs: relatedJobs)
    }
    .background {
      DebugAccessibilityAnnouncementBridge(status: currentAccessibilityStatus)
    }
    .onChange(of: selectedTemplateID) { _, _ in model.clearCommandResult() }
  }

  /// Four zero-parameter read-only templates never needed a split view with a
  /// scrolling master list. They are a short closed set, so they read as one.
  private var templatesSection: some View {
    WorkspaceSection(
      Text(DebugL10n.text("debug.commands.select")),
      spacing: WorkspaceMetrics.rowGap
    ) {
      ForEach(DebugApplicationFacade.approvedCommandTemplates, id: \.id) { template in
        Button {
          selectTemplate(template)
        } label: {
          DebugCommandTemplateRow(
            template: template, isSelected: selectedTemplateID == template.id)
        }
        .buttonStyle(.plain)
        .disabled(model.isSubmittingCommand)
        .accessibilityIdentifier("debug.commands.template.\(template.id)")
      }
    }
  }

  @ViewBuilder
  private var templateDetail: some View {
    if let template = selectedTemplate {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
        invocationSection(template)
        resultSection()
      }
    } else {
      ContentUnavailableView(DebugL10n.text("debug.commands.select"), systemImage: "terminal")
    }
  }

  /// The App publishes only the typed request. Provider lowering stays inside
  /// the admitted Job and is available afterward in the report Artifact.
  private func invocationSection(_ template: DebugCommandTemplatePresentation) -> some View {
    WorkspaceSection(
      Text(DebugL10n.text("debug.commands.argv.title")),
      accessory: {
        DebugAvailabilityStatus(operation: operation)
      }
    ) {
      DebugAvailabilityNotice(operation: operation)
      templateIdentity(template)
      Divider()
      DebugCodeRow(
        label: DebugL10n.text("debug.availability.operation"),
        value: DebugApplicationFacade.debugTemplateReference)
      DebugCodeRow(label: "templateId", value: template.id)
      Text(DebugL10n.text("debug.commands.argv.note"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      runActionRow(template)
    }
  }

  private func templateIdentity(_ template: DebugCommandTemplatePresentation) -> some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
      DebugCodeRow(label: "catalog", value: "arkdeck-remote-operations@1.0.0")
      DebugCodeRow(label: "actionId", value: template.id)
      LabeledContent(DebugL10n.text("debug.commands.effect")) {
        Label(template.effect, systemImage: effectSymbol(template.effect))
          .foregroundStyle(.secondary)
      }
      LabeledContent(DebugL10n.text("debug.commands.target")) {
        Text(target?.id ?? DebugL10n.text("debug.target.none"))
          .font(WorkspaceFont.monospacedValue)
      }
      Text(DebugL10n.text("debug.commands.noParameters"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
    }
  }

  private func runActionRow(_ template: DebugCommandTemplatePresentation) -> some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
      Divider()
      HStack(spacing: WorkspaceMetrics.contentGap) {
        if scopedActiveJobID != nil {
          Button(DebugL10n.text("debug.action.cancel"), action: model.cancelCommand)
            .disabled(model.isCancellingCommand)
            .accessibilityIdentifier("debug.commands.cancel")
        } else {
          Button(DebugL10n.text("debug.commands.run")) {
            runTemplate(template)
          }
          .buttonStyle(.borderedProminent)
          .disabled(
            target == nil || !operationIsAvailable || !template.isRunnable
              || model.isSubmittingCommand
          )
          .help(DebugL10n.text("debug.commands.noPTY"))
          .accessibilityIdentifier("debug.commands.run")
        }
        if feedbackMatchesSelection && model.isSubmittingCommand {
          ProgressView().controlSize(.small)
        }
        if let jobID = scopedActiveJobID {
          Text(jobID)
            .font(WorkspaceFont.monospacedDense)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Spacer(minLength: 0)
      }
      if feedbackMatchesSelection, let failure = model.commandFailure {
        Label(failure, systemImage: "xmark.octagon")
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
    }
  }

  private func resultSection() -> some View {
    WorkspaceSection(Text(DebugL10n.text("debug.commands.result.title"))) {
      if let terminal = scopedTerminal {
        DebugCodeRow(
          label: DebugL10n.text("debug.commands.job.id"), value: terminal.jobID)
        DebugCodeRow(
          label: DebugL10n.text("debug.commands.job.state"), value: terminal.state)
        DebugCodeRow(
          label: DebugL10n.text("debug.commands.job.outcome"),
          value: terminal.outcomeUnknown
            ? DebugL10n.text("debug.commands.job.unknown")
            : DebugL10n.text("debug.commands.job.known"))
        if let failure = terminal.operationFailure {
          Label(
            DebugL10n.text("debug.failure.\(failure.code.rawValue)"),
            systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let latest = terminal.timeline.last {
          Divider()
          LabeledContent(DebugL10n.text("debug.commands.job.latest")) {
            Text(latest)
              .font(WorkspaceFont.monospacedValue)
              .textSelection(.enabled)
          }
        }
      } else {
        Text(DebugL10n.text("debug.commands.result.none"))
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      }
    }
  }

  private var artifactsSection: some View {
    WorkspaceSection(Text(DebugL10n.text("debug.commands.artifacts.title"))) {
      if runtimeArtifacts.isEmpty {
        ContentUnavailableView {
          Label(
            DebugL10n.text("debug.commands.artifacts.empty"),
            systemImage: "doc.badge.clock")
        } description: {
          Text(DebugL10n.text("debug.commands.artifacts.empty.detail"))
        }
        .frame(minHeight: 110)
      } else {
        ForEach(runtimeArtifacts) { row in
          artifactRow(row)
        }
      }
    }
    .confirmationDialog(
      DebugL10n.text("debug.logs.exportPreview.title"),
      isPresented: $isExportPreviewPresented,
      presenting: pendingExport
    ) { row in
      Button(
        DebugL10n.text(
          row.artifact.privacy == "sensitive"
            ? "debug.logs.exportSensitive" : "debug.logs.exportConfirm")
      ) {
        chooseExportDestination(for: row)
      }
      Button(DebugL10n.text("debug.logs.exportCancel"), role: .cancel) {}
    } message: { row in
      Text(
        String(
          localized: LocalizedStringResource.DebugLocalizable
            .debugLogsExportPreviewMessage(
              row.artifact.name,
              ByteCountFormatter.string(
                fromByteCount: row.artifact.byteCount, countStyle: .file),
              row.artifact.privacy,
              row.artifact.sha256)))
    }
  }

  private func artifactRow(_ row: DebugRuntimeArtifactRow) -> some View {
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
      Button(DebugL10n.text("debug.logs.export")) {
        pendingExport = row
        isExportPreviewPresented = true
      }
      .controlSize(.small)
      .disabled(
        row.artifact.status != "published"
          || model.exportStatesByArtifactID[row.artifact.id] == .exporting
      )
      .accessibilityIdentifier("debug.commands.export.\(row.artifact.id)")
      if model.exportStatesByArtifactID[row.artifact.id] == .exporting {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel(DebugL10n.text("debug.logs.exporting"))
      }
    }
  }

  private func selectTemplate(_ template: DebugCommandTemplatePresentation) {
    selectedTemplateID = template.id
  }

  private func runTemplate(_ template: DebugCommandTemplatePresentation) {
    guard let target else { return }
    model.submitTemplate(target: target, templateID: template.id)
  }

  private func chooseExportDestination(for row: DebugRuntimeArtifactRow) {
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.nameFieldStringValue = safeExportName(row.artifact.name)
    Task { @MainActor in
      guard await panel.begin() == .OK, let url = panel.url else { return }
      model.exportArtifact(
        jobID: row.jobID,
        artifact: row.artifact,
        destinationURL: url,
        allowSensitive: row.artifact.privacy == "sensitive")
    }
  }

  private func safeExportName(_ value: String) -> String {
    let sanitized = value.replacing("/", with: "_").replacing(":", with: "_")
    return sanitized.isEmpty ? "ArkDeck-Artifact" : sanitized
  }
}

struct DebugCommandTemplateRow: View {
  let template: DebugCommandTemplatePresentation
  let isSelected: Bool

  private var effectColor: Color {
    template.effect == "readOnly" ? .secondary : .orange
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.tightGap) {
      Image(systemName: effectSymbol(template.effect))
        .foregroundStyle(effectColor)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
        Text(template.id).font(WorkspaceFont.monospacedValue)
        Text(template.effect)
          .font(WorkspaceFont.caption)
          .foregroundStyle(effectColor)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, WorkspaceMetrics.contentGap)
    .padding(.vertical, WorkspaceMetrics.tightGap)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.rect)
    // An accent wash rather than the system selection fill: the row keeps its
    // own effect colour, which white-on-blue would swallow.
    .background(
      isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
      in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius)
        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}

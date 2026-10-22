import AppKit
import ArkDeckClientKit
import ArkDeckCore
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct DebugLogsWorkspace: View {
  var model: DebugWorkspaceViewModel
  let operation: DebugOperationPresentation?
  let target: DebugTargetPresentation?
  let relatedJobs: [DebugJobPresentation]
  let runtimeArtifacts: [DebugRuntimeArtifactRow]

  @State private var durationSeconds = 30
  @State private var minimumLevel = "Warn"
  @State private var domain = ""
  @State private var tag = ""
  @State private var pid = ""
  @State private var keyword = ""
  @State private var marker = ""
  @State private var isViewportPaused = false
  @State private var isRequestExpanded = false
  @State private var pendingExport: DebugRuntimeArtifactRow?
  @State private var isExportPreviewPresented = false

  private var enteredFilters: [(name: String, value: String)] {
    [
      ("domain", domain), ("tag", tag), ("pid", pid), ("keyword", keyword),
      ("marker", marker),
    ].filter { !$0.value.isEmpty }
  }

  private var invalidFilterNames: [String] {
    enteredFilters.filter { !DebugTypedValueValidator.isSafeHilogComponent($0.value) }
      .map(\.name)
  }

  private var filterTokens: [String] {
    enteredFilters.compactMap { field in
      guard DebugTypedValueValidator.isSafeHilogComponent(field.value) else { return nil }
      return "\(field.name):\(field.value)"
    } + ["level:\(minimumLevel.lowercased())"]
  }

  private var operationIsAvailable: Bool {
    guard let operation else { return false }
    if case .available = operation.availability { return true }
    return false
  }

  private var feedbackMatchesTarget: Bool {
    model.logFeedbackMatches(target: target)
  }

  private var scopedActiveJobID: String? {
    feedbackMatchesTarget ? model.activeLogJobID : nil
  }

  private var scopedTerminal: DebugLogJobTerminalPresentation? {
    feedbackMatchesTarget ? model.logTerminal : nil
  }

  var body: some View {
    WorkspacePage(maximumWidth: WorkspaceMetrics.pageMaxWidth) {
      // Configuration beside the viewport it feeds; the evidence tables below
      // both, at the page's full measure, because a shard row carries a name,
      // a size, a hash and two actions and does not fit a narrow column.
      WorkspaceColumns(
        spacing: WorkspaceMetrics.sectionGap,
        leadingRatio: WorkspaceMetrics.splitLeadingColumnRatio
      ) {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
          captureSection
          destructiveSection
        }
      } trailing: {
        liveViewportSection
      }
      shardsSection
      DebugRecentJobsSection(model: model, jobs: relatedJobs)
    }
  }

  private var captureSection: some View {
    WorkspaceSection(
      Text(DebugL10n.text("debug.logs.capture.title")),
      accessory: { DebugAvailabilityStatus(operation: operation) }
    ) {
      // Spec §4.4: state availability before offering the configuration it
      // gates. A ready operation is the accessory line above and nothing
      // more; only a blocker earns page space.
      DebugAvailabilityNotice(operation: operation)
      LabeledContent(DebugL10n.text("debug.logs.target")) {
        Text(target?.id ?? DebugL10n.text("debug.target.none"))
          .font(WorkspaceFont.monospacedValue)
      }
      Stepper(
        String(
          localized: LocalizedStringResource.DebugLocalizable.debugLogsDuration(
            Int32(clamping: durationSeconds))),
        value: $durationSeconds, in: 1...600)
      // Three closed steps, defaulting to Warn: the viewport's default
      // reading is "what needs attention", not the full Info firehose.
      LabeledContent(DebugL10n.text("debug.logs.level")) {
        Picker(DebugL10n.text("debug.logs.level"), selection: $minimumLevel) {
          Text(verbatim: "I").tag("Info")
            .accessibilityLabel("Info")
          Text(verbatim: "W").tag("Warn")
            .accessibilityLabel("Warn")
          Text(verbatim: "E").tag("Error")
            .accessibilityLabel("Error")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(maxWidth: 140)
        .accessibilityIdentifier("debug.logs.level")
      }
      filtersGroup
      // The raw shard is not optional, so it was never a choice: an always-on
      // disabled toggle only looks like a control the build has broken.
      Label(DebugL10n.text("debug.logs.rawSave"), systemImage: "checkmark.circle")
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
      captureFooter
    }
  }

  private var filtersGroup: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
      typedField("debug.logs.domain", text: $domain, prompt: "0xD003900")
      typedField("debug.logs.tag", text: $tag, prompt: "ArkUI")
      typedField("debug.logs.pid", text: $pid, prompt: "1234")
      typedField("debug.logs.keyword", text: $keyword, prompt: "render")
      typedField("debug.logs.marker", text: $marker, prompt: "checkout-start")
      Text(DebugL10n.text("debug.logs.filters.note"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if !invalidFilterNames.isEmpty {
        WorkspaceNotice(tone: .danger, identifier: "debug.logs.filters.invalid") {
          Text(
            String(
              localized: LocalizedStringResource.DebugLocalizable.debugLogsFiltersInvalid(
                invalidFilterNames.joined(separator: ", "))))
        }
      }
    }
  }

  private var captureFooter: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
      Divider()
      typedRequestDisclosure
      captureActionRow
      captureStatus
    }
  }

  /// The form above already names every value in words. Echoing the same
  /// values back as a mono key/value list doubles the section, so the exact
  /// typed request stays one disclosure away instead of always on.
  private var typedRequestDisclosure: some View {
    DisclosureGroup(isExpanded: $isRequestExpanded) {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
        DebugCodeRow(
          label: DebugL10n.text("debug.availability.operation"),
          value: DebugApplicationFacade.captureDiagnosticsReference)
        DebugCodeRow(label: "durationSeconds", value: String(durationSeconds))
        DebugCodeRow(
          label: "hilogFilters",
          value: filterTokens.isEmpty ? "[]" : "[\(filterTokens.joined(separator: ", "))]")
        DebugCodeRow(label: "uiDump", value: "false")
        if let operation {
          Text(
            LocalizedStringResource.DebugLocalizable.debugAvailabilityEffect(
              operation.minimumEffect)
          )
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
        }
      }
      .padding(.top, WorkspaceMetrics.rowGap)
    } label: {
      Text(DebugL10n.text("debug.logs.request.title"))
        .font(WorkspaceFont.label)
        .foregroundStyle(.secondary)
    }
    .accessibilityIdentifier("debug.logs.request")
  }

  private var captureActionRow: some View {
    HStack(spacing: WorkspaceMetrics.contentGap) {
      if scopedActiveJobID != nil {
        Button(DebugL10n.text("debug.action.cancel")) { model.cancelLogs() }
          .disabled(model.isCancellingLogs)
          .accessibilityIdentifier("debug.logs.cancel")
      } else {
        Button(DebugL10n.text("debug.logs.start")) {
          guard let target else { return }
          model.submitLogs(
            target: target, durationSeconds: durationSeconds, filters: filterTokens)
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          target == nil || !operationIsAvailable || !invalidFilterNames.isEmpty
            || model.isSubmittingLogs
        )
        .accessibilityIdentifier("debug.logs.start")
      }
      if let jobID = scopedActiveJobID {
        ProgressView().controlSize(.small)
        Text(jobID)
          .font(WorkspaceFont.monospacedDense)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder
  private var captureStatus: some View {
    if feedbackMatchesTarget, let failure = model.logFailure {
      Label(failure, systemImage: "xmark.octagon")
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    } else if let terminal = scopedTerminal {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
        Label(
          "\(terminal.state) · \(terminal.jobID)",
          systemImage: terminal.state == "succeeded"
            ? "checkmark.circle.fill" : "info.circle"
        )
        if let failure = terminal.operationFailure {
          Text(DebugL10n.text("debug.failure.\(failure.code.rawValue)"))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("debug.logs.typedFailure")
        }
      }
      .font(WorkspaceFont.secondary)
      .foregroundStyle(terminal.state == "succeeded" ? .green : .secondary)
    }
  }

  /// Exactly one destructive buffer action exists in the design vocabulary.
  /// Inventing siblings (resize, flush) would present device mutations no
  /// published operation defines, so the group stays a menu with its blocker.
  private var destructiveSection: some View {
    WorkspaceSection(Text(DebugL10n.text("debug.logs.destructive.title"))) {
      Menu(DebugL10n.text("debug.logs.destructive.menu")) {
        Button(DebugL10n.text("debug.logs.destructive.clear")) {}
          .disabled(true)
      }
      .disabled(true)
      .fixedSize()
      .help(DebugL10n.text("debug.logs.destructive.scope"))
      DebugBlockedReason(text: DebugL10n.text("debug.blocked.bufferOperation"))
    }
  }

  private var liveViewportSection: some View {
    WorkspaceSection(
      Text(DebugL10n.text("debug.logs.live.title")),
      accessory: {
        // Pausing is deliberately a local viewport state; it never cancels or
        // suspends the Runtime Job.
        Button(
          DebugL10n.text(isViewportPaused ? "debug.logs.resume" : "debug.logs.pause")
        ) {
          isViewportPaused.toggle()
        }
        .controlSize(.small)
        .disabled(scopedActiveJobID == nil)
        .help(DebugL10n.text("debug.logs.pause.requiresCapture"))
        .accessibilityIdentifier("debug.logs.pauseViewport")
      }
    ) {
      viewport
      Label(
        DebugL10n.text("debug.logs.viewport.bounded"),
        systemImage: "arrow.down.right.and.arrow.up.left"
      )
      .font(WorkspaceFont.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var viewport: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: WorkspaceMetrics.insetRadius)
        .fill(Color(nsColor: .textBackgroundColor))
      if let terminal = scopedTerminal, !terminal.timeline.isEmpty {
        // A bounded window of entries, so the box grows to what it holds
        // instead of nesting a second scroll view inside the page.
        VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap / 2) {
          ForEach(terminal.timeline.suffix(12).enumerated(), id: \.offset) {
            _, entry in
            Text(entry)
              .font(WorkspaceFont.monospacedDense)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(WorkspaceMetrics.contentGap)
      } else {
        VStack(spacing: WorkspaceMetrics.tightGap) {
          Image(systemName: "text.page.badge.magnifyingglass")
            .font(.title2)
            .foregroundStyle(.secondary)
          Text(DebugL10n.text("debug.logs.live.empty"))
            .font(WorkspaceFont.body.weight(.medium))
          Text(DebugL10n.text("debug.logs.live.empty.detail"))
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(WorkspaceMetrics.pageInsetTop)
      }
    }
    .frame(minHeight: 320)
    .overlay {
      RoundedRectangle(cornerRadius: WorkspaceMetrics.insetRadius)
        .stroke(.separator, lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("debug.logs.viewport")
  }

  private var shardsSection: some View {
    WorkspaceSection(Text(DebugL10n.text("debug.logs.shards.title"))) {
      HStack {
        Text(DebugL10n.text("debug.logs.shards.sequence"))
        Spacer()
        Text(DebugL10n.text("debug.logs.shards.size"))
          .frame(width: 72, alignment: .trailing)
        Text(DebugL10n.text("debug.logs.shards.hash"))
          .frame(width: 100, alignment: .trailing)
        Color.clear.frame(width: 96, height: 1)
      }
      .font(WorkspaceFont.label)
      .foregroundStyle(.secondary)
      Divider()
      if runtimeArtifacts.isEmpty {
        ContentUnavailableView {
          Label(
            DebugL10n.text("debug.logs.shards.empty"),
            systemImage: "externaldrive.badge.questionmark")
        } description: {
          Text(DebugL10n.text("debug.logs.shards.empty.detail"))
        }
        .frame(minHeight: 110)
      } else {
        ForEach(runtimeArtifacts) { row in
          shardRow(row)
        }
      }
      Divider()
      Label(
        DebugL10n.text("debug.logs.exportBoundary"),
        systemImage: "checkmark.shield"
      )
      .font(WorkspaceFont.secondary)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if let operation {
        Text(
          String(
            localized: LocalizedStringResource.DebugLocalizable.debugLogsStorageTotalBudget(
              ByteCountFormatter.string(
                fromByteCount: Int64(operation.outputByteBudget), countStyle: .file)))
        )
        .font(WorkspaceFont.monospacedDense.monospacedDigit())
        .foregroundStyle(.secondary)
      }
    }
  }

  private func shardRow(_ row: DebugRuntimeArtifactRow) -> some View {
    let artifact = row.artifact
    return VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
      HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.contentGap) {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
          Text(artifact.name).font(WorkspaceFont.monospacedValue)
          Text("\(artifact.status) · \(artifact.privacy)")
            .font(WorkspaceFont.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: WorkspaceMetrics.contentGap)
        Text(
          ByteCountFormatter.string(
            fromByteCount: artifact.byteCount, countStyle: .file)
        )
        .font(WorkspaceFont.monospacedDense.monospacedDigit())
        .frame(width: 72, alignment: .trailing)
        Text(String(artifact.sha256.prefix(12)))
          .font(WorkspaceFont.monospacedDense)
          .frame(width: 100, alignment: .trailing)
          .help(artifact.sha256)
        HStack(spacing: WorkspaceMetrics.tightGap) {
          Button(DebugL10n.text("debug.logs.export")) {
            pendingExport = row
            isExportPreviewPresented = true
          }
          .controlSize(.small)
          .disabled(
            artifact.status != "published"
              || model.exportStatesByArtifactID[artifact.id] == .exporting
          )
          .accessibilityIdentifier("debug.logs.export.\(artifact.id)")
          .confirmationDialog(
            DebugL10n.text("debug.logs.exportPreview.title"),
            isPresented: exportDialogPresented(for: artifact.id),
            presenting: pendingExport
          ) { pendingRow in
            Button(
              DebugL10n.text(
                pendingRow.artifact.privacy == "sensitive"
                  ? "debug.logs.exportSensitive" : "debug.logs.exportConfirm")
            ) {
              chooseExportDestination(for: pendingRow)
            }
            Button(DebugL10n.text("debug.logs.exportCancel"), role: .cancel) {}
          } message: { pendingRow in
            Text(
              String(
                localized: LocalizedStringResource.DebugLocalizable
                  .debugLogsExportPreviewMessage(
                    pendingRow.artifact.name,
                    ByteCountFormatter.string(
                      fromByteCount: pendingRow.artifact.byteCount, countStyle: .file),
                    pendingRow.artifact.privacy,
                    pendingRow.artifact.sha256)))
          }
          if model.exportStatesByArtifactID[artifact.id] == .exporting {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel(DebugL10n.text("debug.logs.exporting"))
          }
          if case .completed(let url) = model.exportStatesByArtifactID[artifact.id] {
            Button(DebugL10n.text("debug.logs.showInFinder")) {
              NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .controlSize(.small)
            .accessibilityIdentifier("debug.logs.showInFinder.\(artifact.id)")
          }
        }
        // minWidth, not a hard width: a localized button title must not be
        // clipped to keep the column edge.
        .frame(minWidth: 96, alignment: .trailing)
      }
      if case .failed(let reason) = model.exportStatesByArtifactID[artifact.id] {
        Label(reason, systemImage: "xmark.octagon")
          .font(WorkspaceFont.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("debug.logs.exportFailure.\(artifact.id)")
      }
    }
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

  private func exportDialogPresented(for artifactID: String) -> Binding<Bool> {
    Binding(
      get: { isExportPreviewPresented && pendingExport?.artifact.id == artifactID },
      set: { if !$0 { isExportPreviewPresented = false } })
  }

  private func safeExportName(_ value: String) -> String {
    let sanitized =
      value
      .replacing("/", with: "_")
      .replacing(":", with: "_")
    return sanitized.isEmpty ? "ArkDeck-Artifact" : sanitized
  }

  /// A bare `TextField` hides its title on macOS, so the capture form rendered
  /// as five unlabelled boxes whose only clue was a placeholder. `LabeledContent`
  /// puts each field on the same label/value column as the rows above it.
  private func typedField(_ key: String, text: Binding<String>, prompt: String) -> some View {
    LabeledContent(DebugL10n.text(key)) {
      TextField(DebugL10n.text(key), text: text, prompt: Text(prompt))
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .frame(maxWidth: 180)
    }
  }
}


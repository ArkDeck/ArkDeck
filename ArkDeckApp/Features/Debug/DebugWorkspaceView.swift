import AppKit
import ArkDeckWorkflows
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum DebugWorkspaceTab: String, CaseIterable, Hashable {
  case logs
  case apps
  case network
  case commands

  var title: String {
    DebugL10n.text("debug.tab.\(rawValue)")
  }

  var symbol: String {
    switch self {
    case .logs: "text.alignleft"
    case .apps: "app.badge"
    case .network: "point.3.connected.trianglepath.dotted"
    case .commands: "terminal"
    }
  }
}

/// The complete Debug workspace. It projects Runtime facts and invokes only
/// the closed typed Debug facade; provider lowering and raw command transport
/// remain outside the App.
struct DebugWorkspaceView: View {
  var model: DebugWorkspaceViewModel
  let onOpenHistory: () -> Void

  @SceneStorage("debug.workspace.tab")
  private var storedTab = DebugWorkspaceTab.logs.rawValue
  @State private var selectedTargetID: String?

  private var selectedTab: DebugWorkspaceTab {
    DebugWorkspaceTab(rawValue: storedTab) ?? .logs
  }

  private var selectedTarget: DebugTargetPresentation? {
    model.workspace.targets.first { $0.id == selectedTargetID }
  }

  private var activeJobs: [DebugJobPresentation] {
    model.workspace.jobs.filter(\.isActive)
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
        workspaceHeader
        tabPicker
      }
      .padding(.horizontal, WorkspaceMetrics.pageInsetHorizontal)
      .padding(.top, WorkspaceMetrics.contentGap)
      .padding(.bottom, WorkspaceMetrics.tightGap)
      Divider()
      selectedWorkspace
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if !activeJobs.isEmpty {
          Button(action: onOpenHistory) {
            Label(
              String(
                localized: LocalizedStringResource.DebugLocalizable.debugJobsActive(
                  Int32(clamping: activeJobs.count))),
              systemImage: "bolt.horizontal.circle")
          }
          .accessibilityIdentifier("debug.activeJobs")
        }
        Button {
          model.refresh(targetID: selectedTargetID)
        } label: {
          Label(DebugL10n.text("debug.action.refresh"), systemImage: "arrow.clockwise")
        }
        .disabled(model.isRefreshing)
        .accessibilityIdentifier("debug.refresh")
      }
    }
    .onAppear(perform: reconcileTargetSelection)
    .onChange(of: model.workspace.targets) { _, _ in reconcileTargetSelection() }
    .onChange(of: selectedTargetID) { _, targetID in
      model.refresh(targetID: targetID)
    }
  }

  private var workspaceHeader: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: WorkspaceMetrics.blockGap) {
        titleAndScope
        Spacer(minLength: WorkspaceMetrics.contentGap)
        targetPicker
        operationBadges
      }
      VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
        titleAndScope
        HStack(spacing: WorkspaceMetrics.contentGap) {
          targetPicker
          Spacer(minLength: WorkspaceMetrics.tightGap)
          operationBadges
        }
      }
    }
  }

  // The page title lives in the window toolbar; repeating it here would give
  // the detail two perceivable main headings. Only the scope line stays.
  private var titleAndScope: some View {
    Text(DebugL10n.text("debug.scope"))
      .font(WorkspaceFont.secondary)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("debug.scope")
  }

  private var targetPicker: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
      Text(DebugL10n.text("debug.target.label"))
        .font(WorkspaceFont.caption)
        .foregroundStyle(.secondary)
      Picker(DebugL10n.text("debug.target.label"), selection: $selectedTargetID) {
        Text(DebugL10n.text("debug.target.none")).tag(String?.none)
        ForEach(model.workspace.targets) { target in
          Text(target.id).tag(Optional(target.id))
        }
      }
      .labelsHidden()
      .frame(width: 230)
      .accessibilityIdentifier("debug.target")
      if let selectedTarget {
        Text(
          String(
            localized: LocalizedStringResource.DebugLocalizable.debugTargetBinding(
              Int32(clamping: selectedTarget.bindingRevision), selectedTarget.toolVersion))
        )
        .font(WorkspaceFont.monospacedDense.monospacedDigit())
        .foregroundStyle(.secondary)
      } else if let failure = model.workspace.targetLoadFailure {
        Text(failure)
          .font(WorkspaceFont.caption)
          .foregroundStyle(.red)
          .lineLimit(2)
      }
    }
  }

  private var operationBadges: some View {
    VStack(alignment: .trailing, spacing: WorkspaceMetrics.tightGap) {
      operationBadge(
        reference: DebugApplicationFacade.captureDiagnosticsReference,
        shortTitle: DebugL10n.text("debug.operation.capture"))
      operationBadge(
        reference: DebugApplicationFacade.debugHAPReference,
        shortTitle: DebugL10n.text("debug.operation.hap"))
    }
  }

  private func operationBadge(reference: String, shortTitle: String) -> some View {
    let operation = model.workspace.operation(reference)
    return WorkspaceChip(
      text: Text(shortTitle),
      tone: operationChipTone(operation?.availability),
      symbol: operationStatusSymbol(operation?.availability))
      .help(reference)
  }

  private func operationChipTone(_ availability: DebugRuntimeAvailability?) -> WorkspaceTone {
    switch availability {
    case .available: .ok
    case .checking: .neutral
    case .unavailable, nil: .warning
    }
  }

  private var tabPicker: some View {
    Picker(DebugL10n.text("debug.tabs.label"), selection: $storedTab) {
      ForEach(DebugWorkspaceTab.allCases, id: \.self) { tab in
        Label(tab.title, systemImage: tab.symbol)
          .accessibilityIdentifier("debug.tab.\(tab.rawValue)")
          .tag(tab.rawValue)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .frame(maxWidth: 620)
    .accessibilityIdentifier("debug.tabs")
  }

  @ViewBuilder
  private var selectedWorkspace: some View {
    switch selectedTab {
    case .logs:
      DebugLogsWorkspace(
        model: model,
        operation: model.workspace.operation(
          DebugApplicationFacade.captureDiagnosticsReference),
        target: selectedTarget,
        relatedJobs: model.workspace.jobs.filter {
          $0.operationReference == DebugApplicationFacade.captureDiagnosticsReference
        },
        runtimeArtifacts: model.runtimeArtifactRows(
          operationReference: DebugApplicationFacade.captureDiagnosticsReference,
          targetID: selectedTarget?.id))
    case .apps:
      DebugAppsWorkspace(
        model: model,
        operation: model.workspace.operation(DebugApplicationFacade.debugHAPReference),
        target: selectedTarget,
        relatedJobs: model.workspace.jobs.filter {
          $0.operationReference == DebugApplicationFacade.debugHAPReference
        },
        runtimeProbe: model.workspace.runtimeProbe,
        probeFailure: model.workspace.probeFailure,
        runtimeArtifacts: model.runtimeArtifactRows(
          operationReference: DebugApplicationFacade.debugHAPReference,
          targetID: selectedTarget?.id))
    case .network:
      DebugNetworkWorkspace(
        model: model,
        target: selectedTarget,
        runtimeProbe: model.workspace.runtimeProbe,
        probeFailure: model.workspace.probeFailure)
    case .commands:
      DebugCommandsWorkspace(model: model, target: selectedTarget)
    }
  }

  private func operationStatusSymbol(_ availability: DebugRuntimeAvailability?) -> String {
    switch availability {
    case .available: "checkmark.circle.fill"
    case .checking: "hourglass"
    case .unavailable, nil: "exclamationmark.triangle.fill"
    }
  }

  private func reconcileTargetSelection() {
    guard !model.workspace.targets.isEmpty else {
      selectedTargetID = nil
      return
    }
    if let selectedTargetID, model.workspace.targets.contains(where: { $0.id == selectedTargetID })
    {
      return
    }
    selectedTargetID = model.workspace.targets.first?.id
  }
}

private struct DebugRuntimeArtifactRow: Identifiable {
  let jobID: String
  let artifact: RuntimeArtifactPresentation

  var id: String { "\(jobID):\(artifact.id)" }
}

private struct DebugLogsWorkspace: View {
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
  @State private var savesRawHiLog = true
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

  var body: some View {
    GeometryReader { geometry in
      ViewThatFits(in: .horizontal) {
        HSplitView {
          configuration
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 390, maxHeight: .infinity)
          liveAndStorage
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: geometry.size.width, height: geometry.size.height)

        ScrollView {
          VStack(spacing: WorkspaceMetrics.blockGap) {
            configuration
            liveAndStorage
          }
          .padding(WorkspaceMetrics.pageInsetHorizontal)
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
          localized: LocalizedStringResource.DebugLocalizable.debugLogsExportPreviewMessage(
            row.artifact.name,
            ByteCountFormatter.string(
              fromByteCount: row.artifact.byteCount, countStyle: .file),
            row.artifact.privacy,
            row.artifact.sha256)))
    }
  }

  private var configuration: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.blockGap) {
        DebugCard(
          title: DebugL10n.text("debug.logs.capture.title"), symbol: "record.circle"
        ) {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
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
            typedField("debug.logs.domain", text: $domain, prompt: "0xD003900")
            typedField("debug.logs.tag", text: $tag, prompt: "ArkUI")
            typedField("debug.logs.pid", text: $pid, prompt: "1234")
            typedField("debug.logs.keyword", text: $keyword, prompt: "render")
            typedField("debug.logs.marker", text: $marker, prompt: "checkout-start")
            Toggle(DebugL10n.text("debug.logs.rawSave"), isOn: $savesRawHiLog)
              .disabled(true)
            Text(DebugL10n.text("debug.logs.filters.note"))
              .font(WorkspaceFont.secondary)
              .foregroundStyle(.secondary)
            if !invalidFilterNames.isEmpty {
              Label(
                String(
                  localized: LocalizedStringResource.DebugLocalizable.debugLogsFiltersInvalid(
                    invalidFilterNames.joined(separator: ", "))),
                systemImage: "exclamationmark.circle"
              )
              .font(WorkspaceFont.secondary)
              .foregroundStyle(.red)
            }
          }
        }

        DebugAvailabilityCard(operation: operation)

        DebugCard(
          title: DebugL10n.text("debug.logs.request.title"), symbol: "list.bullet.rectangle"
        ) {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
            DebugCodeRow(
              label: "operation", value: DebugApplicationFacade.captureDiagnosticsReference)
            DebugCodeRow(label: "durationSeconds", value: String(durationSeconds))
            DebugCodeRow(
              label: "hilogFilters",
              value: filterTokens.isEmpty ? "[]" : "[\(filterTokens.joined(separator: ", "))]")
            DebugCodeRow(label: "uiDump", value: "false")
            HStack {
              if model.activeLogJobID != nil {
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
              if let jobID = model.activeLogJobID {
                ProgressView().controlSize(.small)
                Text(jobID).font(WorkspaceFont.monospacedDense).lineLimit(1)
              }
            }
            if let failure = model.logFailure {
              Label(failure, systemImage: "xmark.octagon")
                .font(WorkspaceFont.secondary)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            } else if let terminal = model.logTerminal {
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
        }

        destructiveActions
      }
      .padding(WorkspaceMetrics.pageInsetHorizontal)
    }
  }

  private var liveAndStorage: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.blockGap) {
        DebugCard(title: DebugL10n.text("debug.logs.live.title"), symbol: "text.alignleft") {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
            HStack {
              // Pausing is deliberately a local viewport state; it never
              // cancels or suspends the Runtime Job.
              Button(
                DebugL10n.text(isViewportPaused ? "debug.logs.resume" : "debug.logs.pause")
              ) {
                isViewportPaused.toggle()
              }
              .disabled(model.activeLogJobID == nil)
              .help(DebugL10n.text("debug.logs.pause.requiresCapture"))
              .accessibilityIdentifier("debug.logs.pauseViewport")
              Spacer()
              Label(
                DebugL10n.text("debug.logs.viewport.bounded"),
                systemImage: "arrow.down.right.and.arrow.up.left"
              )
              .font(WorkspaceFont.caption)
              .foregroundStyle(.secondary)
            }
            ZStack(alignment: .topLeading) {
              RoundedRectangle(cornerRadius: WorkspaceMetrics.insetRadius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
              if let terminal = model.logTerminal, !terminal.timeline.isEmpty {
                ScrollView {
                  VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap / 2) {
                    ForEach(Array(terminal.timeline.suffix(12).enumerated()), id: \.offset) {
                      _, entry in
                      Text(entry)
                        .font(WorkspaceFont.monospacedDense)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                  }
                  .padding(WorkspaceMetrics.contentGap)
                }
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
            .frame(minHeight: 250)
            .overlay {
              RoundedRectangle(cornerRadius: WorkspaceMetrics.insetRadius, style: .continuous)
                .stroke(.separator, lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("debug.logs.viewport")
          }
        }

        DebugCard(title: DebugL10n.text("debug.logs.shards.title"), symbol: "externaldrive") {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
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
                let artifact = row.artifact
                VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
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
                      .disabled(
                        artifact.status != "published"
                          || model.exportStatesByArtifactID[artifact.id] == .exporting
                      )
                      .accessibilityIdentifier("debug.logs.export.\(artifact.id)")
                      if model.exportStatesByArtifactID[artifact.id] == .exporting {
                        ProgressView()
                          .controlSize(.small)
                          .accessibilityLabel(DebugL10n.text("debug.logs.exporting"))
                      }
                      if case .completed(let url) = model.exportStatesByArtifactID[artifact.id] {
                        Button(DebugL10n.text("debug.logs.showInFinder")) {
                          NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .accessibilityIdentifier("debug.logs.showInFinder.\(artifact.id)")
                      }
                    }
                    // minWidth, not a hard width: a localized button title must
                    // not be clipped to keep the column edge.
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
            }
            Divider()
            HStack {
              Label(
                DebugL10n.text("debug.logs.exportBoundary"),
                systemImage: "checkmark.shield")
            }
            .font(WorkspaceFont.secondary)
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

        DebugRecentJobsCard(model: model, jobs: relatedJobs)
      }
      .padding(WorkspaceMetrics.pageInsetHorizontal)
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

  private func safeExportName(_ value: String) -> String {
    let sanitized =
      value
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
    return sanitized.isEmpty ? "ArkDeck-Artifact" : sanitized
  }

  private var destructiveActions: some View {
    DebugCard(
      title: DebugL10n.text("debug.logs.destructive.title"),
      symbol: "exclamationmark.triangle"
    ) {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
        Text(DebugL10n.text("debug.logs.destructive.scope"))
          .font(.callout)
        // Exactly one destructive buffer action exists in the design
        // vocabulary. Inventing siblings (resize, flush) would present device
        // mutations no published operation defines.
        Menu(DebugL10n.text("debug.logs.destructive.menu")) {
          Button(DebugL10n.text("debug.logs.destructive.clear")) {}
            .disabled(true)
        }
        .disabled(true)
        DebugBlockedReason(text: DebugL10n.text("debug.blocked.bufferOperation"))
      }
    }
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

private struct DebugAppsWorkspace: View {
  var model: DebugWorkspaceViewModel
  let operation: DebugOperationPresentation?
  let target: DebugTargetPresentation?
  let relatedJobs: [DebugJobPresentation]
  let runtimeProbe: DebugRuntimeProbeSnapshot?
  let probeFailure: String?
  let runtimeArtifacts: [DebugRuntimeArtifactRow]

  @State private var isImporterPresented = false
  @State private var selectedHAPURL: URL?
  @State private var selectionError: String?
  @State private var bundleName = ""
  @State private var abilityName = ""
  @State private var installPolicy = "installOrReplace"
  @State private var cleanupPolicy = "uninstall"
  @State private var postRunState = "stopped"
  @State private var captureDiagnostics = true
  @State private var diagnosticsDuration = 30

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.blockGap) {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: WorkspaceMetrics.blockGap) {
            packageAndIdentity.frame(minWidth: 300, maxWidth: 390)
            lifecycleReview.frame(minWidth: 420, maxWidth: .infinity)
          }
          VStack(spacing: WorkspaceMetrics.blockGap) {
            packageAndIdentity
            lifecycleReview
          }
        }
        packageInventory
        if !runtimeArtifacts.isEmpty { resultArtifacts }
        DebugRecentJobsCard(model: model, jobs: relatedJobs)
      }
      .frame(maxWidth: WorkspaceMetrics.pageMaxWidth, alignment: .topLeading)
      .padding(WorkspaceMetrics.pageInsetHorizontal)
    }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: [UTType(filenameExtension: "hap") ?? .data],
      allowsMultipleSelection: false,
      onCompletion: handleHAPSelection)
  }

  private var packageAndIdentity: some View {
    VStack(spacing: WorkspaceMetrics.blockGap) {
      DebugAvailabilityCard(operation: operation)
      DebugCard(title: DebugL10n.text("debug.apps.package.title"), symbol: "shippingbox") {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
          LabeledContent(DebugL10n.text("debug.apps.target")) {
            Text(target?.id ?? DebugL10n.text("debug.target.none"))
              .font(WorkspaceFont.monospacedValue)
          }
          Button {
            isImporterPresented = true
          } label: {
            Label(DebugL10n.text("debug.apps.chooseHAP"), systemImage: "doc.badge.plus")
          }
          Text(selectedHAPURL?.lastPathComponent ?? DebugL10n.text("debug.apps.noHAP"))
            .font(WorkspaceFont.monospacedValue)
            .foregroundStyle(selectedHAPURL == nil ? .secondary : .primary)
            .textSelection(.enabled)
          if let selectionError {
            Label(selectionError, systemImage: "xmark.octagon")
              .font(WorkspaceFont.secondary)
              .foregroundStyle(.red)
          }
          Text(DebugL10n.text("debug.apps.localOnly"))
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.secondary)
        }
      }

      DebugCard(title: DebugL10n.text("debug.apps.identity.title"), symbol: "tag") {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
          TextField(
            DebugL10n.text("debug.apps.bundle"), text: $bundleName,
            prompt: Text("com.example.app"))
          TextField(
            DebugL10n.text("debug.apps.ability"), text: $abilityName,
            prompt: Text("EntryAbility"))
          // The note below promises schema validation; these two fields are
          // the argv-adjacent inputs on this tab, so the gate is applied
          // here, not deferred to a future submit path.
          if let invalid = invalidIdentityFieldNames {
            Label(
              String(
                localized: LocalizedStringResource.DebugLocalizable.debugTypedInvalidIdentifier(
                  invalid)),
              systemImage: "exclamationmark.circle"
            )
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.red)
            .accessibilityIdentifier("debug.apps.identity.invalid")
          }
          Text(DebugL10n.text("debug.apps.identity.note"))
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
      }
    }
  }

  private var lifecycleReview: some View {
    VStack(spacing: WorkspaceMetrics.blockGap) {
      DebugCard(
        title: DebugL10n.text("debug.apps.lifecycle.title"), symbol: "arrow.triangle.2.circlepath"
      ) {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
          Picker(DebugL10n.text("debug.apps.installPolicy"), selection: $installPolicy) {
            Text(DebugL10n.text("debug.apps.install.replace")).tag("installOrReplace")
            Text(DebugL10n.text("debug.apps.install.fresh")).tag("installFresh")
          }
          Picker(DebugL10n.text("debug.apps.cleanupPolicy"), selection: $cleanupPolicy) {
            Text(DebugL10n.text("debug.apps.cleanup.uninstall")).tag("uninstall")
            Text(DebugL10n.text("debug.apps.cleanup.retain")).tag("retain")
            Text(DebugL10n.text("debug.apps.cleanup.restore")).tag("restorePrevious")
          }
          Picker(DebugL10n.text("debug.apps.postRun"), selection: $postRunState) {
            Text(DebugL10n.text("debug.apps.postRun.stopped")).tag("stopped")
            Text(DebugL10n.text("debug.apps.postRun.running")).tag("running")
          }
          Toggle(DebugL10n.text("debug.apps.captureDiagnostics"), isOn: $captureDiagnostics)
          if captureDiagnostics {
            Stepper(
              String(
                localized: LocalizedStringResource.DebugLocalizable.debugAppsDiagnosticsDuration(
                  Int32(clamping: diagnosticsDuration))),
              value: $diagnosticsDuration, in: 1...300)
          }
          Divider()
          Label(
            DebugL10n.text("debug.apps.mutationScope"),
            systemImage: "exclamationmark.shield"
          )
          .font(.callout.weight(.medium))
          Text(DebugL10n.text("debug.apps.mutationDetail"))
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.secondary)
        }
      }

      DebugCard(title: DebugL10n.text("debug.apps.plan.title"), symbol: "list.number") {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
          DebugCodeRow(label: "bundleName", value: bundleName.isEmpty ? "—" : bundleName)
          DebugCodeRow(label: "abilityName", value: abilityName.isEmpty ? "—" : abilityName)
          DebugCodeRow(label: "installPolicy", value: installPolicy)
          DebugCodeRow(label: "cleanupPolicy", value: cleanupPolicy)
          DebugCodeRow(label: "postRunAbilityState", value: postRunState)
          DebugCodeRow(label: "captureDiagnostics", value: String(captureDiagnostics))
          Divider()
          if let operation {
            ForEach(operation.steps) { step in
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
                Spacer()
                if step.isOptional {
                  Text(DebugL10n.text("debug.optional"))
                    .font(WorkspaceFont.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                }
              }
              if step.id != operation.steps.last?.id { Divider() }
            }
          }
          HStack {
            if model.isSubmittingHAP {
              ProgressView().controlSize(.small)
              Text(
                DebugL10n.text(
                  model.activeHAPJobID == nil
                    ? "debug.apps.importing" : "debug.apps.running")
              )
              .font(WorkspaceFont.secondary)
              if let jobID = model.activeHAPJobID {
                Text(jobID).font(WorkspaceFont.monospacedDense).lineLimit(1)
                Spacer()
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
            }
          }
          if let failure = model.hapFailure {
            Label(failure, systemImage: "xmark.octagon")
              .font(WorkspaceFont.secondary)
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
          }
          if let terminal = model.hapTerminal {
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
      }
    }
  }

  private var packageInventory: some View {
    DebugCard(title: DebugL10n.text("debug.apps.inventory.title"), symbol: "tablecells") {
      VStack(spacing: WorkspaceMetrics.contentGap) {
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
        if let runtimeProbe, runtimeProbe.targetID == target?.id,
          !runtimeProbe.packages.isEmpty
        {
          ForEach(runtimeProbe.packages, id: \.self) { package in
            HStack {
              Text(package).font(WorkspaceFont.monospacedValue).textSelection(.enabled)
              Spacer()
              Text("—")
                .font(WorkspaceFont.tabularSecondary)
                .frame(width: 72, alignment: .trailing)
                .foregroundStyle(.secondary)
              Text("—")
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
        if let warnings = runtimeProbe?.warnings, !warnings.isEmpty {
          Text(warnings.joined(separator: " · "))
            .font(WorkspaceFont.monospacedDense)
            .foregroundStyle(.orange)
            .textSelection(.enabled)
        }
        HStack {
          Button(DebugL10n.text("debug.apps.action.start")) {}.disabled(true)
          Button(DebugL10n.text("debug.apps.action.stop")) {}.disabled(true)
          Spacer()
          Button(DebugL10n.text("debug.apps.action.uninstall"), role: .destructive) {}
            .disabled(true)
        }
      }
    }
  }

  private var resultArtifacts: some View {
    DebugCard(title: DebugL10n.text("debug.apps.artifacts.title"), symbol: "shippingbox.fill") {
      VStack(spacing: WorkspaceMetrics.tightGap) {
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
  }

  private var operationIsAvailable: Bool {
    guard let operation else { return false }
    if case .available = operation.availability { return true }
    return false
  }

  private var canSubmit: Bool {
    target != nil && selectedHAPURL != nil && operationIsAvailable
      && invalidIdentityFieldNames == nil && !bundleName.isEmpty && !abilityName.isEmpty
      && !model.isSubmittingHAP
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
      selectedHAPURL = nil
      selectionError = DebugL10n.text("debug.apps.selection.failed")
    case .success(let urls):
      guard let url = urls.first, url.pathExtension.lowercased() == "hap" else {
        selectedHAPURL = nil
        selectionError = DebugL10n.text("debug.apps.selection.invalid")
        return
      }
      selectedHAPURL = url
      selectionError = nil
    }
  }
}

private struct DebugNetworkWorkspace: View {
  var model: DebugWorkspaceViewModel
  let target: DebugTargetPresentation?
  let runtimeProbe: DebugRuntimeProbeSnapshot?
  let probeFailure: String?

  @State private var direction = DebugPortRuleDirection.forward
  @State private var localPort = ""
  @State private var remotePort = ""

  private var validation: DebugPortRuleValidationResult {
    DebugPortRuleValidator.validate(
      direction: direction, localPortText: localPort, remotePortText: remotePort)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.blockGap) {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: WorkspaceMetrics.blockGap) {
            ruleEditor.frame(minWidth: 320, maxWidth: 410)
            ruleList.frame(minWidth: 420, maxWidth: .infinity)
          }
          VStack(spacing: WorkspaceMetrics.blockGap) {
            ruleEditor
            ruleList
          }
        }
        protocolAndSafety
      }
      .frame(maxWidth: WorkspaceMetrics.pageMaxWidth, alignment: .topLeading)
      .padding(WorkspaceMetrics.pageInsetHorizontal)
    }
  }

  private var ruleEditor: some View {
    DebugCard(title: DebugL10n.text("debug.network.editor.title"), symbol: "plus.circle") {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
        LabeledContent(DebugL10n.text("debug.network.target")) {
          Text(target?.id ?? DebugL10n.text("debug.target.none"))
            .font(WorkspaceFont.monospacedValue)
        }
        Picker(DebugL10n.text("debug.network.direction"), selection: $direction) {
          Text(DebugL10n.text("debug.network.forward")).tag(DebugPortRuleDirection.forward)
          Text(DebugL10n.text("debug.network.reverse")).tag(DebugPortRuleDirection.reverse)
        }
        .pickerStyle(.segmented)
        TextField(DebugL10n.text("debug.network.localPort"), text: $localPort)
          .textFieldStyle(.roundedBorder)
        TextField(DebugL10n.text("debug.network.remotePort"), text: $remotePort)
          .textFieldStyle(.roundedBorder)
        validationMessage
        if case .valid(let rule) = validation {
          DebugCodeRow(
            label: DebugL10n.text("debug.network.typedRule"),
            value: "\(rule.direction.rawValue) · tcp:\(rule.localPort) → tcp:\(rule.remotePort)")
        }
        Button(DebugL10n.text("debug.network.add")) {
          guard let target, case .valid(let rule) = validation else { return }
          model.mutatePortRule(target: target, rule: rule, removing: false)
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          target == nil || model.isMutatingPortRule
            || {
              if case .valid = validation { return false }
              return true
            }())
        if let jobID = model.activePortRuleJobID {
          HStack(spacing: WorkspaceMetrics.tightGap) {
            ProgressView().controlSize(.small)
            Text(jobID).font(WorkspaceFont.monospacedDense).lineLimit(1)
            Spacer()
            Button(DebugL10n.text("debug.action.cancel")) {
              model.cancelPortRuleMutation()
            }
            .disabled(model.isCancellingPortRule)
          }
          .accessibilityIdentifier("debug.network.activeJob")
        }
        if let failure = model.portRuleFailure {
          Label(failure, systemImage: "exclamationmark.triangle")
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let terminal = model.portRuleTerminal {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
            Label(
              "\(terminal.state) · \(terminal.jobID)",
              systemImage: terminal.state == "succeeded"
                ? "checkmark.circle" : "exclamationmark.circle"
            )
            if let failure = terminal.operationFailure {
              Text(DebugL10n.text("debug.failure.\(failure.code.rawValue)"))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("debug.network.typedFailure")
            }
          }
          .font(WorkspaceFont.secondary)
          .foregroundStyle(terminal.state == "succeeded" ? .green : .orange)
        }
      }
    }
  }

  @ViewBuilder
  private var validationMessage: some View {
    switch validation {
    case .valid:
      Label(DebugL10n.text("debug.network.validation.valid"), systemImage: "checkmark.circle")
        .foregroundStyle(.green)
        .font(WorkspaceFont.secondary)
    case .invalid(let failure):
      Label(
        DebugL10n.text("debug.network.validation.\(failure.rawValue)"),
        systemImage: "exclamationmark.circle"
      )
      .foregroundStyle(localPort.isEmpty && remotePort.isEmpty ? Color.secondary : Color.red)
      .font(WorkspaceFont.secondary)
    }
  }

  private var ruleList: some View {
    DebugCard(title: DebugL10n.text("debug.network.rules.title"), symbol: "arrow.left.arrow.right")
    {
      VStack(spacing: WorkspaceMetrics.contentGap) {
        HStack {
          Text(DebugL10n.text("debug.network.rules.direction"))
          Text(DebugL10n.text("debug.network.rules.local"))
          Spacer()
          Text(DebugL10n.text("debug.network.rules.remote"))
          Text(DebugL10n.text("debug.network.rules.state"))
            .frame(width: 90, alignment: .trailing)
          Text(DebugL10n.text("debug.network.rules.action"))
            .frame(width: 72, alignment: .trailing)
        }
        .font(WorkspaceFont.label)
        .foregroundStyle(.secondary)
        Divider()
        if let runtimeProbe, runtimeProbe.targetID == target?.id,
          !runtimeProbe.portRules.isEmpty
        {
          ForEach(Array(runtimeProbe.portRules.enumerated()), id: \.offset) { _, rule in
            HStack {
              Text(rule.direction.rawValue)
              Text("tcp:\(rule.localPort)").font(WorkspaceFont.tabularSecondary)
              Spacer()
              Text("tcp:\(rule.remotePort)").font(WorkspaceFont.tabularSecondary)
              Text("active")
                .font(WorkspaceFont.label)
                .foregroundStyle(.green)
                .frame(width: 90, alignment: .trailing)
              Button(DebugL10n.text("debug.network.delete"), role: .destructive) {
                guard let target,
                  let direction = DebugPortRuleDirection(rawValue: rule.direction.rawValue)
                else { return }
                model.mutatePortRule(
                  target: target,
                  rule: DebugValidatedPortRule(
                    direction: direction,
                    localPort: rule.localPort,
                    remotePort: rule.remotePort),
                  removing: true)
              }
              .frame(width: 72, alignment: .trailing)
              .disabled(model.isMutatingPortRule)
            }
            .accessibilityElement(children: .combine)
          }
        } else {
          ContentUnavailableView {
            Label(
              DebugL10n.text("debug.network.rules.empty"),
              systemImage: "point.3.filled.connected.trianglepath.dotted")
          } description: {
            Text(probeFailure ?? DebugL10n.text("debug.network.rules.empty.detail"))
          }
          .frame(minHeight: 180)
        }
        if let warnings = runtimeProbe?.warnings.filter({ $0.contains("Rules") }),
          !warnings.isEmpty
        {
          Text(warnings.joined(separator: " · "))
            .font(WorkspaceFont.monospacedDense)
            .foregroundStyle(.orange)
        }
        Label(DebugL10n.text("debug.network.delete.scope"), systemImage: "target")
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var protocolAndSafety: some View {
    DebugCard(title: DebugL10n.text("debug.network.safety.title"), symbol: "checkmark.shield") {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
        Label(DebugL10n.text("debug.network.safety.typed"), systemImage: "number")
        Label(DebugL10n.text("debug.network.safety.noShell"), systemImage: "text.badge.xmark")
        Label(DebugL10n.text("debug.network.safety.binding"), systemImage: "link")
      }
      .font(.callout)
    }
  }
}

private struct DebugCommandsWorkspace: View {
  var model: DebugWorkspaceViewModel
  let target: DebugTargetPresentation?

  @State private var selectedTemplateID =
    DebugApplicationFacade.approvedCommandTemplates.first?.id

  private var selectedTemplate: DebugCommandTemplatePresentation? {
    DebugApplicationFacade.approvedCommandTemplates.first { $0.id == selectedTemplateID }
  }

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        // The whole tab's contract, stated before any template is chosen: a
        // closed template set with schema-defined inputs, and the argv below
        // is provider lowering echoed read-only, never an input.
        Label(
          DebugL10n.text("debug.commands.calloutTyped"),
          systemImage: "exclamationmark.shield"
        )
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary, Color.orange)
        .symbolRenderingMode(.palette)
        .padding(.horizontal, WorkspaceMetrics.pageInsetHorizontal)
        .padding(.vertical, WorkspaceMetrics.tightGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("debug.commands.typedOnly")
        Divider()
        HSplitView {
          List {
            ForEach(DebugApplicationFacade.approvedCommandTemplates, id: \.id) { template in
              Button {
                selectedTemplateID = template.id
              } label: {
                DebugCommandTemplateRow(template: template)
              }
              .buttonStyle(.plain)
              .listRowBackground(
                selectedTemplateID == template.id
                  ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
            }
          }
          .frame(minWidth: 240, idealWidth: 280, maxWidth: 330, maxHeight: .infinity)

          commandDetail
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .onChange(of: selectedTemplateID) { _, _ in model.clearCommandResult() }
  }

  private var commandDetail: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.blockGap) {
        if let template = selectedTemplate {
          DebugCard(title: template.id, symbol: "chevron.left.forwardslash.chevron.right") {
            VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
              DebugCodeRow(label: "catalog", value: "arkdeck-remote-operations@1.0.0")
              DebugCodeRow(label: "actionId", value: template.id)
              DebugCodeRow(label: "effect", value: template.effect)
              LabeledContent(DebugL10n.text("debug.commands.target")) {
                Text(target?.id ?? DebugL10n.text("debug.target.none"))
                  .font(WorkspaceFont.monospacedValue)
              }
              Text(DebugL10n.text("debug.commands.noParameters"))
                .font(.callout)
                .foregroundStyle(.secondary)
            }
          }

          DebugCard(
            title: DebugL10n.text("debug.commands.argv.title"), symbol: "list.bullet.rectangle"
          ) {
            VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
              DebugCodeRow(
                label: DebugL10n.text("debug.commands.executable"),
                value: model.commandResult.map {
                  "\($0.executable) · sha256:\($0.executableSHA256.prefix(12))"
                } ?? DebugL10n.text("debug.commands.notGenerated"))
              DebugCodeRow(
                label: DebugL10n.text("debug.commands.arguments"),
                value: model.commandResult?.argumentDisclosure.joined(separator: " ")
                  ?? DebugL10n.text("debug.commands.notGenerated"))
              if let result = model.commandResult {
                DebugCodeRow(label: "lowering sha256", value: result.loweringSHA256)
              }
              Text(DebugL10n.text("debug.commands.argv.note"))
                .font(WorkspaceFont.secondary)
                .foregroundStyle(.secondary)
            }
          }

          DebugCard(title: DebugL10n.text("debug.commands.result.title"), symbol: "doc.text") {
            VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
              HStack {
                DebugCodeRow(
                  label: DebugL10n.text("debug.commands.result.exitCode"),
                  value: model.commandResult?.exitCode.map(String.init) ?? "—")
                Spacer()
                DebugCodeRow(
                  label: DebugL10n.text("debug.commands.result.duration"),
                  value: model.commandResult.map { "\($0.durationMilliseconds) ms" } ?? "—")
              }
              Divider()
              LabeledContent(DebugL10n.text("debug.commands.result.stdout")) {
                Text(model.commandResult?.stdout ?? DebugL10n.text("debug.commands.result.none"))
                  .font(WorkspaceFont.monospacedValue)
                  .textSelection(.enabled)
              }
              LabeledContent(DebugL10n.text("debug.commands.result.stderr")) {
                Text(model.commandResult?.stderr ?? DebugL10n.text("debug.commands.result.none"))
                  .font(WorkspaceFont.monospacedValue)
                  .textSelection(.enabled)
              }
            }
          }

          HStack {
            Button(DebugL10n.text("debug.commands.run")) {
              guard let target else { return }
              model.runTemplate(target: target, templateID: template.id)
            }
            .buttonStyle(.borderedProminent)
            .disabled(target == nil || !template.isRunnable || model.isRunningCommand)
            Spacer()
            Label(DebugL10n.text("debug.commands.noPTY"), systemImage: "rectangle.slash")
              .font(WorkspaceFont.secondary)
              .foregroundStyle(.secondary)
          }
          if model.isRunningCommand { ProgressView().controlSize(.small) }
          if let failure = model.commandFailure {
            Label(failure, systemImage: "xmark.octagon")
              .font(WorkspaceFont.secondary)
              .foregroundStyle(.red)
              .textSelection(.enabled)
          }
          Text(DebugL10n.text("debug.commands.footerNoFreeText"))
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("debug.commands.footer")
        } else {
          ContentUnavailableView(DebugL10n.text("debug.commands.select"), systemImage: "terminal")
        }
      }
      .frame(maxWidth: WorkspaceMetrics.pageMaxWidth, alignment: .topLeading)
      .padding(WorkspaceMetrics.pageInsetHorizontal)
    }
  }
}

private struct DebugCommandTemplateRow: View {
  let template: DebugCommandTemplatePresentation

  private var symbol: String {
    template.effect == "readOnly"
      ? "doc.text.magnifyingglass" : "exclamationmark.shield"
  }

  private var effectColor: Color {
    template.effect == "readOnly" ? .secondary : .orange
  }

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
        Text(template.id).font(WorkspaceFont.monospacedValue)
        Text(template.effect)
          .font(WorkspaceFont.caption)
          .foregroundStyle(effectColor)
      }
    } icon: {
      Image(systemName: symbol)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct DebugAvailabilityCard: View {
  let operation: DebugOperationPresentation?

  var body: some View {
    DebugCard(title: DebugL10n.text("debug.availability.title"), symbol: "checkmark.seal") {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
        if let operation {
          DebugCodeRow(
            label: DebugL10n.text("debug.availability.operation"), value: operation.reference)
          switch operation.availability {
          case .checking:
            Label(DebugL10n.text("debug.availability.checking"), systemImage: "hourglass")
          case .available:
            Label(
              DebugL10n.text("debug.availability.available"), systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
          case .unavailable(let reasons):
            Label(
              DebugL10n.text("debug.availability.unavailable"), systemImage: "xmark.octagon.fill"
            )
            .foregroundStyle(.red)
            ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
              Text(reason)
                .font(WorkspaceFont.monospacedDense)
                .textSelection(.enabled)
            }
          }
          Text(
            LocalizedStringResource.DebugLocalizable.debugAvailabilityEffect(
              operation.minimumEffect)
          )
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
        } else {
          DebugBlockedReason(text: DebugL10n.text("debug.availability.missing"))
        }
      }
    }
  }
}

private struct DebugRecentJobsCard: View {
  var model: DebugWorkspaceViewModel
  let jobs: [DebugJobPresentation]

  var body: some View {
    DebugCard(title: DebugL10n.text("debug.jobs.title"), symbol: "clock.arrow.circlepath") {
      if jobs.isEmpty {
        Text(DebugL10n.text("debug.jobs.empty"))
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 54, alignment: .center)
      } else {
        VStack(spacing: WorkspaceMetrics.tightGap) {
          ForEach(jobs.prefix(5)) { job in
            VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
              HStack(spacing: WorkspaceMetrics.contentGap) {
                Image(systemName: job.needsAttention ? "exclamationmark.triangle" : "circle.fill")
                  .font(WorkspaceFont.caption)
                  .foregroundStyle(job.needsAttention ? .orange : .secondary)
                VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
                  Text(job.id).font(WorkspaceFont.monospacedValue)
                  Text("\(job.targetID) · \(job.operationReference)")
                    .font(WorkspaceFont.monospacedDense)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(job.state)
                  .font(WorkspaceFont.label)
                if job.isActive {
                  Button {
                    model.cancelOutstandingJob(job)
                  } label: {
                    HStack(spacing: WorkspaceMetrics.rowGap) {
                      if model.isCancellingOutstandingJob(job.id) {
                        ProgressView().controlSize(.mini)
                      }
                      Text(DebugL10n.text("debug.action.cancel"))
                    }
                  }
                  .controlSize(.small)
                  .disabled(model.isCancellingOutstandingJob(job.id))
                  .accessibilityIdentifier("debug.jobs.cancel.\(job.id)")
                }
              }
              if let failure = job.operationFailure {
                Text(DebugL10n.text("debug.failure.\(failure.code.rawValue)"))
                  .font(WorkspaceFont.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(3)
                  .accessibilityIdentifier("debug.jobs.typedFailure.\(job.id)")
              } else if let latest = job.timeline.last {
                Text(latest)
                  .font(WorkspaceFont.monospacedDense)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
            }
          }
        }
      }
    }
  }
}

private struct DebugCard<Content: View>: View {
  let title: String
  let symbol: String
  @ViewBuilder let content: Content

  var body: some View {
    WorkspaceTitledCard(Text(title), symbol: symbol) {
      content
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }
}

private struct DebugCodeRow: View {
  let label: String
  let value: String

  var body: some View {
    LabeledContent(label) {
      Text(value)
        .font(WorkspaceFont.monospacedValue)
        .textSelection(.enabled)
        .multilineTextAlignment(.trailing)
    }
  }
}

private struct DebugBlockedReason: View {
  let text: String

  var body: some View {
    Label(text, systemImage: "lock.fill")
      .font(WorkspaceFont.secondary)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityElement(children: .combine)
  }
}

private func effectSymbol(_ effect: String) -> String {
  switch effect {
  case "deviceMutation": "arrow.triangle.2.circlepath"
  case "destructive": "exclamationmark.triangle.fill"
  case "readOnly": "eye"
  default: "desktopcomputer"
  }
}

private func effectColor(_ effect: String) -> Color {
  switch effect {
  case "deviceMutation": .orange
  case "destructive": .red
  default: .secondary
  }
}

@MainActor
@Observable
final class DebugWorkspaceViewModel {
  private(set) var workspace = DebugWorkspacePresentation.loading
  private(set) var isRefreshing = false
  private(set) var artifactsByJobID: [String: [RuntimeArtifactPresentation]] = [:]
  private(set) var exportStatesByArtifactID: [String: RuntimeArtifactExportState] = [:]
  private(set) var isSubmittingLogs = false
  private(set) var isCancellingLogs = false
  private(set) var activeLogJobID: String?
  private(set) var logTerminal: DebugLogJobTerminalPresentation?
  private(set) var logFailure: String?
  private(set) var isRunningCommand = false
  private(set) var commandResult: DebugRuntimeCommandResult?
  private(set) var commandFailure: String?
  private(set) var isMutatingPortRule = false
  private(set) var isCancellingPortRule = false
  private(set) var activePortRuleJobID: String?
  private(set) var portRuleTerminal: DebugLogJobTerminalPresentation?
  private(set) var portRuleFailure: String?
  private(set) var isSubmittingHAP = false
  private(set) var isCancellingHAP = false
  private(set) var activeHAPJobID: String?
  private(set) var hapTerminal: DebugLogJobTerminalPresentation?
  private(set) var hapFailure: String?
  private(set) var cancellingOutstandingJobIDs: Set<String> = []

  private let provider: any DebugApplicationProviding
  private let detailProvider: any RuntimeJobDetailApplicationProviding

  init(
    provider: any DebugApplicationProviding,
    detailProvider: (any RuntimeJobDetailApplicationProviding)? = nil
  ) {
    self.provider = provider
    self.detailProvider = detailProvider ?? RuntimeJobDetailApplicationFacade.make()
  }

  fileprivate func runtimeArtifactRows(
    operationReference: String,
    targetID: String?
  ) -> [DebugRuntimeArtifactRow] {
    workspace.jobs
      .filter {
        $0.operationReference == operationReference
          && (targetID == nil || $0.targetID == targetID)
      }
      .flatMap { job in
        (artifactsByJobID[job.id] ?? []).map {
          DebugRuntimeArtifactRow(jobID: job.id, artifact: $0)
        }
      }
  }

  func exportArtifact(
    jobID: String,
    artifact: RuntimeArtifactPresentation,
    destinationURL: URL,
    allowSensitive: Bool
  ) {
    guard exportStatesByArtifactID[artifact.id] != .exporting else { return }
    exportStatesByArtifactID[artifact.id] = .exporting
    let detailProvider = detailProvider
    Task { [weak self] in
      let result = await detailProvider.exportArtifact(
        jobID: jobID,
        artifact: artifact,
        destinationURL: destinationURL,
        allowSensitive: allowSensitive)
      guard let self, !Task.isCancelled else { return }
      switch result {
      case .completed(let url):
        self.exportStatesByArtifactID[artifact.id] = .completed(url)
      case .failed(let reason):
        self.exportStatesByArtifactID[artifact.id] = .failed(reason)
      }
    }
  }

  func refresh(targetID: String? = nil) {
    guard !isRefreshing else { return }
    isRefreshing = true
    let provider = provider
    let detailProvider = detailProvider
    Task { [weak self] in
      let next = await provider.refreshWorkspace(targetID: targetID)
      var artifacts: [String: [RuntimeArtifactPresentation]] = [:]
      for job in next.jobs.prefix(6) {
        let detail = await detailProvider.loadJobDetail(
          jobID: job.id,
          operationReference: job.operationReference)
        if case .available = detail.artifactAvailability {
          artifacts[job.id] = detail.artifacts
        }
      }
      guard let self else { return }
      defer { self.isRefreshing = false }
      guard !Task.isCancelled else { return }
      self.workspace = next
      self.artifactsByJobID = artifacts
    }
  }

  func submitLogs(
    target: DebugTargetPresentation,
    durationSeconds: Int,
    filters: [String]
  ) {
    guard !isSubmittingLogs else { return }
    isSubmittingLogs = true
    activeLogJobID = nil
    logTerminal = nil
    logFailure = nil
    let provider = provider
    Task { [weak self] in
      let submitted = await provider.submitLogs(
        target: target, durationSeconds: durationSeconds, filters: filters)
      guard let self, !Task.isCancelled else { return }
      switch submitted {
      case .failed(let failure):
        self.logFailure = failure
        self.isSubmittingLogs = false
      case .submitted(let acceptance):
        self.activeLogJobID = acceptance.jobID
        let polling = Task { @MainActor [weak self] in
          while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { break }
            self?.refresh(targetID: target.id)
          }
        }
        let result = await provider.run(jobID: acceptance.jobID)
        polling.cancel()
        guard !Task.isCancelled else { return }
        self.activeLogJobID = nil
        self.isSubmittingLogs = false
        switch result {
        case .completed(let terminal): self.logTerminal = terminal
        case .failed(let failure): self.logFailure = failure
        }
        self.refresh(targetID: target.id)
      }
    }
  }

  func cancelLogs() {
    guard let jobID = activeLogJobID, !isCancellingLogs else { return }
    isCancellingLogs = true
    let provider = provider
    Task { [weak self] in
      let accepted = await provider.cancel(jobID: jobID)
      guard let self else { return }
      self.isCancellingLogs = false
      if !accepted { self.logFailure = "Runtime refused the cancellation request" }
    }
  }

  func submitHAP(
    target: DebugTargetPresentation,
    fileURL: URL,
    bundleName: String,
    abilityName: String,
    installPolicy: String,
    cleanupPolicy: String,
    postRunAbilityState: String,
    captureDiagnostics: Bool,
    diagnosticsDurationSeconds: Int
  ) {
    guard !isSubmittingHAP else { return }
    isSubmittingHAP = true
    activeHAPJobID = nil
    hapTerminal = nil
    hapFailure = nil
    let provider = provider
    Task { [weak self] in
      let submitted = await provider.submitHAP(
        target: target, fileURL: fileURL, bundleName: bundleName, abilityName: abilityName,
        installPolicy: installPolicy, cleanupPolicy: cleanupPolicy,
        postRunAbilityState: postRunAbilityState,
        captureDiagnostics: captureDiagnostics,
        diagnosticsDurationSeconds: diagnosticsDurationSeconds)
      guard let self, !Task.isCancelled else { return }
      switch submitted {
      case .failed(let failure):
        self.hapFailure = failure
        self.isSubmittingHAP = false
      case .submitted(let acceptance):
        self.activeHAPJobID = acceptance.jobID
        let polling = Task { @MainActor [weak self] in
          while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { break }
            self?.refresh(targetID: target.id)
          }
        }
        let result = await provider.run(jobID: acceptance.jobID)
        polling.cancel()
        guard !Task.isCancelled else { return }
        self.activeHAPJobID = nil
        self.isSubmittingHAP = false
        switch result {
        case .completed(let terminal): self.hapTerminal = terminal
        case .failed(let failure): self.hapFailure = failure
        }
        self.refresh(targetID: target.id)
      }
    }
  }

  func cancelHAP() {
    guard let jobID = activeHAPJobID, !isCancellingHAP else { return }
    isCancellingHAP = true
    let provider = provider
    Task { [weak self] in
      let accepted = await provider.cancel(jobID: jobID)
      guard let self else { return }
      self.isCancellingHAP = false
      if !accepted { self.hapFailure = "Runtime refused the cancellation request" }
    }
  }

  func isCancellingOutstandingJob(_ jobID: String) -> Bool {
    cancellingOutstandingJobIDs.contains(jobID)
  }

  func cancelOutstandingJob(_ job: DebugJobPresentation) {
    guard job.isActive, !isCancellingOutstandingJob(job.id) else { return }
    cancellingOutstandingJobIDs.insert(job.id)
    let provider = provider
    Task { [weak self] in
      guard let self else { return }
      defer { self.cancellingOutstandingJobIDs.remove(job.id) }
      guard await provider.cancel(jobID: job.id) else {
        self.recordCancellationFailure(for: job)
        return
      }
      for _ in 0..<80 {
        guard !Task.isCancelled else { return }
        let next = await provider.refreshWorkspace(targetID: job.targetID)
        guard !Task.isCancelled else { return }
        self.workspace = next
        guard next.jobs.first(where: { $0.id == job.id })?.isActive == true else { return }
        try? await Task.sleep(for: .milliseconds(750))
      }
    }
  }

  private func recordCancellationFailure(for job: DebugJobPresentation) {
    let message = "Runtime refused the cancellation request"
    switch job.operationReference {
    case DebugApplicationFacade.debugHAPReference: hapFailure = message
    case DebugApplicationFacade.captureDiagnosticsReference: logFailure = message
    default: portRuleFailure = message
    }
  }

  func mutatePortRule(
    target: DebugTargetPresentation,
    rule: DebugValidatedPortRule,
    removing: Bool
  ) {
    guard !isMutatingPortRule else { return }
    isMutatingPortRule = true
    activePortRuleJobID = nil
    portRuleTerminal = nil
    portRuleFailure = nil
    let provider = provider
    Task { [weak self] in
      let submitted = await provider.submitPortRule(
        target: target, rule: rule, removing: removing)
      guard let self, !Task.isCancelled else { return }
      switch submitted {
      case .failed(let failure):
        self.portRuleFailure = failure
        self.isMutatingPortRule = false
      case .submitted(let acceptance):
        self.activePortRuleJobID = acceptance.jobID
        let polling = Task { @MainActor [weak self] in
          while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { break }
            self?.refresh(targetID: target.id)
          }
        }
        let result = await provider.run(jobID: acceptance.jobID)
        polling.cancel()
        guard !Task.isCancelled else { return }
        self.activePortRuleJobID = nil
        self.isMutatingPortRule = false
        switch result {
        case .completed(let terminal): self.portRuleTerminal = terminal
        case .failed(let failure): self.portRuleFailure = failure
        }
        self.refresh(targetID: target.id)
      }
    }
  }

  func cancelPortRuleMutation() {
    guard let jobID = activePortRuleJobID, !isCancellingPortRule else { return }
    isCancellingPortRule = true
    let provider = provider
    Task { [weak self] in
      let accepted = await provider.cancel(jobID: jobID)
      guard let self else { return }
      self.isCancellingPortRule = false
      if !accepted { self.portRuleFailure = "Runtime refused the cancellation request" }
    }
  }

  func runTemplate(target: DebugTargetPresentation, templateID: String) {
    guard !isRunningCommand else { return }
    isRunningCommand = true
    commandResult = nil
    commandFailure = nil
    let provider = provider
    Task { [weak self] in
      let result = await provider.runTemplate(target: target, templateID: templateID)
      guard let self else { return }
      self.isRunningCommand = false
      switch result {
      case .success(let command): self.commandResult = command
      case .failure(let failure): self.commandFailure = failure.message
      }
    }
  }

  func clearCommandResult() {
    commandResult = nil
    commandFailure = nil
  }
}

private enum DebugL10n {
  static func text(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "DebugLocalizable")
  }
}

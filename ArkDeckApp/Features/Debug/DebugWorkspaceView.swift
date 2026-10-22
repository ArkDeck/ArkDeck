import AppKit
import ArkDeckClientKit
import ArkDeckCore
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum DebugWorkspaceTab: String, CaseIterable, Hashable {
  case artifacts
  case logs
  case apps
  case network
  case commands

  var title: String {
    DebugL10n.text("debug.tab.\(rawValue)")
  }

  /// §14: the tab's stable product capability in the shared registry.
  var productCapability: AppDebugTabCapability {
    switch self {
    case .artifacts: .artifacts
    case .logs: .logs
    case .apps: .apps
    case .network: .network
    case .commands: .commands
    }
  }

  var symbol: String {
    switch self {
    case .artifacts: "shippingbox.and.arrow.backward"
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
  let historyContext: RuntimeHistoryWorkspaceContext?

  @SceneStorage("debug.workspace.tab")
  private var storedTab = DebugWorkspaceTab.artifacts.rawValue
  @SceneStorage("debug.workspace.target") private var selectedTargetID: String?
  @State private var showsTabKeyboardFocus = false
  @FocusState private var focusedTab: DebugWorkspaceTab?

  private var selectedTab: DebugWorkspaceTab {
    DebugWorkspaceTab(rawValue: storedTab) ?? .artifacts
  }

  private var selectedTarget: DebugTargetPresentation? {
    model.workspace.targets.first { $0.id == selectedTargetID }
  }

  private var activeJobs: [DebugJobPresentation] {
    model.workspace.jobs.filter(\.isActive)
  }

  private func relatedJobs(for operationReference: String) -> [DebugJobPresentation] {
    model.workspace.jobs.filter { job in
      job.operationReference == operationReference
        && (selectedTarget.map { job.targetID == $0.id } ?? true)
    }
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
    .focusedSceneValue(\.workspaceRefresh, WorkspaceKeyboardAction(
      title: DebugL10n.text("debug.action.refresh"),
      isEnabled: !model.isRefreshing,
      perform: { model.refresh(targetID: selectedTargetID) }))
    .onAppear(perform: reconcileTargetSelection)
    .onChange(of: historyContext?.id, initial: true) { _, _ in
      if historyContext == nil { reconcileTargetSelection() } else { applyHistoryContext() }
    }
    .onChange(of: model.workspace.targets) { _, _ in reconcileTargetSelection() }
    .onChange(of: model.hasLoadedWorkspace) { _, _ in reconcileTargetSelection() }
    .onChange(of: selectedTargetID, initial: true) { _, targetID in
      model.selectTarget(targetID)
    }
  }

  /// The scope line and the target this page submits against — the page's own
  /// chrome, and nothing else.
  ///
  /// Three per-operation availability badges used to stack here, restating
  /// what the `Runtime availability` card inside every panel already said.
  /// Availability is now one line beside the section title it gates, so the
  /// header is a sentence and a target rather than a third column of state.
  private var workspaceHeader: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
      // The page title lives in the window toolbar; repeating it here would
      // give the detail two perceivable main headings. Only the scope line
      // stays.
      WorkspaceHeaderBar(
        summary: Text(DebugL10n.text("debug.scope")),
        summaryIdentifier: "debug.scope"
      ) {
        targetPicker
      }
      if let failure = model.workspace.targetLoadFailure {
        WorkspaceNotice(tone: .danger, identifier: "debug.target.failure") {
          Text(failure).textSelection(.enabled)
        }
      }
    }
  }

  private var targetPicker: some View {
    HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.tightGap) {
      Text(DebugL10n.text("debug.target.label"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
      Picker(DebugL10n.text("debug.target.label"), selection: Binding(
        get: { selectedTargetID },
        set: { model.nativeLibraryBatch.invalidate(); selectedTargetID = $0 }
      )) {
        Text(DebugL10n.text("debug.target.none")).tag(String?.none)
        ForEach(model.workspace.targets) { target in
          Text(target.id).tag(Optional(target.id))
        }
      }
      .labelsHidden()
      .frame(width: 230)
      .accessibilityIdentifier("debug.target")
      if let selectedTarget {
        WorkspaceChip(
          text: Text(
            String(
              localized: LocalizedStringResource.DebugLocalizable.debugTargetBinding(
                Int32(clamping: selectedTarget.bindingRevision), selectedTarget.toolVersion))),
          symbol: "link",
          identifier: "debug.target.binding")
      }
    }
  }

  private var tabPicker: some View {
    HStack(spacing: WorkspaceMetrics.rowGap) {
      ForEach(DebugWorkspaceTab.allCases, id: \.self) { tab in
        Button {
          activateTab(tab)
        } label: {
          Label(tab.title, systemImage: tab.symbol)
            .font(WorkspaceFont.secondary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, WorkspaceMetrics.tightGap)
            .padding(.vertical, WorkspaceMetrics.rowGap)
            .background(
              selectedTab == tab ? Color.accentColor.opacity(0.14) : Color.clear,
              in: RoundedRectangle(
                cornerRadius: WorkspaceMetrics.controlRadius)
            )
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .focused($focusedTab, equals: tab)
        .overlay {
          if focusedTab == tab && showsTabKeyboardFocus {
            RoundedRectangle(
              cornerRadius: WorkspaceMetrics.controlRadius
            )
            .strokeBorder(Color.accentColor, lineWidth: 2)
          }
        }
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
        .accessibilityIdentifier("debug.tab.\(tab.rawValue)")
        .onKeyPress(.leftArrow) { moveSelectedTab(by: -1) }
        .onKeyPress(.rightArrow) { moveSelectedTab(by: 1) }
        .onKeyPress(.home) { selectTab(DebugWorkspaceTab.allCases.first) }
        .onKeyPress(.end) { selectTab(DebugWorkspaceTab.allCases.last) }
      }
    }
    .padding(WorkspaceMetrics.rowGap)
    .frame(maxWidth: 620)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(
        cornerRadius: WorkspaceMetrics.insetRadius)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkspaceMetrics.insetRadius)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(DebugL10n.text("debug.tabs.label"))
    .accessibilityIdentifier("debug.tabs")
    .onChange(of: focusedTab) { _, tab in
      if tab == nil {
        showsTabKeyboardFocus = false
      } else if currentEventUsesKeyboard {
        showsTabKeyboardFocus = true
      }
    }
  }

  @ViewBuilder
  private var selectedWorkspace: some View {
    switch selectedTab {
    case .artifacts:
      DebugArtifactsWorkspace(
        model: model,
        operation: model.workspace.operation(
          DebugApplicationFacade.nativeLibraryReference),
        target: selectedTarget,
        relatedJobs: relatedJobs(for: DebugApplicationFacade.nativeLibraryReference),
        runtimeArtifacts: model.runtimeArtifactRows(
          operationReference: DebugApplicationFacade.nativeLibraryReference,
          targetID: selectedTarget?.id),
        onOpenLogs: { storedTab = DebugWorkspaceTab.logs.rawValue })
    case .logs:
      DebugLogsWorkspace(
        model: model,
        operation: model.workspace.operation(
          DebugApplicationFacade.captureDiagnosticsReference),
        target: selectedTarget,
        relatedJobs: relatedJobs(for: DebugApplicationFacade.captureDiagnosticsReference),
        runtimeArtifacts: model.runtimeArtifactRows(
          operationReference: DebugApplicationFacade.captureDiagnosticsReference,
          targetID: selectedTarget?.id))
    case .apps:
      DebugAppsWorkspace(
        model: model,
        operation: model.workspace.operation(DebugApplicationFacade.debugHAPReference),
        target: selectedTarget,
        relatedJobs: relatedJobs(for: DebugApplicationFacade.debugHAPReference),
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
      DebugCommandsWorkspace(
        model: model,
        operation: model.workspace.operation(DebugApplicationFacade.debugTemplateReference),
        target: selectedTarget,
        relatedJobs: relatedJobs(for: DebugApplicationFacade.debugTemplateReference),
        runtimeArtifacts: model.runtimeArtifactRows(
          operationReference: DebugApplicationFacade.debugTemplateReference,
          targetID: selectedTarget?.id))
    }
  }

  private func reconcileTargetSelection() {
    if let historyContext, historyContext.workspaceKind == .debug {
      selectedTargetID = historyContext.targetID
      return
    }
    selectedTargetID = DebugWorkspaceRefreshState.reconciledTarget(
      selectedTargetID, targets: model.workspace.targets.map(\.id),
      hasLoaded: model.hasLoadedWorkspace,
      loadFailed: model.workspace.targetLoadFailure != nil)
  }

  private func applyHistoryContext() {
    guard let historyContext, historyContext.workspaceKind == .debug else { return }
    selectedTargetID = historyContext.targetID
    let tab: DebugWorkspaceTab =
      switch historyContext.operationReference {
      case DebugApplicationFacade.debugHAPReference: .apps
      case DebugApplicationFacade.nativeLibraryReference: .artifacts
      case DebugApplicationFacade.createPortForwardReference,
        DebugApplicationFacade.removePortForwardReference:
        .network
      case DebugApplicationFacade.captureDiagnosticsReference: .logs
      case DebugApplicationFacade.debugTemplateReference: .commands
      default: .artifacts
      }
    activateTab(tab)
    model.rememberHistoryContext(historyContext)
  }

  private func moveSelectedTab(by offset: Int) -> KeyPress.Result {
    let tabs = DebugWorkspaceTab.allCases
    guard
      let selected = DebugWorkspaceTab(rawValue: storedTab),
      let index = tabs.firstIndex(of: selected),
      !tabs.isEmpty
    else { return .ignored }
    let nextIndex = (index + offset + tabs.count) % tabs.count
    let nextTab = tabs[nextIndex]
    storedTab = nextTab.rawValue
    focusedTab = nextTab
    showsTabKeyboardFocus = true
    return .handled
  }

  private func selectTab(_ tab: DebugWorkspaceTab?) -> KeyPress.Result {
    guard let tab else { return .ignored }
    storedTab = tab.rawValue
    focusedTab = tab
    showsTabKeyboardFocus = true
    return .handled
  }

  private func activateTab(_ tab: DebugWorkspaceTab) {
    storedTab = tab.rawValue
    focusedTab = tab
    // A selected tab and a keyboard focus ring communicate different state.
    // Keep focus for arrow/Home/End navigation after a click, but only draw
    // the ring for keyboard-originated activation (the macOS focus-visible
    // convention). Pointer clicks use the quieter selected background alone.
    showsTabKeyboardFocus = currentEventUsesKeyboard
  }

  private var currentEventUsesKeyboard: Bool {
    switch NSApp.currentEvent?.type {
    case .keyDown, .keyUp, .flagsChanged:
      true
    default:
      false
    }
  }
}

struct DebugRuntimeArtifactRow: Identifiable {
  let jobID: String
  let artifact: RuntimeArtifactPresentation

  var id: String { "\(jobID):\(artifact.id)" }
}

struct DebugAccessibilityStatus: Equatable {
  let message: String
  let isUrgent: Bool
}

/// AppKit supplies the native macOS announcement channel that SwiftUI does
/// not expose as a stable live-region modifier. This bridge observes only the
/// coarse Native Debug state, so live HiLog lines are never announced one by
/// one.
struct DebugAccessibilityAnnouncementBridge: View {
  let status: DebugAccessibilityStatus?

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
      .onChange(of: status) { _, status in
        guard let status, let application = NSApp else { return }
        unsafe NSAccessibility.post(
          element: application,
          notification: .announcementRequested,
          userInfo: [
            .announcement: status.message,
            .priority: NSNumber(value: status.isUrgent ? 90 : 50),
          ])
      }
  }
}

struct DebugRemoteLibrarySelection: Equatable {
  let sourceID: UUID
  let sourceName: String
  let entry: RemoteBuildDirectoryEntry

  var identityURL: URL {
    var components = URLComponents()
    components.scheme = "arkdeck-remote"
    components.host = sourceID.uuidString.lowercased()
    components.path = "/\(entry.relativePath)"
    return components.url ?? URL(filePath: "/invalid-remote-selection")
  }
}

struct DebugRemoteBuildBrowserSheet: View {
  @Environment(\.dismiss) private var dismiss
  var model: DebugRemoteBuildBrowserViewModel
  let onChoose: (DebugRemoteLibrarySelection) -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: WorkspaceMetrics.contentGap) {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
          Text(DebugL10n.text("debug.artifacts.remoteBrowser.title"))
            .font(.title2.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
          Text(DebugL10n.text("debug.artifacts.remoteBrowser.detail"))
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if model.isLoading { ProgressView().controlSize(.small) }
      }
      .padding(WorkspaceMetrics.pageInsetHorizontal)
      Divider()
      if model.sources.isEmpty && !model.isLoading {
        ContentUnavailableView {
          Label(
            DebugL10n.text("debug.artifacts.remoteBrowser.empty.title"),
            systemImage: "server.rack")
        } description: {
          Text(DebugL10n.text("debug.artifacts.remoteBrowser.empty.detail"))
        } actions: {
          SettingsLink {
            Label(
              DebugL10n.text("debug.artifacts.remoteBrowser.openSettings"),
              systemImage: "gearshape")
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        VStack(spacing: WorkspaceMetrics.contentGap) {
          HStack(spacing: WorkspaceMetrics.contentGap) {
            Picker(
              DebugL10n.text("debug.artifacts.remoteBrowser.server"),
              selection: Binding(
                get: { model.selectedSourceID },
                set: { model.selectSource($0) })
            ) {
              ForEach(model.sources) { source in
                Text("\(source.name) · \(source.endpoint)").tag(Optional(source.id))
              }
            }
            Button {
              model.goUp()
            } label: {
              Label(DebugL10n.text("debug.artifacts.remoteBrowser.up"), systemImage: "arrow.up")
            }
            .disabled(!model.canGoUp)
            Button {
              model.reload()
            } label: {
              Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel(DebugL10n.text("debug.artifacts.remoteBrowser.refresh"))
            .disabled(model.selectedSourceID == nil || model.isLoading)
          }
          HStack(spacing: WorkspaceMetrics.tightGap) {
            Image(systemName: "folder")
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
            Text(
              !model.requestedRelativePath.isEmpty
                ? model.requestedRelativePath
                : DebugL10n.text("debug.artifacts.remoteBrowser.root")
            )
            .font(WorkspaceFont.monospacedValue)
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer()
          }
          .padding(.horizontal, WorkspaceMetrics.tightGap)
          List {
            ForEach(model.listing?.entries ?? []) { entry in
              Button {
                model.open(entry)
              } label: {
                DebugRemoteBuildEntryRow(
                  entry: entry,
                  isSelected: model.selectedEntry?.id == entry.id)
              }
              .buttonStyle(.plain)
              .accessibilityLabel(entry.name)
              .accessibilityValue(
                entry.kind == .directory
                  ? DebugL10n.text("debug.artifacts.remoteBrowser.directory")
                  : DebugL10n.text("debug.artifacts.remoteBrowser.library"))
            }
          }
          .disabled(model.isLoading)
          .overlay {
            if model.listing?.entries.isEmpty == true && !model.isLoading {
              ContentUnavailableView(
                DebugL10n.text("debug.artifacts.remoteBrowser.noArtifacts"),
                systemImage: "shippingbox")
            }
          }
          if let errorMessage = model.errorMessage {
            WorkspaceNotice(tone: .danger, symbol: "xmark.octagon") {
              Text(errorMessage)
            }
          }
        }
        .padding(WorkspaceMetrics.pageInsetHorizontal)
      }
      Divider()
      HStack {
        Button(DebugL10n.text("debug.artifacts.remoteBrowser.cancel")) { dismiss() }
        Spacer()
        Button(DebugL10n.text("debug.artifacts.remoteBrowser.choose")) {
          guard let source = model.selectedSource, let entry = model.selectedLibraryEntry else {
            return
          }
          onChoose(
            DebugRemoteLibrarySelection(
              sourceID: source.id, sourceName: source.name, entry: entry))
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.selectedLibraryEntry == nil)
      }
      .padding(WorkspaceMetrics.pageInsetHorizontal)
    }
    .frame(width: 780, height: 640)
    .task { model.loadSources() }
  }
}

struct DebugRemoteBuildEntryRow: View {
  let entry: RemoteBuildDirectoryEntry
  let isSelected: Bool

  private var isDirectory: Bool { entry.kind == .directory }

  var body: some View {
    HStack(spacing: WorkspaceMetrics.contentGap) {
      Image(systemName: isDirectory ? "folder.fill" : "shippingbox.fill")
        .foregroundStyle(isDirectory ? Color.secondary : Color.accentColor)
        .frame(width: 22)
        .accessibilityHidden(true)
      Text(entry.name)
        .font(WorkspaceFont.monospacedValue)
      Spacer()
      if let byteCount = entry.byteCount, !isDirectory {
        Text(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))
          .font(WorkspaceFont.tabularSecondary)
          .foregroundStyle(.secondary)
      }
      if isDirectory {
        Image(systemName: "chevron.right")
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      } else if isSelected {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.tint)
          .accessibilityHidden(true)
      }
    }
    .contentShape(.rect)
  }
}

struct DebugNativeLibraryBatchSheet: View {
  @Environment(\.dismiss) private var dismiss
  var model: DebugWorkspaceViewModel

  var body: some View {
    let batch = model.nativeLibraryBatch
    VStack(alignment: .leading, spacing: WorkspaceMetrics.blockGap) {
      Text(DebugL10n.text("debug.artifacts.batch.review"))
        .font(WorkspaceFont.sectionTitle).accessibilityAddTraits(.isHeader)
      WorkspaceNotice(tone: .warning) {
        Text(DebugL10n.text("debug.artifacts.batch.warning"))
      }
      if let target = batch.target {
        Text("\(target.id) · binding r\(target.bindingRevision) · \(batch.targetBundle)")
          .font(WorkspaceFont.monospacedValue).textSelection(.enabled)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
          ForEach(batch.rows) { row in
            if let plan = row.preparation {
              DisclosureGroup {
                VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
                  Text("SHA-256: \(plan.sha256)")
                  Text("Plan: \(plan.planDigest)")
                  ForEach(plan.steps) { step in Text("\(step.id) · \(step.kind) · \(step.effect)") }
                }
                .font(WorkspaceFont.monospacedDense).textSelection(.enabled)
              } label: {
                Text("\(plan.libraryName) · \(plan.abi) · \(plan.byteCount) B")
                  .font(WorkspaceFont.monospacedValue)
              }
            }
          }
        }
      }
      .frame(minHeight: 240, maxHeight: 380)
      HStack {
        Button(DebugL10n.text("debug.artifacts.sheet.back")) { dismiss() }
        Spacer()
        Button(DebugL10n.text("debug.artifacts.batch.run")) {
          let targetID = batch.target?.id
          Task {
            await batch.submitReviewed()
            model.refresh(targetID: targetID)
          }
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(batch.phase != .review || batch.isBusy || batch.stopRequested)
        .accessibilityIdentifier("debug.artifacts.batch.submit")
      }
    }
    .padding(WorkspaceMetrics.pageInsetHorizontal)
    .frame(minWidth: 700, minHeight: 480)
  }
}

struct DebugNativeLibraryPlanSheet: View {
  @Environment(\.dismiss) private var dismiss
  var model: DebugWorkspaceViewModel
  let preparation: DebugNativeLibraryPreparation

  var body: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.blockGap) {
      Text(DebugL10n.text("debug.artifacts.sheet.title"))
        .font(.title2.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      WorkspaceNotice(tone: .warning) {
        Text(DebugL10n.text("debug.artifacts.sheet.warning"))
      }
      WorkspaceFactGrid {
        planFact(
          DebugL10n.text("debug.artifacts.sheet.target"),
          "\(preparation.targetID) · binding r\(preparation.bindingRevision)")
        planFact(DebugL10n.text("debug.artifacts.sheet.library"), preparation.libraryName)
        planFact(DebugL10n.text("debug.artifacts.sheet.bundle"), preparation.targetBundle)
        planFact("effect", "deviceMutation")
        planFact(
          DebugL10n.text("debug.artifacts.sheet.verification"),
          DebugL10n.text("debug.artifacts.verify.maps"))
        planFact(
          DebugL10n.text("debug.artifacts.sheet.rollback"),
          DebugL10n.text("debug.artifacts.rollback.auto"))
        planFact(DebugL10n.text("debug.artifacts.sheet.digest"), preparation.planDigest)
      }
      Divider()
      Text(DebugL10n.text("debug.artifacts.sheet.steps"))
        .font(WorkspaceFont.sectionTitle)
        .accessibilityAddTraits(.isHeader)
      ScrollView {
        VStack(spacing: WorkspaceMetrics.tightGap) {
          ForEach(preparation.steps.enumerated(), id: \.element.id) { index, step in
            HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.contentGap) {
              Text("\(index + 1)")
                .font(WorkspaceFont.tabularSecondary)
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
              Image(systemName: effectSymbol(step.effect))
                .foregroundStyle(effectColor(step.effect))
                .accessibilityHidden(true)
              VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
                Text(step.id).font(.callout.monospaced().weight(.medium))
                Text("\(step.kind) · \(step.effect)")
                  .font(WorkspaceFont.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
            }
            .accessibilityElement(children: .combine)
            if index < preparation.steps.count - 1 { Divider() }
          }
        }
      }
      .frame(minHeight: 220, maxHeight: 300)
      HStack {
        Button(DebugL10n.text("debug.artifacts.sheet.back")) { dismiss() }
        Spacer()
        Button(DebugL10n.text("debug.artifacts.sheet.run")) {
          model.submitNativeLibrary(preparation)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("debug.artifacts.submit")
      }
    }
    .padding(WorkspaceMetrics.pageInsetHorizontal)
    .frame(minWidth: 700, minHeight: 620)
  }

  private func planFact(_ name: String, _ value: String) -> WorkspaceFactRow {
    WorkspaceFactRow(name: Text(name), value: Text(value), isSelectable: true)
  }
}

struct DebugNetworkWorkspace: View {
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

  private var feedbackMatchesTarget: Bool {
    model.portRuleFeedbackMatches(target: target)
  }

  private var scopedActiveJobID: String? {
    feedbackMatchesTarget ? model.activePortRuleJobID : nil
  }

  private var scopedTerminal: DebugLogJobTerminalPresentation? {
    feedbackMatchesTarget ? model.portRuleTerminal : nil
  }

  private var currentRuntimeProbe: DebugRuntimeProbeSnapshot? {
    guard let target, let runtimeProbe,
      runtimeProbe.targetID == target.id,
      runtimeProbe.bindingRevision == target.bindingRevision
    else { return nil }
    return runtimeProbe
  }

  private var canAddRule: Bool {
    guard target != nil, !model.isMutatingPortRule else { return false }
    if case .valid = validation { return true }
    return false
  }

  var body: some View {
    WorkspacePage(maximumWidth: WorkspaceMetrics.pageMaxWidth) {
      WorkspaceColumns(
        spacing: WorkspaceMetrics.sectionGap,
        leadingRatio: WorkspaceMetrics.splitLeadingColumnRatio
      ) {
        ruleEditorSection
      } trailing: {
        ruleListSection
      }
    }
  }

  private var ruleEditorSection: some View {
    WorkspaceSection(Text(DebugL10n.text("debug.network.editor.title"))) {
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
      ruleActionFooter
      safetyFooter
    }
  }

  private var ruleActionFooter: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
      Button(DebugL10n.text("debug.network.add")) {
        guard let target, case .valid(let rule) = validation else { return }
        model.mutatePortRule(target: target, rule: rule, removing: false)
      }
      .buttonStyle(.borderedProminent)
      .disabled(!canAddRule)
      .accessibilityIdentifier("debug.network.add")
      if let jobID = scopedActiveJobID {
        HStack(spacing: WorkspaceMetrics.tightGap) {
          ProgressView().controlSize(.small)
          Text(jobID)
            .font(WorkspaceFont.monospacedDense)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 0)
          Button(DebugL10n.text("debug.action.cancel")) {
            model.cancelPortRuleMutation()
          }
          .controlSize(.small)
          .disabled(model.isCancellingPortRule)
        }
        .accessibilityIdentifier("debug.network.activeJob")
      }
      if feedbackMatchesTarget, let failure = model.portRuleFailure {
        Label(failure, systemImage: "exclamationmark.triangle")
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let terminal = scopedTerminal {
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

  /// The three validation and scope facts used to be a section of their own at
  /// the foot of the page, one card away from the fields they describe. They
  /// belong to this editor, so they close it.
  private var safetyFooter: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
      Divider()
        .padding(.bottom, WorkspaceMetrics.rowGap)
      Text(DebugL10n.text("debug.network.safety.title"))
        .font(WorkspaceFont.label)
        .foregroundStyle(.secondary)
      Label(DebugL10n.text("debug.network.safety.typed"), systemImage: "number")
      Label(DebugL10n.text("debug.network.safety.noShell"), systemImage: "text.badge.xmark")
      Label(DebugL10n.text("debug.network.safety.binding"), systemImage: "link")
    }
    .font(WorkspaceFont.secondary)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
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

  private var ruleListSection: some View {
    WorkspaceSection(Text(DebugL10n.text("debug.network.rules.title"))) {
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
      if let currentRuntimeProbe, !currentRuntimeProbe.portRules.isEmpty {
        ForEach(currentRuntimeProbe.portRules.enumerated(), id: \.offset) { _, rule in
          ruleRow(rule)
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
      if let warnings = currentRuntimeProbe?.warnings.filter({ $0.contains("Rules") }),
        !warnings.isEmpty
      {
        Text(warnings.joined(separator: " · "))
          .font(WorkspaceFont.monospacedDense)
          .foregroundStyle(.orange)
      }
      Label(DebugL10n.text("debug.network.delete.scope"), systemImage: "target")
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func ruleRow(_ rule: DebugRuntimePortRule) -> some View {
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
      .controlSize(.small)
      .frame(width: 72, alignment: .trailing)
      .disabled(model.isMutatingPortRule)
    }
    .accessibilityElement(children: .combine)
  }
}


/// Availability as one line beside the section title it gates.
///
/// The workspace used to answer this question twice: per-operation badges in
/// the page header and a `Runtime availability` card inside every panel, both
/// reading "available" on nearly every visit. Spec §4.4 asks the page to
/// state availability before it offers the configuration — it does not ask
/// for a bordered card that is only ever green.
struct DebugAvailabilityStatus: View {
  let operation: DebugOperationPresentation?

  var body: some View {
    let state = DebugAvailabilityState(operation?.availability)
    return Label(state.title, systemImage: state.symbol)
      .font(WorkspaceFont.secondary)
      .foregroundStyle(state.tone.color)
      .help(operation?.reference ?? "")
      .accessibilityIdentifier("debug.availability.status")
  }
}

/// The blocker, and only the blocker. Nothing is drawn while Runtime reports
/// the operation available or is still checking, so the reasons that do
/// arrive are the loudest thing in the section rather than the last line of a
/// card the eye has learned to skip.
struct DebugAvailabilityNotice: View {
  let operation: DebugOperationPresentation?

  var body: some View {
    if let operation {
      if case .unavailable(let reasons) = operation.availability {
        WorkspaceNotice(
          tone: .danger, symbol: "xmark.octagon.fill",
          identifier: "debug.availability.blocked"
        ) {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
            Text(DebugL10n.text("debug.availability.unavailable"))
              .font(WorkspaceFont.secondary.weight(.medium))
            ForEach(reasons.enumerated(), id: \.offset) { _, reason in
              Text(reason)
                .font(WorkspaceFont.monospacedDense)
                .textSelection(.enabled)
            }
          }
        }
      }
    } else {
      WorkspaceNotice(
        tone: .warning, symbol: "lock.fill", identifier: "debug.availability.missing"
      ) {
        Text(DebugL10n.text("debug.availability.missing"))
      }
    }
  }
}

struct DebugAvailabilityState {
  let title: String
  let symbol: String
  let tone: WorkspaceTone

  init(_ availability: DebugRuntimeAvailability?) {
    switch availability {
    case .checking:
      title = DebugL10n.text("debug.availability.checking")
      symbol = "hourglass"
      tone = .neutral
    case .available:
      title = DebugL10n.text("debug.availability.available")
      symbol = "checkmark.circle.fill"
      tone = .ok
    case .unavailable:
      title = DebugL10n.text("debug.availability.unavailable")
      symbol = "xmark.octagon.fill"
      tone = .danger
    case nil:
      title = DebugL10n.text("debug.availability.unavailable")
      symbol = "exclamationmark.triangle.fill"
      tone = .warning
    }
  }
}

struct DebugRecentJobsSection: View {
  var model: DebugWorkspaceViewModel
  let jobs: [DebugJobPresentation]

  var body: some View {
    WorkspaceSection(Text(DebugL10n.text("debug.jobs.title"))) {
      if jobs.isEmpty {
        Text(DebugL10n.text("debug.jobs.empty"))
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      } else {
        ForEach(jobs.prefix(5)) { job in
          jobRow(job)
        }
      }
    }
  }

  private func jobRow(_ job: DebugJobPresentation) -> some View {
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
        Spacer(minLength: WorkspaceMetrics.contentGap)
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

struct DebugCodeRow: View {
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

struct DebugBlockedReason: View {
  let text: String

  var body: some View {
    Label(text, systemImage: "lock.fill")
      .font(WorkspaceFont.secondary)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityElement(children: .combine)
  }
}

func effectSymbol(_ effect: String) -> String {
  switch effect {
  case "deviceMutation": "arrow.triangle.2.circlepath"
  case "destructive": "exclamationmark.triangle.fill"
  case "readOnly": "eye"
  default: "desktopcomputer"
  }
}

func effectColor(_ effect: String) -> Color {
  switch effect {
  case "deviceMutation": .orange
  case "destructive": .red
  default: .secondary
  }
}

enum DebugL10n {
  static func text(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "DebugLocalizable")
  }
}

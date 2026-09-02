import AppKit
import ArkDeckWorkflows
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

  @SceneStorage("debug.workspace.tab.v2")
  private var storedTab = DebugWorkspaceTab.artifacts.rawValue
  @State private var selectedTargetID: String?
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
    .onAppear(perform: reconcileTargetSelection)
    .onChange(of: historyContext?.id, initial: true) { _, _ in
      if historyContext == nil { reconcileTargetSelection() } else { applyHistoryContext() }
    }
    .onChange(of: model.workspace.targets) { _, _ in reconcileTargetSelection() }
    .onChange(of: selectedTargetID) { _, targetID in
      model.refresh(targetID: targetID)
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
      DebugCommandsWorkspace(model: model, target: selectedTarget)
    }
  }

  private func reconcileTargetSelection() {
    if let historyContext, historyContext.workspaceKind == .debug {
      selectedTargetID = historyContext.targetID
      return
    }
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

private struct DebugRuntimeArtifactRow: Identifiable {
  let jobID: String
  let artifact: RuntimeArtifactPresentation

  var id: String { "\(jobID):\(artifact.id)" }
}

private struct DebugAccessibilityStatus: Equatable {
  let message: String
  let isUrgent: Bool
}

/// AppKit supplies the native macOS announcement channel that SwiftUI does
/// not expose as a stable live-region modifier. This bridge observes only the
/// coarse Native Debug state, so live HiLog lines are never announced one by
/// one.
private struct DebugNativeLibraryAnnouncementBridge: View {
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

private struct DebugRemoteLibrarySelection: Equatable {
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

private struct DebugRemoteBuildBrowserSheet: View {
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

private struct DebugRemoteBuildEntryRow: View {
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

private struct DebugArtifactsWorkspace: View {
  private enum BuildSourceKind: String, CaseIterable {
    case local
    case remote
  }

  var model: DebugWorkspaceViewModel
  let operation: DebugOperationPresentation?
  let target: DebugTargetPresentation?
  let relatedJobs: [DebugJobPresentation]
  let runtimeArtifacts: [DebugRuntimeArtifactRow]
  let onOpenLogs: () -> Void

  @State private var isImporterPresented = false
  @State private var presentedPreparation: DebugNativeLibraryPreparation?
  @State private var isRemoteBrowserPresented = false
  @State private var buildSourceKind = BuildSourceKind.local
  @State private var selectedLibraryURL: URL?
  @State private var selectedRemoteLibrary: DebugRemoteLibrarySelection?
  @State private var remoteBrowserModel = DebugRemoteBuildBrowserViewModel(
    provider: RemoteBuildSourceApplicationFacade.make())
  private let remoteBindingProvider: any RemoteBuildSourceBindingProviding =
    RemoteBuildSourceBindingApplicationFacade.make()
  @State private var selectionError: String?
  @State private var targetBundle = ""
  @State private var libraryLogicalName = ""
  private let verificationProfile = "hashProcessAndMaps"
  private let rollbackPolicy = "autoRollback"

  private var operationIsAvailable: Bool {
    guard let operation else { return false }
    if case .available = operation.availability { return true }
    return false
  }

  private var inputsAreValid: Bool {
    target != nil
      && selectedLibraryURL != nil
      && DebugTypedValueValidator.isValidBundleName(targetBundle)
      && DebugTypedValueValidator.isValidNativeLibraryLogicalName(libraryLogicalName)
  }

  private var nativeLibraryFeedbackMatchesTarget: Bool {
    model.nativeLibraryFeedbackMatches(
      target: target,
      fileURL: selectedLibraryURL,
      targetBundle: targetBundle,
      libraryLogicalName: libraryLogicalName,
      verificationProfile: verificationProfile,
      rollbackPolicy: rollbackPolicy)
  }

  private var currentPreparation: DebugNativeLibraryPreparation? {
    guard nativeLibraryFeedbackMatchesTarget else { return nil }
    return model.nativeLibraryPreparation
  }

  private var currentTerminal: DebugLogJobTerminalPresentation? {
    guard nativeLibraryFeedbackMatchesTarget else { return nil }
    return model.nativeLibraryTerminal
  }

  private var currentFailure: String? {
    guard nativeLibraryFeedbackMatchesTarget else { return nil }
    return model.nativeLibraryPreparationFailure ?? model.nativeLibraryFailure
  }

  private var currentAccessibilityStatus: DebugAccessibilityStatus? {
    if let currentFailure {
      return DebugAccessibilityStatus(message: currentFailure, isUrgent: true)
    }
    if let currentTerminal {
      let message =
        currentTerminal.state == "succeeded" && !currentTerminal.outcomeUnknown
        ? DebugL10n.text("debug.artifacts.verified")
        : DebugL10n.text("debug.artifacts.notVerified")
      return DebugAccessibilityStatus(message: message, isUrgent: currentTerminal.outcomeUnknown)
    }
    if model.isSubmittingNativeLibrary && nativeLibraryFeedbackMatchesTarget {
      return DebugAccessibilityStatus(
        message: DebugL10n.text("debug.artifacts.running"), isUrgent: false)
    }
    if model.isPreparingNativeLibrary && nativeLibraryFeedbackMatchesTarget {
      return DebugAccessibilityStatus(
        message: DebugL10n.text("debug.artifacts.preparing"), isUrgent: false)
    }
    if currentPreparation != nil {
      return DebugAccessibilityStatus(
        message: DebugL10n.text("debug.artifacts.planReady"), isUrgent: false)
    }
    return nil
  }

  var body: some View {
    WorkspacePage(maximumWidth: WorkspaceMetrics.pageMaxWidth) {
      targetScope
      // `WorkspaceColumns` measures the container instead of comparing ideal
      // sizes, so the fold happens at a real width. `ViewThatFits` could not:
      // a column of prose has an unbounded ideal width.
      WorkspaceColumns(
        spacing: WorkspaceMetrics.sectionGap,
        leadingRatio: WorkspaceMetrics.splitLeadingColumnRatio
      ) {
        buildSource
      } trailing: {
        deploymentInputs
      }
      reviewAndRun
        .background {
          DebugNativeLibraryAnnouncementBridge(status: currentAccessibilityStatus)
        }
      productionBoundary
      if !runtimeArtifacts.isEmpty { resultArtifacts }
      DebugRecentJobsSection(model: model, jobs: relatedJobs)
    }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: [UTType(filenameExtension: "so") ?? .data],
      allowsMultipleSelection: false,
      onCompletion: handleLibrarySelection
    )
    .sheet(item: $presentedPreparation) {
      DebugNativeLibraryPlanSheet(model: model, preparation: $0)
    }
    .sheet(isPresented: $isRemoteBrowserPresented) {
      DebugRemoteBuildBrowserSheet(model: remoteBrowserModel) { selection in
        selectedRemoteLibrary = selection
        selectedLibraryURL = selection.identityURL
        libraryLogicalName = selection.entry.name
        selectionError = nil
        if let targetID = target?.id {
          let remoteBindingProvider = remoteBindingProvider
          Task { @MainActor in
            do {
              try await remoteBindingProvider.bind(
                sourceID: selection.sourceID, toTargetID: targetID)
            } catch {
              selectionError =
                DebugL10n.text("debug.artifacts.remoteBindingFailed")
                + " " + error.localizedDescription
            }
          }
        }
        model.clearNativeLibraryPreparation()
        isRemoteBrowserPresented = false
      }
    }
    .onChange(of: target?.id) { _, _ in model.clearNativeLibraryPreparation() }
    .onChange(of: target?.bindingRevision) { _, _ in model.clearNativeLibraryPreparation() }
    .onChange(of: targetBundle) { _, _ in model.clearNativeLibraryPreparation() }
    .onChange(of: libraryLogicalName) { _, _ in model.clearNativeLibraryPreparation() }
  }

  private var targetScope: some View {
    HStack(spacing: WorkspaceMetrics.contentGap) {
      Text(DebugL10n.text("debug.artifacts.target"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
      if let target {
        Text("\(target.id) · binding r\(target.bindingRevision)")
          .font(WorkspaceFont.monospacedValue)
          .textSelection(.enabled)
        WorkspaceChip(
          text: Text(DebugL10n.text("debug.artifacts.targetConfirmed")),
          tone: .ok,
          symbol: "checkmark.circle")
        WorkspaceChip(text: Text("deviceMutation"), tone: .warning)
      } else {
        Text(DebugL10n.text("debug.target.none"))
          .font(WorkspaceFont.monospacedValue)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("debug.artifacts.targetScope")
  }

  private var buildSource: some View {
    WorkspaceSection(
      Text(DebugL10n.text("debug.artifacts.source.title")),
      accessory: { DebugAvailabilityStatus(operation: operation) }
    ) {
      // Spec §4.4: state availability before offering the configuration it
      // gates. A ready operation is the accessory line above and nothing
      // more; only a blocker earns page space.
      DebugAvailabilityNotice(operation: operation)
      Text(DebugL10n.text("debug.artifacts.source.detail"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Picker("", selection: $buildSourceKind) {
        Text(DebugL10n.text("debug.artifacts.source.local"))
          .tag(BuildSourceKind.local)
        Text(DebugL10n.text("debug.artifacts.source.remote"))
          .tag(BuildSourceKind.remote)
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .accessibilityLabel(DebugL10n.text("debug.artifacts.source.kind"))
      .accessibilityIdentifier("debug.artifacts.source.kind")
      if buildSourceKind == .local {
        Button {
          isImporterPresented = true
        } label: {
          Label(
            DebugL10n.text("debug.artifacts.chooseLibrary"),
            systemImage: "doc.badge.plus")
        }
        .accessibilityIdentifier("debug.artifacts.chooseLibrary")
      } else {
        Button {
          isRemoteBrowserPresented = true
        } label: {
          Label(
            DebugL10n.text("debug.artifacts.browseRemote"),
            systemImage: "server.rack")
        }
        .accessibilityIdentifier("debug.artifacts.browseRemote")
      }
      VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
        Text(DebugL10n.text("debug.artifacts.selectedLibrary"))
          .font(WorkspaceFont.caption)
          .foregroundStyle(.secondary)
        Text(
          selectedRemoteLibrary?.entry.name ?? selectedLibraryURL?.lastPathComponent
            ?? DebugL10n.text("debug.artifacts.noLibrary")
        )
        .font(WorkspaceFont.monospacedValue)
        .foregroundStyle(selectedLibraryURL == nil ? .secondary : .primary)
        .textSelection(.enabled)
      }
      if let selectedRemoteLibrary {
        Text("\(selectedRemoteLibrary.sourceName) · \(selectedRemoteLibrary.entry.relativePath)")
          .font(WorkspaceFont.monospacedDense)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .truncationMode(.middle)
          .help(selectedRemoteLibrary.entry.relativePath)
      }
      if let selectionError {
        Label(selectionError, systemImage: "xmark.octagon")
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      WorkspaceNotice(tone: .neutral, symbol: "externaldrive") {
        Text(DebugL10n.text("debug.artifacts.sourceBoundary"))
      }
    }
    .onChange(of: buildSourceKind) { _, _ in
      selectedLibraryURL = nil
      selectedRemoteLibrary = nil
      selectionError = nil
      model.clearNativeLibraryPreparation()
    }
  }

  private var deploymentInputs: some View {
    WorkspaceSection(Text(DebugL10n.text("debug.artifacts.destination.title"))) {
      Text(DebugL10n.text("debug.artifacts.destination.detail"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      LabeledContent(DebugL10n.text("debug.artifacts.bundle")) {
        TextField("com.example.app", text: $targetBundle)
          .textFieldStyle(.roundedBorder)
          .frame(minWidth: 220)
          .accessibilityIdentifier("debug.artifacts.bundle")
      }
      LabeledContent(DebugL10n.text("debug.artifacts.logicalName")) {
        TextField("libfeature_debug.so", text: $libraryLogicalName)
          .textFieldStyle(.roundedBorder)
          .frame(minWidth: 220)
          .accessibilityIdentifier("debug.artifacts.logicalName")
      }
      LabeledContent(DebugL10n.text("debug.artifacts.abi")) {
        Text(DebugL10n.text("debug.artifacts.abi.observed"))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.trailing)
      }
      if !targetBundle.isEmpty
        && !DebugTypedValueValidator.isValidBundleName(targetBundle)
      {
        Label(
          DebugL10n.text("debug.artifacts.bundleInvalid"),
          systemImage: "exclamationmark.circle"
        )
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.red)
        .accessibilityIdentifier("debug.artifacts.bundle.invalid")
      }
      if !libraryLogicalName.isEmpty
        && !DebugTypedValueValidator.isValidNativeLibraryLogicalName(libraryLogicalName)
      {
        Label(
          DebugL10n.text("debug.artifacts.logicalNameInvalid"),
          systemImage: "exclamationmark.circle"
        )
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.red)
        .accessibilityIdentifier("debug.artifacts.logicalName.invalid")
      }
      DisclosureGroup(DebugL10n.text("debug.artifacts.advanced")) {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
          LabeledContent(DebugL10n.text("debug.artifacts.verification")) {
            Text(DebugL10n.text("debug.artifacts.verify.maps"))
              .multilineTextAlignment(.trailing)
          }
          LabeledContent(DebugL10n.text("debug.artifacts.rollback")) {
            Text(DebugL10n.text("debug.artifacts.rollback.auto"))
              .multilineTextAlignment(.trailing)
          }
          Text(DebugL10n.text("debug.artifacts.policy.required"))
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, WorkspaceMetrics.tightGap)
      }
    }
  }

  private var reviewAndRun: some View {
    WorkspaceSection(Text(DebugL10n.text("debug.artifacts.review.title"))) {
      Text(DebugL10n.text("debug.artifacts.review.detail"))
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let preparation = currentPreparation {
        WorkspaceNotice(tone: .ok, identifier: "debug.artifacts.planReady") {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
            Text(DebugL10n.text("debug.artifacts.planReady"))
              .bold()
            DebugCodeRow(
              label: "ELF",
              value:
                "\(preparation.abi) · ELF\(preparation.elfClassBits) · machine \(preparation.machine)"
            )
            DebugCodeRow(label: "Build ID", value: preparation.buildID)
            DebugCodeRow(label: "SHA-256", value: preparation.sha256)
          }
        }
      }
      if model.isPreparingNativeLibrary && nativeLibraryFeedbackMatchesTarget {
        HStack(spacing: WorkspaceMetrics.tightGap) {
          ProgressView().controlSize(.small)
          Text(DebugL10n.text("debug.artifacts.preparing"))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("debug.artifacts.preparing")
      }
      if model.isSubmittingNativeLibrary && nativeLibraryFeedbackMatchesTarget {
        WorkspaceNotice(tone: .accent, identifier: "debug.artifacts.running") {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
            Text(DebugL10n.text("debug.artifacts.running"))
              .bold()
            Text(
              model.workspace.jobs.first(where: {
                $0.id == model.activeNativeLibraryJobID
              })?.timeline.last ?? DebugL10n.text("debug.artifacts.running.detail")
            )
            .font(WorkspaceFont.monospacedDense)
          }
        }
      }
      if let terminal = currentTerminal {
        WorkspaceNotice(
          tone: terminal.state == "succeeded" && !terminal.outcomeUnknown ? .ok : .danger,
          identifier: "debug.artifacts.terminal"
        ) {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
            Text(
              terminal.state == "succeeded" && !terminal.outcomeUnknown
                ? DebugL10n.text("debug.artifacts.verified")
                : DebugL10n.text("debug.artifacts.notVerified")
            )
            .bold()
            if let latest = terminal.timeline.last {
              Text(latest)
                .font(WorkspaceFont.monospacedDense)
                .textSelection(.enabled)
            }
          }
        }
      }
      if let failure = currentFailure {
        Label(failure, systemImage: "xmark.octagon")
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
          .accessibilityIdentifier("debug.artifacts.failure")
      }
      HStack(spacing: WorkspaceMetrics.contentGap) {
        if model.isSubmittingNativeLibrary && nativeLibraryFeedbackMatchesTarget {
          Button(DebugL10n.text("debug.action.cancel")) {
            model.cancelNativeLibrary()
          }
          .disabled(model.isCancellingNativeLibrary)
          .accessibilityIdentifier("debug.artifacts.cancel")
        } else {
          Button(
            currentPreparation == nil
              ? DebugL10n.text("debug.artifacts.preview")
              : DebugL10n.text("debug.artifacts.reopenPlan")
          ) {
            if currentPreparation != nil {
              presentedPreparation = currentPreparation
            } else {
              preparePlan()
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(
            !inputsAreValid || !operationIsAvailable
              || model.isPreparingNativeLibrary || model.isSubmittingNativeLibrary
          )
          .accessibilityIdentifier("debug.artifacts.preview")
        }
        if currentTerminal?.state == "succeeded" {
          Button(DebugL10n.text("debug.artifacts.openLogs"), action: onOpenLogs)
            .accessibilityIdentifier("debug.artifacts.openLogs")
        }
        Spacer(minLength: 0)
      }
    }
  }

  private var productionBoundary: some View {
    WorkspaceNotice(tone: .warning, identifier: "debug.artifacts.productionBoundary") {
      Text(DebugL10n.text("debug.artifacts.productionBoundary"))
    }
  }

  private var resultArtifacts: some View {
    WorkspaceSection(
      Text(DebugL10n.text("debug.artifacts.results.title")),
      spacing: WorkspaceMetrics.tightGap
    ) {
      ForEach(runtimeArtifacts) { row in
        HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.contentGap) {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
            Text(row.artifact.name).font(WorkspaceFont.monospacedValue)
            Text(row.artifact.sha256)
              .font(WorkspaceFont.monospacedDense)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          Spacer()
          Text(
            ByteCountFormatter.string(fromByteCount: row.artifact.byteCount, countStyle: .file)
          )
          .font(WorkspaceFont.tabularSecondary)
        }
      }
    }
  }

  private func preparePlan() {
    guard let target, let fileURL = selectedLibraryURL else { return }
    Task {
      let prepared: Bool
      if let selectedRemoteLibrary {
        prepared = await model.prepareRemoteNativeLibrary(
          target: target,
          selectionIdentityURL: fileURL,
          sourceID: selectedRemoteLibrary.sourceID,
          relativePath: selectedRemoteLibrary.entry.relativePath,
          targetBundle: targetBundle,
          libraryLogicalName: libraryLogicalName,
          verificationProfile: verificationProfile,
          rollbackPolicy: rollbackPolicy)
      } else {
        prepared = await model.prepareNativeLibrary(
          target: target,
          fileURL: fileURL,
          targetBundle: targetBundle,
          libraryLogicalName: libraryLogicalName,
          verificationProfile: verificationProfile,
          rollbackPolicy: rollbackPolicy)
      }
      if prepared { presentedPreparation = currentPreparation }
    }
  }

  private func handleLibrarySelection(_ result: Result<[URL], Error>) {
    switch result {
    case .success(let urls):
      guard let url = urls.first else { return }
      selectedLibraryURL = url
      selectedRemoteLibrary = nil
      libraryLogicalName = url.lastPathComponent
      selectionError = nil
      model.clearNativeLibraryPreparation()
    case .failure(let error):
      selectionError = error.localizedDescription
    }
  }
}

private struct DebugNativeLibraryPlanSheet: View {
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

private struct DebugCommandsWorkspace: View {
  var model: DebugWorkspaceViewModel
  let target: DebugTargetPresentation?

  @State private var selectedTemplateID =
    DebugApplicationFacade.approvedCommandTemplates.first?.id

  private var selectedTemplate: DebugCommandTemplatePresentation? {
    DebugApplicationFacade.approvedCommandTemplates.first { $0.id == selectedTemplateID }
  }

  private var feedbackMatchesSelection: Bool {
    model.commandFeedbackMatches(target: target, templateID: selectedTemplateID)
  }

  private var currentCommandResult: DebugRuntimeCommandResult? {
    guard feedbackMatchesSelection, let target, let selectedTemplateID,
      let result = model.commandResult,
      result.targetID == target.id,
      result.bindingRevision == target.bindingRevision,
      result.templateID == selectedTemplateID
    else { return nil }
    return result
  }

  var body: some View {
    WorkspacePage(maximumWidth: WorkspaceMetrics.pageMaxWidth) {
      // The whole tab's contract, stated before any template is chosen: a
      // closed template set with schema-defined inputs, and the argv below is
      // provider lowering echoed read-only, never an input.
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
          selectedTemplateID = template.id
        } label: {
          DebugCommandTemplateRow(
            template: template, isSelected: selectedTemplateID == template.id)
        }
        .buttonStyle(.plain)
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

  /// The template's identity and the provider's lowering of it are the same
  /// subject — what exactly will be invoked — so they are one section instead
  /// of two stacked cards repeating the action ID.
  private func invocationSection(_ template: DebugCommandTemplatePresentation) -> some View {
    WorkspaceSection(
      Text(DebugL10n.text("debug.commands.argv.title")),
      accessory: {
        WorkspaceChip(
          text: Text(template.effect),
          tone: template.effect == "readOnly" ? .neutral : .warning,
          symbol: effectSymbol(template.effect))
      }
    ) {
      templateIdentity(template)
      Divider()
      DebugCodeRow(
        label: DebugL10n.text("debug.commands.executable"),
        value: currentCommandResult.map {
          "\($0.executable) · sha256:\($0.executableSHA256.prefix(12))"
        } ?? DebugL10n.text("debug.commands.notGenerated"))
      DebugCodeRow(
        label: DebugL10n.text("debug.commands.arguments"),
        value: currentCommandResult?.argumentDisclosure.joined(separator: " ")
          ?? DebugL10n.text("debug.commands.notGenerated"))
      if let result = currentCommandResult {
        DebugCodeRow(label: "lowering sha256", value: result.loweringSHA256)
      }
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
        Button(DebugL10n.text("debug.commands.run")) {
          guard let target else { return }
          model.runTemplate(target: target, templateID: template.id)
        }
        .buttonStyle(.borderedProminent)
        .disabled(target == nil || !template.isRunnable || model.isRunningCommand)
        .help(DebugL10n.text("debug.commands.noPTY"))
        .accessibilityIdentifier("debug.commands.run")
        if feedbackMatchesSelection && model.isRunningCommand {
          ProgressView().controlSize(.small)
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
      HStack {
        DebugCodeRow(
          label: DebugL10n.text("debug.commands.result.exitCode"),
          value: currentCommandResult?.exitCode.map(String.init) ?? "—")
        Spacer()
        DebugCodeRow(
          label: DebugL10n.text("debug.commands.result.duration"),
          value: currentCommandResult.map { "\($0.durationMilliseconds) ms" } ?? "—")
      }
      Divider()
      LabeledContent(DebugL10n.text("debug.commands.result.stdout")) {
        Text(currentCommandResult?.stdout ?? DebugL10n.text("debug.commands.result.none"))
          .font(WorkspaceFont.monospacedValue)
          .textSelection(.enabled)
      }
      LabeledContent(DebugL10n.text("debug.commands.result.stderr")) {
        Text(currentCommandResult?.stderr ?? DebugL10n.text("debug.commands.result.none"))
          .font(WorkspaceFont.monospacedValue)
          .textSelection(.enabled)
      }
    }
  }
}

private struct DebugCommandTemplateRow: View {
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

/// Availability as one line beside the section title it gates.
///
/// The workspace used to answer this question twice: per-operation badges in
/// the page header and a `Runtime availability` card inside every panel, both
/// reading "available" on nearly every visit. Spec §4.4 asks the page to
/// state availability before it offers the configuration — it does not ask
/// for a bordered card that is only ever green.
private struct DebugAvailabilityStatus: View {
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
private struct DebugAvailabilityNotice: View {
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

private struct DebugAvailabilityState {
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

private struct DebugRecentJobsSection: View {
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
  private struct TargetBindingScope: Equatable {
    let targetID: String
    let bindingRevision: Int

    init(target: DebugTargetPresentation) {
      targetID = target.id
      bindingRevision = target.bindingRevision
    }

    func matches(_ target: DebugTargetPresentation?) -> Bool {
      guard let target else { return false }
      return targetID == target.id && bindingRevision == target.bindingRevision
    }
  }

  private struct CommandFeedbackScope: Equatable {
    let target: TargetBindingScope
    let templateID: String
  }

  private struct NativeLibraryFeedbackScope: Equatable {
    let targetID: String
    let bindingRevision: Int
    let fileURL: URL
    let targetBundle: String
    let libraryLogicalName: String
    let verificationProfile: String
    let rollbackPolicy: String
  }

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
  private(set) var isPreparingNativeLibrary = false
  private(set) var nativeLibraryPreparation: DebugNativeLibraryPreparation?
  private(set) var nativeLibraryPreparationFailure: String?
  private(set) var isSubmittingNativeLibrary = false
  private(set) var isCancellingNativeLibrary = false
  private(set) var activeNativeLibraryJobID: String?
  private(set) var nativeLibraryTerminal: DebugLogJobTerminalPresentation?
  private(set) var nativeLibraryFailure: String?
  private(set) var cancellingOutstandingJobIDs: Set<String> = []
  private var historyArtifactsByJobID: [String: [RuntimeArtifactPresentation]] = [:]

  private var logFeedbackScope: TargetBindingScope?
  private var hapFeedbackScope: TargetBindingScope?
  private var portRuleFeedbackScope: TargetBindingScope?
  private var commandFeedbackScope: CommandFeedbackScope?
  private var nativeLibraryFeedbackScope: NativeLibraryFeedbackScope?
  private var nativeLibraryPreparationGeneration = 0

  private let provider: any DebugApplicationProviding
  private let detailProvider: any RuntimeJobDetailApplicationProviding

  init(
    provider: any DebugApplicationProviding,
    detailProvider: (any RuntimeJobDetailApplicationProviding)? = nil
  ) {
    self.provider = provider
    self.detailProvider = detailProvider ?? RuntimeJobDetailApplicationFacade.make()
  }

  func logFeedbackMatches(target: DebugTargetPresentation?) -> Bool {
    logFeedbackScope?.matches(target) == true
  }

  func hapFeedbackMatches(target: DebugTargetPresentation?) -> Bool {
    hapFeedbackScope?.matches(target) == true
  }

  func portRuleFeedbackMatches(target: DebugTargetPresentation?) -> Bool {
    portRuleFeedbackScope?.matches(target) == true
  }

  func commandFeedbackMatches(
    target: DebugTargetPresentation?,
    templateID: String?
  ) -> Bool {
    guard let templateID else { return false }
    return commandFeedbackScope
      == target.map {
        CommandFeedbackScope(target: TargetBindingScope(target: $0), templateID: templateID)
      }
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

  func nativeLibraryFeedbackMatches(
    target: DebugTargetPresentation?,
    fileURL: URL?,
    targetBundle: String,
    libraryLogicalName: String,
    verificationProfile: String,
    rollbackPolicy: String
  ) -> Bool {
    guard let target, let fileURL else { return false }
    return nativeLibraryFeedbackScope
      == NativeLibraryFeedbackScope(
        targetID: target.id,
        bindingRevision: target.bindingRevision,
        fileURL: fileURL,
        targetBundle: targetBundle,
        libraryLogicalName: libraryLogicalName,
        verificationProfile: verificationProfile,
        rollbackPolicy: rollbackPolicy)
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
      artifacts.merge(self.historyArtifactsByJobID) { _, historical in historical }
      self.artifactsByJobID = artifacts
    }
  }

  /// Makes immutable Artifact metadata from the selected History record
  /// available to Debug without submitting or running anything.
  func rememberHistoryContext(_ context: RuntimeHistoryWorkspaceContext) {
    guard context.workspaceKind == .debug else { return }
    historyArtifactsByJobID[context.jobID] = context.artifacts
    artifactsByJobID[context.jobID] = context.artifacts
  }

  func submitLogs(
    target: DebugTargetPresentation,
    durationSeconds: Int,
    filters: [String]
  ) {
    guard !isSubmittingLogs else { return }
    logFeedbackScope = TargetBindingScope(target: target)
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
    additionalFileURLs: [URL],
    bundleName: String,
    abilityName: String,
    installPolicy: String,
    cleanupPolicy: String,
    postRunAbilityState: String,
    captureDiagnostics: Bool,
    diagnosticsDurationSeconds: Int
  ) {
    guard !isSubmittingHAP else { return }
    hapFeedbackScope = TargetBindingScope(target: target)
    isSubmittingHAP = true
    activeHAPJobID = nil
    hapTerminal = nil
    hapFailure = nil
    let provider = provider
    Task { [weak self] in
      let submitted = await provider.submitHAP(
        target: target, fileURL: fileURL, additionalFileURLs: additionalFileURLs,
        bundleName: bundleName, abilityName: abilityName,
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

  func prepareNativeLibrary(
    target: DebugTargetPresentation,
    fileURL: URL,
    targetBundle: String,
    libraryLogicalName: String,
    verificationProfile: String,
    rollbackPolicy: String
  ) async -> Bool {
    guard !isPreparingNativeLibrary, !isSubmittingNativeLibrary else { return false }
    nativeLibraryPreparationGeneration += 1
    let preparationGeneration = nativeLibraryPreparationGeneration
    nativeLibraryFeedbackScope = NativeLibraryFeedbackScope(
      targetID: target.id,
      bindingRevision: target.bindingRevision,
      fileURL: fileURL,
      targetBundle: targetBundle,
      libraryLogicalName: libraryLogicalName,
      verificationProfile: verificationProfile,
      rollbackPolicy: rollbackPolicy)
    isPreparingNativeLibrary = true
    nativeLibraryPreparation = nil
    nativeLibraryPreparationFailure = nil
    nativeLibraryTerminal = nil
    nativeLibraryFailure = nil
    let result = await provider.prepareNativeLibrary(
      target: target,
      fileURL: fileURL,
      targetBundle: targetBundle,
      libraryLogicalName: libraryLogicalName,
      verificationProfile: verificationProfile,
      rollbackPolicy: rollbackPolicy)
    guard preparationGeneration == nativeLibraryPreparationGeneration else {
      isPreparingNativeLibrary = false
      return false
    }
    guard !Task.isCancelled else {
      isPreparingNativeLibrary = false
      return false
    }
    isPreparingNativeLibrary = false
    switch result {
    case .prepared(let preparation):
      nativeLibraryPreparation = preparation
      return true
    case .failed(let failure):
      nativeLibraryPreparationFailure = failure
      return false
    }
  }

  func prepareRemoteNativeLibrary(
    target: DebugTargetPresentation,
    selectionIdentityURL: URL,
    sourceID: UUID,
    relativePath: String,
    targetBundle: String,
    libraryLogicalName: String,
    verificationProfile: String,
    rollbackPolicy: String
  ) async -> Bool {
    guard !isPreparingNativeLibrary, !isSubmittingNativeLibrary else { return false }
    nativeLibraryPreparationGeneration += 1
    let preparationGeneration = nativeLibraryPreparationGeneration
    nativeLibraryFeedbackScope = NativeLibraryFeedbackScope(
      targetID: target.id,
      bindingRevision: target.bindingRevision,
      fileURL: selectionIdentityURL,
      targetBundle: targetBundle,
      libraryLogicalName: libraryLogicalName,
      verificationProfile: verificationProfile,
      rollbackPolicy: rollbackPolicy)
    isPreparingNativeLibrary = true
    nativeLibraryPreparation = nil
    nativeLibraryPreparationFailure = nil
    nativeLibraryTerminal = nil
    nativeLibraryFailure = nil
    let result = await provider.prepareRemoteNativeLibrary(
      target: target,
      sourceID: sourceID,
      relativePath: relativePath,
      targetBundle: targetBundle,
      libraryLogicalName: libraryLogicalName,
      verificationProfile: verificationProfile,
      rollbackPolicy: rollbackPolicy)
    guard preparationGeneration == nativeLibraryPreparationGeneration else {
      isPreparingNativeLibrary = false
      return false
    }
    guard !Task.isCancelled else {
      isPreparingNativeLibrary = false
      return false
    }
    isPreparingNativeLibrary = false
    switch result {
    case .prepared(let preparation):
      nativeLibraryPreparation = preparation
      return true
    case .failed(let failure):
      nativeLibraryPreparationFailure = failure
      return false
    }
  }

  func clearNativeLibraryPreparation() {
    nativeLibraryPreparationGeneration += 1
    nativeLibraryPreparation = nil
    nativeLibraryPreparationFailure = nil
  }

  func submitNativeLibrary(_ preparation: DebugNativeLibraryPreparation) {
    guard !isSubmittingNativeLibrary,
      nativeLibraryPreparation?.planDigest == preparation.planDigest,
      nativeLibraryFeedbackScope?.targetID == preparation.targetID,
      nativeLibraryFeedbackScope?.bindingRevision == preparation.bindingRevision,
      nativeLibraryFeedbackScope?.targetBundle == preparation.targetBundle,
      nativeLibraryFeedbackScope?.libraryLogicalName == preparation.libraryName,
      nativeLibraryFeedbackScope?.verificationProfile == preparation.verificationProfile,
      nativeLibraryFeedbackScope?.rollbackPolicy == preparation.rollbackPolicy
    else { return }
    isSubmittingNativeLibrary = true
    activeNativeLibraryJobID = nil
    nativeLibraryTerminal = nil
    nativeLibraryFailure = nil
    let provider = provider
    Task { [weak self] in
      let submitted = await provider.submitNativeLibrary(preparation: preparation)
      guard let self, !Task.isCancelled else { return }
      switch submitted {
      case .failed(let failure):
        self.nativeLibraryFailure = failure
        self.isSubmittingNativeLibrary = false
      case .submitted(let acceptance):
        self.activeNativeLibraryJobID = acceptance.jobID
        let polling = Task { @MainActor [weak self] in
          while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { break }
            self?.refresh(targetID: preparation.targetID)
          }
        }
        let result = await provider.run(jobID: acceptance.jobID)
        polling.cancel()
        guard !Task.isCancelled else { return }
        self.activeNativeLibraryJobID = nil
        self.isSubmittingNativeLibrary = false
        switch result {
        case .completed(let terminal): self.nativeLibraryTerminal = terminal
        case .failed(let failure): self.nativeLibraryFailure = failure
        }
        self.refresh(targetID: preparation.targetID)
      }
    }
  }

  func cancelNativeLibrary() {
    guard let jobID = activeNativeLibraryJobID, !isCancellingNativeLibrary else { return }
    isCancellingNativeLibrary = true
    let provider = provider
    Task { [weak self] in
      let accepted = await provider.cancel(jobID: jobID)
      guard let self else { return }
      self.isCancellingNativeLibrary = false
      if !accepted {
        self.nativeLibraryFailure = "Runtime refused the cancellation request"
      }
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
    case DebugApplicationFacade.nativeLibraryReference: nativeLibraryFailure = message
    default: portRuleFailure = message
    }
  }

  func mutatePortRule(
    target: DebugTargetPresentation,
    rule: DebugValidatedPortRule,
    removing: Bool
  ) {
    guard !isMutatingPortRule else { return }
    portRuleFeedbackScope = TargetBindingScope(target: target)
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
    commandFeedbackScope = CommandFeedbackScope(
      target: TargetBindingScope(target: target), templateID: templateID)
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
    commandFeedbackScope = nil
    commandResult = nil
    commandFailure = nil
  }
}

private enum DebugL10n {
  static func text(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "DebugLocalizable")
  }
}

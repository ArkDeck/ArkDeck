import AppKit
import ArkDeckWorkflows
import Observation
import SwiftUI
import os

/// Points of Interest for the user-perceived launch path. Instruments' App
/// Launch template owns process/loader/first-frame timing; these regions add
/// the product milestones that matter after the process begins building the
/// SwiftUI shell.
@MainActor
enum AppStartupPerformance {
  private static let clock = ContinuousClock()
  private static let signposter = OSSignposter(
    subsystem: Bundle.main.bundleIdentifier ?? "com.arkdeck.desktop",
    category: .pointsOfInterest)
  private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.arkdeck.desktop",
    category: "StartupPerformance")
  private static var startupState: OSSignpostIntervalState?
  private static var startupBeganAt: ContinuousClock.Instant?
  private static var deviceDiscoveryState: OSSignpostIntervalState?
  private static let uiTestEvidenceEnvironmentKey =
    "ARKDECK_UI_TEST_STARTUP_EVIDENCE_PATH"

  static func beginStartup() {
    guard startupState == nil else { return }
    startupBeganAt = clock.now
    startupState = signposter.beginInterval("App Startup to Device Information")
    signposter.emitEvent("Startup Model Construction Began")
  }

  static func modelsReady() {
    signposter.emitEvent("Startup Models Ready")
  }

  static func firstWindowAppeared() {
    signposter.emitEvent("First Window Appeared")
    if let startupBeganAt {
      let seconds = startupBeganAt.duration(to: clock.now).timeInterval
      logger.notice("First window appeared after \(seconds, privacy: .public) seconds")
    }
  }

  static func beginDeviceDiscovery() {
    guard deviceDiscoveryState == nil else { return }
    deviceDiscoveryState = signposter.beginInterval("Startup Device Discovery")
  }

  static func deviceCandidatesPublished() {
    signposter.emitEvent("Device Candidates Published")
  }

  static func deviceInformationReady() {
    signposter.emitEvent("Complete Device Information Ready")
    if let state = deviceDiscoveryState {
      signposter.endInterval("Startup Device Discovery", state)
      deviceDiscoveryState = nil
    }
  }

  static func deviceInformationDisplayed() -> TimeInterval? {
    guard let state = startupState, let startupBeganAt else { return nil }
    signposter.emitEvent("Complete Device Information Displayed")
    let seconds = startupBeganAt.duration(to: clock.now).timeInterval
    logger.notice(
      "Complete device information displayed after \(seconds, privacy: .public) seconds")
    signposter.endInterval("App Startup to Device Information", state)
    startupState = nil
    AppStartupPerformance.startupBeganAt = nil
    return ProcessInfo.processInfo.environment[uiTestEvidenceEnvironmentKey] == nil
      ? nil : seconds
  }
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let parts = components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
  }
}

/// Owns the App's long-lived presentation models without constructing every
/// workspace before the first frame. Only projections rendered by the shell
/// itself are eager; a workspace pays its setup cost when its branch first
/// becomes visible.
@MainActor
@Observable
private final class ArkDeckAppModelStore {
  let autoUpdate: AutoUpdateViewModel
  let runtimeHistory: RuntimeHistoryViewModel
  let deviceList: DeviceListViewModel

  @ObservationIgnored lazy var hdcDiagnostics = HDCStatusViewModel(
    provider: HDCApplicationDiagnosticsFacade.make())
  @ObservationIgnored lazy var overviewCapabilities = OverviewCapabilityViewModel(
    provider: OverviewCapabilityApplicationFacade.make())
  @ObservationIgnored lazy var flashWorkspace = FlashWorkspaceViewModel(
    provider: FlashApplicationFacade.make())
  // A launch without `--ui-test-viewer…` never reaches the fixture, so the
  // production path stays the XPC facade and nothing else.
  @ObservationIgnored lazy var uiDumpWorkspace = UIDumpWorkspaceViewModel(
    provider: ViewerUIFixture.provider() ?? UIDumpApplicationFacade.make())
  @ObservationIgnored lazy var debugWorkspace = DebugWorkspaceViewModel(
    provider: DebugApplicationFacade.make())
  @ObservationIgnored lazy var traceWorkspace = TraceWorkspaceViewModel(
    provider: TraceApplicationFacade.make())
  @ObservationIgnored lazy var settingsWorkspace = SettingsWorkspaceViewModel(
    provider: SettingsApplicationFacade.make())

  init() {
    AppStartupPerformance.beginStartup()
    autoUpdate = AutoUpdateViewModel()
    runtimeHistory = RuntimeHistoryViewModel(
      provider: RuntimeHistoryApplicationFacade.make(),
      detailProvider: RuntimeJobDetailApplicationFacade.make())
    deviceList = DeviceListViewModel(
      provider: DeviceListApplicationFacade.make(),
      resetDisplayNames: ProcessInfo.processInfo.arguments.contains(
        "--ui-test-reset-device-names"))
    AppStartupPerformance.modelsReady()
    // The connected-device row is first-screen content, so begin its async
    // read while SwiftUI builds the window instead of waiting for `.task`
    // after first appearance. The task inherits the main actor only for
    // publication; the provider actor owns the Runtime/XPC wait.
    deviceList.refreshForStartup()
  }
}

@main
struct ArkDeckApp: App {
  @State private var models = ArkDeckAppModelStore()

  var body: some Scene {
    WindowGroup {
      AppShellView(models: models)
    }
    .defaultSize(width: 1180, height: 760)
    Settings {
      SettingsSceneLoader(models: models)
    }
  }
}

/// Shell navigation is presentation vocabulary owned by the App target; the
/// domain package deliberately knows nothing about it.
private enum ArkDeckNavigationItem: String, CaseIterable, Hashable, Identifiable, Sendable {
  case overview
  case flash
  case debug
  case uiDump
  case trace
  case history

  var id: String { rawValue }

  var localizationKey: String {
    switch self {
    case .overview: "app.navigation.overview"
    case .flash: "app.navigation.flash"
    case .debug: "app.navigation.debug"
    case .uiDump: "app.navigation.uiDump"
    case .trace: "app.navigation.trace"
    case .history: "app.navigation.history"
    }
  }

  var systemImageName: String {
    switch self {
    case .overview: "rectangle.grid.2x2"
    case .flash: "bolt"
    case .debug: "ladybug"
    case .uiDump: "rectangle.3.group"
    case .trace: "waveform.path.ecg"
    case .history: "clock.arrow.circlepath"
    }
  }

  var accessibilityIdentifier: String { "app.navigation.\(rawValue)" }
}

/// A sidebar choice: one of the fixed workspaces, or a device row. A device
/// row is a navigation destination for that device's detail. It never becomes
/// an implicit target scope for a workflow workspace.
private enum ShellSelection: Hashable {
  case navigation(ArkDeckNavigationItem)
  case device(connectKey: String)

  /// Stable scene-storage encoding; unknown values fall back to Overview.
  var storageValue: String {
    switch self {
    case .navigation(let item): return item.rawValue
    case .device(let connectKey): return "device:\(connectKey)"
    }
  }

  init(storageValue: String) {
    if storageValue.hasPrefix("device:") {
      self = .device(connectKey: String(storageValue.dropFirst("device:".count)))
    } else {
      self = .navigation(ArkDeckNavigationItem(rawValue: storageValue) ?? .overview)
    }
  }
}

/// Native window shell: system split view, unified toolbar, and one workspace
/// per navigation item. Implemented workspaces consume only their own Runtime
/// projections; features without an accepted production surface remain
/// explicit rather than re-rendering another page's data under a new title.
private struct OverviewWorkspaceView: View {
  let hdcDiagnostics: HDCStatusViewModel
  let overviewCapabilities: OverviewCapabilityViewModel

  var body: some View {
    HDCStatusView(
      presentation: hdcDiagnostics.presentation,
      capabilityMatrix: overviewCapabilities.presentation,
      onRefresh: {
        hdcDiagnostics.refresh()
        overviewCapabilities.refresh()
      },
      isRefreshInFlight: hdcDiagnostics.isRefreshInFlight
        || overviewCapabilities.isRefreshInFlight,
      onRequestRecoveryImpactPreview: hdcDiagnostics.requestRecoveryImpactPreview,
      onConfirmRecoveryImpactPreview: hdcDiagnostics.confirmRecoveryImpactPreview,
      onDispatchConfirmedRecovery: hdcDiagnostics.dispatchConfirmedRecoveryAction,
      onSelectUserConfiguredExecutable: hdcDiagnostics.selectUserConfiguredExecutable,
      configurationError: hdcDiagnostics.configurationError)
  }
}

/// Observation stays inside the inspector instead of making every Runtime
/// history publication invalidate the complete navigation shell.
private struct RuntimeHistoryJobInspector: View {
  let model: RuntimeHistoryViewModel
  let onOpenHistory: () -> Void
  @Binding var isExpanded: Bool

  var body: some View {
    GlobalJobInspectorView(
      presentation: model.presentation,
      isRefreshInFlight: model.isRefreshInFlight,
      onRefresh: model.refresh,
      onOpenHistory: onOpenHistory,
      isExpanded: $isExpanded)
  }
}

/// The global recovery summary has its own Observation dependency boundary.
/// A history refresh no longer reruns sidebar and device-detail construction.
private struct RuntimeRecoveryBanner: View {
  let model: RuntimeHistoryViewModel
  let onOpenHistory: () -> Void

  var body: some View {
    GlobalRecoveryBannerView(
      presentation: model.presentation,
      onOpenHistory: onOpenHistory)
  }
}

/// Update state is independent from navigation and device discovery. Keeping
/// it in ToolbarContent prevents an updater transition from invalidating the
/// AppShellView body.
private struct UpdateAttentionToolbarContent: ToolbarContent {
  let model: AutoUpdateViewModel

  @ToolbarContentBuilder
  var body: some ToolbarContent {
    if let attention = model.attention {
      ToolbarItem(placement: .automatic) {
        SettingsLink {
          Label(
            LocalizedStringKey(attention.localizationKey),
            systemImage: attention.systemImageName
          )
          .labelStyle(.titleAndIcon)
        }
        .accessibilityIdentifier("app.toolbar.updateAttention")
      }
    } else {
      ToolbarItem(placement: .automatic) {
        SettingsLink {
          Label("app.toolbar.openSettings", systemImage: "gearshape")
            .labelStyle(.iconOnly)
        }
        .help(Text("app.toolbar.openSettings"))
        .accessibilityIdentifier("app.toolbar.openSettings")
      }
    }
  }
}

private struct AppShellView: View {
  @SceneStorage("app.shell.selection")
  private var storedSelection = ArkDeckNavigationItem.overview.rawValue
  @State private var isJobInspectorExpanded = false
  @State private var renamingDeviceConnectKey: String?
  @State private var pendingDeviceName = ""
  private let models: ArkDeckAppModelStore
  private let autoUpdate: AutoUpdateViewModel
  private let runtimeHistory: RuntimeHistoryViewModel
  private let deviceList: DeviceListViewModel

  init(models: ArkDeckAppModelStore) {
    self.models = models
    autoUpdate = models.autoUpdate
    runtimeHistory = models.runtimeHistory
    deviceList = models.deviceList
  }

  private var shellSelection: ShellSelection {
    ShellSelection(storageValue: storedSelection)
  }

  private var selectedItem: ArkDeckNavigationItem {
    if case .navigation(let item) = shellSelection { return item }
    return .overview
  }

  private var selection: Binding<ShellSelection?> {
    Binding(
      get: { shellSelection },
      set: { storedSelection = ($0 ?? .navigation(.overview)).storageValue })
  }

  var body: some View {
    VStack(spacing: 0) {
      NavigationSplitView {
        List(selection: selection) {
          Section("app.navigation.section.device") {
            navigationRow(.overview)
            deviceRows
          }
          Section("app.navigation.section.workflows") {
            navigationRow(.flash)
            navigationRow(.debug)
            navigationRow(.uiDump)
            navigationRow(.trace)
          }
          Section("app.navigation.section.records") {
            navigationRow(.history)
          }
        }
        .navigationSplitViewColumnWidth(min: 232, ideal: 244, max: 300)
        .navigationTitle("app.shell.title")
      } detail: {
        GeometryReader { geometry in
          jobAwareDetail
            .frame(
              width: geometry.size.width, height: geometry.size.height,
              alignment: .topLeading)
        }
        .navigationTitle(detailTitle)
        .toolbar { UpdateAttentionToolbarContent(model: autoUpdate) }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      if !isJobInspectorExpanded {
        Divider()
        RuntimeHistoryJobInspector(
          model: runtimeHistory,
          onOpenHistory: openHistory,
          isExpanded: $isJobInspectorExpanded
        )
        .frame(height: 40)
        .background(.bar)
      }
    }
    .frame(minWidth: 900, minHeight: 600)
    .onAppear {
      AppStartupPerformance.firstWindowAppeared()
    }
    // Leaving the device whose trust window is being waited on ends that wait
    // without a verdict: an abandoned window must not later claim it closed.
    .onChange(of: storedSelection) { _, newValue in
      let waitedKey: String?
      switch deviceList.authorizationWait {
      case .idle: waitedKey = nil
      case .polling(let key, _), .timedOut(let key), .unavailable(let key, _): waitedKey = key
      }
      guard let waitedKey else { return }
      if case .device(waitedKey) = ShellSelection(storageValue: newValue) { return }
      deviceList.cancelAuthorizationWait()
    }
    // A workspace owns fresh facts only while it is visible. The device read
    // admits the restored selection below; subsequent navigation refreshes
    // only the newly visible branch.
    .onChange(of: storedSelection) { _, newValue in
      guard deviceList.presentation.availability != .checking else { return }
      refreshVisibleProjection(for: newValue)
    }
    // The shared device observation feeds every workspace that needs routing,
    // and keeps feeding it: a device that unplugs leaves the pickers without
    // anyone navigating. It runs only while the App is active.
    .onChange(of: deviceList.presentation) { _, observation in
      publishDeviceObservation(observation)
    }
    .task(id: deviceList.startupInformationReady) {
      guard deviceList.startupInformationReady else { return }
      // Yield the main actor once so SwiftUI can commit the complete device
      // row before independent secondary reads fan out concurrently.
      await Task.yield()
      runtimeHistory.refresh()
      autoUpdate.startup()
      ApplicationIconChoice.applyStoredSelection()
      publishDeviceObservation(deviceList.presentation)
      refreshVisibleProjection(for: storedSelection)
      deviceList.startLiveObservation()
    }
    .onDisappear { deviceList.stopLiveObservation() }
    .alert(
      deviceString("device.rename.title"),
      isPresented: renameDialogIsPresented
    ) {
      TextField(deviceString("device.rename.field"), text: pendingDeviceNameBinding)
        .accessibilityIdentifier("device.rename.name")
      Button(deviceString("device.rename.cancel"), role: .cancel) {}
      Button(deviceString("device.rename.commit"), action: commitRename)
        .disabled(!deviceList.canUseDisplayName(pendingDeviceName))
        .accessibilityIdentifier("device.rename.commit")
    } message: {
      Text(deviceString("device.rename.message"))
    }
  }

  @ViewBuilder
  private var jobAwareDetail: some View {
    if isJobInspectorExpanded {
      VSplitView {
        workspaceWithRecovery
          .frame(minHeight: 320, maxHeight: .infinity)
        RuntimeHistoryJobInspector(
          model: runtimeHistory,
          onOpenHistory: openHistory,
          isExpanded: $isJobInspectorExpanded
        )
        .frame(minHeight: 220, idealHeight: 260, maxHeight: 320)
      }
    } else {
      workspaceWithRecovery
    }
  }

  private var workspaceWithRecovery: some View {
    VStack(spacing: 0) {
      RuntimeRecoveryBanner(model: runtimeHistory, onOpenHistory: openHistory)
      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func openHistory() {
    storedSelection = ShellSelection.navigation(.history).storageValue
  }

  /// Fans the shared observation out to the workspaces that need routing.
  /// Under the Viewer fixture the fixture's own device stands in, so a
  /// launch that fabricates a capture also fabricates the device it came
  /// from rather than contradicting itself.
  private func publishDeviceObservation(_ observation: DeviceListPresentation) {
    let effective = ViewerUIFixture.deviceObservation() ?? observation
    models.uiDumpWorkspace.applyDeviceObservation(
      effective, names: deviceDisplayNames(effective))
  }

  /// Presentation-only names, keyed by the adopted target the workspaces
  /// address. A connect key identifies hardware and never reaches a picker.
  private func deviceDisplayNames(_ observation: DeviceListPresentation) -> [String: String] {
    var names: [String: String] = [:]
    for candidate in observation.candidates {
      guard let targetID = candidate.adoptedTargetID else { continue }
      names[targetID] = deviceList.displayName(for: candidate)
    }
    return names
  }

  private func refreshVisibleProjection(for storageValue: String) {
    switch ShellSelection(storageValue: storageValue) {
    case .device:
      break
    case .navigation(.overview):
      models.hdcDiagnostics.refresh()
      models.overviewCapabilities.refresh()
    case .navigation(.history):
      runtimeHistory.refresh()
    case .navigation(.flash):
      models.flashWorkspace.refresh()
    case .navigation(.debug):
      models.debugWorkspace.refresh()
    case .navigation(.uiDump):
      models.uiDumpWorkspace.refresh()
    case .navigation(.trace):
      models.traceWorkspace.refresh()
    }
  }

  private var detailTitle: Text {
    if case .device(let connectKey) = shellSelection {
      let candidate = deviceList.candidate(forConnectKey: connectKey)
      return Text(candidate.map(deviceList.displayName(for:)) ?? connectKey)
    }
    return Text(LocalizedStringKey(selectedItem.localizationKey))
  }

  /// Device detail destinations live under the same Devices section as Overview. The list
  /// states its own failure and stays silent only when there is genuinely
  /// nothing: an unreadable candidate list is never shown as an empty one.
  @ViewBuilder
  private var deviceRows: some View {
    switch deviceList.presentation.availability {
    case .checking:
      EmptyView()
    case .unavailable:
      Label {
        Text("app.devices.unavailable")
          .font(.caption)
          .foregroundStyle(.secondary)
      } icon: {
        Image(systemName: "antenna.radiowaves.left.and.right.slash")
          .foregroundStyle(.secondary)
      }
      .accessibilityIdentifier("app.devices.unavailable")
    case .available:
      ForEach(deviceList.presentation.candidates) { candidate in
        DeviceSidebarRow(
          candidate: candidate,
          displayName: deviceList.displayName(for: candidate)
        )
        .contextMenu {
          Button {
            beginRenaming(candidate)
          } label: {
            Label(deviceString("device.action.rename"), systemImage: "pencil")
          }
          .accessibilityIdentifier("device.action.rename.\(candidate.connectKey)")

          Button {
            deviceList.refresh()
          } label: {
            Label(deviceString("device.action.recheck"), systemImage: "arrow.clockwise")
          }
          .disabled(deviceList.isRefreshing)
          .accessibilityIdentifier("device.action.recheck.\(candidate.connectKey)")
        }
        .tag(ShellSelection.device(connectKey: candidate.connectKey))
      }
    }
  }

  @ViewBuilder
  private var detail: some View {
    if deviceList.presentation.availability == .checking {
      ProgressView()
        .controlSize(.large)
        .accessibilityIdentifier("app.devices.checking")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if case .device(let connectKey) = shellSelection {
      if let candidate = deviceList.candidate(forConnectKey: connectKey) {
        DeviceDetailView(
          candidate: candidate,
          displayName: deviceList.displayName(for: candidate),
          isRefreshing: deviceList.isRefreshing,
          waitState: deviceList.authorizationWaitState(forConnectKey: connectKey),
          onRecheck: deviceList.refresh,
          onBeginWait: { deviceList.beginAuthorizationWait(forConnectKey: connectKey) },
          onOpenOverview: {
            deviceList.cancelAuthorizationWait()
            storedSelection = ShellSelection.navigation(.overview).storageValue
          })
      } else {
        // The chosen device left the candidate list (unplugged, or the list
        // was re-read). Say so; do not render stale facts as current.
        ContentUnavailableView {
          Label {
            Text("app.devices.gone")
              .accessibilityIdentifier("app.devices.gone")
          } icon: {
            Image(systemName: "cable.connector.slash")
          }
        } description: {
          Text("app.devices.goneDetail")
        }
      }
    } else {
      workspaceDetail
    }
  }

  @ViewBuilder
  private var workspaceDetail: some View {
    switch selectedItem {
    case .overview:
      OverviewWorkspaceView(
        hdcDiagnostics: models.hdcDiagnostics,
        overviewCapabilities: models.overviewCapabilities)
    case .history:
      RuntimeHistoryView(
        presentation: runtimeHistory.presentation,
        detailsByJobID: runtimeHistory.detailsByJobID,
        loadingDetailJobIDs: runtimeHistory.loadingDetailJobIDs,
        exportStatesByArtifactID: runtimeHistory.exportStatesByArtifactID,
        isRefreshInFlight: runtimeHistory.isRefreshInFlight,
        isLoadOlderInFlight: runtimeHistory.isLoadOlderInFlight,
        onRefresh: runtimeHistory.refresh,
        onLoadOlder: runtimeHistory.loadOlder,
        onLoadDetail: runtimeHistory.loadDetail,
        onExportArtifact: runtimeHistory.exportArtifact)
    case .flash:
      FlashWorkspaceView(
        model: models.flashWorkspace,
        runtimeHistory: runtimeHistory.presentation,
        isRuntimeHistoryRefreshing: runtimeHistory.isRefreshInFlight,
        onRefreshRuntimeHistory: runtimeHistory.refresh,
        onOpenHistory: openHistory)
    case .debug:
      DebugWorkspaceView(
        model: models.debugWorkspace,
        onOpenHistory: openHistory)
    case .uiDump:
      UIDumpWorkspaceView(model: models.uiDumpWorkspace)
    case .trace:
      TraceWorkspaceView(model: models.traceWorkspace)
    }
  }

  private func navigationRow(_ item: ArkDeckNavigationItem) -> some View {
    NavigationLink(value: ShellSelection.navigation(item)) {
      Label {
        Text(LocalizedStringKey(item.localizationKey))
      } icon: {
        Image(systemName: item.systemImageName)
      }
      .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
      .contentShape(Rectangle())
    }
    // NavigationLink is the native selectable element for a split-view
    // sidebar. It keeps the visible label, stable identifier, selected state
    // and activation action together instead of flattening them into an
    // identifier-less AXRow.
    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityIdentifier(item.accessibilityIdentifier)
  }

  private var renameDialogIsPresented: Binding<Bool> {
    Binding(
      get: { renamingDeviceConnectKey != nil },
      set: { isPresented in
        if !isPresented {
          renamingDeviceConnectKey = nil
          pendingDeviceName = ""
        }
      })
  }

  private var pendingDeviceNameBinding: Binding<String> {
    Binding(
      get: { pendingDeviceName },
      set: { newValue in
        pendingDeviceName = String(newValue.prefix(DeviceListViewModel.maximumDisplayNameLength))
      })
  }

  private func beginRenaming(_ candidate: DeviceCandidatePresentation) {
    storedSelection = ShellSelection.device(connectKey: candidate.connectKey).storageValue
    pendingDeviceName = deviceList.displayName(for: candidate)
    renamingDeviceConnectKey = candidate.connectKey
  }

  private func commitRename() {
    guard let connectKey = renamingDeviceConnectKey else { return }
    _ = deviceList.renameCandidate(withConnectKey: connectKey, to: pendingDeviceName)
  }
}

/// A Settings scene can exist without a Settings window. Delay access to its
/// models until the scene is actually presented; constructing the scene graph
/// at launch must not initialize session storage or diagnostics exporters.
private struct SettingsSceneLoader: View {
  let models: ArkDeckAppModelStore
  @State private var isPresented = false

  var body: some View {
    Group {
      if isPresented {
        SettingsSceneContent(models: models)
      } else {
        ProgressView()
      }
    }
    .task {
      await Task.yield()
      isPresented = true
    }
  }
}

private struct SettingsSceneContent: View {
  var model: SettingsWorkspaceViewModel
  let hdcDiagnostics: HDCStatusViewModel
  let runtimeHistory: RuntimeHistoryViewModel
  let autoUpdate: AutoUpdateViewModel

  init(models: ArkDeckAppModelStore) {
    model = models.settingsWorkspace
    hdcDiagnostics = models.hdcDiagnostics
    runtimeHistory = models.runtimeHistory
    autoUpdate = models.autoUpdate
  }

  var body: some View {
    SettingsRootView(
      model: model,
      hdcPresentation: hdcDiagnostics.presentation,
      isHDCRefreshInFlight: hdcDiagnostics.isRefreshInFlight,
      hdcConfigurationError: hdcDiagnostics.configurationError,
      hasActiveRuntimeJobs: runtimeHistory.hasActiveJobs,
      onHDCRefresh: { hdcDiagnostics.refresh() },
      onSelectHDC: hdcDiagnostics.selectUserConfiguredExecutable
    ) {
      AutoUpdateSettingsView(model: autoUpdate)
    }
  }
}

private struct AutoUpdateSettingsView: View {
  let model: AutoUpdateViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("update.title")
        .font(.title2)
      Toggle(
        "update.automaticChecks",
        isOn: Binding(
          get: { model.automaticChecksEnabled },
          set: { enabled in model.setAutomaticChecksEnabled(enabled) })
      )
      .accessibilityIdentifier("update.automaticChecks")
      Text("update.privacyDisclosure")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Button("update.checkNow", action: model.checkManually)
          .accessibilityIdentifier("update.checkNow")
          .disabled(model.isBusy || !model.canCheck)
        Button("update.download", action: model.download)
          .accessibilityIdentifier("update.download")
          .disabled(model.isBusy || !model.canDownload)
        Button("update.reveal", action: model.reveal)
          .accessibilityIdentifier("update.reveal")
          .disabled(model.isBusy || !model.canReveal)
      }
      Text(LocalizedStringKey(model.statusKey))
        .font(.headline)
        .accessibilityIdentifier("update.status")
      if let releaseNotesSummary = model.releaseNotesSummary {
        Text(releaseNotesSummary)
          .textSelection(.enabled)
      }
      Text("update.manualInstallDisclosure")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

@MainActor
@Observable
private final class AutoUpdateViewModel {
  private(set) var automaticChecksEnabled = true
  private(set) var statusKey = "update.status.idle"
  private(set) var releaseNotesSummary: String?
  private(set) var isBusy = false
  private(set) var canCheck = true
  private(set) var canDownload = false
  private(set) var canReveal = false
  /// Only states the user has to act on reach the main window. Idle and
  /// up-to-date results stay in the Settings scene.
  private(set) var attention: Attention?

  enum Attention: String, Sendable {
    case available
    case awaitingConsent
    case failed

    var localizationKey: String {
      switch self {
      case .available: "update.toolbar.available"
      case .awaitingConsent: "update.toolbar.awaitingConsent"
      case .failed: "update.toolbar.failed"
      }
    }

    var systemImageName: String {
      switch self {
      case .available: "arrow.down.circle"
      case .awaitingConsent: "hand.raised"
      case .failed: "exclamationmark.triangle"
      }
    }
  }

  @ObservationIgnored private var service: AutoUpdateService?
  private let identity = AutoUpdateApplicationFacade.currentProductIdentity()
  @ObservationIgnored private var started = false
  /// UI automation drives a declared state instead of the real updater, which
  /// is neither deterministic nor free of network effects. It is only the
  /// state: the mapping below is the product's own, so a test reads what the
  /// App really renders rather than a second copy of the rules.
  private let usesFixture: Bool

  init() {
    usesFixture = AutoUpdateUIFixture.isSelected()
    service = nil
  }

  func startup() {
    guard !started else { return }
    started = true
    if usesFixture {
      Task { await synchronize() }
      return
    }
    Task { [weak self] in
      // Storage discovery and diagnostic log scanning are not UI work. Build
      // the actor away from the main actor, after connected devices are visible.
      let service = await Task.detached(priority: .utility) {
        try? AutoUpdateApplicationFacade.make()
      }.value
      guard let self, !Task.isCancelled else { return }
      guard let service else {
        statusKey = "update.status.unavailable"
        return
      }
      self.service = service
      do {
        try await service.recoverOrphanPartials()
        automaticChecksEnabled = await service.automaticChecksEnabled
        _ = try await service.checkAutomaticallyIfDue(identity: identity)
        await synchronize()
      } catch AutoUpdateServiceError.automaticChecksDisabled,
        AutoUpdateServiceError.automaticCheckNotDue
      {
        await synchronize()
      } catch {
        // Only connectivity failure is softened. Integrity, replay and local-state failures keep
        // the service's explicit failed presentation instead of looking like a routine miss.
        if case .failed(.network) = await service.state {
          statusKey = "update.status.automaticCheckIncomplete"
          isBusy = false
        } else {
          await synchronize()
        }
      }
    }
  }

  func setAutomaticChecksEnabled(_ enabled: Bool) {
    automaticChecksEnabled = enabled
    guard let service else { return }
    Task { await service.setAutomaticChecksEnabled(enabled) }
  }

  func checkManually() {
    // Under the fixture a check re-reads the declared state, so one launched
    // instance walks every state through the App's real check path.
    if usesFixture {
      Task { await synchronize() }
      return
    }
    guard let service else { return }
    isBusy = true
    statusKey = "update.status.checking"
    Task {
      do {
        _ = try await service.checkManually(identity: identity)
        await synchronize()
      } catch {
        await synchronize()
      }
    }
  }

  func download() {
    guard let service else { return }
    isBusy = true
    statusKey = "update.status.downloading"
    Task {
      do {
        _ = try await service.downloadAvailableUpdate()
        await synchronize()
      } catch {
        await synchronize()
      }
    }
  }

  func reveal() {
    guard let service else { return }
    isBusy = true
    Task {
      do {
        _ = try await service.handoff(
          explicitConsent: true, revealer: FinderUpdateArtifactRevealer())
        await synchronize()
      } catch {
        await synchronize()
      }
    }
  }

  private func synchronize() async {
    let state: AutoUpdateState
    if usesFixture {
      guard let declared = AutoUpdateUIFixture.state() else { return }
      state = declared
    } else if let service {
      state = await service.state
    } else {
      return
    }
    isBusy = false
    canCheck = true
    canDownload = false
    canReveal = false
    releaseNotesSummary = nil
    attention = nil
    switch state {
    case .idle:
      statusKey = "update.status.idle"
    case .checking:
      statusKey = "update.status.checking"
      isBusy = true
      canCheck = false
    case .available(let feed):
      statusKey = "update.status.available"
      releaseNotesSummary = feed.payload.releaseNotesSummary
      canDownload = true
      attention = .available
    case .noUpdate:
      statusKey = "update.status.current"
    case .downloading:
      statusKey = "update.status.downloading"
      isBusy = true
      canCheck = false
    case .verifying:
      statusKey = "update.status.verifying"
      isBusy = true
      canCheck = false
    case .awaitingConsent(let feed, _):
      statusKey = "update.status.awaitingConsent"
      releaseNotesSummary = feed.payload.releaseNotesSummary
      canCheck = false
      canReveal = true
      attention = .awaitingConsent
    case .handedOff:
      statusKey = "update.status.handedOff"
      canCheck = false
    case .failed:
      statusKey = "update.status.failed"
      attention = .failed
    case .cancelled:
      statusKey = "update.status.cancelled"
    }
  }
}

private struct FinderUpdateArtifactRevealer: UpdateArtifactRevealing {
  @MainActor
  func revealInFinder(_ url: URL) throws {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
}

/// Bridges the App presentation to a domain-owned state provider. The model
/// has no candidate, process runner, lifecycle executor, or durable-audit
/// access of its own.
@MainActor
@Observable
private final class HDCStatusViewModel {
  private(set) var presentation: HDCDiagnosticsPresentation = .loading
  private(set) var configurationError: String?
  private(set) var isRefreshInFlight = false
  let lifecycleDispatchIsProductionComposed: Bool
  private let provider: any HDCApplicationDiagnosticsProviding

  init(provider: any HDCApplicationDiagnosticsProviding) {
    self.provider = provider
    lifecycleDispatchIsProductionComposed = provider.lifecycleDispatchIsProductionComposed
  }

  func refresh() {
    guard !isRefreshInFlight else { return }
    isRefreshInFlight = true
    let provider = provider
    Task { [weak self] in
      let next = await provider.refresh()
      guard let self else { return }
      defer { self.isRefreshInFlight = false }
      guard !Task.isCancelled else { return }
      self.presentation = next
    }
  }

  func requestRecoveryImpactPreview() {
    load { provider in await provider.requestRecoveryImpactPreview() }
  }

  func confirmRecoveryImpactPreview() {
    load { provider in await provider.confirmRecoveryImpactPreview() }
  }

  func dispatchConfirmedRecovery() {
    load { provider in await provider.dispatchConfirmedRecovery() }
  }

  var dispatchConfirmedRecoveryAction: (() -> Void)? {
    guard lifecycleDispatchIsProductionComposed else { return nil }
    return dispatchConfirmedRecovery
  }

  func selectUserConfiguredExecutable(_ url: URL) {
    guard !isRefreshInFlight else { return }
    let provider = provider
    Task { [weak self] in
      do {
        let next = try await provider.selectUserConfiguredExecutable(url)
        guard !Task.isCancelled else { return }
        self?.configurationError = nil
        self?.presentation = next
      } catch {
        self?.configurationError =
          "Unable to retain access to the selected HDC executable: \(error)"
      }
    }
  }

  private func load(
    _ operation:
      @escaping @Sendable (any HDCApplicationDiagnosticsProviding) async
      -> HDCDiagnosticsPresentation
  ) {
    let provider = provider
    Task { [weak self] in
      let next = await operation(provider)
      guard !Task.isCancelled else { return }
      self?.presentation = next
    }
  }
}

@MainActor
@Observable
private final class OverviewCapabilityViewModel {
  private(set) var presentation = OverviewCapabilityMatrixPresentation.loading
  private(set) var isRefreshInFlight = false
  private let provider: any OverviewCapabilityApplicationProviding

  init(provider: any OverviewCapabilityApplicationProviding) {
    self.provider = provider
  }

  func refresh() {
    guard !isRefreshInFlight else { return }
    isRefreshInFlight = true
    let provider = provider
    Task { [weak self] in
      let next = await provider.refresh()
      guard let self else { return }
      self.isRefreshInFlight = false
      guard !Task.isCancelled else { return }
      self.presentation = next
    }
  }
}

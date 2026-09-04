import AppKit
import ArkDeckTraceAdapter
import ArkDeckWorkflows
import ArkTraceAppSupport
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
  var requestedNavigation: ArkDeckNavigationItem?
  var reopenedHistoryContext: RuntimeHistoryWorkspaceContext?

  @ObservationIgnored lazy var hdcDiagnostics = HDCStatusViewModel(
    provider: HDCApplicationDiagnosticsFacade.make())
  @ObservationIgnored lazy var overviewCapabilities = OverviewCapabilityViewModel(
    provider: OverviewCapabilityApplicationFacade.make())
  @ObservationIgnored lazy var overviewRemoteServer = OverviewRemoteServerViewModel()
  @ObservationIgnored lazy var flashWorkspace = FlashWorkspaceViewModel(
    provider: FlashApplicationFacade.make())
  // A launch without `--ui-test-viewer…` never reaches the fixture, so the
  // production path stays the XPC facade and nothing else.
  @ObservationIgnored lazy var uiDumpWorkspace = UIDumpWorkspaceViewModel(
    provider: ViewerUIFixture.provider() ?? UIDumpApplicationFacade.make())
  @ObservationIgnored lazy var debugWorkspace = DebugWorkspaceViewModel(
    provider: DebugApplicationFacade.make())
  @ObservationIgnored lazy var traceDocument = TraceDocumentController(
    configuration: ArkDeckTraceConfiguration.make())
  @ObservationIgnored lazy var traceWorkspace = TraceWorkspaceViewModel(
    provider: TraceApplicationFacade.make(),
    documentController: traceDocument)
  @ObservationIgnored lazy var settingsWorkspace = SettingsWorkspaceViewModel(
    provider: SettingsApplicationFacade.make())
  @ObservationIgnored lazy var deviceWorkspace = DeviceWorkspaceViewModel(
    provider: DeviceControlFacade.make())
  // A launch without `--ui-test-device-recording=` never reaches the fixture.
  @ObservationIgnored lazy var deviceRecording = DeviceRecordingViewModel(
    provider: DeviceRecordingFixture.provider() ?? DeviceControlFacade.make())
  @ObservationIgnored lazy var diagnosticsWorkspace = DiagnosticsWorkspaceViewModel(
    provider: RuntimeJobDetailApplicationFacade.make())

  init() {
    AppStartupPerformance.beginStartup()
    autoUpdate = AutoUpdateViewModel()
    runtimeHistory = RuntimeHistoryViewModel(
      provider: RuntimeHistoryApplicationFacade.make(),
      detailProvider: RuntimeJobDetailApplicationFacade.make(),
      filterProvider: RuntimeHistoryFilterApplicationFacade.make())
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

  func requestTraceWorkspace() {
    requestedNavigation = .trace
  }

  func consumeRequestedNavigation() -> ArkDeckNavigationItem? {
    defer { requestedNavigation = nil }
    return requestedNavigation
  }
}

@main
struct ArkDeckApp: App {
  @State private var models = ArkDeckAppModelStore()
  @Environment(\.openWindow) private var openWindow

  var body: some Scene {
    WindowGroup(id: ArkDeckWindow.main) {
      AppShellView(models: models)
        .onOpenURL(perform: openTrace)
        .overlay(alignment: .bottomTrailing) {
          if ProcessInfo.processInfo.arguments.contains("--ui-test-window-geometry") {
            WindowGeometryEvidence()
              .frame(width: 1, height: 1)
          }
        }
        .overlay(alignment: .bottomTrailing) {
          if let size = WindowFrameEstablisher.requestedSize {
            WindowFrameEstablisher(size: size)
              .frame(width: 1, height: 1)
          }
        }
    }
    .defaultSize(width: 1180, height: 760)
    .commands {
      CommandMenu("Trace") {
        Button(traceViewerText("Capture Trace…")) {
          models.requestTraceWorkspace()
          openWindow(id: ArkDeckWindow.main)
        }
        .keyboardShortcut("n")
        Button(traceViewerText("Open Trace…"), action: presentTraceOpenPanel)
          .keyboardShortcut("o", modifiers: [.command, .shift])
        Button(traceViewerText("Reload Trace")) { models.traceDocument.reload() }
          .keyboardShortcut("r", modifiers: [.command, .shift])
          .disabled(models.traceDocument.sourceURL == nil)
        Divider()
        Button(traceViewerText("Filter Trace Processes")) { models.traceDocument.focusProcessFilter() }
          .keyboardShortcut("f")
          .disabled(models.traceDocument.trackGroups.isEmpty)
        Button(traceViewerText("viewer.searchEvents.menu")) { models.traceDocument.focusTraceSearch() }
          .keyboardShortcut("f", modifiers: [.command, .shift])
          .disabled(models.traceDocument.metadata == nil)
      }
      CommandGroup(replacing: .help) {
        Button(traceViewerText("Trace Keyboard Shortcuts")) {
          openWindow(id: ArkDeckWindow.traceShortcuts)
        }
      }
    }
    Window("Trace Viewer", id: ArkDeckWindow.traceViewer) {
      TraceViewerSceneView(models: models)
    }
    .defaultSize(width: 1_280, height: 800)
    Window(traceViewerText("Trace Keyboard Shortcuts"), id: ArkDeckWindow.traceShortcuts) {
      ShortcutHelpView()
    }
    .defaultSize(width: 520, height: 620)
    Settings {
      SettingsSceneLoader(models: models)
    }
  }

  @MainActor
  private func presentTraceOpenPanel() {
    let panel = NSOpenPanel()
    panel.title = traceViewerText("viewer.openPanel.title")
    panel.prompt = traceViewerText("Open")
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = ArkDeckTraceConfiguration.supportedTraceContentTypes
    Task { @MainActor in
      guard await panel.begin() == .OK, let url = panel.url else { return }
      openTrace(url)
    }
  }

  @MainActor
  private func openTrace(_ url: URL) {
    guard url.isFileURL else { return }
    models.traceDocument.open(url)
    openWindow(id: ArkDeckWindow.traceViewer)
  }
}

enum ArkDeckWindow {
  static let main = "arkdeck.window.main"
  static let traceViewer = "arkdeck.window.traceViewer"
  static let traceShortcuts = "arkdeck.window.traceShortcuts"
}

/// Opt-in UI-test observation of the actual window, not a synthetic AppKit
/// style mask. The actual frame, full-size content and unobscured layout are
/// separate measurements; none is inferred from a generic title-bar size.
/// This never resizes a window or overrides its saved placement.
private struct WindowGeometryEvidence: NSViewRepresentable {
  func makeNSView(context: Context) -> Probe {
    Probe(frame: .zero)
  }

  func updateNSView(_ view: Probe, context: Context) {
    view.publish()
  }

  final class Probe: NSView {
    override init(frame: NSRect) {
      super.init(frame: frame)
      setAccessibilityElement(true)
      setAccessibilityRole(.staticText)
      setAccessibilityIdentifier("uiTest.windowGeometry")
      setAccessibilityLabel("Window geometry")
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      publish()
    }

    override func layout() {
      super.layout()
      publish()
    }

    func publish() {
      Task { @MainActor [weak self] in
        await Task.yield()
        guard let self, let window = unsafe self.window else { return }
        let frame = window.frame
        let content = window.contentRect(forFrameRect: frame)
        let layout = window.contentLayoutRect
        let facts = [
          "frameWidth": frame.width, "frameHeight": frame.height,
          "contentWidth": content.width, "contentHeight": content.height,
          "layoutWidth": layout.width, "layoutHeight": layout.height,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: facts) else { return }
        self.setAccessibilityValue(String(decoding: data, as: UTF8.self))
      }
    }
  }
}

/// Opt-in UI-test establishment of the window frame at launch.
///
/// `-ApplePersistenceIgnoreState` does not cover AppKit's window frame
/// autosave, so an ordinary test launch opens at whatever frame the previous
/// App process left behind — any earlier test, possibly saved against a
/// display arrangement that no longer exists. A geometry assertion made
/// against such a window measures desktop history instead of the product.
/// This hook gives a test run a declared frame: the requested outer size,
/// anchored to the top-left of the screen's visible area so later interactive
/// resizes have the whole visible height below them. It applies exactly once
/// per window; a test remains free to resize afterwards through the normal
/// AppKit paths, and an ordinary launch never reaches it.
private struct WindowFrameEstablisher: NSViewRepresentable {
  /// `--ui-test-window-frame=<width>x<height>`, or nil for every ordinary
  /// launch. A malformed value is nil on purpose: the adopting test asserts
  /// the frame it requested, so a typo fails there with the actual frame in
  /// evidence instead of crashing the App before it can publish anything.
  static let requestedSize: CGSize? = {
    let prefix = "--ui-test-window-frame="
    guard
      let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) })
    else { return nil }
    let parts = flag.dropFirst(prefix.count).split(separator: "x")
    guard
      parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
      width > 0, height > 0
    else { return nil }
    return CGSize(width: width, height: height)
  }()

  let size: CGSize

  func makeNSView(context: Context) -> Establisher {
    Establisher(size: size)
  }

  func updateNSView(_ view: Establisher, context: Context) {}

  final class Establisher: NSView {
    private let size: CGSize
    private var established = false

    init(size: CGSize) {
      self.size = size
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard unsafe window != nil, !established else { return }
      established = true
      // One turn later, so this wins over the autosaved-frame restore that
      // runs while the window is still being set up.
      Task { @MainActor [weak self] in
        await Task.yield()
        guard let self, let window = unsafe self.window else { return }
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        window.setFrame(
          NSRect(
            x: visible.minX, y: visible.maxY - self.size.height,
            width: self.size.width, height: self.size.height),
          display: true)
      }
    }
  }
}

private struct TraceViewerSceneView: View {
  let models: ArkDeckAppModelStore
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    TraceViewerRootView(
      controller: models.traceDocument,
      openCapture: {
        models.requestTraceWorkspace()
        openWindow(id: ArkDeckWindow.main)
      })
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
  case device
  case diagnostics
  case history

  var id: String { rawValue }

  var localizationKey: String {
    switch self {
    case .overview: "app.navigation.overview"
    case .flash: "app.navigation.flash"
    case .debug: "app.navigation.debug"
    case .uiDump: "app.navigation.uiDump"
    case .trace: "app.navigation.trace"
    case .device: "app.navigation.device"
    case .diagnostics: "app.navigation.diagnostics"
    case .history: "app.navigation.history"
    }
  }

  /// §14: every route names its stable product capability. The switch is
  /// exhaustive, so a new route cannot ship without an entry in the shared
  /// registry that the coverage manifest is generated from.
  var productCapability: AppNavigationCapability {
    switch self {
    case .overview: .overview
    case .flash: .flash
    case .debug: .debug
    case .uiDump: .uiDump
    case .trace: .trace
    case .device: .device
    case .diagnostics: .diagnostics
    case .history: .history
    }
  }

  var systemImageName: String {
    switch self {
    case .overview: "rectangle.grid.2x2"
    case .flash: "bolt"
    case .debug: "terminal"
    case .uiDump: "rectangle.3.group"
    case .trace: "waveform.path.ecg"
    case .device: "iphone"
    case .diagnostics: "waveform.path"
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
    } else if storageValue == "toolkit" {
      // Restore the previous workspace name without changing device-row routing.
      self = .navigation(.device)
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
  let overviewRemoteServer: OverviewRemoteServerViewModel
  let deviceList: DeviceListViewModel
  let runtimeHistory: RuntimeHistoryViewModel
  let onOpenWorkspace: (ArkDeckNavigationItem) -> Void
  let onOpenJob: (String) -> Void
  let onPrepare: (RuntimeWorkspaceContinuation) -> Void

  @State private var resumingRun: RuntimeJobSummaryPresentation?

  var body: some View {
    HDCStatusView(
      presentation: hdcDiagnostics.presentation,
      capabilityMatrix: overviewCapabilities.presentation,
      onRefresh: {
        hdcDiagnostics.refresh()
        overviewCapabilities.refresh()
        overviewRemoteServer.load(targetID: overviewCapabilities.presentation.targetID)
        runtimeHistory.refresh()
      },
      isRefreshInFlight: hdcDiagnostics.isRefreshInFlight
        || overviewCapabilities.isRefreshInFlight
        || runtimeHistory.isRefreshInFlight,
      onRequestRecoveryImpactPreview: hdcDiagnostics.requestRecoveryImpactPreview,
      onConfirmRecoveryImpactPreview: hdcDiagnostics.confirmRecoveryImpactPreview,
      onDispatchConfirmedRecovery: hdcDiagnostics.dispatchConfirmedRecoveryAction,
      onSelectUserConfiguredExecutable: hdcDiagnostics.selectUserConfiguredExecutable,
      configurationError: hdcDiagnostics.configurationError,
      header: { record })
      .sheet(item: $resumingRun) { run in
        OverviewResumeSheet(
          run: run,
          detail: runtimeHistory.detailsByJobID[run.id],
          isLoadingDetail: runtimeHistory.loadingDetailJobIDs.contains(run.id),
          currentTargetID: overviewCapabilities.presentation.targetID,
          currentBindingRevision: overviewCapabilities.presentation.bindingRevision,
          onOpenWorkspace: { openWorkspace(continuing: run) },
          onPrepare: { draft in
            resumingRun = nil
            onPrepare(draft)
          },
          onCancel: { resumingRun = nil })
      }
      .onChange(of: runtimeHistory.presentation, initial: true) { _, presentation in
        readEvidenceForVisibleRuns(presentation)
      }
      .onChange(of: overviewCapabilities.presentation.targetID, initial: true) {
        _, targetID in
        overviewRemoteServer.load(targetID: targetID)
      }
  }

  private var record: some View {
    OverviewRecordView(
      devices: deviceList.presentation,
      capabilities: overviewCapabilities.presentation,
      remoteServer: overviewRemoteServer.presentation,
      history: runtimeHistory.presentation,
      detailsByJobID: runtimeHistory.detailsByJobID,
      onSelectTarget: { overviewCapabilities.select(targetID: $0) },
      onOpenHistory: { onOpenWorkspace(.history) },
      onOpenJob: onOpenJob,
      onResume: { resumingRun = $0 })
  }

  /// Whether a run may be offered as repeatable depends on facts that live in
  /// its evidence, so the page reads the evidence for the runs it is actually
  /// showing. The read is bounded by the record's own truncation, never by the
  /// whole archive, and each Job is read once.
  private func readEvidenceForVisibleRuns(_ presentation: RuntimeHistoryPresentation) {
    let visible = OverviewRunRecordProjection.threads(from: presentation.jobs)
      .flatMap(\.runs)
    for run in visible where runtimeHistory.detailsByJobID[run.id] == nil {
      runtimeHistory.loadDetail(jobID: run.id, operationReference: run.operationReference)
    }
  }

  /// Opens the workspace that submitted this run. When the reported inputs do
  /// not identify one, the sheet stays put rather than prefilling a different
  /// request in whichever workspace looked closest.
  private func openWorkspace(continuing run: RuntimeJobSummaryPresentation) {
    let parameters = runtimeHistory.detailsByJobID[run.id]?.evidence?.parameters ?? []
    guard
      let kind = run.resolvedWorkspaceKind ?? RuntimeWorkspaceKindProjection.kind(
        forOperation: run.operationReference, parameters: parameters)
    else { return }
    resumingRun = nil
    onOpenWorkspace(Self.navigation(for: kind))
  }

  private static func navigation(for kind: RuntimeWorkspaceKind) -> ArkDeckNavigationItem {
    switch kind {
    case .viewer: .uiDump
    case .trace: .trace
    case .debug: .debug
    case .flash: .flash
    case .device: .device
    case .diagnostics: .diagnostics
    }
  }
}

/// Observation stays inside the inspector instead of making every Runtime
/// history publication invalidate the complete navigation shell.
private struct RuntimeHistoryJobInspector: View {
  let model: RuntimeHistoryViewModel
  let onOpenHistory: () -> Void
  let onOpenJob: (String) -> Void
  @Binding var isExpanded: Bool

  var body: some View {
    GlobalJobInspectorView(
      presentation: model.presentation,
      isRefreshInFlight: model.isRefreshInFlight,
      onRefresh: model.refresh,
      onOpenHistory: onOpenHistory,
      onOpenJob: onOpenJob,
      isExpanded: $isExpanded)
  }
}

/// The global recovery summary has its own Observation dependency boundary.
/// A history refresh no longer reruns sidebar and device-detail construction.
private struct RuntimeRecoveryBanner: View {
  let model: RuntimeHistoryViewModel
  let onOpenJob: (String) -> Void
  let availableSize: CGSize

  var body: some View {
    GlobalRecoveryBannerView(
      presentation: model.presentation,
      onOpenJob: onOpenJob,
      availableSize: availableSize)
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
  @State private var requestedHistoryJobID: String?
  @State private var preparedContinuation: RuntimeWorkspaceContinuation?
  @State private var forwardedTraceContextID: String?
  @State private var forwardedDiagnosticsContextID: String?
  @SceneStorage("app.shell.selection")
  private var storedSelection = ArkDeckNavigationItem.overview.rawValue

  /// Test-only: see the startup task. Never true in a shipped launch.
  private static let resetsShellSelection = ProcessInfo.processInfo.arguments.contains(
    "--ui-test-reset-shell-selection")
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
    // One container owns both panes in both states. Replacing VSplitView with
    // VStack when collapsed destroys their structural identities, including
    // History's unsaved filters and the inspector's selected Job. A fixed
    // collapsed height leaves no divider travel; expanded constraints retain
    // the native, draggable 220...320pt inspector.
    VSplitView {
      navigationShell
        .frame(minHeight: 320, maxHeight: .infinity)
      jobInspector
        .frame(
          minHeight: isJobInspectorExpanded ? 220 : WorkspaceMetrics.jobInspectorBarHeight,
          idealHeight: isJobInspectorExpanded ? 260 : WorkspaceMetrics.jobInspectorBarHeight,
          maxHeight: isJobInspectorExpanded ? 320 : WorkspaceMetrics.jobInspectorBarHeight)
    }
    .frame(minWidth: 900, minHeight: 600)
    .onAppear {
      applyRequestedNavigation(models.consumeRequestedNavigation())
      AppStartupPerformance.firstWindowAppeared()
    }
    .onChange(of: models.requestedNavigation) { _, request in
      applyRequestedNavigation(request)
      if request != nil {
        _ = models.consumeRequestedNavigation()
      }
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
    // A capture's own bounded reads share the daemon with the device probe.
    // Measured: one probe is ~54ms of daemon time and the daemon answers one
    // request at a time, so a tick landing mid-read makes that read wait.
    .onChange(of: models.uiDumpWorkspace.isCapturing) { _, capturing in
      deviceList.setLiveObservationPaused(capturing)
    }
    .onChange(of: models.deviceWorkspace.isCapturing) { _, capturing in
      deviceList.setLiveObservationPaused(capturing)
    }
    .task(id: deviceList.startupInformationReady) {
      guard deviceList.startupInformationReady else { return }
      // `@SceneStorage` outlives `-ApplePersistenceIgnoreState`, so a UI test
      // inherits whichever workspace the previous run happened to leave
      // selected — a sweep that walks every workspace poisons its own next
      // launch. This restores the declared landing selection so a test can
      // still assert what a first launch shows, instead of asserting whatever
      // the last one ended on.
      if Self.resetsShellSelection { storedSelection = ArkDeckNavigationItem.overview.rawValue }
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

  private var jobInspector: some View {
    RuntimeHistoryJobInspector(
      model: runtimeHistory,
      onOpenHistory: openHistory,
      onOpenJob: openHistoryJob,
      isExpanded: $isJobInspectorExpanded)
  }

  private func applyRequestedNavigation(_ request: ArkDeckNavigationItem?) {
    guard let request else { return }
    storedSelection = ShellSelection.navigation(request).storageValue
  }

  private var navigationShell: some View {
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
          navigationRow(.device)
          navigationRow(.diagnostics)
        }
        Section("app.navigation.section.records") {
          navigationRow(.history)
        }
      }
      .navigationSplitViewColumnWidth(min: 232, ideal: 244, max: 300)
      .navigationTitle("app.shell.title")
    } detail: {
      // The recovery banner needs the detail container's proposed size, not
      // the workspace's ideal size. Measuring the workspace itself creates a
      // feedback loop on macOS 26: NavigationSplitView exposes the resulting
      // unconstrained ideal height through AX, placing otherwise visible
      // controls above the window. GeometryReader is the constraint boundary
      // here; the explicit frame keeps both layout and accessibility geometry
      // tied to the visible detail pane.
      GeometryReader { geometry in
        workspaceWithRecovery(availableSize: geometry.size)
          .frame(
            width: geometry.size.width, height: geometry.size.height,
            alignment: .topLeading)
      }
      .navigationTitle(detailTitle)
      .toolbar { UpdateAttentionToolbarContent(model: autoUpdate) }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func workspaceWithRecovery(availableSize: CGSize) -> some View {
    VStack(spacing: 0) {
      RuntimeRecoveryBanner(
        model: runtimeHistory, onOpenJob: openHistoryJob, availableSize: availableSize)
      if let draft = preparedContinuation, navigationItem(for: draft.workspaceKind) == selectedItem {
        WorkspaceContinuationCard(
          draft: draft,
          currentTargetID: models.overviewCapabilities.presentation.targetID,
          currentBindingRevision: models.overviewCapabilities.presentation.bindingRevision,
          onOpenJob: openHistoryJob,
          onClose: { preparedContinuation = nil })
          .id(draft.id)
      }
      if let context = visibleHistoryContext {
        HistoryWorkspaceContextBanner(context: context) {
          if context.workspaceKind == .device {
            models.deviceWorkspace.dismissHistoryContext()
          }
          models.reopenedHistoryContext = nil
        }
      }
      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func openHistory() {
    requestedHistoryJobID = nil
    storedSelection = ShellSelection.navigation(.history).storageValue
  }

  private func openHistoryJob(_ jobID: String) {
    requestedHistoryJobID = jobID
    storedSelection = ShellSelection.navigation(.history).storageValue
  }

  private var visibleHistoryContext: RuntimeHistoryWorkspaceContext? {
    guard let context = models.reopenedHistoryContext,
      navigationItem(for: context.workspaceKind) == selectedItem
        || (selectedItem == .trace && forwardedTraceContextID == context.id)
        || (selectedItem == .diagnostics && forwardedDiagnosticsContextID == context.id)
    else { return nil }
    return context
  }

  private func navigationItem(for kind: RuntimeWorkspaceKind) -> ArkDeckNavigationItem {
    switch kind {
    case .flash: .flash
    case .viewer: .uiDump
    case .trace: .trace
    case .diagnostics: .diagnostics
    case .debug: .debug
    case .device: .device
    }
  }

  private func openHistoryWorkspace(_ context: RuntimeHistoryWorkspaceContext) {
    forwardedTraceContextID = nil
    forwardedDiagnosticsContextID = nil
    models.reopenedHistoryContext = context
    let item = navigationItem(for: context.workspaceKind)
    storedSelection = ShellSelection.navigation(item).storageValue

    // Let SwiftUI install the destination's observers before an Artifact read
    // can complete (Trace opens its viewer when that read publishes).
    Task { @MainActor in
      await Task.yield()
      guard visibleHistoryContext?.id == context.id else { return }
      switch context.workspaceKind {
      case .flash:
        models.flashWorkspace.focusHistoryContext(context)
      case .viewer:
        models.uiDumpWorkspace.openHistoryContext(context)
      case .trace:
        models.traceWorkspace.openHistoryContext(context)
      case .debug:
        models.debugWorkspace.rememberHistoryContext(context)
      case .device:
        models.deviceWorkspace.openHistoryContext(context)
      case .diagnostics:
        models.diagnosticsWorkspace.openHistoryContext(context)
      }
    }
  }

  /// A capture can contain several channels even when its original workspace
  /// was Viewer or Trace. Read the same immutable record in Diagnostics;
  /// never relabel its source workspace or prepare a new request.
  private func openHistoryDiagnostics(_ context: RuntimeHistoryWorkspaceContext) {
    guard context.operationReference == "capture.diagnostics@1" else { return }
    forwardedTraceContextID = nil
    forwardedDiagnosticsContextID = context.id
    models.reopenedHistoryContext = context
    storedSelection = ShellSelection.navigation(.diagnostics).storageValue
    Task { @MainActor in
      await Task.yield()
      guard selectedItem == .diagnostics, visibleHistoryContext == context else { return }
      models.diagnosticsWorkspace.openHistoryContext(context)
    }
  }

  /// Fans the shared observation out to the workspaces that need routing.
  /// Under the Viewer fixture the fixture's own device stands in, so a
  /// launch that fabricates a capture also fabricates the device it came
  /// from rather than contradicting itself.
  private func publishDeviceObservation(_ observation: DeviceListPresentation) {
    let effective = ViewerUIFixture.deviceObservation() ?? observation
    models.overviewCapabilities.applyDeviceObservation(observation)
    models.uiDumpWorkspace.applyDeviceObservation(
      effective, names: deviceDisplayNames(effective))
    // HDC diagnostics reads the real observation: a fixture Viewer capture
    // must not make the machine claim a device is authorized.
    models.hdcDiagnostics.applyDeviceObservation(observation)
    if case .navigation(.trace) = shellSelection {
      models.traceWorkspace.applyDeviceObservation(
        observation, names: deviceDisplayNames(observation))
    }
    models.deviceWorkspace.publish(deviceObservation: observation)
    models.diagnosticsWorkspace.publish(deviceObservation: observation)
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
      // The record is the page's main content now, so it refreshes with the
      // page rather than only when History is opened.
      runtimeHistory.refresh()
    case .navigation(.history):
      runtimeHistory.refresh()
    case .navigation(.flash):
      models.flashWorkspace.refresh()
    case .navigation(.debug):
      models.debugWorkspace.refresh()
    case .navigation(.uiDump):
      models.uiDumpWorkspace.refresh()
    case .navigation(.trace):
      models.traceWorkspace.applyDeviceObservation(
        deviceList.presentation, names: deviceDisplayNames(deviceList.presentation))
      models.traceWorkspace.refresh()
    case .navigation(.device):
      // Only routing. Device shows a still the person asked for, so arriving
      // on the tab must not quietly photograph the device.
      models.deviceWorkspace.publish(deviceObservation: deviceList.presentation)
    case .navigation(.diagnostics):
      // Routing as well. A diagnostic session is armed deliberately; opening
      // the tab is not that decision.
      models.diagnosticsWorkspace.publish(deviceObservation: deviceList.presentation)
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
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.secondary)
      } icon: {
        Image(systemName: "antenna.radiowaves.left.and.right.slash")
          .foregroundStyle(.secondary)
      }
      .frame(
        maxWidth: .infinity, minHeight: WorkspaceMetrics.navigationRowHeight,
        alignment: .leading
      )
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
        overviewCapabilities: models.overviewCapabilities,
        overviewRemoteServer: models.overviewRemoteServer,
        deviceList: models.deviceList,
        runtimeHistory: runtimeHistory,
        onOpenWorkspace: { item in
          requestedHistoryJobID = nil
          storedSelection = ShellSelection.navigation(item).storageValue
        },
        onOpenJob: openHistoryJob,
        onPrepare: { draft in
          preparedContinuation = draft
          models.reopenedHistoryContext = nil
          storedSelection = ShellSelection.navigation(navigationItem(for: draft.workspaceKind)).storageValue
        })
    case .history:
      RuntimeHistoryView(
        presentation: runtimeHistory.presentation,
        detailsByJobID: runtimeHistory.detailsByJobID,
        loadingDetailJobIDs: runtimeHistory.loadingDetailJobIDs,
        exportStatesByArtifactID: runtimeHistory.exportStatesByArtifactID,
        isRefreshInFlight: runtimeHistory.isRefreshInFlight,
        isLoadOlderInFlight: runtimeHistory.isLoadOlderInFlight,
        savedFilterQuery: runtimeHistory.savedFilterQuery,
        isSavedFilterLoaded: runtimeHistory.isSavedFilterLoaded,
        isSavedFilterMutationInFlight: runtimeHistory.isSavedFilterMutationInFlight,
        savedFilterFailure: runtimeHistory.savedFilterFailure,
        onRefresh: runtimeHistory.refresh,
        onLoadOlder: runtimeHistory.loadOlder,
        onLoadDetail: runtimeHistory.loadDetail,
        onReloadDetail: runtimeHistory.reloadDetail,
        onLoadSavedFilter: runtimeHistory.loadSavedFilter,
        onSaveFilter: runtimeHistory.saveHistoryFilter,
        onDeleteSavedFilter: runtimeHistory.deleteSavedFilter,
        onExportArtifact: runtimeHistory.exportArtifact,
        onOpenWorkspace: openHistoryWorkspace,
        onOpenDiagnostics: openHistoryDiagnostics,
        requestedJobID: $requestedHistoryJobID)
    case .flash:
      FlashWorkspaceView(
        model: models.flashWorkspace,
        runtimeHistory: runtimeHistory.presentation,
        isRuntimeHistoryRefreshing: runtimeHistory.isRefreshInFlight,
        onRefreshRuntimeHistory: runtimeHistory.refresh,
        onOpenHistory: openHistory,
        onOpenJob: openHistoryJob)
    case .debug:
      DebugWorkspaceView(
        model: models.debugWorkspace,
        onOpenHistory: openHistory,
        historyContext: visibleHistoryContext)
    case .uiDump:
      UIDumpWorkspaceView(model: models.uiDumpWorkspace)
    case .trace:
      TraceWorkspaceView(model: models.traceWorkspace)
    case .device:
      DeviceWorkspaceView(
        model: models.deviceWorkspace, recording: models.deviceRecording)
    case .diagnostics:
      DiagnosticsWorkspaceView(model: models.diagnosticsWorkspace) { context in
        forwardedTraceContextID = context.id
        models.reopenedHistoryContext = context
        storedSelection = ShellSelection.navigation(.trace).storageValue
        Task { @MainActor in
          await Task.yield()
          guard selectedItem == .trace, visibleHistoryContext == context else { return }
          models.traceWorkspace.openHistoryContext(context)
        }
      }
    }
  }

  private func navigationRow(_ item: ArkDeckNavigationItem) -> some View {
    NavigationLink(value: ShellSelection.navigation(item)) {
      Label {
        Text(LocalizedStringKey(item.localizationKey))
      } icon: {
        Image(systemName: item.systemImageName)
          // Keep the native symbol weight and aspect ratio. The narrow phone
          // needs the next SF scale to balance the wider workspace symbols.
          .imageScale(item == .device ? .large : .medium)
          .frame(width: 22, height: 22)
      }
      .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
      .contentShape(.rect)
    }
    // NavigationLink is the native selectable element for a split-view
    // sidebar. It keeps the visible label, stable identifier, selected state
    // and activation action together instead of flattening them into an
    // identifier-less AXRow.
    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    .contentShape(.rect)
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
        // Match the eventual pane frame (SettingsRootView) so the window does
        // not open around a spinner and then resize.
        ProgressView()
          .frame(minWidth: 760, idealWidth: 820, minHeight: 560, idealHeight: 620)
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
    VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
      Text("update.privacyDisclosure")
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: WorkspaceMetrics.proseMaxWidth, alignment: .leading)
      GroupBox("update.title") {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
          Toggle(
            "update.automaticChecks",
            isOn: Binding(
              get: { model.automaticChecksEnabled },
              set: { enabled in model.setAutomaticChecksEnabled(enabled) })
          )
          .accessibilityIdentifier("update.automaticChecks")
          Text(LocalizedStringKey(model.statusKey))
            .font(WorkspaceFont.body.weight(.semibold))
            .accessibilityIdentifier("update.status")
          if let releaseNotesSummary = model.releaseNotesSummary {
            Text(releaseNotesSummary)
              .font(WorkspaceFont.secondary)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          HStack(spacing: WorkspaceMetrics.tightGap) {
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
          Text("update.manualInstallDisclosure")
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
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

  @ObservationIgnored private var service: RuntimeUpdateApplicationFacade?
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

  /// The device observation arrives from the App's shared source rather than
  /// being probed here. Authorization is the only device fact this surface
  /// needs, and it is already being observed once for everyone.
  private(set) var deviceObservation = DeviceListPresentation.loading

  func applyDeviceObservation(_ observation: DeviceListPresentation) {
    deviceObservation = observation
  }

  func refresh() {
    guard !isRefreshInFlight else { return }
    isRefreshInFlight = true
    let provider = provider
    let observation = deviceObservation
    Task { [weak self] in
      let next = await provider.refresh(deviceObservation: observation)
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
  /// The target the operator chose. Nil means "resolve it only if there is
  /// nothing to choose between"; the provider refuses rather than picking one
  /// when several are adopted.
  private(set) var selectedTargetID: String?
  private let provider: any OverviewCapabilityApplicationProviding
  private var providerPresentation = OverviewCapabilityMatrixPresentation.loading
  private var deviceObservation = DeviceListPresentation.loading

  init(provider: any OverviewCapabilityApplicationProviding) {
    self.provider = provider
  }

  func select(targetID: String?) {
    guard targetID != selectedTargetID else { return }
    let onlineTargetIDs = Set(
      OverviewOnlineTargetProjection.targets(from: deviceObservation).map(\.id))
    if let targetID {
      guard onlineTargetIDs.contains(targetID) else { return }
    }
    selectedTargetID = targetID
    publishPresentation()
    refresh()
  }

  /// The App already owns one live device observation for every workspace.
  /// Overview consumes that same fact instead of treating durable target
  /// history as an online-device list or adding another HDC probe.
  func applyDeviceObservation(_ observation: DeviceListPresentation) {
    guard observation != deviceObservation else { return }
    deviceObservation = observation
    let onlineTargets = OverviewOnlineTargetProjection.targets(from: observation)
    if let selectedTargetID,
      !onlineTargets.contains(where: { $0.id == selectedTargetID })
    {
      self.selectedTargetID = onlineTargets.count == 1 ? onlineTargets[0].id : nil
    } else if selectedTargetID == nil, onlineTargets.count == 1 {
      selectedTargetID = onlineTargets[0].id
    }
    publishPresentation()
    if let selectedTargetID, providerPresentation.targetID != selectedTargetID {
      refresh()
    }
  }

  func refresh() {
    guard !isRefreshInFlight else { return }
    isRefreshInFlight = true
    let provider = provider
    let requested = selectedTargetID
    Task { [weak self] in
      let next = await provider.refresh(targetID: requested)
      guard let self else { return }
      self.isRefreshInFlight = false
      guard !Task.isCancelled else { return }
      self.providerPresentation = next
      // A target that stopped being adopted must not keep being requested, or
      // every later refresh reports the same stale choice instead of the one
      // device now present.
      if let requested, !next.adoptedTargets.contains(where: { $0.id == requested }) {
        self.selectedTargetID = nil
      }
      self.publishPresentation()
      // A live-device update can arrive while the previous target probe is in
      // flight. The guarded refresh above intentionally did not stack work;
      // now that it is terminal, issue exactly one request for the new scope.
      if let selectedTargetID = self.selectedTargetID,
        selectedTargetID != requested,
        next.targetID != selectedTargetID
      {
        self.refresh()
      }
    }
  }

  private func publishPresentation() {
    presentation = OverviewOnlineTargetProjection.presentation(
      from: providerPresentation,
      devices: deviceObservation,
      preferredTargetID: selectedTargetID)
  }
}

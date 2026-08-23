import ArkDeckWorkflows
import Foundation
import Observation
import SwiftUI

/// Sidebar device rows and the authorization guidance detail.
///
/// Everything here reads the `device.candidates` discovery projection. The
/// App can list candidates and re-read their state; it cannot adopt or
/// restart anything from this surface, and adoption is named as the CLI act
/// it is. Workflows owns the bounded authorization polling and terminal
/// classification; the App renders its published window and result.
@MainActor
@Observable
final class DeviceListViewModel {
  static let maximumDisplayNameLength = 64

  /// One device's bounded trust wait. `polling` carries the App-owned
  /// deadline the countdown renders; `timedOut` is emitted only when the
  /// Workflows provider exhausts its production polling policy.
  enum AuthorizationWait: Equatable {
    case idle
    case polling(connectKey: String, deadline: Date)
    case timedOut(connectKey: String)
    case unavailable(connectKey: String, reason: String)
  }

  private(set) var presentation = DeviceListPresentation.loading
  private(set) var isRefreshing = false
  private(set) var startupInformationReady = false
  private(set) var authorizationWait = AuthorizationWait.idle
  private(set) var customDisplayNames: [String: String]

  private static let displayNamesDefaultsKey = "app.devices.customDisplayNames.v1"
  private let provider: any DeviceListApplicationProviding
  private let displayNamesDefaults: UserDefaults
  private let waitWindow: TimeInterval
  @ObservationIgnored private var waitTask: Task<Void, Never>?
  @ObservationIgnored private var liveTask: Task<Void, Never>?
  @ObservationIgnored private var refreshGeneration: UInt64 = 0

  init(
    provider: any DeviceListApplicationProviding,
    displayNamesDefaults: UserDefaults = .standard,
    resetDisplayNames: Bool = false
  ) {
    self.provider = provider
    self.displayNamesDefaults = displayNamesDefaults
    if resetDisplayNames {
      displayNamesDefaults.removeObject(forKey: Self.displayNamesDefaultsKey)
    }
    customDisplayNames =
      displayNamesDefaults.dictionary(
        forKey: Self.displayNamesDefaultsKey
      )?.compactMapValues { $0 as? String } ?? [:]
    waitWindow = provider.authorizationWaitWindowSeconds
  }

  func refresh() {
    guard let generation = beginRefresh() else { return }
    let provider = provider
    Task { [weak self] in
      let current = await provider.refreshCandidates()
      self?.finishRefresh(current, generation: generation)
    }
  }

  /// The App's one live device observation.
  ///
  /// Every workspace used to ask HDC for routing again on the way in, which
  /// cost a probe per navigation and still showed a device that had been
  /// unplugged since. One poll here answers all of them, and a device that
  /// goes away disappears from every surface at once rather than at each
  /// surface's next visit.
  ///
  /// Polling, not subscription: the daemon's door is request/response and
  /// publishes no device event, so a timer is the honest mechanism. It runs
  /// only while the App is active — a backgrounded window has nobody to show
  /// a state change to, and the probe is not free.
  ///
  /// Ten seconds, measured rather than picked: one `device.candidates` costs
  /// ~54ms of daemon time, and the daemon answers one request at a time, so a
  /// tick that lands mid-read makes the read wait. At four seconds that
  /// collision was frequent enough to show up as several-fold jitter in
  /// unrelated reads; ten keeps an unplug prompt without paying for it
  /// continuously.
  func startLiveObservation(interval: Duration = .seconds(10)) {
    guard liveTask == nil else { return }
    liveTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard let self, !Task.isCancelled else { return }
        // `refresh()` already declines to start while one is in flight, so a
        // slow probe delays the next tick instead of stacking requests.
        self.refresh()
      }
    }
  }

  func stopLiveObservation() {
    liveTask?.cancel()
    liveTask = nil
  }

  /// Suspends polling while a device job is running. The probe and the job's
  /// own reads compete for the same single-threaded daemon, and a device
  /// mid-capture is not going anywhere.
  func setLiveObservationPaused(_ paused: Bool) {
    if paused {
      stopLiveObservation()
    } else {
      startLiveObservation()
    }
  }

  /// The App's startup task awaits this read as its only startup I/O. Manual
  /// refresh keeps the fire-and-forget UI action above; both paths share the
  /// same synchronous admission guard.
  func refreshForStartup() {
    guard let generation = beginRefresh() else { return }
    AppStartupPerformance.beginDeviceDiscovery()
    let provider = provider
    // A task created on the App's main actor does not start until the first
    // window has finished its initial SwiftUI/AppKit work. Start only the
    // Sendable, read-only provider call off that actor, then return to the
    // model for the single publication below.
    Task.detached(priority: .userInitiated) { [weak self] in
      let current = await provider.startupCandidates()
      guard !Task.isCancelled else { return }
      await self?.finishRefresh(current, generation: generation, isStartup: true)
    }
  }

  private func beginRefresh() -> UInt64? {
    guard !isRefreshing else { return nil }
    isRefreshing = true
    refreshGeneration &+= 1
    return refreshGeneration
  }

  private func finishRefresh(
    _ current: DeviceListPresentation,
    generation: UInt64,
    isStartup: Bool = false
  ) {
    guard generation == refreshGeneration else { return }
    isRefreshing = false
    guard !Task.isCancelled else { return }

    // Runtime publishes a timestamped HDC observation and the latest verified
    // model / firmware / transport in one projection. One main-actor
    // assignment makes the complete row visible without a second XPC request
    // or render pass.
    presentation = current
    if isStartup {
      AppStartupPerformance.deviceCandidatesPublished()
      startupInformationReady = true
      AppStartupPerformance.deviceInformationReady()
    }
  }

  func candidate(forConnectKey connectKey: String) -> DeviceCandidatePresentation? {
    presentation.candidates.first { $0.connectKey == connectKey }
  }

  /// A custom name is presentation-only. Runtime identity and target binding
  /// continue to use the candidate's connect key and adopted target ID.
  func displayName(for candidate: DeviceCandidatePresentation) -> String {
    if let targetID = candidate.adoptedTargetID,
      let name = customDisplayNames["target:\(targetID)"]
    {
      return name
    }
    if let name = customDisplayNames["candidate:\(candidate.connectKey)"] {
      return name
    }
    return candidate.adoptedTargetID ?? candidate.connectKey
  }

  func canUseDisplayName(_ rawName: String) -> Bool {
    Self.normalizedDisplayName(rawName) != nil
  }

  @discardableResult
  func renameCandidate(withConnectKey connectKey: String, to rawName: String) -> Bool {
    guard let candidate = candidate(forConnectKey: connectKey),
      let name = Self.normalizedDisplayName(rawName)
    else { return false }

    var next = customDisplayNames
    let candidateKey = "candidate:\(candidate.connectKey)"
    if let targetID = candidate.adoptedTargetID {
      next["target:\(targetID)"] = name
      // A pre-adoption name follows the device into its durable target key;
      // do not leave an address-scoped alias that a later candidate could use.
      next.removeValue(forKey: candidateKey)
    } else {
      next[candidateKey] = name
    }
    customDisplayNames = next
    displayNamesDefaults.set(next, forKey: Self.displayNamesDefaultsKey)
    return true
  }

  private static func normalizedDisplayName(_ rawName: String) -> String? {
    let name = rawName.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    guard !name.isEmpty, name.count <= maximumDisplayNameLength else { return nil }
    return name
  }

  /// Starts (or restarts) the domain-owned bounded wait for one device's trust
  /// prompt. The local deadline only renders the same published window; it
  /// never decides whether the result is timed out, denied, or ready.
  func beginAuthorizationWait(forConnectKey connectKey: String) {
    waitTask?.cancel()
    let deadline = Date().addingTimeInterval(waitWindow)
    authorizationWait = .polling(connectKey: connectKey, deadline: deadline)
    let provider = provider
    waitTask = Task { [weak self] in
      let result = await provider.waitForAuthorization(connectKey: connectKey)
      guard let self, !Task.isCancelled else { return }
      guard case .polling(let waited, _) = self.authorizationWait,
        waited == connectKey
      else { return }
      self.presentation = result.presentation
      switch result.authorization {
      case .ready:
        self.authorizationWait = .idle
      case .timedOut:
        self.authorizationWait = .timedOut(connectKey: connectKey)
      case .cancelled:
        self.authorizationWait = .idle
      case .unavailable(let reason), .denied(let reason), .keyAccessDenied(let reason):
        self.authorizationWait = .unavailable(connectKey: connectKey, reason: reason)
      case .unauthorizedWaitingForTrust:
        self.authorizationWait = .unavailable(
          connectKey: connectKey,
          reason: "Authorization wait ended without a terminal classification")
      }
    }
  }

  /// Leaving the device (or the surface) ends its wait without a verdict:
  /// an abandoned window must not later report itself as closed.
  func cancelAuthorizationWait() {
    waitTask?.cancel()
    waitTask = nil
    authorizationWait = .idle
  }

  func authorizationWaitState(forConnectKey connectKey: String) -> AuthorizationWait {
    switch authorizationWait {
    case .polling(let waited, _) where waited == connectKey: return authorizationWait
    case .timedOut(let waited) where waited == connectKey: return authorizationWait
    case .unavailable(let waited, _) where waited == connectKey: return authorizationWait
    default: return .idle
    }
  }
}

/// One sidebar row: identity line plus a three-way state that is readable
/// without color — ready (adopted, Connected), needs trust (Unauthorized),
/// offline — and the tool's raw state word for anything the vocabulary does
/// not recognize.
struct DeviceSidebarRow: View {
  let candidate: DeviceCandidatePresentation
  let displayName: String
  @State private var startupEvidenceSeconds: TimeInterval?

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 1) {
        Text(displayName)
          .font(.body)
          .lineLimit(1)
          .truncationMode(.middle)
        // The second line names what was actually observed — firmware and
        // transport from the last succeeded observation — and falls back to
        // the connect key when no observation evidence exists yet.
        HStack(spacing: 4) {
          Text(stateText)
            .font(.caption)
            .foregroundStyle(.secondary)
          if let secondary = observedSummary {
            Text(secondary)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
              .accessibilityIdentifier("device.row.observed.\(candidate.connectKey)")
          } else if candidate.isAdopted {
            Text(candidate.connectKey)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
      }
    } icon: {
      Image(systemName: stateSymbol)
        .foregroundStyle(stateColor)
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(
      startupEvidenceSeconds.map { "startup-seconds:\($0)" } ?? stateText)
    .accessibilityIdentifier("device.row.\(candidate.connectKey)")
    .onAppear {
      // End the startup interval at the presentation boundary, not when the
      // model finishes its XPC read. This is the first SwiftUI lifecycle point
      // at which the complete row is actually part of the visible hierarchy.
      startupEvidenceSeconds = AppStartupPerformance.deviceInformationDisplayed()
    }
  }

  private var observedSummary: String? {
    guard let facts = candidate.observedFacts else { return nil }
    let parts = [facts.firmware, facts.transport].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private var stateText: String {
    if candidate.stateObservationHealth == .stale {
      return deviceString("device.state.needsRecheck")
    }
    switch candidate.state {
    case "Connected":
      return deviceString(
        candidate.isAdopted ? "device.state.ready" : "device.state.authorizedUnadopted")
    case "Unauthorized":
      return deviceString("device.state.needsTrust")
    case "Offline":
      return deviceString("device.state.offline")
    default:
      return candidate.state
    }
  }

  private var stateSymbol: String {
    if candidate.stateObservationHealth == .stale { return "arrow.clockwise.circle" }
    switch candidate.state {
    case "Connected": return candidate.isAdopted ? "checkmark.circle.fill" : "checkmark.circle"
    case "Unauthorized": return "exclamationmark.triangle.fill"
    case "Offline": return "circle.dashed"
    default: return "questionmark.circle"
    }
  }

  private var stateColor: Color {
    if candidate.stateObservationHealth == .stale { return .orange }
    switch candidate.state {
    case "Connected": return .green
    case "Unauthorized": return .orange
    case "Offline": return .secondary
    default: return .secondary
    }
  }
}

/// The detail a device row opens. For an unauthorized device this is the
/// three-step trust guidance plus the bounded wait; for a ready one, its
/// adoption facts. It is a detail navigation destination, never an implicit
/// target scope for the workflow workspaces.
struct DeviceDetailView: View {
  let candidate: DeviceCandidatePresentation
  let displayName: String
  let isRefreshing: Bool
  let waitState: DeviceListViewModel.AuthorizationWait
  let onRecheck: () -> Void
  let onBeginWait: () -> Void
  let onOpenOverview: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 24) {
            statusAndActionsSection
              .frame(width: 320, alignment: .topLeading)
            factsSection
              .frame(width: 520, alignment: .topLeading)
          }

          VStack(alignment: .leading, spacing: 24) {
            statusAndActionsSection
            factsSection
          }
        }
      }
      .frame(maxWidth: 960, alignment: .topLeading)
      .padding(20)
    }
    .accessibilityIdentifier("device.detail")
  }

  private var statusAndActionsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      deviceSectionHeader(deviceString("device.detail.statusTitle"))
      stateBlock
      if candidate.state == "Unauthorized" {
        trustSteps
        authorizationWaitBlock
      }
      actionRow
      Text(deviceString("device.detail.recheckNote"))
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if !candidate.isAdopted, candidate.isAuthorized {
        // Adoption is deliberately not an App action: the transport refuses
        // target.adopt. Say who performs it instead of hiding the step.
        Text(deviceString("device.detail.adoptViaCLI"))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("device.detail.adoptViaCLI")
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("device.detail.statusSection")
  }

  private var factsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      deviceSectionHeader(deviceString("device.detail.factsTitle"))
      factsGrid
      if candidate.observedFacts != nil {
        // Provenance, not certification: these fields describe what the last
        // succeeded observation recorded, not the device's state this second.
        Text(deviceString("device.fact.observedProvenance"))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("device.detail.factsSection")
  }

  private func deviceSectionHeader(_ title: String) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title)
        .font(.subheadline.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      Divider()
    }
  }

  @ViewBuilder
  private var stateBlock: some View {
    if candidate.stateObservationHealth == .stale {
      deviceNotice(
        deviceString("device.state.needsRecheck"),
        systemImage: "arrow.clockwise.circle",
        color: .orange,
        identifier: "device.trust.needsRecheck")
    } else {
      switch candidate.state {
      case "Unauthorized":
        deviceNotice(
          deviceString("device.trust.waiting"),
          systemImage: "exclamationmark.triangle.fill",
          color: .orange,
          identifier: "device.trust.waiting")
      case "Offline":
        deviceNotice(
          deviceString("device.trust.offline"),
          systemImage: "circle.dashed",
          color: .secondary,
          identifier: "device.trust.offline")
      case "Connected":
        deviceNotice(
          deviceString(
            candidate.isAdopted ? "device.trust.ready" : "device.trust.authorizedUnadopted"),
          systemImage: "checkmark.circle.fill",
          color: .green,
          identifier: "device.trust.ready")
      default:
        deviceNotice(
          String(localized: .deviceTrustUnknownState(candidate.state)),
          systemImage: "questionmark.circle",
          color: .secondary,
          identifier: "device.trust.unknownState")
      }
    }
  }

  /// The bounded wait's own strip. Polling shows the provider's real deadline;
  /// terminal states come from Workflows and are not inferred from this view.
  @ViewBuilder
  private var authorizationWaitBlock: some View {
    switch waitState {
    case .idle:
      EmptyView()
    case .polling(_, let deadline):
      Label {
        HStack(spacing: 6) {
          Text(deviceString("device.wait.polling"))
          Text(timerInterval: Date.now...deadline, countsDown: true)
            .font(.callout.monospacedDigit().weight(.semibold))
        }
      } icon: {
        ProgressView().controlSize(.small)
      }
      .font(.callout)
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
      .accessibilityIdentifier("device.wait.polling")
    case .timedOut:
      VStack(alignment: .leading, spacing: 10) {
        deviceNotice(
          deviceString("device.wait.timedOut"),
          systemImage: "exclamationmark.triangle.fill",
          color: .orange,
          identifier: "device.wait.timedOut")
        // Restarting the shared HDC server is never the default fix: it is a
        // separate, explicitly confirmed flow that lives on Overview, and it
        // affects DevEco and every connected device. This button only leads
        // there; nothing restarts from this page.
        Button(deviceString("device.wait.openOverviewRecovery"), action: onOpenOverview)
          .accessibilityIdentifier("device.wait.openOverviewRecovery")
      }
    case .unavailable(_, let reason):
      deviceNotice(
        String(localized: .deviceWaitUnavailable(reason)),
        systemImage: "xmark.octagon.fill",
        color: .red,
        identifier: "device.wait.unavailable")
    }
  }

  @ViewBuilder
  private var actionRow: some View {
    HStack(spacing: 10) {
      if candidate.state == "Unauthorized" {
        Button(
          {
            if case .timedOut = waitState {
              return deviceString("device.action.retryWait")
            }
            if case .unavailable = waitState {
              return deviceString("device.action.retryWait")
            }
            return deviceString("device.action.beginWait")
          }(),
          action: onBeginWait
        )
        .buttonStyle(.borderedProminent)
        .disabled(isPolling)
        .accessibilityIdentifier("device.action.beginWait")
      }
      Button(deviceString("device.action.recheck"), action: onRecheck)
        .disabled(isRefreshing || isPolling)
        .accessibilityIdentifier("device.action.recheck")
      if isRefreshing {
        ProgressView().controlSize(.small)
      }
    }
  }

  private var isPolling: Bool {
    if case .polling = waitState { return true }
    return false
  }

  private var trustSteps: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(deviceString("device.trust.stepsTitle"))
        .font(.subheadline.weight(.semibold))
      trustStep(1, "device.trust.step1")
      trustStep(2, "device.trust.step2")
      trustStep(3, "device.trust.step3")
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("device.trust.steps")
  }

  private func trustStep(_ number: Int, _ key: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("\(number).")
        .font(.callout.monospacedDigit().weight(.semibold))
        .foregroundStyle(.secondary)
      Text(deviceString(key))
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var factsGrid: some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
      GridRow(alignment: .firstTextBaseline) {
        Text(deviceString("device.fact.connectKey")).foregroundStyle(.secondary)
        Text(candidate.connectKey)
          .font(.body.monospaced())
          .textSelection(.enabled)
      }
      GridRow(alignment: .firstTextBaseline) {
        Text(deviceString("device.fact.state")).foregroundStyle(.secondary)
        Text(candidate.state)
          .font(.body.monospaced())
          .accessibilityIdentifier("device.fact.state")
      }
      if let stateObservedAtUTC = candidate.stateObservedAtUTC {
        GridRow(alignment: .firstTextBaseline) {
          Text(deviceString("device.fact.stateObservedAt")).foregroundStyle(.secondary)
          Text(stateObservedAtUTC).font(.body.monospaced())
        }
      }
      if let targetID = candidate.adoptedTargetID {
        GridRow(alignment: .firstTextBaseline) {
          Text(deviceString("device.fact.target")).foregroundStyle(.secondary)
          Text(targetID)
            .font(.body.monospaced())
            .textSelection(.enabled)
        }
      }
      if let revision = candidate.bindingRevision {
        GridRow(alignment: .firstTextBaseline) {
          Text(deviceString("device.fact.bindingRevision")).foregroundStyle(.secondary)
          Text(String(revision))
            .font(.body.monospacedDigit())
        }
      }
      if let facts = candidate.observedFacts {
        if let model = facts.model {
          GridRow(alignment: .firstTextBaseline) {
            Text(deviceString("device.fact.model")).foregroundStyle(.secondary)
            Text(model).font(.body.monospaced()).textSelection(.enabled)
          }
        }
        if let firmware = facts.firmware {
          GridRow(alignment: .firstTextBaseline) {
            Text(deviceString("device.fact.firmware")).foregroundStyle(.secondary)
            Text(firmware)
              .font(.body.monospaced())
              .textSelection(.enabled)
              .accessibilityIdentifier("device.fact.firmware")
          }
        }
        if let transport = facts.transport {
          GridRow(alignment: .firstTextBaseline) {
            Text(deviceString("device.fact.transport")).foregroundStyle(.secondary)
            Text(transport).font(.body.monospaced())
          }
        }
        if let confirmedAt = facts.confirmedAtUTC {
          GridRow(alignment: .firstTextBaseline) {
            Text(deviceString("device.fact.observedAt")).foregroundStyle(.secondary)
            Text(confirmedAt).font(.body.monospaced())
          }
        }
      }
    }
  }
}

func deviceNotice(
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

func deviceString(_ key: String) -> String {
  String(localized: String.LocalizationValue(key))
}

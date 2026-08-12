import ArkDeckWorkflows
import Combine
import Foundation
import SwiftUI

/// Sidebar device rows and the authorization guidance detail.
///
/// Everything here reads the `device.candidates` discovery projection. The
/// App can list candidates and re-read their state; it cannot adopt or
/// restart anything from this surface, and adoption is named as the CLI act
/// it is. Workflows owns the bounded authorization polling and terminal
/// classification; the App renders its published window and result.
@MainActor
final class DeviceListViewModel: ObservableObject {
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

  @Published private(set) var presentation = DeviceListPresentation.loading
  @Published private(set) var isRefreshing = false
  @Published private(set) var authorizationWait = AuthorizationWait.idle
  @Published private(set) var customDisplayNames: [String: String]

  private static let displayNamesDefaultsKey = "app.devices.customDisplayNames.v1"
  private let provider: any DeviceListApplicationProviding
  private let displayNamesDefaults: UserDefaults
  private let waitWindow: TimeInterval
  private var waitTask: Task<Void, Never>?
  private var refreshGeneration: UInt64 = 0

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
    customDisplayNames = displayNamesDefaults.dictionary(
      forKey: Self.displayNamesDefaultsKey
    )?.compactMapValues { $0 as? String } ?? [:]
    waitWindow = provider.authorizationWaitWindowSeconds
  }

  func refresh() {
    guard let generation = beginRefresh() else { return }
    Task { [weak self] in
      await self?.finishRefresh(generation: generation)
    }
  }

  /// The App's startup task awaits this read before it launches unrelated
  /// workspace probes. Manual refresh keeps the fire-and-forget UI action
  /// above; both paths share the same synchronous admission guard.
  func refreshForStartup() async {
    guard let generation = beginRefresh() else { return }
    await finishRefresh(generation: generation)
  }

  private func beginRefresh() -> UInt64? {
    guard !isRefreshing else { return nil }
    isRefreshing = true
    refreshGeneration &+= 1
    return refreshGeneration
  }

  private func finishRefresh(generation: UInt64) async {
    let base = await provider.refreshCandidates()
    guard generation == refreshGeneration else { return }
    isRefreshing = false
    guard !Task.isCancelled else { return }

    // Candidate identity and trust are the startup-critical result. Publish
    // them immediately; model / firmware / transport are historical
    // decoration and must never hold the sidebar behind Job history reads.
    presentation = base

    let provider = provider
    Task { [weak self] in
      let enriched = await provider.enrichCandidates(base)
      guard let self, !Task.isCancelled, generation == self.refreshGeneration else { return }
      self.presentation = enriched
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
    .accessibilityValue(stateText)
    .accessibilityIdentifier("device.row.\(candidate.connectKey)")
  }

  private var observedSummary: String? {
    guard let facts = candidate.observedFacts else { return nil }
    let parts = [facts.firmware, facts.transport].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private var stateText: String {
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
    switch candidate.state {
    case "Connected": return candidate.isAdopted ? "checkmark.circle.fill" : "checkmark.circle"
    case "Unauthorized": return "exclamationmark.triangle.fill"
    case "Offline": return "circle.dashed"
    default: return "questionmark.circle"
    }
  }

  private var stateColor: Color {
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
/// adoption facts. It is not a navigation destination — the sidebar's
/// workflow items stay unselected while a device row is chosen.
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
        Text(
          String(
            format: deviceString("device.detail.title"),
            displayName)
        )
        .font(.title3.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("device.detail.title")

        GroupBox {
          VStack(alignment: .leading, spacing: 14) {
            stateBlock
            if candidate.state == "Unauthorized" {
              trustSteps
              authorizationWaitBlock
            }
            factsGrid
            if candidate.observedFacts != nil {
              // Provenance, not certification: these fields describe what the
              // last succeeded observation recorded, not the device's state
              // this second.
              Text(deviceString("device.fact.observedProvenance"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            actionRow
            Text(deviceString("device.detail.recheckNote"))
              .font(.footnote)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 4)
        }
        .frame(maxWidth: 640, alignment: .leading)

        if !candidate.isAdopted, candidate.isAuthorized {
          // Adoption is deliberately not an App action: the transport refuses
          // target.adopt. Say who performs it instead of hiding the step.
          Text(deviceString("device.detail.adoptViaCLI"))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 640, alignment: .leading)
            .accessibilityIdentifier("device.detail.adoptViaCLI")
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(20)
    }
  }

  @ViewBuilder
  private var stateBlock: some View {
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
        String(format: deviceString("device.trust.unknownState"), candidate.state),
        systemImage: "questionmark.circle",
        color: .secondary,
        identifier: "device.trust.unknownState")
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
        String(format: deviceString("device.wait.unavailable"), reason),
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

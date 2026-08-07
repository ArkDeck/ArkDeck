import ArkDeckWorkflows
import Combine
import SwiftUI

/// Sidebar device rows and the authorization guidance detail.
///
/// Everything here reads the `device.candidates` discovery projection. The
/// App can list candidates and re-read their state; it cannot adopt, poll on
/// a timer it does not have, or restart anything from this surface — retry is
/// a plain re-read, and adoption is named as the CLI act it is.
@MainActor
final class DeviceListViewModel: ObservableObject {
  @Published private(set) var presentation = DeviceListPresentation.loading
  @Published private(set) var isRefreshing = false

  private let provider: any DeviceListApplicationProviding

  init(provider: any DeviceListApplicationProviding) {
    self.provider = provider
  }

  func refresh() {
    guard !isRefreshing else { return }
    isRefreshing = true
    let provider = provider
    Task { [weak self] in
      let next = await provider.refreshCandidates()
      guard let self else { return }
      defer { self.isRefreshing = false }
      guard !Task.isCancelled else { return }
      self.presentation = next
    }
  }

  func candidate(forConnectKey connectKey: String) -> DeviceCandidatePresentation? {
    presentation.candidates.first { $0.connectKey == connectKey }
  }
}

/// One sidebar row: identity line plus a three-way state that is readable
/// without color — ready (adopted, Connected), needs trust (Unauthorized),
/// offline — and the tool's raw state word for anything the vocabulary does
/// not recognize.
struct DeviceSidebarRow: View {
  let candidate: DeviceCandidatePresentation

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 1) {
        Text(candidate.adoptedTargetID ?? candidate.connectKey)
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
/// three-step trust guidance; for a ready one, its adoption facts. It is not
/// a navigation destination — the sidebar's workflow items stay unselected
/// while a device row is chosen.
struct DeviceDetailView: View {
  let candidate: DeviceCandidatePresentation
  let isRefreshing: Bool
  let onRecheck: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text(
          String(
            format: deviceString("device.detail.title"),
            candidate.adoptedTargetID ?? candidate.connectKey)
        )
        .font(.title3.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("device.detail.title")

        GroupBox {
          VStack(alignment: .leading, spacing: 14) {
            stateBlock
            if candidate.state == "Unauthorized" {
              trustSteps
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
            HStack(spacing: 10) {
              Button(deviceString("device.action.recheck"), action: onRecheck)
                .disabled(isRefreshing)
                .accessibilityIdentifier("device.action.recheck")
              if isRefreshing {
                ProgressView().controlSize(.small)
              }
            }
            // Retry is a plain, zero-cost re-read. There is no countdown here
            // because the App holds no bounded-wait deadline to count.
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

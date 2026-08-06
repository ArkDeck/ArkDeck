import ArkDeckWorkflows
import SwiftUI

/// Records workspace: the Runtime job history the daemon reports, read-only.
///
/// This view can render a job and nothing else. It holds no client, no socket
/// and no operation reference it could submit, and the surface it consumes
/// exposes a single read — so there is no control here that could queue,
/// cancel or retry anything, by construction rather than by omission.
struct RuntimeHistoryView: View {
  let presentation: RuntimeHistoryPresentation
  let isRefreshInFlight: Bool
  let onRefresh: (() -> Void)?
  @State private var selectedJobID: RuntimeJobSummaryPresentation.ID?

  private var selectedJob: RuntimeJobSummaryPresentation? {
    presentation.jobs.first { $0.id == selectedJobID }
  }

  var body: some View {
    Group {
      switch presentation.availability {
      case .unavailable(let reason):
        // A history that could not be read must never look like a history
        // that is empty, so the reason replaces the table rather than
        // sitting above an empty one.
        ContentUnavailableView {
          Label {
            Text("history.unavailable.title")
              .accessibilityIdentifier("history.unavailable.title")
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
        } description: {
          Text(reason)
            .accessibilityIdentifier("history.unavailable.reason")
            .multilineTextAlignment(.center)
        }
      case .available:
        available
      }
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        if let onRefresh {
          Button("history.action.refresh", action: onRefresh)
            .accessibilityIdentifier("history.refresh")
            .disabled(isRefreshInFlight)
        }
      }
    }
  }

  @ViewBuilder
  private var available: some View {
    if presentation.jobs.isEmpty {
      ContentUnavailableView {
        Label {
          Text("history.empty.title").accessibilityIdentifier("history.empty.title")
        } icon: {
          Image(systemName: "clock")
        }
      } description: {
        Text("history.empty.description")
          .accessibilityIdentifier("history.empty.description")
      }
    } else {
      // The split has to be given the workspace's measured size. Left to size
      // itself it takes its content's ideal instead: a two-row table and an
      // empty detail placeholder produced an 83pt-tall, 1205pt-wide split
      // centred in a 648×600 workspace — the table's rows drew outside its own
      // scroll view, where a click reaches nothing, and the detail pane hung
      // off the right of the window. Neither `maxWidth: .infinity` nor an
      // explicit `idealWidth` moved it; only a measured width does.
      GeometryReader { workspace in
        HSplitView {
          // Minimums, not ideals: an ideal width is ignored here, and the two
          // minimums have to fit the narrowest workspace the shell can make —
          // a 900pt window minus a 300pt sidebar.
          jobTable
            .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
          detail
            .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: workspace.size.width, height: workspace.size.height)
      }
    }
  }

  private var jobTable: some View {
    VStack(alignment: .leading, spacing: 0) {
      Table(presentation.jobs, selection: $selectedJobID) {
        TableColumn("history.column.job") { job in
          Text(job.id).font(.body.monospaced())
        }
        TableColumn("history.column.operation") { job in
          Text(job.operationReference).font(.body.monospaced())
        }
        TableColumn("history.column.state") { job in
          Label {
            Text(job.state)
          } icon: {
            Image(systemName: job.needsAttention ? "exclamationmark.triangle" : "checkmark.circle")
              .foregroundStyle(job.needsAttention ? Color.orange : Color.secondary)
          }
          .accessibilityIdentifier("history.row.state.\(job.id)")
        }
      }
      .accessibilityIdentifier("history.table")
      Divider()
      Text("history.readOnlyNote")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("history.readOnlyNote")
        .padding(12)
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let job = selectedJob {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text("history.detail.title")
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
          Divider()
          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            row("history.detail.job", job.id, id: "history.detail.job", monospaced: true)
            row(
              "history.detail.operation", job.operationReference,
              id: "history.detail.operation", monospaced: true)
            row("history.detail.target", job.targetID, id: "history.detail.target", monospaced: true)
            row("history.detail.state", job.state, id: "history.detail.state")
          }
          // An unknown outcome is the one condition a reader must not mistake
          // for a finished job, so it is stated rather than implied by state.
          if job.outcomeUnknown {
            attention("history.detail.outcomeUnknown", id: "history.detail.outcomeUnknown")
          }
          if job.waitingForHuman {
            attention("history.detail.waitingForHuman", id: "history.detail.waitingForHuman")
          }
          if job.outstandingResidueCount > 0 {
            Text(
              String(
                format: String(localized: "history.detail.residue"), job.outstandingResidueCount)
            )
            .font(.callout)
            .accessibilityIdentifier("history.detail.residue")
          }
          if !job.timeline.isEmpty {
            Text("history.detail.timeline")
              .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
              ForEach(Array(job.timeline.enumerated()), id: \.offset) { _, entry in
                Text(entry).font(.callout.monospaced())
              }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(Text(job.timeline.joined(separator: " | ")))
            .accessibilityIdentifier("history.detail.timeline.entries")
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
      }
    } else {
      ContentUnavailableView {
        Text("history.detail.select").accessibilityIdentifier("history.detail.select")
      }
    }
  }

  private func attention(_ titleKey: String, id: String) -> some View {
    Label {
      Text(LocalizedStringKey(titleKey)).accessibilityIdentifier(id)
    } icon: {
      Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
    }
    .font(.callout)
  }

  private func row(
    _ titleKey: String, _ value: String, id: String, monospaced: Bool = false
  ) -> some View {
    GridRow(alignment: .firstTextBaseline) {
      Text(LocalizedStringKey(titleKey))
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.leading)
      Text(value)
        .font(monospaced ? .body.monospaced() : .body)
        .accessibilityIdentifier(id)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// Bridges the App presentation to the domain-owned Runtime reader. Like the
/// HDC model it has no transport of its own and no way to submit.
@MainActor
final class RuntimeHistoryViewModel: ObservableObject {
  @Published private(set) var presentation: RuntimeHistoryPresentation = .loading
  @Published private(set) var isRefreshInFlight = false
  private let provider: any RuntimeHistoryApplicationProviding

  init(provider: any RuntimeHistoryApplicationProviding) {
    self.provider = provider
  }

  func refresh() {
    guard !isRefreshInFlight else { return }
    isRefreshInFlight = true
    let provider = provider
    Task { [weak self] in
      let next = await provider.refreshHistory()
      guard let self else { return }
      defer { self.isRefreshInFlight = false }
      guard !Task.isCancelled else { return }
      self.presentation = next
    }
  }
}

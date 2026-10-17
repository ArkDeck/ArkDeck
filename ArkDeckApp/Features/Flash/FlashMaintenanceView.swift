import ArkDeckClientKit
import SwiftUI

struct FlashMaintenanceView: View {
  let model: FlashWorkspaceViewModel
  let jobs: [RuntimeJobSummaryPresentation]
  @State private var sourceJobID = ""
  @State private var action: Task<Void, Never>?

  private var sources: [RuntimeJobSummaryPresentation] {
    jobs.filter { $0.targetID == model.selectedTargetID &&
      ["flash.full-restore@1", "flash.dayu200", "flash.restore-boot-loop@1"].contains($0.operationReference) }
      .sorted { ($0.activityDate ?? .distantPast) > ($1.activityDate ?? .distantPast) }
  }
  private var resultJob: String? {
    jobs.sorted { ($0.activityDate ?? .distantPast) > ($1.activityDate ?? .distantPast) }.first { $0.targetID == model.selectedTargetID &&
      ["flash.verify@1", "flash.restore-boot-loop@1"].contains($0.operationReference) }?.id
  }
  var body: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
      Text(flashText("flash.maintenance.title")).font(.headline).accessibilityAddTraits(.isHeader)
      Text(flashText("flash.maintenance.detail")).foregroundStyle(.secondary)
      if sources.isEmpty {
        Text(flashText("flash.maintenance.noSource"))
      } else {
        Picker(flashText("flash.maintenance.source"), selection: $sourceJobID) {
          ForEach(sources) { job in Text(job.id).tag(job.id) }
        }
        .accessibilityIdentifier("flash.maintenance.source")
        HStack {
          Button(flashText("flash.maintenance.verify")) { start(restoring: false) }
            .accessibilityIdentifier("flash.maintenance.verify")
          Button(flashText("flash.maintenance.restore")) { start(restoring: true) }
            .disabled(model.selectedArchiveURL == nil)
            .accessibilityIdentifier("flash.maintenance.restore")
        }
        .disabled(model.isMaintaining || model.isSubmitting || !sources.contains { $0.id == sourceJobID })
        if model.selectedArchiveURL == nil { Text(flashText("flash.maintenance.archive")).foregroundStyle(.secondary) }
      }
      if model.isMaintaining { ProgressView(flashText("flash.maintenance.busy")) }
      if model.maintenanceTargetID == model.selectedTargetID, let failure = model.maintenanceFailure {
        Text(failure).textSelection(.enabled).accessibilityIdentifier("flash.maintenance.failure")
      }
      if model.maintenanceTargetID == model.selectedTargetID, let status = model.maintenanceStatus {
        Text(status.jobID).font(.caption.monospaced()).textSelection(.enabled)
        if let result = status.maintenanceResult { FlashMaintenanceResultView(result: result) }
        else { Text(status.state).textSelection(.enabled) }
      }
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    .task(id: sources.map(\.id)) {
      if !sources.contains(where: { $0.id == sourceJobID }) { sourceJobID = sources.first?.id ?? "" }
    }
    .task(id: resultJob) {
      if let resultJob { await model.readMaintenance(jobID: resultJob) }
    }
  }
  private func start(restoring: Bool) {
    guard action == nil else { return }
    let source = sourceJobID
    action = Task {
      await model.runMaintenance(sourceJobID: source, restoring: restoring, budgetMs: 600_000)
      action = nil
    }
  }
}

import ArkDeckWorkflows
import Observation
import SwiftUI

struct AutomationWorkspaceView: View {
  var model: AutomationWorkspaceViewModel
  @State private var selectedTaskID: AutomationTaskPresentation.ID?

  private var selectedTask: AutomationTaskPresentation? {
    if let selectedTaskID,
      let task = model.presentation.tasks.first(where: { $0.id == selectedTaskID })
    {
      return task
    }
    return model.presentation.tasks.first
  }

  var body: some View {
    Group {
      switch model.presentation.availability {
      case .unavailable(let reason):
        ContentUnavailableView {
          Label("automation.unavailable.title", systemImage: "gearshape.2.fill")
        } description: {
          VStack(spacing: 8) {
            Text(reason).font(.callout.monospaced()).textSelection(.enabled)
            Text("automation.unavailable.guidance")
          }
        }
        .accessibilityIdentifier("automation.unavailable")
      case .available:
        if model.presentation.tasks.isEmpty {
          ContentUnavailableView(
            "automation.empty.title",
            systemImage: "checklist.unchecked",
            description: Text("automation.empty.description")
          )
          .accessibilityIdentifier("automation.empty")
        } else {
          HSplitView {
            taskList
              .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)
            detail
              .frame(minWidth: 420, maxWidth: .infinity)
          }
        }
      }
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("automation.action.refresh") { model.refresh() }
          .disabled(model.isRefreshing || model.isPerformingAction)
          .accessibilityIdentifier("automation.refresh")
      }
    }
    .onChange(of: model.presentation.tasks.map(\.id), initial: true) { _, ids in
      if let selectedTaskID, ids.contains(selectedTaskID) { return }
      selectedTaskID = ids.first
    }
  }

  private var taskList: some View {
    List(model.presentation.tasks, selection: $selectedTaskID) { task in
      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline) {
          lifecycleLabel(task.lifecycle)
          Spacer(minLength: 8)
          Text("#\(task.activeRound)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        Text(task.id)
          .font(.callout.monospaced().weight(.semibold))
          .lineLimit(1)
        Text(task.goal)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .padding(.vertical, 4)
      .tag(task.id)
      .accessibilityIdentifier("automation.task.\(task.id)")
    }
    .accessibilityIdentifier("automation.taskList")
  }

  @ViewBuilder
  private var detail: some View {
    if let task = selectedTask {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            lifecycleLabel(task.lifecycle)
            Text(task.stage)
              .font(.callout.monospaced())
              .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(task.type).font(.caption.monospaced()).foregroundStyle(.secondary)
          }

          Text(task.goal)
            .font(.title3.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)

          GroupBox("automation.facts.title") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
              factRow("automation.fact.task", task.id)
              factRow("automation.fact.target", task.targetID)
              factRow("automation.fact.round", String(task.activeRound))
              factRow("automation.fact.version", String(task.version))
              factRow("automation.fact.updated", task.updatedAtUTC)
              if let activeJobID = task.activeJobID {
                factRow("automation.fact.activeJob", activeJobID)
              }
              if let waitReason = task.waitReason {
                factRow("automation.fact.waitReason", waitReason)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
          }

          GroupBox("automation.operations.title") {
            if task.allowedOperations.isEmpty {
              Text("automation.operations.empty").foregroundStyle(.secondary)
            } else {
              Text(task.allowedOperations.joined(separator: " · "))
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
          }

          HStack(spacing: 10) {
            Button("automation.action.reconcile") {
              model.perform(.reconcile, taskID: task.id)
            }
            .buttonStyle(.borderedProminent)
            .disabled(task.isTerminal || model.isPerformingAction)
            .accessibilityIdentifier("automation.reconcile")

            Button("automation.action.pause") {
              model.perform(.pause, taskID: task.id)
            }
            .disabled(
              task.isTerminal || task.lifecycle == "waiting"
                || task.lifecycle == "humanRequired" || model.isPerformingAction
            )
            .accessibilityIdentifier("automation.pause")

            Button("automation.action.cancel", role: .destructive) {
              model.perform(.cancel, taskID: task.id)
            }
            .disabled(task.isTerminal || model.isPerformingAction)
            .accessibilityIdentifier("automation.cancel")

            if model.isPerformingAction {
              ProgressView().controlSize(.small)
                .accessibilityLabel(Text("automation.action.inProgress"))
            }
          }

          Label("automation.boundary", systemImage: "lock.shield")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          if let failure = model.actionFailure {
            Label(failure, systemImage: "xmark.octagon.fill")
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("automation.actionFailure")
          }
        }
        .frame(maxWidth: 760, alignment: .topLeading)
        .padding(20)
      }
      .accessibilityIdentifier("automation.detail")
    } else {
      ContentUnavailableView("automation.select.title", systemImage: "sidebar.right")
    }
  }

  private func factRow(_ key: LocalizedStringKey, _ value: String) -> some View {
    GridRow(alignment: .firstTextBaseline) {
      Text(key).foregroundStyle(.secondary)
      Text(value)
        .font(.body.monospaced())
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func lifecycleLabel(_ lifecycle: String) -> some View {
    Label {
      Text(lifecycle)
    } icon: {
      Image(systemName: lifecycleSymbol(lifecycle)).accessibilityHidden(true)
    }
    .font(.callout.weight(.semibold))
    .foregroundStyle(lifecycleColor(lifecycle))
  }

  private func lifecycleSymbol(_ lifecycle: String) -> String {
    switch lifecycle {
    case "succeeded": "checkmark.circle.fill"
    case "failed": "xmark.octagon.fill"
    case "cancelled": "stop.circle.fill"
    case "humanRequired": "person.crop.circle.badge.exclamationmark"
    case "waiting": "pause.circle.fill"
    default: "gearshape.2.fill"
    }
  }

  private func lifecycleColor(_ lifecycle: String) -> Color {
    switch lifecycle {
    case "succeeded": .green
    case "failed": .red
    case "cancelled": .secondary
    case "humanRequired", "waiting": .orange
    default: .blue
    }
  }
}

@MainActor
@Observable
final class AutomationWorkspaceViewModel {
  private(set) var presentation = AutomationPresentation.loading
  private(set) var isRefreshing = false
  private(set) var isPerformingAction = false
  private(set) var actionFailure: String?

  private let provider: any AutomationApplicationProviding

  init(provider: any AutomationApplicationProviding) {
    self.provider = provider
  }

  func refresh() {
    guard !isRefreshing else { return }
    isRefreshing = true
    let provider = provider
    Task { [weak self] in
      let next = await provider.refresh()
      guard let self, !Task.isCancelled else { return }
      self.presentation = next
      self.isRefreshing = false
    }
  }

  func perform(_ action: AutomationTaskAction, taskID: String) {
    guard !isPerformingAction else { return }
    isPerformingAction = true
    actionFailure = nil
    let provider = provider
    Task { [weak self] in
      let result = await provider.perform(action, taskID: taskID)
      guard let self, !Task.isCancelled else { return }
      self.isPerformingAction = false
      switch result {
      case .completed(let task):
        var tasks = self.presentation.tasks.filter { $0.id != task.id }
        tasks.append(task)
        tasks.sort { ($0.updatedAtUTC, $0.id) > ($1.updatedAtUTC, $1.id) }
        self.presentation = AutomationPresentation(
          availability: .available, tasks: tasks)
      case .failed(let reason):
        self.actionFailure = reason
      }
    }
  }
}

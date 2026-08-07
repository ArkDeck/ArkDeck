import ArkDeckWorkflows
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum DebugWorkspaceTab: String, CaseIterable, Hashable {
  case logs
  case apps
  case network
  case commands

  var title: String {
    DebugL10n.text("debug.tab.\(rawValue)")
  }

  var symbol: String {
    switch self {
    case .logs: "text.alignleft"
    case .apps: "app.badge"
    case .network: "point.3.connected.trianglepath.dotted"
    case .commands: "terminal"
    }
  }
}

/// The complete Debug workspace. It projects Runtime facts and typed Catalog
/// contracts, but deliberately owns no submit, import, or command transport.
struct DebugWorkspaceView: View {
  @ObservedObject var model: DebugWorkspaceViewModel
  let onOpenHistory: () -> Void

  @SceneStorage("debug.workspace.tab")
  private var storedTab = DebugWorkspaceTab.logs.rawValue
  @State private var selectedTargetID: String?

  private var selectedTab: DebugWorkspaceTab {
    DebugWorkspaceTab(rawValue: storedTab) ?? .logs
  }

  private var selectedTarget: DebugTargetPresentation? {
    model.workspace.targets.first { $0.id == selectedTargetID }
  }

  private var activeJobs: [DebugJobPresentation] {
    model.workspace.jobs.filter(\.isActive)
  }

  var body: some View {
    VStack(spacing: 0) {
      workspaceHeader
      Divider()
      tabPicker
      Divider()
      selectedWorkspace
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if !activeJobs.isEmpty {
          Button(action: onOpenHistory) {
            Label(
              DebugL10n.format("debug.jobs.active", activeJobs.count),
              systemImage: "bolt.horizontal.circle")
          }
          .accessibilityIdentifier("debug.activeJobs")
        }
        Button(action: model.refresh) {
          Label(DebugL10n.text("debug.action.refresh"), systemImage: "arrow.clockwise")
        }
        .disabled(model.isRefreshing)
        .accessibilityIdentifier("debug.refresh")
      }
    }
    .onAppear(perform: reconcileTargetSelection)
    .onChange(of: model.workspace.targets) { _, _ in reconcileTargetSelection() }
  }

  private var workspaceHeader: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 16) {
        titleAndScope
        Spacer(minLength: 12)
        targetPicker
        operationBadges
      }
      VStack(alignment: .leading, spacing: 12) {
        titleAndScope
        HStack(spacing: 12) {
          targetPicker
          Spacer(minLength: 8)
          operationBadges
        }
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
  }

  // The page title lives in the window toolbar; repeating it here would give
  // the detail two perceivable main headings. Only the scope line stays.
  private var titleAndScope: some View {
    Text(DebugL10n.text("debug.scope"))
      .font(.footnote)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("debug.scope")
  }

  private var targetPicker: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(DebugL10n.text("debug.target.label"))
        .font(.caption)
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
        Text(
          DebugL10n.format(
            "debug.target.binding", selectedTarget.bindingRevision, selectedTarget.toolVersion)
        )
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      } else if let failure = model.workspace.targetLoadFailure {
        Text(failure)
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(2)
      }
    }
  }

  private var operationBadges: some View {
    VStack(alignment: .trailing, spacing: 6) {
      operationBadge(
        reference: DebugApplicationFacade.captureDiagnosticsReference,
        shortTitle: DebugL10n.text("debug.operation.capture"))
      operationBadge(
        reference: DebugApplicationFacade.debugHAPReference,
        shortTitle: DebugL10n.text("debug.operation.hap"))
    }
  }

  private func operationBadge(reference: String, shortTitle: String) -> some View {
    let operation = model.workspace.operation(reference)
    return HStack(spacing: 6) {
      Image(systemName: operationStatusSymbol(operation?.availability))
      Text(shortTitle)
      Text(reference)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
    }
    .font(.caption.weight(.medium))
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(.quaternary, in: Capsule())
    .accessibilityElement(children: .combine)
  }

  private var tabPicker: some View {
    Picker(DebugL10n.text("debug.tabs.label"), selection: $storedTab) {
      ForEach(DebugWorkspaceTab.allCases, id: \.self) { tab in
        Label(tab.title, systemImage: tab.symbol)
          .accessibilityIdentifier("debug.tab.\(tab.rawValue)")
          .tag(tab.rawValue)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .frame(maxWidth: 620)
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
    .accessibilityIdentifier("debug.tabs")
  }

  @ViewBuilder
  private var selectedWorkspace: some View {
    switch selectedTab {
    case .logs:
      DebugLogsWorkspace(
        operation: model.workspace.operation(
          DebugApplicationFacade.captureDiagnosticsReference),
        target: selectedTarget,
        relatedJobs: model.workspace.jobs.filter {
          $0.operationReference == DebugApplicationFacade.captureDiagnosticsReference
        })
    case .apps:
      DebugAppsWorkspace(
        operation: model.workspace.operation(DebugApplicationFacade.debugHAPReference),
        target: selectedTarget,
        relatedJobs: model.workspace.jobs.filter {
          $0.operationReference == DebugApplicationFacade.debugHAPReference
        })
    case .network:
      DebugNetworkWorkspace(target: selectedTarget)
    case .commands:
      DebugCommandsWorkspace(target: selectedTarget)
    }
  }

  private func operationStatusSymbol(_ availability: DebugRuntimeAvailability?) -> String {
    switch availability {
    case .available: "checkmark.circle.fill"
    case .checking: "hourglass"
    case .unavailable, nil: "exclamationmark.triangle.fill"
    }
  }

  private func reconcileTargetSelection() {
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
}

private struct DebugLogsWorkspace: View {
  let operation: DebugOperationPresentation?
  let target: DebugTargetPresentation?
  let relatedJobs: [DebugJobPresentation]

  @State private var durationSeconds = 30
  @State private var minimumLevel = "Warn"
  @State private var domain = ""
  @State private var tag = ""
  @State private var pid = ""
  @State private var keyword = ""
  @State private var marker = ""
  @State private var isViewportPaused = false
  @State private var savesRawHiLog = true

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

  var body: some View {
    GeometryReader { geometry in
      ViewThatFits(in: .horizontal) {
        HSplitView {
          configuration
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 390, maxHeight: .infinity)
          liveAndStorage
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: geometry.size.width, height: geometry.size.height)

        ScrollView {
          VStack(spacing: 16) {
            configuration
            liveAndStorage
          }
          .padding(16)
        }
      }
    }
  }

  private var configuration: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        DebugCard(
          title: DebugL10n.text("debug.logs.capture.title"), symbol: "record.circle"
        ) {
          VStack(alignment: .leading, spacing: 12) {
            LabeledContent(DebugL10n.text("debug.logs.target")) {
              Text(target?.id ?? DebugL10n.text("debug.target.none"))
                .font(.body.monospaced())
            }
            Stepper(
              DebugL10n.format("debug.logs.duration", durationSeconds),
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
            typedField("debug.logs.domain", text: $domain, prompt: "0xD003900")
            typedField("debug.logs.tag", text: $tag, prompt: "ArkUI")
            typedField("debug.logs.pid", text: $pid, prompt: "1234")
            typedField("debug.logs.keyword", text: $keyword, prompt: "render")
            typedField("debug.logs.marker", text: $marker, prompt: "checkout-start")
            Toggle(DebugL10n.text("debug.logs.rawSave"), isOn: $savesRawHiLog)
              .disabled(true)
            Text(DebugL10n.text("debug.logs.filters.note"))
              .font(.footnote)
              .foregroundStyle(.secondary)
            if !invalidFilterNames.isEmpty {
              Label(
                DebugL10n.format(
                  "debug.logs.filters.invalid", invalidFilterNames.joined(separator: ", ")),
                systemImage: "exclamationmark.circle"
              )
              .font(.footnote)
              .foregroundStyle(.red)
            }
          }
        }

        DebugAvailabilityCard(operation: operation)

        DebugCard(
          title: DebugL10n.text("debug.logs.request.title"), symbol: "list.bullet.rectangle"
        ) {
          VStack(alignment: .leading, spacing: 8) {
            DebugCodeRow(
              label: "operation", value: DebugApplicationFacade.captureDiagnosticsReference)
            DebugCodeRow(label: "durationSeconds", value: String(durationSeconds))
            DebugCodeRow(
              label: "hilogFilters",
              value: filterTokens.isEmpty ? "[]" : "[\(filterTokens.joined(separator: ", "))]")
            DebugCodeRow(label: "uiDump", value: "false")
            Button(DebugL10n.text("debug.logs.start")) {}
              .buttonStyle(.borderedProminent)
              .disabled(true)
              .help(DebugL10n.text("debug.blocked.readOnlyTransport"))
              .accessibilityIdentifier("debug.logs.start")
            DebugBlockedReason(text: DebugL10n.text("debug.blocked.readOnlyTransport"))
          }
        }

        destructiveActions
      }
      .padding(16)
    }
  }

  private var liveAndStorage: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        DebugCard(title: DebugL10n.text("debug.logs.live.title"), symbol: "text.alignleft") {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              // Pausing freezes the viewport, never the host capture, and only
              // an active capture has a viewport to pause — so the button is
              // disabled while nothing is being captured, which in this
              // read-only build is always.
              Button(
                DebugL10n.text(isViewportPaused ? "debug.logs.resume" : "debug.logs.pause")
              ) {
                isViewportPaused.toggle()
              }
              .disabled(true)
              .help(DebugL10n.text("debug.logs.pause.requiresCapture"))
              .accessibilityIdentifier("debug.logs.pauseViewport")
              Spacer()
              Label(
                DebugL10n.text("debug.logs.viewport.bounded"),
                systemImage: "arrow.down.right.and.arrow.up.left"
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
            ZStack {
              RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor))
              VStack(spacing: 8) {
                Image(systemName: "text.page.badge.magnifyingglass")
                  .font(.title2)
                  .foregroundStyle(.secondary)
                Text(DebugL10n.text("debug.logs.live.empty"))
                  .font(.callout.weight(.medium))
                Text(DebugL10n.text("debug.logs.live.empty.detail"))
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .multilineTextAlignment(.center)
                  .frame(maxWidth: 420)
              }
              .padding()
            }
            .frame(minHeight: 250)
            .overlay {
              RoundedRectangle(cornerRadius: 8)
                .stroke(.separator, lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("debug.logs.viewport")
          }
        }

        DebugCard(title: DebugL10n.text("debug.logs.shards.title"), symbol: "externaldrive") {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text(DebugL10n.text("debug.logs.shards.sequence"))
              Spacer()
              Text(DebugL10n.text("debug.logs.shards.size"))
              Text(DebugL10n.text("debug.logs.shards.hash"))
                .frame(width: 100, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider()
            ContentUnavailableView {
              Label(
                DebugL10n.text("debug.logs.shards.empty"),
                systemImage: "externaldrive.badge.questionmark")
            } description: {
              Text(DebugL10n.text("debug.logs.shards.empty.detail"))
            }
            .frame(minHeight: 110)
            Divider()
            HStack {
              Label(
                DebugL10n.text("debug.logs.storage.partial"),
                systemImage: "checkmark.shield")
              Spacer()
              Button(DebugL10n.text("debug.logs.export")) {}
                .disabled(true)
                .help(DebugL10n.text("debug.blocked.artifactExport"))
            }
            .font(.footnote)
            if let operation {
              Text(
                DebugL10n.format(
                  "debug.logs.storage.totalBudget",
                  ByteCountFormatter.string(
                    fromByteCount: Int64(operation.outputByteBudget), countStyle: .file))
              )
              .font(.footnote.monospacedDigit())
              .foregroundStyle(.secondary)
            }
          }
        }

        DebugRecentJobsCard(jobs: relatedJobs)
      }
      .padding(16)
    }
  }

  private var destructiveActions: some View {
    DebugCard(
      title: DebugL10n.text("debug.logs.destructive.title"),
      symbol: "exclamationmark.triangle"
    ) {
      VStack(alignment: .leading, spacing: 10) {
        Text(DebugL10n.text("debug.logs.destructive.scope"))
          .font(.callout)
        // Exactly one destructive buffer action exists in the design
        // vocabulary. Inventing siblings (resize, flush) would present device
        // mutations no published operation defines.
        Menu(DebugL10n.text("debug.logs.destructive.menu")) {
          Button(DebugL10n.text("debug.logs.destructive.clear")) {}
            .disabled(true)
        }
        .disabled(true)
        DebugBlockedReason(text: DebugL10n.text("debug.blocked.bufferOperation"))
      }
    }
  }

  private func typedField(_ key: String, text: Binding<String>, prompt: String) -> some View {
    TextField(DebugL10n.text(key), text: text, prompt: Text(prompt))
      .textFieldStyle(.roundedBorder)
  }
}

private struct DebugAppsWorkspace: View {
  let operation: DebugOperationPresentation?
  let target: DebugTargetPresentation?
  let relatedJobs: [DebugJobPresentation]

  @State private var isImporterPresented = false
  @State private var selectedHAPURL: URL?
  @State private var selectionError: String?
  @State private var bundleName = ""
  @State private var abilityName = ""
  @State private var installPolicy = "installOrReplace"
  @State private var cleanupPolicy = "uninstall"
  @State private var postRunState = "stopped"
  @State private var captureDiagnostics = true
  @State private var diagnosticsDuration = 30

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 16) {
            packageAndIdentity.frame(minWidth: 300, maxWidth: 390)
            lifecycleReview.frame(minWidth: 420, maxWidth: .infinity)
          }
          VStack(spacing: 16) {
            packageAndIdentity
            lifecycleReview
          }
        }
        packageInventory
        DebugRecentJobsCard(jobs: relatedJobs)
      }
      .frame(maxWidth: 1_050, alignment: .topLeading)
      .padding(16)
    }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: [UTType(filenameExtension: "hap") ?? .data],
      allowsMultipleSelection: false,
      onCompletion: handleHAPSelection)
  }

  private var packageAndIdentity: some View {
    VStack(spacing: 16) {
      DebugAvailabilityCard(operation: operation)
      DebugCard(title: DebugL10n.text("debug.apps.package.title"), symbol: "shippingbox") {
        VStack(alignment: .leading, spacing: 12) {
          LabeledContent(DebugL10n.text("debug.apps.target")) {
            Text(target?.id ?? DebugL10n.text("debug.target.none"))
              .font(.body.monospaced())
          }
          Button {
            isImporterPresented = true
          } label: {
            Label(DebugL10n.text("debug.apps.chooseHAP"), systemImage: "doc.badge.plus")
          }
          Text(selectedHAPURL?.lastPathComponent ?? DebugL10n.text("debug.apps.noHAP"))
            .font(.callout.monospaced())
            .foregroundStyle(selectedHAPURL == nil ? .secondary : .primary)
            .textSelection(.enabled)
          if let selectionError {
            Label(selectionError, systemImage: "xmark.octagon")
              .font(.footnote)
              .foregroundStyle(.red)
          }
          Text(DebugL10n.text("debug.apps.localOnly"))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }

      DebugCard(title: DebugL10n.text("debug.apps.identity.title"), symbol: "tag") {
        VStack(alignment: .leading, spacing: 10) {
          TextField(
            DebugL10n.text("debug.apps.bundle"), text: $bundleName,
            prompt: Text("com.example.app"))
          TextField(
            DebugL10n.text("debug.apps.ability"), text: $abilityName,
            prompt: Text("EntryAbility"))
          // The note below promises schema validation; these two fields are
          // the argv-adjacent inputs on this tab, so the gate is applied
          // here, not deferred to a future submit path.
          if let invalid = invalidIdentityFieldNames {
            Label(
              DebugL10n.format("debug.typed.invalidIdentifier", invalid),
              systemImage: "exclamationmark.circle"
            )
            .font(.footnote)
            .foregroundStyle(.red)
            .accessibilityIdentifier("debug.apps.identity.invalid")
          }
          Text(DebugL10n.text("debug.apps.identity.note"))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
      }
    }
  }

  private var lifecycleReview: some View {
    VStack(spacing: 16) {
      DebugCard(
        title: DebugL10n.text("debug.apps.lifecycle.title"), symbol: "arrow.triangle.2.circlepath"
      ) {
        VStack(alignment: .leading, spacing: 12) {
          Picker(DebugL10n.text("debug.apps.installPolicy"), selection: $installPolicy) {
            Text(DebugL10n.text("debug.apps.install.replace")).tag("installOrReplace")
            Text(DebugL10n.text("debug.apps.install.fresh")).tag("installFresh")
          }
          Picker(DebugL10n.text("debug.apps.cleanupPolicy"), selection: $cleanupPolicy) {
            Text(DebugL10n.text("debug.apps.cleanup.uninstall")).tag("uninstall")
            Text(DebugL10n.text("debug.apps.cleanup.retain")).tag("retain")
            Text(DebugL10n.text("debug.apps.cleanup.restore")).tag("restorePrevious")
          }
          Picker(DebugL10n.text("debug.apps.postRun"), selection: $postRunState) {
            Text(DebugL10n.text("debug.apps.postRun.stopped")).tag("stopped")
            Text(DebugL10n.text("debug.apps.postRun.running")).tag("running")
          }
          Toggle(DebugL10n.text("debug.apps.captureDiagnostics"), isOn: $captureDiagnostics)
          if captureDiagnostics {
            Stepper(
              DebugL10n.format("debug.apps.diagnosticsDuration", diagnosticsDuration),
              value: $diagnosticsDuration, in: 1...300)
          }
          Divider()
          Label(
            DebugL10n.text("debug.apps.mutationScope"),
            systemImage: "exclamationmark.shield"
          )
          .font(.callout.weight(.medium))
          Text(DebugL10n.text("debug.apps.mutationDetail"))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }

      DebugCard(title: DebugL10n.text("debug.apps.plan.title"), symbol: "list.number") {
        VStack(alignment: .leading, spacing: 8) {
          if let operation {
            ForEach(operation.steps) { step in
              HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: effectSymbol(step.effect))
                  .frame(width: 18)
                  .foregroundStyle(effectColor(step.effect))
                VStack(alignment: .leading, spacing: 2) {
                  Text(step.id).font(.callout.monospaced().weight(.medium))
                  Text("\(step.kind) · \(step.effect)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if step.isOptional {
                  Text(DebugL10n.text("debug.optional"))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                }
              }
              if step.id != operation.steps.last?.id { Divider() }
            }
          }
          Button(DebugL10n.text("debug.apps.run")) {}
            .buttonStyle(.borderedProminent)
            .disabled(true)
            .help(DebugL10n.text("debug.blocked.hapImport"))
          DebugBlockedReason(text: DebugL10n.text("debug.blocked.hapImport"))
        }
      }
    }
  }

  private var packageInventory: some View {
    DebugCard(title: DebugL10n.text("debug.apps.inventory.title"), symbol: "tablecells") {
      VStack(spacing: 12) {
        HStack {
          Text(DebugL10n.text("debug.apps.inventory.package"))
          Spacer()
          Text(DebugL10n.text("debug.apps.inventory.pid"))
            .font(.body.monospacedDigit())
          Text(DebugL10n.text("debug.apps.inventory.debuggable"))
            .frame(width: 100, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        Divider()
        ContentUnavailableView {
          Label(DebugL10n.text("debug.apps.inventory.empty"), systemImage: "app.dashed")
        } description: {
          Text(DebugL10n.text("debug.apps.inventory.empty.detail"))
        }
        .frame(minHeight: 120)
        HStack {
          Button(DebugL10n.text("debug.apps.action.start")) {}.disabled(true)
          Button(DebugL10n.text("debug.apps.action.stop")) {}.disabled(true)
          Spacer()
          Button(DebugL10n.text("debug.apps.action.uninstall"), role: .destructive) {}
            .disabled(true)
        }
      }
    }
  }

  private var invalidIdentityFieldNames: String? {
    let invalid = [
      (DebugL10n.text("debug.apps.bundle"), bundleName),
      (DebugL10n.text("debug.apps.ability"), abilityName),
    ]
    .filter { !$0.1.isEmpty && !DebugTypedValueValidator.isSafeTypedIdentifier($0.1) }
    .map(\.0)
    return invalid.isEmpty ? nil : invalid.joined(separator: ", ")
  }

  private func handleHAPSelection(_ result: Result<[URL], Error>) {
    switch result {
    case .failure:
      selectedHAPURL = nil
      selectionError = DebugL10n.text("debug.apps.selection.failed")
    case .success(let urls):
      guard let url = urls.first, url.pathExtension.lowercased() == "hap" else {
        selectedHAPURL = nil
        selectionError = DebugL10n.text("debug.apps.selection.invalid")
        return
      }
      selectedHAPURL = url
      selectionError = nil
    }
  }
}

private struct DebugNetworkWorkspace: View {
  let target: DebugTargetPresentation?

  @State private var direction = DebugPortRuleDirection.forward
  @State private var localPort = ""
  @State private var remotePort = ""

  private var validation: DebugPortRuleValidationResult {
    DebugPortRuleValidator.validate(
      direction: direction, localPortText: localPort, remotePortText: remotePort)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 16) {
            ruleEditor.frame(minWidth: 320, maxWidth: 410)
            ruleList.frame(minWidth: 420, maxWidth: .infinity)
          }
          VStack(spacing: 16) {
            ruleEditor
            ruleList
          }
        }
        protocolAndSafety
      }
      .frame(maxWidth: 1_050, alignment: .topLeading)
      .padding(16)
    }
  }

  private var ruleEditor: some View {
    DebugCard(title: DebugL10n.text("debug.network.editor.title"), symbol: "plus.circle") {
      VStack(alignment: .leading, spacing: 12) {
        LabeledContent(DebugL10n.text("debug.network.target")) {
          Text(target?.id ?? DebugL10n.text("debug.target.none"))
            .font(.body.monospaced())
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
        Button(DebugL10n.text("debug.network.add")) {}
          .buttonStyle(.borderedProminent)
          .disabled(true)
          .help(DebugL10n.text("debug.blocked.forwardOperation"))
        DebugBlockedReason(text: DebugL10n.text("debug.blocked.forwardOperation"))
      }
    }
  }

  @ViewBuilder
  private var validationMessage: some View {
    switch validation {
    case .valid:
      Label(DebugL10n.text("debug.network.validation.valid"), systemImage: "checkmark.circle")
        .foregroundStyle(.green)
        .font(.footnote)
    case .invalid(let failure):
      Label(
        DebugL10n.text("debug.network.validation.\(failure.rawValue)"),
        systemImage: "exclamationmark.circle"
      )
      .foregroundStyle(localPort.isEmpty && remotePort.isEmpty ? Color.secondary : Color.red)
      .font(.footnote)
    }
  }

  private var ruleList: some View {
    DebugCard(title: DebugL10n.text("debug.network.rules.title"), symbol: "arrow.left.arrow.right")
    {
      VStack(spacing: 12) {
        HStack {
          Text(DebugL10n.text("debug.network.rules.direction"))
          Text(DebugL10n.text("debug.network.rules.local"))
          Spacer()
          Text(DebugL10n.text("debug.network.rules.remote"))
          Text(DebugL10n.text("debug.network.rules.state"))
            .frame(width: 90, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        Divider()
        ContentUnavailableView {
          Label(
            DebugL10n.text("debug.network.rules.empty"),
            systemImage: "point.3.filled.connected.trianglepath.dotted")
        } description: {
          Text(DebugL10n.text("debug.network.rules.empty.detail"))
        }
        .frame(minHeight: 180)
        Divider()
        HStack {
          Label(DebugL10n.text("debug.network.delete.scope"), systemImage: "target")
            .font(.footnote)
            .foregroundStyle(.secondary)
          Spacer()
          Button(DebugL10n.text("debug.network.delete"), role: .destructive) {}
            .disabled(true)
        }
      }
    }
  }

  private var protocolAndSafety: some View {
    DebugCard(title: DebugL10n.text("debug.network.safety.title"), symbol: "checkmark.shield") {
      VStack(alignment: .leading, spacing: 8) {
        Label(DebugL10n.text("debug.network.safety.typed"), systemImage: "number")
        Label(DebugL10n.text("debug.network.safety.noShell"), systemImage: "text.badge.xmark")
        Label(DebugL10n.text("debug.network.safety.binding"), systemImage: "link")
      }
      .font(.callout)
    }
  }
}

private struct DebugCommandsWorkspace: View {
  let target: DebugTargetPresentation?

  @State private var selectedTemplateID =
    DebugApplicationFacade.approvedCommandTemplates.first?.id
  @State private var bundleName = ""

  private var selectedTemplate: DebugCommandTemplatePresentation? {
    DebugApplicationFacade.approvedCommandTemplates.first { $0.id == selectedTemplateID }
  }

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        // The whole tab's contract, stated before any template is chosen: a
        // closed template set with schema-defined inputs, and the argv below
        // is provider lowering echoed read-only, never an input.
        Label(
          DebugL10n.text("debug.commands.calloutTyped"),
          systemImage: "exclamationmark.shield"
        )
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .accessibilityIdentifier("debug.commands.typedOnly")
        Divider()
        HSplitView {
          List {
            ForEach(DebugApplicationFacade.approvedCommandTemplates, id: \.id) { template in
              Button {
                selectedTemplateID = template.id
              } label: {
                DebugCommandTemplateRow(template: template)
              }
              .buttonStyle(.plain)
              .listRowBackground(
                selectedTemplateID == template.id ? Color.accentColor.opacity(0.14) : Color.clear)
            }
          }
          .frame(minWidth: 240, idealWidth: 280, maxWidth: 330, maxHeight: .infinity)

          commandDetail
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
  }

  private var commandDetail: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let template = selectedTemplate {
          DebugCard(title: template.id, symbol: "chevron.left.forwardslash.chevron.right") {
            VStack(alignment: .leading, spacing: 12) {
              DebugCodeRow(label: "catalog", value: "arkdeck-remote-operations@1.0.0")
              DebugCodeRow(label: "actionId", value: template.id)
              DebugCodeRow(label: "effect", value: template.effect)
              LabeledContent(DebugL10n.text("debug.commands.target")) {
                Text(target?.id ?? DebugL10n.text("debug.target.none"))
                  .font(.body.monospaced())
              }
              if template.parameterNames.contains("bundleName") {
                TextField(
                  DebugL10n.text("debug.commands.bundle"), text: $bundleName,
                  prompt: Text("com.example.app")
                )
                .textFieldStyle(.roundedBorder)
                if !bundleName.isEmpty,
                  !DebugTypedValueValidator.isSafeTypedIdentifier(bundleName)
                {
                  Label(
                    DebugL10n.format(
                      "debug.typed.invalidIdentifier",
                      DebugL10n.text("debug.commands.bundle")),
                    systemImage: "exclamationmark.circle"
                  )
                  .font(.footnote)
                  .foregroundStyle(.red)
                  .accessibilityIdentifier("debug.commands.bundle.invalid")
                }
              } else {
                Text(DebugL10n.text("debug.commands.noParameters"))
                  .font(.callout)
                  .foregroundStyle(.secondary)
              }
            }
          }

          DebugCard(
            title: DebugL10n.text("debug.commands.argv.title"), symbol: "list.bullet.rectangle"
          ) {
            VStack(alignment: .leading, spacing: 10) {
              DebugCodeRow(
                label: DebugL10n.text("debug.commands.executable"),
                value: DebugL10n.text("debug.commands.notGenerated"))
              DebugCodeRow(
                label: DebugL10n.text("debug.commands.arguments"),
                value: DebugL10n.text("debug.commands.notGenerated"))
              Text(DebugL10n.text("debug.commands.argv.note"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }

          DebugCard(title: DebugL10n.text("debug.commands.result.title"), symbol: "doc.text") {
            VStack(alignment: .leading, spacing: 10) {
              HStack {
                DebugCodeRow(
                  label: DebugL10n.text("debug.commands.result.exitCode"), value: "—")
                Spacer()
                DebugCodeRow(
                  label: DebugL10n.text("debug.commands.result.duration"), value: "—")
              }
              Divider()
              LabeledContent(DebugL10n.text("debug.commands.result.stdout")) {
                Text(DebugL10n.text("debug.commands.result.none"))
                  .foregroundStyle(.secondary)
              }
              LabeledContent(DebugL10n.text("debug.commands.result.stderr")) {
                Text(DebugL10n.text("debug.commands.result.none"))
                  .foregroundStyle(.secondary)
              }
            }
          }

          HStack {
            Button(DebugL10n.text("debug.commands.run")) {}
              .buttonStyle(.borderedProminent)
              .disabled(true)
            Spacer()
            Label(DebugL10n.text("debug.commands.noPTY"), systemImage: "rectangle.slash")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          DebugBlockedReason(text: DebugL10n.text("debug.blocked.commandOperation"))
          Text(DebugL10n.text("debug.commands.footerNoFreeText"))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("debug.commands.footer")
        } else {
          ContentUnavailableView(DebugL10n.text("debug.commands.select"), systemImage: "terminal")
        }
      }
      .frame(maxWidth: 760, alignment: .topLeading)
      .padding(16)
    }
  }
}

private struct DebugCommandTemplateRow: View {
  let template: DebugCommandTemplatePresentation

  private var symbol: String {
    template.effect == "readOnly"
      ? "doc.text.magnifyingglass" : "exclamationmark.shield"
  }

  private var effectColor: Color {
    template.effect == "readOnly" ? .secondary : .orange
  }

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(template.id).font(.body.monospaced())
        Text(template.effect)
          .font(.caption)
          .foregroundStyle(effectColor)
      }
    } icon: {
      Image(systemName: symbol)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct DebugAvailabilityCard: View {
  let operation: DebugOperationPresentation?

  var body: some View {
    DebugCard(title: DebugL10n.text("debug.availability.title"), symbol: "checkmark.seal") {
      VStack(alignment: .leading, spacing: 8) {
        if let operation {
          DebugCodeRow(
            label: DebugL10n.text("debug.availability.operation"), value: operation.reference)
          switch operation.availability {
          case .checking:
            Label(DebugL10n.text("debug.availability.checking"), systemImage: "hourglass")
          case .available:
            Label(
              DebugL10n.text("debug.availability.available"), systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
          case .unavailable(let reasons):
            Label(
              DebugL10n.text("debug.availability.unavailable"), systemImage: "xmark.octagon.fill"
            )
            .foregroundStyle(.red)
            ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
              Text(reason)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            }
          }
          Text(DebugL10n.format("debug.availability.effect", operation.minimumEffect))
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
          DebugBlockedReason(text: DebugL10n.text("debug.availability.missing"))
        }
      }
    }
  }
}

private struct DebugRecentJobsCard: View {
  let jobs: [DebugJobPresentation]

  var body: some View {
    DebugCard(title: DebugL10n.text("debug.jobs.title"), symbol: "clock.arrow.circlepath") {
      if jobs.isEmpty {
        Text(DebugL10n.text("debug.jobs.empty"))
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 54, alignment: .center)
      } else {
        VStack(spacing: 8) {
          ForEach(jobs.prefix(5)) { job in
            HStack(spacing: 10) {
              Image(systemName: job.needsAttention ? "exclamationmark.triangle" : "circle.fill")
                .font(.caption)
                .foregroundStyle(job.needsAttention ? .orange : .secondary)
              VStack(alignment: .leading, spacing: 2) {
                Text(job.id).font(.callout.monospaced())
                Text("\(job.targetID) · \(job.operationReference)")
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Text(job.state)
                .font(.caption.weight(.medium))
            }
          }
        }
      }
    }
  }
}

private struct DebugCard<Content: View>: View {
  let title: String
  let symbol: String
  @ViewBuilder let content: Content

  var body: some View {
    GroupBox {
      content
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    } label: {
      Label(title, systemImage: symbol)
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
    }
  }
}

private struct DebugCodeRow: View {
  let label: String
  let value: String

  var body: some View {
    LabeledContent(label) {
      Text(value)
        .font(.callout.monospaced())
        .textSelection(.enabled)
        .multilineTextAlignment(.trailing)
    }
  }
}

private struct DebugBlockedReason: View {
  let text: String

  var body: some View {
    Label(text, systemImage: "lock.fill")
      .font(.footnote)
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
final class DebugWorkspaceViewModel: ObservableObject {
  @Published private(set) var workspace = DebugWorkspacePresentation.loading
  @Published private(set) var isRefreshing = false

  private let provider: any DebugApplicationProviding

  init(provider: any DebugApplicationProviding) {
    self.provider = provider
  }

  func refresh() {
    guard !isRefreshing else { return }
    isRefreshing = true
    Task {
      workspace = await provider.refreshWorkspace()
      isRefreshing = false
    }
  }
}

private enum DebugL10n {
  static func text(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "DebugLocalizable")
  }

  static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: text(key), arguments: arguments)
  }
}

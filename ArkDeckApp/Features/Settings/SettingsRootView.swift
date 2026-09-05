import AppKit
import ArkDeckWorkflows
import SwiftUI
import UniformTypeIdentifiers

struct SettingsRootView<UpdatesContent: View>: View {
  var model: SettingsWorkspaceViewModel
  let hdcPresentation: HDCDiagnosticsPresentation
  let isHDCRefreshInFlight: Bool
  let hdcConfigurationError: String?
  let hasActiveRuntimeJobs: Bool
  @State private var traceCacheModel: TraceCacheSettingsViewModel
  let onHDCRefresh: () -> Void
  let onSelectHDC: (URL) -> Void
  let updatesContent: UpdatesContent

  init(
    model: SettingsWorkspaceViewModel,
    hdcPresentation: HDCDiagnosticsPresentation,
    isHDCRefreshInFlight: Bool,
    hdcConfigurationError: String?,
    hasActiveRuntimeJobs: Bool,
    traceCacheProvider: any RuntimeTraceCacheApplicationProviding =
      RuntimeTraceCacheApplicationFacade.make(),
    onHDCRefresh: @escaping () -> Void,
    onSelectHDC: @escaping (URL) -> Void,
    @ViewBuilder updatesContent: () -> UpdatesContent
  ) {
    self.model = model
    self.hdcPresentation = hdcPresentation
    self.isHDCRefreshInFlight = isHDCRefreshInFlight
    self.hdcConfigurationError = hdcConfigurationError
    self.hasActiveRuntimeJobs = hasActiveRuntimeJobs
    _traceCacheModel = State(
      initialValue: TraceCacheSettingsViewModel(provider: traceCacheProvider))
    self.onHDCRefresh = onHDCRefresh
    self.onSelectHDC = onSelectHDC
    self.updatesContent = updatesContent()
  }

  var body: some View {
    TabView {
      Tab(settingsText("settings.tab.general"), systemImage: "gearshape") {
        GeneralSettingsPane(model: model)
      }
      Tab(
        settingsText("settings.tab.toolchains"),
        systemImage: "wrench.and.screwdriver"
      ) {
        ToolchainsSettingsPane(
          presentation: hdcPresentation,
          isRefreshInFlight: isHDCRefreshInFlight,
          configurationError: hdcConfigurationError,
          hasActiveRuntimeJobs: hasActiveRuntimeJobs,
          onRefresh: onHDCRefresh,
          onSelectExecutable: onSelectHDC)
      }
      Tab(settingsText("settings.tab.remoteSources"), systemImage: "server.rack") {
        RemoteBuildSourcesSettingsPane(model: model)
      }
      Tab(settingsText("settings.tab.storage"), systemImage: "externaldrive") {
        StorageSettingsPane(model: model)
      }
      Tab(settingsText("settings.tab.trace"), systemImage: "waveform.path.ecg") {
        TraceSettingsPane(model: traceCacheModel)
      }
      Tab(settingsText("settings.tab.updates"), systemImage: "arrow.triangle.2.circlepath") {
        WorkspacePage {
          updatesContent
        }
      }
      Tab(settingsText("settings.tab.diagnostics"), systemImage: "stethoscope") {
        DiagnosticsSettingsPane(model: model)
      }
    }
    .frame(minWidth: 760, idealWidth: 820, minHeight: 560, idealHeight: 620)
    .task {
      model.refresh()
      model.refreshRemoteSources()
    }
  }
}

private struct GeneralSettingsPane: View {
  var model: SettingsWorkspaceViewModel
  @AppStorage(ApplicationIconChoice.persistenceKey)
  private var applicationIconChoice = ApplicationIconChoice.defaultChoice.rawValue

  var body: some View {
    WorkspacePage {
      WorkspaceHeaderBar(summary: Text(settingsText("settings.general.subtitle")))
      GroupBox(settingsText("settings.general.appIcon")) {
        ApplicationIconPicker(selection: $applicationIconChoice)
      }
      if let general = model.presentation?.general {
        GroupBox(settingsText("settings.general.build")) {
          WorkspaceFactGrid {
            settingsFact("settings.general.app", general.appName)
            settingsFact("settings.general.version", general.appVersion)
            settingsFact("settings.general.buildNumber", general.buildVersion)
            settingsFact("settings.general.platform", general.platform)
            settingsFact("settings.general.architecture", general.architecture)
          }
        }
      } else {
        SettingsUnavailableRow(model: model, refreshIdentifier: "settings.general.refresh")
      }
      GroupBox(settingsText("settings.general.privacy")) {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
          SettingsAssuranceRow(
            icon: "lock.shield",
            title: settingsText("settings.general.localFirst"),
            detail: settingsText("settings.general.localFirst.detail"))
          SettingsAssuranceRow(
            icon: "icloud.slash",
            title: settingsText("settings.general.noUpload"),
            detail: settingsText("settings.general.noUpload.detail"))
        }
      }
    }
  }
}

private struct RemoteBuildSourcesSettingsPane: View {
  var model: SettingsWorkspaceViewModel
  @State private var editorSource: RemoteBuildSourcePresentation?
  @State private var isEditorPresented = false

  var body: some View {
    WorkspacePage {
      WorkspaceHeaderBar(summary: Text(settingsText("settings.remoteSources.subtitle")))
      GroupBox(settingsText("settings.remoteSources.title")) {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
          if model.remoteSources.isEmpty && model.isRemoteSourcesBusy {
            SettingsLoadingRow()
          } else if model.remoteSources.isEmpty {
            ContentUnavailableView(
              settingsText("settings.remoteSources.empty.title"),
              systemImage: "server.rack",
              description: Text(settingsText("settings.remoteSources.empty.detail")))
            .frame(maxWidth: .infinity, minHeight: 180)
          } else {
            ForEach(model.remoteSources) { source in
              RemoteBuildSourceSettingsRow(
                source: source,
                onEdit: {
                  editorSource = source
                  isEditorPresented = true
                },
                onRemove: { Task { await model.removeRemoteSource(source.id) } })
              if source.id != model.remoteSources.last?.id { Divider() }
            }
          }
          HStack {
            Button {
              editorSource = nil
              isEditorPresented = true
            } label: {
              Label(settingsText("settings.remoteSources.add"), systemImage: "plus")
            }
            .accessibilityIdentifier("settings.remoteSources.add")
            Button(settingsText("settings.remoteSources.refresh")) {
              model.refreshRemoteSources()
            }
            .accessibilityIdentifier("settings.remoteSources.refresh")
            .disabled(model.isRemoteSourcesBusy)
            Spacer()
            if model.isRemoteSourcesBusy { ProgressView().controlSize(.small) }
          }
        }
        .padding(WorkspaceMetrics.contentGap)
      }
      GroupBox(settingsText("settings.remoteSources.security.title")) {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
          SettingsAssuranceRow(
            icon: "key.horizontal",
            title: settingsText("settings.remoteSources.security.keychain"),
            detail: settingsText("settings.remoteSources.security.keychain.detail"))
          SettingsAssuranceRow(
            icon: "checkmark.shield",
            title: settingsText("settings.remoteSources.security.hostKey"),
            detail: settingsText("settings.remoteSources.security.hostKey.detail"))
          SettingsAssuranceRow(
            icon: "lock.doc",
            title: settingsText("settings.remoteSources.security.readOnly"),
            detail: settingsText("settings.remoteSources.security.readOnly.detail"))
        }
        .padding(WorkspaceMetrics.contentGap)
      }
      if let error = model.remoteSourceError {
        settingsErrorNotice(error)
      }
    }
    .sheet(isPresented: $isEditorPresented, onDismiss: model.clearRemoteSourceProbe) {
      RemoteBuildSourceEditor(model: model, source: editorSource)
    }
  }
}

private struct RemoteBuildSourceSettingsRow: View {
  let source: RemoteBuildSourcePresentation
  let onEdit: () -> Void
  let onRemove: () -> Void
  @State private var isRemovalConfirmationPresented = false

  var body: some View {
    HStack(alignment: .top, spacing: WorkspaceMetrics.contentGap) {
      Image(systemName: source.credentialStored ? "server.rack" : "exclamationmark.triangle")
        .font(.title3)
        .foregroundStyle(source.credentialStored ? Color.secondary : Color.orange)
        .frame(width: 28)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
        HStack(spacing: WorkspaceMetrics.tightGap) {
          Text(source.name).font(.headline)
          if source.credentialStored {
            Label(
              settingsText(
                source.usesSystemDefaultCredential
                  ? "settings.remoteSources.credentialSystemDefault"
                  : "settings.remoteSources.credentialStored"),
              systemImage: source.usesSystemDefaultCredential ? "person.badge.key" : "key.fill")
              .font(WorkspaceFont.caption)
              .foregroundStyle(.green)
          }
        }
        Text(source.endpoint)
          .font(WorkspaceFont.monospacedValue)
          .textSelection(.enabled)
        Text(source.rootPath)
          .font(WorkspaceFont.monospacedDense)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(source.rootPath)
        Text(source.hostKeyFingerprint)
          .font(WorkspaceFont.monospacedDense)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer(minLength: WorkspaceMetrics.contentGap)
      Button(settingsText("settings.remoteSources.edit"), action: onEdit)
      Button(role: .destructive) {
        isRemovalConfirmationPresented = true
      } label: {
        Image(systemName: "trash")
      }
      .accessibilityLabel(settingsText("settings.remoteSources.remove"))
      .confirmationDialog(
        settingsText("settings.remoteSources.remove.title"),
        isPresented: $isRemovalConfirmationPresented,
        titleVisibility: .visible
      ) {
        Button(settingsText("settings.remoteSources.remove"), role: .destructive, action: onRemove)
        Button(settingsText("settings.common.cancel"), role: .cancel) {}
      } message: {
        Text(settingsText("settings.remoteSources.remove.detail"))
      }
    }
    .accessibilityElement(children: .contain)
  }
}

private struct RemoteBuildSourceEditor: View {
  @Environment(\.dismiss) private var dismiss
  var model: SettingsWorkspaceViewModel
  let source: RemoteBuildSourcePresentation?

  @State private var name: String
  @State private var host: String
  @State private var port: String
  @State private var username: String
  @State private var rootPath: String
  @State private var authentication: RemoteBuildSourceAuthentication
  @State private var password = ""
  @State private var privateKeyData: Data?
  @State private var privateKeyName: String?
  @State private var passphrase = ""
  @State private var usesSystemDefaultKey: Bool
  @State private var isKeyImporterPresented = false
  @State private var importerError: String?

  init(model: SettingsWorkspaceViewModel, source: RemoteBuildSourcePresentation?) {
    self.model = model
    self.source = source
    _name = State(initialValue: source?.name ?? "")
    _host = State(initialValue: source?.host ?? "")
    _port = State(initialValue: String(source?.port ?? 22))
    _username = State(initialValue: source?.username ?? "")
    _rootPath = State(initialValue: source?.rootPath ?? "")
    _authentication = State(initialValue: source?.authentication ?? .password)
    _usesSystemDefaultKey = State(
      initialValue: source == nil || source?.usesSystemDefaultCredential == true)
  }

  private var credentialInput: RemoteBuildSourceCredentialInput? {
    switch authentication {
    case .password:
      password.isEmpty ? nil : .password(password)
    case .privateKey:
      if let privateKeyData {
        .privateKey(privateKeyData, passphrase: passphrase.isEmpty ? nil : passphrase)
      } else if usesSystemDefaultKey {
        .systemDefault(passphrase: passphrase.isEmpty ? nil : passphrase)
      } else {
        nil
      }
    }
  }

  private var privateKeyStatus: String {
    if let privateKeyName { return privateKeyName }
    if usesSystemDefaultKey {
      return settingsText("settings.remoteSources.systemDefaultIdentity")
    }
    return settingsText("settings.remoteSources.noPrivateKey")
  }

  private var draft: RemoteBuildSourceDraft {
    RemoteBuildSourceDraft(
      id: source?.id, name: name, host: host, port: Int(port) ?? 0,
      username: username, rootPath: rootPath, authentication: authentication)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
          Text(
            source == nil
              ? settingsText("settings.remoteSources.editor.addTitle")
              : settingsText("settings.remoteSources.editor.editTitle")
          )
          .font(.title2.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
          Text(settingsText("settings.remoteSources.editor.detail"))
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(WorkspaceMetrics.pageInsetHorizontal)
      Divider()
      Form {
        Section(settingsText("settings.remoteSources.editor.server")) {
          TextField(settingsText("settings.remoteSources.field.name"), text: $name)
            .accessibilityIdentifier("settings.remoteSources.field.name")
          TextField(settingsText("settings.remoteSources.field.host"), text: $host)
            .accessibilityIdentifier("settings.remoteSources.field.host")
          TextField(settingsText("settings.remoteSources.field.port"), text: $port)
            .accessibilityIdentifier("settings.remoteSources.field.port")
          TextField(settingsText("settings.remoteSources.field.username"), text: $username)
            .accessibilityIdentifier("settings.remoteSources.field.username")
          TextField(settingsText("settings.remoteSources.field.root"), text: $rootPath)
            .accessibilityIdentifier("settings.remoteSources.field.root")
        }
        Section(settingsText("settings.remoteSources.editor.credential")) {
          Picker(settingsText("settings.remoteSources.field.authentication"), selection: $authentication) {
            Text(settingsText("settings.remoteSources.auth.password"))
              .tag(RemoteBuildSourceAuthentication.password)
            Text(settingsText("settings.remoteSources.auth.privateKey"))
              .tag(RemoteBuildSourceAuthentication.privateKey)
          }
          .accessibilityIdentifier("settings.remoteSources.field.authentication")
          if authentication == .password {
            SecureField(
              source == nil
                ? settingsText("settings.remoteSources.field.password")
                : settingsText("settings.remoteSources.field.passwordOptional"),
              text: $password)
              .accessibilityIdentifier("settings.remoteSources.field.password")
          } else {
            HStack {
              Button {
                isKeyImporterPresented = true
              } label: {
                Label(
                  settingsText("settings.remoteSources.choosePrivateKey"),
                  systemImage: "doc.badge.plus")
              }
              .accessibilityIdentifier("settings.remoteSources.choosePrivateKey")
              if !usesSystemDefaultKey {
                Button(settingsText("settings.remoteSources.useSystemDefault")) {
                  privateKeyData = nil
                  privateKeyName = nil
                  usesSystemDefaultKey = true
                  importerError = nil
                  model.clearRemoteSourceProbe()
                }
                .accessibilityIdentifier("settings.remoteSources.useSystemDefault")
              }
              Text(privateKeyStatus)
                .font(WorkspaceFont.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Text(settingsText("settings.remoteSources.systemDefaultHint"))
              .font(WorkspaceFont.secondary)
              .foregroundStyle(.secondary)
            SecureField(settingsText("settings.remoteSources.field.passphrase"), text: $passphrase)
              .accessibilityIdentifier("settings.remoteSources.field.passphrase")
          }
          if let importerError { settingsErrorNotice(importerError) }
          if source != nil && credentialInput == nil {
            Label(
              settingsText("settings.remoteSources.usingStoredCredential"),
              systemImage: "key.fill")
            .font(WorkspaceFont.secondary)
            .foregroundStyle(.secondary)
          }
        }
        Section(settingsText("settings.remoteSources.editor.verify")) {
          Button {
            Task { _ = await model.probeRemoteSource(draft: draft, credential: credentialInput) }
          } label: {
            Label(
              settingsText("settings.remoteSources.testConnection"),
              systemImage: "network.badge.shield.half.filled")
          }
          .accessibilityIdentifier("settings.remoteSources.testConnection")
          .disabled(model.isRemoteSourcesBusy)
          if model.isRemoteSourcesBusy {
            HStack { ProgressView().controlSize(.small); Text(settingsText("settings.remoteSources.testing")) }
          }
          if let probe = model.remoteSourceProbe {
            WorkspaceNotice(tone: .ok, symbol: "checkmark.shield") {
              VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
                Text(settingsText("settings.remoteSources.verified"))
                  .bold()
                Text(probe.endpoint).font(WorkspaceFont.monospacedValue)
                Text(probe.canonicalRootPath).font(WorkspaceFont.monospacedDense)
                Text(probe.hostKeyFingerprint).font(WorkspaceFont.monospacedDense)
                if probe.requiresNewHostTrust {
                  Text(settingsText("settings.remoteSources.trustOnSave"))
                    .font(WorkspaceFont.secondary)
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
          if let error = model.remoteSourceError { settingsErrorNotice(error) }
        }
      }
      .formStyle(.grouped)
      Divider()
      HStack {
        Button(settingsText("settings.common.cancel")) {
          model.clearRemoteSourceProbe()
          dismiss()
        }
          .accessibilityIdentifier("settings.remoteSources.cancel")
        Spacer()
        Button(settingsText("settings.remoteSources.save")) {
          guard let probe = model.remoteSourceProbe else { return }
          Task {
            if await model.saveRemoteSource(probe) { dismiss() }
          }
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("settings.remoteSources.save")
        .disabled(model.remoteSourceProbe == nil || model.isRemoteSourcesBusy)
      }
      .padding(WorkspaceMetrics.pageInsetHorizontal)
    }
    .frame(width: 680, height: 660)
    .fileImporter(
      isPresented: $isKeyImporterPresented,
      allowedContentTypes: [.data],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        guard let url = urls.first else {
          importerError = settingsText("settings.remoteSources.privateKeyReadFailed")
          return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
          let size = values.fileSize, size > 0, size <= 256 * 1_024,
          let data = try? Data(contentsOf: url), !data.isEmpty
        {
          privateKeyData = data
          privateKeyName = url.lastPathComponent
          usesSystemDefaultKey = false
          importerError = nil
          model.clearRemoteSourceProbe()
        } else {
          importerError = settingsText("settings.remoteSources.privateKeyInvalid")
        }
      case .failure:
        importerError = settingsText("settings.remoteSources.privateKeyReadFailed")
        model.clearRemoteSourceProbe()
      }
    }
    .onChange(of: name) { _, _ in model.clearRemoteSourceProbe() }
    .onChange(of: host) { _, _ in model.clearRemoteSourceProbe() }
    .onChange(of: port) { _, _ in model.clearRemoteSourceProbe() }
    .onChange(of: username) { _, _ in model.clearRemoteSourceProbe() }
    .onChange(of: rootPath) { _, _ in model.clearRemoteSourceProbe() }
    .onChange(of: authentication) { _, value in
      if value == .privateKey && source?.authentication != .privateKey {
        usesSystemDefaultKey = true
      }
      model.clearRemoteSourceProbe()
    }
    .onChange(of: password) { _, _ in model.clearRemoteSourceProbe() }
    .onChange(of: passphrase) { _, _ in model.clearRemoteSourceProbe() }
  }
}

enum ApplicationIconChoice: String, CaseIterable, Hashable, Identifiable {
  case keycap
  case waveform

  static let persistenceKey = "ArkDeck.applicationIcon"
  static let defaultChoice = ApplicationIconChoice.waveform

  var id: String { rawValue }

  var imageAssetName: String {
    switch self {
    case .keycap: "ArkDeckKeycapIcon"
    case .waveform: "ArkDeckWaveformIcon"
    }
  }

  var title: String {
    switch self {
    case .keycap: settingsText("settings.general.appIcon.keycap")
    case .waveform: settingsText("settings.general.appIcon.waveform")
    }
  }

  var image: NSImage? {
    NSImage(named: NSImage.Name(imageAssetName))
  }

  @MainActor
  func apply() {
    guard let image else { return }
    NSApplication.shared.applicationIconImage = image
  }

  @MainActor
  static func applyStoredSelection() {
    let rawValue = UserDefaults.standard.string(forKey: persistenceKey)
    (rawValue.flatMap(ApplicationIconChoice.init(rawValue:)) ?? defaultChoice).apply()
  }
}

private struct ApplicationIconPicker: View {
  @Binding var selection: String
  @FocusState private var focusedChoice: ApplicationIconChoice?

  private var selectedChoice: ApplicationIconChoice {
    ApplicationIconChoice(rawValue: selection) ?? .defaultChoice
  }

  var body: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
      Text(settingsText("settings.general.appIcon.detail"))
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: WorkspaceMetrics.contentGap) {
        ForEach(ApplicationIconChoice.allCases) { choice in
          option(choice)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func option(_ choice: ApplicationIconChoice) -> some View {
    let isSelected = choice == selectedChoice
    let shape = RoundedRectangle(
      cornerRadius: WorkspaceMetrics.insetRadius)

    return Button {
      selection = choice.rawValue
      choice.apply()
    } label: {
      HStack(spacing: WorkspaceMetrics.contentGap) {
        ApplicationIconPreview(choice: choice)
        VStack(alignment: .leading, spacing: WorkspaceMetrics.tightGap) {
          Text(choice.title)
            .font(.headline)
          if isSelected {
            Label(
              settingsText("settings.general.appIcon.selected"),
              systemImage: "checkmark.circle.fill"
            )
            .font(.callout)
            .foregroundStyle(.tint)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(WorkspaceMetrics.contentGap)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(nsColor: .controlBackgroundColor), in: shape)
      .overlay {
        shape.strokeBorder(
          isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
          lineWidth: isSelected ? 2 : 1)
      }
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .focused($focusedChoice, equals: choice)
    .overlay {
      if focusedChoice == choice {
        shape.strokeBorder(Color.accentColor, lineWidth: 2)
      }
    }
    .accessibilityLabel(choice.title)
    .accessibilityValue(
      isSelected ? settingsText("settings.general.appIcon.selected") : ""
    )
    .accessibilityHint(settingsText("settings.general.appIcon.detail"))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("settings.general.appIcon.\(choice.rawValue)")
  }
}

private struct ApplicationIconPreview: View {
  let choice: ApplicationIconChoice

  var body: some View {
    Group {
      if let image = choice.image {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
      } else {
        Image(systemName: "app.dashed")
          .resizable()
          .scaledToFit()
          .padding(WorkspaceMetrics.tightGap)
      }
    }
    // Concentric: the preview sits inside the option tile (radius 9), so its
    // own corner is the next step down, not a larger 14.
    .frame(width: 40, height: 40)
    .background(
      Color(nsColor: .windowBackgroundColor),
      in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    }
    .accessibilityHidden(true)
  }
}

private struct ToolchainsSettingsPane: View {
  let presentation: HDCDiagnosticsPresentation
  let isRefreshInFlight: Bool
  let configurationError: String?
  let hasActiveRuntimeJobs: Bool
  let onRefresh: () -> Void
  let onSelectExecutable: (URL) -> Void
  @State private var isSelectingExecutable = false
  @State private var importerError: String?

  var body: some View {
    WorkspacePage {
      WorkspaceHeaderBar(summary: Text(settingsText("settings.toolchains.subtitle")))
      GroupBox(settingsText("settings.toolchains.hdc")) {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
          HStack(spacing: WorkspaceMetrics.tightGap) {
            Image(systemName: healthSymbol)
              .foregroundStyle(healthColor)
              .accessibilityHidden(true)
            Text(healthText)
              .font(WorkspaceFont.body.weight(.semibold))
            Spacer()
            if isRefreshInFlight {
              ProgressView()
                .controlSize(.small)
                .accessibilityLabel(settingsText("settings.common.refreshing"))
            }
          }
          WorkspaceFactGrid {
            settingsFact(
              "settings.toolchains.path", presentation.absolutePath, isMonospaced: true)
            settingsFact("settings.toolchains.source", presentation.source)
            settingsFact("settings.toolchains.sha256", presentation.hash, isMonospaced: true)
            settingsFact("settings.toolchains.trust", presentation.platformTrust)
            settingsFact("settings.toolchains.clientVersion", presentation.clientVersion)
            settingsFact("settings.toolchains.serverVersion", presentation.serverVersion)
            settingsFact("settings.toolchains.daemonVersion", presentation.daemonVersion)
            settingsFact("settings.toolchains.endpoint", presentation.endpoint)
          }
          Divider()
          HStack {
            if !presentation.isRuntimeManaged {
              Button(settingsText("settings.toolchains.choose")) {
                isSelectingExecutable = true
              }
              .accessibilityIdentifier("settings.toolchains.choose")
              .disabled(isRefreshInFlight)
            }
            Button(settingsText("settings.common.refresh"), action: onRefresh)
              .accessibilityIdentifier("settings.toolchains.refresh")
              .disabled(isRefreshInFlight)
            Spacer()
          }
          // The pane's main fact: a running Job keeps the toolchain pinned at
          // its creation; switching is never retroactive. While Jobs are
          // actually running the sentence escalates to a warn callout,
          // because that is the moment it can be misread.
          if hasActiveRuntimeJobs {
            Label {
              Text(settingsText("settings.toolchains.futureJobsActive"))
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            }
            .font(.callout)
            .padding(WorkspaceMetrics.contentGap)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
              RoundedRectangle(cornerRadius: WorkspaceMetrics.insetRadius)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .accessibilityIdentifier("settings.toolchains.activeJobsCallout")
          } else {
            Text(settingsText("settings.toolchains.futureJobs"))
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      if let error = importerError
        ?? (configurationError == nil
          ? nil : settingsText("settings.toolchains.selectionError"))
      {
        settingsErrorNotice(error)
      }
    }
    .fileImporter(
      isPresented: $isSelectingExecutable,
      allowedContentTypes: [.item],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        guard let url = urls.first else { return }
        importerError = nil
        onSelectExecutable(url)
      case .failure:
        importerError = settingsText("settings.toolchains.selectionError")
      }
    }
  }

  private var healthSymbol: String {
    // `unavailable` has its own text here but used to fall through to the
    // unknown glyph, so Settings and Overview disagreed about the same fact.
    switch presentation.serverHealth.rawValue.lowercased() {
    case "healthy": "checkmark.circle.fill"
    case "unhealthy": "exclamationmark.triangle.fill"
    case "unavailable": "xmark.octagon.fill"
    default: "questionmark.circle"
    }
  }

  private var healthText: String {
    switch presentation.serverHealth.rawValue.lowercased() {
    case "healthy": settingsText("settings.toolchains.health.healthy")
    case "unavailable": settingsText("settings.toolchains.health.unavailable")
    default: settingsText("settings.toolchains.health.unknown")
    }
  }

  private var healthColor: Color {
    switch presentation.serverHealth.rawValue.lowercased() {
    case "healthy": .green
    case "unhealthy": .orange
    case "unavailable": .red
    default: .secondary
    }
  }
}

private struct StorageSettingsPane: View {
  var model: SettingsWorkspaceViewModel
  @State private var quotaGiB = ""
  @State private var safetyMarginGiB = ""
  @State private var retentionDays = ""
  @State private var validationMessage: String?
  @State private var isSelectingRoot = false

  var body: some View {
    WorkspacePage {
      WorkspaceHeaderBar(summary: Text(settingsText("settings.storage.subtitle")))
      if let storage = model.presentation?.storage {
        GroupBox(settingsText("settings.storage.location")) {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
            WorkspaceFactGrid {
              settingsFact("settings.storage.root", storage.rootPath, isMonospaced: true)
              settingsFact(
                "settings.storage.rootSource",
                settingsText(
                  storage.usesCustomRoot
                    ? "settings.storage.rootSource.custom"
                    : "settings.storage.rootSource.default"))
            }
            HStack {
              Button(settingsText("settings.storage.chooseRoot")) {
                isSelectingRoot = true
              }
              .accessibilityIdentifier("settings.storage.chooseRoot")
              .disabled(model.isStorageBusy)
              Button(settingsText("settings.storage.resetRoot"), action: model.resetStorageRoot)
                .disabled(model.isStorageBusy || !storage.usesCustomRoot)
              Spacer()
            }
            Text(settingsText("settings.storage.futureJobs"))
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }

        GroupBox(settingsText("settings.storage.policy")) {
          VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
            // Not a WorkspaceFactGrid: these are three columns of editable
            // input (label, field, unit), not a read-only key/value list, and
            // rows of controls need the larger content gap to stay tappable.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: WorkspaceMetrics.keyColumnGap, verticalSpacing: WorkspaceMetrics.contentGap) {
              storageField(
                label: settingsText("settings.storage.quota"),
                value: $quotaGiB,
                suffix: settingsText("settings.storage.gib"),
                id: "settings.storage.quota")
              storageField(
                label: settingsText("settings.storage.margin"),
                value: $safetyMarginGiB,
                suffix: settingsText("settings.storage.gib"),
                id: "settings.storage.margin")
              storageField(
                label: settingsText("settings.storage.retention"),
                value: $retentionDays,
                suffix: settingsText("settings.storage.days"),
                id: "settings.storage.retention")
            }
            HStack {
              Button(settingsText("settings.storage.save"), action: savePolicy)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("settings.storage.save")
                .disabled(model.isStorageBusy)
              if model.isStorageBusy {
                ProgressView()
                  .controlSize(.small)
                  .accessibilityLabel(settingsText("settings.common.saving"))
              }
            }
            Text(settingsText("settings.storage.policyDetail"))
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }

        GroupBox(settingsText("settings.storage.runtimeUsage")) {
          runtimeArtifactUsage(storage)
        }

        GroupBox(settingsText("settings.storage.sessionUsage")) {
          sessionRootUsage(storage)
        }
      } else {
        SettingsUnavailableRow(model: model, refreshIdentifier: "settings.storage.refresh")
      }
      if let validationMessage {
        settingsErrorNotice(validationMessage)
      }
      // Save, root selection and reset report here, under the controls they
      // belong to. A refresh that failed before there was anything to show is
      // the unavailable row's to report, once.
      if model.presentation?.storage != nil, let error = model.storageError {
        settingsErrorNotice(error)
      }
    }
    .onAppear(perform: synchronizeDrafts)
    .onChange(of: model.presentation?.storage) { _, _ in synchronizeDrafts() }
    .fileImporter(
      isPresented: $isSelectingRoot,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        guard let url = urls.first else { return }
        validationMessage = nil
        model.selectStorageRoot(url)
      case .failure:
        validationMessage = settingsText("settings.storage.selectionError")
      }
    }
  }

  private func storageField(
    label: String,
    value: Binding<String>,
    suffix: String,
    id: String
  ) -> some View {
    GridRow {
      Text(label)
      HStack(spacing: WorkspaceMetrics.tightGap) {
        TextField(label, text: value)
          .frame(width: 110)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier(id)
        Text(suffix).foregroundStyle(.secondary)
      }
    }
  }

  /// The bytes the product actually writes. They are measured and bounded by
  /// the Runtime, which is why this reads its figure instead of counting a
  /// directory: the daemon's store sits outside this App's container.
  ///
  /// A Runtime that did not answer shows no number at all. Rendering silence as
  /// an empty store is the same mistake one level down from measuring the wrong
  /// directory: both produce a plausible figure about nothing.
  @ViewBuilder
  private func runtimeArtifactUsage(_ storage: SettingsStoragePresentation) -> some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
      if let artifacts = storage.runtimeArtifacts {
        ProgressView(
          value: Double(artifacts.usedBytes),
          total: Double(max(artifacts.totalBytes, 1))
        )
        .accessibilityLabel(settingsText("settings.storage.runtimeUsage"))
        .accessibilityValue(
          "\(storageBytes(artifacts.usedBytes)) / \(storageBytes(artifacts.totalBytes))")
        WorkspaceFactGrid {
          settingsFact("settings.storage.currentUsage", storageBytes(artifacts.usedBytes))
          settingsFact("settings.storage.runtimeTotal", storageBytes(artifacts.totalBytes))
          settingsFact("settings.storage.remaining", storageBytes(artifacts.remainingBytes))
        }
      } else {
        Label(
          settingsText("settings.storage.runtimeUnavailable"),
          systemImage: "questionmark.circle"
        )
        .foregroundStyle(.secondary)
      }
      Text(settingsText("settings.storage.runtimeUsage.detail"))
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  /// The other root: the one the policy above governs. Reported on its own so
  /// neither figure can be read as the whole product's storage.
  @ViewBuilder
  private func sessionRootUsage(_ storage: SettingsStoragePresentation) -> some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
      if let sessionRoot = storage.sessionRoot {
        WorkspaceFactGrid {
          settingsFact("settings.storage.currentUsage", storageBytes(sessionRoot.measuredBytes))
          settingsFact("settings.storage.pinned", pinnedSummary(sessionRoot))
        }
        if sessionRoot.unaccountedSessionCount > 0 {
          Label(unaccountedSummary(sessionRoot), systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        } else if sessionRoot.measurementIncomplete {
          Label(
            settingsText("settings.storage.unknownPressure"),
            systemImage: "exclamationmark.triangle"
          )
          .foregroundStyle(.orange)
        }
      } else {
        Label(
          settingsText("settings.storage.measurementUnavailable"),
          systemImage: "questionmark.circle"
        )
        .foregroundStyle(.secondary)
      }
      Text(settingsText("settings.storage.sessionUsage.detail"))
        .font(.callout)
        .foregroundStyle(.secondary)
      Text(settingsText("settings.storage.pinGuarantee"))
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private func storageBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
  }

  private func pinnedSummary(_ sessionRoot: SettingsSessionRootUsage) -> String {
    String(
      localized: LocalizedStringResource.SettingsLocalizable.settingsStoragePinnedFormat(
        sessionRoot.pinnedSessionCount, storageBytes(sessionRoot.pinnedBytes)))
  }

  private func unaccountedSummary(_ sessionRoot: SettingsSessionRootUsage) -> String {
    String(
      localized: LocalizedStringResource.SettingsLocalizable.settingsStorageUnaccountedFormat(
        sessionRoot.unaccountedSessionCount))
  }

  private func synchronizeDrafts() {
    guard let storage = model.presentation?.storage else { return }
    quotaGiB = String(storage.totalQuotaBytes / SettingsWorkspaceViewModel.gibibyte)
    safetyMarginGiB = String(storage.safetyMarginBytes / SettingsWorkspaceViewModel.gibibyte)
    retentionDays = String(storage.retentionDays)
    validationMessage = nil
  }

  private func savePolicy() {
    guard let quota = UInt64(quotaGiB), let margin = UInt64(safetyMarginGiB),
      let retention = UInt64(retentionDays),
      quota > margin, margin > 0, retention > 0,
      !quota.multipliedReportingOverflow(by: SettingsWorkspaceViewModel.gibibyte).overflow,
      !margin.multipliedReportingOverflow(by: SettingsWorkspaceViewModel.gibibyte).overflow
    else {
      validationMessage = settingsText("settings.storage.validationError")
      return
    }
    validationMessage = nil
    model.updateStoragePolicy(
      totalQuotaBytes: quota * SettingsWorkspaceViewModel.gibibyte,
      safetyMarginBytes: margin * SettingsWorkspaceViewModel.gibibyte,
      retentionDays: retention)
  }
}

private struct DiagnosticsSettingsPane: View {
  var model: SettingsWorkspaceViewModel

  var body: some View {
    WorkspacePage {
      WorkspaceHeaderBar(summary: Text(settingsText("settings.diagnostics.subtitle")))
      GroupBox(settingsText("settings.diagnostics.defaultScope")) {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
          SettingsAssuranceRow(
            icon: "checkmark.circle",
            title: settingsText("settings.diagnostics.metadata"),
            detail: settingsText("settings.diagnostics.metadata.detail"))
          SettingsAssuranceRow(
            icon: "eye.slash",
            title: settingsText("settings.diagnostics.redactedHDC"),
            detail: settingsText("settings.diagnostics.redactedHDC.detail"))
          SettingsAssuranceRow(
            icon: "nosign",
            title: settingsText("settings.diagnostics.rawExcluded"),
            detail: settingsText("settings.diagnostics.rawExcluded.detail"))
        }
      }
      GroupBox(settingsText("settings.diagnostics.export")) {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
          Text(settingsText("settings.diagnostics.previewFirst"))
            .fixedSize(horizontal: false, vertical: true)
          Button(settingsText("settings.diagnostics.chooseAndPreview"), action: chooseDestination)
            .accessibilityIdentifier("settings.diagnostics.preview")
            .disabled(model.isDiagnosticsBusy)
          if model.isDiagnosticsBusy {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel(settingsText("settings.common.working"))
          }
          if let destination = model.diagnosticDestination,
            let preview = model.diagnosticPreview
          {
            Divider()
            WorkspaceFactGrid {
              settingsFact(
                "settings.diagnostics.destination", destination.path, isMonospaced: true)
              settingsFact(
                "settings.diagnostics.size",
                ByteCountFormatter.string(
                  fromByteCount: Int64(clamping: preview.estimatedBytes),
                  countStyle: .file))
              settingsFact(
                "settings.diagnostics.scopeHash", preview.scopeSHA256, isMonospaced: true)
              settingsFact(
                "settings.diagnostics.deviceRaw",
                settingsText(
                  preview.deviceRawExcluded
                    ? "settings.diagnostics.excluded"
                    : "settings.diagnostics.notExcluded"))
            }
            VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
              Text(settingsText("settings.diagnostics.entries"))
                .font(WorkspaceFont.label)
              ForEach(preview.includedEntries, id: \.self) { entry in
                Label(entry, systemImage: "doc")
                  .font(.system(.callout, design: .monospaced))
              }
            }
            Label(
              settingsText("settings.diagnostics.warning"),
              systemImage: "exclamationmark.triangle"
            )
            .font(.callout)
            .foregroundStyle(.orange)
            HStack {
              Button(
                settingsText("settings.diagnostics.exportNow"), action: model.exportDiagnostics
              )
              .buttonStyle(.borderedProminent)
              .accessibilityIdentifier("settings.diagnostics.export")
              .disabled(
                model.isDiagnosticsBusy || model.exportedDiagnosticURL != nil
                  || !preview.deviceRawExcluded)
              if let exportedURL = model.exportedDiagnosticURL {
                Button(settingsText("settings.diagnostics.reveal")) {
                  NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                }
              }
            }
          }
          Text(settingsText("settings.diagnostics.noAutomaticUpload"))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if let message = model.diagnosticsMessage {
        if model.exportedDiagnosticURL != nil {
          WorkspaceNotice(tone: .ok, symbol: "checkmark.circle.fill") { Text(message) }
        } else {
          settingsErrorNotice(message)
        }
      }
    }
  }

  private func chooseDestination() {
    let panel = NSSavePanel()
    panel.title = settingsText("settings.diagnostics.panelTitle")
    panel.prompt = settingsText("settings.diagnostics.panelPrompt")
    panel.nameFieldStringValue = "ArkDeck-Diagnostics"
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    Task { @MainActor in
      guard await panel.begin() == .OK, let url = panel.url else { return }
      model.previewDiagnostics(at: url)
    }
  }
}

/// One row of a Settings key/value list. A path or a hash keeps the single-line
/// middle elision the pane has always used; everything else keeps its tabular
/// digits, and both stay selectable.
private func settingsFact(
  _ key: String, _ value: String, isMonospaced: Bool = false
) -> WorkspaceFactRow {
  WorkspaceFactRow(
    name: Text(settingsText(key)),
    value: Text(value),
    isMonospaced: isMonospaced,
    usesTabularDigits: !isMonospaced,
    isSelectable: true,
    elidedValue: isMonospaced ? value : nil)
}

private struct SettingsAssuranceRow: View {
  let icon: String
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: WorkspaceMetrics.contentGap) {
      Image(systemName: icon)
        .frame(width: 20)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
        Text(title).font(.headline)
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// The shared "could not be loaded" row: the notice the design's
/// `settings.error.refresh` row mirrors, with the Refresh action that row has
/// always carried there. A pane that needs the Runtime-backed presentation
/// and has none shows this rather than a spinner nothing will stop: the
/// refresh runs once, when the Settings scene appears, so a Runtime that was
/// unreachable at that moment used to stay unreachable until the window was
/// closed and reopened. Until the first refresh has reported, and while one
/// is in flight, the loading row stands in.
private struct SettingsUnavailableRow: View {
  var model: SettingsWorkspaceViewModel
  let refreshIdentifier: String

  var body: some View {
    if let error = model.storageError, !model.isRefreshing {
      VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
        settingsErrorNotice(error, identifier: "settings.error.refresh")
        Button(settingsText("settings.common.refresh"), action: model.refresh)
          .accessibilityIdentifier(refreshIdentifier)
      }
    } else {
      SettingsLoadingRow()
    }
  }
}

private struct SettingsLoadingRow: View {
  var body: some View {
    HStack(spacing: WorkspaceMetrics.tightGap) {
      ProgressView().controlSize(.small)
      Text(settingsText("settings.common.loading"))
    }
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
  }
}

/// Settings' failures are the App's warn notice, not a bordered line of orange
/// text: the tone's symbol, border and wash carry the state together, so colour
/// is never the only carrier (spec §2, §4.4).
private func settingsErrorNotice(_ message: String, identifier: String? = nil) -> some View {
  WorkspaceNotice(
    tone: .warning, symbol: "exclamationmark.triangle.fill", identifier: identifier
  ) {
    Text(message)
  }
}

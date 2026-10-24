import AppKit
import ArkDeckClientKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Device · device control.
///
/// Explicit preview refreshes bounded stills. The frame's age is always on screen, a
/// gesture is shown pending until the runtime answers, and an outcome the
/// runtime could not establish is shown as unknown rather than resolved one
/// way for the sake of a tidier list.
struct DeviceWorkspaceView: View {
  var model: DeviceWorkspaceViewModel
  @Bindable var recording: DeviceRecordingViewModel
  @FocusState private var screenFocused: Bool
  @State private var pointerFocusRequest = 0
  @State private var isSaveErrorPresented = false
  @State private var saveErrorMessage = ""
  @State private var isSavingRecording = false
  @State private var workspaceSize = CGSize.zero
  @State private var screenAvailableSize = CGSize.zero
  @State private var keyboardText = ""
  @State private var clipboardAllowed = false
  @State private var selectedDeviceKey: DeviceKeyboardKey = .enter

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      if workspaceSize.width >= 880 {
        HStack(spacing: 0) {
          screenPane
          Divider()
          ScrollView { inspector }
            .frame(width: 320)
            .accessibilityIdentifier("device.inspector.scroll")
        }
      } else {
        ScrollViewReader { scroll in
          ScrollView {
            VStack(spacing: 0) {
              screenPane
                .frame(height: min(420, max(160, workspaceSize.height - 140)))
                .id("device.screen")
              inspector
            }
          }
          .onChange(of: screenFocused) { _, focused in
            if focused { scroll.scrollTo("device.screen", anchor: .top) }
          }
          .onChange(of: pointerFocusRequest) { _, _ in
            scroll.scrollTo("device.screen", anchor: .top)
          }
        }
      }
      Divider()
      footer
    }
    .onGeometryChange(for: CGSize.self, of: { $0.size }) { workspaceSize = $0 }
    .task { await model.refresh() }
    .onDisappear { clearKeyboardDraft(); model.deactivate() }
    .onChange(of: model.target) { _, _ in clearKeyboardDraft() }
    .alert(
      deviceText("device.record.saveFailed"),
      isPresented: $isSaveErrorPresented
    ) {} message: {
      Text(saveErrorMessage)
    }
  }

  // MARK: - Toolbar

  private var toolbar: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(model.targetName)
          .font(WorkspaceFont.sectionTitle)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(model.targetName)
        Text(model.targetDetail)
          .font(WorkspaceFont.caption)
          .foregroundStyle(.secondary)
          .monospaced()
          .lineLimit(2)
          .truncationMode(.middle)
          .help(model.targetDetail)
      }
      Spacer(minLength: WorkspaceMetrics.tightGap)
      Button {
        Task { await model.captureScreen() }
      } label: {
        Label(
          model.isCapturing
            ? deviceText("device.screen.capturing") : deviceText("device.screen.capture"),
          systemImage: "camera")
      }
      .fixedSize()
      .disabled(!model.canCapture || recording.isBusy)
      .accessibilityIdentifier("device.capture")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  // MARK: - Screen

  private var screenPane: some View {
    ZStack {
      Color(nsColor: .windowBackgroundColor)
      if model.isOpeningHistoryScreen {
        ProgressView {
          Text("history.loading", tableName: "HistoryLocalizable")
        }
        .accessibilityIdentifier("device.history.loading")
      } else if let frame = model.frame, let image = NSImage(data: frame.imageData) {
        let rendered = Self.fittedSize(
          container: screenAvailableSize,
          aspect: CGFloat(frame.width) / CGFloat(frame.height))
        ZStack {
          Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .accessibilityLabel(deviceText("device.screen.picture"))
            .accessibilityIdentifier("device.screen.image")
          gestureSurface(frame: frame, rendered: rendered)
          if model.frameIsStale { staleOverlay }
          if screenFocused, model.canSendInput {
            Image(systemName: "plus.circle")
              .font(WorkspaceFont.sectionTitle)
              .imageScale(.large)
              .foregroundStyle(.white)
              .background(Circle().fill(.black.opacity(0.8)))
              .position(
                x: rendered.width * model.keyboardPointer.x,
                y: rendered.height * model.keyboardPointer.y)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
          if let marker = model.pendingMarker {
            touchMarker(marker, rendered: rendered, pending: true)
          } else if let marker = model.lastMarker {
            touchMarker(marker, rendered: rendered, pending: false)
          }
        }
        .frame(width: rendered.width, height: rendered.height)
        .clipped()
      } else {
        ContentUnavailableView {
          Label(deviceText("device.screen.empty.title"), systemImage: "iphone")
        } description: {
          Text(model.emptyMessage)
        }
        .accessibilityIdentifier("device.screen.empty")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onGeometryChange(for: CGSize.self, of: { $0.size }) { screenAvailableSize = $0 }
  }

  /// One transparent layer owns every pointer event. Stacked full-size
  /// containers otherwise swallow the clicks that were meant for the picture.
  private func gestureSurface(frame: DeviceScreenFrame, rendered: CGSize) -> some View {
    Color.clear
      .contentShape(.rect)
      .accessibilityIdentifier("device.screen.surface")
      .accessibilityLabel(deviceText("device.keyboard.title"))
      .accessibilityValue(keyboardPosition)
      .accessibilityHint(deviceText("device.keyboard.help"))
      .focusable()
      .focused($screenFocused)
      .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
        guard model.canSendInput, !recording.isBusy else { return .ignored }
        let step = press.modifiers.contains(.shift) ? 0.1 : 0.02
        switch press.key {
        case .upArrow: model.moveKeyboardPointer(dx: 0, dy: -step)
        case .downArrow: model.moveKeyboardPointer(dx: 0, dy: step)
        case .leftArrow: model.moveKeyboardPointer(dx: -step, dy: 0)
        case .rightArrow: model.moveKeyboardPointer(dx: step, dy: 0)
        default: return .ignored
        }
        return .handled
      }
      .onKeyPress(keys: [.return, .space, .escape], phases: .down) { press in
        guard model.canSendInput, !recording.isBusy else { return .ignored }
        if press.key == .escape { model.cancelKeyboardSwipe(); return .handled }
        if press.modifiers.contains(.shift) {
          if model.keyboardPointer.anchor == nil { model.beginKeyboardSwipe() }
          else { Task { await model.sendKeyboardGesture(.swipe) } }
        } else {
          let gesture: DeviceGesture = press.modifiers.contains(.option) ? .longPress : .tap
          Task { await model.sendKeyboardGesture(gesture) }
        }
        return .handled
      }
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in model.pointerMoved(to: value.location, rendered: rendered) }
          .onEnded { value in
            Task {
              await model.pointerEnded(
                start: value.startLocation, end: value.location,
                rendered: rendered, frame: frame)
            }
          }
      )
      // Keep keyboard focus on the picture while a request settles. The model
      // refuses busy/stale input; disabling the focusable surface would scroll
      // a compact workspace back to the inspector when its focus disappears.
  }

  /// The picture stays on screen - it is still the last thing the device is
  /// known to have shown - but it is marked, so nobody aims at it by mistake.
  private var staleOverlay: some View {
    VStack {
      HStack {
        Label(deviceText("device.stale.badge"), systemImage: "clock.badge.exclamationmark")
          .font(WorkspaceFont.label)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(.orange.opacity(0.85))
          .foregroundStyle(.white)
          .clipShape(.capsule)
          .padding(8)
        Spacer()
      }
      Spacer()
    }
    .allowsHitTesting(false)
    .accessibilityIdentifier("device.stale.badge")
  }

  private func touchMarker(
    _ marker: DeviceWorkspaceViewModel.Marker, rendered: CGSize, pending: Bool
  ) -> some View {
    // Pending is hollow, settled is filled: the difference is what tells a
    // person whether the device has answered yet, at a glance and without
    // reading the log.
    Circle()
      .strokeBorder(pending ? Color.orange : Color.orange.opacity(0.9), lineWidth: 2)
      .background(
        Circle().fill(pending ? Color.clear : Color.orange.opacity(0.25))
      )
      .frame(width: 26, height: 26)
      .position(
        x: rendered.width * marker.unitX,
        y: rendered.height * marker.unitY)
      .allowsHitTesting(false)
      .accessibilityIdentifier(pending ? "device.touch.pending" : "device.touch.settled")
  }

  // MARK: - Inspector

  private var inspector: some View {
    VStack(alignment: .leading, spacing: 0) {
      previewPane
      Divider()
      VStack(alignment: .leading, spacing: 8) {
        Text(deviceText("device.gestures.title"))
          .font(WorkspaceFont.sectionTitle)
        gestureRow("device.gestures.tap")
        gestureRow("device.gestures.longPress")
        gestureRow("device.gestures.swipe")
        Text(deviceText("device.keyboard.help"))
          .font(WorkspaceFont.caption)
          .foregroundStyle(.secondary)
        Text(keyboardPosition).font(WorkspaceFont.caption).monospacedDigit()
          .accessibilityIdentifier("device.keyboard.position")
        Button(deviceText("device.keyboard.focus")) { focusPointer() }
          .disabled(!model.canSendInput || recording.isBusy)
          .accessibilityIdentifier("device.keyboard.focus")
        HStack {
          Button(deviceText("device.gesture.tap")) { Task { await model.sendKeyboardGesture(.tap) } }
            .accessibilityIdentifier("device.keyboard.tap")
          Button(deviceText("device.gesture.longPress")) { Task { await model.sendKeyboardGesture(.longPress) } }
            .accessibilityIdentifier("device.keyboard.longPress")
        }
        .disabled(!model.canSendInput || recording.isBusy)
        Button(deviceText(model.keyboardPointer.anchor == nil ? "device.keyboard.swipeStart" : "device.keyboard.swipeEnd")) {
          if model.keyboardPointer.anchor == nil { model.beginKeyboardSwipe(); focusPointer() }
          else { Task { await model.sendKeyboardGesture(.swipe) } }
        }
        .disabled(!model.canSendInput || recording.isBusy)
        .accessibilityIdentifier("device.keyboard.swipe")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
      Divider()
      deviceKeyboardPane
      Divider()
      recordingPane
      Divider()
      VStack(alignment: .leading, spacing: 8) {
        Text(deviceText("device.log.title"))
          .font(WorkspaceFont.sectionTitle)
        if model.log.isEmpty {
          Text(deviceText("device.log.empty"))
            .font(WorkspaceFont.caption)
            .foregroundStyle(.secondary)
        } else {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(model.log) { entry in logRow(entry) }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
      Spacer()
      Divider()
      performanceNotice
    }
  }

  private var keyboardPosition: String {
    guard let frame = model.frame,
      let request = model.keyboardPointer.request(.tap, frame: frame)
    else { return deviceText("device.frame.none") }
    return "X \(request.x) · Y \(request.y)"
  }

  private var deviceKeyboardPane: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(deviceText("device.input.title")).font(WorkspaceFont.sectionTitle)
      Text(deviceText("device.input.focusHelp"))
        .font(WorkspaceFont.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Picker(deviceText("device.input.key"), selection: $selectedDeviceKey) {
        ForEach(DeviceKeyboardKey.allCases, id: \.self) { key in
          Text(deviceText("device.input.key.\(key.rawValue)")).tag(key)
        }
      }
      .accessibilityIdentifier("device.input.key")
      Button(deviceText("device.input.sendKey")) {
        let command = DeviceKeyboardCommand.key(selectedDeviceKey)
        Task { await model.sendDeviceKeyboard(command) }
      }
      .disabled(!model.canSendInput || recording.isBusy)
      .accessibilityIdentifier("device.input.sendKey")
      SecureField(deviceText("device.input.text"), text: $keyboardText)
        .textFieldStyle(.roundedBorder)
        .privacySensitive()
        .accessibilityIdentifier("device.input.text")
      Text("\(keyboardText.utf8.count)/512 UTF-8")
        .font(WorkspaceFont.caption).monospacedDigit().foregroundStyle(.secondary)
      Toggle(deviceText("device.input.clipboardConsent"), isOn: $clipboardAllowed)
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("device.input.clipboardConsent")
      Text(deviceText("device.input.privacyHelp"))
        .font(WorkspaceFont.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button(deviceText("device.input.sendText")) {
        let command = DeviceKeyboardCommand.text(keyboardText, allowDeviceClipboard: clipboardAllowed)
        clearKeyboardDraft()
        Task { await model.sendDeviceKeyboard(command) }
      }
      .disabled(!model.canSendInput || recording.isBusy
        || !DeviceKeyboardCommand.text(keyboardText, allowDeviceClipboard: clipboardAllowed).isValid)
      .accessibilityIdentifier("device.input.sendText")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
  }

  private func clearKeyboardDraft() {
    keyboardText = ""
    clipboardAllowed = false
  }

  private func focusPointer() {
    screenFocused = true
    // A mouse scroll need not resign keyboard focus. Repeating the command
    // must reveal the picture even when it was already the keyboard target.
    pointerFocusRequest &+= 1
  }

  private var previewPane: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        if model.preview.isRunning { model.preview.stop() }
        else { Task { await model.startPreview() } }
      } label: {
        Label(
          deviceText(model.preview.isRunning ? "device.preview.stop" : "device.preview.start"),
          systemImage: model.preview.isRunning ? "pause.circle" : "play.circle")
      }
      .disabled(!model.preview.isRunning && (!model.canCapture || recording.isBusy))
      .accessibilityIdentifier("device.preview.toggle")
      Text(model.previewStatus)
        .font(WorkspaceFont.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("device.preview.status")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
  }

  /// What watching costs.
  ///
  /// It carries no dismiss control on purpose. A person reading a device is
  /// measuring something, and capturing moves what they are measuring:
  /// measured on hardware, a 30-frame run took the device's one-minute load
  /// average from 2.00 to 2.24 with a second runnable process appearing. A
  /// notice that can be closed is a notice that is absent exactly when
  /// somebody has been using the workspace long enough for it to matter.
  private var performanceNotice: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "gauge.with.dots.needle.33percent")
        .font(WorkspaceFont.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(deviceText("device.performance.title"))
          .font(WorkspaceFont.label)
        Text(deviceText("device.performance.detail"))
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("device.performance")
  }

  private func gestureRow(_ key: String) -> some View {
    Text(deviceText(key))
      .font(WorkspaceFont.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func logRow(_ entry: DeviceWorkspaceViewModel.LogEntry) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: entry.systemImage)
        .foregroundStyle(entry.tint)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.title).font(WorkspaceFont.label)
        Text(entry.detail)
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .monospaced()
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    // One row is one thing that happened, so it reads as one element rather
    // than as a title and a detail a reader has to stitch back together.
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(entry.isRefusal ? "device.log.refused" : "device.log.entry")
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: 12) {
      Label(model.frameAgeSummary, systemImage: "clock")
        .font(WorkspaceFont.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("device.frame.age")
      Spacer()
      Text(deviceText("device.boundary"))
        .font(WorkspaceFont.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("device.boundary")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
  }


  // MARK: - Recording

  /// The device offers no recorder, so this is a run of stills composed on
  /// this side. The pane says so rather than letting the word "record" imply
  /// a video rate the platform cannot give.
  private var recordingPane: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text(deviceText("device.record.title"))
          .font(WorkspaceFont.sectionTitle)
        Spacer()
        if recording.isBusy { ProgressView().controlSize(.small) }
      }

      // Frames, not seconds: the rate belongs to the device's readback and
      // cannot be asked for, so the only honest control is how many stills.
      HStack(spacing: 8) {
        Stepper(
          value: $recording.frameCount,
          in: 2...300, step: 10
        ) {
          Text("\(recording.frameCount) \(deviceText("device.record.frames"))")
            .font(WorkspaceFont.caption)
            .monospacedDigit()
        }
        .disabled(recording.isBusy)
        .accessibilityIdentifier("device.record.frames")
      }

      Button {
        Task { await model.recordScreen(using: recording) }
      } label: {
        Label(recording.stageTitle, systemImage: "record.circle")
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .disabled(recording.isBusy || model.isCapturing || model.isSendingGesture || model.preview.isBusy)
      .accessibilityIdentifier("device.record.start")

      // Said, not swallowed, and said alongside whatever the run is doing:
      // "nothing was measured" is a different thing from "there is room", and
      // only one of them is a check. It no longer stops the run - see
      // `headroomUnchecked`.
      if recording.headroomUnchecked {
        Label(
          deviceText("device.record.headroomUnknown"),
          systemImage: "questionmark.circle")
          .font(.system(size: 10))
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("device.record.headroomUnknown")
      }

      switch recording.stage {
      case .preflighting, .capturing, .assembling, .validating:
        Text(recording.stageTitle)
          .font(WorkspaceFont.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("device.record.stage")
      case .ready(let ready):
        readyBar(ready)
      case .failed(let reason):
        Text(reason)
          .font(WorkspaceFont.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("device.record.failed")
      case .refused(let refusal):
        refusalBar(refusal)
      case .idle:
        Text(deviceText("device.record.ceiling"))
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
  }

  /// Both numbers on one line. Split out of the view body because the
  /// concatenation there was past what the type checker would take.
  static func headroomSummary(_ refusal: DeviceRecordingBudget.Refusal) -> String {
    let needed = refusal.neededBytes.formatted(.byteCount(style: .file))
    let free = refusal.remainingBytes.formatted(.byteCount(style: .file))
    return "\(deviceText("device.record.needs")) \(needed) · "
      + "\(free) \(deviceText("device.record.free"))"
  }

  /// Refused before anything started. It names both numbers, because "no
  /// room" that names none cannot be acted on, and it offers the longest run
  /// that would fit rather than only saying no.
  private func refusalBar(_ refusal: DeviceRecordingBudget.Refusal) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      refusalText(refusal)
      if refusal.framesThatWouldFit >= 2 {
        Button {
          recording.shrinkToFit(refusal)
        } label: {
          Text(
            "\(refusal.framesThatWouldFit) \(deviceText("device.record.frames")) "
              + deviceText("device.record.wouldFit"))
            .font(WorkspaceFont.caption)
        }
        .font(WorkspaceFont.caption)
        .buttonStyle(.link)
        .accessibilityIdentifier("device.record.shrink")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The refusal's prose, combined into one element so it reads as one
  /// statement. The button that acts on it stays outside: combining children
  /// swallows a control, and a refusal whose only remedy is unreachable is
  /// back to offering nothing.
  private func refusalText(_ refusal: DeviceRecordingBudget.Refusal) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(
        deviceText("device.record.noRoom"), systemImage: "externaldrive.badge.exclamationmark")
        .font(WorkspaceFont.label)
        .foregroundStyle(.orange)
      Text(Self.headroomSummary(refusal))
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(.secondary)
      Text(deviceText("device.record.noRoom.detail"))
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("device.record.refused")
  }

  /// What the run achieved and where it went. The rate is measured off the
  /// movie's own span, never a target, because the device sets it.
  private func readyBar(_ ready: DeviceRecordingViewModel.Ready) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        Text(
          "\(ready.frameCount) \(deviceText("device.record.frames")) · "
            + ready.framesPerSecond.formatted(
              .number.precision(.fractionLength(2))) + " fps "
            + deviceText("device.record.rate"))
          .font(WorkspaceFont.label)
          .monospacedDigit()
      }
      // One result is one thing, so it reads as one element rather than as an
      // icon and a sentence a reader has to stitch back together.
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("device.record.ready")

      if ready.framesMissing > 0 {
        Label(
          "\(ready.framesMissing) \(deviceText("device.record.gap"))",
          systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 10))
          .foregroundStyle(.orange)
          .accessibilityIdentifier("device.record.gap")
      }

      Text(ready.url.path)
        .font(.system(size: 10))
        .monospaced()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityIdentifier("device.record.location")

      Text(deviceText("device.record.timeline"))
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 8) {
        Button(deviceText("device.record.reveal")) {
          NSWorkspace.shared.activateFileViewerSelecting([ready.url])
        }
        .accessibilityIdentifier("device.record.reveal")
        Button(deviceText("device.record.saveAs")) { save(ready) }
          .accessibilityIdentifier("device.record.saveAs")
          .disabled(isSavingRecording)
        Button(deviceText("device.record.again")) { recording.reset() }
          .accessibilityIdentifier("device.record.again")
      }
      .font(WorkspaceFont.caption)
      .buttonStyle(.link)
    }
  }

  /// Copied, never moved: the composed file stays where the workspace can
  /// still show it if the copy is cancelled or fails.
  private func save(_ ready: DeviceRecordingViewModel.Ready) {
    guard !isSavingRecording else { return }
    isSavingRecording = true
    let panel = NSSavePanel()
    panel.nameFieldStringValue = ready.url.lastPathComponent
    panel.allowedContentTypes = [.quickTimeMovie]
    Task { @MainActor in
      defer { isSavingRecording = false }
      guard await panel.begin() == .OK, let destination = panel.url else { return }
      do {
        try await DeviceRecordingExport.copy(from: ready.url, to: destination)
      } catch {
        saveErrorMessage = error.localizedDescription
        isSaveErrorPresented = true
      }
    }
  }

  /// The image is framed at exactly this size, so the gesture layer's
  /// coordinate space is the picture itself and no letterbox offset ever
  /// enters the mapping.
  static func fittedSize(container: CGSize, aspect: CGFloat) -> CGSize {
    guard aspect > 0 else { return .zero }
    let width = min(container.width - 24, (container.height - 24) * aspect)
    return CGSize(width: max(1, width), height: max(1, width / aspect))
  }
}

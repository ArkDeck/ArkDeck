import AppKit
import ArkDeckWorkflows
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Toolkit · device control.
///
/// The picture is a still, not a live view. Everything here is arranged so a
/// person can tell the difference: the frame's age is always on screen, a
/// gesture is shown pending until the runtime answers, and an outcome the
/// runtime could not establish is shown as unknown rather than resolved one
/// way for the sake of a tidier list.
struct ToolkitWorkspaceView: View {
  var model: ToolkitWorkspaceViewModel
  var recording: ToolkitRecordingViewModel

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        toolbar
        Divider()
        if geometry.size.width >= 880 {
          HStack(spacing: 0) {
            screenPane
            Divider()
            inspector.frame(width: 320)
          }
        } else {
          ScrollView { VStack(spacing: 0) { screenPane.frame(height: 420); inspector } }
        }
        Divider()
        footer
      }
    }
    .task { await model.refresh() }
  }

  // MARK: - Toolbar

  private var toolbar: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(model.targetName)
          .font(.system(size: 13, weight: .semibold))
        Text(model.targetDetail)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .monospaced()
      }
      Spacer()
      Button {
        Task { await model.captureScreen() }
      } label: {
        Label(
          model.isCapturing
            ? toolkitText("toolkit.screen.capturing") : toolkitText("toolkit.screen.capture"),
          systemImage: "camera")
      }
      .disabled(!model.canCapture || model.isCapturing)
      .accessibilityIdentifier("toolkit.capture")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  // MARK: - Screen

  private var screenPane: some View {
    GeometryReader { proxy in
      ZStack {
        Color(nsColor: .windowBackgroundColor)
        if let frame = model.frame, let image = NSImage(data: frame.imageData) {
          let rendered = Self.fittedSize(
            container: proxy.size,
            aspect: CGFloat(frame.width) / CGFloat(frame.height))
          ZStack {
            Image(nsImage: image)
              .resizable()
              .interpolation(.high)
              .scaledToFit()
            gestureSurface(frame: frame, rendered: rendered)
            if model.frameIsStale { staleOverlay }
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
            Label(toolkitText("toolkit.screen.empty.title"), systemImage: "iphone")
          } description: {
            Text(model.emptyMessage)
          }
          .accessibilityIdentifier("toolkit.screen.empty")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// One transparent layer owns every pointer event. Stacked full-size
  /// containers otherwise swallow the clicks that were meant for the picture.
  private func gestureSurface(frame: ToolkitScreenFrame, rendered: CGSize) -> some View {
    Color.clear
      .contentShape(Rectangle())
      .accessibilityIdentifier("toolkit.screen.surface")
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
      .disabled(model.isSendingGesture)
  }

  /// The picture stays on screen - it is still the last thing the device is
  /// known to have shown - but it is marked, so nobody aims at it by mistake.
  private var staleOverlay: some View {
    VStack {
      HStack {
        Label(toolkitText("toolkit.stale.badge"), systemImage: "clock.badge.exclamationmark")
          .font(.system(size: 11, weight: .medium))
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(.orange.opacity(0.85))
          .foregroundStyle(.white)
          .clipShape(Capsule())
          .padding(8)
        Spacer()
      }
      Spacer()
    }
    .allowsHitTesting(false)
    .accessibilityIdentifier("toolkit.stale.badge")
  }

  private func touchMarker(
    _ marker: ToolkitWorkspaceViewModel.Marker, rendered: CGSize, pending: Bool
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
      .accessibilityIdentifier(pending ? "toolkit.touch.pending" : "toolkit.touch.settled")
  }

  // MARK: - Inspector

  private var inspector: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        Text(toolkitText("toolkit.gestures.title"))
          .font(.system(size: 13, weight: .semibold))
        gestureRow("toolkit.gestures.tap")
        gestureRow("toolkit.gestures.longPress")
        gestureRow("toolkit.gestures.swipe")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
      Divider()
      recordingPane
      Divider()
      VStack(alignment: .leading, spacing: 8) {
        Text(toolkitText("toolkit.log.title"))
          .font(.system(size: 13, weight: .semibold))
        if model.log.isEmpty {
          Text(toolkitText("toolkit.log.empty"))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        } else {
          ScrollView {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(model.log) { entry in logRow(entry) }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
      Spacer()
    }
  }

  private func gestureRow(_ key: String) -> some View {
    Text(toolkitText(key))
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func logRow(_ entry: ToolkitWorkspaceViewModel.LogEntry) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: entry.systemImage)
        .foregroundStyle(entry.tint)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.title).font(.system(size: 11, weight: .medium))
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
    .accessibilityIdentifier(entry.isRefusal ? "toolkit.log.refused" : "toolkit.log.entry")
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: 12) {
      Label(model.frameAgeSummary, systemImage: "clock")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("toolkit.frame.age")
      Spacer()
      Text(toolkitText("toolkit.boundary"))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("toolkit.boundary")
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
        Text(toolkitText("toolkit.record.title"))
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        if recording.isBusy { ProgressView().controlSize(.small) }
      }

      // Frames, not seconds: the rate belongs to the device's readback and
      // cannot be asked for, so the only honest control is how many stills.
      HStack(spacing: 8) {
        Stepper(
          value: Binding(get: { recording.frameCount }, set: { recording.frameCount = $0 }),
          in: 2...300, step: 10
        ) {
          Text("\(recording.frameCount) \(toolkitText("toolkit.record.frames"))")
            .font(.system(size: 11))
            .monospacedDigit()
        }
        .disabled(recording.isBusy)
        .accessibilityIdentifier("toolkit.record.frames")
      }

      Button {
        Task { await recording.record(target: model.target) }
      } label: {
        Label(recording.stageTitle, systemImage: "record.circle")
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .disabled(recording.isBusy)
      .accessibilityIdentifier("toolkit.record.start")

      switch recording.stage {
      case .capturing, .assembling, .validating:
        Text(recording.stageTitle)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("toolkit.record.stage")
      case .ready(let ready):
        readyBar(ready)
      case .failed(let reason):
        Text(reason)
          .font(.system(size: 11))
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("toolkit.record.failed")
      case .refused(let refusal):
        refusalBar(refusal)
      case .headroomUnknown:
        // Said, not swallowed: "nothing was measured" is a different thing
        // from "there is room", and only one of them is a check.
        Label(
          toolkitText("toolkit.record.headroomUnknown"),
          systemImage: "questionmark.circle")
          .font(.system(size: 10))
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("toolkit.record.headroomUnknown")
      case .idle:
        Text(toolkitText("toolkit.record.ceiling"))
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
  static func headroomSummary(_ refusal: ToolkitRecordingBudget.Refusal) -> String {
    let needed = refusal.neededBytes.formatted(.byteCount(style: .file))
    let free = refusal.remainingBytes.formatted(.byteCount(style: .file))
    return "\(toolkitText("toolkit.record.needs")) \(needed) · "
      + "\(free) \(toolkitText("toolkit.record.free"))"
  }

  /// Refused before anything started. It names both numbers, because "no
  /// room" that names none cannot be acted on, and it offers the longest run
  /// that would fit rather than only saying no.
  private func refusalBar(_ refusal: ToolkitRecordingBudget.Refusal) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(
        toolkitText("toolkit.record.noRoom"), systemImage: "externaldrive.badge.exclamationmark")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.orange)
      Text(Self.headroomSummary(refusal))
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(.secondary)
      Text(toolkitText("toolkit.record.noRoom.detail"))
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if refusal.framesThatWouldFit >= 2 {
        Button {
          recording.shrinkToFit(refusal)
        } label: {
          Text(
            "\(refusal.framesThatWouldFit) \(toolkitText("toolkit.record.frames")) "
              + toolkitText("toolkit.record.wouldFit"))
            .font(.system(size: 11))
        }
        .font(.system(size: 11))
        .buttonStyle(.link)
        .accessibilityIdentifier("toolkit.record.shrink")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("toolkit.record.refused")
  }

  /// What the run achieved and where it went. The rate is measured off the
  /// movie's own span, never a target, because the device sets it.
  private func readyBar(_ ready: ToolkitRecordingViewModel.Ready) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        Text(
          "\(ready.frameCount) \(toolkitText("toolkit.record.frames")) · "
            + ready.framesPerSecond.formatted(
              .number.precision(.fractionLength(2))) + " fps "
            + toolkitText("toolkit.record.rate"))
          .font(.system(size: 11, weight: .medium))
          .monospacedDigit()
      }
      // One result is one thing, so it reads as one element rather than as an
      // icon and a sentence a reader has to stitch back together.
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("toolkit.record.ready")

      if ready.framesMissing > 0 {
        Label(
          "\(ready.framesMissing) \(toolkitText("toolkit.record.gap"))",
          systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 10))
          .foregroundStyle(.orange)
          .accessibilityIdentifier("toolkit.record.gap")
      }

      Text(ready.url.path)
        .font(.system(size: 10))
        .monospaced()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityIdentifier("toolkit.record.location")

      Text(toolkitText("toolkit.record.timeline"))
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 8) {
        Button(toolkitText("toolkit.record.reveal")) {
          NSWorkspace.shared.activateFileViewerSelecting([ready.url])
        }
        .accessibilityIdentifier("toolkit.record.reveal")
        Button(toolkitText("toolkit.record.saveAs")) { save(ready) }
          .accessibilityIdentifier("toolkit.record.saveAs")
        Button(toolkitText("toolkit.record.again")) { recording.reset() }
          .accessibilityIdentifier("toolkit.record.again")
      }
      .font(.system(size: 11))
      .buttonStyle(.link)
    }
  }

  /// Copied, never moved: the composed file stays where the workspace can
  /// still show it if the copy is cancelled or fails.
  private func save(_ ready: ToolkitRecordingViewModel.Ready) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = ready.url.lastPathComponent
    panel.allowedContentTypes = [.quickTimeMovie]
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    try? FileManager.default.removeItem(at: destination)
    try? FileManager.default.copyItem(at: ready.url, to: destination)
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

import AppKit
import ArkDeckWorkflows
import Observation
import SwiftUI

/// Toolkit · device control.
///
/// The picture is a still, not a live view. Everything here is arranged so a
/// person can tell the difference: the frame's age is always on screen, a
/// gesture is shown pending until the runtime answers, and an outcome the
/// runtime could not establish is shown as unknown rather than resolved one
/// way for the sake of a tidier list.
struct ToolkitWorkspaceView: View {
  var model: ToolkitWorkspaceViewModel

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

  /// The image is framed at exactly this size, so the gesture layer's
  /// coordinate space is the picture itself and no letterbox offset ever
  /// enters the mapping.
  static func fittedSize(container: CGSize, aspect: CGFloat) -> CGSize {
    guard aspect > 0 else { return .zero }
    let width = min(container.width - 24, (container.height - 24) * aspect)
    return CGSize(width: max(1, width), height: max(1, width / aspect))
  }
}

import AppKit
import ArkDeckWorkflows
import Observation
import SwiftUI

/// A Job-bound inspection surface. It deliberately has no command, argv,
/// remote-path, Recipe, or parameter-policy input.
struct UIDumpWorkspaceView: View {
  var model: UIDumpWorkspaceViewModel

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        toolbar
        Divider()
        if let capture = model.capture {
          if geometry.size.width >= 880 {
            HStack(spacing: 0) {
              screenshot(capture)
              Divider()
              inspector(capture)
            }
          } else {
            ScrollView {
              VStack(spacing: 0) {
                screenshot(capture).frame(minHeight: 420)
                Divider()
                inspector(capture).frame(minHeight: 520)
              }
            }
          }
        } else {
          emptyState
        }
      }
    }
    .task { model.refresh() }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { model.refresh() } label: {
          Label("Refresh Viewer", systemImage: "arrow.clockwise")
        }
        .disabled(model.isRefreshing || model.isCapturing)
        .accessibilityIdentifier("viewer.refresh")
      }
    }
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      Text("Viewer").font(.title2.weight(.semibold))
      Picker("Exact target", selection: targetBinding) {
        Text("No target").tag("")
        ForEach(model.workspace.targets) { target in
          Text(target.pickerTitle).tag(target.id)
        }
      }
      .frame(maxWidth: 220)
      .accessibilityIdentifier("viewer.target")

      if let capture = model.capture {
        Picker("Current screen", selection: rootBinding) {
          ForEach(capture.roots, id: \.self) { identity in
            Text(model.nodeTitle(identity) ?? "Current screen").tag(identity)
          }
        }
        .frame(maxWidth: 190)
        Text(capture.identity.capturedAtUTC)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .help(capture.identity.capturedAtUTC)
      }

      Spacer(minLength: 8)
      TextField("Search component, ID, or text", text: queryBinding)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 250)
        .accessibilityIdentifier("viewer.search")
      Toggle("Show component bounds", isOn: boundsBinding)
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("viewer.showBounds")
      Button { model.recapture() } label: {
        Label(model.isCapturing ? "Capturing…" : "Recapture", systemImage: "camera.viewfinder")
      }
      .buttonStyle(.borderedProminent)
      .disabled(!model.canRecapture)
      .accessibilityIdentifier("viewer.recapture")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "rectangle.on.rectangle.angled")
        .font(.largeTitle).foregroundStyle(.secondary)
      Text("No verified capture").font(.title3.weight(.semibold))
      Text(model.emptyMessage)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 480)
      if let failure = model.captureFailure {
        Label(failure, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("viewer.captureFailure")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }

  private func screenshot(_ capture: ViewerCapture) -> some View {
    VStack(spacing: 0) {
      paneHeader("Device screenshot", detail: capture.coordinatesAreVerified
        ? "Verified capture · Click to inspect"
        : "Coordinates cannot be verified")
      GeometryReader { proxy in
        ZStack {
          Color(nsColor: .windowBackgroundColor)
          if let image = NSImage(data: capture.screenshotData) {
            let content = fittedSize(
              container: proxy.size,
              aspect: CGFloat(capture.screenshotWidth) / CGFloat(capture.screenshotHeight))
            ZStack {
              Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
              if capture.coordinatesAreVerified {
                ForEach(model.screenshotNodes(capture)) { node in
                  screenshotRegion(node, in: capture, content: content)
                }
                screenshotHitTest(capture, content: content)
              }
            }
            .frame(width: content.width, height: content.height)
          } else {
            ContentUnavailableView("Screenshot is unavailable", systemImage: "photo")
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      if !capture.coordinatesAreVerified {
        Label("The tree bounds do not prove this screenshot's coordinate space. Tree and Raw dump remain available, but screenshot selection is disabled.", systemImage: "exclamationmark.triangle")
          .font(.footnote)
          .foregroundStyle(.orange)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("viewer.screenshot")
  }

  @ViewBuilder
  private func screenshotRegion(
    _ node: ViewerNode,
    in capture: ViewerCapture,
    content: CGSize
  ) -> some View {
    if let bounds = node.bounds {
      let selected = node.identity == model.selectedNodeIdentity
      if model.showBounds || selected {
        ZStack(alignment: .topTrailing) {
          Rectangle()
            .fill(selected ? Color.accentColor.opacity(0.10) : .clear)
            .overlay {
              Rectangle().stroke(
                selected ? Color.accentColor : Color.accentColor.opacity(0.35),
                lineWidth: selected ? 2 : 1)
            }
          if selected {
            Text("#\(node.deviceID ?? "—") \(node.type)")
              .font(.caption2.monospaced())
              .padding(.horizontal, 4).padding(.vertical, 2)
              .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 3))
              .foregroundStyle(Color.primary)
            .fixedSize()
          }
        }
        .frame(
          width: max(1, content.width * bounds.width / Double(capture.screenshotWidth)),
          height: max(1, content.height * bounds.height / Double(capture.screenshotHeight)))
        .position(
          x: content.width * (bounds.x + bounds.width / 2) / Double(capture.screenshotWidth),
          y: content.height * (bounds.y + bounds.height / 2) / Double(capture.screenshotHeight))
        .zIndex(Double(node.depth) + (node.zIndex ?? 0))
        // The visual bounds must never compete with the single coordinate
        // hit target below. Hundreds of transparent native buttons made the
        // screenshot appear unclickable when bounds were hidden.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
    }
  }

  /// The tree remains the keyboard-accessible component selector. This
  /// surface gives pointer users one stable coordinate target regardless of
  /// whether visual bounds are currently shown.
  private func screenshotHitTest(_ capture: ViewerCapture, content: CGSize) -> some View {
    Color.clear
      .contentShape(Rectangle())
      .gesture(SpatialTapGesture().onEnded { value in
        model.select(in: capture, at: value.location, renderedSize: content)
      })
      .accessibilityLabel("Select component in screenshot")
      .accessibilityHint("Use the UI tree to select a component with the keyboard.")
      .accessibilityIdentifier("viewer.screenshot.hitTest")
  }

  private func inspector(_ capture: ViewerCapture) -> some View {
    GeometryReader { proxy in
      let treeHeight = max(150, proxy.size.height * model.inspectorTreePercent / 100)
      VStack(spacing: 0) {
        tree(capture).frame(height: treeHeight)
        resizeHandle
        properties(capture).frame(maxHeight: .infinity)
      }
    }
    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("viewer.inspector")
  }

  private func tree(_ capture: ViewerCapture) -> some View {
    let rows = model.visibleNodes
    return VStack(spacing: 0) {
      HStack {
        paneHeader("UI tree", detail: "\(rows.count) / \(capture.nodes.count) matches")
        Spacer()
      }
      ScrollViewReader { reader in
        ScrollView([.horizontal, .vertical]) {
          LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(rows) { node in
              treeRow(node)
                .id(node.identity)
            }
            if rows.isEmpty {
              Text("No matching components. The current selection is unchanged.")
                .foregroundStyle(.secondary).padding(12)
            }
          }
          .padding(6)
        }
        .onChange(of: model.selectedNodeIdentity) { _, identity in
          guard let identity else { return }
          withAnimation(.easeOut(duration: 0.15)) { reader.scrollTo(identity, anchor: .center) }
        }
      }
    }
    .accessibilityIdentifier("viewer.tree")
  }

  private func treeRow(_ node: ViewerNode) -> some View {
    let selected = node.identity == model.selectedNodeIdentity
    return HStack(spacing: 5) {
      if !node.children.isEmpty {
        Button { model.toggleExpansion(node.identity) } label: {
          Image(systemName: model.expandedNodeIdentities.contains(node.identity) ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold)).frame(width: 16, height: 20)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.expandedNodeIdentities.contains(node.identity) ? "Collapse \(node.type)" : "Expand \(node.type)")
      } else {
        Color.clear.frame(width: 16, height: 20)
      }
      Button { model.select(node.identity) } label: {
        HStack(spacing: 5) {
          Image(systemName: "square.dashed").foregroundStyle(.secondary)
          Text(node.type).font(.callout.monospaced()).lineLimit(1)
          if let text = node.text, !text.isEmpty { Text(text).foregroundStyle(.secondary).lineLimit(1) }
          if let id = node.deviceID { Text("#\(id)").font(.caption.monospaced()).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 6).frame(minHeight: 24, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
      }
      .buttonStyle(.plain)
      .accessibilityValue(selected ? "Selected" : "Not selected")
      .accessibilityIdentifier("viewer.tree.node.\(node.identity)")
    }
    .padding(.leading, CGFloat(node.depth) * 14)
  }

  private var resizeHandle: some View {
    Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.8)).frame(height: 7)
      .overlay(Capsule().fill(Color.secondary.opacity(0.65)).frame(width: 36, height: 2))
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0).onChanged { value in
        model.adjustInspectorTree(by: value.translation.height)
      })
      .focusable()
      .accessibilityLabel("Resize UI tree and node properties")
      .accessibilityValue("UI tree uses \(Int(model.inspectorTreePercent)) percent of the inspector")
      .accessibilityAdjustableAction { direction in
        model.adjustInspectorTree(by: direction == .increment ? -4 : 4)
      }
      .accessibilityIdentifier("viewer.inspector.separator")
  }

  private func properties(_ capture: ViewerCapture) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if let node = model.selectedNode {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(node.type).font(.headline)
            if let id = node.deviceID { Text("#\(id)").font(.headline.monospaced()) }
            Spacer()
            if node.visible { Label("Visible", systemImage: "eye") }
            if node.clickable == true { Label("Interactive", systemImage: "hand.tap") }
          }.font(.caption)
          Text(model.breadcrumb(for: node.identity)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(10)
        HStack(spacing: 6) {
          inspectorTabButton(.properties)
          inspectorTabButton(.layout)
          inspectorTabButton(.accessibility)
          inspectorTabButton(.rawDump)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        Divider()
        ScrollView {
          inspectorContent(node, capture: capture)
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
      } else {
        ContentUnavailableView("Select a component", systemImage: "cursorarrow.click")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .accessibilityIdentifier("viewer.properties")
  }

  @ViewBuilder
  private func inspectorContent(_ node: ViewerNode, capture: ViewerCapture) -> some View {
    switch model.inspectorTab {
    case .properties:
      keyValues([("Type", node.type), ("ID", node.deviceID ?? "Unavailable"), ("Text", node.text ?? "Unavailable"), ("Inspector ID", node.inspectorID ?? "Unavailable"), ("Enabled", state(node.enabled)), ("Clickable", state(node.clickable))])
    case .layout:
      keyValues([("Screenshot mapping", capture.coordinatesAreVerified ? "Verified" : "Unavailable"), ("Bounds", boundsText(node.bounds)), ("z-order", node.zIndex.map { String($0) } ?? "Unavailable"), ("Hit test", node.bounds != nil && capture.coordinatesAreVerified ? "Available" : "Unavailable")])
    case .accessibility:
      keyValues([("Visible", state(node.visible)), ("Focusable", state(node.focusable)), ("Accessible label", node.text ?? "Unavailable"), ("Description", node.inspectorID ?? "Unavailable")])
    case .rawDump:
      Text(capture.formattedRawFields(for: node.identity) ?? "Raw fields are unavailable")
        .font(.callout.monospaced()).textSelection(.enabled)
        .accessibilityIdentifier("viewer.rawDump")
    }
  }

  private func keyValues(_ rows: [(String, String)]) -> some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
      ForEach(rows, id: \.0) { name, value in
        GridRow {
          Text(name).foregroundStyle(.secondary)
          Text(value).font(.callout.monospaced()).textSelection(.enabled)
        }
      }
    }
  }

  private func inspectorTabButton(_ tab: ViewerInspectorTab) -> some View {
    Button(tab.title) { model.setInspectorTab(tab) }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .accessibilityLabel("Show \(tab.title)")
  }

  private func paneHeader(_ title: String, detail: String) -> some View {
    HStack(spacing: 8) {
      Text(title).font(.headline)
      Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      Spacer()
    }
    .padding(.horizontal, 12).padding(.vertical, 9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
  }

  private func fittedSize(container: CGSize, aspect: CGFloat) -> CGSize {
    guard aspect > 0 else { return .zero }
    let width = min(container.width - 24, (container.height - 24) * aspect)
    return CGSize(width: max(1, width), height: max(1, width / aspect))
  }
  private func state(_ value: Bool?) -> String { value.map { $0 ? "Yes" : "No" } ?? "Unavailable" }
  private func boundsText(_ value: ViewerBounds?) -> String {
    guard let value else { return "Unavailable" }
    return "x \(value.x), y \(value.y), \(value.width) × \(value.height)"
  }
  private var targetBinding: Binding<String> {
    Binding(get: { model.selectedTargetID }, set: { model.setTargetID($0) })
  }
  private var rootBinding: Binding<String> {
    Binding(get: { model.selectedRootIdentity }, set: { model.setRoot($0) })
  }
  private var queryBinding: Binding<String> {
    Binding(get: { model.searchQuery }, set: { model.setSearchQuery($0) })
  }
  private var boundsBinding: Binding<Bool> {
    Binding(get: { model.showBounds }, set: { model.setShowBounds($0) })
  }
}

enum ViewerInspectorTab: String {
  case properties, layout, accessibility, rawDump
  var id: String { rawValue }
  var title: String { switch self { case .properties: "Properties"; case .layout: "Layout"; case .accessibility: "Accessibility"; case .rawDump: "Raw dump" } }
}

@MainActor
@Observable
final class UIDumpWorkspaceViewModel {
  private(set) var workspace = UIDumpWorkspacePresentation.loading
  private(set) var selectedTargetID = ""
  private(set) var capture: ViewerCapture?
  private(set) var selectedNodeIdentity: String?
  private(set) var selectedRootIdentity = ""
  private(set) var expandedNodeIdentities: Set<String> = []
  private(set) var searchQuery = ""
  private(set) var showBounds = true
  private(set) var inspectorTreePercent: Double = 60
  private(set) var inspectorTab: ViewerInspectorTab = .properties
  private(set) var isRefreshing = false
  private(set) var isCapturing = false
  private(set) var captureFailure: String?
  private let provider: any UIDumpApplicationProviding

  init(provider: any UIDumpApplicationProviding) { self.provider = provider }
  var selectedTarget: UIDumpTargetPresentation? { workspace.targets.first { $0.id == selectedTargetID } }
  var selectedNode: ViewerNode? { selectedNodeIdentity.flatMap { capture?.node(identity: $0) } }
  var emptyMessage: String {
    if let failure = workspace.targetLoadFailure { return failure }
    if selectedTarget == nil { return "Select an adopted target with a complete binding, then recapture." }
    if let reason = selectedTarget?.connection.failureReason {
      return "\(selectedTarget?.id ?? "This target") cannot be recaptured: \(reason). Select a Connected target."
    }
    if case .unavailable(let reasons) = workspace.operation.availability { return reasons.joined(separator: "\n") }
    return "Recapture creates a typed Runtime Job and shows only verified, same-Job Artifacts."
  }
  var canRecapture: Bool {
    guard !isCapturing, selectedTarget?.isCaptureReady == true else { return false }
    if case .available = workspace.operation.availability { return true }
    return false
  }
  var visibleNodes: [ViewerNode] {
    guard let capture else { return [] }
    return capture.visibleTreeNodes(
      rootIdentity: selectedRootIdentity,
      query: searchQuery,
      expandedNodeIdentities: expandedNodeIdentities)
  }
  func screenshotNodes(_ capture: ViewerCapture) -> [ViewerNode] {
    capture.subtreeNodes(rootIdentity: selectedRootIdentity).filter { node in
      node.bounds != nil && node.visible
    }.sorted { $0.depth < $1.depth }
  }
  func refresh() {
    guard !isRefreshing else { return }
    isRefreshing = true
    let provider = provider
    Task { [weak self] in
      let next = await provider.refreshWorkspace()
      guard let self, !Task.isCancelled else { return }
      self.workspace = next
      self.selectedTargetID = self.preferredTargetID(in: next.targets)
      if self.selectedTarget?.isCaptureReady == false { self.captureFailure = nil }
      self.isRefreshing = false
    }
  }
  private func preferredTargetID(in targets: [UIDumpTargetPresentation]) -> String {
    // Preserve an explicit exact selection even if it goes offline. Replacing
    // it behind the user's back could send a capture to a different device.
    if !selectedTargetID.isEmpty, targets.contains(where: { $0.id == selectedTargetID }) {
      return selectedTargetID
    }
    // With no existing selection (including first launch), make the safe and
    // useful default the first target with a fresh Connected route.
    return targets.first(where: \.isCaptureReady)?.id ?? targets.first?.id ?? ""
  }
  func recapture() {
    guard let target = selectedTarget, canRecapture else { return }
    isCapturing = true; captureFailure = nil
    let provider = provider
    Task { [weak self] in
      let result = await provider.recapture(target: target)
      guard let self, !Task.isCancelled else { return }
      self.isCapturing = false
      switch result {
      case .captured(let next):
        self.capture = next
        self.selectedRootIdentity = next.roots.first ?? ""
        // A previous screen's query must not leave a fresh capture looking
        // empty or hide the row selected from the screenshot.
        self.searchQuery = ""
        self.expandedNodeIdentities = Set(next.nodes.filter { !$0.children.isEmpty }.map(\.identity))
        self.select(next.nodes.first?.identity ?? "")
      case .failed(let reason): self.captureFailure = reason
      }
      self.refresh()
    }
  }
  func setTargetID(_ value: String) {
    selectedTargetID = value
    captureFailure = nil
  }
  func setRoot(_ value: String) { selectedRootIdentity = value }
  func setSearchQuery(_ value: String) { searchQuery = value }
  func setShowBounds(_ value: Bool) { showBounds = value }
  func setInspectorTab(_ value: ViewerInspectorTab) { inspectorTab = value }
  func toggleExpansion(_ identity: String) { if !expandedNodeIdentities.insert(identity).inserted { expandedNodeIdentities.remove(identity) } }
  func adjustInspectorTree(by delta: Double) { inspectorTreePercent = min(68, max(35, inspectorTreePercent - delta / 8)) }
  func select(in capture: ViewerCapture, at location: CGPoint, renderedSize: CGSize) {
    guard renderedSize.width > 0, renderedSize.height > 0 else { return }
    let screenshotX = Double(location.x / renderedSize.width) * Double(capture.screenshotWidth)
    let screenshotY = Double(location.y / renderedSize.height) * Double(capture.screenshotHeight)
    guard let node = ViewerHitTesting.node(in: capture, x: screenshotX, y: screenshotY) else {
      return
    }
    select(node.identity)
  }
  func select(_ identity: String) {
    guard let capture, let node = capture.node(identity: identity) else { return }
    selectedNodeIdentity = node.identity
    expandedNodeIdentities.formUnion(capture.ancestors(of: node.identity))
  }
  func nodeTitle(_ identity: String) -> String? { capture?.node(identity: identity).map { "#\($0.deviceID ?? "—") \($0.type)" } }
  func breadcrumb(for identity: String) -> String {
    guard let capture else { return "" }
    return (capture.ancestors(of: identity) + [identity]).compactMap { nodeTitle($0) }.joined(separator: " › ")
  }
}

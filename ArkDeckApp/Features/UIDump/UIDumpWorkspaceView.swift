import AppKit
import ArkDeckWorkflows
import Observation
import SwiftUI

/// A Job-bound inspection surface. It deliberately has no command, argv,
/// remote-path, Recipe, or parameter-policy input.
struct UIDumpWorkspaceView: View {
  private static let treeRowHeight: CGFloat = 26
  private static let treeRowSpacing: CGFloat = 1
  private static let treeVerticalPadding: CGFloat = 6

  var model: UIDumpWorkspaceViewModel
  @FocusState private var separatorFocused: Bool
  @State private var treeScrollPosition = ScrollPosition()
  /// The vertical offset the in-flight selection reveal must end on, or nil
  /// when no reveal is pending. The reveal's two scroll requests race row
  /// realisation, so the scroll geometry callback below keeps re-asserting
  /// this target until the observed offset actually reaches it; a user
  /// gesture or a changed row set retires it instead.
  @State private var pendingTreeRevealOffsetY: CGFloat?
  @State private var workspaceWidth: CGFloat = 0
  @State private var screenshotAvailableSize = CGSize.zero
  @State private var inspectorAvailableHeight: CGFloat = 0
  @State private var treeViewportSize = CGSize.zero
  @State private var didRevealInitialTreeSelection = false

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      if model.isOpeningHistoryCapture {
        ProgressView {
          Text("history.loading", tableName: "HistoryLocalizable")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("viewer.history.loading")
      } else if let capture = model.capture {
        if workspaceWidth >= 880 {
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
      if let capture = model.capture {
        Divider()
        footer(capture)
      }
    }
    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { workspaceWidth = $0 }
    .task { model.refresh() }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { model.refresh() } label: {
          Label(viewerText("viewer.toolbar.refresh"), systemImage: "arrow.clockwise")
        }
        .disabled(model.isRefreshing || model.isCapturing)
        .accessibilityIdentifier("viewer.refresh")
      }
    }
  }

  private var toolbar: some View {
    // The page's name is in the window toolbar. Repeating it here gave the
    // detail pane two perceivable main headings (spec §3, §6); the prototype
    // gets away with its own `<h1>` because its title bar reads
    // "ArkDeck — Viewer" rather than the bare page name this App shows.
    HStack(spacing: WorkspaceMetrics.contentGap) {
      Picker(viewerText("viewer.toolbar.device"), selection: targetBinding) {
        Text(viewerText("viewer.toolbar.noDevice")).tag("")
        ForEach(model.targets) { target in
          Text(model.deviceTitle(target)).tag(target.id)
        }
      }
      .frame(maxWidth: 220)
      .accessibilityIdentifier("viewer.target")

      if let capture = model.capture {
        Picker(viewerText("viewer.toolbar.currentScreen"), selection: rootBinding) {
          ForEach(capture.roots, id: \.self) { identity in
            Text(model.nodeTitle(identity) ?? viewerText("viewer.toolbar.currentScreen")).tag(identity)
          }
        }
        .frame(maxWidth: 190)
        Text(capture.identity.capturedAtUTC)
          .font(WorkspaceFont.monospacedDense.monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .help(capture.identity.capturedAtUTC)
      }

      Spacer(minLength: 8)
      HStack(spacing: 4) {
        TextField(viewerText("viewer.toolbar.search"), text: queryBinding)
          .textFieldStyle(.roundedBorder)
          .frame(minWidth: 150, maxWidth: 250)
          .accessibilityIdentifier("viewer.search")
        if model.hasSearchQuery {
          Text(model.searchMatchSummary)
            .font(WorkspaceFont.monospacedDense.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 34)
            .accessibilityLabel(viewerText("viewer.search.matchCount"))
            .accessibilityValue(model.searchMatchSummary)
            .accessibilityIdentifier("viewer.search.matchCount")
          searchNavigationButton(
            direction: .previous,
            systemImage: "chevron.up",
            label: viewerText("viewer.search.previous"))
          searchNavigationButton(
            direction: .next,
            systemImage: "chevron.down",
            label: viewerText("viewer.search.next"))
        }
      }
      Button { model.recapture() } label: {
        Label(
          model.isCapturing
            ? viewerText("viewer.toolbar.capturing")
            : viewerText(
              model.capture == nil ? "viewer.toolbar.capture" : "viewer.toolbar.recapture"),
          systemImage: "camera.viewfinder")
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
      Text(viewerText("viewer.empty.title")).font(.title3.weight(.semibold))
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
      paneHeader(
        viewerText("viewer.pane.screenshot"),
        identifier: "viewer.pane.screenshot",
        detail: capture.coordinatesAreVerified
          ? "" : viewerText("viewer.pane.coordinatesUnverified")
      ) {
        // The toggle only changes this pane, so it belongs to this pane rather
        // than to a window-wide toolbar.
        Toggle(viewerText("viewer.pane.showBounds"), isOn: boundsBinding)
          .toggleStyle(.checkbox)
          .font(WorkspaceFont.caption)
          .accessibilityIdentifier("viewer.showBounds")
      }
      ZStack {
        Color(nsColor: .windowBackgroundColor)
        if let image = NSImage(data: capture.screenshotData) {
          let content = fittedSize(
            container: screenshotAvailableSize,
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
              screenshotSelectionAnnotation(capture, content: content)
            }
          }
          .frame(width: content.width, height: content.height)
          // Selection annotations may sit just outside a small component,
          // but they still belong to the screenshot and never escape it.
          .clipped()
        } else {
          ContentUnavailableView(viewerText("viewer.screenshot.unavailable"), systemImage: "photo")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onGeometryChange(for: CGSize.self, of: { $0.size }) { screenshotAvailableSize = $0 }
      if !capture.coordinatesAreVerified {
        Label(viewerText("viewer.screenshot.unverifiedDetail"), systemImage: "exclamationmark.triangle")
          .font(WorkspaceFont.secondary)
          .foregroundStyle(.orange)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func screenshotRegion(
    _ node: ViewerNode,
    in capture: ViewerCapture,
    content: CGSize
  ) -> some View {
    if let bounds = ViewerScreenshotMapping.visibleBounds(of: node, in: capture)
    {
      let selected = node.identity == model.selectedNodeIdentity
      let outlined = model.showBounds || selected
      Rectangle()
        .fill(selected ? Color.accentColor.opacity(0.10) : .clear)
        .overlay {
          if outlined {
            Rectangle().strokeBorder(
              selected ? Color.accentColor : Color.accentColor.opacity(0.35),
              lineWidth: selected ? 2 : 1)
          }
        }
      .frame(
        width: max(1, content.width * bounds.width / Double(capture.screenshotWidth)),
        height: max(1, content.height * bounds.height / Double(capture.screenshotHeight)))
      .position(
        x: content.width * (bounds.x + bounds.width / 2) / Double(capture.screenshotWidth),
        y: content.height * (bounds.y + bounds.height / 2) / Double(capture.screenshotHeight))
      // The selected component is the inspection result, so its outline must
      // remain above deeper transparent descendants and optional all-bounds
      // guides. This changes presentation only, never hit-test ordering.
      .zIndex(selected ? 1_000_000 : Double(node.depth) + (node.zIndex ?? 0))
      // Pointer selection stays with the single coordinate target below, which
      // resolves the deepest node under the point. Real dumps stack several
      // full-screen containers, so turning these into click targets lets the
      // shallowest one swallow every click — that is what once made the
      // screenshot "appear unclickable", and it is an occlusion problem rather
      // than a cost problem.
      .allowsHitTesting(false)
      // Assistive technology is a different matter: it needs to reach each
      // node spatially, and it addresses elements by name rather than by
      // position, so nothing occludes anything. These stay present whether or
      // not the bounds are drawn — showing bounds is a visual preference, not
      // an accessibility one.
      .accessibilityElement()
      .accessibilityLabel(model.nodeTitle(node.identity) ?? node.type)
      .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
      .accessibilityAction { model.select(node.identity) }
      .accessibilityIdentifier("viewer.screenshot.node.\(node.identity)")
    }
  }

  /// The label is a sibling of the measured region, not its overlay. AppKit
  /// otherwise unions the label and rectangle into one accessibility frame,
  /// making a small image appear to have a much larger selected range.
  @ViewBuilder
  private func screenshotSelectionAnnotation(_ capture: ViewerCapture, content: CGSize) -> some View {
    if let identity = model.selectedNodeIdentity,
      let node = capture.node(identity: identity),
      let bounds = ViewerScreenshotMapping.visibleBounds(of: node, in: capture)
    {
      Rectangle()
        .fill(.clear)
        .frame(
          width: max(1, content.width * bounds.width / Double(capture.screenshotWidth)),
          height: max(1, content.height * bounds.height / Double(capture.screenshotHeight)))
        .overlay(
          alignment: bounds.x + bounds.width / 2 > Double(capture.screenshotWidth) / 2
            ? .topTrailing : .topLeading
        ) {
          Text("#\(node.deviceID ?? "—") \(node.type)")
            .font(WorkspaceFont.monospacedDense)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(Color.primary)
            .fixedSize()
            .offset(y: bounds.y < 64 ? 3 : -22)
        }
        .position(
          x: content.width * (bounds.x + bounds.width / 2) / Double(capture.screenshotWidth),
          y: content.height * (bounds.y + bounds.height / 2) / Double(capture.screenshotHeight))
        .zIndex(1_000_001)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }

  /// The tree remains the keyboard-accessible component selector. This
  /// surface gives pointer users one stable coordinate target regardless of
  /// whether visual bounds are currently shown.
  private func screenshotHitTest(_ capture: ViewerCapture, content: CGSize) -> some View {
    Color.clear
      .contentShape(.rect)
      .gesture(SpatialTapGesture().onEnded { value in
        model.select(in: capture, at: value.location, renderedSize: content)
      })
      .accessibilityLabel(viewerText("viewer.screenshot.selectLabel"))
      .accessibilityHint(viewerText("viewer.screenshot.selectHint"))
      .accessibilityIdentifier("viewer.screenshot.hitTest")
  }

  private func inspector(_ capture: ViewerCapture) -> some View {
    let treeHeight = max(150, inspectorAvailableHeight * model.inspectorTreePercent / 100)
    return VStack(spacing: 0) {
      tree(capture).frame(height: treeHeight)
      resizeHandle
      properties(capture).frame(maxHeight: .infinity)
    }
    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
      inspectorAvailableHeight = $0
    }
  }

  private func tree(_ capture: ViewerCapture) -> some View {
    let rows = model.visibleNodes
    let minimumDepth = rows.map(\.depth).min() ?? 0
    let maximumDepth = rows.map(\.depth).max() ?? minimumDepth
    return VStack(spacing: 0) {
      paneHeader(
        viewerText("viewer.pane.tree"),
        identifier: "viewer.pane.tree",
        detail: "\(rows.count) / \(capture.nodes.count)")
      // A row inside a horizontally scrolling outline has no bounded width, so
      // it must size to its own content and only borrow the viewport width as
      // a floor. Asking for `maxWidth: .infinity` here made every row claim the
      // scroll content width in turn and cascaded the tree diagonally.
      ScrollView([.horizontal, .vertical]) {
        LazyVStack(alignment: .leading, spacing: Self.treeRowSpacing) {
          ForEach(rows) { node in
            treeRow(
              node,
              visualDepth: max(0, node.depth - minimumDepth),
              maximumVisualDepth: max(0, maximumDepth - minimumDepth),
              viewportWidth: treeViewportSize.width)
              .id(node.identity)
          }
          if rows.isEmpty {
            Text(viewerText("viewer.tree.noMatches"))
              .foregroundStyle(.secondary).padding(12)
          }
          Color.clear
            .frame(height: max(0, treeViewportSize.height / 2))
            .id("viewer.tree.trailingSpacer")
            .accessibilityHidden(true)
        }
        .scrollTargetLayout()
        .padding(.vertical, Self.treeVerticalPadding)
      }
      .scrollPosition($treeScrollPosition)
      .scrollIndicators(.visible, axes: [.horizontal, .vertical])
      .accessibilityIdentifier("viewer.tree.scroll")
      .onGeometryChange(for: CGSize.self, of: { $0.size }) { treeViewportSize = $0 }
      .onAppear { revealInitialTreeSelectionIfReady() }
      .onChange(of: model.selectionRevealGeneration) { _, _ in
        // Selection and search navigation are high-frequency inspection
        // actions. Reveal immediately so rapid result changes never queue
        // or fight an in-flight scrolling animation.
        revealTreeSelection(viewportHeight: treeViewportSize.height)
      }
      .onScrollGeometryChange(for: CGPoint.self, of: { $0.contentOffset }) { _, offset in
        // The reveal's completion condition is the observed offset, not a
        // fixed number of transactions: whichever of the two reveal
        // requests resolves last — and any late row realisation that moves
        // content afterwards — the target is re-asserted until the scroll
        // actually rests on it. Re-asserting an unreachable target moves
        // nothing, produces no further callback, and so ends the loop.
        guard let target = pendingTreeRevealOffsetY else { return }
        if abs(offset.y - target) <= 0.5 {
          pendingTreeRevealOffsetY = nil
        } else {
          treeScrollPosition.scrollTo(y: target)
        }
      }
      .onScrollPhaseChange { _, newPhase in
        // The person owns the viewport the moment they scroll it; a
        // pending reveal must never fight a gesture.
        if newPhase == .tracking || newPhase == .interacting || newPhase == .decelerating {
          pendingTreeRevealOffsetY = nil
        }
      }
      .onChange(of: model.visibleNodes.map(\.identity)) { _, _ in
        // The target was computed against the previous row set; a new set
        // re-reveals through its own generation bump when it means to.
        pendingTreeRevealOffsetY = nil
      }
      .onChange(of: treeViewportSize) { _, _ in
        pendingTreeRevealOffsetY = nil
        revealInitialTreeSelectionIfReady()
      }
      // The outline keyboard model lives on the scrolling row set, not on each
      // row: rows are recycled by LazyVStack, so per-row key handlers would
      // stop responding as soon as a deep tree scrolled the focused row away.
      .focusable()
      .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
      .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
      .onKeyPress(.leftArrow) { model.collapseOrSelectParent(); return .handled }
      .onKeyPress(.rightArrow) { model.expandOrSelectFirstChild(); return .handled }
      .onKeyPress(.home) { model.moveSelectionToEdge(first: true); return .handled }
      .onKeyPress(.end) { model.moveSelectionToEdge(first: false); return .handled }
      .accessibilityLabel(viewerText("viewer.tree.label"))
    }
  }

  private func revealInitialTreeSelectionIfReady() {
    guard !didRevealInitialTreeSelection, treeViewportSize.height > 0 else { return }
    didRevealInitialTreeSelection = true
    revealTreeSelection(viewportHeight: treeViewportSize.height)
  }

  private func revealTreeSelection(viewportHeight: CGFloat) {
    guard let identity = model.selectedNodeIdentity else { return }
    // A filtered search may already have targeted this identity before the
    // full outline is restored. Publish a fresh position request so selecting
    // the same component again re-resolves its new coordinates instead of
    // treating the unchanged id as a no-op.
    var position = ScrollPosition()
    position.scrollTo(id: identity, anchor: .center)
    treeScrollPosition = position
    guard
      let rowIndex = model.visibleNodes.firstIndex(where: { $0.identity == identity })
    else {
      pendingTreeRevealOffsetY = nil
      return
    }
    let rowCenter = Self.treeVerticalPadding
      + CGFloat(rowIndex) * (Self.treeRowHeight + Self.treeRowSpacing)
      + Self.treeRowHeight / 2
    let verticalOffset = max(0, rowCenter - viewportHeight / 2)
    // The deterministic row offset is the reveal's real destination. One
    // yielded transaction is only the first impulse: at some viewport
    // heights the id request resolves after it and re-lands the row at the
    // viewport's lower edge (the macOS combined-axis bug), so the scroll
    // geometry callback on the tree keeps re-asserting this target until
    // the offset is observed to rest on it.
    pendingTreeRevealOffsetY = verticalOffset
    Task { @MainActor in
      // The id request resolves the row's variable horizontal geometry. Apply
      // the deterministic row offset on the next transaction; `scrollTo(y:)`
      // preserves that horizontal position while avoiding the macOS combined-
      // axis bug that otherwise leaves the row at the lower edge.
      await Task.yield()
      guard pendingTreeRevealOffsetY == verticalOffset else { return }
      treeScrollPosition.scrollTo(y: verticalOffset)
    }
  }

  /// One row with separate disclosure and selection controls.
  ///
  /// The selection fill is an inset capsule rather than a full-bleed band, and
  /// the disclosure chevron is a real button, so keyboard and VoiceOver users
  /// can expand without changing selection. `#id` trails the label inline: a
  /// deep tree scrolls horizontally, so there is no fixed right edge to align
  /// a column to, and the node's own name must never be truncated to make one.
  private func treeRow(
    _ node: ViewerNode,
    visualDepth: Int,
    maximumVisualDepth: Int,
    viewportWidth: CGFloat
  ) -> some View {
    let selected = node.identity == model.selectedNodeIdentity
    let expanded = model.expandedNodeIdentities.contains(node.identity)
    return HStack(spacing: 6) {
      if node.children.isEmpty {
        Color.clear.frame(width: 16, height: 16)
      } else {
        Button(
          viewerText(expanded ? "viewer.tree.collapse" : "viewer.tree.expand"),
          systemImage: "chevron.right"
        ) {
          model.toggleExpansion(node.identity)
        }
        .font(.caption2.bold())
        .rotationEffect(.degrees(expanded ? 90 : 0))
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .frame(width: 16, height: 16)
      }
      Button { model.select(node.identity) } label: {
        HStack(spacing: 6) {
          Image(systemName: Self.symbol(for: node.type))
            .font(WorkspaceFont.caption)
            .frame(width: 16, height: 16)
            .opacity(selected ? 0.95 : 0.65)
            .accessibilityHidden(true)

          Text(node.type)
            .font(WorkspaceFont.secondary)
            .lineLimit(1)
            .fixedSize()
          if let text = node.text, !text.isEmpty {
            Text(text)
              .font(WorkspaceFont.secondary)
              .opacity(selected ? 0.85 : 0.62)
              .lineLimit(1)
              .fixedSize()
          }
          if let id = node.deviceID {
            Text("#\(id)")
              .font(WorkspaceFont.monospacedDense)
              .monospacedDigit()
              .opacity(selected ? 0.85 : 0.55)
              .fixedSize()
          }
        }
      }
      .buttonStyle(.plain)
      .accessibilityValue(
        selected ? viewerText("viewer.tree.selected") : viewerText("viewer.tree.notSelected"))
      // Real merged dumps can exceed fifty levels. Preserve indentation while
      // reserving enough of the current viewport for the node's actual label;
      // otherwise auto-reveal shows a blue selection band with every glyph
      // beyond the right edge.
      .padding(
        .leading,
        CGFloat(
          ViewerTreeLayoutPolicy.leadingIndent(
            depth: visualDepth,
            maximumDepth: maximumVisualDepth,
            viewportWidth: Double(viewportWidth))))
      .padding(.trailing, 8)
      .frame(minHeight: Self.treeRowHeight, alignment: .leading)
      // The floor keeps the selection capsule spanning the visible pane; the
      // content decides the real width so nothing is truncated or wrapped.
      .frame(minWidth: max(0, viewportWidth - 12), alignment: .leading)
    }
    .contentShape(.rect)
    .foregroundStyle(selected ? Color.white : Color.primary)
    .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
    .padding(.horizontal, 6)
    .accessibilityIdentifier("viewer.tree.node.\(node.identity)")
  }

  /// Node kind, not decoration. One identical outline square on every row told
  /// the reader nothing; these five shapes separate containers from leaves at a
  /// glance and are the only thing distinguishing a `Text` from an `Image` when
  /// a deep tree has scrolled the labels out of alignment.
  static func symbol(for type: String) -> String {
    switch type {
    // Not `textformat`: SF Symbols localizes it, and in a Simplified Chinese
    // run it renders the word 格式 inside the outline instead of a glyph.
    case "Text", "Span", "Search", "RichText": "text.alignleft"
    case "Image", "Icon", "ImageSpan": "photo"
    case "Toggle", "Button", "Slider", "Checkbox", "Radio", "Select": "switch.2"
    case "CustomComponent", "BuilderNode", "ConditionalContent", "LazyForEach", "ForEach":
      "curlybraces"
    case "Column", "Row", "List", "ListItem", "Stack", "Flex", "Grid", "Scroll", "Swiper":
      "rectangle.split.2x1"
    default: "rectangle"
    }
  }

  /// macOS splits panes with a hairline. The visible rule stays 1 pt; the drag
  /// and focus target is the 9 pt transparent band around it.
  private var resizeHandle: some View {
    Color.clear
      .frame(height: 9)
      .overlay {
        Rectangle()
          .fill(separatorFocused ? Color.accentColor : Color(nsColor: .separatorColor))
          .frame(height: 1)
      }
      .contentShape(.rect)
      .gesture(DragGesture(minimumDistance: 0).onChanged { value in
        model.adjustInspectorTree(by: value.translation.height)
      })
      .focusable()
      .focused($separatorFocused)
      .onKeyPress(.upArrow) { model.adjustInspectorTree(by: 32); return .handled }
      .onKeyPress(.downArrow) { model.adjustInspectorTree(by: -32); return .handled }
      .onKeyPress(.home) { model.setInspectorTree(percent: 35); return .handled }
      .onKeyPress(.end) { model.setInspectorTree(percent: 68); return .handled }
      // A hairline drawn on `Color.clear` publishes nothing on its own, so the
      // splitter has to be declared an element before it can carry a name, a
      // value, or a keyboard action for VoiceOver.
      .accessibilityElement()
      .accessibilityLabel(viewerText("viewer.separator.label"))
      .accessibilityValue(
        String(
          localized: LocalizedStringResource.UIDumpLocalizable.viewerSeparatorValue(
            Int32(clamping: Int(model.inspectorTreePercent)))))
      .accessibilityAdjustableAction { direction in
        model.adjustInspectorTree(by: direction == .increment ? -32 : 32)
      }
      .accessibilityIdentifier("viewer.inspector.separator")
  }

  private func properties(_ capture: ViewerCapture) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if let node = model.selectedNode {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Image(systemName: Self.symbol(for: node.type))
              .font(WorkspaceFont.caption).foregroundStyle(.secondary)
            Text(node.type).font(WorkspaceFont.sectionTitle)
            if let id = node.deviceID { statusChip("#\(id)") }
            // Neutral, not green: "visible" and "interactive" are facts about
            // the node, not a health verdict. Semantic green stays reserved
            // for outcomes that are actually good news.
            if node.clickable == true { statusChip(ViewerInspectorCopy.interactive) }
            if node.visible { statusChip(ViewerInspectorCopy.visible) }
            Spacer(minLength: 0)
          }
          Text(model.breadcrumb(for: node.identity))
            .font(WorkspaceFont.monospacedDense)
            .foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.head)
            .help(model.breadcrumb(for: node.identity))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        Divider()
        ScrollView(.horizontal) {
          HStack(spacing: 0) {
            inspectorTabButton(.properties)
            inspectorTabButton(.layout)
            inspectorTabButton(.accessibility)
            inspectorTabButton(.rawDump)
            inspectorTabButton(.advancedDump)
            Spacer(minLength: 0)
          }
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, 6)
        Divider()
        if model.inspectorTab == .advancedDump {
          AdvancedDumpInspectorView(
            nodeIdentity: node.identity,
            dumpNodeIdentity: model.advancedDumpNodeIdentity,
            fields: model.advancedDumpFields,
            failure: model.advancedDumpFailure,
            isLoading: model.isLoadingAdvancedDump,
            retry: { model.retryAdvancedDump() })
            .id(node.identity)
        } else {
          ScrollView {
            inspectorContent(node, capture: capture)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      } else {
        ContentUnavailableView(ViewerInspectorCopy.selectPrompt, systemImage: "cursorarrow.click")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  /// Live telemetry for the capture on screen, in the pipeline's own stage
  /// names so a line here and a signpost interval in Instruments read the
  /// same. A capture that was not measured says so rather than showing zeros.
  private func footer(_ capture: ViewerCapture) -> some View {
    HStack(spacing: 6) {
      Text(
        String(
          localized: LocalizedStringResource.UIDumpLocalizable.viewerFooterNodes(
            Int32(clamping: capture.nodes.count))))
      if let metrics = capture.metrics {
        Text("· submit \(milliseconds(metrics.submitMilliseconds))")
        Text("· run \(milliseconds(metrics.runMilliseconds))")
        Text("· list \(milliseconds(metrics.listMilliseconds))")
        Text("· read \(bytes(metrics.readBytes))/\(milliseconds(metrics.readMilliseconds))")
        if let throughput = metrics.readMegabytesPerSecond {
          Text("(\(throughput.formatted(.number.precision(.fractionLength(1)))) MB/s)")
        }
        Text("· parse \(milliseconds(metrics.parseMilliseconds))")
        Text("· Σ \(milliseconds(metrics.totalMilliseconds))")
      } else {
        Text("· \(viewerText("viewer.footer.notMeasured"))")
      }
      Spacer(minLength: 0)
    }
    .font(WorkspaceFont.monospacedDense)
    .foregroundStyle(.secondary)
    .lineLimit(1)
    .padding(.horizontal, 12)
    .frame(height: 26)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("viewer.footer")
  }

  /// `FormatStyle` rather than the C varargs formatter: the App target builds
  /// with strict memory safety, and a contract test bans that form outright —
  /// by scanning source text, so even naming it in a comment fails the gate.
  private func milliseconds(_ value: Double) -> String {
    value >= 1000
      ? "\((value / 1000).formatted(.number.precision(.fractionLength(2))))s"
      : "\(value.formatted(.number.precision(.fractionLength(0))))ms"
  }

  private func bytes(_ value: Int) -> String {
    value >= 1_048_576
      ? "\((Double(value) / 1_048_576).formatted(.number.precision(.fractionLength(1))))MB"
      : "\((Double(value) / 1024).formatted(.number.precision(.fractionLength(0))))KB"
  }

  private func statusChip(_ text: String) -> some View {
    Text(verbatim: text)
      .font(WorkspaceFont.monospacedDense)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 6).padding(.vertical, 1)
      .overlay {
        Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      }
  }

  /// Grouped, because a flat run of a dozen identical rows reads as a dump
  /// rather than an inspector. Identity, state, and geometry answer different
  /// questions and are scanned separately.
  @ViewBuilder
  private func inspectorContent(_ node: ViewerNode, capture: ViewerCapture) -> some View {
    switch model.inspectorTab {
    case .properties:
      keyValueGroup(ViewerInspectorCopy.identity, [
        ("id", node.deviceID),
        ("type", node.type),
        ("inspectorId", node.inspectorID),
        ("text", node.text),
      ])
      keyValueGroup(ViewerInspectorCopy.state, [
        ("enabled", state(node.enabled)),
        ("visible", state(node.visible)),
        ("clickable", state(node.clickable)),
        ("focusable", state(node.focusable)),
        ("focused", state(node.focused)),
      ])
    case .layout:
      keyValueGroup(ViewerInspectorCopy.geometry, [
        ("bounds", boundsText(node.bounds)),
        (ViewerInspectorCopy.screenshotMapping,
         ViewerScreenshotMapping.visibleBounds(of: node, in: capture) != nil
           ? ViewerInspectorCopy.verified : nil),
        (ViewerInspectorCopy.hitTest,
         ViewerScreenshotMapping.visibleBounds(of: node, in: capture) != nil
           ? ViewerInspectorCopy.available : nil),
      ])
      keyValueGroup(ViewerInspectorCopy.paint, [
        ("zIndex", node.zIndex.map { String($0) }),
      ])
    case .accessibility:
      keyValueGroup(ViewerInspectorCopy.semantics, [
        (ViewerInspectorCopy.accessibleLabel, node.text),
        (ViewerInspectorCopy.description, node.inspectorID),
      ])
      keyValueGroup(ViewerInspectorCopy.focus, [
        ("visible", state(node.visible)),
        ("focusable", state(node.focusable)),
        ("focused", state(node.focused)),
      ])
    case .rawDump:
      Text(verbatim:
        capture.formattedRawFields(for: node.identity) ?? ViewerInspectorCopy.rawUnavailable)
        .font(WorkspaceFont.monospacedValue).textSelection(.enabled)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("viewer.rawDump")
    case .advancedDump:
      EmptyView()
    }
  }

  @ViewBuilder
  private func keyValueGroup(_ title: String, _ rows: [(String, String?)]) -> some View {
    let availableRows = rows.compactMap { row -> (String, String)? in
      guard let value = row.1, !value.isEmpty else { return nil }
      return (row.0, value)
    }
    if !availableRows.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        Text(verbatim: title)
          .font(WorkspaceFont.label)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 12).padding(.vertical, 6)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.bar)
        Divider()
        ForEach(availableRows, id: \.0) { name, value in
          HStack(alignment: .top, spacing: 0) {
            // A fixed key column. A fluid one let two-character keys claim 40%
            // of the inspector and pushed their values half a pane away.
            Text(verbatim: name)
              .font(WorkspaceFont.secondary).foregroundStyle(.secondary)
              .frame(width: 150, alignment: .leading)
            Text(verbatim: value)
              .font(WorkspaceFont.monospacedValue)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.horizontal, 12).padding(.vertical, 6)
          Divider()
        }
      }
    }
  }

  private enum SearchNavigationDirection: String {
    case previous, next
  }

  private func searchNavigationButton(
    direction: SearchNavigationDirection,
    systemImage: String,
    label: String
  ) -> some View {
    Button {
      switch direction {
      case .previous: model.selectPreviousSearchMatch()
      case .next: model.selectNextSearchMatch()
      }
    } label: {
      Image(systemName: systemImage)
        .font(.caption2.bold())
        .frame(width: 24, height: 24)
        .contentShape(.rect)
    }
    .buttonStyle(.borderless)
    .disabled(!model.canNavigateSearchMatches)
    .help(label)
    .accessibilityLabel(label)
    .accessibilityIdentifier("viewer.search.\(direction.rawValue)")
  }

  private func inspectorTabButton(_ tab: ViewerInspectorTab) -> some View {
    let active = model.inspectorTab == tab
    return Button { model.setInspectorTab(tab) } label: {
      Text(verbatim: tab.title)
        .font(active ? WorkspaceFont.secondary.weight(.semibold) : WorkspaceFont.secondary)
        .foregroundStyle(active ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 6).padding(.vertical, 6)
        .frame(minHeight: 32)
        .overlay(alignment: .bottom) {
          Rectangle()
            .fill(active ? Color.accentColor : .clear)
            .frame(height: 2)
        }
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    // Before the padding, not after: a later modifier would attach the
    // identifier to the padding container and leave the button itself
    // anonymous in the accessibility tree.
    .accessibilityLabel(ViewerInspectorCopy.show(tab.title))
    .accessibilityAddTraits(active ? [.isSelected] : [])
    .padding(.trailing, 8)
    .accessibilityIdentifier("viewer.inspector.tab.\(tab.id)")
  }

  /// Pane chrome, not page chrome: a 12 pt content axis shared with the rows
  /// and the inspector below, with the detail trailing so titles stay flush
  /// left down the whole column.
  private func paneHeader<Trailing: View>(
    _ title: String, identifier: String, detail: String,
    @ViewBuilder trailing: () -> Trailing
  ) -> some View {
    HStack(spacing: 8) {
      // The identifier rides the title, not the header container: a container
      // identifier overwrites every descendant's, which is how the inspector
      // tabs and the separator once became unreachable.
      Text(title)
        .font(WorkspaceFont.secondary.weight(.semibold))
        .accessibilityIdentifier(identifier)
      Spacer(minLength: 8)
      if !detail.isEmpty {
        Text(detail)
          .font(WorkspaceFont.monospacedDense)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      trailing()
    }
    .padding(.horizontal, 12)
    .frame(height: 32)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
  }

  private func paneHeader(_ title: String, identifier: String, detail: String) -> some View {
    paneHeader(title, identifier: identifier, detail: detail) { EmptyView() }
  }

  private func fittedSize(container: CGSize, aspect: CGFloat) -> CGSize {
    guard aspect > 0 else { return .zero }
    let width = min(container.width - 24, (container.height - 24) * aspect)
    return CGSize(width: max(1, width), height: max(1, width / aspect))
  }
  private func state(_ value: Bool?) -> String? {
    value.map { $0 ? ViewerInspectorCopy.yes : ViewerInspectorCopy.no }
  }
  private func boundsText(_ value: ViewerBounds?) -> String? {
    guard let value else { return nil }
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

/// Search state lives in this leaf view so a keystroke never invalidates the
/// screenshot, outline tree, or the rest of the Viewer workspace. The result
/// list is lazy because a real componentDetail response commonly has hundreds
/// of fields and eagerly rebuilding every selectable value made deletion lag.
private struct AdvancedDumpInspectorView: View {
  let nodeIdentity: String
  let dumpNodeIdentity: String?
  let fields: [ViewerDumpField]
  let failure: String?
  let isLoading: Bool
  let retry: @MainActor () -> Void

  @State private var searchQuery = ""
  @State private var searchFocusRequestID: UInt64 = 0

  var body: some View {
    let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasQuery = !trimmedQuery.isEmpty
    let matches = matchingFields(query: trimmedQuery)

    VStack(alignment: .leading, spacing: 0) {
      searchBar(matchCount: matches.count, hasQuery: hasQuery)
      Divider()
      ScrollView {
        content(matches: matches, hasQuery: hasQuery)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func searchBar(matchCount: Int, hasQuery: Bool) -> some View {
    HStack(spacing: 8) {
      Button { searchFocusRequestID &+= 1 } label: {
        Image(systemName: "magnifyingglass")
          .frame(width: 24, height: 24)
          .contentShape(.rect)
      }
      .buttonStyle(.borderless)
      .keyboardShortcut("f", modifiers: [.command])
      .disabled(fields.isEmpty)
      .help(ViewerInspectorCopy.advancedSearchShortcut)
      .accessibilityLabel(ViewerInspectorCopy.advancedSearch)
      .accessibilityIdentifier("viewer.advancedDump.search.focus")

      ViewerSearchTextField(
        text: $searchQuery,
        placeholder: ViewerInspectorCopy.advancedSearchPlaceholder,
        accessibilityLabel: ViewerInspectorCopy.advancedSearch,
        focusRequestID: searchFocusRequestID,
        onCancel: { searchQuery = "" })
        .frame(minWidth: 180, maxWidth: 360)
        .frame(height: 22)
        .disabled(fields.isEmpty)
        .accessibilityIdentifier("viewer.advancedDump.search")

      Spacer(minLength: 0)

      if hasQuery {
        let summary = "\(matchCount) / \(fields.count)"
        Text(summary)
          .font(WorkspaceFont.monospacedDense.monospacedDigit())
          .foregroundStyle(.secondary)
          .accessibilityLabel(ViewerInspectorCopy.advancedSearchResults)
          .accessibilityValue(summary)
          .accessibilityIdentifier("viewer.advancedDump.search.matchCount")

        Button { searchQuery = "" } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(ViewerInspectorCopy.advancedSearchClear)
        .accessibilityLabel(ViewerInspectorCopy.advancedSearchClear)
        .accessibilityIdentifier("viewer.advancedDump.search.clear")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
  }

  @ViewBuilder
  private func content(matches: [IndexedField], hasQuery: Bool) -> some View {
    if isLoading, dumpNodeIdentity == nodeIdentity {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(verbatim: ViewerInspectorCopy.advancedLoading)
          .font(WorkspaceFont.secondary).foregroundStyle(.secondary)
      }
      .padding(.horizontal, 12).padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("viewer.advancedDump.loading")
    } else if dumpNodeIdentity == nodeIdentity, !fields.isEmpty {
      if matches.isEmpty, hasQuery {
        noResults
      } else {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(matches) { match in
            AdvancedDumpFieldRow(field: match.field)
              .equatable()
            Divider()
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    } else {
      VStack(alignment: .leading, spacing: 8) {
        Text(verbatim: failure ?? ViewerInspectorCopy.advancedUnavailable)
          .font(WorkspaceFont.secondary)
          .foregroundStyle(failure == nil ? Color.secondary : Color.red)
          .fixedSize(horizontal: false, vertical: true)
        if failure != nil {
          Button(ViewerInspectorCopy.retry) { retry() }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("viewer.advancedDump.retry")
        }
      }
      .padding(.horizontal, 12).padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("viewer.advancedDump")
    }
  }

  private var noResults: some View {
    VStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.title2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(verbatim: ViewerInspectorCopy.advancedSearchNoResults)
        .font(WorkspaceFont.secondary.weight(.semibold))
        .accessibilityLabel(
          "\(ViewerInspectorCopy.advancedSearchNoResults): \(searchQuery)")
        .accessibilityIdentifier("viewer.advancedDump.search.noResults")
      Text(verbatim: searchQuery)
        .font(WorkspaceFont.monospacedDense)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Button(ViewerInspectorCopy.advancedSearchClear) { searchQuery = "" }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("viewer.advancedDump.search.noResults.clear")
    }
    .padding(.horizontal, 12).padding(.vertical, 24)
    .frame(maxWidth: .infinity, alignment: .center)
  }

  private func matchingFields(query: String) -> [IndexedField] {
    let indexedFields = fields.enumerated().map { IndexedField(id: $0.offset, field: $0.element) }
    guard !query.isEmpty else { return indexedFields }
    return indexedFields.filter { match in
      match.field.key.localizedStandardContains(query)
        || match.field.value.localizedStandardContains(query)
    }
  }

  private struct IndexedField: Identifiable {
    let id: Int
    let field: ViewerDumpField
  }
}

private struct AdvancedDumpFieldRow: View, Equatable {
  let field: ViewerDumpField

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      Text(verbatim: field.key)
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(field.key)
        .frame(width: 134, alignment: .leading)
      Text(verbatim: ":")
        .font(WorkspaceFont.monospacedValue)
        .foregroundStyle(.secondary)
        .frame(width: 16, alignment: .leading)
      Text(verbatim: field.value)
        .font(WorkspaceFont.monospacedValue)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 12).padding(.vertical, 6)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(field.key) : \(field.value)")
    .accessibilityIdentifier("viewer.advancedDump.field.\(field.key)")
  }
}

/// Native search field whose explicit focus request also works when it comes
/// from a keyboard shortcut. SwiftUI focus can be handed back to the previous
/// responder after a menu key equivalent; AppKit's first responder request is
/// the durable source of truth for the caret.
private struct ViewerSearchTextField: NSViewRepresentable {
  @Binding var text: String
  let placeholder: String
  let accessibilityLabel: String
  let focusRequestID: UInt64
  let onCancel: @MainActor () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField(string: text)
    field.placeholderString = placeholder
    field.setAccessibilityLabel(accessibilityLabel)
    field.isBezeled = true
    field.bezelStyle = .roundedBezel
    field.focusRingType = .default
    field.isEditable = true
    field.isSelectable = true
    field.usesSingleLineMode = true
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    field.delegate = context.coordinator
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text { field.stringValue = text }
    context.coordinator.focusIfAsked(field, id: focusRequestID)
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: ViewerSearchTextField
    private var lastFocusRequestID: UInt64?

    init(_ parent: ViewerSearchTextField) { self.parent = parent }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.text = field.stringValue
    }

    func control(
      _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
      guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
      parent.onCancel()
      unsafe control.window?.makeFirstResponder(nil)
      return true
    }

    func focusIfAsked(_ field: NSTextField, id: UInt64) {
      guard id != 0, lastFocusRequestID != id else { return }
      lastFocusRequestID = id
      Task { @MainActor [weak field] in
        await Task.yield()
        guard let field, let window = unsafe field.window else { return }
        window.makeFirstResponder(field)
      }
    }
  }
}

enum ViewerInspectorTab: String {
  case properties, layout, accessibility, rawDump, advancedDump
  var id: String { rawValue }
  var title: String {
    switch self {
    case .properties: ViewerInspectorCopy.properties
    case .layout: ViewerInspectorCopy.layout
    case .accessibility: ViewerInspectorCopy.accessibility
    case .rawDump: ViewerInspectorCopy.rawDump
    case .advancedDump: ViewerInspectorCopy.advancedDump
    }
  }
}

/// Inspector vocabulary deliberately stays in English. These labels describe
/// provider fields and debugging concepts beside an English Raw dump; changing
/// them with the App locale makes the same concept wear two names in one pane.
private enum ViewerInspectorCopy {
  static let properties = "Properties"
  static let layout = "Layout"
  static let accessibility = "Accessibility"
  static let rawDump = "Raw dump"
  static let advancedDump = "Advanced Dump"
  static let identity = "Identity"
  static let state = "State"
  static let geometry = "Geometry"
  static let paint = "Paint"
  static let semantics = "Semantics"
  static let focus = "Focus"
  static let interactive = "Interactive"
  static let visible = "Visible"
  static let screenshotMapping = "screenshot mapping"
  static let hitTest = "hit test"
  static let accessibleLabel = "accessible label"
  static let description = "description"
  static let available = "Available"
  static let verified = "Verified"
  static let yes = "Yes"
  static let no = "No"
  static let selectPrompt = "Select a component"
  static let rawUnavailable = "Raw fields are unavailable"
  static let advancedUnavailable = "Select this tab to capture componentDetail fields"
  static let advancedLoading = "Capturing componentDetail…"
  static let advancedIdentifiersUnavailable =
    "This component has no numeric hostWindowId/componentId pair in the current capture"
  static let retry = "Retry"
  static let advancedSearch = "Search Advanced Dump"
  static let advancedSearchPlaceholder = "Search fields or values"
  static let advancedSearchShortcut = "Search Advanced Dump (⌘F)"
  static let advancedSearchResults = "Advanced Dump search results"
  static let advancedSearchClear = "Clear search"
  static let advancedSearchNoResults = "No matching fields or values"

  static func show(_ title: String) -> String { "Show \(title)" }
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
  private(set) var searchMatchIdentities: [String] = []
  private(set) var selectedSearchMatchIndex: Int?
  private(set) var selectionRevealGeneration = 0
  private(set) var visibleNodes: [ViewerNode] = []
  private(set) var showBounds = false
  private(set) var inspectorTreePercent: Double = 60
  private(set) var inspectorTab: ViewerInspectorTab = .properties
  private(set) var isRefreshing = false
  private(set) var isCapturing = false
  private(set) var isOpeningHistoryCapture = false
  private(set) var captureFailure: String?
  private(set) var advancedDumpNodeIdentity: String?
  private(set) var advancedDumpFields: [ViewerDumpField] = []
  private(set) var advancedDumpFailure: String?
  private(set) var isLoadingAdvancedDump = false
  private var advancedDumpGeneration = 0
  /// The App's shared device observation. Viewer never probes HDC itself; it
  /// reads this, so an unplug reaches the picker without anyone navigating.
  private(set) var deviceObservation = DeviceListPresentation.loading
  private(set) var deviceNames: [String: String] = [:]
  private let provider: any UIDumpApplicationProviding
  private var historyPinnedTargetID: String?
  private var captureGeneration = 0

  init(provider: any UIDumpApplicationProviding) { self.provider = provider }

  /// Adoption facts come from the durable target store; only the route is
  /// live, so the newest observation is re-joined on every read rather than
  /// frozen into  at refresh time.
  var targets: [UIDumpTargetPresentation] {
    UIDumpApplicationFacade.rejoin(targets: workspace.targets, with: deviceObservation)
  }

  func applyDeviceObservation(_ observation: DeviceListPresentation, names: [String: String]) {
    deviceObservation = observation
    deviceNames = names
  }

  /// What the picker calls a device: the name a person gave it, or the target
  /// it was adopted as — never a raw connect key, which identifies hardware
  /// and does not belong on screen.
  func deviceTitle(_ target: UIDumpTargetPresentation) -> String {
    let name = deviceNames[target.id] ?? target.id
    guard let reason = target.connection.failureReason else { return name }
    return "\(name) · \(reason)"
  }

  var selectedTarget: UIDumpTargetPresentation? { targets.first { $0.id == selectedTargetID } }
  var selectedNode: ViewerNode? { selectedNodeIdentity.flatMap { capture?.node(identity: $0) } }
  var hasSearchQuery: Bool {
    !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  var searchMatchSummary: String {
    guard let selectedSearchMatchIndex, !searchMatchIdentities.isEmpty else { return "0 / 0" }
    return "\(selectedSearchMatchIndex + 1) / \(searchMatchIdentities.count)"
  }
  var canNavigateSearchMatches: Bool { searchMatchIdentities.count > 1 }
  var emptyMessage: String {
    if let failure = workspace.targetLoadFailure { return failure }
    if selectedTarget == nil { return viewerText("viewer.empty.selectTarget") }
    if let reason = selectedTarget?.connection.failureReason {
      return String(
        localized: LocalizedStringResource.UIDumpLocalizable.viewerEmptyTargetBlocked(
          selectedTarget?.id ?? "", reason))
    }
    if case .unavailable(let reasons) = workspace.operation.availability { return reasons.joined(separator: "\n") }
    return viewerText("viewer.empty.explain")
  }
  var canRecapture: Bool {
    guard !isCapturing, !isOpeningHistoryCapture, selectedTarget?.isCaptureReady == true else {
      return false
    }
    if case .available = workspace.operation.availability { return true }
    return false
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
    let observation = deviceObservation
    Task { [weak self] in
      let next = await provider.refreshWorkspace(deviceObservation: observation)
      guard let self, !Task.isCancelled else { return }
      self.workspace = next
      self.selectedTargetID = self.preferredTargetID(in: self.targets)
      if self.selectedTarget?.isCaptureReady == false { self.captureFailure = nil }
      self.isRefreshing = false
    }
  }
  private func preferredTargetID(in targets: [UIDumpTargetPresentation]) -> String {
    // A History context names an exact target. If that target no longer
    // exists, keep the unmatched selection so recapture stays disabled rather
    // than silently switching the historical screen to another device.
    if let historyPinnedTargetID { return historyPinnedTargetID }
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
    captureGeneration &+= 1
    let generation = captureGeneration
    let provider = provider
    Task { [weak self] in
      let result = await provider.recapture(target: target)
      guard let self else { return }
      self.isCapturing = false
      guard !Task.isCancelled, self.captureGeneration == generation else { return }
      switch result {
      case .captured(let next): self.applyCapture(next)
      case .failed(let reason): self.captureFailure = reason
      }
      self.refresh()
    }
  }

  /// Opens the immutable Artifact set named by History. No operation is
  /// submitted and the resulting capture never grants permission to recapture.
  func openHistoryContext(_ context: RuntimeHistoryWorkspaceContext) {
    guard context.workspaceKind == .viewer else { return }
    captureGeneration &+= 1
    let generation = captureGeneration
    selectedTargetID = context.targetID
    historyPinnedTargetID = context.targetID
    isOpeningHistoryCapture = false
    resetAdvancedDump()
    // A previous record must not appear under the newly selected Job banner.
    capture = nil
    selectedNodeIdentity = nil
    updateVisibleNodes()
    guard let bindingRevision = context.bindingRevision else {
      captureFailure = "Historical Viewer context has no binding revision"
      return
    }
    isOpeningHistoryCapture = true
    captureFailure = nil
    let provider = provider
    Task { [weak self] in
      let result = await provider.loadHistoricalCapture(
        jobID: context.jobID,
        targetID: context.targetID,
        bindingRevision: bindingRevision)
      guard let self, self.captureGeneration == generation else { return }
      self.isOpeningHistoryCapture = false
      guard !Task.isCancelled else { return }
      switch result {
      case .captured(let capture): self.applyCapture(capture)
      case .failed(let reason): self.captureFailure = reason
      }
    }
  }

  private func applyCapture(_ next: ViewerCapture) {
    resetAdvancedDump()
    capture = next
    let root = next.primaryRootIdentity ?? ""
    selectedRootIdentity = root
    // A previous screen's query must not leave a fresh capture looking empty
    // or hide the row selected from the screenshot.
    searchQuery = ""
    searchMatchIdentities = []
    selectedSearchMatchIndex = nil
    expandedNodeIdentities = next.node(identity: root)?.children.isEmpty == false ? [root] : []
    updateVisibleNodes()
    select(root)
  }
  func setTargetID(_ value: String) {
    captureGeneration &+= 1
    isOpeningHistoryCapture = false
    historyPinnedTargetID = nil
    selectedTargetID = value
    captureFailure = nil
    resetAdvancedDump()
  }
  func setRoot(_ value: String) {
    guard let capture, let root = capture.node(identity: value) else { return }
    selectedRootIdentity = root.identity
    expandedNodeIdentities = root.children.isEmpty ? [] : [root.identity]
    if hasSearchQuery {
      updateSearchMatches(selectFirst: true)
    } else {
      select(root.identity)
    }
    updateVisibleNodes()
  }
  func setSearchQuery(_ value: String) {
    searchQuery = value
    updateSearchMatches(selectFirst: true)
    updateVisibleNodes()
  }
  func setShowBounds(_ value: Bool) { showBounds = value }
  func setInspectorTab(_ value: ViewerInspectorTab) {
    inspectorTab = value
    if value == .advancedDump { loadAdvancedDumpIfNeeded() }
  }
  func toggleExpansion(_ identity: String) {
    if !expandedNodeIdentities.insert(identity).inserted {
      expandedNodeIdentities.remove(identity)
    }
    updateVisibleNodes()
  }
  func adjustInspectorTree(by delta: Double) { setInspectorTree(percent: inspectorTreePercent - delta / 8) }
  /// Resizing is presentation only. It must never touch `selectedNodeIdentity`,
  /// or dragging the separator would silently move the inspected node.
  func setInspectorTree(percent: Double) { inspectorTreePercent = min(68, max(35, percent)) }
  func select(in capture: ViewerCapture, at location: CGPoint, renderedSize: CGSize) {
    guard renderedSize.width > 0, renderedSize.height > 0 else { return }
    let screenshotX = Double(location.x / renderedSize.width) * Double(capture.screenshotWidth)
    let screenshotY = Double(location.y / renderedSize.height) * Double(capture.screenshotHeight)
    guard let node = ViewerHitTesting.node(
      in: capture, rootIdentity: selectedRootIdentity,
      x: screenshotX, y: screenshotY)
    else {
      return
    }
    select(node.identity)
  }
  func select(_ identity: String) {
    guard let capture, let node = capture.node(identity: identity) else { return }
    if selectedNodeIdentity != node.identity { resetAdvancedDump() }
    selectedNodeIdentity = node.identity
    expandedNodeIdentities.formUnion(capture.ancestors(of: node.identity))
    updateVisibleNodes()
    if let index = searchMatchIdentities.firstIndex(of: node.identity) {
      selectedSearchMatchIndex = index
    }
    // A repeated click is still a reveal request. The row may have been moved
    // away from center manually even though its identity did not change.
    selectionRevealGeneration &+= 1
    if inspectorTab == .advancedDump { loadAdvancedDumpIfNeeded() }
  }

  func retryAdvancedDump() {
    resetAdvancedDump()
    loadAdvancedDumpIfNeeded()
  }

  private func resetAdvancedDump() {
    advancedDumpGeneration &+= 1
    advancedDumpNodeIdentity = nil
    advancedDumpFields = []
    advancedDumpFailure = nil
    isLoadingAdvancedDump = false
  }

  private func loadAdvancedDumpIfNeeded() {
    guard inspectorTab == .advancedDump, !isLoadingAdvancedDump,
      let capture, let nodeIdentity = selectedNodeIdentity,
      advancedDumpNodeIdentity != nodeIdentity,
      let target = selectedTarget,
      capture.identity.targetID == target.id,
      capture.identity.bindingRevision == target.bindingRevision
    else { return }
    guard let selection = capture.advancedDumpSelection(for: nodeIdentity) else {
      advancedDumpNodeIdentity = nodeIdentity
      advancedDumpFailure = ViewerInspectorCopy.advancedIdentifiersUnavailable
      return
    }
    advancedDumpNodeIdentity = nodeIdentity
    advancedDumpFields = []
    advancedDumpFailure = nil
    isLoadingAdvancedDump = true
    let generation = advancedDumpGeneration
    let provider = provider
    let captureJobID = capture.identity.jobID
    Task { [weak self] in
      let result = await provider.advancedDump(target: target, selection: selection)
      guard let self, !Task.isCancelled,
        self.capture?.identity.jobID == captureJobID,
        self.selectedNodeIdentity == nodeIdentity,
        self.advancedDumpGeneration == generation
      else { return }
      self.isLoadingAdvancedDump = false
      switch result {
      case .captured(let fields): self.advancedDumpFields = fields
      case .failed(let reason): self.advancedDumpFailure = reason
      }
    }
  }

  private func updateSearchMatches(selectFirst: Bool) {
    guard let capture, hasSearchQuery else {
      searchMatchIdentities = []
      selectedSearchMatchIndex = nil
      return
    }
    searchMatchIdentities = capture.searchMatches(
      rootIdentity: selectedRootIdentity,
      query: searchQuery
    ).map(\.identity)
    guard !searchMatchIdentities.isEmpty else {
      selectedSearchMatchIndex = nil
      return
    }
    if selectFirst || selectedSearchMatchIndex == nil {
      selectedSearchMatchIndex = 0
      select(searchMatchIdentities[0])
    }
  }

  private func updateVisibleNodes() {
    guard let capture else {
      visibleNodes = []
      return
    }
    visibleNodes = capture.visibleTreeNodes(
      rootIdentity: selectedRootIdentity,
      query: searchQuery,
      expandedNodeIdentities: expandedNodeIdentities)
  }

  func selectPreviousSearchMatch() { moveSearchMatch(by: -1) }
  func selectNextSearchMatch() { moveSearchMatch(by: 1) }

  private func moveSearchMatch(by offset: Int) {
    guard !searchMatchIdentities.isEmpty else { return }
    let current = selectedSearchMatchIndex ?? 0
    let next = (current + offset + searchMatchIdentities.count) % searchMatchIdentities.count
    selectedSearchMatchIndex = next
    select(searchMatchIdentities[next])
  }
  // MARK: - macOS outline keyboard model
  //
  // Movement walks `visibleNodes`, which is the same collapsed/filtered row set
  // the tree draws. Anything else would let the keyboard land on a row the user
  // cannot see. Every move is a selection change only: it never edits the
  // capture, and left/right only touch expansion state.

  /// Moves the selection `offset` rows through the currently visible set.
  func moveSelection(by offset: Int) {
    let rows = visibleNodes
    guard !rows.isEmpty else { return }
    guard let current = selectedNodeIdentity,
      let index = rows.firstIndex(where: { $0.identity == current })
    else {
      select(rows[0].identity)
      return
    }
    let next = min(rows.count - 1, max(0, index + offset))
    select(rows[next].identity)
  }

  func moveSelectionToEdge(first: Bool) {
    let rows = visibleNodes
    guard let node = first ? rows.first : rows.last else { return }
    select(node.identity)
  }

  /// Left: collapse an open node, otherwise step out to the parent.
  func collapseOrSelectParent() {
    guard let identity = selectedNodeIdentity, let node = capture?.node(identity: identity) else { return }
    if !node.children.isEmpty, expandedNodeIdentities.contains(identity) {
      expandedNodeIdentities.remove(identity)
      updateVisibleNodes()
      return
    }
    if let parent = node.parentIdentity { select(parent) }
  }

  /// Right: open a closed node, otherwise step into its first child.
  func expandOrSelectFirstChild() {
    guard let identity = selectedNodeIdentity, let node = capture?.node(identity: identity),
      !node.children.isEmpty
    else { return }
    if !expandedNodeIdentities.contains(identity) {
      expandedNodeIdentities.insert(identity)
      updateVisibleNodes()
      return
    }
    if let child = node.children.first { select(child) }
  }

  func nodeTitle(_ identity: String) -> String? { capture?.node(identity: identity).map { "#\($0.deviceID ?? "—") \($0.type)" } }
  func breadcrumb(for identity: String) -> String {
    guard let capture else { return "" }
    return (capture.ancestors(of: identity) + [identity]).compactMap { nodeTitle($0) }.joined(separator: " › ")
  }
}

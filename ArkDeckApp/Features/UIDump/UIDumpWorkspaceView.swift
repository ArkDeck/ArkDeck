import AppKit
import ArkDeckWorkflows
import Observation
import SwiftUI

/// A Job-bound inspection surface. It deliberately has no command, argv,
/// remote-path, Recipe, or parameter-policy input.
struct UIDumpWorkspaceView: View {
  var model: UIDumpWorkspaceViewModel
  @FocusState private var separatorFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        if let capture = model.capture {
          Divider()
          footer(capture)
        }
      }
    }
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
      TextField(viewerText("viewer.toolbar.search"), text: queryBinding)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 250)
        .accessibilityIdentifier("viewer.search")
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
      }
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
      .contentShape(Rectangle())
      .gesture(SpatialTapGesture().onEnded { value in
        model.select(in: capture, at: value.location, renderedSize: content)
      })
      .accessibilityLabel(viewerText("viewer.screenshot.selectLabel"))
      .accessibilityHint(viewerText("viewer.screenshot.selectHint"))
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
      GeometryReader { proxy in
        ScrollViewReader { reader in
          ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 1) {
              ForEach(rows) { node in
                treeRow(
                  node,
                  visualDepth: max(0, node.depth - minimumDepth),
                  maximumVisualDepth: max(0, maximumDepth - minimumDepth),
                  viewportWidth: proxy.size.width)
                  .id(node.identity)
              }
              if rows.isEmpty {
                Text(viewerText("viewer.tree.noMatches"))
                  .foregroundStyle(.secondary).padding(12)
              }
            }
            .padding(.vertical, 6)
          }
          .onChange(of: model.selectedNodeIdentity) { _, identity in
            guard let identity else { return }
            // Reduce Motion users get the same reveal without the slide, and a
            // selection change never becomes a large moving surface.
            if reduceMotion {
              reader.scrollTo(identity, anchor: UnitPoint(x: 0, y: 0.5))
            } else {
              withAnimation(.easeOut(duration: 0.15)) {
                reader.scrollTo(identity, anchor: UnitPoint(x: 0, y: 0.5))
              }
            }
          }
        }
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

  /// One row, one button, sized to its own content.
  ///
  /// The selection fill is an inset capsule rather than a full-bleed band, and
  /// the disclosure chevron lives inside the row's hit area so the row never
  /// needs two competing controls. `#id` trails the label inline: a deep tree
  /// scrolls horizontally, so there is no fixed right edge to align a column
  /// to, and the node's own name must never be truncated to make one.
  private func treeRow(
    _ node: ViewerNode,
    visualDepth: Int,
    maximumVisualDepth: Int,
    viewportWidth: CGFloat
  ) -> some View {
    let selected = node.identity == model.selectedNodeIdentity
    let expanded = model.expandedNodeIdentities.contains(node.identity)
    return Button { model.select(node.identity) } label: {
      HStack(spacing: 6) {
        Group {
          if node.children.isEmpty {
            Color.clear
          } else {
            Image(systemName: "chevron.right")
              .font(.system(size: 9, weight: .semibold))
              .rotationEffect(.degrees(expanded ? 90 : 0))
          }
        }
        .frame(width: 16, height: 16)
        .contentShape(Rectangle())
        .onTapGesture { model.toggleExpansion(node.identity) }

        Image(systemName: Self.symbol(for: node.type))
          .font(WorkspaceFont.caption)
          .frame(width: 16, height: 16)
          .opacity(selected ? 0.95 : 0.65)

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
      .frame(minHeight: 26, alignment: .leading)
      // The floor keeps the selection capsule spanning the visible pane; the
      // content decides the real width so nothing is truncated or wrapped.
      .frame(minWidth: max(0, viewportWidth - 12), alignment: .leading)
      .contentShape(Rectangle())
      .foregroundStyle(selected ? Color.white : Color.primary)
      .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 6)
    .accessibilityValue(
      selected ? viewerText("viewer.tree.selected") : viewerText("viewer.tree.notSelected"))
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
      .contentShape(Rectangle())
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
        HStack(spacing: 0) {
          inspectorTabButton(.properties)
          inspectorTabButton(.layout)
          inspectorTabButton(.accessibility)
          inspectorTabButton(.rawDump)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        Divider()
        ScrollView {
          inspectorContent(node, capture: capture)
            .frame(maxWidth: .infinity, alignment: .leading)
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
      .overlay(Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
  }

  /// Grouped, because a flat run of a dozen identical rows reads as a dump
  /// rather than an inspector. Identity, state, and geometry answer different
  /// questions and are scanned separately.
  @ViewBuilder
  private func inspectorContent(_ node: ViewerNode, capture: ViewerCapture) -> some View {
    switch model.inspectorTab {
    case .properties:
      keyValueGroup(ViewerInspectorCopy.identity, [
        ("id", node.deviceID ?? ViewerInspectorCopy.unavailable),
        ("type", node.type),
        ("inspectorId", node.inspectorID ?? ViewerInspectorCopy.unavailable),
        ("text", node.text ?? ViewerInspectorCopy.unavailable),
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
           ? ViewerInspectorCopy.verified : ViewerInspectorCopy.unavailable),
        (ViewerInspectorCopy.hitTest,
         ViewerScreenshotMapping.visibleBounds(of: node, in: capture) != nil
           ? ViewerInspectorCopy.available : ViewerInspectorCopy.unavailable),
      ])
      keyValueGroup(ViewerInspectorCopy.paint, [
        ("zIndex", node.zIndex.map { String($0) } ?? ViewerInspectorCopy.unavailable),
      ])
    case .accessibility:
      keyValueGroup(ViewerInspectorCopy.semantics, [
        (ViewerInspectorCopy.accessibleLabel, node.text ?? ViewerInspectorCopy.unavailable),
        (ViewerInspectorCopy.description, node.inspectorID ?? ViewerInspectorCopy.unavailable),
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
    }
  }

  private func keyValueGroup(_ title: String, _ rows: [(String, String)]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(verbatim: title)
        .font(WorkspaceFont.label)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
      Divider()
      ForEach(rows, id: \.0) { name, value in
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
        .contentShape(Rectangle())
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
  private func state(_ value: Bool?) -> String {
    value.map { $0 ? ViewerInspectorCopy.yes : ViewerInspectorCopy.no }
      ?? ViewerInspectorCopy.unavailable
  }
  private func boundsText(_ value: ViewerBounds?) -> String {
    guard let value else { return ViewerInspectorCopy.unavailable }
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
  var title: String {
    switch self {
    case .properties: ViewerInspectorCopy.properties
    case .layout: ViewerInspectorCopy.layout
    case .accessibility: ViewerInspectorCopy.accessibility
    case .rawDump: ViewerInspectorCopy.rawDump
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
  static let unavailable = "Unavailable"
  static let verified = "Verified"
  static let yes = "Yes"
  static let no = "No"
  static let selectPrompt = "Select a component"
  static let rawUnavailable = "Raw fields are unavailable"

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
  private(set) var showBounds = false
  private(set) var inspectorTreePercent: Double = 60
  private(set) var inspectorTab: ViewerInspectorTab = .properties
  private(set) var isRefreshing = false
  private(set) var isCapturing = false
  private(set) var captureFailure: String?
  /// The App's shared device observation. Viewer never probes HDC itself; it
  /// reads this, so an unplug reaches the picker without anyone navigating.
  private(set) var deviceObservation = DeviceListPresentation.loading
  private(set) var deviceNames: [String: String] = [:]
  private let provider: any UIDumpApplicationProviding

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
        let root = next.primaryRootIdentity ?? ""
        self.selectedRootIdentity = root
        // A previous screen's query must not leave a fresh capture looking
        // empty or hide the row selected from the screenshot.
        self.searchQuery = ""
        self.expandedNodeIdentities = next.node(identity: root)?.children.isEmpty == false
          ? [root] : []
        self.select(root)
      case .failed(let reason): self.captureFailure = reason
      }
      self.refresh()
    }
  }
  func setTargetID(_ value: String) {
    selectedTargetID = value
    captureFailure = nil
  }
  func setRoot(_ value: String) {
    guard let capture, let root = capture.node(identity: value) else { return }
    selectedRootIdentity = root.identity
    expandedNodeIdentities = root.children.isEmpty ? [] : [root.identity]
    select(root.identity)
  }
  func setSearchQuery(_ value: String) { searchQuery = value }
  func setShowBounds(_ value: Bool) { showBounds = value }
  func setInspectorTab(_ value: ViewerInspectorTab) { inspectorTab = value }
  func toggleExpansion(_ identity: String) { if !expandedNodeIdentities.insert(identity).inserted { expandedNodeIdentities.remove(identity) } }
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
    selectedNodeIdentity = node.identity
    expandedNodeIdentities.formUnion(capture.ancestors(of: node.identity))
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

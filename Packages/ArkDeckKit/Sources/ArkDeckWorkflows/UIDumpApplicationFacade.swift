// App-facing Viewer projection over the Runtime's typed XPC door.
//
// Viewer is deliberately not a command surface. It submits only the
// published capture.diagnostics@1 request, pins an adopted target/binding,
// and reads immutable Job-bound Artifacts through the bounded Runtime API.

import ArkDeckCore
import ArkDeckRuntime
import CryptoKit
import Foundation

public enum UIDumpRuntimeAvailability: Sendable, Equatable {
  case checking
  case available
  case unavailable(reasons: [String])
}

public struct UIDumpOperationPresentation: Sendable, Equatable {
  public let reference: String
  public let title: String
  public let availability: UIDumpRuntimeAvailability
  public let minimumEffect: String
  public let permittedEffects: [String]

  public init(
    reference: String,
    title: String,
    availability: UIDumpRuntimeAvailability,
    minimumEffect: String,
    permittedEffects: [String]
  ) {
    self.reference = reference
    self.title = title
    self.availability = availability
    self.minimumEffect = minimumEffect
    self.permittedEffects = permittedEffects
  }
}

public struct UIDumpTargetPresentation: Sendable, Equatable, Identifiable {
  public let id: String
  public let bindingRevision: Int
  public let toolVersion: String
  public let adoptedAtUTC: String
  /// A fresh `device.candidates` observation joined to this durable target.
  /// Viewer must never turn a historical target record into permission to
  /// capture: only a current Connected route can submit the typed request.
  public let connection: UIDumpTargetConnection

  public init(
    id: String,
    bindingRevision: Int,
    toolVersion: String,
    adoptedAtUTC: String,
    connection: UIDumpTargetConnection = .unavailable(
      reason: "No current HDC route was reported for this target")
  ) {
    self.id = id
    self.bindingRevision = bindingRevision
    self.toolVersion = toolVersion
    self.adoptedAtUTC = adoptedAtUTC
    self.connection = connection
  }

  public var isCaptureReady: Bool { connection.isCaptureReady }
  public var pickerTitle: String { "\(id) · \(connection.displayName)" }
}

public enum UIDumpTargetConnection: Sendable, Equatable {
  case connected
  case unavailable(reason: String)

  public var isCaptureReady: Bool {
    if case .connected = self { return true }
    return false
  }

  public var displayName: String {
    switch self {
    case .connected: "Connected"
    case .unavailable: "Unavailable"
    }
  }

  public var failureReason: String? {
    if case .unavailable(let reason) = self { return reason }
    return nil
  }
}

public struct UIDumpJobPresentation: Sendable, Equatable, Identifiable {
  public let id: String
  public let targetID: String
  public let state: String
  public let waitingForHuman: Bool
  public let outcomeUnknown: Bool
  public let outstandingResidueCount: Int
  public let finishedAtUTC: String?

  public init(
    id: String,
    targetID: String,
    state: String,
    waitingForHuman: Bool,
    outcomeUnknown: Bool,
    outstandingResidueCount: Int,
    finishedAtUTC: String? = nil
  ) {
    self.id = id
    self.targetID = targetID
    self.state = state
    self.waitingForHuman = waitingForHuman
    self.outcomeUnknown = outcomeUnknown
    self.outstandingResidueCount = outstandingResidueCount
    self.finishedAtUTC = finishedAtUTC
  }

  public var needsAttention: Bool {
    waitingForHuman || outcomeUnknown || outstandingResidueCount > 0
  }
}

public struct UIDumpWorkspacePresentation: Sendable, Equatable {
  public let operation: UIDumpOperationPresentation
  public let targets: [UIDumpTargetPresentation]
  public let relatedJobs: [UIDumpJobPresentation]
  public let targetLoadFailure: String?
  public let jobLoadFailure: String?

  public init(
    operation: UIDumpOperationPresentation,
    targets: [UIDumpTargetPresentation],
    relatedJobs: [UIDumpJobPresentation],
    targetLoadFailure: String? = nil,
    jobLoadFailure: String? = nil
  ) {
    self.operation = operation
    self.targets = targets
    self.relatedJobs = relatedJobs
    self.targetLoadFailure = targetLoadFailure
    self.jobLoadFailure = jobLoadFailure
  }

  public static let loading = UIDumpWorkspacePresentation(
    operation: UIDumpApplicationFacade.operationPresentation(availability: .checking),
    targets: [], relatedJobs: [])
}

public struct ViewerCaptureIdentity: Sendable, Equatable {
  public let jobID: String
  public let targetID: String
  public let bindingRevision: Int
  public let capturedAtUTC: String

  public init(jobID: String, targetID: String, bindingRevision: Int, capturedAtUTC: String) {
    self.jobID = jobID
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.capturedAtUTC = capturedAtUTC
  }
}

public struct ViewerBounds: Sendable, Equatable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init?(x: Double, y: Double, width: Double, height: Double) {
    guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
      width >= 0, height >= 0
    else { return nil }
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public func contains(x pointX: Double, y pointY: Double) -> Bool {
    pointX >= x && pointY >= y && pointX <= x + width && pointY <= y + height
  }

  public func intersection(_ other: ViewerBounds) -> ViewerBounds? {
    let left = max(x, other.x)
    let top = max(y, other.y)
    let right = min(x + width, other.x + other.width)
    let bottom = min(y + height, other.y + other.height)
    guard right > left, bottom > top else { return nil }
    return ViewerBounds(x: left, y: top, width: right - left, height: bottom - top)
  }
}

/// Maps provider geometry into the pixels the screenshot can actually show.
/// Dumps may publish a partially off-screen window or node. Letting that raw
/// rectangle drive SwiftUI's frame makes the outline escape the image and
/// makes its accessibility hit area disagree with the visible screenshot.
public enum ViewerScreenshotMapping {
  public static func visibleBounds(
    _ bounds: ViewerBounds?, screenshotWidth: Int, screenshotHeight: Int
  ) -> ViewerBounds? {
    guard screenshotWidth > 0, screenshotHeight > 0, let bounds,
      let viewport = ViewerBounds(
        x: 0, y: 0, width: Double(screenshotWidth), height: Double(screenshotHeight))
    else { return nil }
    return bounds.intersection(viewport)
  }

  /// Returns the pixels of one node that are actually visible in the capture.
  /// ArkUI publishes a node's bounds separately from the `clip` flags on its
  /// ancestors. A list item can therefore have valid screen coordinates and
  /// still be partly outside the list or swiper viewport. Screenshot outlines
  /// and pointer hit testing must use the same accumulated clipping rectangle.
  public static func visibleBounds(
    of node: ViewerNode,
    in capture: ViewerCapture
  ) -> ViewerBounds? {
    guard capture.coordinatesAreVerified,
      var visible = visibleBounds(
      node.bounds,
      screenshotWidth: capture.screenshotWidth,
      screenshotHeight: capture.screenshotHeight)
    else { return nil }

    var cursor = node.parentIdentity
    var visited: Set<String> = []
    while let identity = cursor,
      visited.insert(identity).inserted,
      let ancestor = capture.node(identity: identity)
    {
      if ancestor.clipsChildren {
        guard let ancestorBounds = visibleBounds(
          ancestor.bounds,
          screenshotWidth: capture.screenshotWidth,
          screenshotHeight: capture.screenshotHeight),
          let clipped = visible.intersection(ancestorBounds)
        else { return nil }
        visible = clipped
      }
      cursor = ancestor.parentIdentity
    }
    return visible
  }
}

/// Keeps deep outline rows readable at the scroll view's leading position.
/// The tree still grows horizontally for long labels, but depth alone cannot
/// consume the whole viewport and leave only the selected background visible.
public enum ViewerTreeLayoutPolicy {
  public static func leadingIndent(
    depth: Int,
    maximumDepth: Int,
    viewportWidth: Double
  ) -> Double {
    guard viewportWidth.isFinite, viewportWidth > 0 else { return 6 }
    let baseIndent = 6.0
    let normalizedDepth = max(0, depth)
    let normalizedMaximumDepth = max(normalizedDepth, maximumDepth, 1)
    let minimumContentWidth = max(180, viewportWidth * 0.4)
    let maximumIndent = max(6, viewportWidth - minimumContentWidth)
    // Fit ordinary trees with a comfortable 18 pt step. For a fifty-level
    // real dump, reduce every step evenly instead of clamping the deepest
    // rows onto one leading edge. Extremely deep provider data keeps an 8 pt
    // step and uses the tree's horizontal scroll rather than losing hierarchy.
    let availableIndent = max(0, maximumIndent - baseIndent)
    let adaptiveStep = availableIndent / Double(normalizedMaximumDepth)
    let step = max(8, min(18, adaptiveStep))
    return baseIndent + Double(normalizedDepth) * step
  }
}

/// `identity` is private to one immutable capture. `deviceID` is only the
/// source value when it was supplied by the dump, never a synthesized path.
public struct ViewerNode: Sendable, Equatable, Identifiable {
  public let identity: String
  public let deviceID: String?
  public let parentIdentity: String?
  public let children: [String]
  public let type: String
  public let text: String?
  public let inspectorID: String?
  public let bounds: ViewerBounds?
  public let visible: Bool
  public let enabled: Bool?
  public let clickable: Bool?
  public let focusable: Bool?
  public let focused: Bool?
  public let clipsChildren: Bool
  public let hitTestBehavior: String?
  public let zIndex: Double?
  public let depth: Int
  public let rawFields: Data

  public var id: String { identity }

  /// `None` and `Transparent` nodes remain inspectable from the tree, but a
  /// coordinate click must pass through them just as it does on the device.
  /// Otherwise a full-screen transparent overlay can make every component
  /// behind it impossible to select from the screenshot.
  public var acceptsPointerHit: Bool {
    guard let behavior = hitTestBehavior?.lowercased() else { return true }
    return behavior != "none"
      && behavior != "transparent"
      && behavior != "hittestmode.none"
      && behavior != "hittestmode.transparent"
  }
}

/// One selected-component field prepared for the Viewer's key/value inspector.
///
/// The device owns both strings. Keeping this projection separate from
/// `ViewerNode` means an unknown provider field remains inspectable without
/// turning it into a field ArkDeck claims to understand.
public struct ViewerDumpField: Sendable, Equatable {
  public let key: String
  public let value: String

  public init(key: String, value: String) {
    self.key = key
    self.value = value
  }
}

/// The two ArkUI identifiers accepted by the published `componentDetail`
/// recipe. Both values originate in one immutable ui-tree Artifact; no App
/// surface can supply argv or a remote path.
public struct ViewerAdvancedDumpSelection: Sendable, Equatable {
  public let windowID: String
  public let componentID: String

  public init(windowID: String, componentID: String) {
    self.windowID = windowID
    self.componentID = componentID
  }
}

public enum ViewerAdvancedDumpSubmissionResult: Sendable, Equatable {
  case captured([ViewerDumpField])
  case failed(String)
}

public enum ViewerAdvancedDumpParser {
  public static func parse(_ data: Data) throws -> [ViewerDumpField] {
    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
      throw ViewerCaptureFailure.invalidAdvancedDump
    }
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      let fields = object.keys.sorted().compactMap { key -> ViewerDumpField? in
        guard let value = fieldValue(object[key]) else { return nil }
        return ViewerDumpField(key: key, value: value)
      }
      if !fields.isEmpty { return fields }
    }

    var fields: [ViewerDumpField] = []
    for rawLine in text.split(whereSeparator: \Character.isNewline) {
      let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
      guard let separator = line.firstIndex(of: ":") else { continue }
      let rawKey = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
      let key = rawKey.trimmingCharacters(
        in: CharacterSet(charactersIn: "|`+-=>[]{} "))
      let value = line[line.index(after: separator)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty else { continue }
      fields.append(ViewerDumpField(key: key, value: value))
    }
    guard !fields.isEmpty else {
      let normalized = text.lowercased()
      if normalized.contains("arkui-comp.dump") || normalized.contains("arkui.dump") {
        throw ViewerCaptureFailure.advancedDumpRequiresSidecar
      }
      throw ViewerCaptureFailure.invalidAdvancedDump
    }
    return fields
  }

  private static func fieldValue(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return "null" }
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    guard JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

public struct ViewerCapture: Sendable, Equatable {
  public let screenshotData: Data
  public let screenshotWidth: Int
  public let screenshotHeight: Int
  public let roots: [String]
  public let nodes: [ViewerNode]
  public let rawDumpDocument: Data?
  public let identity: ViewerCaptureIdentity
  public let coordinatesAreVerified: Bool
  /// What this capture cost to produce. `nil` for a capture that was not
  /// measured — a fixture, or a decode in a test — so the UI can say "not
  /// measured" instead of reporting a fabricated zero.
  public let metrics: ViewerCaptureMetrics?
  private let nodeIndex: [String: ViewerNode]

  public init(
    screenshotData: Data,
    screenshotWidth: Int,
    screenshotHeight: Int,
    roots: [String],
    nodes: [ViewerNode],
    rawDumpDocument: Data?,
    identity: ViewerCaptureIdentity,
    coordinatesAreVerified: Bool,
    metrics: ViewerCaptureMetrics? = nil
  ) {
    self.screenshotData = screenshotData
    self.screenshotWidth = screenshotWidth
    self.screenshotHeight = screenshotHeight
    self.roots = roots
    self.nodes = nodes
    self.rawDumpDocument = rawDumpDocument
    self.identity = identity
    self.coordinatesAreVerified = coordinatesAreVerified
    self.metrics = metrics
    // A capture is immutable. Build its lookup table exactly once so Viewer
    // rendering never turns a large device tree into repeated linear scans.
    var index: [String: ViewerNode] = [:]
    for node in nodes where index[node.identity] == nil {
      index[node.identity] = node
    }
    self.nodeIndex = index
  }

  public func node(identity: String) -> ViewerNode? {
    nodeIndex[identity]
  }

  /// Prefer the foreground window fact from the Artifact. Provider order is
  /// retained only when no unique focused root is available.
  public var primaryRootIdentity: String? {
    let focusedRoots = roots.filter { nodeIndex[$0]?.focused == true }
    return focusedRoots.count == 1 ? focusedRoots[0] : roots.first
  }

  /// Returns the same capture with its measured cost attached. Parsing is
  /// itself one of the measured stages, so the number cannot exist until after
  /// the capture does.
  public func withMetrics(_ metrics: ViewerCaptureMetrics) -> ViewerCapture {
    ViewerCapture(
      screenshotData: screenshotData, screenshotWidth: screenshotWidth,
      screenshotHeight: screenshotHeight, roots: roots, nodes: nodes,
      rawDumpDocument: rawDumpDocument, identity: identity,
      coordinatesAreVerified: coordinatesAreVerified, metrics: metrics)
  }

  public func ancestors(of identity: String) -> [String] {
    var result: [String] = []
    var cursor = node(identity: identity)?.parentIdentity
    var visited: Set<String> = []
    while let value = cursor,
      visited.insert(value).inserted,
      let node = node(identity: value)
    {
      result.append(value)
      cursor = node.parentIdentity
    }
    return result.reversed()
  }

  /// Returns the visible tree rows with a bounded traversal. UI trees are
  /// provider data, so duplicate links or an unexpected cycle must neither
  /// recurse forever nor make the App's main thread unavailable.
  public func visibleTreeNodes(
    rootIdentity: String?,
    query: String,
    expandedNodeIdentities: Set<String>
  ) -> [ViewerNode] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let roots: [String]
    if let rootIdentity, !rootIdentity.isEmpty {
      roots = nodeIndex[rootIdentity] == nil ? [] : [rootIdentity]
    } else {
      roots = self.roots
    }

    var included: Set<String> = []
    if !normalizedQuery.isEmpty {
      let matches = Set(
        searchMatches(rootIdentity: rootIdentity, query: normalizedQuery).map(\.identity))
      guard !matches.isEmpty else { return [] }
      included = matches
      for match in matches {
        var cursor = nodeIndex[match]?.parentIdentity
        var visited: Set<String> = []
        while let value = cursor,
          visited.insert(value).inserted,
          let node = nodeIndex[value]
        {
          included.insert(value)
          cursor = node.parentIdentity
        }
      }
    }

    var rows: [ViewerNode] = []
    var visited: Set<String> = []
    func visit(_ identity: String) {
      guard visited.insert(identity).inserted,
        let node = nodeIndex[identity],
        normalizedQuery.isEmpty || included.contains(identity)
      else { return }
      rows.append(node)
      if !normalizedQuery.isEmpty || expandedNodeIdentities.contains(identity) {
        node.children.forEach(visit)
      }
    }
    roots.forEach(visit)
    return rows
  }

  /// Exact search hits in stable provider/tree order. Ancestors are excluded:
  /// they remain visible in the filtered outline only as navigation context
  /// and must not inflate the result counter or become Next/Previous targets.
  public func searchMatches(rootIdentity: String?, query: String) -> [ViewerNode] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalizedQuery.isEmpty else { return [] }
    return subtreeNodes(rootIdentity: rootIdentity).filter { node in
      [node.type, node.text, node.deviceID, node.inspectorID]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
        .contains(normalizedQuery)
    }
  }

  /// The screenshot overlay only needs the selected root's subtree. This
  /// avoids computing every node's ancestor chain during each redraw.
  public func subtreeNodes(rootIdentity: String?) -> [ViewerNode] {
    guard let rootIdentity, !rootIdentity.isEmpty else { return nodes }
    guard nodeIndex[rootIdentity] != nil else { return [] }
    var included: Set<String> = []
    var pending = [rootIdentity]
    while let identity = pending.popLast(), included.insert(identity).inserted {
      pending.append(contentsOf: nodeIndex[identity]?.children ?? [])
    }
    return nodes.filter { included.contains($0.identity) }
  }

  public func formattedRawFields(for identity: String) -> String? {
    guard let data = node(identity: identity)?.rawFields,
      let object = try? JSONSerialization.jsonObject(with: data)
    else { return nil }
    let selectedComponent: Any
    if var fields = object as? [String: Any] {
      fields.removeValue(forKey: "children")
      selectedComponent = fields
    } else {
      selectedComponent = object
    }
    guard JSONSerialization.isValidJSONObject(selectedComponent),
      let formatted = try? JSONSerialization.data(
        withJSONObject: selectedComponent, options: [.prettyPrinted, .sortedKeys])
    else { return nil }
    return String(data: formatted, encoding: .utf8)
  }

  /// Resolves the selected component id and its nearest enclosing host window
  /// from the immutable tree. Some provider revisions repeat hostWindowId on
  /// every node while others publish it only on the window root, so ancestry
  /// is the bounded and truthful fallback.
  public func advancedDumpSelection(for identity: String) -> ViewerAdvancedDumpSelection? {
    guard let selected = node(identity: identity),
      let componentID = Self.decimalIdentifier(selected.deviceID)
    else { return nil }
    var cursor: String? = selected.identity
    var visited: Set<String> = []
    while let value = cursor, visited.insert(value).inserted, let candidate = node(identity: value) {
      if let windowID = Self.hostWindowID(in: candidate.rawFields) {
        return ViewerAdvancedDumpSelection(windowID: windowID, componentID: componentID)
      }
      cursor = candidate.parentIdentity
    }
    return nil
  }

  private static func hostWindowID(in data: Data) -> String? {
    guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    let fields = document["attributes"] as? [String: Any] ?? document
    if let value = fields["hostWindowId"] as? String { return decimalIdentifier(value) }
    if let value = fields["hostWindowId"] as? NSNumber {
      return decimalIdentifier(value.stringValue)
    }
    return nil
  }

  private static func decimalIdentifier(_ value: String?) -> String? {
    guard let value, !value.isEmpty, value.count <= 20,
      value.allSatisfy({ $0.isASCII && $0.isNumber })
    else { return nil }
    return value
  }
}

public enum ViewerCaptureFailure: Error, Sendable, Equatable {
  case unreadableTree
  case invalidTree
  case invalidRawDump
  case invalidPNG
  case invalidAdvancedDump
  case advancedDumpRequiresSidecar

  public var message: String {
    switch self {
    case .unreadableTree: "The UI tree Artifact is not readable JSON"
    case .invalidTree: "The UI tree Artifact does not contain a valid node tree"
    case .invalidRawDump: "The UI dump Artifact is not readable JSON"
    case .invalidPNG: "The screenshot Artifact is not a valid PNG"
    case .invalidAdvancedDump: "ArkUI returned no readable key : value fields for this component"
    case .advancedDumpRequiresSidecar:
      "ArkUI moved this Advanced Dump to a remote sidecar; retrieval is not safely available for this device build"
    }
  }
}

/// Strictly parses the published `dumpLayout` tree while retaining every
/// original node JSON document for the Raw dump inspector.
public enum ViewerCaptureParser {
  private struct ProvisionalNode {
    let path: [Int]
    let parentPath: [Int]?
    let childPaths: [[Int]]
    let sourceID: String?
    let type: String
    let text: String?
    let inspectorID: String?
    let bounds: ViewerBounds?
    let visible: Bool
    let enabled: Bool?
    let clickable: Bool?
    let focusable: Bool?
    let focused: Bool?
    let clipsChildren: Bool
    let hitTestBehavior: String?
    let zIndex: Double?
    let rawFields: Data
  }

  public static func parse(
    screenshotData: Data,
    treeData: Data,
    rawDumpData: Data?,
    identity: ViewerCaptureIdentity
  ) throws -> ViewerCapture {
    let screenshot = try pngDimensions(screenshotData)
    // `ui-dump.json` is an optional compatibility artifact. Some device
    // providers label their text window inventory as JSON even though the
    // payload is opaque text. The structured ui-tree.json remains the Viewer
    // source of truth, so retain the raw bytes without making that optional
    // artifact capable of invalidating an otherwise verified capture.
    guard let root = try? JSONSerialization.jsonObject(with: treeData) as? [String: Any] else {
      throw ViewerCaptureFailure.unreadableTree
    }
    let document = componentRoots(of: root)
    var provisional: [ProvisionalNode] = []
    for (index, component) in document.roots.enumerated() {
      try appendNode(component, path: [index], parentPath: nil, into: &provisional)
    }

    let identifiers = Dictionary(grouping: provisional.compactMap(\.sourceID), by: { $0 })
      .mapValues(\.count)
    var identityByPath: [[Int]: String] = [:]
    for item in provisional {
      let pathText = item.path.map(String.init).joined(separator: ".")
      if let sourceID = item.sourceID, identifiers[sourceID] == 1 {
        identityByPath[item.path] = "device:\(sourceID)"
      } else {
        identityByPath[item.path] = "path:\(pathText)"
      }
    }
    let nodes = provisional.compactMap { item -> ViewerNode? in
      guard let nodeIdentity = identityByPath[item.path] else { return nil }
      return ViewerNode(
        identity: nodeIdentity,
        deviceID: item.sourceID,
        parentIdentity: item.parentPath.flatMap { identityByPath[$0] },
        children: item.childPaths.compactMap { identityByPath[$0] },
        type: item.type,
        text: item.text,
        inspectorID: item.inspectorID,
        bounds: item.bounds,
        visible: item.visible,
        enabled: item.enabled,
        clickable: item.clickable,
        focusable: item.focusable,
        focused: item.focused,
        clipsChildren: item.clipsChildren,
        hitTestBehavior: item.hitTestBehavior,
        zIndex: item.zIndex,
        depth: max(0, item.path.count - 1),
        rawFields: item.rawFields)
    }
    guard !nodes.isEmpty else { throw ViewerCaptureFailure.invalidTree }
    let roots = nodes.filter { $0.parentIdentity == nil }.map(\.identity)
    guard !roots.isEmpty else { throw ViewerCaptureFailure.invalidTree }
    let coordinatesAreVerified = document.bounds.map { bounds in
      bounds.x == 0 && bounds.y == 0
        && Int(bounds.width) == screenshot.width && Int(bounds.height) == screenshot.height
    } ?? nodes.contains { node in
      guard node.parentIdentity == nil, let bounds = node.bounds else { return false }
      return bounds.x == 0 && bounds.y == 0
        && Int(bounds.width) == screenshot.width && Int(bounds.height) == screenshot.height
    }
    return ViewerCapture(
      screenshotData: screenshotData,
      screenshotWidth: screenshot.width,
      screenshotHeight: screenshot.height,
      roots: roots,
      nodes: nodes,
      rawDumpDocument: rawDumpData,
      identity: identity,
      coordinatesAreVerified: coordinatesAreVerified)
  }

  /// Steps past the dump's document envelope so the tree begins at its real
  /// root components.
  ///
  /// A device dump wraps its component tree in an object whose attributes are
  /// all empty. The envelope is the display document, not a component: it has
  /// no type or identifier and nothing to inspect. It may hold several window
  /// roots (for example the focused app plus SceneBoard's status bar), so child
  /// count is not evidence that the envelope is a component. Presenting that
  /// case made a real capture start at `Unknown` and hid every useful row one
  /// level below it.
  ///
  /// A wrapper that names itself is still a component and is kept. The full
  /// display bounds from the discarded document remain the coordinate-space
  /// proof; window roots need not each cover the status/navigation bars.
  private static func componentRoots(
    of document: [String: Any]
  ) -> (roots: [[String: Any]], bounds: ViewerBounds?) {
    var current = document
    var documentBounds: ViewerBounds?
    // Bounded: a malformed dump must not turn this into an unbounded descent.
    for _ in 0..<8 {
      let attributes = current["attributes"] as? [String: Any] ?? current
      guard string(attributes["type"]) == nil,
        string(attributes["accessibilityId"]) == nil,
        string(attributes["id"]) == nil,
        string(attributes["nodeId"]) == nil,
        string(attributes["componentId"]) == nil,
        let children = current["children"] as? [[String: Any]],
        !children.isEmpty
      else { return ([current], documentBounds) }
      documentBounds = documentBounds ?? bounds(attributes["bounds"] ?? current["bounds"])
      if children.count > 1 { return (children, documentBounds) }
      current = children[0]
    }
    return ([current], documentBounds)
  }

  private static func appendNode(
    _ object: [String: Any],
    path: [Int],
    parentPath: [Int]?,
    into items: inout [ProvisionalNode]
  ) throws {
    let attributes = object["attributes"] as? [String: Any] ?? object
    // Retain every field owned by this component, including provider-specific
    // fields Viewer does not model, but never duplicate its descendant tree in
    // Raw dump. Besides being the wrong inspection scope, serializing every
    // subtree once per node makes a large capture grow quadratically in memory.
    var componentFields = object
    componentFields.removeValue(forKey: "children")
    guard
      let rawFields = try? JSONSerialization.data(
        withJSONObject: componentFields, options: [.sortedKeys])
    else { throw ViewerCaptureFailure.invalidTree }
    let childObjects: [[String: Any]]
    if let children = object["children"] {
      guard let values = children as? [[String: Any]] else { throw ViewerCaptureFailure.invalidTree }
      childObjects = values
    } else {
      childObjects = []
    }
    let childPaths = childObjects.indices.map { path + [$0] }
    // `accessibilityId` first. On a real ArkUI dump `id` is the developer's
    // own `.id()` attribute and is empty on almost every node, while
    // `accessibilityId` is the framework's per-node identifier and is the
    // number a person cross-references against the platform's own inspector
    // output. Reading `id` first meant every node fell back to a synthesized
    // path identity and the whole tree showed "#—".
    let sourceID = string(attributes["accessibilityId"])
      ?? string(attributes["id"])
      ?? string(attributes["nodeId"])
      ?? string(attributes["componentId"])
    let type = string(attributes["type"])
      ?? string(attributes["componentType"])
      ?? string(attributes["class"])
      ?? "Unknown"
    items.append(
      ProvisionalNode(
        path: path,
        parentPath: parentPath,
        childPaths: childPaths,
        sourceID: sourceID,
        type: type,
        text: string(attributes["text"]),
        inspectorID: string(attributes["inspectorId"]),
        bounds: bounds(attributes["bounds"] ?? object["bounds"]),
        visible: bool(attributes["visible"]) ?? true,
        enabled: bool(attributes["enabled"]),
        clickable: bool(attributes["clickable"]),
        focusable: bool(attributes["focusable"]),
        focused: bool(attributes["focused"]),
        clipsChildren: bool(attributes["clip"]) ?? false,
        hitTestBehavior: string(attributes["hitTestBehavior"]),
        zIndex: number(attributes["zIndex"] ?? attributes["zOrder"]),
        rawFields: rawFields))
    for (index, child) in childObjects.enumerated() {
      try appendNode(child, path: path + [index], parentPath: path, into: &items)
    }
  }

  private static func pngDimensions(_ data: Data) throws -> (width: Int, height: Int) {
    let bytes = [UInt8](data)
    guard bytes.count >= 24,
      Array(bytes.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
      Array(bytes[12...15]) == [73, 72, 68, 82]
    else { throw ViewerCaptureFailure.invalidPNG }
    let width = bytes[16...19].reduce(0) { ($0 << 8) | Int($1) }
    let height = bytes[20...23].reduce(0) { ($0 << 8) | Int($1) }
    guard width > 0, height > 0 else { throw ViewerCaptureFailure.invalidPNG }
    return (width, height)
  }

  private static func string(_ value: Any?) -> String? {
    if let value = value as? String, !value.isEmpty { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
  }

  private static func bool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? String { return Bool(value) }
    return nil
  }

  private static func number(_ value: Any?) -> Double? {
    if let value = value as? NSNumber { return value.doubleValue.isFinite ? value.doubleValue : nil }
    if let value = value as? String, let number = Double(value), number.isFinite { return number }
    return nil
  }

  private static func bounds(_ value: Any?) -> ViewerBounds? {
    if let object = value as? [String: Any] {
      let x = number(object["x"] ?? object["left"])
      let y = number(object["y"] ?? object["top"])
      if let x, let y, let width = number(object["width"]), let height = number(object["height"]) {
        return ViewerBounds(x: x, y: y, width: width, height: height)
      }
      if let x, let y, let right = number(object["right"]), let bottom = number(object["bottom"]) {
        return ViewerBounds(x: x, y: y, width: right - x, height: bottom - y)
      }
    }
    if let values = value as? [Any], values.count == 4,
      let x = number(values[0]), let y = number(values[1]),
      let width = number(values[2]), let height = number(values[3])
    {
      return ViewerBounds(x: x, y: y, width: width, height: height)
    }
    if let value = value as? String {
      let pattern = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#
      let expression = try! NSRegularExpression(pattern: pattern)
      let range = NSRange(value.startIndex..., in: value)
      let values = expression.matches(in: value, range: range).compactMap { match in
        Double((value as NSString).substring(with: match.range))
      }
      if values.count == 4 {
        return ViewerBounds(
          x: values[0], y: values[1],
          width: values[2] - values[0], height: values[3] - values[1])
      }
    }
    return nil
  }
}

public enum ViewerHitTesting {
  /// Chooses the frontmost painted branch, then its deepest node. Depth alone
  /// is insufficient: a floating TabBar is normally shallower than the list
  /// and image nodes it overlays. At the first divergent siblings, zIndex and
  /// provider child order establish which whole branch is in front.
  public static func node(
    in capture: ViewerCapture,
    rootIdentity: String? = nil,
    x: Double,
    y: Double
  ) -> ViewerNode? {
    guard capture.coordinatesAreVerified else { return nil }
    let candidates = capture.subtreeNodes(rootIdentity: rootIdentity)
    var stableOrder: [String: Int] = [:]
    for (offset, candidate) in candidates.enumerated()
      where stableOrder[candidate.identity] == nil
    {
      stableOrder[candidate.identity] = offset
    }
    return candidates
      .filter { node in
        node.visible && node.acceptsPointerHit
          && (ViewerScreenshotMapping.visibleBounds(of: node, in: capture)?
            .contains(x: x, y: y) ?? false)
      }
      .max {
        isPaintedBehind(
          $0, $1, in: capture, stableOrder: stableOrder)
      }
  }

  private static func isPaintedBehind(
    _ left: ViewerNode,
    _ right: ViewerNode,
    in capture: ViewerCapture,
    stableOrder: [String: Int]
  ) -> Bool {
    let leftPath = capture.ancestors(of: left.identity) + [left.identity]
    let rightPath = capture.ancestors(of: right.identity) + [right.identity]
    let sharedCount = min(leftPath.count, rightPath.count)
    var divergence = 0
    while divergence < sharedCount,
      leftPath[divergence] == rightPath[divergence]
    {
      divergence += 1
    }

    if divergence < sharedCount,
      let leftBranch = capture.node(identity: leftPath[divergence]),
      let rightBranch = capture.node(identity: rightPath[divergence])
    {
      let leftZ = finiteZ(leftBranch.zIndex)
      let rightZ = finiteZ(rightBranch.zIndex)
      if leftZ != rightZ { return leftZ < rightZ }

      if divergence > 0,
        let parent = capture.node(identity: leftPath[divergence - 1]),
        let leftIndex = parent.children.firstIndex(of: leftBranch.identity),
        let rightIndex = parent.children.firstIndex(of: rightBranch.identity),
        leftIndex != rightIndex
      {
        return leftIndex < rightIndex
      }

      return (stableOrder[leftBranch.identity] ?? 0)
        < (stableOrder[rightBranch.identity] ?? 0)
    }

    // One candidate is an ancestor of the other within the same painted
    // branch. The descendant is the more specific component at that point.
    if leftPath.count != rightPath.count { return leftPath.count < rightPath.count }
    return (stableOrder[left.identity] ?? 0) < (stableOrder[right.identity] ?? 0)
  }

  private static func finiteZ(_ value: Double?) -> Double {
    guard let value, value.isFinite else { return 0 }
    return value
  }
}

public enum ViewerCaptureSubmissionResult: Sendable, Equatable {
  case captured(ViewerCapture)
  case failed(String)
}

public protocol UIDumpApplicationProviding: Sendable {
  /// The device observation is supplied rather than fetched. HDC routing is
  /// one fact about the machine, not a fact about Viewer, and every surface
  /// that re-asked for it paid a probe and still went stale the moment the
  /// user looked away. The App keeps one live observation and hands it here.
  func refreshWorkspace(
    deviceObservation: DeviceListPresentation
  ) async -> UIDumpWorkspacePresentation
  func recapture(target: UIDumpTargetPresentation) async -> ViewerCaptureSubmissionResult
  /// Reads the immutable Viewer Artifact set produced by an existing terminal
  /// Job. This is a bounded read only: it never submits or runs an operation.
  func loadHistoricalCapture(
    jobID: String,
    targetID: String,
    bindingRevision: Int
  ) async -> ViewerCaptureSubmissionResult
  func advancedDump(
    target: UIDumpTargetPresentation,
    selection: ViewerAdvancedDumpSelection
  ) async -> ViewerAdvancedDumpSubmissionResult
  func cancel(jobID: String) async -> Bool
}

public extension UIDumpApplicationProviding {
  func loadHistoricalCapture(
    jobID _: String,
    targetID _: String,
    bindingRevision _: Int
  ) async -> ViewerCaptureSubmissionResult {
    .failed("This Viewer provider cannot read historical captures")
  }
}

public enum ViewerCaptureRequestBuilder {
  /// Viewer needs a current screenshot and component tree, not a prolonged
  /// diagnostic-log window. The published operation permits one second, so
  /// keep the Viewer capture bounded to its shortest truthful interval.
  public static let durationSeconds = DiagnosticCapturePreset.shortCaptureDurationSeconds

  public static func request(target: UIDumpTargetPresentation, nonce: String) throws -> RuntimeOperationRequest {
    try RuntimeOperationRequest(
      requestID: "viewer-capture-ui-\(nonce)",
      idempotencyKey: "viewer-capture-ui-\(nonce)",
      target: DurableTargetReference(
        targetID: target.id, expectedBindingRevision: target.bindingRevision),
      operation: RuntimeOperationReference(id: "capture.diagnostics", version: 1),
      // A Viewer recapture needs a verified PNG and component tree. It does
      // not consume HiLog, whose buffer drain can dominate the interaction
      // on a connected device.
      inputs: DiagnosticCapturePreset.uiDump(),
      requestedOutputs: [.rawArtifacts, .derivedArtifacts, .hardwareEvidence],
      clientContext: RuntimeWorkspaceThread.clientContext(
        clientName: ArkDeckAgentClientName.debugLogsWorkspace, targetID: target.id))
  }

  public static func advancedDumpRequest(
    target: UIDumpTargetPresentation,
    selection: ViewerAdvancedDumpSelection,
    nonce: String
  ) throws -> RuntimeOperationRequest {
    try RuntimeOperationRequest(
      requestID: "viewer-advanced-dump-\(nonce)",
      idempotencyKey: "viewer-advanced-dump-\(nonce)",
      target: DurableTargetReference(
        targetID: target.id, expectedBindingRevision: target.bindingRevision),
      operation: RuntimeOperationReference(id: "capture.diagnostics", version: 1),
      inputs: try DiagnosticCapturePreset.componentDetail(
        windowID: selection.windowID,
        componentID: selection.componentID),
      requestedOutputs: [.rawArtifacts, .derivedArtifacts, .hardwareEvidence],
      clientContext: RuntimeWorkspaceThread.clientContext(
        clientName: ArkDeckAgentClientName.debugLogsWorkspace, targetID: target.id))
  }
}

public enum UIDumpApplicationFacade {
  /// Re-joins already-decoded targets against a newer device observation, so a
  /// workspace can answer an unplug from the App's shared observation without
  /// re-reading the durable target store.
  public static func rejoin(
    targets: [UIDumpTargetPresentation], with observation: DeviceListPresentation
  ) -> [UIDumpTargetPresentation] {
    UIDumpWorkspaceResponseDecoding.rejoin(targets: targets, with: observation)
  }

  public static let operationReference = "capture.diagnostics@1"
  private static let descriptor = RuntimeOperationCatalog.descriptor(reference: operationReference)!

  public static func make() -> any UIDumpApplicationProviding {
    UIDumpProductionApplicationProvider()
  }

  static func operationPresentation(availability: UIDumpRuntimeAvailability) -> UIDumpOperationPresentation {
    UIDumpOperationPresentation(
      reference: descriptor.reference,
      title: descriptor.title,
      availability: availability,
      minimumEffect: descriptor.minimumEffect.rawValue,
      permittedEffects: descriptor.permittedEffects.map(\.rawValue))
  }
}

private actor UIDumpProductionApplicationProvider: UIDumpApplicationProviding {
  /// Measured on a 446KB screenshot: 64KB chunks cost 21.7ms, 256KB cost
  /// 7.5ms, 1MB costs 4.8ms, and 4MB costs no less than 1MB. The cost is per
  /// request (~3ms each), not per byte, so this is the point where fewer
  /// round trips stops buying anything.
  private static let artifactChunkBytes: Int64 = 1_024 * 1_024
  private static let maximumSingleArtifactBytes = 32 * 1_024 * 1_024

  func refreshWorkspace(
    deviceObservation: DeviceListPresentation
  ) async -> UIDumpWorkspacePresentation {
    async let operations = UIDumpXPCTransport.request(method: "operation.list")
    // `target.list` stays: it is a durable store read, not a device probe, and
    // it carries the adoption facts a candidate does not. What Viewer no
    // longer does is re-run the HDC probe — admission still requires a fresh
    // Connected route, but freshness is now a property the shared observation
    // stamps and this workspace checks, instead of an accident of having just
    // navigated here.
    async let targets = UIDumpXPCTransport.request(method: "target.list")
    async let jobs = UIDumpXPCTransport.request(
      method: "job.list", params: RuntimeAppJobListPolicy.recentSummaryParams)
    return UIDumpWorkspaceResponseDecoding.presentation(
      operationResponse: await operations,
      targetResponse: await targets,
      deviceObservation: deviceObservation,
      jobResponse: await jobs)
  }

  func recapture(target: UIDumpTargetPresentation) async -> ViewerCaptureSubmissionResult {
    do {
      let nonce = UUID().uuidString.lowercased()
      let request = try ViewerCaptureRequestBuilder.request(target: target, nonce: nonce)
      let requestData = try CanonicalJSONEncoders.canonical().encode(request)
      guard let requestJSON = String(data: requestData, encoding: .utf8) else {
        return .failed("Could not encode the typed Viewer request")
      }
      let (submitted, submitMilliseconds) = try await ViewerSignpost.measure("viewer.submit") {
        try resultObject(
          await UIDumpXPCTransport.request(
            method: "job.submit", params: ["requestJson": .string(requestJSON)]),
          label: "Viewer capture submission")
      }
      guard let jobID = submitted["jobId"] as? String, !jobID.isEmpty else {
        return .failed("Runtime accepted Viewer capture without returning a Job ID")
      }
      let (terminal, runMilliseconds) = try await ViewerSignpost.measure("viewer.run") {
        try resultObject(
          await UIDumpXPCTransport.request(method: "job.run", params: ["jobId": .string(jobID)]),
          label: "Viewer capture")
      }
      let facts = try terminalFacts(terminal, jobID: jobID, target: target)
      guard facts.state == "succeeded", !facts.outcomeUnknown,
        !facts.waitingForHuman, facts.outstandingResidueCount == 0
      else {
        return .failed("Viewer capture did not produce a safe terminal result (\(facts.state))")
      }
      return .captured(
        try await loadCapture(
          facts: facts, targetID: target.id, bindingRevision: target.bindingRevision,
          submitMilliseconds: submitMilliseconds, runMilliseconds: runMilliseconds))
    } catch let failure as ViewerTransportFailure {
      return .failed(failure.message)
    } catch let failure as ViewerArtifactFailure {
      return .failed(failure.message)
    } catch let failure as ViewerCaptureFailure {
      return .failed(failure.message)
    } catch {
      return .failed("Viewer capture failed: \(error)")
    }
  }

  func loadHistoricalCapture(
    jobID: String,
    targetID: String,
    bindingRevision: Int
  ) async -> ViewerCaptureSubmissionResult {
    guard !jobID.isEmpty, !targetID.isEmpty, bindingRevision >= 0 else {
      return .failed("Historical Viewer context is incomplete")
    }
    do {
      let target = UIDumpTargetPresentation(
        id: targetID,
        bindingRevision: bindingRevision,
        toolVersion: "history",
        adoptedAtUTC: "")
      let status = try resultObject(
        await UIDumpXPCTransport.request(
          method: "job.status", params: ["jobId": .string(jobID)]),
        label: "Historical Viewer Job")
      let facts = try terminalFacts(status, jobID: jobID, target: target)
      guard facts.state == "succeeded", !facts.outcomeUnknown,
        !facts.waitingForHuman, facts.outstandingResidueCount == 0
      else {
        return .failed(
          "Historical Viewer Job did not finish with a confirmed capture (\(facts.state))")
      }
      return .captured(
        try await loadCapture(
          facts: facts, targetID: targetID, bindingRevision: bindingRevision))
    } catch let failure as ViewerTransportFailure {
      return .failed(failure.message)
    } catch let failure as ViewerArtifactFailure {
      return .failed(failure.message)
    } catch let failure as ViewerCaptureFailure {
      return .failed(failure.message)
    } catch {
      return .failed("Historical Viewer capture failed: \(error)")
    }
  }

  func advancedDump(
    target: UIDumpTargetPresentation,
    selection: ViewerAdvancedDumpSelection
  ) async -> ViewerAdvancedDumpSubmissionResult {
    do {
      let nonce = UUID().uuidString.lowercased()
      let request = try ViewerCaptureRequestBuilder.advancedDumpRequest(
        target: target, selection: selection, nonce: nonce)
      let requestData = try CanonicalJSONEncoders.canonical().encode(request)
      guard let requestJSON = String(data: requestData, encoding: .utf8) else {
        return .failed("Could not encode the typed Advanced Dump request")
      }
      let submitted = try resultObject(
        await UIDumpXPCTransport.request(
          method: "job.submit", params: ["requestJson": .string(requestJSON)]),
        label: "Advanced Dump submission")
      guard let jobID = submitted["jobId"] as? String, !jobID.isEmpty else {
        return .failed("Runtime accepted Advanced Dump without returning a Job ID")
      }
      let terminal = try resultObject(
        await UIDumpXPCTransport.request(method: "job.run", params: ["jobId": .string(jobID)]),
        label: "Advanced Dump")
      let facts = try terminalFacts(terminal, jobID: jobID, target: target)
      guard facts.state == "succeeded", !facts.outcomeUnknown,
        !facts.waitingForHuman, facts.outstandingResidueCount == 0
      else {
        return .failed("Advanced Dump did not produce a safe terminal result (\(facts.state))")
      }
      let entries = try artifactList(
        await UIDumpXPCTransport.request(
          method: "artifact.list", params: ["jobId": .string(jobID)]),
        jobID: jobID)
      let artifact = try requiredArtifact(
        named: "advanced-dump.txt", mediaType: "text/plain", entries: entries)
      return .captured(try ViewerAdvancedDumpParser.parse(await readArtifact(artifact, jobID: jobID)))
    } catch let failure as ViewerTransportFailure {
      return .failed(failure.message)
    } catch let failure as ViewerArtifactFailure {
      return .failed(failure.message)
    } catch let failure as ViewerCaptureFailure {
      return .failed(failure.message)
    } catch {
      return .failed("Advanced Dump failed: \(error)")
    }
  }

  func cancel(jobID: String) async -> Bool {
    guard let result = try? await resultObject(
      UIDumpXPCTransport.request(method: "job.cancel", params: ["jobId": .string(jobID)]),
      label: "Viewer cancellation")
    else { return false }
    return result["cancelRequested"] as? Bool == true
  }

  private func loadCapture(
    facts: ViewerTerminalFacts,
    targetID: String,
    bindingRevision: Int,
    submitMilliseconds: Double = 0,
    runMilliseconds: Double = 0
  ) async throws -> ViewerCapture {
    let (selection, listMilliseconds) = try await ViewerSignpost.measure("viewer.artifactList") {
      let entries = try artifactList(
        await UIDumpXPCTransport.request(
          method: "artifact.list", params: ["jobId": .string(facts.jobID)]),
        jobID: facts.jobID)
      let screenshot = try requiredArtifact(
        named: "screenshot.png", mediaType: "image/png", entries: entries)
      let tree = try requiredArtifact(
        named: "ui-tree.json", mediaType: "application/json", entries: entries)
      let rawDump = try optionalArtifact(
        named: "ui-dump.json", mediaType: "application/json", entries: entries)
      let total = ([screenshot, tree] + (rawDump.map { [$0] } ?? []))
        .reduce(Int64(0)) { $0 + $1.byteCount }
      guard total <= Int64(UIDumpOfflineInspector.maximumCaptureBytes) else {
        throw ViewerArtifactFailure(
          message: "Viewer Artifact set exceeds its in-memory safety limit")
      }
      return (screenshot: screenshot, tree: tree, rawDump: rawDump)
    }
    let screenshot = selection.screenshot
    let tree = selection.tree
    let rawDump = selection.rawDump
    let (payload, readMilliseconds) = try await ViewerSignpost.measure("viewer.artifactRead") {
      let screenshotData = try await readArtifact(screenshot, jobID: facts.jobID)
      let treeData = try await readArtifact(tree, jobID: facts.jobID)
      let rawDumpData: Data?
      if let rawDump {
        rawDumpData = try await readArtifact(rawDump, jobID: facts.jobID)
      } else {
        rawDumpData = nil
      }
      return (screenshotData: screenshotData, treeData: treeData, rawDumpData: rawDumpData)
    }
    let screenshotData = payload.screenshotData
    let treeData = payload.treeData
    let rawDumpData = payload.rawDumpData
    guard let capturedAtUTC = facts.finishedAtUTC, !capturedAtUTC.isEmpty else {
      throw ViewerArtifactFailure(message: "Runtime did not report a terminal Viewer capture time")
    }
    let (capture, parseMilliseconds) = try ViewerSignpost.measureSync("viewer.parse") {
      func artifact(_ metadata: ViewerArtifactMetadata, _ data: Data) throws
        -> UIDumpOfflineArtifact
      {
        try UIDumpOfflineArtifact(
          source: UIDumpOfflineSource(
            artifactID: metadata.id,
            name: metadata.name,
            mediaType: metadata.mediaType,
            sha256: metadata.sha256,
            byteCount: Int(metadata.byteCount)),
          data: data)
      }
      do {
        let inspection = try UIDumpOfflineInspector().inspect(
          UIDumpOfflineCaptureInput(
            identity: ViewerCaptureIdentity(
              jobID: facts.jobID,
              targetID: targetID,
              bindingRevision: bindingRevision,
              capturedAtUTC: capturedAtUTC),
            screenshot: try artifact(screenshot, screenshotData),
            tree: try artifact(tree, treeData),
            rawDump: try rawDump.map { metadata in
              try artifact(metadata, rawDumpData ?? Data())
            },
            observedFromUTC: nil,
            observedToUTC: capturedAtUTC))
        return inspection.capture
      } catch {
        throw ViewerArtifactFailure(
          message: "Viewer offline inspection rejected the published Artifact set: \(error)")
      }
    }
    return capture.withMetrics(
      ViewerCaptureMetrics(
        submitMilliseconds: submitMilliseconds,
        runMilliseconds: runMilliseconds,
        listMilliseconds: listMilliseconds,
        readMilliseconds: readMilliseconds,
        readBytes: screenshotData.count + treeData.count + (rawDumpData?.count ?? 0),
        parseMilliseconds: parseMilliseconds,
        nodeCount: capture.nodes.count))
  }

  private func readArtifact(_ artifact: ViewerArtifactMetadata, jobID: String) async throws -> Data {
    var bytes = Data()
    var digest = SHA256()
    var offset: Int64 = 0
    while offset < artifact.byteCount {
      let response = await UIDumpXPCTransport.request(
        method: "artifact.read",
        params: [
          "jobId": .string(jobID), "artifactId": .string(artifact.id),
          "offset": .integer(offset), "maxBytes": .integer(Self.artifactChunkBytes),
          "allowSensitive": .bool(true),
        ])
      let chunk = try artifactChunk(response, artifact: artifact, expectedOffset: offset)
      guard !chunk.data.isEmpty else {
        throw ViewerArtifactFailure(message: "Runtime returned an empty non-terminal Viewer Artifact chunk")
      }
      bytes.append(chunk.data)
      digest.update(data: chunk.data)
      offset = chunk.nextOffset
      guard chunk.eof == (offset == artifact.byteCount) else {
        throw ViewerArtifactFailure(message: "Runtime Artifact end-of-file facts drifted during Viewer read")
      }
    }
    guard sha256(digest.finalize()) == artifact.sha256 else {
      throw ViewerArtifactFailure(message: "Viewer Artifact SHA-256 does not match Runtime metadata")
    }
    return bytes
  }

  private func requiredArtifact(
    named name: String, mediaType: String, entries: [ViewerArtifactMetadata]
  ) throws -> ViewerArtifactMetadata {
    let matches = entries.filter { $0.name == name }
    guard matches.count == 1 else {
      throw ViewerArtifactFailure(message: "Viewer capture is missing exactly one \(name) Artifact")
    }
    return try validated(matches[0], expectedMediaType: mediaType)
  }

  private func optionalArtifact(
    named name: String, mediaType: String, entries: [ViewerArtifactMetadata]
  ) throws -> ViewerArtifactMetadata? {
    let matches = entries.filter { $0.name == name }
    guard matches.count <= 1 else {
      throw ViewerArtifactFailure(message: "Viewer capture returned duplicate \(name) Artifacts")
    }
    return try matches.first.map { try validated($0, expectedMediaType: mediaType) }
  }

  private func validated(
    _ artifact: ViewerArtifactMetadata, expectedMediaType: String
  ) throws -> ViewerArtifactMetadata {
    guard artifact.status == "published", artifact.privacy == "sensitive",
      artifact.mediaType == expectedMediaType,
      artifact.byteCount >= 0, artifact.byteCount <= Int64(Self.maximumSingleArtifactBytes),
      isSHA256(artifact.sha256)
    else {
      throw ViewerArtifactFailure(message: "Viewer Artifact metadata failed validation for \(artifact.name)")
    }
    return artifact
  }
}

private struct ViewerTerminalFacts {
  let jobID: String
  let state: String
  let waitingForHuman: Bool
  let outcomeUnknown: Bool
  let outstandingResidueCount: Int
  let finishedAtUTC: String?
}

private struct ViewerArtifactMetadata {
  let id: String
  let name: String
  let mediaType: String
  let byteCount: Int64
  let sha256: String
  let privacy: String
  let status: String
}

private struct ViewerArtifactFailure: Error { let message: String }

enum UIDumpWorkspaceResponseDecoding {
  fileprivate static func presentation(
    operationResponse: Result<Data, ViewerTransportFailure>,
    targetResponse: Result<Data, ViewerTransportFailure>,
    deviceObservation: DeviceListPresentation,
    jobResponse: Result<Data, ViewerTransportFailure>
  ) -> UIDumpWorkspacePresentation {
    let targets = decodeTargets(targetResponse, observation: deviceObservation)
    let jobs = decodeJobs(jobResponse)
    return UIDumpWorkspacePresentation(
      operation: UIDumpApplicationFacade.operationPresentation(
        availability: decodeAvailability(operationResponse)),
      targets: targets.value ?? [], relatedJobs: jobs.value ?? [],
      targetLoadFailure: targets.failure, jobLoadFailure: jobs.failure)
  }

  private static func decodeAvailability(
    _ response: Result<Data, ViewerTransportFailure>
  ) -> UIDumpRuntimeAvailability {
    guard case .success(let data) = response,
      let entries = try? resultArray(data, label: "Operation list"),
      let entry = entries.first(where: { $0["reference"] as? String == UIDumpApplicationFacade.operationReference }),
      let availability = entry["availability"] as? String,
      let reasons = entry["reasons"] as? [String]
    else {
      let reason: String
      if case .failure(let failure) = response { reason = failure.message }
      else { reason = "capture.diagnostics@1 is missing complete availability facts" }
      return .unavailable(reasons: [reason])
    }
    return availability == "available" ? .available : .unavailable(
      reasons: reasons.isEmpty ? ["Runtime did not report an availability reason"] : reasons)
  }

  private static func decodeTargets(
    _ response: Result<Data, ViewerTransportFailure>,
    observation: DeviceListPresentation
  ) -> ViewerDecodedList<UIDumpTargetPresentation> {
    do {
      let entries = try resultArray(response.get(), label: "Target list")
      let routes = targetConnections(observation)
      var targets: [UIDumpTargetPresentation] = []
      for entry in entries {
        guard let id = entry["targetId"] as? String,
          let revision = entry["bindingRevision"] as? Int,
          let toolVersion = entry["toolVersion"] as? String,
          let adoptedAtUTC = entry["adoptedAtUtc"] as? String
        else { return ViewerDecodedList(failure: "Runtime returned a target without complete binding facts") }
        targets.append(UIDumpTargetPresentation(
          id: id,
          bindingRevision: revision,
          toolVersion: toolVersion,
          adoptedAtUTC: adoptedAtUTC,
          connection: routes.connections[id] ?? .unavailable(
            reason: routes.failure ?? "No current HDC route was reported for this target")))
      }
      return ViewerDecodedList(value: targets)
    } catch let failure as ViewerTransportFailure {
      return ViewerDecodedList(failure: failure.message)
    } catch let failure as ViewerArtifactFailure {
      return ViewerDecodedList(failure: failure.message)
    } catch {
      return ViewerDecodedList(failure: "Runtime returned an unreadable target list")
    }
  }

  /// Re-joins already-decoded targets against a newer device observation.
  ///
  /// The adoption facts in a target are durable; only the route is live. This
  /// lets a workspace answer an unplug from the shared observation alone,
  /// without re-reading the target store to learn something the target store
  /// does not know.
  static func rejoin(
    targets: [UIDumpTargetPresentation], with observation: DeviceListPresentation
  ) -> [UIDumpTargetPresentation] {
    // Not yet observed is not observed-unavailable. Overriding during the
    // first poll would flap every picker to Unavailable and back, and would
    // report an absence of measurement as a measurement.
    guard case .available = observation.availability else { return targets }
    let routes = targetConnections(observation)
    return targets.map { target in
      UIDumpTargetPresentation(
        id: target.id,
        bindingRevision: target.bindingRevision,
        toolVersion: target.toolVersion,
        adoptedAtUTC: target.adoptedAtUTC,
        connection: routes.connections[target.id] ?? .unavailable(
          reason: routes.failure ?? "No current HDC route was reported for this target"))
    }
  }

  static func targetConnection(for candidate: DeviceCandidatePresentation) -> UIDumpTargetConnection {
    guard candidate.isAuthorized else {
      let reason: String
      if candidate.stateObservationHealth == .stale {
        reason = "HDC reported \(candidate.state), but that observation is stale"
      } else {
        reason = "HDC reported \(candidate.state)"
      }
      return .unavailable(reason: reason)
    }
    return .connected
  }

  private static func targetConnections(
    _ presentation: DeviceListPresentation
  ) -> ViewerTargetConnections {
      guard case .available = presentation.availability else {
        let reason: String
        if case .unavailable(let value) = presentation.availability { reason = value }
        else { reason = "Runtime is still checking device state" }
        return ViewerTargetConnections(
          connections: [:], failure: "Could not read current device state: \(reason)")
      }

      var connections: [String: UIDumpTargetConnection] = [:]
      for candidate in presentation.candidates {
        guard let targetID = candidate.adoptedTargetID else { continue }
        guard connections[targetID] == nil else {
          return ViewerTargetConnections(
            connections: [:],
            failure: "Runtime reported more than one current route for target \(targetID)")
        }
        connections[targetID] = targetConnection(for: candidate)
      }
      return ViewerTargetConnections(connections: connections, failure: nil)
  }

  private static func decodeJobs(
    _ response: Result<Data, ViewerTransportFailure>
  ) -> ViewerDecodedList<UIDumpJobPresentation> {
    do {
      let entries = try resultArray(response.get(), label: "Job list")
      var jobs: [UIDumpJobPresentation] = []
      for entry in entries {
        guard entry["operation"] as? String == UIDumpApplicationFacade.operationReference else { continue }
        guard let id = entry["jobId"] as? String,
          let targetID = entry["targetId"] as? String,
          let state = entry["state"] as? String,
          let waitingForHuman = entry["waitingForHuman"] as? Bool,
          let outcomeUnknown = entry["outcomeUnknown"] as? Bool,
          let residue = entry["outstandingResidueCount"] as? Int
        else { return ViewerDecodedList(failure: "Runtime returned an incomplete Viewer Job") }
        jobs.append(UIDumpJobPresentation(
          id: id, targetID: targetID, state: state, waitingForHuman: waitingForHuman,
          outcomeUnknown: outcomeUnknown, outstandingResidueCount: residue,
          finishedAtUTC: entry["finishedAtUtc"] as? String))
      }
      return ViewerDecodedList(value: jobs)
    } catch let failure as ViewerTransportFailure {
      return ViewerDecodedList(failure: failure.message)
    } catch let failure as ViewerArtifactFailure {
      return ViewerDecodedList(failure: failure.message)
    } catch {
      return ViewerDecodedList(failure: "Runtime returned an unreadable Job list")
    }
  }
}

private struct ViewerTargetConnections {
  let connections: [String: UIDumpTargetConnection]
  let failure: String?
}

private struct ViewerDecodedList<Value> {
  let value: [Value]?
  let failure: String?
  init(value: [Value]) { self.value = value; failure = nil }
  init(failure: String) { value = nil; self.failure = failure }
}

private enum ViewerTransportFailure: Error, Sendable, Equatable {
  case transport(String)
  var message: String {
    switch self {
    case .transport(let value): value
    }
  }
}

private enum UIDumpXPCTransport {
  static func request(
    method: String, params: [String: JSONValue]? = nil
  ) async -> Result<Data, ViewerTransportFailure> {
    await RuntimeXPCRequestTransport.request(method: method, params: params)
      .mapError { ViewerTransportFailure.transport($0.message) }
  }
}

private func resultObject(
  _ response: Result<Data, ViewerTransportFailure>, label: String
) throws -> [String: Any] {
  let data = try response.get()
  guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw ViewerArtifactFailure(message: "\(label) response was unreadable")
  }
  if let error = object["error"] as? [String: Any] {
    let code = error["code"] as? String ?? "unknown"
    let message = error["message"] as? String ?? "no message"
    throw ViewerArtifactFailure(message: "\(label) was refused: \(code) — \(message)")
  }
  guard object["ok"] as? Bool == true, let result = object["result"] as? [String: Any] else {
    throw ViewerArtifactFailure(message: "\(label) response was incomplete")
  }
  return result
}

private func resultArray(_ data: Data, label: String) throws -> [[String: Any]] {
  guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw ViewerArtifactFailure(message: "\(label) response was unreadable")
  }
  if let error = object["error"] as? [String: Any] {
    let code = error["code"] as? String ?? "unknown"
    let message = error["message"] as? String ?? "no message"
    throw ViewerArtifactFailure(message: "\(label) was refused: \(code) — \(message)")
  }
  guard object["ok"] as? Bool == true, let result = object["result"] as? [[String: Any]] else {
    throw ViewerArtifactFailure(message: "\(label) response was incomplete")
  }
  return result
}

private func terminalFacts(
  _ values: [String: Any], jobID: String, target: UIDumpTargetPresentation
) throws -> ViewerTerminalFacts {
  guard values["jobId"] as? String == jobID,
    values["targetId"] as? String == target.id,
    values["operation"] as? String == UIDumpApplicationFacade.operationReference,
    let state = values["state"] as? String,
    let waitingForHuman = values["waitingForHuman"] as? Bool,
    let outcomeUnknown = values["outcomeUnknown"] as? Bool,
    let residue = values["outstandingResidueCount"] as? Int
  else { throw ViewerArtifactFailure(message: "Runtime returned incomplete terminal Viewer Job facts") }
  return ViewerTerminalFacts(
    jobID: jobID, state: state, waitingForHuman: waitingForHuman,
    outcomeUnknown: outcomeUnknown, outstandingResidueCount: residue,
    finishedAtUTC: values["finishedAtUtc"] as? String)
}

private func artifactList(
  _ response: Result<Data, ViewerTransportFailure>, jobID: String
) throws -> [ViewerArtifactMetadata] {
  let entries = try resultArray(response.get(), label: "Viewer Artifact list")
  return try entries.map { value in
    guard value["jobId"] as? String == jobID,
      let id = value["artifactId"] as? String,
      let name = value["name"] as? String,
      let mediaType = value["mediaType"] as? String,
      let byteCount = int64(value["byteCount"]),
      let sha256 = value["sha256"] as? String,
      let privacy = value["privacy"] as? String,
      let status = value["status"] as? String
    else { throw ViewerArtifactFailure(message: "Runtime returned incomplete Viewer Artifact metadata") }
    return ViewerArtifactMetadata(
      id: id, name: name, mediaType: mediaType, byteCount: byteCount,
      sha256: sha256, privacy: privacy, status: status)
  }
}

private func artifactChunk(
  _ response: Result<Data, ViewerTransportFailure>,
  artifact: ViewerArtifactMetadata,
  expectedOffset: Int64
) throws -> (data: Data, nextOffset: Int64, eof: Bool) {
  let result = try resultObject(response, label: "Viewer Artifact read")
  guard result["artifactId"] as? String == artifact.id,
    int64(result["offset"]) == expectedOffset,
    let nextOffset = int64(result["nextOffset"]), nextOffset > expectedOffset,
    int64(result["totalByteCount"]) == artifact.byteCount,
    let byteCount = int64(result["byteCount"]), byteCount == nextOffset - expectedOffset,
    let base64 = result["base64"] as? String,
    let data = Data(base64Encoded: base64), Int64(data.count) == byteCount,
    let eof = result["eof"] as? Bool,
    nextOffset <= artifact.byteCount
  else { throw ViewerArtifactFailure(message: "Runtime returned drifting Viewer Artifact chunk facts") }
  return (data, nextOffset, eof)
}

private func int64(_ value: Any?) -> Int64? {
  if let value = value as? Int64 { return value }
  if let value = value as? Int { return Int64(value) }
  if let value = value as? NSNumber { return value.int64Value }
  return nil
}

private func isSHA256(_ value: String) -> Bool {
  value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
}

private func sha256(_ digest: SHA256.Digest) -> String {
  digest.map { String(format: "%02x", $0) }.joined()
}

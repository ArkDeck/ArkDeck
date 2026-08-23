import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Deterministic Viewer captures for UI automation and for measuring the
/// Viewer against tree sizes a demo device will not produce.
///
/// Like `AutoUpdateUIFixture` this supplies a *domain* object — a
/// `ViewerCapture` — and never a presentation, so a test still exercises the
/// App's real capture-to-UI mapping instead of a second copy of it that could
/// drift. Nothing here reaches XPC, the artifact store, or a device, and a
/// launch without one of these arguments never reaches any of it.
///
/// The screenshot is drawn from the same bounds the tree publishes. That is
/// deliberate: if hit testing and the drawn image ever disagree, the fixture
/// shows it immediately rather than hiding it behind a photograph whose
/// geometry nothing can check. It is schematic on purpose — a fixture must
/// never be mistakable for a real capture.
public enum ViewerUIFixture {
  private static let prefix = "--ui-test-viewer"

  /// Whether this launch drives Viewer from a fixture at all.
  public static func isSelected(arguments: [String] = CommandLine.arguments) -> Bool {
    arguments.contains { $0.hasPrefix(prefix) }
  }

  /// The provider to install, or `nil` for every ordinary launch. Production
  /// `UIDumpApplicationFacade.make()` is never reached through this type, and
  /// this type is never reached without an explicit launch argument.
  public static func provider(
    arguments: [String] = CommandLine.arguments
  ) -> (any UIDumpApplicationProviding)? {
    guard isSelected(arguments: arguments) else { return nil }
    return Provider(capture: capture(nodes: requestedNodeCount(in: arguments)))
  }

  /// `--ui-test-viewer` renders the reviewed design tree. The
  /// `--ui-test-viewer-stress-<n>` forms render a synthetic tree of `n` nodes
  /// so tree, search, and hit testing can be measured at sizes a settings
  /// screen never reaches.
  static func requestedNodeCount(in arguments: [String]) -> Int? {
    guard
      let flag = arguments.first(where: { $0.hasPrefix("\(prefix)-stress-") }),
      let count = Int(flag.dropFirst("\(prefix)-stress-".count)),
      count > 0
    else { return nil }
    return min(count, 200_000)
  }

  // MARK: - Captures

  /// `nodes == nil` builds the reviewed design tree; otherwise a synthetic
  /// tree of that many nodes.
  public static func capture(nodes: Int? = nil) -> ViewerCapture {
    let tree = nodes.map(syntheticTree(count:)) ?? designTree()
    return ViewerCapture(
      screenshotData: png(for: tree, width: screenWidth, height: screenHeight),
      screenshotWidth: screenWidth,
      screenshotHeight: screenHeight,
      roots: tree.filter { $0.parentIdentity == nil }.map(\.identity),
      nodes: tree,
      rawDumpDocument: nil,
      identity: ViewerCaptureIdentity(
        jobID: "job-ui-fixture",
        targetID: "target-ui-fixture",
        bindingRevision: 1,
        capturedAtUTC: "2026-08-22T00:00:00Z"),
      coordinatesAreVerified: true)
  }

  /// The device the fixture claims to have captured.
  ///
  /// A fixture that offers a Connected target must also present the device
  /// that makes it Connected, or the App's shared observation would correctly
  /// contradict it and the fixture would be describing a device nobody has.
  public static func deviceObservation(
    arguments: [String] = CommandLine.arguments
  ) -> DeviceListPresentation? {
    guard isSelected(arguments: arguments) else { return nil }
    return DeviceListPresentation(
      availability: .available,
      candidates: [
        DeviceCandidatePresentation(
          connectKey: "ui-fixture-connect-key",
          state: "Connected",
          adoptedTargetID: "target-ui-fixture",
          bindingRevision: 1,
          stateObservedAtUTC: "2026-08-22T00:00:00Z",
          stateObservationHealth: .current)
      ])
  }

  public static let screenWidth = 1080
  public static let screenHeight = 1920

  /// The same ids, types, and bounds the reviewed prototype publishes, so the
  /// App and the design can be compared node for node rather than by eye.
  static func designTree() -> [ViewerNode] {
    var rows: [Row] = [
      Row(1, nil, 1, "Root", nil, 0, 0, 1080, 1920),
      Row(3, 1, 2, "Stage", nil, 0, 0, 1080, 1920),
      Row(8, 3, 3, "Column", nil, 0, 0, 1080, 1920),
      Row(12, 8, 4, "Navigation", "设置", 0, 0, 1080, 232),
      Row(15, 8, 4, "Search", "搜索设置项", 48, 252, 984, 100, interactive: true),
      Row(18, 8, 4, "ProfileCard", "小艺", 40, 382, 1000, 160, interactive: true),
      Row(23, 18, 5, "Column", "AccountSummaryContent", 64, 398, 952, 128),
      Row(24, 23, 6, "Row", "ProfileIdentityContainer", 76, 410, 928, 104),
      Row(25, 24, 7, "CustomComponent", "HarmonyAccountAvatarAndCloudStatus", 92, 420, 80, 80),
      Row(26, 24, 7, "BuilderNode", "AccountDetailActionSlot", 196, 416, 72, 42),
      Row(27, 24, 7, "ConditionalContent", "CloudStorageSubscriptionSummary", 196, 466, 340, 38),
      Row(21, 8, 4, "List", nil, 40, 578, 1000, 1216),
      Row(22, 21, 5, "ListItem", "WLAN", 40, 578, 1000, 136, interactive: true),
      Row(31, 22, 6, "Row", "WLAN", 62, 590, 956, 112, interactive: true),
      Row(32, 31, 7, "Image", "wifi", 86, 614, 64, 64),
      Row(38, 31, 7, "Text", "WLAN", 186, 622, 102, 48),
      Row(40, 31, 7, "Row", "已连接", 640, 600, 356, 92, interactive: true),
      Row(41, 40, 8, "Text", "已连接", 724, 622, 82, 48),
      Row(42, 40, 8, "Toggle", "WLAN", 886, 614, 110, 64, interactive: true, inspectorID: "wifi_switch"),
    ]
    let items: [(Int, Int, Int, String, String)] = [
      (50, 52, 53, "蓝牙", "bluetooth"),
      (58, 59, 60, "移动网络", "cellular"),
      (66, 67, 68, "超级终端", "superDevice"),
      (74, 75, 76, "更多连接", "moreConnections"),
      (82, 83, 84, "显示和亮度", "display"),
      (90, 91, 92, "声音和振动", "sound"),
      (98, 99, 100, "通知和状态栏", "notification"),
    ]
    for (index, item) in items.enumerated() {
      let top = Double(730 + index * 152)
      rows.append(Row(item.0, 21, 5, "ListItem", item.3, 40, top, 1000, 136, interactive: true))
      rows.append(Row(item.1, item.0, 6, "Image", item.4, 86, top + 36, 64, 64))
      rows.append(Row(item.2, item.0, 6, "Text", item.3, 186, top + 44, Double(item.3.count) * 34, 48))
    }
    rows.append(Row(120, 8, 4, "Column", "safe-area", 0, 1810, 1080, 110))
    return build(rows)
  }

  /// A wide-and-deep synthetic tree. Real dumps are both, and a tree that is
  /// only deep or only wide hides a different half of the cost.
  static func syntheticTree(count: Int) -> [ViewerNode] {
    var rows: [Row] = [Row(1, nil, 1, "Root", nil, 0, 0, 1080, 1920)]
    let types = ["Column", "Row", "List", "ListItem", "Text", "Image", "Toggle", "CustomComponent"]
    var nextID = 2
    var frontier = [(id: 1, level: 1, x: 0.0, y: 0.0, width: 1080.0, height: 1920.0)]
    var cursor = 0
    while nextID <= count, cursor < frontier.count {
      let parent = frontier[cursor]
      cursor += 1
      let fanout = parent.level < 4 ? 4 : 3
      for slot in 0..<fanout where nextID <= count {
        let level = parent.level + 1
        let width = max(8, parent.width * 0.82)
        let height = max(8, parent.height / Double(fanout) * 0.86)
        let x = min(Double(screenWidth) - width, parent.x + parent.width * 0.04)
        let y = min(Double(screenHeight) - height, parent.y + parent.height / Double(fanout) * Double(slot))
        let type = types[nextID % types.count]
        rows.append(
          Row(
            nextID, parent.id, level, type,
            type == "Text" || type == "Image" ? "node-\(nextID)" : nil,
            x, y, width, height,
            interactive: type == "Toggle"))
        frontier.append((nextID, level, x, y, width, height))
        nextID += 1
      }
    }
    return build(rows)
  }

  // MARK: - Row -> ViewerNode

  struct Row {
    let id: Int
    let parent: Int?
    let level: Int
    let type: String
    let text: String?
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let interactive: Bool
    let inspectorID: String?

    init(
      _ id: Int, _ parent: Int?, _ level: Int, _ type: String, _ text: String?,
      _ x: Double, _ y: Double, _ width: Double, _ height: Double,
      interactive: Bool = false, inspectorID: String? = nil
    ) {
      self.id = id
      self.parent = parent
      self.level = level
      self.type = type
      self.text = text
      self.x = x
      self.y = y
      self.width = width
      self.height = height
      self.interactive = interactive
      self.inspectorID = inspectorID
    }
  }

  static func build(_ rows: [Row]) -> [ViewerNode] {
    var children: [Int: [String]] = [:]
    for row in rows {
      guard let parent = row.parent else { continue }
      children[parent, default: []].append(String(row.id))
    }
    return rows.map { row in
      var raw: [String: Any] = [
        "id": row.id, "type": row.type, "bounds": [row.x, row.y, row.width, row.height],
        "enabled": true, "visible": true, "clickable": row.interactive,
        "focusable": row.interactive, "zIndex": row.level,
        // A dump the parser has never seen must survive into Raw dump intact.
        // Keeping one here means the fixture proves that, not just asserts it.
        "fixtureUnknownField": "preserved",
      ]
      if let text = row.text { raw["text"] = text }
      if let inspectorID = row.inspectorID { raw["inspectorId"] = inspectorID }
      return ViewerNode(
        identity: String(row.id),
        deviceID: String(row.id),
        parentIdentity: row.parent.map(String.init),
        children: children[row.id] ?? [],
        type: row.type,
        text: row.text,
        inspectorID: row.inspectorID,
        bounds: ViewerBounds(x: row.x, y: row.y, width: row.width, height: row.height),
        visible: true,
        enabled: true,
        clickable: row.interactive,
        focusable: row.interactive,
        zIndex: Double(row.level),
        depth: row.level - 1,
        rawFields: (try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]))
          ?? Data("{}".utf8))
    }
  }

  // MARK: - Schematic screenshot

  /// One filled rect per node, drawn from the node's own bounds. Deliberately
  /// schematic: a fixture that looked like a photograph could be mistaken for
  /// a real capture in a screenshot attached to a report.
  static func png(for nodes: [ViewerNode], width: Int, height: Int) -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return Data() }
    context.setFillColor(CGColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for node in nodes.sorted(by: { $0.depth < $1.depth }) {
      guard let bounds = node.bounds, bounds.width > 2, bounds.height > 2 else { continue }
      // CoreGraphics is bottom-left; dump bounds are top-left.
      let rect = CGRect(
        x: bounds.x, y: Double(height) - bounds.y - bounds.height,
        width: bounds.width, height: bounds.height)
      let tint = Self.tint(for: node.type)
      context.setFillColor(tint)
      context.fill(rect)
      context.setStrokeColor(CGColor(red: 0.55, green: 0.58, blue: 0.63, alpha: 0.55))
      context.setLineWidth(2)
      context.stroke(rect)
    }
    guard let image = context.makeImage() else { return Data() }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)
    else { return Data() }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return Data() }
    return output as Data
  }

  static func tint(for type: String) -> CGColor {
    switch type {
    case "Text", "Span", "Search": CGColor(red: 1, green: 1, blue: 1, alpha: 0.92)
    case "Image", "Icon": CGColor(red: 0.60, green: 0.72, blue: 0.92, alpha: 0.95)
    case "Toggle", "Button": CGColor(red: 0.20, green: 0.47, blue: 0.96, alpha: 0.95)
    case "ListItem", "ProfileCard": CGColor(red: 1, green: 1, blue: 1, alpha: 0.98)
    default: CGColor(red: 0.87, green: 0.89, blue: 0.92, alpha: 0.45)
    }
  }

  // MARK: - Provider

  private struct Provider: UIDumpApplicationProviding {
    let capture: ViewerCapture

    func refreshWorkspace(
      deviceObservation: DeviceListPresentation
    ) async -> UIDumpWorkspacePresentation {
      UIDumpWorkspacePresentation(
        operation: UIDumpApplicationFacade.operationPresentation(availability: .available),
        targets: [
          UIDumpTargetPresentation(
            id: "target-ui-fixture",
            bindingRevision: 1,
            toolVersion: "ui-fixture",
            adoptedAtUTC: "2026-08-22T00:00:00Z",
            connection: .connected)
        ],
        relatedJobs: [])
    }

    func recapture(target: UIDumpTargetPresentation) async -> ViewerCaptureSubmissionResult {
      .captured(capture)
    }

    func cancel(jobID: String) async -> Bool { false }
  }
}

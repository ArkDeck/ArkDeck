import Darwin
import Foundation
import XCTest

@testable import ArkDeckCore

/// What Swift's CLI does for `ui-dump inspect|hit-test`, recorded for the
/// Rust CLI to replay (`rust/crates/arkdeck-cli/tests/ui_dump.rs`).
///
/// The real `arkdeck` process runs each argv against `ScriptedRuntime` (the
/// domain executor oracle's scripted peer). The Job's inventory is built from
/// Swift's recorded Artifact row (`Fixtures/ControlFrames/artifact.list.jsonl`)
/// around a screenshot, a component tree and a raw dump made for each case:
/// a tree inside a display envelope whose bounds verify the coordinates, with
/// identities, types, flags, bounds and z-order spelled every way the parser
/// reads them (strings, numbers, booleans, arrays and corner strings); hit
/// tests in front, behind a transparent overlay, inside a clip, under a root
/// and off every node; a capture whose coordinates are unverified; and the
/// refusals — no tree, no screenshot, a product of the wrong privacy, a
/// duplicate, a PNG that is not one, bytes that do not match their digest and
/// an empty inventory. The record is each run's argv, script, the frames it
/// sent (random identities labelled), its exit status, stdout and stderr.
///
/// Record a new oracle with
/// `ARKDECK_RUST_UI_DUMP_INSPECT_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class CLIUIDumpInspectOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/ui-dump-inspect", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_UI_DUMP_INSPECT_RECORD"
  private static let jobID = "job-ui-dump-oracle"

  private static func member(_ value: JSONValue?, _ key: String) -> JSONValue? {
    guard case .object(let fields)? = value else { return nil }
    return fields[key]
  }

  private static func with(_ value: JSONValue, _ key: String, _ replacement: JSONValue?)
    -> JSONValue
  {
    guard case .object(var fields) = value else { return value }
    fields[key] = replacement
    return .object(fields)
  }

  /// Swift's recorded published Artifact that names an observation window.
  private static func itemTemplate() throws -> JSONValue {
    let text = try String(
      contentsOf: repository.appending(
        path: "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/artifact.list.jsonl"
      ), encoding: .utf8)
    for line in text.split(separator: "\n") {
      let frame = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
      guard member(frame, "ok") == .bool(true),
        case .array(let items)? = member(member(frame, "result"), "items")
      else { continue }
      for item in items
      where member(item, "status") == .string("published")
        && member(item, "observationWindow") != .null
      {
        return item
      }
    }
    throw XCTSkip("Swift recorded no Artifact with an observation window")
  }

  private struct Artifact {
    let id: String
    let name: String
    let mediaType: String
    let privacy: String
    let bytes: Data
  }

  private static func item(_ artifact: Artifact, template: JSONValue) -> JSONValue {
    var item = template
    item = with(item, "artifactId", .string(artifact.id))
    item = with(item, "name", .string(artifact.name))
    item = with(item, "mediaType", .string(artifact.mediaType))
    item = with(item, "privacy", .string(artifact.privacy))
    item = with(item, "status", .string("published"))
    item = with(item, "sourceOperation", .string("capture.diagnostics@1"))
    item = with(item, "lease", .string("lease-v1:\(jobID):\(artifact.id)"))
    item = with(item, "owner", .object(["id": .string(jobID), "kind": .string("job")]))
    item = with(item, "byteCount", .integer(Int64(artifact.bytes.count)))
    item = with(item, "artifactDigest", .string(SHA256Hex.string(of: artifact.bytes)))
    return item
  }

  private static func page(_ items: [JSONValue]) -> JSONValue {
    .object([
      "hasMore": .bool(false), "items": .array(items), "nextCursor": .null,
      "order": .string("createdAtDescArtifactIdAsc"), "pageKind": .string("snapshot"),
      "schemaVersion": .string("arkdeck.cli.page/1"),
      "snapshotRevision": .string("00000000-0000-4000-8000-0000000000d7"),
    ])
  }

  private static func read(_ artifact: Artifact, served: Data? = nil) -> JSONValue {
    let body = served ?? artifact.bytes
    return .object([
      "artifactDigest": .string(SHA256Hex.string(of: artifact.bytes)),
      "artifactId": .string(artifact.id), "base64": .string(body.base64EncodedString()),
      "byteCount": .integer(Int64(body.count)), "eof": .bool(true),
      "nextOffset": .integer(Int64(body.count)), "offset": .integer(0),
      "totalByteCount": .integer(Int64(artifact.bytes.count)),
    ])
  }

  private static func png(width: UInt32, height: UInt32) -> Data {
    var bytes: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82]
    for value in [width, height] {
      bytes += [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
    }
    bytes += [8, 6, 0, 0, 0]
    return Data(bytes)
  }

  /// A display envelope over two windows: the app, whose list clips its
  /// rows, and a status bar behind a transparent overlay.
  private static let verifiedTree = Data(
    """
    {"attributes":{"bounds":"[0,0][400,800]"},"children":[
     {"attributes":{"type":"Window","accessibilityId":1,"bounds":[0,0,400,800],
       "focused":"true","zIndex":0},"children":[
       {"attributes":{"type":"List","accessibilityId":"2","clip":true,
         "bounds":{"left":0,"top":100,"right":400,"bottom":500}},"children":[
         {"attributes":{"type":"Row","accessibilityId":3.5,"text":"first",
           "bounds":{"x":0,"y":80,"width":400,"height":60},"clickable":1}},
         {"attributes":{"type":"Row","nodeId":"4","text":"second",
           "bounds":{"x":0,"y":160,"width":400,"height":60},"enabled":false}}]},
       {"attributes":{"componentType":"Overlay","id":"5","bounds":[0,0,400,800],
         "hitTestBehavior":"HitTestMode.Transparent","zIndex":"9"}},
       {"attributes":{"class":"Button","componentId":"6","inspectorId":"ok",
         "bounds":"[300,700][380,760]","zOrder":2,"focusable":"yes","visible":"true"}},
       {"type":"Floating","accessibilityId":true,"bounds":[250,690,100,40],"zIndex":1}]},
     {"attributes":{"type":"StatusBar","accessibilityId":"7","bounds":[0,0,400,40]},
      "children":[{"attributes":{"type":"Clock","accessibilityId":"7","text":12}}]}]}
    """.utf8)

  /// A tree whose root does not cover the screenshot.
  private static let unverifiedTree = Data(
    """
    {"type":"Window","id":"w","bounds":[0,0,100,100],"children":[{"type":"Text","id":"t"}]}
    """.utf8)

  private struct Case {
    let name: String
    let argv: [String]
    let script: [(String, ScriptedRuntime.Reply)]
  }

  private static func cases() throws -> [Case] {
    let template = try itemTemplate()
    let screenshot = Artifact(
      id: "ART-00000000000000000000000000000e01", name: "screenshot.png",
      mediaType: "image/png", privacy: "sensitive", bytes: png(width: 400, height: 800))
    let rawDump = Artifact(
      id: "ART-00000000000000000000000000000e02", name: "ui-dump.json",
      mediaType: "application/json", privacy: "sensitive", bytes: Data("window 1\n".utf8))
    let tree = Artifact(
      id: "ART-00000000000000000000000000000e03", name: "ui-tree.json",
      mediaType: "application/json", privacy: "sensitive", bytes: verifiedTree)
    let log = Artifact(
      id: "ART-00000000000000000000000000000e04", name: "hilog.txt",
      mediaType: "text/plain", privacy: "standard", bytes: Data("log\n".utf8))
    func inventory(_ artifacts: [Artifact]) -> (String, ScriptedRuntime.Reply) {
      ("artifact.list", .result(page(artifacts.map { item($0, template: template) })))
    }
    func reads(_ artifacts: [Artifact]) -> [(String, ScriptedRuntime.Reply)] {
      artifacts.map { ("artifact.read", .result(read($0))) }
    }
    let all = [screenshot, rawDump, tree, log]
    let full = [inventory(all)] + reads([tree, screenshot, rawDump])
    func machine(_ argv: [String], _ name: String) -> [String] {
      argv + ["--output", "json", "--control-request-id", "ctl-ui-dump-\(name)"]
    }
    let inspect = ["ui-dump", "inspect", "--job", jobID]
    func hit(_ x: String, _ y: String, _ extra: [String] = []) -> [String] {
      ["ui-dump", "hit-test", "--job", jobID, "--x", x, "--y", y] + extra
    }
    var list: [Case] = [
      Case(name: "inspect", argv: machine(inspect, "inspect"), script: full),
      Case(name: "inspectHuman", argv: inspect, script: full),
      Case(name: "hitRowInsideClip", argv: machine(hit("10", "150"), "hitRowInsideClip"), script: full),
      Case(name: "hitClippedAway", argv: machine(hit("10", "90"), "hitClippedAway"), script: full),
      Case(name: "hitButtonOverFloating", argv: machine(hit("310", "710"), "hitButtonOverFloating"), script: full),
      Case(name: "hitStatusBar", argv: machine(hit("5", "5"), "hitStatusBar"), script: full),
      Case(
        name: "hitUnderRoot",
        argv: machine(hit("5", "5", ["--root", "device:1"]), "hitUnderRoot"), script: full),
      Case(
        name: "hitUnknownRoot",
        argv: machine(hit("5", "5", ["--root", "device:none"]), "hitUnknownRoot"), script: full),
      Case(name: "hitOffScreen", argv: machine(hit("900", "900"), "hitOffScreen"), script: full),
      Case(name: "hitHuman", argv: hit("10", "150"), script: full),
    ]
    let unverified = Artifact(
      id: tree.id, name: tree.name, mediaType: tree.mediaType, privacy: tree.privacy,
      bytes: unverifiedTree)
    list.append(
      Case(
        name: "hitUnverified", argv: machine(hit("1", "1"), "hitUnverified"),
        script: [inventory([screenshot, unverified])] + reads([unverified, screenshot])))
    list.append(
      Case(
        name: "inspectUnverified", argv: machine(inspect, "inspectUnverified"),
        script: [inventory([screenshot, unverified])] + reads([unverified, screenshot])))
    list.append(
      Case(
        name: "noTree", argv: machine(inspect, "noTree"),
        script: [inventory([screenshot, log])]))
    list.append(
      Case(
        name: "noScreenshot", argv: machine(inspect, "noScreenshot"),
        script: [inventory([tree, log])]))
    let standard = Artifact(
      id: tree.id, name: tree.name, mediaType: tree.mediaType, privacy: "standard",
      bytes: tree.bytes)
    list.append(
      Case(
        name: "treeNotSensitive", argv: machine(inspect, "treeNotSensitive"),
        script: [inventory([screenshot, standard])]))
    let duplicate = Artifact(
      id: "ART-00000000000000000000000000000e05", name: "ui-tree.json",
      mediaType: "application/json", privacy: "sensitive", bytes: verifiedTree)
    list.append(
      Case(
        name: "duplicateTree", argv: machine(inspect, "duplicateTree"),
        script: [inventory([screenshot, tree, duplicate])]))
    let notPNG = Artifact(
      id: screenshot.id, name: screenshot.name, mediaType: screenshot.mediaType,
      privacy: screenshot.privacy, bytes: Data("not a png at all, still not".utf8))
    list.append(
      Case(
        name: "screenshotNotPNG", argv: machine(inspect, "screenshotNotPNG"),
        script: [inventory([notPNG, tree])] + reads([tree, notPNG])))
    var altered = verifiedTree
    altered[altered.startIndex] = UInt8(ascii: "[")
    list.append(
      Case(
        name: "treeBytesDiffer", argv: machine(inspect, "treeBytesDiffer"),
        script: [
          inventory([screenshot, tree]), ("artifact.read", .result(read(tree, served: altered))),
          ("artifact.read", .result(read(screenshot))),
        ]))
    list.append(
      Case(
        name: "emptyInventory", argv: machine(inspect, "emptyInventory"),
        script: [inventory([])]))
    return list
  }

  private struct CLIRun {
    let exitCode: Int32
    let stdout: String
    let stderr: String
  }

  private func runCLI(_ arguments: [String]) throws -> CLIRun {
    let executable = Bundle(for: Self.self).bundleURL
      .deletingLastPathComponent().appending(path: "arkdeck")
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let out = stdout.fileHandleForReading.readDataToEndOfFile()
    let err = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CLIRun(
      exitCode: process.terminationStatus,
      stdout: String(decoding: out, as: UTF8.self),
      stderr: String(decoding: err, as: UTF8.self))
  }

  func testSwiftUIDumpDerivationTheRustCLIReplays() throws {
    var records: [JSONValue] = []
    for scripted in try Self.cases() {
      let runtime = try ScriptedRuntime(scripted.script)
      let run = try runCLI(scripted.argv + ["--socket", runtime.socketPath])
      let served = runtime.stop()
      records.append(
        .object([
          "name": .string(scripted.name), "argv": .array(scripted.argv.map(JSONValue.string)),
          "script": .array(scripted.script.map { method, reply in reply.recorded(method) }),
          "sent": .array(served.sent), "connections": .integer(Int64(served.connections)),
          "unusedScript": .array(served.unused.map(JSONValue.string)),
          "exit": .integer(Int64(run.exitCode)), "stdout": .string(run.stdout),
          "stderr": .string(run.stderr),
        ]))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [:]
    files["cases.json"] = try encoder.encode(JSONValue.array(records)) + Data("\n".utf8)
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string("CLIUIDumpInspectOracleContractTests"),
          "owners": .array([
            .string("RuntimeCLI.emitUIDumpDerivation"), .string("UIDumpOfflineInspector"),
            .string("ViewerCaptureParser"), .string("ViewerHitTesting"),
            .string("CLIOfflineDerivation"),
          ]),
          "answers": .string("Fixtures/ControlFrames"),
        ])) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.recordVariable, oracle: Self.oracle)
  }
}

import Darwin
import Foundation
import XCTest

@testable import ArkDeckCore

/// What Swift's CLI does for `diagnostics inspect|preview`, recorded for the
/// Rust CLI to replay (`rust/crates/arkdeck-cli/tests/diagnostics_inspect.rs`).
///
/// The real `arkdeck` process runs each argv against `ScriptedRuntime` (the
/// domain executor oracle's scripted peer). The Job is Swift's recorded
/// `capture.diagnostics@1` Job (`Fixtures/ControlFrames/job.show.jsonl`); its
/// Artifact inventory and bytes are built here from Swift's recorded page and
/// read shapes, around session documents made for each case: a complete
/// reading, a missing marker document, disagreeing index and summary, bytes
/// that do not match their digest, an empty inventory, an unknown marker, and
/// previews of text, invalid UTF-8, clipped text, a sensitive log with and
/// without explicit access, malformed JSON and an image. The record is each
/// run's argv, script, the frames it sent (random identities labelled), its
/// exit status, stdout and stderr. Every run names its correlation identity,
/// so each envelope is fixed.
///
/// Record a new oracle with
/// `ARKDECK_RUST_DIAGNOSTICS_INSPECT_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class CLIDiagnosticsInspectOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/diagnostics-inspect", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_DIAGNOSTICS_INSPECT_RECORD"

  private static func frames(_ method: String) throws -> [JSONValue] {
    let text = try String(
      contentsOf: repository.appending(
        path:
          "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/\(method).jsonl"
      ), encoding: .utf8)
    return try text.split(separator: "\n").map {
      try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
    }
  }

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

  /// Swift's recorded diagnostics Job: its `job.show` answer.
  private static func job() throws -> (id: String, show: JSONValue) {
    for frame in try frames("job.show") {
      guard member(frame, "ok") == .bool(true), let result = member(frame, "result"),
        member(member(result, "job"), "operation") == .string("capture.diagnostics@1"),
        case .string(let id)? = member(member(result, "job"), "jobId")
      else { continue }
      return (id, result)
    }
    throw XCTSkip("Swift recorded no diagnostics Job")
  }

  /// Swift's recorded published Artifact, as an item of `job`.
  private static func itemTemplate() throws -> JSONValue {
    for frame in try frames("artifact.list") {
      guard member(frame, "ok") == .bool(true),
        case .array(let items)? = member(member(frame, "result"), "items"),
        let item = items.first, member(item, "status") == .string("published")
      else { continue }
      return item
    }
    throw XCTSkip("Swift recorded no Artifact")
  }

  private struct Artifact {
    let id: String
    let name: String
    let mediaType: String
    let privacy: String
    let bytes: Data?
  }

  private static func item(_ artifact: Artifact, job: String, template: JSONValue) -> JSONValue {
    var item = template
    item = with(item, "artifactId", .string(artifact.id))
    item = with(item, "name", .string(artifact.name))
    item = with(item, "mediaType", .string(artifact.mediaType))
    item = with(item, "privacy", .string(artifact.privacy))
    item = with(item, "sourceOperation", .string("capture.diagnostics@1"))
    item = with(item, "owner", .object(["id": .string(job), "kind": .string("job")]))
    if let bytes = artifact.bytes {
      item = with(item, "status", .string("published"))
      item = with(item, "lease", .string("lease-v1:\(job):\(artifact.id)"))
      item = with(item, "byteCount", .integer(Int64(bytes.count)))
      item = with(item, "artifactDigest", .string(SHA256Hex.string(of: bytes)))
    } else {
      item = with(item, "status", .string("missing"))
      // Only a published Artifact holds a lease.
      item = with(item, "lease", .null)
      item = with(item, "byteCount", .integer(0))
      item = with(item, "artifactDigest", .null)
    }
    return item
  }

  private static func page(_ items: [JSONValue]) -> JSONValue {
    .object([
      "hasMore": .bool(false), "items": .array(items), "nextCursor": .null,
      "order": .string("createdAtDescArtifactIdAsc"), "pageKind": .string("snapshot"),
      "schemaVersion": .string("arkdeck.cli.page/1"),
      "snapshotRevision": .string("00000000-0000-4000-8000-00000000d1a6"),
    ])
  }

  private static func read(_ artifact: Artifact, served: Data? = nil) -> JSONValue {
    let bytes = artifact.bytes ?? Data()
    let body = served ?? bytes
    return .object([
      "artifactDigest": .string(SHA256Hex.string(of: bytes)),
      "artifactId": .string(artifact.id), "base64": .string(body.base64EncodedString()),
      "byteCount": .integer(Int64(body.count)), "eof": .bool(true),
      "nextOffset": .integer(Int64(bytes.count)), "offset": .integer(0),
      "totalByteCount": .integer(Int64(bytes.count)),
    ])
  }

  private static func json(_ value: JSONValue) throws -> Data {
    try CanonicalJSONEncoders.canonical().encode(value)
  }

  private struct Case {
    let name: String
    let argv: [String]
    let script: [(String, ScriptedRuntime.Reply)]
  }

  private static func cases() throws -> [Case] {
    let (jobID, show) = try job()
    let template = try itemTemplate()
    let trace: JSONValue = .object([
      "detail": .string("trace capture failed"), "required": .bool(true),
      "status": .string("missing"),
    ])
    func documents(completeness: String = "incomplete", markers: JSONValue? = nil) throws
      -> (index: Data, summary: Data, markers: Data)
    {
      let artifacts: JSONValue = .object(["trace.htrace": trace])
      let index = try json(
        .object([
          "jobId": .string(jobID), "operation": .string("capture.diagnostics@1"),
          "artifacts": artifacts,
        ]))
      let summary = try json(
        .object([
          "jobId": .string(jobID), "operation": .string("capture.diagnostics@1"),
          "artifacts": artifacts, "completeness": .string(completeness),
          "missingRequired": .array([.string("trace.htrace")]),
        ]))
      let marks = try json(
        markers
          ?? .object([
            "documentType": .string("arkdeck-diagnostic-markers"),
            "schemaVersion": .string("1.0.0"), "jobId": .string(jobID),
            "markers": .array([
              .object([
                "kind": .string("manual"), "atHostUTC": .string("2026-09-10T00:00:01Z"),
                "label": .string("stutter"),
              ]),
              .object(["kind": .string("auto"), "trigger": .string("anr")]),
              .object([
                "kind": .string("auto"), "trigger": .string("crash"),
                "atHostUTC": .string("2026-09-10T00:00:02.500Z"), "label": .integer(7),
              ]),
            ]),
            "notDerived": .array([
              .object(["kind": .string("frameDrops"), "reason": .string("not sampled")])
            ]),
            "coverage": .object(["ringHeldAnchor": .integer(1)]),
          ]))
      return (index, summary, marks)
    }
    func artifacts(_ docs: (index: Data, summary: Data, markers: Data), markers: Bool = true)
      -> [Artifact]
    {
      [
        Artifact(
          id: "ART-00000000000000000000000000000d01", name: "artifact-index.json",
          mediaType: "application/json", privacy: "standard", bytes: docs.index),
        Artifact(
          id: "ART-00000000000000000000000000000d02", name: "capture-summary.json",
          mediaType: "application/json", privacy: "standard", bytes: docs.summary),
        Artifact(
          id: "ART-00000000000000000000000000000d03", name: "markers.json",
          mediaType: "application/json", privacy: "standard",
          bytes: markers ? docs.markers : nil),
        Artifact(
          id: "ART-00000000000000000000000000000d04", name: "trace.htrace",
          mediaType: "application/octet-stream", privacy: "sensitive", bytes: nil),
        Artifact(
          id: "ART-00000000000000000000000000000d05", name: "hilog.txt",
          mediaType: "text/plain", privacy: "standard",
          bytes: Data("first line\nsecond ".utf8) + Data([0xFF, 0xFE]) + Data(" line\n".utf8)),
        Artifact(
          id: "ART-00000000000000000000000000000d06", name: "private-hilog.txt",
          mediaType: "text/plain", privacy: "sensitive", bytes: Data("secret line\n".utf8)),
        Artifact(
          id: "ART-00000000000000000000000000000d07", name: "ui-dump.json",
          mediaType: "application/json", privacy: "standard",
          bytes: Data("{\"a\":".utf8) + Data([0xC3])),
        Artifact(
          id: "ART-00000000000000000000000000000d08", name: "screenshot.png",
          mediaType: "image/png", privacy: "standard", bytes: Data([0x89, 0x50, 0x4E, 0x47])),
      ]
    }
    func inventory(_ list: [Artifact]) -> (String, ScriptedRuntime.Reply) {
      ("artifact.list", .result(page(list.map { item($0, job: jobID, template: template) })))
    }
    let docs = try documents()
    let all = artifacts(docs)
    let inspect = ["diagnostics", "inspect", "--job", jobID, "--output", "json"]
    func correlated(_ argv: [String], _ name: String) -> [String] {
      argv + ["--control-request-id", "ctl-diagnostics-\(name)"]
    }
    let reads: [(String, ScriptedRuntime.Reply)] = all.prefix(3).map {
      ("artifact.read", .result(read($0)))
    }
    var list: [Case] = []
    list.append(
      Case(
        name: "inspectComplete", argv: correlated(inspect, "inspectComplete"),
        script: [inventory(all), ("job.show", .result(show))] + reads))
    list.append(
      Case(
        name: "inspectHuman",
        argv: ["diagnostics", "inspect", "--job", jobID],
        script: [inventory(all), ("job.show", .result(show))] + reads))
    let withoutMarkers = artifacts(docs, markers: false)
    list.append(
      Case(
        name: "inspectWithoutMarkers", argv: correlated(inspect, "inspectWithoutMarkers"),
        script: [inventory(withoutMarkers), ("job.show", .result(show))]
          + withoutMarkers.prefix(2).map { ("artifact.read", .result(read($0))) }))
    let mismatched = try documents(completeness: "complete")
    let mismatchedAll = artifacts(mismatched)
    list.append(
      Case(
        name: "inspectSummaryMismatch", argv: correlated(inspect, "inspectSummaryMismatch"),
        script: [inventory(mismatchedAll), ("job.show", .result(show))]
          + mismatchedAll.prefix(3).map { ("artifact.read", .result(read($0))) }))
    list.append(
      Case(
        name: "inspectBytesDiffer", argv: correlated(inspect, "inspectBytesDiffer"),
        script: [
          inventory(all), ("job.show", .result(show)),
          ("artifact.read", .result(read(all[0], served: Data("{}".utf8)))),
        ]))
    list.append(
      Case(
        name: "inspectEmptyInventory", argv: correlated(inspect, "inspectEmptyInventory"),
        script: [inventory([])]))
    let unknown = try documents(
      markers: .object([
        "documentType": .string("arkdeck-diagnostic-markers"),
        "schemaVersion": .string("1.0.0"), "jobId": .string(jobID),
        "markers": .array([.object(["kind": .string("guess")])]), "notDerived": .array([]),
      ]))
    let unknownAll = artifacts(unknown)
    list.append(
      Case(
        name: "inspectUnknownMarker", argv: correlated(inspect, "inspectUnknownMarker"),
        script: [inventory(unknownAll), ("job.show", .result(show))]
          + unknownAll.prefix(3).map { ("artifact.read", .result(read($0))) }))
    func preview(_ name: String, _ artifact: Artifact, _ extra: [String] = [], reads: Bool = true)
      -> Case
    {
      Case(
        name: name,
        argv: correlated(
          ["diagnostics", "preview", "--job", jobID, "--artifact", artifact.id] + extra
            + ["--output", "json"], name),
        script: [inventory(all)] + (reads ? [("artifact.read", .result(read(artifact)))] : []))
    }
    list.append(preview("previewText", all[4]))
    list.append(preview("previewClipped", all[4], ["--max-characters", "5"]))
    list.append(preview("previewSensitiveRefused", all[5], reads: false))
    list.append(preview("previewSensitiveAllowed", all[5], ["--allow-sensitive"]))
    list.append(preview("previewInvalidJson", all[6]))
    list.append(preview("previewImage", all[7]))
    list.append(
      Case(
        name: "previewUnknownArtifact",
        argv: correlated(
          ["diagnostics", "preview", "--job", jobID, "--artifact",
           "ART-00000000000000000000000000000dff", "--output", "json"],
          "previewUnknownArtifact"),
        script: [inventory(all)]))
    list.append(
      Case(
        name: "previewHuman",
        argv: ["diagnostics", "preview", "--job", jobID, "--artifact", all[4].id],
        script: [inventory(all), ("artifact.read", .result(read(all[4])))]))
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

  func testSwiftDiagnosticsInspectionTheRustCLIReplays() throws {
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
          "producer": .string("CLIDiagnosticsInspectOracleContractTests"),
          "owners": .array([
            .string("RuntimeCLI.runDiagnosticsResource"),
            .string("DiagnosticSessionOfflineInspector"), .string("DiagnosticSessionReading"),
            .string("DiagnosticArtifactTextPreview"),
          ]),
          "answers": .string("Fixtures/ControlFrames"),
        ])) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.recordVariable, oracle: Self.oracle)
  }
}

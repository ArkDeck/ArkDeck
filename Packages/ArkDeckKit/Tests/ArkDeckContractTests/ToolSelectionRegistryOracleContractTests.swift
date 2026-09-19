// Shared Swift oracle for the Rust tool registry's HDC selection ledger
// (TASK-XPA-012): `tools.json` in the bootstrap store as the production
// `BootstrapToolRegistry` leaves it after each operation on the selection —
// `adoptInstalledHDC`, `initializeServiceSelection`, `selectionCandidate`,
// `prepareSelection`, `startupSelection`, `publishPendingSelection`,
// `failPendingSelection`, `selectionOutcome`, `acknowledgeSelectionOutcome`,
// with `register`, `acquire`, `release`, `remove` and `list` around them —
// each operation's answer or refusal, and whether it published the index.
//
// The registered tools are synthetic Mach-O executables built here byte for
// byte: a header and one load command, no program, never run. macOS reports
// them unsigned, so the production trust inspection, the content digests and
// every index are the same on every host, and the registration clock is
// fixed: played again, the oracle is every checked-in file, byte for byte.
// Each tool stands for a published HDC identity, as the daemon's lookup
// answers for a real HDC, except one that has none and one that loads a
// library outside the system (not relocatable), for the refusals they reach.
// A few steps change the store behind the registry's back (`harness.*`): a
// lost index, a ledger without its pin, altered content, a held lock.
//
// Host-local only: no device, no daemon, no HDC server. Record a new oracle
// with `ARKDECK_RUST_TOOL_SELECTION_REGISTRY_RECORD=/private/tmp/<new directory>`.
import Darwin
import Foundation
import XCTest

@testable import ArkDeckBootstrap
@testable import ArkDeckCore

final class ToolSelectionRegistryOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/tool-selection-registry", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_TOOL_SELECTION_REGISTRY_RECORD"
  private static let registeredAt = "2026-09-01T00:00:00Z"
  private static let identityVersion = "fixture-1"
  private static let identityProfiles = ["fixture-profile"]
  private static let reason = "tool.selectedStartupVerificationFailed"
  private static let unknownTool = "tool:sha256:" + String(repeating: "0", count: 64)
  private var root: URL!

  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/tool-selection-registry-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: Executables

  private struct Executable: Sendable {
    let label: String
    let bytes: Data
    let published: Bool
  }

  private static func word(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
  }

  /// A 64-bit arm64 MH_EXECUTE header and its one load command.
  private static func executable(_ command: Data) -> Data {
    word(0xfeed_facf) + word(0x0100_000c) + word(0) + word(2) + word(1)
      + word(UInt32(command.count)) + word(0) + word(0) + command
  }

  /// LC_UUID: each tool its own content.
  private static func uuid(_ byte: UInt8) -> Data {
    word(0x1b) + word(24) + Data(repeating: byte, count: 16)
  }

  /// LC_LOAD_DYLIB of a library outside the system.
  private static func library(_ path: String) -> Data {
    let size = (24 + path.utf8.count + 1 + 7) / 8 * 8
    var command = word(0xc) + word(UInt32(size)) + word(24) + Data(repeating: 0, count: 12)
    command.append(Data(path.utf8))
    command.append(Data(repeating: 0, count: size - command.count))
    return command
  }

  private static let executables: [Executable] = [
    Executable(label: "a", bytes: executable(uuid(0xa1)), published: true),
    Executable(label: "b", bytes: executable(uuid(0xb2)), published: true),
    Executable(label: "c", bytes: executable(uuid(0xc3)), published: true),
    Executable(label: "unpublished", bytes: executable(uuid(0xd4)), published: false),
    Executable(
      label: "unrelocatable", bytes: executable(library("/opt/fixture/libfixture.dylib")),
      published: true),
  ]

  // MARK: Timelines

  private enum Operation: Sendable {
    case register(String)
    case adopt(String)
    case initialize(String, expected: String)
    case candidate(String, expected: String, pending: String? = nil)
    case prepare(String, tool: String, expected: String)
    case startup
    case publish(String)
    case fail(String, reason: String)
    case outcome(String)
    case acknowledge(String)
    case acquire(String, expected: String, kind: String, id: String)
    case release(String, kind: String, id: String)
    case remove(String, expected: String)
    case list
    /// `tools.json` removed beside the retained content.
    case loseIndex
    /// The selected tool's `activeSelection` pin taken out of the index.
    case unpinIndex
    /// One byte of a tool's retained executable changed in place.
    case alterContent(String)
  }

  private struct Step: Sendable {
    let operation: Operation
    /// Another owner holds the store's lock while the operation runs.
    let lockHeld: Bool
    init(_ operation: Operation, lockHeld: Bool = false) {
      self.operation = operation
      self.lockHeld = lockHeld
    }
  }

  private static let timelines: [(name: String, steps: [Step])] = [
    (
      "fresh-store",
      [
        Step(.startup),
        Step(.outcome("select-a")),
        Step(.acknowledge("select-a")),
        Step(.candidate("a", expected: "1")),
        Step(.prepare("select-a", tool: "a", expected: "1")),
        Step(.publish("select-a")),
        Step(.fail("select-a", reason: reason)),
        Step(.fail("select-a", reason: "not a reason")),
        Step(.initialize("a", expected: "1")),
        Step(.initialize("hdc", expected: "1")),
        Step(.startup, lockHeld: true),
        Step(.list),
      ]
    ),
    (
      "initialized-then-published",
      [
        Step(.register("a")),
        Step(.register("b")),
        Step(.initialize("a", expected: "1")),
        Step(.initialize("a", expected: "1")),
        Step(.initialize("a", expected: "2")),
        Step(.initialize("b", expected: "1")),
        Step(.candidate("b", expected: "1")),
        Step(.candidate("b", expected: "2")),
        Step(.candidate("a", expected: "1")),
        Step(.prepare("select-b", tool: "b", expected: "1")),
        Step(.prepare("select-b", tool: "b", expected: "1")),
        Step(.outcome("select-b")),
        Step(.startup),
        Step(.candidate("b", expected: "1")),
        Step(.candidate("b", expected: "1", pending: "select-b")),
        Step(.candidate("b", expected: "1", pending: "select-other")),
        Step(.remove("a", expected: "1")),
        Step(.remove("b", expected: "1")),
        Step(.publish("select-b")),
        Step(.publish("select-b")),
        Step(.outcome("select-b")),
        Step(.outcome("select-other")),
        Step(.candidate("a", expected: "2")),
        Step(.prepare("select-a", tool: "a", expected: "2")),
        Step(.initialize("b", expected: "1")),
        Step(.acknowledge("select-other")),
        Step(.acknowledge("select-b")),
        Step(.outcome("select-b")),
        Step(.startup),
        Step(.initialize("b", expected: "1")),
        Step(.remove("a", expected: "1")),
        Step(.list),
      ]
    ),
    (
      "adopted-then-failed",
      [
        Step(.adopt("a")),
        Step(.adopt("a")),
        Step(.adopt("b")),
        Step(.prepare("select-b", tool: "b", expected: "1")),
        Step(.prepare("select-c", tool: "b", expected: "1")),
        Step(.prepare("select-b", tool: "a", expected: "1")),
        Step(.initialize("a", expected: "1")),
        Step(.startup, lockHeld: true),
        Step(.fail("select-c", reason: reason)),
        Step(.fail("select-b", reason: reason)),
        Step(.outcome("select-b")),
        Step(.fail("select-b", reason: reason)),
        Step(.publish("select-b")),
        Step(.remove("b", expected: "1")),
        Step(.acknowledge("select-b")),
        Step(.prepare("select-b2", tool: "b", expected: "1")),
        Step(.startup),
        Step(.list),
      ]
    ),
    (
      "refusals-by-tool",
      [
        Step(.register("a")),
        Step(.register("c")),
        Step(.register("unpublished")),
        Step(.register("unrelocatable")),
        Step(.initialize("unpublished", expected: "1")),
        Step(.initialize("unrelocatable", expected: "1")),
        Step(.remove("c", expected: "1")),
        Step(.initialize("c", expected: "1")),
        Step(.acquire("a", expected: "1", kind: "activeSelection", id: "runtime-hdc-selection")),
        Step(.startup),
        Step(.initialize("a", expected: "1")),
        Step(.release("a", kind: "activeSelection", id: "runtime-hdc-selection")),
        Step(.release("a", kind: "activeSelection", id: "runtime-hdc-selection")),
        Step(.initialize("a", expected: "1")),
        Step(.candidate("unpublished", expected: "1")),
        Step(.candidate("c", expected: "1")),
        Step(.candidate(unknownTool, expected: "1")),
        Step(.prepare("select-unpublished", tool: "unpublished", expected: "1")),
        Step(.prepare("select-c", tool: "c", expected: "1")),
        Step(.prepare("select-a", tool: "a", expected: "1")),
        Step(.prepare("select unrelocatable", tool: "unrelocatable", expected: "1")),
        Step(.prepare("select-unrelocatable", tool: "unrelocatable", expected: "1")),
        Step(.startup),
        Step(.publish("select-unrelocatable")),
        Step(.acknowledge("select-unrelocatable")),
        Step(.startup),
        Step(.list),
      ]
    ),
    (
      "lost-index",
      [
        Step(.register("a")),
        Step(.loseIndex),
        Step(.startup),
        Step(.initialize("a", expected: "1")),
        Step(.list),
      ]
    ),
    (
      "unpinned-ledger",
      [
        Step(.register("a")),
        Step(.initialize("a", expected: "1")),
        Step(.unpinIndex),
        Step(.startup),
        Step(.outcome("select-a")),
        Step(.acknowledge("select-a")),
      ]
    ),
    (
      "altered-content",
      [
        Step(.register("a")),
        Step(.register("b")),
        Step(.initialize("a", expected: "1")),
        Step(.alterContent("b")),
        Step(.startup),
        Step(.candidate("b", expected: "1")),
        Step(.prepare("select-b", tool: "b", expected: "1")),
        Step(.alterContent("a")),
        Step(.startup),
        Step(.outcome("select-b")),
        Step(.acknowledge("select-b")),
      ]
    ),
  ]

  // MARK: Playing

  /// One timeline's store and the tools its steps name.
  private struct Play {
    let registry: BootstrapToolRegistry
    let store: URL
    let sources: [String: URL]
    let references: [String: String]

    func reference(_ tool: String) -> String { references[tool] ?? tool }
  }

  private func registry(at store: URL) -> BootstrapToolRegistry {
    let published = Set(
      Self.executables.filter(\.published).map { SHA256Hex.string(of: $0.bytes) })
    let identity = BootstrapToolRegistry.PublishedIdentity(
      version: Self.identityVersion, profileReferences: Self.identityProfiles)
    return BootstrapToolRegistry(
      owner: BootstrapBundleRegistry(root: store),
      knownIdentity: { published.contains($0) ? identity : nil },
      nowUTC: { Self.registeredAt })
  }

  private static func name(_ operation: Operation) -> String {
    switch operation {
    case .register: "register"
    case .adopt: "adoptInstalledHDC"
    case .initialize: "initializeServiceSelection"
    case .candidate: "selectionCandidate"
    case .prepare: "prepareSelection"
    case .startup: "startupSelection"
    case .publish: "publishPendingSelection"
    case .fail: "failPendingSelection"
    case .outcome: "selectionOutcome"
    case .acknowledge: "acknowledgeSelectionOutcome"
    case .acquire: "acquire"
    case .release: "release"
    case .remove: "remove"
    case .list: "list"
    case .loseIndex: "harness.removeIndex"
    case .unpinIndex: "harness.unpinActiveTool"
    case .alterContent: "harness.alterContent"
    }
  }

  private static func arguments(_ operation: Operation, in play: Play) -> [String: JSONValue] {
    func owner(_ kind: String, _ id: String) -> JSONValue {
      .object(["kind": .string(kind), "id": .string(id)])
    }
    switch operation {
    case .register(let tool), .adopt(let tool), .alterContent(let tool):
      return ["executable": .string(tool)]
    case .initialize(let tool, let expected):
      return ["toolRef": .string(play.reference(tool)), "expectedGeneration": .string(expected)]
    case .candidate(let tool, let expected, let pending):
      return [
        "newToolRef": .string(play.reference(tool)),
        "expectedActiveGeneration": .string(expected),
        "pendingActionID": pending.map(JSONValue.string) ?? .null,
      ]
    case .prepare(let action, let tool, let expected):
      return [
        "actionID": .string(action), "newToolRef": .string(play.reference(tool)),
        "expectedActiveGeneration": .string(expected),
      ]
    case .publish(let action), .outcome(let action), .acknowledge(let action):
      return ["actionID": .string(action)]
    case .fail(let action, let reason):
      return ["actionID": .string(action), "reasonCode": .string(reason)]
    case .acquire(let tool, let expected, let kind, let id):
      return [
        "toolRef": .string(play.reference(tool)), "expectedGeneration": .string(expected),
        "owner": owner(kind, id),
      ]
    case .release(let tool, let kind, let id):
      return ["toolRef": .string(play.reference(tool)), "owner": owner(kind, id)]
    case .remove(let tool, let expected):
      return ["toolRef": .string(play.reference(tool)), "expectedGeneration": .string(expected)]
    case .startup, .list, .loseIndex, .unpinIndex:
      return [:]
    }
  }

  private static func startup(
    _ value: BootstrapToolRegistry.StartupSelection?, store: URL
  ) throws -> JSONValue {
    guard let value else { return .null }
    let prefix = store.path + "/"
    let path = value.resolved.executableURL.path
    guard path.hasPrefix(prefix) else { throw CocoaError(.fileReadInvalidFileName) }
    return .object([
      "toolRef": .string(value.toolRef),
      "activeGeneration": .string(String(value.activeGeneration)),
      "pendingControlActionId": value.pendingActionID.map(JSONValue.string) ?? .null,
      "executable": .string(String(path.dropFirst(prefix.count))),
      "executableSHA256": .string(value.resolved.executableSHA256),
      "dependencies": .array(value.resolved.dependencies.map(\.value)),
    ])
  }

  private static func outcome(
    _ value: BootstrapToolRegistry.DurableSelectionOutcome
  ) -> JSONValue {
    switch value {
    case .pending: .object(["outcome": .string("pending")])
    case .succeeded(let reference, let generation):
      .object([
        "outcome": .string("succeeded"), "activeToolRef": .string(reference),
        "activeGeneration": .string(String(generation)),
      ])
    case .failed(let reference, let generation, let reason):
      .object([
        "outcome": .string("failed"), "activeToolRef": .string(reference),
        "activeGeneration": .string(String(generation)), "reasonCode": .string(reason),
      ])
    case .absent: .object(["outcome": .string("absent")])
    }
  }

  private static func owner(_ kind: String, _ id: String) throws -> BootstrapToolRegistry.ReferenceOwner {
    guard let kind = BootstrapBundleRegistry.ReferenceKind(rawValue: kind) else {
      throw CocoaError(.coderInvalidValue)
    }
    return try BootstrapToolRegistry.ReferenceOwner(kind: kind, id: id)
  }

  private static func perform(_ operation: Operation, in play: Play) throws -> JSONValue {
    let registry = play.registry
    switch operation {
    case .register(let tool):
      return try registry.register(file: play.sources[tool]!)
    case .adopt(let tool):
      return try registry.adoptInstalledHDC(file: play.sources[tool]!).value
    case .initialize(let tool, let expected):
      return try startup(
        registry.initializeServiceSelection(
          reference: play.reference(tool), expectedGeneration: expected),
        store: play.store)
    case .candidate(let tool, let expected, let pending):
      let candidate = try registry.selectionCandidate(
        newToolRef: play.reference(tool), expectedActiveGeneration: expected,
        pendingActionID: pending)
      return .object(["selection": candidate.selection.value, "newTool": candidate.newTool])
    case .prepare(let action, let tool, let expected):
      return try registry.prepareSelection(
        actionID: action, newToolRef: play.reference(tool), expectedActiveGeneration: expected
      ).value
    case .startup:
      return try startup(registry.startupSelection(), store: play.store)
    case .publish(let action):
      return try registry.publishPendingSelection(actionID: action).value
    case .fail(let action, let reason):
      return try registry.failPendingSelection(actionID: action, reasonCode: reason).value
    case .outcome(let action):
      return outcome(try registry.selectionOutcome(actionID: action))
    case .acknowledge(let action):
      try registry.acknowledgeSelectionOutcome(actionID: action)
      return .null
    case .acquire(let tool, let expected, let kind, let id):
      return try registry.acquire(
        play.reference(tool), expectedGeneration: expected, owner: owner(kind, id))
    case .release(let tool, let kind, let id):
      try registry.release(play.reference(tool), owner: owner(kind, id))
      return .null
    case .remove(let tool, let expected):
      return try registry.remove(play.reference(tool), expectedGeneration: expected)
    case .list:
      return .array(try registry.list { _, rows in rows })
    case .loseIndex:
      try FileManager.default.removeItem(at: play.store.appending(path: "tools.json"))
      return .null
    case .unpinIndex:
      let index = play.store.appending(path: "tools.json")
      let unpinned = try unpinned(JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: index)))
      try CanonicalJSONEncoders.canonical().encode(unpinned).write(to: index)
      guard chmod(index.path, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
      return .null
    case .alterContent(let tool):
      let digest = play.reference(tool).dropFirst("tool:sha256:".count)
      let path = play.store.appending(path: "tool-\(digest).hdc/hdc").path
      let fd = open(path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
      guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
      defer { close(fd) }
      var byte: UInt8 = 0xff
      guard pwrite(fd, &byte, 1, 40) == 1 else { throw CocoaError(.fileWriteUnknown) }
      return .null
    }
  }

  /// The selected index with its active tool's pin taken out.
  private static func unpinned(_ index: JSONValue) -> JSONValue {
    let pin = JSONValue.object([
      "kind": .string("activeSelection"), "id": .string("runtime-hdc-selection"),
    ])
    guard case .object(var fields) = index, case .array(let records)? = fields["records"] else {
      return index
    }
    fields["records"] = .array(
      records.map { record in
        guard case .object(var fields) = record, case .array(let references)? = fields["references"]
        else { return record }
        fields["references"] = .array(references.filter { $0 != pin })
        return .object(fields)
      })
    return .object(fields)
  }

  /// `tools.json`'s bytes and file identity, when it exists.
  private static func index(of store: URL) throws -> (bytes: Data, identity: [Int])? {
    let url = store.appending(path: "tools.json")
    var status = stat()
    guard lstat(url.path, &status) == 0 else {
      guard errno == ENOENT else { throw CocoaError(.fileReadUnknown) }
      return nil
    }
    return (
      try Data(contentsOf: url),
      [
        Int(status.st_ino), status.st_birthtimespec.tv_sec, status.st_birthtimespec.tv_nsec,
      ]
    )
  }

  private static func holdingLock<T>(of store: URL, _ body: () throws -> T) throws -> T {
    let fd = open(store.appending(path: ".lock").path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw CocoaError(.fileLocking) }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileLocking) }
    defer { flock(fd, LOCK_UN) }
    return try body()
  }

  private static func encoded(_ value: JSONValue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    return try encoder.encode(value) + Data("\n".utf8)
  }

  /// Every timeline played on its own fresh store: the oracle's files.
  private func produce() throws -> [String: Data] {
    let sourceDirectory = root.appending(path: "sources", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: sourceDirectory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    var sources: [String: URL] = [:]
    for executable in Self.executables {
      let url = sourceDirectory.appending(path: "hdc-\(executable.label)")
      try executable.bytes.write(to: url)
      guard chmod(url.path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
      sources[executable.label] = url
    }
    // The references every tool will have, from a store of its own.
    let census = registry(at: root.appending(path: "census", directoryHint: .isDirectory))
    var references: [String: String] = [:]
    for executable in Self.executables {
      guard case .object(let row) = try census.register(file: sources[executable.label]!),
        case .string(let reference)? = row["toolRef"]
      else { throw CocoaError(.fileReadCorruptFile) }
      references[executable.label] = reference
    }

    var files: [String: Data] = [:]
    var timelines: [JSONValue] = []
    for timeline in Self.timelines {
      let store = root.appending(path: "stores/\(timeline.name)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: store.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let play = Play(
        registry: registry(at: store), store: store, sources: sources, references: references)
      var previous = try Self.index(of: store)?.identity
      var steps: [JSONValue] = []
      for step in timeline.steps {
        var entry: [String: JSONValue] = [
          "operation": .string(Self.name(step.operation)),
          "arguments": .object(Self.arguments(step.operation, in: play)),
        ]
        if step.lockHeld { entry["lockHeldByAnotherOwner"] = .bool(true) }
        do {
          if step.lockHeld {
            entry["answer"] = try Self.holdingLock(of: store) {
              try Self.perform(step.operation, in: play)
            }
          } else {
            entry["answer"] = try Self.perform(step.operation, in: play)
          }
        } catch let failure as AgentExecutionControlFailure {
          entry["refusal"] = .object([
            "code": .string(failure.code), "message": .string(failure.message),
          ])
        }
        let index = try Self.index(of: store)
        if let index {
          let digest = SHA256Hex.string(of: index.bytes)
          files["indexes/\(digest).json"] = index.bytes
          entry["index"] = .string(digest)
        } else {
          entry["index"] = .null
        }
        entry["published"] = .bool(index != nil && index?.identity != previous)
        previous = index?.identity
        steps.append(.object(entry))
      }
      timelines.append(.object(["name": .string(timeline.name), "steps": .array(steps)]))
    }

    files["timelines.json"] = try Self.encoded(.array(timelines))
    files["oracle.json"] = try Self.encoded(
      .object([
        "producer": .string(
          "ToolSelectionRegistryOracleContractTests.testTheProductionRegistryKeepsTheSelectionLedgerAsRecorded"
        ),
        "store": .object([
          "type": .string("BootstrapToolRegistry"),
          "productionDirectory": .string(
            "~/Library/Application Support/ArkDeck/Bootstrap/v1"),
          "index": .string("tools.json"),
          "indexSchemaVersion": .string("arkdeck.bootstrap-tools/2"),
          "encoding": .string("JSONEncoder [.sortedKeys, .withoutEscapingSlashes]"),
          "lock": .string(".lock"),
        ]),
        "registeredAt": .string(Self.registeredAt),
        "publishedIdentity": .object([
          "version": .string(Self.identityVersion),
          "profileReferences": .array(Self.identityProfiles.map(JSONValue.string)),
        ]),
        "executables": .object(
          Dictionary(
            uniqueKeysWithValues: Self.executables.map { executable in
              (
                executable.label,
                JSONValue.object([
                  "base64": .string(executable.bytes.base64EncodedString()),
                  "sha256": .string(SHA256Hex.string(of: executable.bytes)),
                  "published": .bool(executable.published),
                  "toolRef": .string(references[executable.label]!),
                ])
              )
            })),
      ]))
    return files
  }

  func testTheProductionRegistryKeepsTheSelectionLedgerAsRecorded() throws {
    let files = try produce()
    if let output = ProcessInfo.processInfo.environment[Self.recordVariable] {
      let destination = URL(fileURLWithPath: output, isDirectory: true)
      guard destination.path.hasPrefix("/private/tmp/"),
        !FileManager.default.fileExists(atPath: destination.path)
      else { throw CocoaError(.fileWriteFileExists) }
      for (path, data) in files {
        let url = destination.appending(path: path)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try data.write(to: url)
      }
      return
    }

    // Played again, the oracle is every checked-in file and no other.
    let checkedIn = try FileManager.default.subpathsOfDirectory(atPath: Self.oracle.path)
      .filter { path in
        var directory: ObjCBool = false
        FileManager.default.fileExists(
          atPath: Self.oracle.appending(path: path).path, isDirectory: &directory)
        return !directory.boolValue
      }
    XCTAssertEqual(Set(checkedIn), Set(files.keys))
    for (path, data) in files {
      let recorded = try Data(contentsOf: Self.oracle.appending(path: path))
      XCTAssertEqual(
        String(decoding: data, as: UTF8.self), String(decoding: recorded, as: UTF8.self), path)
    }
  }
}

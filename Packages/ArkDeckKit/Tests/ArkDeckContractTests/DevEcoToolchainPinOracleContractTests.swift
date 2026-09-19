// Shared Swift oracle for the Rust DevEco toolchain pins (TASK-XPA-015, M3):
// the index `BootstrapDevEcoToolchainRegistry` keeps in its registry root as
// `deveco-toolchains.json` after each acquire, release, resolve and removal a
// workspace preset's toolchain pin goes through, with each answer and refusal.
// Three timelines: one toolchain through its whole pin life, one whose
// content changes after registration, and one that reaches the reference
// bound.
//
// The fabricated DevEco root's file identities (device, inode, times) change
// on every run, so a new recording never repeats the old index bytes. The
// checked-in oracle is held two ways instead:
// - every checked-in file has the SHA-256 its provenance pins, and every index
//   state is its own canonical bytes;
// - the same timelines, played again through the production registry, give
//   the same answers and the same index states once the root's and children's
//   file identities are set aside.
//
// Host-local only: fabricated content, injected trust, no daemon. Record a new
// oracle with `ARKDECK_RUST_DEVECO_PIN_RECORD=/private/tmp/<new directory>`.
import Darwin
import Foundation
import XCTest

@testable import ArkDeckBootstrap
@testable import ArkDeckCore

final class DevEcoToolchainPinOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/deveco-toolchain-pins", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_DEVECO_PIN_RECORD"
  /// A fixed root: the index names the fabricated Contents root by its path.
  private static let root = URL(
    filePath: "/private/tmp/arkdeck-deveco-pin-oracle", directoryHint: .isDirectory)
  private static let identityKeys: Set<String> = [
    "device", "inode", "modifiedSeconds", "modifiedNanos", "changedSeconds", "changedNanos",
  ]

  override func setUpWithError() throws {
    try? FileManager.default.removeItem(at: Self.root)
    try FileManager.default.createDirectory(
      at: Self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: Self.root)
  }

  // MARK: Fixture

  /// The registry `BootstrapToolRegistryContractTests.devecoRegistry` builds:
  /// fixed trust for the bundle and its children, the signed-resource
  /// envelope checked against the files, a fixed clock.
  private static func registry(_ timeline: String) -> BootstrapDevEcoToolchainRegistry {
    let inspect: (URL) throws -> BootstrapToolTrust = { url in
      if url.pathExtension == "app" {
        return BootstrapToolTrust(
          signature: "verified", identifier: "com.huawei.devecostudio.ds",
          teamIdentifier: "TZEA3TN37Q",
          codeDirectorySHA256: String(repeating: "a", count: 64))
      }
      return BootstrapToolTrust(
        signature: "verified", identifier: "node", teamIdentifier: "HX7739G8FX",
        codeDirectorySHA256: String(repeating: "b", count: 64))
    }
    return BootstrapDevEcoToolchainRegistry(
      owner: BootstrapBundleRegistry(root: registryRoot(timeline)),
      inspectTrust: inspect, inspectPublisherTrust: inspect,
      verifySignedResources: { contents, expected in
        for (relativePath, digest) in expected {
          guard
            SHA256Hex.string(of: try Data(contentsOf: contents.appending(path: relativePath)))
              == digest
          else { throw AgentExecutionControlFailure("fileIdentityChanged", "resource changed") }
        }
      },
      nowUTC: { "2026-09-01T00:00:00Z" })
  }

  private static func registryRoot(_ timeline: String) -> URL {
    root.appending(path: "\(timeline)/registry", directoryHint: .isDirectory)
  }

  /// `BootstrapToolRegistryContractTests.devecoFixture`'s Contents root.
  private static func contents(_ timeline: String) throws -> URL {
    let contents = root.appending(
      path: "\(timeline)/DevEco-Studio.app/Contents", directoryHint: .isDirectory)
    for relative in [
      "Resources", "sdk/default/openharmony", "tools/node/bin", "tools/hvigor/bin",
      "_CodeSignature",
    ] {
      try FileManager.default.createDirectory(
        at: contents.appending(path: relative, directoryHint: .isDirectory),
        withIntermediateDirectories: true)
    }
    try Data("""
      {"name":"DevEco Studio","version":"26.0.0.2","buildNumber":"26002",
       "productCode":"DS","productVendor":"Huawei",
       "launch":[{"os":"macOS","arch":"aarch64"}]}
      """.utf8).write(to: contents.appending(path: "Resources/product-info.json"))
    try Data("""
      {"data":{"apiVersion":"26","platformVersion":"26.0.0","version":"26.0.0.25"}}
      """.utf8).write(to: contents.appending(path: "sdk/default/sdk-pkg.json"))
    let node = contents.appending(path: "tools/node/bin/node")
    try Data("fixture native node".utf8).write(to: node)
    guard chmod(node.path, 0o755) == 0 else { throw POSIXError(.EPERM) }
    try Data("fixture hvigor".utf8).write(
      to: contents.appending(path: "tools/hvigor/bin/hvigorw.js"))
    try Data("fixture signed resource envelope".utf8).write(
      to: contents.appending(path: "_CodeSignature/CodeResources"))
    return contents
  }

  // MARK: Timelines

  private struct Step {
    var name: String
    var call: String
    var reference: String? = nil
    var expectedGeneration: String? = nil
    var owner: (kind: BootstrapBundleRegistry.ReferenceKind, id: String)? = nil
    var count: Int? = nil
  }

  private static func preset(_ id: String) -> (BootstrapBundleRegistry.ReferenceKind, String) {
    (.workspacePreset, id)
  }

  /// Each timeline's steps, run in order against its own registry.
  private static func timelines(reference: String) -> [(String, [Step])] {
    let unknown = "toolchain:sha256:" + String(repeating: "0", count: 64)
    return [
      (
        "life",
        [
          Step(name: "register", call: "register"),
          Step(
            name: "acquire-b", call: "acquire", reference: reference,
            expectedGeneration: "1", owner: preset("preset-b")),
          Step(
            name: "acquire-b-again", call: "acquire", reference: reference,
            expectedGeneration: "1", owner: preset("preset-b")),
          Step(
            name: "acquire-a", call: "acquire", reference: reference,
            expectedGeneration: "1", owner: preset("preset-a")),
          Step(
            name: "acquire-job", call: "acquire", reference: reference,
            expectedGeneration: "1", owner: (.job, "job-fixture")),
          Step(
            name: "acquire-stale-generation", call: "acquire", reference: reference,
            expectedGeneration: "2", owner: preset("preset-c")),
          Step(
            name: "acquire-unknown", call: "acquire", reference: unknown,
            expectedGeneration: "1", owner: preset("preset-c")),
          Step(
            name: "acquire-malformed", call: "acquire", reference: "toolchain:md5:abc",
            expectedGeneration: "1", owner: preset("preset-c")),
          Step(
            name: "remove-retained", call: "remove", reference: reference,
            expectedGeneration: "1"),
          Step(
            name: "resolve-a", call: "resolve", reference: reference, expectedGeneration: "1",
            owner: preset("preset-a")),
          Step(
            name: "resolve-unpinned", call: "resolve", reference: reference,
            expectedGeneration: "1", owner: preset("preset-z")),
          Step(name: "release-a", call: "release", reference: reference, owner: preset("preset-a")),
          Step(
            name: "release-a-again", call: "release", reference: reference,
            owner: preset("preset-a")),
          Step(name: "release-job", call: "release", reference: reference, owner: (.job, "job-fixture")),
          Step(name: "release-b", call: "release", reference: reference, owner: preset("preset-b")),
          Step(name: "remove", call: "remove", reference: reference, expectedGeneration: "1"),
          Step(
            name: "acquire-removed", call: "acquire", reference: reference,
            expectedGeneration: "1", owner: preset("preset-a")),
          Step(
            name: "release-removed", call: "release", reference: reference,
            owner: preset("preset-b")),
        ]
      ),
      (
        "drift",
        [
          Step(name: "register", call: "register"),
          Step(
            name: "acquire-a", call: "acquire", reference: reference, expectedGeneration: "1",
            owner: preset("preset-a")),
          Step(name: "change-hvigor", call: "changeHvigor"),
          Step(
            name: "acquire-b-changed", call: "acquire", reference: reference,
            expectedGeneration: "1", owner: preset("preset-b")),
          Step(
            name: "release-a-changed", call: "release", reference: reference,
            owner: preset("preset-a")),
        ]
      ),
      (
        "bound",
        [
          Step(name: "register", call: "register"),
          Step(name: "seed", call: "seedReferences", reference: reference, count: 1_023),
          Step(
            name: "acquire-at-bound", call: "acquire", reference: reference,
            expectedGeneration: "1", owner: preset("preset-1023")),
          Step(
            name: "acquire-over-bound", call: "acquire", reference: reference,
            expectedGeneration: "1", owner: preset("preset-1024")),
          Step(
            name: "acquire-held-at-bound", call: "acquire", reference: reference,
            expectedGeneration: "1", owner: preset("preset-0000")),
        ]
      ),
    ]
  }

  private static func owner(
    _ owner: (kind: BootstrapBundleRegistry.ReferenceKind, id: String)
  ) throws -> BootstrapBundleRegistry.ReferenceOwner {
    try BootstrapBundleRegistry.ReferenceOwner(kind: owner.kind, id: owner.id)
  }

  private static func resolution(
    _ resolved: BootstrapDevEcoToolchainRegistry.ResolvedToolchain
  ) -> JSONValue {
    .object([
      "toolchainRef": .string(resolved.toolchainRef),
      "generation": .string(String(resolved.generation)),
      "contentsRoot": .string(resolved.contentsRoot.path),
      "sdkRoot": .string(resolved.sdkRoot.path),
      "nodeExecutable": .string(resolved.nodeExecutable.path),
      "hvigorScript": .string(resolved.hvigorScript.path),
      "productVersion": .string(resolved.productVersion),
      "sdkVersion": .string(resolved.sdkVersion),
      "verifiedResources": .array(
        resolved.verifiedResources.map { resource in
          .object([
            "path": .string(resource.url.path), "sha256": .string(resource.sha256),
            "byteCount": .integer(Int64(resource.byteCount)),
            "requireExecutable": .bool(resource.requireExecutable),
          ])
        }),
    ])
  }

  /// One step's call, answered as a value, `null` or a refusal.
  private static func perform(
    _ step: Step, timeline: String, registry: BootstrapDevEcoToolchainRegistry
  ) throws -> (answer: JSONValue, error: JSONValue) {
    do {
      switch step.call {
      case "register":
        return (try registry.register(root: try contents(timeline)), .null)
      case "acquire":
        return (
          try registry.acquire(
            step.reference!, expectedGeneration: step.expectedGeneration!,
            owner: try owner(step.owner!)),
          .null
        )
      case "seedReferences":
        // Pins written straight into the index in its own canonical form:
        // publishing each through the owner syncs the file once per pin.
        let url = registryRoot(timeline).appending(path: "deveco-toolchains.json")
        guard
          case .object(var index) = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: url)),
          case .array(var records)? = index["records"],
          case .object(var record)? = records.first
        else { throw POSIXError(.EINVAL) }
        record["references"] = .array(
          (0..<step.count!).map {
            .object([
              "kind": .string("workspacePreset"), "id": .string(String(format: "preset-%04d", $0)),
            ])
          })
        records[0] = .object(record)
        index["records"] = .array(records)
        try canonical(.object(index)).write(to: url)
        return (.null, .null)
      case "release":
        try registry.release(step.reference!, owner: try owner(step.owner!))
        return (.null, .null)
      case "remove":
        return (
          try registry.remove(step.reference!, expectedGeneration: step.expectedGeneration!),
          .null
        )
      case "resolve":
        return (
          resolution(
            try registry.resolve(
              step.reference!, expectedGeneration: step.expectedGeneration!,
              owner: try owner(step.owner!))),
          .null
        )
      case "changeHvigor":
        try Data("changed hvigor".utf8).write(
          to: root.appending(
            path: "\(timeline)/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js"))
        return (.null, .null)
      default:
        throw POSIXError(.EINVAL)
      }
    } catch let failure as AgentExecutionControlFailure {
      return (.null, .object(["code": .string(failure.code), "message": .string(failure.message)]))
    }
  }

  private struct Played {
    var cases: JSONValue
    /// Index bytes by their SHA-256.
    var states: [String: Data]
  }

  /// Every timeline through the production registry: each step's inputs,
  /// answer and the index it left.
  private static func play() throws -> Played {
    // The reference is the content digest, identical for every timeline.
    let probe = registry("probe")
    guard case .object(let registered) = try probe.register(root: try contents("probe")),
      case .string(let reference)? = registered["toolRef"]
    else { throw POSIXError(.EINVAL) }
    var states: [String: Data] = [:]
    var timelines: [JSONValue] = []
    for (timeline, steps) in Self.timelines(reference: reference) {
      let registry = registry(timeline)
      var recorded: [JSONValue] = []
      for step in steps {
        let (answer, error) = try perform(step, timeline: timeline, registry: registry)
        let bytes = try Data(
          contentsOf: registryRoot(timeline).appending(path: "deveco-toolchains.json"))
        let digest = SHA256Hex.string(of: bytes)
        states[digest] = bytes
        var fields: [String: JSONValue] = [
          "name": .string(step.name), "call": .string(step.call),
          "answer": answer, "error": error, "state": .string(digest),
        ]
        if let reference = step.reference { fields["reference"] = .string(reference) }
        if let generation = step.expectedGeneration {
          fields["expectedGeneration"] = .string(generation)
        }
        if let owner = step.owner {
          fields["owner"] = .object(["kind": .string(owner.kind.rawValue), "id": .string(owner.id)])
        }
        if let count = step.count {
          fields["count"] = .integer(Int64(count))
          fields["owners"] = .string(
            "workspacePreset preset-0000 through " + String(format: "preset-%04d", count - 1))
        }
        recorded.append(.object(fields))
      }
      timelines.append(.object(["name": .string(timeline), "steps": .array(recorded)]))
    }
    return Played(
      cases: .object([
        "schemaVersion": .string("arkdeck.deveco-toolchain-pin-oracle/1"),
        "reference": .string(reference),
        "contentsRoot": .string(root.path + "/<timeline>/DevEco-Studio.app/Contents"),
        "timelines": .array(timelines),
      ]),
      states: states)
  }

  /// An index with every file identity set aside.
  private static func masked(_ state: Data) throws -> JSONValue {
    func strip(_ value: JSONValue) -> JSONValue {
      guard case .object(var fields) = value else { return value }
      for key in identityKeys { fields.removeValue(forKey: key) }
      return .object(fields)
    }
    guard case .object(var index) = try JSONDecoder().decode(JSONValue.self, from: state),
      case .array(let records)? = index["records"]
    else { throw POSIXError(.EINVAL) }
    index["records"] = .array(
      records.map { record in
        guard case .object(var fields) = record else { return record }
        if let root = fields["root"] { fields["root"] = strip(root) }
        if case .array(let children)? = fields["children"] {
          fields["children"] = .array(children.map(strip))
        }
        return .object(fields)
      })
    return .object(index)
  }

  private static func canonical(_ value: JSONValue) throws -> Data {
    try CanonicalJSONEncoders.canonical().encode(value)
  }

  func testTheProductionRegistryPinsReleasesAndRefusesAsRecorded() throws {
    let played = try Self.play()

    if let output = ProcessInfo.processInfo.environment[Self.recordVariable] {
      let directory = URL(filePath: output, directoryHint: .isDirectory)
      let statesDirectory = directory.appending(path: "states", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: statesDirectory, withIntermediateDirectories: true)
      var pinned: [String: JSONValue] = [:]
      let cases = try Self.canonical(played.cases)
      try cases.write(to: directory.appending(path: "cases.json"))
      pinned["cases.json"] = .string(SHA256Hex.string(of: cases))
      for (digest, bytes) in played.states {
        try bytes.write(to: statesDirectory.appending(path: "\(digest).json"))
        pinned["states/\(digest).json"] = .string(digest)
      }
      let provenance = try Self.canonical(
        .object([
          "recordedBy": .string(
            "DevEcoToolchainPinOracleContractTests.testTheProductionRegistryPinsReleasesAndRefusesAsRecorded"),
          "source": .string(
            "BootstrapDevEcoToolchainRegistry over a fabricated DevEco root with injected trust"),
          "files": .object(pinned),
        ]))
      try provenance.write(to: directory.appending(path: "provenance.json"))
      return
    }

    // 0. The checked-in oracle is exactly a recording: every file, and no
    // other, has the SHA-256 its provenance pins, and each index is its own
    // canonical bytes.
    guard
      case .object(let provenance) = try JSONDecoder().decode(
        JSONValue.self, from: Data(contentsOf: Self.oracle.appending(path: "provenance.json"))),
      case .object(let pinned)? = provenance["files"]
    else { return XCTFail("provenance.json pins no files") }
    let checkedIn = try FileManager.default.subpathsOfDirectory(atPath: Self.oracle.path)
      .filter { path in
        var directory: ObjCBool = false
        FileManager.default.fileExists(
          atPath: Self.oracle.appending(path: path).path, isDirectory: &directory)
        return !directory.boolValue && path != "provenance.json"
      }
    XCTAssertEqual(Set(checkedIn), Set(pinned.keys))
    for (path, digest) in pinned {
      let bytes = try Data(contentsOf: Self.oracle.appending(path: path))
      XCTAssertEqual(digest, .string(SHA256Hex.string(of: bytes)), path)
      if path.hasPrefix("states/") {
        XCTAssertEqual(
          try Self.canonical(JSONDecoder().decode(JSONValue.self, from: bytes)), bytes,
          "\(path) is not its own canonical bytes")
      }
    }

    // 1. Played again, every answer is the recorded one and every index the
    // recorded one once file identities are set aside.
    let recorded = try JSONDecoder().decode(
      JSONValue.self, from: Data(contentsOf: Self.oracle.appending(path: "cases.json")))
    guard case .object(let recordedFields) = recorded,
      case .object(let playedFields) = played.cases,
      case .array(let recordedTimelines)? = recordedFields["timelines"],
      case .array(let playedTimelines)? = playedFields["timelines"]
    else { return XCTFail("cases.json has no timelines") }
    XCTAssertEqual(recordedFields["reference"], playedFields["reference"])
    XCTAssertEqual(recordedTimelines.count, playedTimelines.count)
    for (recordedTimeline, playedTimeline) in zip(recordedTimelines, playedTimelines) {
      guard case .object(let recordedTimelineFields) = recordedTimeline,
        case .object(let playedTimelineFields) = playedTimeline,
        case .array(let recordedSteps)? = recordedTimelineFields["steps"],
        case .array(let playedSteps)? = playedTimelineFields["steps"]
      else { return XCTFail("a timeline has no steps") }
      XCTAssertEqual(recordedSteps.count, playedSteps.count)
      for (recordedStep, playedStep) in zip(recordedSteps, playedSteps) {
        guard case .object(var expected) = recordedStep, case .object(var actual) = playedStep,
          case .string(let expectedState)? = expected.removeValue(forKey: "state"),
          case .string(let actualState)? = actual.removeValue(forKey: "state")
        else { return XCTFail("a step has no state") }
        XCTAssertEqual(actual, expected, "\(expected["name"] ?? .null)")
        XCTAssertEqual(
          try Self.masked(played.states[actualState]!),
          try Self.masked(Data(contentsOf: Self.oracle.appending(path: "states/\(expectedState).json"))),
          "\(expected["name"] ?? .null)")
      }
    }
  }
}

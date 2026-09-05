import Foundation
import XCTest

@testable import ArkDeckCLI
@testable import ArkDeckCore

/// `TASK-XPA-001`: every control-plane method of the single current protocol
/// has one typed schema under `spec/control/methods/`, and the frames the
/// daemon really answered validate against it. The committed corpus is the
/// smallest frame of every request and response shape a contract-test run
/// recorded; a run with `ARKDECK_CONTROL_FRAME_LOG` set additionally validates
/// everything it just recorded, so a handler that starts emitting an
/// unpublished field fails here before a Rust reader generated from the schema
/// meets it.
final class ControlMethodSchemaContractTests: XCTestCase {
  private static let repositoryRoot: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url = url.deletingLastPathComponent() }
    return url
  }()
  private static let schemaDirectory =
    repositoryRoot.appending(path: CLIMachineContracts.controlMethodSchemaDirectory)
  private static let corpusDirectory = repositoryRoot.appending(
    path: "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames")
  private static let regenerate =
    "record a contract-test run with ARKDECK_CONTROL_FRAME_LOG=<dir> and run "
    + "`python3 Packages/ArkDeckKit/Scripts/generate-control-contract.py --derive-method-schemas <dir>`"

  private static let published = ArkDeckControlProtocol.methods

  private struct MethodSchema {
    let method: String
    let document: JSONValue
    let fields: [String: JSONValue]
    let definitions: [String: JSONValue]

    init(url: URL) throws {
      method = url.deletingPathExtension().lastPathComponent
      document = try JSONValueBridge.value(from: Data(contentsOf: url))
      guard case .object(let fields) = document, case .object(let definitions)? = fields["$defs"]
      else { throw NSError(domain: "ControlMethodSchema", code: 1) }
      self.fields = fields
      self.definitions = definitions
    }

    /// Validates one definition by name against the whole document, so `$ref`
    /// resolution keeps working.
    func validates(_ value: JSONValue, as definition: String) -> Bool {
      guard let target = definitions[definition] else { return false }
      return JSONSchemaSubset.validate(value, against: Self.scoped(target, in: document))
    }

    private static func scoped(_ definition: JSONValue, in document: JSONValue) -> JSONValue {
      // The validator resolves `#/$defs/...` against the root it is handed;
      // handing it the whole document with the definition merged at the top
      // keeps every reference valid.
      guard case .object(var root) = document, case .object(let target) = definition else {
        return definition
      }
      for key in ["type", "properties", "required", "additionalProperties", "items", "anyOf", "oneOf", "allOf", "enum", "const", "not", "$ref", "minimum", "maximum", "minLength", "pattern"] {
        root[key] = target[key]
      }
      return .object(root)
    }
  }

  private static func schemas() throws -> [String: MethodSchema] {
    let files = try FileManager.default.contentsOfDirectory(
      at: schemaDirectory, includingPropertiesForKeys: nil)
    var schemas: [String: MethodSchema] = [:]
    for url in files where url.pathExtension == "json" {
      let schema = try MethodSchema(url: url)
      schemas[schema.method] = schema
    }
    return schemas
  }

  private struct Frame {
    let method: String
    let protocolVersion: String
    let ok: Bool
    let params: JSONValue
    let result: JSONValue?
    let errorCode: String?
    let errorDetails: JSONValue?

    init?(line: Substring) {
      guard !line.isEmpty,
        case .object(let fields)? = try? JSONValueBridge.value(from: Data(line.utf8)),
        case .string(let method)? = fields["method"],
        case .string(let version)? = fields["protocolVersion"],
        case .bool(let ok)? = fields["ok"]
      else { return nil }
      self.method = method
      protocolVersion = version
      self.ok = ok
      params = fields["params"] ?? .object([:])
      result = fields["result"]
      if case .object(let error)? = fields["error"] {
        if case .string(let code)? = error["code"] { errorCode = code } else { errorCode = nil }
        errorDetails = error["details"]
      } else {
        errorCode = nil
        errorDetails = nil
      }
    }
  }

  private static func frames(in directory: URL) throws -> [(file: String, line: Int, frame: Frame)] {
    var frames: [(String, Int, Frame)] = []
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    where url.pathExtension == "jsonl" {
      let text = try String(contentsOf: url, encoding: .utf8)
      for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        guard !line.isEmpty else { continue }
        guard let frame = Frame(line: line) else {
          XCTFail("\(url.lastPathComponent):\(index + 1) is not a recorded control frame")
          continue
        }
        frames.append((url.lastPathComponent, index + 1, frame))
      }
    }
    return frames
  }

  /// Every failure one frame has against its schema, empty when it validates.
  private func failures(of frame: Frame, against schema: MethodSchema) -> [String] {
    var failures: [String] = []
    if !schema.validates(frame.params, as: "request") { failures.append("request parameters") }
    if frame.ok {
      if let result = frame.result, !schema.validates(result, as: "result") {
        failures.append("result")
      }
    } else {
      if let code = frame.errorCode, !schema.validates(.string(code), as: "errorCode") {
        failures.append("error code \(code)")
      }
      if let details = frame.errorDetails, !schema.validates(details, as: "errorDetails") {
        failures.append("error details")
      }
    }
    return failures
  }

  // MARK: - Tests

  func testEveryPublishedMethodHasExactlyOneTypedSchema() throws {
    let schemas = try Self.schemas()
    XCTAssertEqual(
      Set(schemas.keys), Self.published,
      "spec/control/methods must hold one schema per published method; \(Self.regenerate)")
    for (method, schema) in schemas {
      XCTAssertEqual(schema.fields["$schema"], .string("https://json-schema.org/draft/2020-12/schema"), method)
      XCTAssertEqual(schema.fields["title"], .string("arkdeck.control.method/\(method)"), method)
      XCTAssertEqual(schema.fields["x-arkdeck-method"], .string(method), method)
      XCTAssertEqual(
        schema.fields["x-arkdeck-protocolVersion"],
        .string(ArkDeckControlProtocol.currentVersion), method)
      XCTAssertEqual(
        schema.fields["x-arkdeck-contractIdentity"],
        .string(ArkDeckControlProtocol.contractIdentity),
        "\(method) was derived under another control contract; \(Self.regenerate)")
      for definition in ["request", "result", "errorCode", "errorDetails"] {
        XCTAssertNotNil(schema.definitions[definition], "\(method) lacks $defs.\(definition)")
      }
      guard case .object(let request)? = schema.definitions["request"] else {
        return XCTFail("\(method) request schema lost its shape")
      }
      XCTAssertEqual(request["type"], .string("object"), method)
      XCTAssertEqual(
        request["additionalProperties"], .bool(false),
        "\(method) publishes a closed parameter set")
    }
  }

  func testEveryRecordedFrameInTheCommittedCorpusValidatesAgainstItsSchema() throws {
    let schemas = try Self.schemas()
    let frames = try Self.frames(in: Self.corpusDirectory)
    XCTAssertFalse(frames.isEmpty, "the committed corpus is empty; \(Self.regenerate)")
    var covered: Set<String> = []
    for (file, line, frame) in frames {
      guard let schema = schemas[frame.method] else {
        XCTFail("\(file):\(line) records \(frame.method), which has no published schema")
        continue
      }
      XCTAssertEqual(file, "\(frame.method).jsonl", "\(file):\(line) is filed under the wrong method")
      XCTAssertEqual(
        frame.protocolVersion, ArkDeckControlProtocol.currentVersion,
        "\(file):\(line) was recorded on a version this Runtime does not speak")
      covered.insert(frame.method)
      let failures = failures(of: frame, against: schema)
      XCTAssertTrue(failures.isEmpty, "\(file):\(line) \(frame.method): \(failures.joined(separator: ", "))")
    }
    XCTAssertEqual(
      Self.published.subtracting(covered), [],
      "every published method needs at least one recorded frame; \(Self.regenerate)")
  }

  /// Results are closed to the fields the daemon emitted, so a Rust
  /// implementation that adds a field, or a Swift handler that starts
  /// emitting one nobody recorded, fails the contract rather than drifting.
  func testAnUnrecordedResultFieldIsRefused() throws {
    let schemas = try Self.schemas()
    let frames = try Self.frames(in: Self.corpusDirectory)
    var checked = 0
    for (_, _, frame) in frames where frame.ok {
      guard case .object(var result)? = frame.result, let schema = schemas[frame.method] else { continue }
      XCTAssertTrue(schema.validates(.object(result), as: "result"), frame.method)
      result["unrecordedField"] = .string("drift")
      XCTAssertFalse(schema.validates(.object(result), as: "result"), "\(frame.method) accepted an unrecorded result field")
      checked += 1
    }
    XCTAssertGreaterThan(checked, 20)
  }

  /// When the test run itself records frames, everything it recorded must
  /// validate: the corpus is a selection, the live recording is the proof.
  func testFramesRecordedByThisRunValidate() throws {
    guard let directory = ProcessInfo.processInfo.environment["ARKDECK_CONTROL_FRAME_LOG"],
      !directory.isEmpty, FileManager.default.fileExists(atPath: directory)
    else { throw XCTSkip("no ARKDECK_CONTROL_FRAME_LOG directory for this run") }
    let schemas = try Self.schemas()
    var validated = 0
    for (file, line, frame) in try Self.frames(in: URL(fileURLWithPath: directory, isDirectory: true)) {
      guard let schema = schemas[frame.method] else { continue }
      let failures = failures(of: frame, against: schema)
      XCTAssertTrue(failures.isEmpty, "\(file):\(line) \(frame.method): \(failures.joined(separator: ", "))")
      validated += 1
    }
    XCTAssertGreaterThan(validated, 0)
  }
}

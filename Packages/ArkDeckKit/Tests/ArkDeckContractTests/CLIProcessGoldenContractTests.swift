import Foundation
import XCTest

/// §15.2's process-level conformance: the contract as a *process*.
///
/// Every other CLI test calls the parser in-process, which cannot see the three
/// things a caller actually depends on — the exit status the shell reads, which
/// stream each byte went to, and how many documents landed on stdout. A parser
/// that returns the right error value and a binary that prints it to the wrong
/// stream are indistinguishable from inside.
///
/// Every case here is deterministic without a daemon. Cases that would connect
/// point `--socket` at a path that cannot exist, so the answer is the same on a
/// developer machine with a Runtime installed and on a CI runner without one —
/// a golden that passes only where a daemon happens to be running is a golden
/// that proves nothing.
final class CLIProcessGoldenContractTests: XCTestCase {

  private struct Run {
    let exitCode: Int32
    let stdout: String
    let stderr: String
  }

  /// The built `arkdeck`, beside the test bundle that `swift test` produced.
  private func binary() throws -> URL {
    let bundle = Bundle(for: type(of: self)).bundleURL.deletingLastPathComponent()
    let candidate = bundle.appending(path: "arkdeck")
    // Never skipped when absent: a golden suite that quietly does nothing is
    // the failure mode it exists to prevent. `swift test` builds this binary
    // because the contract tests import the CLI target, so a missing one is a
    // broken build rather than an environment this suite should tolerate.
    guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
      throw NSError(
        domain: "ArkDeckCLIProcessGolden", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "no built arkdeck beside the test bundle at \(candidate.path)"
        ])
    }
    return candidate
  }

  private func run(_ argv: [String], file: StaticString = #filePath, line: UInt = #line) throws
    -> Run
  {
    let process = Process()
    process.executableURL = try binary()
    process.arguments = argv
    // A stray socket override in the environment would make these answers
    // depend on the machine.
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "ARKDECK_SOCKET")
    process.environment = environment
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Run(
      exitCode: process.terminationStatus,
      stdout: String(decoding: outData, as: UTF8.self),
      stderr: String(decoding: errData, as: UTF8.self))
  }

  /// How many complete JSON documents are on stdout. §8.1 allows exactly one
  /// in a machine mode, and counting is the only way to catch a second one.
  ///
  /// A document has to both balance *and* parse: a completion script balances
  /// nothing and must count as zero, not as one badly-formed document.
  private func jsonDocumentCount(_ text: String) -> Int {
    var remaining = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
    var count = 0
    while let end = firstBalancedValueEnd(in: remaining) {
      let candidate = String(remaining[..<end])
      guard let data = candidate.data(using: .utf8),
        (try? JSONSerialization.jsonObject(with: data)) != nil
      else { return count }
      count += 1
      remaining = remaining[end...].drop { $0.isWhitespace }
    }
    return count
  }

  /// The end index of the first balanced `{…}` or `[…]`, or nil when the text
  /// does not begin with one.
  private func firstBalancedValueEnd(in text: Substring) -> String.Index? {
    guard let first = text.first, first == "{" || first == "[" else { return nil }
    var depth = 0
    var inString = false
    var escaped = false
    for position in text.indices {
      let character = text[position]
      if escaped {
        escaped = false
        continue
      }
      if inString {
        if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
        }
        continue
      }
      switch character {
      case "\"": inString = true
      case "{", "[": depth += 1
      case "}", "]":
        depth -= 1
        if depth == 0 { return text.index(after: position) }
      default: break
      }
    }
    return nil
  }

  private func decoded(_ text: String) throws -> [String: Any] {
    let data = try XCTUnwrap(text.data(using: .utf8))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  /// The instrument before the measurement. Every assertion below about "one
  /// document" is only as good as this counter, and a counter that cannot tell
  /// two from one would have passed the defect this suite exists to catch — a
  /// result envelope followed by an error envelope.
  func testTheDocumentCounterIsTrustworthy() {
    XCTAssertEqual(jsonDocumentCount("{\"a\":1}"), 1)
    XCTAssertEqual(jsonDocumentCount("{\"a\":1}\n"), 1)
    XCTAssertEqual(jsonDocumentCount("{\"a\":1}\n{\"b\":2}\n"), 2)
    XCTAssertEqual(jsonDocumentCount("[1,2]\n[3]\n"), 2)
    // Braces inside strings must not close a document early.
    XCTAssertEqual(jsonDocumentCount("{\"a\":\"}{\"}"), 1)
    XCTAssertEqual(jsonDocumentCount("{\"a\":\"\\\\\"}"), 1)
    // Not JSON at all.
    XCTAssertEqual(jsonDocumentCount("#!/bin/sh\ncomplete -F _arkdeck arkdeck\n"), 0)
    XCTAssertEqual(jsonDocumentCount(""), 0)
    // Balanced but unparseable is not a document.
    XCTAssertEqual(jsonDocumentCount("{not json}"), 0)
  }

  // MARK: Help and discovery exit zero and stay on stdout

  func testHelpAndVersionExitZeroWithNothingOnStandardError() throws {
    for argv in [[], ["--help"], ["-h"], ["--version"], ["help", "job", "status"]] {
      let result = try run(argv)
      XCTAssertEqual(result.exitCode, 0, "`\(argv.joined(separator: " "))`")
      XCTAssertFalse(result.stdout.isEmpty, "`\(argv.joined(separator: " "))` printed nothing")
      XCTAssertTrue(
        result.stderr.isEmpty,
        "`\(argv.joined(separator: " "))` wrote to stderr: \(result.stderr)")
    }
  }

  func testVersionInJsonIsOneDocumentCarryingEveryContract() throws {
    let result = try run(["--version", "--output", "json"])
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(jsonDocumentCount(result.stdout), 1)
    let envelope = try decoded(result.stdout)
    XCTAssertEqual(envelope["schemaVersion"] as? String, "arkdeck.cli.result/1")
    XCTAssertEqual(envelope["ok"] as? Bool, true)
    let payload = try XCTUnwrap(envelope["result"] as? [String: Any])
    for key in [
      "cliProductVersion", "commandRegistrySchemaVersion", "preferredControlProtocolVersion",
      "supportedControlProtocolExactVersions", "machineContractVersion", "resultSchemaVersion",
      "pageSchemaVersion", "eventSchemaVersion", "nextActionSchemaVersion",
      "errorRegistryVersion", "canonicalJsonVersion", "buildIdentity",
    ] {
      XCTAssertNotNil(payload[key], "§12 requires \(key)")
    }
  }

  func testTheRegistryProjectionIsOneDocument() throws {
    let result = try run(["commands", "--output", "json"])
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(jsonDocumentCount(result.stdout), 1)
    let payload = try XCTUnwrap(try decoded(result.stdout)["result"] as? [String: Any])
    XCTAssertNotNil(payload["commandRegistrySchemaVersion"])
    XCTAssertNotNil(payload["commands"])
  }

  /// §8.1: a completion script is script bytes on stdout and nothing else.
  func testCompletionIsScriptBytesOnly() throws {
    for shell in ["bash", "zsh", "fish", "powershell"] {
      let result = try run(["completion", shell])
      XCTAssertEqual(result.exitCode, 0, shell)
      XCTAssertTrue(result.stdout.hasPrefix("#"), "\(shell) must start with a comment")
      XCTAssertTrue(result.stderr.isEmpty, shell)
      XCTAssertEqual(jsonDocumentCount(result.stdout), 0, "\(shell) must not be JSON")
    }
  }

  // MARK: Failures carry the right status on the right stream

  func testAHumanFailureWritesNothingToStandardOut() throws {
    for (argv, expected) in [
      (["bogus"], Int32(64)),
      (["job"], Int32(64)),
      (["job", "status"], Int32(64)),
      (["job", "status", "--job", "A", "--job", "B"], Int32(64)),
      (["job", "list", "--page-size", "0"], Int32(64)),
      (["capability", "draft"], Int32(64)),
      (["flash", "execute"], Int32(64)),
      (["completion", "tcsh"], Int32(64)),
    ] {
      let result = try run(argv)
      XCTAssertEqual(result.exitCode, expected, "`\(argv.joined(separator: " "))`")
      XCTAssertTrue(
        result.stdout.isEmpty,
        "`\(argv.joined(separator: " "))` put a failure on stdout: \(result.stdout)")
      XCTAssertFalse(result.stderr.isEmpty, "`\(argv.joined(separator: " "))` said nothing")
    }
  }

  /// §8.1: a caller that asked for JSON gets the refusal in JSON, on stdout,
  /// even when the command path never resolved.
  func testAnArgvFailureInJsonIsOneEnvelopeOnStandardOut() throws {
    let result = try run(["bogus", "--output", "json"])
    XCTAssertEqual(result.exitCode, 64)
    XCTAssertEqual(jsonDocumentCount(result.stdout), 1)
    XCTAssertTrue(result.stderr.isEmpty, result.stderr)
    let envelope = try decoded(result.stdout)
    XCTAssertEqual(envelope["ok"] as? Bool, false)
    XCTAssertEqual(envelope["command"] as? String, "registry.parse")
    let error = try XCTUnwrap(envelope["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, "invalidCommand")
  }

  /// §12 fixes the shape of a removed token's answer, and an agent branches on
  /// these exact keys.
  func testARetiredCommandAnswersWithTheLifecycleContract() throws {
    let result = try run(["flash", "execute", "--output", "json"])
    XCTAssertEqual(result.exitCode, 64)
    XCTAssertEqual(jsonDocumentCount(result.stdout), 1)
    let error = try XCTUnwrap(try decoded(result.stdout)["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, "commandRemoved")
    let details = try XCTUnwrap(error["details"] as? [String: Any])
    XCTAssertEqual(details["lifecycleStatus"] as? String, "removed")
    XCTAssertEqual(
      details["replacementArgvPattern"] as? String,
      "arkdeck agent run --operation flash.full-restore@1 ...")
  }

  // MARK: The transport answer is the same everywhere

  /// A socket that cannot exist gives every machine the same answer, which is
  /// what makes this assertable at all. §8.4: nothing left the process, so it
  /// is `runtimeUnavailable` rather than an unknown outcome — even for a
  /// mutation-capable method.
  func testAnUnreachableRuntimeIsUnavailableRatherThanUnknown() throws {
    for argv in [
      ["job", "status", "--job", "J-1"],
      ["job", "run", "--job", "J-1"],
      ["target", "list"],
    ] {
      let result = try run(argv + ["--socket", "/nonexistent/arkdeck-golden.sock",
        "--output", "json"])
      XCTAssertEqual(result.exitCode, 69, "`\(argv.joined(separator: " "))`")
      XCTAssertEqual(jsonDocumentCount(result.stdout), 1)
      let error = try XCTUnwrap(try decoded(result.stdout)["error"] as? [String: Any])
      XCTAssertEqual(error["code"] as? String, "runtimeUnavailable")
      XCTAssertEqual(error["controlRequestRetryable"] as? Bool, true)
    }
  }

  /// §12 keeps `--json` in its own shape: JSON, but not the envelope.
  func testLegacyJsonAnswersFailuresWithoutTheEnvelope() throws {
    let result = try run([
      "job", "status", "--job", "J-1", "--socket", "/nonexistent/arkdeck-golden.sock", "--json",
    ])
    XCTAssertEqual(result.exitCode, 69)
    XCTAssertEqual(jsonDocumentCount(result.stdout), 1)
    let document = try decoded(result.stdout)
    XCTAssertNil(document["schemaVersion"], "legacy-json is not the versioned envelope")
    XCTAssertNil(document["meta"])
    let error = try XCTUnwrap(document["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, "runtimeUnavailable")
  }

  /// §18 requires JSON conformance across the surface, and these leaves used
  /// to answer only in prose — so `--output json` had to be refused on them,
  /// which is a hole in the contract rather than a property of the commands.
  func testTheFlashArchiveLeavesAnswerInMachineForm() throws {
    let result = try run(["flash", "reconcile", "--output", "json"])
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(jsonDocumentCount(result.stdout), 1)
    let payload = try XCTUnwrap(try decoded(result.stdout)["result"] as? [String: Any])
    // The same shape whether or not there is anything to report: a caller that
    // has to branch on "did it print the empty sentence" is parsing prose.
    XCTAssertNotNil(payload["findings"])
    XCTAssertNotNil(payload["orphanedReservations"])
    XCTAssertNotNil(payload["requiresAttention"])

    // §12 marks these as legacy compatibility leaves, and a caller has to be
    // able to see that without reading the source.
    let meta = try XCTUnwrap(try decoded(result.stdout)["meta"] as? [String: Any])
    let lifecycle = try XCTUnwrap(meta["lifecycle"] as? [String: Any])
    XCTAssertEqual(lifecycle["status"] as? String, "legacy")
  }

  /// A leaf whose success is JSON and whose failure is prose on stderr is only
  /// half migrated. The archive publishes exactly three failures, so all three
  /// carry a §8.4 code.
  func testAMissingCampaignFailsInTheShapeTheCallerAskedFor() throws {
    let result = try run([
      "flash", "status", "--campaign-id", "ECAMP-does-not-exist", "--output", "json",
    ])
    XCTAssertEqual(result.exitCode, 65)
    XCTAssertEqual(jsonDocumentCount(result.stdout), 1)
    let error = try XCTUnwrap(try decoded(result.stdout)["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, "resourceNotFound")

    let human = try run(["flash", "status", "--campaign-id", "ECAMP-does-not-exist"])
    XCTAssertEqual(human.exitCode, 65)
    XCTAssertTrue(human.stdout.isEmpty)
    XCTAssertFalse(human.stderr.isEmpty)
  }

  /// Only the two surfaces §8.1 exempts may refuse a machine mode: help is
  /// prose and a completion script is script bytes. Anything else refusing it
  /// is a gap, and this is what makes the remaining ones visible.
  func testOnlyHelpAndCompletionRefuseAMachineMode() throws {
    let result = try run(["commands", "--output", "json"])
    let payload = try XCTUnwrap(try decoded(result.stdout)["result"] as? [String: Any])
    let commands = try XCTUnwrap(payload["commands"] as? [[String: Any]])
    let withoutJSON = commands
      .filter { ($0["kind"] as? String) == "executable" }
      .filter { !(($0["outputModes"] as? [String] ?? []).contains("json")) }
      .map { ($0["path"] as? [String] ?? []).joined(separator: " ") }
      .sorted()
    XCTAssertEqual(
      withoutJSON,
      ["completion", "help", "update-feed assemble", "update-feed prepare"],
      "a leaf that cannot answer in JSON is a §18 conformance gap; `update-feed` is the "
        + "remaining one and needs a structured result before it can be closed")
  }

  func testTheTwoMachineSpellingsCannotBeCombined() throws {
    let result = try run(["operation", "list", "--output", "json", "--json"])
    XCTAssertEqual(result.exitCode, 64)
    let error = try XCTUnwrap(try decoded(result.stdout)["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, "invalidOption")
  }
}

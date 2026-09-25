// Shared Swift oracle for the pinned `xcode-select` tool shim (TASK-XPA-015):
// what the Runtime pins for `/usr/bin/git`, and what that runs, launched from
// its inode as the Runtime launches what it pinned, once clang and then make
// have last started by name — clang's refusal and the Makefile's marks before
// the fix, git's checkpoint object after it.
//
// Only the product's own pinning (`WorkspaceExecutableIdentity.hashing`) is
// exercised. The launch, the signing identifier (`codesign`) and xcrun's
// answer are this test's own, so the one file records the Runtime before and
// after the fix. Paths that differ between hosts are named, not spelled:
// `<xcrun --find git>` for the tool xcrun resolves, `<root>` for the project.
// Record with `ARKDECK_RUST_TOOL_SHIM_RECORD=/private/tmp/<new directory>`;
// the Rust port replays `after.json`.

import Darwin
import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class XcodeToolShimOracleContractTests: XCTestCase {
  private static let recordVariable = "ARKDECK_RUST_TOOL_SHIM_RECORD"

  func testWhatThePinnedGitRunsIsRecorded() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-tool-shim-oracle", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString.prefix(8).lowercased(), directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root.appending(path: "Sources", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("stash create:\n\t@touch ran-make-$@\n".utf8)
      .write(to: root.appending(path: "Makefile"))
    try Data("a\n".utf8).write(to: root.appending(path: "Sources/App.txt"))
    for arguments in [["init", "--quiet"], ["add", "-A"], ["commit", "--quiet", "-m", "base"]] {
      XCTAssertEqual(try Self.host("/usr/bin/git", ["-C", root.path] + arguments).status, 0)
    }
    try Data("a\nb\n".utf8).write(to: root.appending(path: "Sources/App.txt"))

    let pinned = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/git").path
    let resolved = try Self.host("/usr/bin/xcrun", ["--find", "git"], environment: [:]).stdout
      .trimmingCharacters(in: .newlines)
    var launches: [[String: Any]] = []
    for (primed, banner) in [("/usr/bin/clang", "clang version"), ("/usr/bin/make", "GNU Make")] {
      // Started by name until the shim itself, from its inode, runs it. Any
      // process on the host that starts one of the shim's names moves that
      // name, so the shim is primed as far as it will go, never required to
      // hold: what the fix pins runs git whichever name it is.
      var shimRunsIt = false
      for _ in 0..<20 where !shimRunsIt {
        _ = try Self.host(primed, ["--version"])
        shimRunsIt = try Self.launched("/usr/bin/git", ["--version"], in: root).stdout
          .contains(banner)
      }
      let ran = try Self.launched(pinned, ["-C", root.path, "stash", "create"], in: root)
      let object = ran.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      launches.append([
        "primed": primed,
        "exitStatus": ran.status,
        "checkpointObject": object.count == 40 && object.allSatisfy(\.isHexDigit),
        "stderr": ran.stderr.replacingOccurrences(of: root.path, with: "<root>"),
        "marks": ["ran-make-stash", "ran-make-create"].filter {
          FileManager.default.fileExists(atPath: root.appending(path: $0).path)
        },
      ])
    }
    let document: [String: Any] = [
      "schemaVersion": "arkdeck.xcode-tool-shim-oracle/1",
      "requested": "/usr/bin/git",
      "pinned": pinned == resolved ? "<xcrun --find git>" : pinned,
      "pinnedSigningIdentifier": try Self.signingIdentifier(pinned),
      "launches": launches,
    ]
    let bytes = try JSONSerialization.data(
      withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    if let output = ProcessInfo.processInfo.environment[Self.recordVariable] {
      try (bytes + Data("\n".utf8)).write(to: URL(filePath: output).appending(path: "oracle.json"))
    }
    // What the fix holds: git, whichever tool last started, and no mark.
    XCTAssertEqual(document["pinned"] as? String, "<xcrun --find git>")
    for launch in launches {
      XCTAssertEqual(launch["exitStatus"] as? Int32, 0, "\(launch)")
      XCTAssertEqual(launch["checkpointObject"] as? Bool, true, "\(launch)")
      XCTAssertEqual(launch["marks"] as? [String], [], "\(launch)")
    }
  }

  /// The identifier `codesign` reads from the file's signature.
  private static func signingIdentifier(_ path: String) throws -> String {
    let shown = try host("/usr/bin/codesign", ["-dv", path])
    let line = (shown.stdout + shown.stderr).split(separator: "\n")
      .first { $0.hasPrefix("Identifier=") }
    return try XCTUnwrap(line).dropFirst("Identifier=".count).description
  }

  /// A host tool started by name, as a build would start it.
  private static func host(
    _ program: String, _ arguments: [String],
    environment: [String: String] = [
      "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_AUTHOR_NAME": "Oracle", "GIT_AUTHOR_EMAIL": "oracle@invalid.example",
      "GIT_COMMITTER_NAME": "Oracle", "GIT_COMMITTER_EMAIL": "oracle@invalid.example",
    ]
  ) throws -> (status: Int32, stdout: String, stderr: String) {
    try run(URL(filePath: program), arguments, environment: environment, in: nil)
  }

  /// `executable` started from its inode (`/.vol/<device>/<inode>`), as the
  /// Runtime starts what it pinned.
  private static func launched(
    _ executable: String, _ arguments: [String], in directory: URL
  ) throws -> (status: Int32, stdout: String, stderr: String) {
    var information = stat()
    guard stat(executable, &information) == 0 else { throw CocoaError(.fileNoSuchFile) }
    return try run(
      URL(filePath: "/.vol/\(UInt32(bitPattern: information.st_dev))/\(information.st_ino)"),
      arguments, environment: ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"],
      in: directory)
  }

  private static func run(
    _ executable: URL, _ arguments: [String], environment: [String: String], in directory: URL?
  ) throws -> (status: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    if let directory { process.currentDirectoryURL = directory }
    process.standardInput = FileHandle.nullDevice
    let (stdout, stderr) = (Pipe(), Pipe())
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let errors = stderr.fileHandleForReading.readDataToEndOfFile()
    while process.isRunning { usleep(5_000) }
    return (
      process.terminationStatus, String(decoding: output, as: UTF8.self),
      String(decoding: errors, as: UTF8.self)
    )
  }
}

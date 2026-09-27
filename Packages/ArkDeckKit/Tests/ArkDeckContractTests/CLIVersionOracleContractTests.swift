import CryptoKit
import Foundation
import XCTest

/// Execute Swift's real CLI so the Rust fixture cannot invent version semantics.
final class CLIVersionOracleContractTests: XCTestCase {
  func testActualSwiftVersionOutputAndArgumentPrecedence() throws {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf:
      repository.appending(path: "rust/tests/fixtures/cli-version/cases.json"))) as! [String: Any]
    let executable = Bundle(for: Self.self).bundleURL
      .deletingLastPathComponent().appending(path: "arkdeck")
    let digest = SHA256.hash(data: try Data(contentsOf: executable))
      .map { String(format: "%02x", $0) }.joined()
    let identity = "sha256:" + digest
    for item in fixture["runs"] as! [[String: Any]] {
      let argv = item["argv"] as! [String]
      let process = Process()
      process.executableURL = executable
      process.arguments = argv
      let stdout = Pipe()
      let stderr = Pipe()
      process.standardOutput = stdout
      process.standardError = stderr
      try process.run()
      let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      process.waitUntilExit()
      XCTAssertEqual(Int(process.terminationStatus), item["exitCode"] as? Int, "\(argv)")
      if (item["stdout"] as! String).contains("sha256:<executable>") {
        XCTAssertTrue(out.contains(identity), "version must hash this executable: \(argv)")
      }
      func label(_ text: String) -> String {
        text.replacingOccurrences(of: identity, with: "sha256:<executable>")
          .replacingOccurrences(
            of: #"ctl-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#,
            with: "ctl-<uuid>", options: .regularExpression)
      }
      XCTAssertEqual(label(out), item["stdout"] as? String, "stdout: \(argv)")
      XCTAssertEqual(label(err), item["stderr"] as? String, "stderr: \(argv)")
    }
  }
}

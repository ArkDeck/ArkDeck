import Foundation
import XCTest

/// Byte-for-byte comparison of files a test produces with a checked-in oracle
/// directory. Kept from the retired HDC oracle harness when the Swift Runtime
/// was deleted (CHG-2026-074): the ClientKit oracles still use it.
enum OracleFiles {
  /// Writes a new oracle when `variable` names a new directory under
  /// `/private/tmp`; otherwise the checked-in oracle must match byte for byte.
  static func recordOrCompare(_ files: [String: Data], variable: String, oracle: URL) throws {
    if let output = ProcessInfo.processInfo.environment[variable] {
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
    let recorded = try FileManager.default.subpathsOfDirectory(atPath: oracle.path)
      .filter { path in
        var directory: ObjCBool = false
        FileManager.default.fileExists(
          atPath: oracle.appending(path: path).path, isDirectory: &directory)
        return !directory.boolValue
      }
    let produced = Set(files.keys)
    XCTAssertEqual(
      Set(recorded), produced,
      "recorded only: \(Set(recorded).subtracting(produced).sorted()); "
        + "produced only: \(produced.subtracting(recorded).sorted())")
    for (path, data) in files.sorted(by: { $0.key < $1.key }) {
      let expected = try Data(contentsOf: oracle.appending(path: path))
      XCTAssertEqual(expected, data, "\(path)\(firstDifference(recorded: expected, produced: data))")
    }
  }

  /// Where two files first differ and what surrounds it, so that a mismatch of
  /// two files of the same size names the value rather than the size.
  static func firstDifference(recorded: Data, produced: Data) -> String {
    guard recorded != produced else { return "" }
    let index =
      zip(recorded, produced).enumerated().first { $0.element.0 != $0.element.1 }?.offset
      ?? min(recorded.count, produced.count)
    func excerpt(_ data: Data) -> String {
      let lower = max(0, index - 60)
      let upper = min(data.count, index + 60)
      let text = String(decoding: data.subdata(in: lower..<upper), as: UTF8.self)
      return text.replacingOccurrences(of: "\n", with: "⏎")
    }
    return " differs at byte \(index) of \(recorded.count)/\(produced.count): recorded «"
      + excerpt(recorded) + "» produced «" + excerpt(produced) + "»"
  }
}

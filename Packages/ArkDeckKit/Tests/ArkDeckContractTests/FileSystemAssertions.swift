import Darwin
import Foundation
import XCTest

/// Asserts file-system identity rather than URL spelling.
///
/// macOS exposes aliases such as `/tmp` and `/private/tmp` for the same item,
/// and Foundation's path normalization is not a stable identity boundary
/// across OS and toolchain versions. Use this when a contract cares that two
/// existing URLs reach the same file or directory. Keep string equality for
/// contracts that intentionally pin a serialized or user-visible path.
func XCTAssertSameFileSystemItem(
  _ lhs: URL,
  _ rhs: URL,
  _ message: @autoclosure () -> String = "",
  file: StaticString = #filePath,
  line: UInt = #line
) {
  var lhsMetadata = stat()
  guard stat(lhs.path, &lhsMetadata) == 0 else {
    XCTFail("could not stat expected file-system item at \(lhs.path)", file: file, line: line)
    return
  }

  var rhsMetadata = stat()
  guard stat(rhs.path, &rhsMetadata) == 0 else {
    XCTFail("could not stat actual file-system item at \(rhs.path)", file: file, line: line)
    return
  }

  let context = message()
  let contextSuffix = context.isEmpty ? "" : ": \(context)"
  XCTAssertTrue(
    lhsMetadata.st_dev == rhsMetadata.st_dev && lhsMetadata.st_ino == rhsMetadata.st_ino,
    "expected the same file-system item, but \(lhs.path) and \(rhs.path) have different "
      + "device/inode identities\(contextSuffix)",
    file: file,
    line: line)
}

final class FileSystemAssertionsContractTests: XCTestCase {
  func testTmpAliasUsesFileIdentityInsteadOfAbsolutePathSpelling() {
    let alias = URL(filePath: "/tmp", directoryHint: .isDirectory)
    let physical = URL(filePath: "/private/tmp", directoryHint: .isDirectory)

    XCTAssertNotEqual(alias.path, physical.path, "the regression requires two path spellings")
    XCTAssertSameFileSystemItem(
      alias,
      physical,
      "macOS /tmp and /private/tmp must compare by identity rather than by string")
  }
}

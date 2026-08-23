import XCTest

@testable import ArkDeckCLI

/// Native Artifact export and import are one headless product path.
///
/// `artifact export` prefixes the recorded name with `ART-<identity>-` so it
/// never overwrites an unrelated file. `artifact import-native-library` used
/// to reject that output because its basename no longer began with `lib`,
/// forcing an otherwise CLI-only GJ-3 run to stop for a manual rename.
final class NativeLibraryArtifactCLIContractTests: XCTestCase {
  private let artifactID = "ART-0123456789abcdef0123456789abcdef"

  func testDirectNativeLibraryNameStaysUnchanged() throws {
    XCTAssertEqual(
      try RuntimeCLI.canonicalNativeLibraryImportName("libarkdeck_gj.so"),
      "libarkdeck_gj.so")
  }

  func testArtifactExportNameRoundTripsToRecordedLogicalName() throws {
    XCTAssertEqual(
      try RuntimeCLI.canonicalNativeLibraryImportName(
        "\(artifactID)-libarkdeck_gj.so"),
      "libarkdeck_gj.so")
  }

  func testExportPrefixDoesNotConsumeTheLogicalNameLengthBudget() throws {
    let logicalName = "lib" + String(repeating: "a", count: 122) + ".so"
    XCTAssertEqual(logicalName.count, 128)
    XCTAssertEqual(
      try RuntimeCLI.canonicalNativeLibraryImportName("\(artifactID)-\(logicalName)"),
      logicalName)
  }

  func testNearMatchArtifactPrefixesAndUnsafeSuffixesStayRejected() {
    for name in [
      "ART-0123456789abcdef-libarkdeck_gj.so",
      "ART-0123456789ABCDEF0123456789ABCDEF-libarkdeck_gj.so",
      "ART-0123456789abcdef0123456789abcdef-not-a-library.so",
      "ART-0123456789abcdef0123456789abcdef-libbad/name.so",
      "ART-0123456789abcdef0123456789abcdef-libbad.so.txt",
    ] {
      XCTAssertThrowsError(
        try RuntimeCLI.canonicalNativeLibraryImportName(name),
        "must reject \(name)")
    }
  }
}

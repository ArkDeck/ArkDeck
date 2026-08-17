// The install readback keeps what the device said about the libraries.
//
// The fixtures are trimmed from a `bm dump -n com.example.waterflowdemo` taken
// off a DAYU 200 running OpenHarmony 7.0.0.37, where a correctly packaged and
// signed `.so` could not be loaded. The three fields below are what said why,
// and the readback used to discard all of them.

import XCTest

@testable import ArkDeckWorkflows

final class InstallReadbackFactsContractTests: XCTestCase {
  /// The shape of a real dump: a `<bundle>:` line, then the document.
  private func dump(nativeLibraryPath: String, cpuAbi: String, fileNames: String) -> String {
    """
    com.example.waterflowdemo:
    {
        "applicationInfo": {
            "bundleName": "com.example.waterflowdemo",
            "cpuAbi": "\(cpuAbi)",
            "nativeLibraryPath": "\(nativeLibraryPath)"
        },
        "hapModuleInfos": [
            { "moduleName": "entry", "nativeLibraryFileNames": \(fileNames) }
        ]
    }
    """
  }

  /// The device that could not load anything. Every value is empty, and empty
  /// is the answer — a readback that omitted these fields would look the same
  /// as one from a device that loaded the libraries fine.
  func testADeviceThatTookNoLibraryIsRecordedAsHavingTakenNone() {
    var summary: [String: String] = [:]
    HDCObservationProviderAdapter.appendNativeLibraryFacts(
      from: dump(nativeLibraryPath: "", cpuAbi: "", fileNames: "[]"), to: &summary)
    XCTAssertEqual(summary["nativeLibraryPath"], "")
    XCTAssertEqual(summary["cpuAbi"], "")
    XCTAssertEqual(summary["nativeLibraryFileCount"], "0")
  }

  func testADeviceThatTookTheLibrariesRecordsWhereTheyLanded() {
    var summary: [String: String] = [:]
    HDCObservationProviderAdapter.appendNativeLibraryFacts(
      from: dump(
        nativeLibraryPath: "libs/arm64", cpuAbi: "arm64-v8a",
        fileNames: "[\"libcrashprobe.so\", \"libc++_shared.so\"]"),
      to: &summary)
    XCTAssertEqual(summary["nativeLibraryPath"], "libs/arm64")
    XCTAssertEqual(summary["cpuAbi"], "arm64-v8a")
    XCTAssertEqual(summary["nativeLibraryFileCount"], "2")
  }

  /// Counted across every module, because a multi-module application can ship
  /// libraries in more than one of them.
  func testLibrariesAreCountedAcrossEveryModule() {
    let text = """
      com.example.demo:
      {
          "applicationInfo": { "cpuAbi": "arm64-v8a", "nativeLibraryPath": "libs/arm64" },
          "hapModuleInfos": [
              { "moduleName": "entry", "nativeLibraryFileNames": ["a.so"] },
              { "moduleName": "feature1", "nativeLibraryFileNames": ["b.so", "c.so"] }
          ]
      }
      """
    var summary: [String: String] = [:]
    HDCObservationProviderAdapter.appendNativeLibraryFacts(from: text, to: &summary)
    XCTAssertEqual(summary["nativeLibraryFileCount"], "3")
  }

  /// Parsing is an addition, not a new gate. A dump this cannot decode leaves
  /// the summary exactly as the install verdict built it, so a firmware that
  /// changes the format cannot turn a successful install into a failure.
  func testAnUndecodableDumpAddsNothingAndRemovesNothing() {
    for text in ["com.example.demo:\nnot json at all", "", "{ truncated", "no brace here"] {
      var summary = ["bundleName": "com.example.demo", "installed": "true"]
      HDCObservationProviderAdapter.appendNativeLibraryFacts(from: text, to: &summary)
      XCTAssertEqual(
        summary, ["bundleName": "com.example.demo", "installed": "true"],
        "undecodable dump must not alter the verdict: \(text)")
    }
  }

  /// A dump that decodes but omits a field records the fields it does carry,
  /// rather than inventing a value for the missing one.
  func testAMissingFieldIsAbsentRatherThanInvented() {
    var summary: [String: String] = [:]
    HDCObservationProviderAdapter.appendNativeLibraryFacts(
      from: "d:\n{ \"applicationInfo\": { \"cpuAbi\": \"arm64-v8a\" } }", to: &summary)
    XCTAssertEqual(summary["cpuAbi"], "arm64-v8a")
    XCTAssertNil(summary["nativeLibraryPath"])
    XCTAssertNil(summary["nativeLibraryFileCount"])
  }
}

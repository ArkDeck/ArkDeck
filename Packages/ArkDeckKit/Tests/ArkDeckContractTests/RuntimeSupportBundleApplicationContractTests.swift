import ArkDeckClientKit
import Foundation
import XCTest

final class RuntimeSupportBundleApplicationContractTests: XCTestCase {
  func testPreviewIsReadOnlyAndExactDigestIsRequiredForExplicitExport() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-runtime-support-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "support", directoryHint: .isDirectory)
    let provider = RuntimeSupportBundleApplicationFacade.make()

    let preview = try await provider.preview(at: destination)
    XCTAssertEqual(preview.schemaVersion, "arkdeck.runtime-support-bundle-preview/1")
    XCTAssertEqual(preview.scopeSHA256.count, 64)
    XCTAssertTrue(preview.deviceRawExcluded)
    XCTAssertEqual(
      Set(preview.includedEntries),
      Set(["bundle.json", "hdc/tool-placeholder.json", "metadata.json"]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

    do {
      _ = try await provider.export(
        to: destination, approvedScopeSHA256: String(repeating: "0", count: 64))
      XCTFail("an unapproved scope was exported")
    } catch {
      XCTAssertEqual(error as? RuntimeSupportBundleServiceError, .previewMismatch)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

    let receipt = try await provider.export(
      to: destination, approvedScopeSHA256: preview.scopeSHA256)
    XCTAssertEqual(receipt.schemaVersion, "arkdeck.runtime-support-bundle-export/1")
    XCTAssertEqual(receipt.status, "exported")
    XCTAssertEqual(receipt.destination, destination.standardizedFileURL.path)
    XCTAssertEqual(receipt.scopeSHA256, preview.scopeSHA256)
    XCTAssertEqual(receipt.exportedBytes, preview.estimatedBytes)
    XCTAssertTrue(receipt.deviceRawExcluded)
    let manifest = try Data(contentsOf: destination.appending(path: "bundle.json"))
    XCTAssertTrue(manifest.contains(Data("\"automaticUploadEnabled\":false".utf8)))
    XCTAssertTrue(manifest.contains(Data("\"deviceRawExcluded\":true".utf8)))
  }

  func testPreviewDigestBindsTheDestinationAndLeavesNoPartialBundleOnMismatch() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-runtime-support-drift-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appending(path: "first", directoryHint: .isDirectory)
    let second = root.appending(path: "second", directoryHint: .isDirectory)
    let provider = RuntimeSupportBundleApplicationFacade.make()
    let preview = try await provider.preview(at: first)

    do {
      _ = try await provider.export(to: second, approvedScopeSHA256: preview.scopeSHA256)
      XCTFail("a digest approved for another destination was accepted")
    } catch {
      XCTAssertEqual(error as? RuntimeSupportBundleServiceError, .previewMismatch)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
  }
}

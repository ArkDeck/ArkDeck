import ArkDeckWorkflows
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

  func testRealCLIProcessPublishesOnePreviewThenExportsTheApprovedOwnerOnlyTree() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-runtime-support-cli-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "support", directoryHint: .isDirectory)

    let previewRun = try runCLI([
      "runtime", "support-bundle", "preview", "--destination", destination.path,
      "--output", "json", "--control-request-id", "ctl-support-preview-test",
    ])
    XCTAssertEqual(previewRun.exitCode, 0, previewRun.stderr)
    XCTAssertTrue(previewRun.stderr.isEmpty)
    let previewEnvelope = try object(previewRun.stdout)
    XCTAssertEqual(previewEnvelope["command"] as? String, "runtime.support-bundle.preview")
    XCTAssertEqual(previewEnvelope["ok"] as? Bool, true)
    let preview = try XCTUnwrap(previewEnvelope["result"] as? [String: Any])
    let digest = try XCTUnwrap(preview["scopeSHA256"] as? String)
    XCTAssertEqual(digest.count, 64)
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

    let rejected = root.appending(path: "rejected", directoryHint: .isDirectory)
    let rejectedRun = try runCLI([
      "runtime", "support-bundle", "export", "--destination", rejected.path,
      "--preview-digest", digest, "--output", "json",
      "--control-request-id", "ctl-support-rejected-test",
    ])
    XCTAssertEqual(rejectedRun.exitCode, 77)
    let rejectedEnvelope = try object(rejectedRun.stdout)
    let rejectedError = try XCTUnwrap(rejectedEnvelope["error"] as? [String: Any])
    XCTAssertEqual(rejectedError["code"] as? String, "previewDrifted")
    XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))

    let exportRun = try runCLI([
      "runtime", "support-bundle", "export", "--destination", destination.path,
      "--preview-digest", digest, "--output", "json",
      "--control-request-id", "ctl-support-export-test",
    ])
    XCTAssertEqual(exportRun.exitCode, 0, exportRun.stderr)
    XCTAssertTrue(exportRun.stderr.isEmpty)
    let exportEnvelope = try object(exportRun.stdout)
    XCTAssertEqual(exportEnvelope["command"] as? String, "runtime.support-bundle.export")
    XCTAssertEqual(exportEnvelope["ok"] as? Bool, true)
    let receipt = try XCTUnwrap(exportEnvelope["result"] as? [String: Any])
    XCTAssertEqual(receipt["status"] as? String, "exported")
    XCTAssertEqual(receipt["scopeSHA256"] as? String, digest)
    XCTAssertEqual(receipt["deviceRawExcluded"] as? Bool, true)
    for relativePath in ["", "bundle.json", "metadata.json", "hdc", "hdc/tool-placeholder.json"] {
      let url = relativePath.isEmpty ? destination : destination.appending(path: relativePath)
      let permissions = try XCTUnwrap(
        FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
      XCTAssertEqual(permissions.intValue & 0o077, 0, relativePath)
    }
  }

  private struct CLIRun {
    let exitCode: Int32
    let stdout: String
    let stderr: String
  }

  private func runCLI(_ arguments: [String]) throws -> CLIRun {
    let executable = Bundle(for: Self.self).bundleURL
      .deletingLastPathComponent().appending(path: "arkdeck")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw NSError(
        domain: "RuntimeSupportBundleCLI", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "missing arkdeck executable at \(executable.path)"])
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let out = stdout.fileHandleForReading.readDataToEndOfFile()
    let err = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CLIRun(
      exitCode: process.terminationStatus,
      stdout: String(decoding: out, as: UTF8.self),
      stderr: String(decoding: err, as: UTF8.self))
  }

  private func object(_ text: String) throws -> [String: Any] {
    let data = try XCTUnwrap(text.data(using: .utf8))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}

import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class DeviceRecordingExportTests: XCTestCase {
  @MainActor
  func testCopyPreservesSourceAndPublishesCompleteDestination() async throws {
    try await withScratch { directory in
      let source = directory.appending(path: "recording.mov")
      let destination = directory.appending(path: "saved.mov")
      let bytes = Data(repeating: 0x61, count: 128 * 1_024)
      try bytes.write(to: source)

      try await DeviceRecordingExport.copy(from: source, to: destination)

      XCTAssertEqual(try Data(contentsOf: source), bytes)
      XCTAssertEqual(try Data(contentsOf: destination), bytes)
      XCTAssertEqual(try contents(of: directory), ["recording.mov", "saved.mov"])
    }
  }

  @MainActor
  func testReplacingDestinationPreservesSourceAndRemovesStagingFile() async throws {
    try await withScratch { directory in
      let source = directory.appending(path: "recording.mov")
      let destination = directory.appending(path: "saved.mov")
      let bytes = Data("complete recording".utf8)
      try bytes.write(to: source)
      try Data("old destination".utf8).write(to: destination)

      try await DeviceRecordingExport.copy(from: source, to: destination)

      XCTAssertEqual(try Data(contentsOf: source), bytes)
      XCTAssertEqual(try Data(contentsOf: destination), bytes)
      XCTAssertEqual(try contents(of: directory), ["recording.mov", "saved.mov"])
    }
  }

  @MainActor
  func testFailedCopyDoesNotDeleteExistingDestination() async throws {
    try await withScratch { directory in
      let destination = directory.appending(path: "saved.mov")
      let original = Data("keep this file".utf8)
      try original.write(to: destination)

      do {
        try await DeviceRecordingExport.copy(
          from: directory.appending(path: "missing.mov"), to: destination)
        XCTFail("A missing source must fail")
      } catch {
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try contents(of: directory), ["saved.mov"])
      }
    }
  }

  @MainActor
  func testCancelledExportDoesNotPublishOrReplaceDestination() async throws {
    try await withScratch { directory in
      let source = directory.appending(path: "recording.mov")
      let destination = directory.appending(path: "saved.mov")
      let original = Data("old destination".utf8)
      try Data("new recording".utf8).write(to: source)
      try original.write(to: destination)

      let export = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await DeviceRecordingExport.copy(from: source, to: destination)
      }
      do {
        try await export.value
        XCTFail("A cancelled export must fail before publishing")
      } catch is CancellationError {
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try contents(of: directory), ["recording.mov", "saved.mov"])
      }
    }
  }

  @MainActor
  private func withScratch(_ test: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-recording-export-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await test(directory)
  }

  private func contents(of directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  }
}

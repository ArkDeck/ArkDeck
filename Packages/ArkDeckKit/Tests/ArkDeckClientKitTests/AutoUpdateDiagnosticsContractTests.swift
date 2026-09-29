import ArkDeckClientKit
import Foundation
import Testing

/// The updater logs through the SystemLogger adapter of its production
/// assembly; both live in ClientKit beside the updater.
struct AutoUpdateDiagnosticsContractTests {
  @Test func TEST_AU_CONTRACT_001_updateDiagnosticsUseClosedPublicEventsOnly() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-update-logging-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try StructuredDiagnosticLogStore(directory: root.appending(path: "logs"))
    let logger = SystemAutoUpdateEventLogger(logger: SystemLogger(structuredStore: store))
    for event in [
      AutoUpdateLogEvent.checkStarted, .available, .noUpdate, .downloadStarted,
      .verificationStarted, .failed, .cancelled, .handedOff,
    ] {
      logger.record(event)
    }
    let bytes = try store.snapshot().files.reduce(into: Data()) { $0.append($1.data) }
    #expect(bytes.contains(Data("\"eventName\":\"update.check\"".utf8)))
    #expect(bytes.contains(Data("\"eventName\":\"update.download\"".utf8)))
    #expect(bytes.contains(Data("\"eventName\":\"update.verification\"".utf8)))
    #expect(bytes.contains(Data("\"eventName\":\"update.handoff\"".utf8)))
    #expect(!bytes.contains(Data("/Users/".utf8)))
    #expect(!bytes.contains(Data("github.com".utf8)))
  }
}

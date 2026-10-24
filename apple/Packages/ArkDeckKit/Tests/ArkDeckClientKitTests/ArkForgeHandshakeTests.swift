import Foundation
import Testing
@testable import ArkDeckClientKit

struct ArkForgeHandshakeTests {
  @Test func refusalKeepsItsTypeAndDaemonReasonInTheFlashWorkspace() {
    let reason = "ArkForge PROTOCOL_REFUSED: protocol major 2 is not compatible with 1"
    let data = Data(#"{"ok":false,"error":{"code":"unsupportedProtocolVersion","message":"ArkForge PROTOCOL_REFUSED: protocol major 2 is not compatible with 1"}}"#.utf8)
    let presentation = RockchipDeviceAccessResponseDecoding.presentation(.success(data))
    #expect(presentation.availability == .unavailable(reason: "unsupportedProtocolVersion: \(reason)"))
    #expect(presentation.advice?.verdict == .protocolBlocked)
    #expect(presentation.observationCount == 0)
  }

  @Test func transportErrorsDoNotLeakPrivateDiagnostics() {
    let data = Data(#"{"ok":false,"error":{"code":"rejected","message":"private socket path"}}"#.utf8)
    let presentation = RockchipDeviceAccessResponseDecoding.presentation(.success(data))
    #expect(presentation.availability == .unavailable(reason: "runtime_device_access_unavailable"))
  }
}

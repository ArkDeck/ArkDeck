// The XPC transport's whole job is to be narrower than the Unix socket.
// These tests pin that narrowness, because the App reaching Runtime through
// it is only safe while it stays a read-only door.

import ArkDeckCore
import Foundation
import XCTest

@testable import ArkDeckAgentDaemon

final class AgentXPCTransportContractTests: XCTestCase {
  private func frame(method: String) -> Data {
    Data(#"{"v":1,"id":"contract","method":"\#(method)"}"#.utf8)
  }

  // Every allowlisted method forwards, and the allowlist is exactly the set
  // of methods that read state.
  func testTheAllowlistForwardsExactlyTheReadOnlyControlPlane() {
    for method in ArkDeckAgentXPC.forwardableReadOnlyMethods {
      XCTAssertEqual(
        AgentXPCEndpoint.readOnlyMethod(of: frame(method: method)), method,
        "\(method) is on the allowlist and must forward")
    }
    XCTAssertEqual(
      ArkDeckAgentXPC.forwardableReadOnlyMethods,
      [
        "artifact.inspect", "artifact.list", "job.evidence", "job.list",
        "job.list-page", "job.status", "operation.list", "target.list",
      ],
      "widening this set is a device-effect decision, not a refactor")
  }

  // The load-bearing assertion: no method that can queue, execute, cancel,
  // adopt or import may cross this transport, so a sandboxed client of it
  // cannot reach E1 or E2 at all.
  func testEveryMutatingControlPlaneMethodIsRefusedBeforeTheHandler() {
    for method in [
      "job.submit", "job.run", "job.cancel", "job.reconcile", "job.plan",
      "target.adopt", "artifact.export", "artifact.read",
      "artifact.importHap.begin", "artifact.importHap.append",
      "artifact.importHap.commit", "artifact.importHap.abort",
      "artifact.importFlashBundle.begin", "artifact.importFlashBundle.commit",
      "artifact.importNativeLibrary.begin", "artifact.importNativeLibrary.commit",
    ] {
      XCTAssertNil(
        AgentXPCEndpoint.readOnlyMethod(of: frame(method: method)),
        "\(method) must never cross the sandboxed App transport")
      XCTAssertEqual(
        AgentXPCEndpoint.refusal(for: frame(method: method)), .methodNotReadOnly)
    }
  }

  // Fail closed on anything that is not a recognisable allowlisted request:
  // an unknown method, a method added to the daemon after this build, and a
  // frame that does not parse at all.
  func testUnknownAndMalformedFramesFailClosed() {
    XCTAssertNil(AgentXPCEndpoint.readOnlyMethod(of: frame(method: "job.somethingNew")))
    XCTAssertEqual(
      AgentXPCEndpoint.refusal(for: frame(method: "job.somethingNew")), .methodNotReadOnly)

    for malformed in [Data(), Data("not json".utf8), Data(#"{"v":1}"#.utf8), Data("[]".utf8)] {
      XCTAssertNil(AgentXPCEndpoint.readOnlyMethod(of: malformed))
      XCTAssertEqual(AgentXPCEndpoint.refusal(for: malformed), .malformedRequestFrame)
    }
  }

  // The service name is duplicated across three artifacts that cannot import
  // each other. If they drift, the lookup fails closed at runtime with no
  // compile-time signal, so the drift is caught here instead.
  func testTheMachServiceNameAgreesAcrossTheAppEntitlementAndLaunchAgent() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let name = ArkDeckAgentXPC.machServiceName
    XCTAssertEqual(name, "com.arkdeck.agentd")

    let entitlements = try String(
      contentsOf: root.appending(path: "ArkDeckApp/ArkDeckApp.entitlements"), encoding: .utf8)
    XCTAssertTrue(
      entitlements.contains("com.apple.security.temporary-exception.mach-lookup.global-name"),
      "the sandboxed App cannot look up the service without this exception")
    XCTAssertTrue(
      entitlements.contains("<string>\(name)</string>"),
      "the App's mach-lookup exception must name the exact vended service")

    let launchAgent = try String(
      contentsOf: root.appending(path: "Packages/ArkDeckKit/LaunchAgents/com.arkdeck.agentd.plist"),
      encoding: .utf8)
    XCTAssertTrue(
      launchAgent.contains("<key>\(name)</key>"),
      "the LaunchAgent must vend the exact service the App looks up")
  }
}

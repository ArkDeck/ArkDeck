import Foundation
import Testing
@testable import ArkDeckClientKit

struct HDCClientDiagnosticsTests {
  private func response(_ changes: [String: Any] = [:]) throws -> Data {
    var status: [String: Any] = [
      "schemaVersion": "arkdeck.runtime-hdc-status/1", "availability": "available",
      "executableSHA256": String(repeating: "a", count: 64), "endpoint": "127.0.0.1:8710",
      "endpointSource": "default", "generation": "7", "ownership": "arkDeckManaged",
      "serverHealth": "healthy", "clientVersion": "3.2.0f", "serverVersion": "3.2.0f",
      "daemonVersion": "0.1.0", "newDispatchCount": 0,
    ]
    status.merge(changes) { _, value in value }
    return try JSONSerialization.data(withJSONObject: ["ok": true, "result": status])
  }

  private func observation(stale: Bool = false) -> DeviceListPresentation {
    DeviceListPresentation(
      availability: .available,
      candidates: [.init(connectKey: "fixture", state: "Connected", adoptedTargetID: "target", bindingRevision: 1,
        stateObservationHealth: stale ? .stale : .current)])
  }

  private actor Replies {
    var responses: [RuntimeXPCRequestTransport.ResultValue]
    var calls: [String] = []
    init(_ responses: [RuntimeXPCRequestTransport.ResultValue]) { self.responses = responses }
    func send(_ method: String) -> RuntimeXPCRequestTransport.ResultValue {
      calls.append(method)
      guard !responses.isEmpty else { return .failure(.refused("unexpected request")) }
      return responses.removeFirst()
    }
  }

  @Test func productionRefreshUsesOnlyRuntimeAndDoesNotInventMissingObservations() async throws {
    let replies = Replies([.success(try response())])
    let provider = HDCClientDiagnosticsProvider(send: { await replies.send($0) })
    let status = await provider.refresh(deviceObservation: observation())
    #expect(status.isRuntimeManaged)
    #expect(status.serverHealth == .healthy)
    #expect(status.authorization == .ready)
    #expect(status.generation == "7")
    #expect(status.ownership == .arkDeckManaged)
    #expect(status.loadFailure == nil)
    #expect(status.automaticLifecycleDispatchCount == nil)
    #expect(status.automaticSubserverDispatchCount == nil)
    #expect(!status.deviceEventsAvailable)
    #expect(status.ownershipBasis == nil)
    #expect(status.channelProtection == .unverifiedAssumeUnprotected)
    #expect(!provider.lifecycleDispatchIsProductionComposed)
    let calls = await replies.calls
    #expect(calls == ["runtime.hdc.status"])
  }

  @Test func disconnectClearsPreviousFactsWithoutFallbackOrRetry() async throws {
    let replies = Replies([.success(try response()), .failure(.unavailable("connection interrupted"))])
    let provider = HDCClientDiagnosticsProvider(send: { await replies.send($0) })
    _ = await provider.refresh(deviceObservation: observation())
    let failed = await provider.refresh(deviceObservation: observation())
    #expect(failed.isRuntimeManaged)
    #expect(failed.serverHealth == .unknown)
    #expect(failed.ownership == .unknown)
    #expect(failed.generation == "unknown")
    #expect(try #require(failed.loadFailure).contains("connection interrupted"))
    #expect(failed.authorization != .ready)
    let calls = await replies.calls
    #expect(calls == ["runtime.hdc.status", "runtime.hdc.status"])
  }

  @Test func unavailableAndMalformedFactsCannotPromoteAuthorizationOrHealth() throws {
    for change: [String: Any] in [
      ["availability": "unavailable", "reasonCode": "hdc.notConfigured"],
      ["availability": "unknown", "reasonCode": "hdc.identityObservationTimedOut"],
      ["schemaVersion": "future"], ["executableSHA256": "short"],
      ["endpoint": "192.0.2.1:8710"], ["endpoint": "127.0.0.1:0"],
      ["generation": "01"], ["generation": "0"], ["ownership": "future"],
      ["serverHealth": "future"], ["endpointSource": "future"],
    ] {
      let status = HDCClientDiagnosticsDecoding.presentation(.success(try response(change)), deviceObservation: observation())
      #expect(status.loadFailure != nil, "\(change)")
      #expect(status.serverHealth == .unknown)
      #expect(status.authorization != .ready)
      #expect(status.lifecycleImpactPreview == nil)
    }
    let missing = HDCClientDiagnosticsDecoding.presentation(
      .success(try response(["availability": "unavailable", "reasonCode": "hdc.notConfigured"])), deviceObservation: observation())
    #expect(try #require(missing.loadFailure).contains("hdc.notConfigured"))
  }

  @Test func runtimeRefusalPreservesReasonAndClearsFacts() throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "ok": false, "error": ["code": "methodNotAllowlisted", "message": "App method unavailable"],
    ])
    let status = HDCClientDiagnosticsDecoding.presentation(.success(data), deviceObservation: observation())
    #expect(try #require(status.loadFailure).contains("methodNotAllowlisted"))
    #expect(try #require(status.loadFailure).contains("App method unavailable"))
    #expect(status.serverHealth == .unknown)
    #expect(status.authorization != .ready)
  }

  @Test func timeoutRemainsUnknownAndStaleDeviceDoesNotShowReady() throws {
    let timedOut = HDCClientDiagnosticsDecoding.presentation(.failure(.timedOut), deviceObservation: observation())
    #expect(timedOut.loadFailure != nil)
    #expect(timedOut.serverHealth == .unknown)
    let stale = HDCClientDiagnosticsDecoding.presentation(.success(try response()), deviceObservation: observation(stale: true))
    #expect(stale.serverHealth == .healthy)
    #expect(stale.authorization != .ready)
  }

  @Test func legacyLocalFlagsDoNotSelectHostExecutionOrFixture() {
    let production = HDCClientDiagnosticsApplicationFacade.make(arguments: [
      "ArkDeck", "--ui-test-hdc-local-production-presentation", "--ui-test-reset-hdc-selection",
    ])
    #expect(production is HDCClientDiagnosticsProvider)
    #expect(!production.lifecycleDispatchIsProductionComposed)
    #expect(HDCClientDiagnosticsApplicationFacade.make(arguments: ["--ui-test-hdc-diagnostics"]) is HDCClientDiagnosticsFixture)
  }

  @Test func unavailableRecoveryNeverCreatesConfirmationOrDispatch() async {
    let replies = Replies([])
    let provider = HDCClientDiagnosticsProvider(send: { await replies.send($0) })
    for status in [await provider.requestRecoveryImpactPreview(), await provider.confirmRecoveryImpactPreview(),
      await provider.dispatchConfirmedRecovery()] {
      guard case .unavailable = status.lifecycleRecovery else {
        Issue.record("no App approval route is composed")
        return
      }
      #expect(status.lifecycleImpactPreview == nil)
    }
    await #expect(throws: (any Error).self, "App must not register a local execution path") {
      _ = try await provider.selectUserConfiguredExecutable(URL(filePath: "/tmp/unregistered-hdc"))
    }
    let calls = await replies.calls
    #expect(calls.isEmpty)
  }

  @Test func explicitFixtureRetainsDisplayStatesWithoutAuthority() async {
    let fixture = HDCClientDiagnosticsFixture(arguments: ["--ui-test-hdc-diagnostics", "--ui-test-hdc-channel-verified"])
    let current = await fixture.refresh(deviceObservation: .loading)
    #expect(!current.isRuntimeManaged)
    #expect(current.deviceEventsAvailable)
    #expect(current.automaticLifecycleDispatchCount == 0)
    let preview = await fixture.requestRecoveryImpactPreview()
    #expect(preview.lifecycleImpactPreview?.generation == 7)
    let confirmed = await fixture.confirmRecoveryImpactPreview()
    guard case .confirmed(let display) = confirmed.lifecycleRecovery else {
      Issue.record("fixture label must be retained")
      return
    }
    #expect(display.generation == 7)
    #expect(!fixture.lifecycleDispatchIsProductionComposed)
  }
}

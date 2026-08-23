import ArkDeckCore
import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// What a Runtime request costs before any payload moves.
///
/// Opt-in and measurement-only: it needs a live daemon, so it is skipped
/// unless `TEST_RUNNER_ARKDECK_XPC_COST=1` reaches the runner. It asserts
/// nothing about absolute time — a busy machine would fail that — and instead
/// compares two shapes of the same work on the same machine in the same run.
final class RuntimeXPCTransportCostTests: XCTestCase {
  private static let environmentKey = "ARKDECK_XPC_COST"
  private let rounds = 24

  /// A store read with no device work in it. Isolating transport cost needs a
  /// method that does nothing else — the first attempt used `operation.list`,
  /// which turned out to spend seconds evaluating availability.
  private let method = "target.list"

  /// Every read the Viewer performs, so the cost of a refresh can be attributed
  /// rather than guessed.
  private let sweep = ["target.list", "operation.list", "job.list", "operation.list"]

  func testWhatEachRuntimeReadCosts() async throws {
    guard ProcessInfo.processInfo.environment[Self.environmentKey] == "1" else {
      throw XCTSkip("Set \(Self.environmentKey)=1 with a running daemon to measure read cost")
    }
    _ = await RuntimeXPCRequestTransport.request(method: "target.list")
    var lines: [String] = []
    for method in sweep {
      var samples: [Double] = []
      let params: [String: JSONValue]? =
        method == "operation.describe"
        ? ["operation": .string("capture.diagnostics@1")] : nil
      for _ in 0..<8 {
        let start = DispatchTime.now().uptimeNanoseconds
        let response = await RuntimeXPCRequestTransport.request(method: method, params: params)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        guard case .success = response else { break }
        samples.append(elapsed)
      }
      guard !samples.isEmpty else {
        lines.append("\(method): refused")
        continue
      }
      lines.append("\(method): \(summary(samples))")
      print("[xpc-cost] \(method): \(summary(samples))")
    }
    let evidence = XCTAttachment(string: lines.joined(separator: "\n"))
    evidence.name = "runtime-read-cost"
    evidence.lifetime = .keepAlways
    add(evidence)
  }

  /// Where a bounded artifact read actually spends its time, and whether the
  /// chunk size is the lever. Driven by `ARKDECK_XPC_JOB` / `ARKDECK_XPC_ARTIFACT`
  /// because a published artifact only exists after a real capture.
  func testWhatABoundedArtifactReadCosts() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment[Self.environmentKey] == "1",
      let jobID = environment["ARKDECK_XPC_JOB"],
      let artifactID = environment["ARKDECK_XPC_ARTIFACT"]
    else {
      throw XCTSkip("Set \(Self.environmentKey)=1 with ARKDECK_XPC_JOB / ARKDECK_XPC_ARTIFACT")
    }

    var lines: [String] = []
    for chunkBytes in [64 * 1_024, 256 * 1_024, 1_024 * 1_024, 4 * 1_024 * 1_024] {
      var perChunk: [Double] = []
      var whole: [Double] = []
      for _ in 0..<4 {
        let started = DispatchTime.now().uptimeNanoseconds
        var offset: Int64 = 0
        var chunks = 0
        while true {
          let start = DispatchTime.now().uptimeNanoseconds
          let response = await RuntimeXPCRequestTransport.request(
            method: "artifact.read",
            params: [
              "jobId": .string(jobID), "artifactId": .string(artifactID),
              "offset": .integer(offset), "maxBytes": .integer(Int64(chunkBytes)),
              "allowSensitive": .bool(true),
            ])
          perChunk.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
          guard case .success(let data) = response,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = object["result"] as? [String: Any],
            let base64 = result["base64"] as? String
          else { throw XCTSkip("the daemon refused artifact.read") }
          chunks += 1
          _ = base64
          offset = (result["nextOffset"] as? NSNumber)?.int64Value ?? offset
          if result["eof"] as? Bool == true || chunks > 512 { break }
        }
        whole.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
      }
      let line = "chunk \(chunkBytes / 1024)KB x\(perChunk.count / 4): whole \(summary(whole)) | per-chunk \(summary(perChunk))"
      lines.append(line)
      print("[xpc-cost] \(line)")
    }
    let evidence = XCTAttachment(string: lines.joined(separator: "\n"))
    evidence.name = "artifact-read-cost"
    evidence.lifetime = .keepAlways
    add(evidence)
  }

  /// The App does three things this harness did not: it decodes base64, hashes
  /// incrementally, and accumulates into one `Data` — all inside an actor.
  /// This runs the same read both ways so the difference is attributable.
  func testWhereTheAppSideReadSpendsItsTime() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment[Self.environmentKey] == "1",
      let jobID = environment["ARKDECK_XPC_JOB"],
      let artifactID = environment["ARKDECK_XPC_ARTIFACT"],
      let totalBytes = environment["ARKDECK_XPC_BYTES"].flatMap(Int64.init)
    else {
      throw XCTSkip("Set \(Self.environmentKey)=1 with job / artifact / bytes")
    }

    let reader = ReadReplica()
    var bare: [Double] = []
    var full: [Double] = []
    for _ in 0..<6 {
      bare.append(
        try await reader.read(
          jobID: jobID, artifactID: artifactID, totalBytes: totalBytes, verify: false))
      full.append(
        try await reader.read(
          jobID: jobID, artifactID: artifactID, totalBytes: totalBytes, verify: true))
    }
    print("[xpc-cost] in-actor, transport only: \(summary(bare))")
    print("[xpc-cost] in-actor, + base64 + SHA-256 + accumulate: \(summary(full))")
    let evidence = XCTAttachment(
      string: "transport only: \(summary(bare))\nwith App-side work: \(summary(full))")
    evidence.name = "app-side-read-cost"
    evidence.lifetime = .keepAlways
    add(evidence)
  }

  /// A faithful replica of the production read loop, on an actor like the
  /// production provider.
  private actor ReadReplica {
    func read(
      jobID: String, artifactID: String, totalBytes: Int64, verify: Bool
    ) async throws -> Double {
      let start = DispatchTime.now().uptimeNanoseconds
      var bytes = Data()
      var digest = SHA256()
      var offset: Int64 = 0
      while offset < totalBytes {
        let response = await RuntimeXPCRequestTransport.request(
          method: "artifact.read",
          params: [
            "jobId": .string(jobID), "artifactId": .string(artifactID),
            "offset": .integer(offset), "maxBytes": .integer(256 * 1_024),
            "allowSensitive": .bool(true),
          ])
        guard case .success(let data) = response,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let result = object["result"] as? [String: Any],
          let base64 = result["base64"] as? String,
          let next = (result["nextOffset"] as? NSNumber)?.int64Value
        else { throw ReplicaFailure.refused }
        if verify {
          guard let chunk = Data(base64Encoded: base64) else { throw ReplicaFailure.refused }
          digest.update(data: chunk)
          bytes.append(chunk)
        }
        offset = next
        if result["eof"] as? Bool == true { break }
      }
      if verify { _ = digest.finalize() }
      return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    enum ReplicaFailure: Error { case refused }
  }

  /// What the daemon's own code-identity check costs, and what memoising it
  /// saves. Measured against the installed helper without replacing it, so
  /// the saving can be shown before anything is deployed.
  func testTrustedDaemonIdentityIsExpensiveOnceAndFreeAfterwards() throws {
    guard ProcessInfo.processInfo.environment[Self.environmentKey] == "1" else {
      throw XCTSkip("Set \(Self.environmentKey)=1 with an installed helper to measure this")
    }
    let store = LoginKeychainSigningSecretStore()
    RuntimeFileDerivedCaches.daemonIdentity.invalidate()

    let cold = try elapsed { _ = try store.trustedDaemonApplicationSHA256() }
    var warm: [Double] = []
    for _ in 0..<8 {
      warm.append(try elapsed { _ = try store.trustedDaemonApplicationSHA256() })
    }

    print("[xpc-cost] daemon identity: cold \(round(cold * 100) / 100)ms, warm \(summary(warm))")
    let evidence = XCTAttachment(
      string: "cold \(cold)ms\nwarm \(summary(warm))")
    evidence.name = "daemon-identity-cost"
    evidence.lifetime = .keepAlways
    add(evidence)

    // The point of the cache, asserted as a ratio so a busy machine cannot
    // fail it: a repeat answer must not cost what the first one did.
    XCTAssertLessThan(
      median(warm) * 20, cold,
      "a memoised code-identity answer must be far cheaper than evaluating it again")
  }

  /// The hash that availability re-derived once per published operation.
  func testExecutableDigestIsHashedOnceAndMemoisedAfterwards() throws {
    guard ProcessInfo.processInfo.environment[Self.environmentKey] == "1" else {
      throw XCTSkip("Set \(Self.environmentKey)=1 to measure the executable digest")
    }
    let path = "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
    try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "needs an installed hdc")
    RuntimeFileDerivedCaches.executableDigest.invalidate()

    let cold = try elapsed { _ = try WorkspaceExecutableIdentity.hashing(path: path) }
    var warm: [Double] = []
    for _ in 0..<24 {
      warm.append(try elapsed { _ = try WorkspaceExecutableIdentity.hashing(path: path) })
    }
    print("[xpc-cost] executable digest: cold \(round(cold * 100) / 100)ms, warm \(summary(warm))")

    // Availability asks for this once per operation. Twenty-five operations
    // used to mean twenty-five hashes of the same unchanged file.
    XCTAssertLessThan(
      median(warm) * 20, cold,
      "a memoised digest must not cost what hashing the file again costs")
    let evidence = XCTAttachment(string: "cold \(cold)ms\nwarm \(summary(warm))")
    evidence.name = "executable-digest-cost"
    evidence.lifetime = .keepAlways
    add(evidence)
  }

  private func elapsed(_ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
  }

  func testConnectionPerRequestVersusOneReusedConnection() async throws {
    guard ProcessInfo.processInfo.environment[Self.environmentKey] == "1" else {
      throw XCTSkip("Set \(Self.environmentKey)=1 with a running daemon to measure transport cost")
    }

    // Warm both paths: the first request of a session pays a launchd lookup
    // that says nothing about steady-state cost.
    _ = await RuntimeXPCRequestTransport.request(method: method)
    let warmup = try await reusedConnectionSamples(count: 2)
    XCTAssertEqual(warmup.count, 2, "the daemon must answer before this measures anything")

    var perRequest: [Double] = []
    for _ in 0..<rounds {
      let start = DispatchTime.now().uptimeNanoseconds
      let response = await RuntimeXPCRequestTransport.request(method: method)
      let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
      guard case .success = response else {
        throw XCTSkip("the daemon refused \(method); nothing to measure")
      }
      perRequest.append(elapsed)
    }

    let reused = try await reusedConnectionSamples(count: rounds)

    report("connection-per-request", perRequest)
    report("one-reused-connection", reused)
    let saved = median(perRequest) - median(reused)
    print(
      "[xpc-cost] median saved per request = \(round(saved * 100) / 100)ms; "
        + "spread(per-request) = \(round((spread(perRequest)) * 100) / 100)ms, "
        + "spread(reused) = \(round((spread(reused)) * 100) / 100)ms")

    let evidence = XCTAttachment(
      string: """
        method=\(method) rounds=\(rounds)
        connection-per-request: \(summary(perRequest))
        one-reused-connection: \(summary(reused))
        """)
    evidence.name = "xpc-transport-cost"
    evidence.lifetime = .keepAlways
    add(evidence)

    // The only assertion: both shapes actually ran. The numbers are the point.
    XCTAssertEqual(perRequest.count, rounds)
    XCTAssertEqual(reused.count, rounds)
  }

  // MARK: - One connection, many requests

  private func reusedConnectionSamples(count: Int) async throws -> [Double] {
    let connection = NSXPCConnection(
      machServiceName: ArkDeckAgentXPC.machServiceName, options: [])
    connection.remoteObjectInterface = NSXPCInterface(with: ArkDeckAgentXPCProtocol.self)
    connection.resume()
    defer { connection.invalidate() }

    var samples: [Double] = []
    for _ in 0..<count {
      let frame = try ArkDeckAgentXPC.requestFrame(method: method, params: nil)
      let start = DispatchTime.now().uptimeNanoseconds
      let answered: Bool = await withCheckedContinuation { continuation in
        let proxy =
          connection.remoteObjectProxyWithErrorHandler { _ in
            continuation.resume(returning: false)
          } as? ArkDeckAgentXPCProtocol
        guard let proxy else { return continuation.resume(returning: false) }
        proxy.sendRequestFrame(frame) { data, _ in
          continuation.resume(returning: data != nil)
        }
      }
      guard answered else { throw XCTSkip("the daemon stopped answering mid-measurement") }
      samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    return samples
  }

  // MARK: - Reporting

  private func report(_ label: String, _ samples: [Double]) {
    print("[xpc-cost] \(label): \(summary(samples))")
  }

  private func summary(_ samples: [Double]) -> String {
    let sorted = samples.sorted()
    func at(_ fraction: Double) -> Double {
      sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))]
    }
    return String(
      format: "min %.2fms p50 %.2fms p90 %.2fms max %.2fms",
      sorted.first ?? 0, at(0.5), at(0.9), sorted.last ?? 0)
  }

  private func median(_ samples: [Double]) -> Double {
    let sorted = samples.sorted()
    return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
  }

  private func spread(_ samples: [Double]) -> Double {
    (samples.max() ?? 0) - (samples.min() ?? 0)
  }
}

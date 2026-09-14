// Shared Swift oracle for the Rust HDC runtime status observer (TASK-XPA-016,
// M1): the `arkdeck.runtime-hdc-status/1` object `HeadlessHDCStatusObserver`
// answers `runtime.hdc.status` with, across its whole decision table — the
// unconfigured shape, a managed server, the three ways ownership stays
// unproven, the five ways an observed identity fails to match the selected
// tool and endpoint, the five non-observed classifications, the tool changing
// under the observation or under the ownership check, a missing tool, a
// digest that does not match, and the explicit and inherited endpoints. The
// Rust observer replays every case and must answer the same bytes.
//
// Everything here is host-local and machine-independent: the tool is the
// shared fake HDC driver (fixed bytes, unsigned — so the production signature
// inspection runs on it and answers the unsigned object), at a fixed root,
// under a fixed clock. What needs a live kernel process — the commandless
// identity observation and the managed-process predicate — is the observer's
// own seam and is recorded as each case's input. The supervisor route of the
// ownership decision is not recorded (a supervisor actor cannot be composed
// here); the Rust port of that decision is unit-tested on its own.
//
// Record a new oracle with `ARKDECK_RUST_HDC_STATUS_RECORD=/private/tmp/<new
// directory>`; otherwise the checked-in oracle must match byte for byte.
import Darwin
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckWorkflows

final class HDCStatusOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/hdc-status", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_HDC_STATUS_RECORD"
  /// A fixed root: the tool's path is part of the answer.
  private static let root = URL(
    filePath: "/private/tmp/arkdeck-hdc-status-oracle", directoryHint: .isDirectory)
  private static let nowUTC = "2026-09-14T00:00:00Z"
  private static let daemonVersion = "0.0.0-oracle"
  private static let endpoint = "127.0.0.1:8710"
  private static let arguments = ["-s", endpoint, "-m"]
  private static let driverSHA256 = SHA256Hex.string(of: HDCOracleFake.driver)
  private static let members: Set<String> = [
    "schemaVersion", "availability", "observedAt", "executablePath", "executableSource",
    "configuredExecutableSHA256", "executableSHA256", "signature", "clientVersion",
    "clientVersionSource", "serverVersion", "daemonVersion", "endpoint", "endpointSource",
    "serverEndpointRef", "ownership", "generation", "processId", "serverHealth",
    "healthReasonCode", "startupVersions", "reasonCode", "newDispatchCount",
  ]

  private enum Disturbance: String {
    case none
    /// The tool's mode is taken away and restored while the identity is observed.
    case duringObservation
    /// The same, while the managed process is verified.
    case duringOwnership
  }

  private struct Case {
    let name: String
    /// `nil` is the unconfigured daemon (`HeadlessHDCStatusObserver.unconfigured`).
    var executable: ResolvedExecutable?
    var startup: HDCManagedRuntimeDiagnostics
    var daemonVersion: String?
    var launch: HDCManagedProcessLaunch?
    var classification: HDCSupervisorObservationClassification
    var identity: HDCServerProcessIdentityReceipt?
    var managedProcessVerified: Bool
    var disturbance: Disturbance
  }

  private var files: [String: Data] = [:]
  private var cases: [JSONValue] = []

  private static var hdc: ResolvedExecutable {
    ResolvedExecutable(path: root.appending(path: "hdc").path, sha256: driverSHA256)
  }

  private static func startup(
    endpoint: String = endpoint, source: String = "default"
  ) -> HDCManagedRuntimeDiagnostics {
    .init(
      executableSHA256: driverSHA256, clientVersion: "cached-client",
      serverVersion: "cached-server", endpoint: endpoint, endpointSource: source)
  }

  private static func receipt(
    pid: Int32 = 42, seconds: UInt64 = 100, microseconds: UInt64 = 23,
    path: String = hdc.path, sha256: String = driverSHA256, endpoint: String = endpoint
  ) -> HDCServerProcessIdentityReceipt {
    .init(
      pid: pid, startSeconds: seconds, startMicroseconds: microseconds,
      executablePath: URL(filePath: path), executableSHA256: sha256,
      endpoint: HDCServerEndpoint(endpoint))
  }

  private static func launch(seconds: UInt64 = 100) -> HDCManagedProcessLaunch {
    .init(
      pid: 42, startSeconds: seconds, startMicroseconds: 23, executablePath: hdc.path,
      executableSHA256: driverSHA256, arguments: arguments)
  }

  /// A managed server observed as launched: every other case departs from it.
  private static func base(_ name: String) -> Case {
    Case(
      name: name, executable: hdc, startup: startup(), daemonVersion: daemonVersion,
      launch: launch(), classification: .observed(generation: 100_000_023),
      identity: receipt(), managedProcessVerified: true, disturbance: .none)
  }

  private static func json(_ receipt: HDCServerProcessIdentityReceipt) -> JSONValue {
    .object([
      "pid": .integer(Int64(receipt.pid)),
      "startSeconds": .integer(Int64(receipt.startSeconds)),
      "startMicroseconds": .integer(Int64(receipt.startMicroseconds)),
      "executablePath": .string(receipt.executablePath.path),
      "executableSHA256": .string(receipt.executableSHA256),
      "endpoint": .string(receipt.endpoint.rawValue),
    ])
  }

  private static func json(_ launch: HDCManagedProcessLaunch) -> JSONValue {
    .object([
      "pid": .integer(Int64(launch.pid)),
      "startSeconds": .integer(Int64(launch.startSeconds)),
      "startMicroseconds": .integer(Int64(launch.startMicroseconds)),
      "executablePath": .string(launch.executablePath),
      "executableSHA256": .string(launch.executableSHA256),
      "arguments": .array(launch.arguments.map(JSONValue.string)),
    ])
  }

  private static func json(_ candidate: Case) -> JSONValue {
    var observation: [String: JSONValue] = [
      "identity": candidate.identity.map(json) ?? .null
    ]
    switch candidate.classification {
    case .observed(let generation):
      observation["classification"] = .string("observed")
      observation["generation"] = .integer(Int64(generation))
    case .unavailable(let reason):
      observation["classification"] = .string("unavailable")
      observation["reason"] = .string(reason)
    case .unknown(let reason):
      observation["classification"] = .string("unknown")
      observation["reason"] = .string(reason)
    case .unsupported(let reason):
      observation["classification"] = .string("unsupported")
      observation["reason"] = .string(reason)
    case .timedOut:
      observation["classification"] = .string("timedOut")
    case .cancelled:
      observation["classification"] = .string("cancelled")
    }
    return .object([
      "name": .string(candidate.name),
      "executable": candidate.executable.map {
        .object(["path": .string($0.path), "sha256": .string($0.sha256)])
      } ?? .null,
      "startup": .object([
        "executableSHA256": .string(candidate.startup.executableSHA256),
        "clientVersion": .string(candidate.startup.clientVersion),
        "serverVersion": .string(candidate.startup.serverVersion),
        "endpoint": .string(candidate.startup.endpoint),
        "endpointSource": .string(candidate.startup.endpointSource),
      ]),
      "daemonVersion": candidate.daemonVersion.map(JSONValue.string) ?? .null,
      "launch": candidate.launch.map(json) ?? .null,
      "observation": .object(observation),
      "managedProcessVerified": .bool(candidate.managedProcessVerified),
      "disturbance": .string(candidate.disturbance.rawValue),
    ])
  }

  /// The observer composed as the daemon composes it, except for the seam
  /// inputs the case names; the signature inspection is the production one.
  private static func snapshot(_ candidate: Case) async -> JSONValue {
    guard let executable = candidate.executable else {
      return HeadlessHDCStatusObserver.unconfigured(daemonVersion: candidate.daemonVersion)
    }
    let path = executable.path
    let disturb: @Sendable () -> Void = {
      _ = chmod(path, 0o600)
      _ = chmod(path, 0o700)
    }
    let result = HDCSupervisorObservationResult(
      classification: candidate.classification, identity: candidate.identity)
    let launch = candidate.launch
    let disturbance = candidate.disturbance
    let verified = candidate.managedProcessVerified
    let observer = HeadlessHDCStatusObserver(
      executable: executable, startup: candidate.startup, daemonVersion: candidate.daemonVersion,
      managedLaunch: { launch },
      observeIdentity: { _, _ in
        if disturbance == .duringObservation { disturb() }
        return result
      },
      inspectSignature: HeadlessHDCStatusObserver.signature,
      validateManagedProcess: { _, _ in
        if disturbance == .duringOwnership { disturb() }
        return verified
      },
      nowUTC: { nowUTC })
    return await observer.snapshot()
  }

  private func object(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let fields) = value else { throw CocoaError(.coderInvalidValue) }
    return fields
  }

  /// Runs one case, checks the decision it must reach, and records its input
  /// and its canonical answer.
  private func run(
    _ candidate: Case, availability: String, ownership: String, reasonCode: String,
    generation: JSONValue, processId: JSONValue, executableSHA256: JSONValue,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let snapshot = await Self.snapshot(candidate)
    let fields = try object(snapshot)
    XCTAssertEqual(Set(fields.keys), Self.members, candidate.name, file: file, line: line)
    XCTAssertEqual(
      fields["schemaVersion"], .string("arkdeck.runtime-hdc-status/1"), candidate.name,
      file: file, line: line)
    XCTAssertEqual(fields["availability"], .string(availability), candidate.name, file: file, line: line)
    XCTAssertEqual(fields["ownership"], .string(ownership), candidate.name, file: file, line: line)
    XCTAssertEqual(fields["reasonCode"], .string(reasonCode), candidate.name, file: file, line: line)
    XCTAssertEqual(fields["generation"], generation, candidate.name, file: file, line: line)
    XCTAssertEqual(fields["processId"], processId, candidate.name, file: file, line: line)
    XCTAssertEqual(
      fields["executableSHA256"], executableSHA256, candidate.name, file: file, line: line)
    // Never promoted from the startup cache, never invented.
    XCTAssertEqual(fields["serverVersion"], .null, candidate.name, file: file, line: line)
    XCTAssertEqual(fields["serverHealth"], .string("unknown"), candidate.name, file: file, line: line)
    XCTAssertEqual(
      fields["healthReasonCode"], .string("hdc.commandlessIdentityDoesNotProveHealth"),
      candidate.name, file: file, line: line)
    XCTAssertEqual(fields["newDispatchCount"], .integer(0), candidate.name, file: file, line: line)
    XCTAssertEqual(
      fields["clientVersion"], .null, "the driver's digest is not a registered one",
      file: file, line: line)
    let index = cases.count
    cases.append(Self.json(candidate))
    files[String(format: "snapshots/%02d-%@.json", index, candidate.name)] =
      try PortableCanonicalJSON.canonicalBytes(snapshot) + Data("\n".utf8)
  }

  /// Serializes every user of the fixed root, the Rust replay included.
  private static func lock() throws -> Int32 {
    let lock = open(root.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard lock >= 0 else { throw POSIXError(.EACCES) }
    guard flock(lock, LOCK_EX) == 0 else {
      close(lock)
      throw POSIXError(.EBUSY)
    }
    return lock
  }

  func testSwiftAnswersTheLiveHDCStatusAcrossItsDecisionTable() async throws {
    let manager = FileManager.default
    let lock = try Self.lock()
    defer { close(lock) }
    try? manager.removeItem(at: Self.root)
    defer { try? manager.removeItem(at: Self.root) }
    try manager.createDirectory(
      at: Self.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let hdc = Self.root.appending(path: "hdc")
    try HDCOracleFake.driver.write(to: hdc)
    guard chmod(hdc.path, 0o700) == 0 else { throw POSIXError(.EPERM) }
    let generation = JSONValue.string("100000023")
    let processId = JSONValue.integer(42)
    let digest = JSONValue.string(Self.driverSHA256)

    // 00: the daemon without a configured tool.
    var unconfigured = Self.base("unconfigured")
    unconfigured.executable = nil
    unconfigured.daemonVersion = nil
    try await run(
      unconfigured, availability: "unavailable", ownership: "unknown",
      reasonCode: "hdc.notConfigured", generation: .null, processId: .null,
      executableSHA256: .null)

    // 01: the managed server, observed as it was launched.
    let managed = Self.base("observed-managed")
    try await run(
      managed, availability: "available", ownership: "arkDeckManaged",
      reasonCode: "hdc.identityObserved", generation: generation, processId: processId,
      executableSHA256: digest)
    let managedFields = try object(await Self.snapshot(managed))
    let signature = try object(XCTUnwrap(managedFields["signature"]))
    XCTAssertEqual(
      signature,
      [
        "state": .string("unsigned"), "identifier": .null, "teamIdentifier": .null,
        "platformTrust": .string("unverified"), "executionAssessment": .string("notPerformed"),
      ], "the production signature inspection of the unsigned driver")

    // 02–04: observed, but ownership stays unproven — no launch record, the
    // live process not verified, the launch's birth not the observed one.
    var noLaunch = Self.base("observed-ownership-unproven-no-launch")
    noLaunch.launch = nil
    try await run(
      noLaunch, availability: "available", ownership: "unknown",
      reasonCode: "hdc.ownershipUnproven", generation: generation, processId: processId,
      executableSHA256: digest)
    var unverified = Self.base("observed-ownership-unproven-process-differs")
    unverified.managedProcessVerified = false
    try await run(
      unverified, availability: "available", ownership: "unknown",
      reasonCode: "hdc.ownershipUnproven", generation: generation, processId: processId,
      executableSHA256: digest)
    var reborn = Self.base("observed-ownership-unproven-birth-differs")
    reborn.launch = Self.launch(seconds: 101)
    try await run(
      reborn, availability: "available", ownership: "unknown",
      reasonCode: "hdc.ownershipUnproven", generation: generation, processId: processId,
      executableSHA256: digest)

    // 05–10: an observed identity that is not the selected tool at the
    // selected endpoint: availability stays unknown, nothing is claimed.
    var otherEndpoint = Self.base("observed-identity-mismatch-endpoint")
    otherEndpoint.identity = Self.receipt(endpoint: "127.0.0.1:8711")
    try await run(
      otherEndpoint, availability: "unknown", ownership: "unknown",
      reasonCode: "hdc.identityMismatch", generation: .null, processId: .null,
      executableSHA256: digest)
    var otherDigest = Self.base("observed-identity-mismatch-digest")
    otherDigest.identity = Self.receipt(sha256: String(repeating: "f", count: 64))
    try await run(
      otherDigest, availability: "unknown", ownership: "unknown",
      reasonCode: "hdc.identityMismatch", generation: .null, processId: .null,
      executableSHA256: digest)
    var otherPath = Self.base("observed-identity-mismatch-path")
    otherPath.identity = Self.receipt(path: Self.root.appending(path: "other-hdc").path)
    try await run(
      otherPath, availability: "unknown", ownership: "unknown",
      reasonCode: "hdc.identityMismatch", generation: .null, processId: .null,
      executableSHA256: digest)
    var otherGeneration = Self.base("observed-identity-mismatch-generation")
    otherGeneration.classification = .observed(generation: 7)
    try await run(
      otherGeneration, availability: "unknown", ownership: "unknown",
      reasonCode: "hdc.identityMismatch", generation: .null, processId: .null,
      executableSHA256: digest)
    var noIdentity = Self.base("observed-identity-missing")
    noIdentity.identity = nil
    try await run(
      noIdentity, availability: "unknown", ownership: "unknown",
      reasonCode: "hdc.identityMismatch", generation: .null, processId: .null,
      executableSHA256: digest)
    var zeroGeneration = Self.base("observed-generation-zero")
    zeroGeneration.classification = .observed(generation: 0)
    zeroGeneration.identity = Self.receipt(seconds: 0, microseconds: 0)
    try await run(
      zeroGeneration, availability: "unknown", ownership: "unknown",
      reasonCode: "hdc.identityMismatch", generation: .null, processId: .null,
      executableSHA256: digest)

    // 11–15: no observed identity.
    var unavailable = Self.base("unavailable")
    unavailable.classification = .unavailable(reason: "no process owns the endpoint")
    unavailable.identity = nil
    try await run(
      unavailable, availability: "unavailable", ownership: "unknown",
      reasonCode: "hdc.selectedServerNotObserved", generation: .null, processId: .null,
      executableSHA256: digest)
    var unsupported = Self.base("unsupported")
    unsupported.classification = .unsupported(
      reason: "selected executable or endpoint has no published commandless identity family")
    unsupported.identity = nil
    try await run(
      unsupported, availability: "unavailable", ownership: "unknown",
      reasonCode: "hdc.identityFamilyUnavailable", generation: .null, processId: .null,
      executableSHA256: digest)
    var timedOut = Self.base("timed-out")
    timedOut.classification = .timedOut
    timedOut.identity = nil
    try await run(
      timedOut, availability: "unknown", ownership: "unknown",
      reasonCode: "hdc.identityObservationTimedOut", generation: .null, processId: .null,
      executableSHA256: digest)
    var cancelled = Self.base("cancelled")
    cancelled.classification = .cancelled
    cancelled.identity = nil
    try await run(
      cancelled, availability: "unknown", ownership: "unknown",
      reasonCode: "hdc.identityObservationCancelled", generation: .null, processId: .null,
      executableSHA256: digest)
    var unknown = Self.base("unknown")
    unknown.classification = .unknown(reason: "observed identity does not match the selected tool and endpoint")
    unknown.identity = nil
    try await run(
      unknown, availability: "unknown", ownership: "unknown",
      reasonCode: "hdc.identityUnknown", generation: .null, processId: .null,
      executableSHA256: digest)

    // 16–19: the tool itself fails the observation — changed under the
    // identity read, changed under the ownership check, missing, or not the
    // configured digest. Every tool fact but the configured ones is withdrawn.
    var changedDuringRead = Self.base("tool-changed-during-observation")
    changedDuringRead.disturbance = .duringObservation
    try await run(
      changedDuringRead, availability: "unavailable", ownership: "unknown",
      reasonCode: "hdc.toolIdentityOrSignatureInvalid", generation: .null, processId: .null,
      executableSHA256: .null)
    var changedDuringOwnership = Self.base("tool-changed-during-ownership")
    changedDuringOwnership.disturbance = .duringOwnership
    try await run(
      changedDuringOwnership, availability: "unavailable", ownership: "unknown",
      reasonCode: "hdc.toolIdentityOrSignatureInvalid", generation: .null, processId: .null,
      executableSHA256: .null)
    var missing = Self.base("tool-missing")
    missing.executable = ResolvedExecutable(
      path: Self.root.appending(path: "absent-hdc").path, sha256: Self.driverSHA256)
    try await run(
      missing, availability: "unavailable", ownership: "unknown",
      reasonCode: "hdc.toolIdentityOrSignatureInvalid", generation: .null, processId: .null,
      executableSHA256: .null)
    var wrongDigest = Self.base("tool-digest-mismatch")
    wrongDigest.executable = ResolvedExecutable(
      path: Self.hdc.path, sha256: String(repeating: "0", count: 64))
    wrongDigest.startup = .init(
      executableSHA256: String(repeating: "0", count: 64), clientVersion: "cached-client",
      serverVersion: "cached-server", endpoint: Self.endpoint, endpointSource: "default")
    try await run(
      wrongDigest, availability: "unavailable", ownership: "unknown",
      reasonCode: "hdc.toolIdentityOrSignatureInvalid", generation: .null, processId: .null,
      executableSHA256: .null)

    // 20–21: the endpoint the daemon selected — explicit, and inherited from
    // `OHOS_HDC_SERVER_PORT` — names the server reference.
    var explicit = Self.base("explicit-endpoint-unavailable")
    explicit.startup = Self.startup(endpoint: "127.0.0.1:9000", source: "explicit")
    explicit.classification = .unavailable(reason: "no process owns the endpoint")
    explicit.identity = nil
    explicit.launch = nil
    try await run(
      explicit, availability: "unavailable", ownership: "unknown",
      reasonCode: "hdc.selectedServerNotObserved", generation: .null, processId: .null,
      executableSHA256: digest)
    var inherited = Self.base("inherited-endpoint-observed-unproven")
    inherited.startup = Self.startup(endpoint: "127.0.0.1:8720", source: "inheritedEnvironment")
    inherited.identity = Self.receipt(endpoint: "127.0.0.1:8720")
    inherited.launch = nil
    try await run(
      inherited, availability: "available", ownership: "unknown",
      reasonCode: "hdc.ownershipUnproven", generation: generation, processId: processId,
      executableSHA256: digest)
    let inheritedFields = try object(await Self.snapshot(inherited))
    let reference = inheritedFields["serverEndpointRef"]
    XCTAssertEqual(
      reference, .string("hdc-endpoint:" + SHA256Hex.string(of: Data("127.0.0.1:8720".utf8))))

    XCTAssertEqual(cases.count, 22)
    try record()
  }

  private func record() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    files["cases.json"] = try encoder.encode(JSONValue.array(cases)) + Data("\n".utf8)
    var digests: [String: JSONValue] = [:]
    for (path, data) in files { digests[path] = .string(SHA256Hex.string(of: data)) }
    let provenance: [String: JSONValue] = [
      "producer": .string(
        "HDCStatusOracleContractTests.testSwiftAnswersTheLiveHDCStatusAcrossItsDecisionTable"),
      "root": .string(Self.root.path),
      "executablePath": .string(Self.hdc.path),
      "hdcSHA256": .string(Self.driverSHA256),
      "nowUTC": .string(Self.nowUTC),
      "daemonVersion": .string(Self.daemonVersion),
      "schemaVersion": .string("arkdeck.runtime-hdc-status/1"),
      // The published identity families the production observer gates on;
      // the driver belongs to neither, so no case can carry a client version.
      "registeredIdentities": .array([
        .object([
          "family": .string("readOnlyProbeRegistry"),
          "toolVersion": .string(HDCReadOnlyProbeRegistry.targetToolVersion),
          "executableSHA256": .string(HDCReadOnlyProbeRegistry.targetExecutableSHA256),
        ]),
        .object([
          "family": .string("supervisorObservationProbeCatalog"),
          "toolVersion": .string(HDCSupervisorObservationProbeCatalog.targetToolVersion),
          "executableSHA256": .string(HDCSupervisorObservationProbeCatalog.targetExecutableSHA256),
          "exactEndpoint": .string(HDCSupervisorObservationProbeCatalog.exactEndpoint),
          "timeoutMilliseconds": .integer(
            Int64(HDCSupervisorObservationProbeCatalog.timeoutMilliseconds)),
        ]),
      ]),
      "files": .object(digests),
    ]
    files["provenance.json"] =
      try encoder.encode(JSONValue.object(provenance)) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.recordVariable, oracle: Self.oracle)
  }
}

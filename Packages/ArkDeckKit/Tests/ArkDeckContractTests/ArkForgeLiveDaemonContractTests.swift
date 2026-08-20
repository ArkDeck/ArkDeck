import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows
@testable import ArkForgeIPC

/// ArkDeck driving a live `arkforged`, which is the only place the last mile
/// can be tested at all.
///
/// ArkForge's own `arkforge-rehearse` imports the real archive, materializes
/// the real plan and lowers all nine writes to argv — and then stops, because
/// a write needs a StepPermit, a permit needs an authority, and ArkForge's
/// architecture guard forbids `arkforged` from even naming the minting
/// function. So everything past the permit exists only when an authority
/// drives it: a disagreement between ArkDeck's signer and ArkForge's verifier
/// is invisible to either repository's own test suite, however green both are.
///
/// Gated on a socket rather than starting a daemon here. The daemon needs
/// deployed artifacts, and a test that installed them would be a test that
/// decided what to install — which is the operator's call, and is what
/// `ArkForgeLaneInstallContractTests` covers separately.
///
/// Nothing in this file is permitted to reach a write. Every case either stops
/// before `startExecution` succeeds or refuses the admission, because a
/// validation run that flashed a board would be the exact confusion — message
/// accepted read as device changed — this lane exists to prevent.
final class ArkForgeLiveDaemonContractTests: XCTestCase {

  private static let socketKey = "ARKDECK_ARKFORGE_LIVE_SOCKET"
  private static let daemonSHAKey = "ARKDECK_ARKFORGED_SHA256"

  private func liveClient(
    timeoutSeconds: Int = 30
  ) throws -> ArkForgeDaemonClient {
    guard let socket = ProcessInfo.processInfo.environment[Self.socketKey] else {
      throw XCTSkip(
        "set \(Self.socketKey) to a running arkforged controller.sock to run the live tests")
    }
    return try ArkForgeDaemonClient(socketPath: socket, timeoutSeconds: timeoutSeconds)
  }

  /// The USB location id of the board this bench runs against, when one is
  /// attached. `ioreg -p IOUSB -l | grep locationID` for the DAYU200.
  private static let topologyKey = "ARKDECK_ARKFORGE_LIVE_USB_TOPOLOGY"

  // MARK: - The device join, checked against the daemon's own digest

  /// The one cross-implementation fact the observation join rests on.
  ///
  /// `ArkForgeObservationSelection` recomputes, in Swift, the digest the
  /// daemon computes in Rust over the same port path. If the two disagreed,
  /// selection would never match anything — and it would fail as "the daemon
  /// cannot see the bound device", which points an operator at the cable
  /// rather than at the code. So this asserts the digests agree on bytes a
  /// running daemon produced, the same way the permit vectors do.
  func testTheTopologyDigestAgreesWithTheDaemons() throws {
    let client = try liveClient()
    guard let topology = ProcessInfo.processInfo.environment[Self.topologyKey] else {
      throw XCTSkip("set \(Self.topologyKey) to the attached board's USB locationID")
    }
    let observations = try client.discoverDevices(requestID: "live-discover")
    XCTAssertFalse(
      observations.isEmpty,
      "the daemon observed nothing; it needs a USB transport (AD-027) and a board attached")

    let computed = try XCTUnwrap(
      ArkForgeObservationSelection.topologyDigest(usbTopology: topology))
    XCTAssertTrue(
      observations.contains { $0.topologyDigest.lowercased() == computed },
      """
      no observation carries the digest this side computed for port \(topology).
        computed: \(computed)
        observed: \(observations.map { "\($0.observationID)=\($0.topologyDigest)" })
      The two implementations disagree about the same physical fact.
      """)
  }

  func testSelectionFindsExactlyTheBoundDevice() throws {
    let client = try liveClient()
    guard let topology = ProcessInfo.processInfo.environment[Self.topologyKey] else {
      throw XCTSkip("set \(Self.topologyKey) to the attached board's USB locationID")
    }
    let observations = try client.discoverDevices(requestID: "live-discover-select")
    switch ArkForgeObservationSelection.select(
      observations: observations, usbTopology: topology)
    {
    case .success(let observation):
      XCTAssertEqual(
        observation.topologyDigest.lowercased(),
        ArkForgeObservationSelection.topologyDigest(usbTopology: topology))
    case .failure(let why):
      XCTFail("\(why)")
    }
  }

  func testLiveDualSourceLoaderObservationMatchesTheBoundBoard() throws {
    guard let socket = ProcessInfo.processInfo.environment[Self.socketKey],
      let topology = ProcessInfo.processInfo.environment[Self.topologyKey],
      let stableIdentity = ProcessInfo.processInfo.environment[
        "ARKDECK_ARKFORGE_LIVE_STABLE_IDENTITY_SHA256"]
    else {
      throw XCTSkip(
        "set \(Self.socketKey), \(Self.topologyKey), and "
          + "ARKDECK_ARKFORGE_LIVE_STABLE_IDENTITY_SHA256 for the attached Loader")
    }
    let observer = ProductArkForgeLoaderObserver(
      runtimeDirectory: URL(filePath: socket).deletingLastPathComponent())

    let identity = try observer.observeLoader(
      stableIdentitySHA256: stableIdentity,
      expectedUSBTopology: topology,
      requestID: "live-dual-source-loader")

    XCTAssertEqual(identity.serialDigestSHA256, stableIdentity)
    XCTAssertEqual(identity.topology, topology)
  }

  // MARK: - The whole chain, against a real daemon and a real board

  /// Import → inspect → discover → select → materialize, end to end.
  ///
  /// This is the case that says whether ArkDeck can flash at all. Three
  /// findings had to be closed before it could pass, and each was invisible
  /// from inside one repository:
  ///
  /// - **AD-025**: only `productionVerified` could back an executable plan,
  ///   and that state is defined by a flash that would itself need one. The
  ///   daemon must be started `--hardware-campaign <id>`.
  /// - **AD-027**: `arkforged` held only transcript transports, so it saw no
  ///   device to materialize against however many were attached.
  /// - **AD-026**: nothing in ArkDeck had ever put a plan in the daemon's
  ///   store, because the client had neither call.
  ///
  /// Read-only. Materialization probes the device and builds a plan; it writes
  /// nothing, and this case deliberately stops before `startExecution`.
  func testTheWholeMaterializationChainProducesAnExecutablePlan() throws {
    let client = try liveClient(
      timeoutSeconds: ArkForgeDaemonClient.materializationTimeoutSeconds)
    guard let archive = ProcessInfo.processInfo.environment["ARKDECK_DAYU200_ARCHIVE"],
      let digest = ProcessInfo.processInfo.environment["ARKDECK_DAYU200_ARCHIVE_SHA256"],
      let topology = ProcessInfo.processInfo.environment[Self.topologyKey],
      let profileID = ProcessInfo.processInfo.environment["ARKDECK_ARKFORGE_PROFILE_ID"],
      let stableIdentity = ProcessInfo.processInfo.environment[
        "ARKDECK_ARKFORGE_LIVE_STABLE_IDENTITY_SHA256"],
      let stableIdentityBytes = ArkForgeLaneHost.digestBytes(stableIdentity)
    else {
      throw XCTSkip(
        "set ARKDECK_DAYU200_ARCHIVE, ARKDECK_DAYU200_ARCHIVE_SHA256, \(Self.topologyKey) "
          + "and ARKDECK_ARKFORGE_PROFILE_ID to run the full chain")
    }

    if (try? client.inspectArtifact(artifactID: digest, requestID: "live-inspect")) == nil {
      let imported = try client.importArtifact(
        contentsOf: URL(filePath: archive), expectedSHA256: digest,
        requestID: "live-import")
      XCTAssertEqual(
        imported.artifactID, digest,
        "the store is content-addressed; the id it returns is the digest it measured")
      _ = try client.inspectArtifact(artifactID: digest, requestID: "live-inspect-2")
    }

    let observations = try client.discoverDevices(requestID: "live-discover-chain")
    let observation: ArkForgeDeviceObservation
    switch ArkForgeObservationSelection.select(
      observations: observations, usbTopology: topology)
    {
    case .success(let selected): observation = selected
    case .failure(let why): return XCTFail("\(why)")
    }

    let answer = try client.materializePlan(
      ArkForgeMaterializePlanRequest(
        artifactID: digest, profileID: profileID, observationID: observation.observationID,
        intent: "fullRestore", toolchainID: "arkforged-native-rockusb",
        authorityNamespace: "arkdeck", bindingID: "LIVE-DAYU200",
        bindingRevision: 1, stableIdentitySHA256: stableIdentityBytes,
        executionPurpose: "primaryFlash"),
      requestID: "live-materialize")
    switch answer {
    case .plan(let plan):
      XCTAssertFalse(plan.planID.isEmpty)
      XCTAssertEqual(plan.planSHA256.count, 64, "a plan digest is 64 hex characters")
      // The two strings `startExecution` needs. Before this change the engine
      // sent its own operation name and its own plan digest, and the daemon
      // answered PLAN_NOT_STARTABLE for a plan it had never been given.
      print("materialized planID=\(plan.planID) planSHA256=\(plan.planSHA256)")
    case .assessment(let assessment):
      XCTFail(
        """
        the daemon materialized an assessment rather than an executable plan.
          availability: \(assessment.availability)
          reason:       \(assessment.unavailableReason)
          unknowns:     \(assessment.unknowns)
        A maturity blocker here means the daemon was not started with \
        --hardware-campaign; any other blocker is a profile or artifact fault.
        """)
    }
  }

  // MARK: - The standing facts, measured rather than captured

  /// The golden frames in `ArkForgeIPCContractTests` prove the codec against
  /// bytes a daemon once produced. This proves the same two facts against a
  /// daemon running *now*, on the artifacts an operator actually deployed —
  /// which is a different claim, and the one that matters before a board.
  func testALiveDaemonReportsTheReadinessTheLaneRequires() throws {
    let client = try liveClient()
    let ack = client.helloAck
    guard let daemonSHA256 = ProcessInfo.processInfo.environment[Self.daemonSHAKey] else {
      throw XCTSkip(
        "set \(Self.daemonSHAKey) to the identity-bound arkforged executable digest")
    }
    let expected = ArkForgeLaneComposition.ToolchainIdentity(
      id: "arkforged-native-rockusb", sha256: daemonSHA256)

    XCTAssertEqual(ack.sessionKind, .controller)
    XCTAssertTrue(
      ack.executionReady,
      "the deployed daemon is not execution-ready: \(ack.executionBlockers)")
    XCTAssertTrue(ack.executionBlockers.isEmpty)
    XCTAssertNoThrow(
      try ArkForgeLaneHost.verifyReadiness(ack, expectedToolchain: expected),
      "the lane refuses a daemon this deployment produced")
    XCTAssertEqual(ack.toolchainID, "arkforged-native-rockusb")
    XCTAssertEqual(ack.toolchainSHA256, daemonSHA256.lowercased())
  }

  // MARK: - The plan identity the engine actually sends

  /// The identity `startExecution` is given now comes from the daemon.
  ///
  /// This case was red from the moment it was written, and its failure named
  /// AD-026: the engine sent `planID: request.operation` and
  /// `planSHA256: materializedPlanDigest` — facts about the plan **ArkDeck**
  /// materialized — to a daemon that resolves plans from its own store, and
  /// got `PLAN_NOT_STARTABLE: no stored plan flash.dayu200`.
  ///
  /// It passes by materializing first, which is what the lane now does.
  ///
  /// # This does not flash
  ///
  /// `startExecution` creates a job; it dispatches nothing. Dispatch needs a
  /// StepPermit, no permit is signed here, and the job is cancelled before the
  /// first admission can be answered. `cancelledSafe` is the daemon's own word
  /// for "no tool was ever spawned" — a stronger statement than "the process
  /// group was torn down", and the only acceptable outcome for a test.
  func testAMaterializedPlanIdentityStartsAJob() throws {
    let client = try liveClient(
      timeoutSeconds: ArkForgeDaemonClient.materializationTimeoutSeconds)
    guard let digest = ProcessInfo.processInfo.environment["ARKDECK_DAYU200_ARCHIVE_SHA256"],
      let topology = ProcessInfo.processInfo.environment[Self.topologyKey],
      let profileID = ProcessInfo.processInfo.environment["ARKDECK_ARKFORGE_PROFILE_ID"],
      let stableIdentity = ProcessInfo.processInfo.environment[
        "ARKDECK_ARKFORGE_LIVE_STABLE_IDENTITY_SHA256"],
      let stableIdentityBytes = ArkForgeLaneHost.digestBytes(stableIdentity)
    else {
      throw XCTSkip("needs the archive digest, the USB topology and the profile id")
    }
    // The artifact must already be in the store; the chain case puts it there.
    guard (try? client.inspectArtifact(artifactID: digest, requestID: "start-inspect")) != nil
    else {
      throw XCTSkip("import the archive first — see the materialization chain case")
    }

    let observations = try client.discoverDevices(requestID: "start-discover")
    guard
      case .success(let observation) = ArkForgeObservationSelection.select(
        observations: observations, usbTopology: topology)
    else {
      return XCTFail("the daemon cannot see the board at port \(topology)")
    }
    guard
      case .plan(let plan) = try client.materializePlan(
        ArkForgeMaterializePlanRequest(
          artifactID: digest, profileID: profileID, observationID: observation.observationID,
          intent: "fullRestore", toolchainID: "arkforged-native-rockusb",
          authorityNamespace: "arkdeck", bindingID: "LIVE-DAYU200",
          bindingRevision: 1, stableIdentitySHA256: stableIdentityBytes,
          executionPurpose: "primaryFlash"),
        requestID: "start-materialize")
    else {
      return XCTFail("no executable plan; the daemon needs --hardware-campaign")
    }

    let started = try client.startExecution(
      ArkForgeStartExecutionRequest(
        planID: plan.planID, planSHA256: plan.planSHA256, executionPurpose: "primaryFlash",
        controllerSessionID: "arkdeck-live-contract"),
      requestID: "start-execution")
    XCTAssertFalse(started.jobID.isEmpty, "a materialized plan must be startable")

    let cancelled = try client.cancelJob(jobID: started.jobID, requestID: "start-cancel")
    XCTAssertEqual(
      cancelled.cancellationState, "cancelledSafe",
      "nothing may have been dispatched: no permit was signed")
  }

}

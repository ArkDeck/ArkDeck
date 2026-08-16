import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkForgeIPC

/// The IPC codec against bytes a real `arkforged` produced.
///
/// The golden frames below were captured on 2026-08-16 from ArkForge
/// `d637a2e`+ running with the bundled Rockchip component
/// (`231a05ef…`, see AD-023) — not hand-assembled from the `.proto`. That
/// distinction matters: a codec tested only against its own encoder agrees
/// with itself, and the failure this repository has to avoid is an authority
/// that speaks a dialect the daemon does not.
///
/// `AFA-AC-2` covers the permit bytes; this file covers the envelope that
/// carries them.
final class ArkForgeIPCContractTests: XCTestCase {

  private func bytes(_ hex: String) -> Data {
    var out = [UInt8]()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      out.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
    return Data(out)
  }

  // MARK: - Golden frames from a live daemon

  /// A daemon with a tool bound and no authority paired.
  private static let helloAckHex =
    "080118022205302e312e303a134e4f5f5041495245445f415554484f52495459420d726b6465"
    + "76656c6f70746f6f6c4a40323331613035656639616165313766396338623864333830316233"
    + "65633266346134363533323931373832303231666536353531373631306161313163373965"

  func testHelloAckFromALiveDaemonDecodes() throws {
    let ack = try ArkForgeHelloAck.decode(bytes(Self.helloAckHex))

    XCTAssertEqual(ack.protocolMajor, 1)
    // Minor 0 is a proto3 default and is absent from the bytes. Reading it as
    // anything but 0 would mean the decoder invented a value.
    XCTAssertEqual(ack.protocolMinor, 0)
    XCTAssertEqual(ack.sessionKind, .controller)
    XCTAssertEqual(ack.daemonVersion, "0.1.0")
    XCTAssertNil(ack.refusal)

    // The two standing facts, and the reason they are two: a tool is bound
    // (so `toolchain_sha256` is populated) but no authority is paired, so
    // nothing can execute. A client reading only `executionReady` would learn
    // "no" without learning which of the two is missing.
    XCTAssertFalse(ack.executionReady)
    XCTAssertEqual(ack.executionBlockers, ["NO_PAIRED_AUTHORITY"])
    XCTAssertEqual(ack.toolchainID, "rkdeveloptool")
    XCTAssertEqual(
      ack.toolchainSHA256,
      "231a05ef9aae17f9c8b8d3801b3ec2f4a4653291782021fe65517610aa11c79e",
      "the daemon reports the bundled component this change pins (AD-023)")
  }

  func testAnOKResponseFromALiveDaemonDecodes() throws {
    // discoverDevices with no transport: OK, empty payload, stream ended.
    let response = try ArkForgeResponse.decode(bytes("0a055245512d31100318013001"))
    XCTAssertEqual(response.requestID, "REQ-1")
    XCTAssertEqual(response.api, .discoverDevices)
    XCTAssertEqual(response.status, .ok)
    XCTAssertTrue(response.streamEnd)
    XCTAssertEqual(response.streamSequence, 0)
    XCTAssertNil(try response.errorBody())
  }

  func testStartExecutionRefusalCarriesItsStableCode() throws {
    let hex =
      "0a055245512d321006180322cf010a134e4f5f5041495245445f415554484f5249545912b701"
      + "4e4f5f5041495245445f415554484f524954593a206e6f20617574686f72697479206973207061"
      + "6972656420776974682074686973206461656d6f6e2c20736f206120537465705065726d697420"
      + "63616e6e6f7420626520766572696669656420616761696e737420612070616972696e67207365"
      + "6372657420616e64206e6f2073657373696f6e2063616e207265636569766520697473207265636"
      + "56970747320286172636869746563747572652e6d6420382e36293001"
    let response = try ArkForgeResponse.decode(bytes(hex))
    XCTAssertEqual(response.api, .startExecution)
    XCTAssertEqual(response.status, .unavailable)

    let error = try XCTUnwrap(try response.errorBody())
    XCTAssertEqual(error.code, "NO_PAIRED_AUTHORITY")
    XCTAssertTrue(error.message.contains("StepPermit"))
    // The refusal happens before the payload is parsed — it is a standing fact
    // about the daemon, not a fact about this request. An empty payload still
    // gets the same answer, which is what this capture is.
  }

  // MARK: - Encoder agreement

  func testHelloEncodesToTheBytesTheDaemonAccepted() {
    // The exact four bytes the live capture sent and the daemon answered.
    // Minor 0 is omitted: proto3 does not write defaults, and a Hello that
    // wrote `10 00` would still be legal but would not be these bytes.
    XCTAssertEqual(
      Array(ArkForgeHello(sessionKind: .controller).encoded), [0x08, 0x01, 0x18, 0x02])
    XCTAssertEqual(
      Array(ArkForgeHello(sessionKind: .publicSession).encoded), [0x08, 0x01, 0x18, 0x01])
  }

  func testRequestEncodesToTheBytesTheDaemonAccepted() {
    let request = ArkForgeRequest(requestID: "REQ-1", api: .discoverDevices, payload: Data())
    XCTAssertEqual(
      Array(request.encoded), [0x0a, 0x05] + Array("REQ-1".utf8) + [0x10, 0x03])
  }

  // MARK: - Fail-closed rules

  func testAnUnknownEnumValueIsRefusedRatherThanDefaulted() {
    // architecture.md 15.2. A daemon answering with a status this build has
    // never heard of must not read as STATUS_UNSPECIFIED — that would turn an
    // unknown outcome into a zero value and lose the refusal.
    let unknownStatus = Data([0x18, 0x63])  // field 3, varint 99
    XCTAssertThrowsError(try ArkForgeResponse.decode(unknownStatus)) { error in
      guard case ProtobufWireError.unknownEnumValue(let message, let field, let value) = error
      else { return XCTFail("expected an unknown-enum refusal, got \(error)") }
      XCTAssertEqual(message, "Response")
      XCTAssertEqual(field, 3)
      XCTAssertEqual(value, 99)
    }
  }

  func testAnUnknownFieldIsSkippedRatherThanRefused() {
    // The other half of IPC-001: a new field added by a later daemon is
    // additive, and refusing it would make every forward-compatible change a
    // breaking one. Field 99, length-delimited, is not in the schema.
    var frame = Array(ArkForgeHello(sessionKind: .controller).encoded)
    frame.append(contentsOf: [0xfa, 0x06, 0x03, 0x61, 0x62, 0x63])  // field 99: "abc"
    frame.append(contentsOf: [0x22, 0x05] + Array("0.1.0".utf8))  // daemon_version
    let ack = try? ArkForgeHelloAck.decode(Data(frame))
    XCTAssertEqual(ack?.daemonVersion, "0.1.0")
    XCTAssertEqual(ack?.sessionKind, .controller)
  }

  func testAMalformedVarintIsRefusedRatherThanWrapping() {
    // Ten continuation bytes would shift past 64 bits. Wrapping silently is
    // how a length or a sequence number becomes a different number.
    let malformed = Data([0x08] + [UInt8](repeating: 0xff, count: 12))
    XCTAssertThrowsError(try ArkForgeResponse.decode(malformed)) { error in
      XCTAssertEqual(error as? ProtobufWireError, .malformedVarint)
    }
  }

  func testALengthThatOverrunsTheBufferIsRefusedBeforeAllocation() {
    // Field 1, length-delimited, claiming 300 bytes in a 4-byte message.
    let overrun = Data([0x0a, 0xac, 0x02, 0x00])
    XCTAssertThrowsError(try ArkForgeResponse.decode(overrun)) { error in
      XCTAssertEqual(error as? ProtobufWireError, .truncated)
    }
  }

  func testInvalidUTF8IsRefusedRatherThanReplaced() {
    // Lossy conversion would turn a corrupted request id into a plausible one.
    let invalid = Data([0x0a, 0x02, 0xff, 0xfe])
    XCTAssertThrowsError(try ArkForgeResponse.decode(invalid)) { error in
      XCTAssertEqual(error as? ProtobufWireError, .invalidUTF8(field: 1))
    }
  }

  func testTheFrameLimitMatchesTheDaemons() {
    // A mismatch shows up as one side refusing frames the other considers
    // legal, which is a confusing failure far from its cause.
    XCTAssertEqual(ArkForgeFraming.maxFrameBytes, 16 * 1024 * 1024)
  }

  // MARK: - Permit submission

  func testAPermitSubmissionCarriesTheSignedBytesUnchanged() {
    // The permit travels as the exact canonical CBOR the authority signed. A
    // permit re-encoded by a second codec is a different permit, and "the same
    // permit" is what the integrity tag exists to pin down (architecture.md 8.6).
    let signed = Data([0xa1, 0x61, 0x61, 0x01])
    let tag = [UInt8](repeating: 0xab, count: 32)
    let request = ArkForgeSubmitStepPermitRequest(
      jobID: "JOB-1", requestID: "ADM-1", permitCBOR: signed, integrityTag: tag,
      pairingEpoch: 7)
    let encoded = Array(request.encoded)

    // Field 3 is the permit bytes, verbatim and length-prefixed.
    let marker: [UInt8] = [0x1a, UInt8(signed.count)] + Array(signed)
    XCTAssertTrue(
      encoded.indices.contains(where: { index in
        Array(encoded[index...].prefix(marker.count)) == marker
      }), "the signed CBOR must appear in the frame unmodified")
    XCTAssertNil(request.refusal)
  }

  func testARefusalIsAnAnswerAndCarriesNoPermit() {
    // Silence and refusal are different things to the daemon: a refusal goes
    // to CancelledSafe, silence lets the snapshot expire and admission runs
    // again (design §3.3).
    let request = ArkForgeSubmitStepPermitRequest(
      jobID: "JOB-1", requestID: "ADM-1", refusal: "binding revision moved")
    XCTAssertEqual(request.refusal, "binding revision moved")
    XCTAssertTrue(request.permitCBOR.isEmpty)
    XCTAssertTrue(request.integrityTag.isEmpty)
    XCTAssertEqual(request.pairingEpoch, 0)
  }

  // MARK: - Admission snapshot freshness

  func testAnExpiredSnapshotIsNotFresh() {
    // Signing a stale snapshot wastes a round-trip and tells the daemon this
    // authority is not checking: past the lifetime it takes a new snapshot
    // rather than accepting a late permit (architecture.md 8.3).
    let snapshot = ArkForgeStepAdmissionSnapshot(
      jobID: "JOB-1", planID: "PLAN-1", planSHA256: [], stepID: "STEP-1", attemptID: "A-1",
      publicStepSHA256: [], privateActionSHA256: [], effectSetSHA256: [],
      admittedDeviceFactsSHA256: [], observedMode: "loader",
      observedAtEpochMs: 1_000_000, snapshotLifetimeMs: 60_000, requestID: "ADM-1")

    XCTAssertTrue(snapshot.isFresh(atEpochMs: 1_000_000))
    XCTAssertTrue(snapshot.isFresh(atEpochMs: 1_060_000))
    XCTAssertFalse(snapshot.isFresh(atEpochMs: 1_060_001))
    // A clock that went backwards is not freshness either.
    XCTAssertFalse(snapshot.isFresh(atEpochMs: 999_999))
  }
}

/// The toolchain choice AD-023 forced, asserted rather than commented.
final class ArkForgeToolchainPinContractTests: XCTestCase {

  func testThePinIsTheSignedBundledComponent() {
    // The signed component in the app bundle, not the unsigned ingest the
    // package record carries. `arkforged` hashes the file it executes.
    XCTAssertTrue(SHA256Hex.isLowercaseSHA256(ArkForgeToolchainPin.signedSHA256))
    XCTAssertTrue(SHA256Hex.isLowercaseSHA256(ArkForgeToolchainPin.unsignedSHA256))
    XCTAssertNotEqual(
      ArkForgeToolchainPin.signedSHA256, ArkForgeToolchainPin.unsignedSHA256,
      "signing changes the bytes; pinning the wrong one refuses at daemon startup")
  }

  func testThePinAgreesWithTheComponentPackageRecord() throws {
    // The unsigned half has an authoritative source in this repository, so it
    // is read rather than trusted. A component rebuild that changed it without
    // this constant moving would leave the two silently disagreeing.
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let record = repoRoot.appending(
      path: "openspec/integrations/rockchip/bundled-component/1.0.0/package.json")
    let json =
      try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any]
    let component = try XCTUnwrap(json?["component"] as? [String: Any])

    XCTAssertEqual(component["sha256"] as? String, ArkForgeToolchainPin.unsignedSHA256)
    XCTAssertEqual(component["unsigned"] as? Bool, true)
    XCTAssertEqual(component["bundlePath"] as? String, ArkForgeToolchainPin.bundleRelativePath)
    XCTAssertEqual(
      Set(try XCTUnwrap(component["dependencies"] as? [String])),
      ArkForgeToolchainPin.permittedDependencies,
      "AD-023 turns on this list: the rejected build linked Homebrew's libusb")
  }

  func testTheRejectedBuildsAreNamedRatherThanJustRefused() {
    // Three digests, three different fixes. A bare "mismatch" sends an
    // operator to compare hex strings; these send them to the cause.
    XCTAssertNil(
      ArkForgeToolchainPin.mismatchExplanation(
        reportedSHA256: ArkForgeToolchainPin.signedSHA256))

    let homebrew = ArkForgeToolchainPin.mismatchExplanation(
      reportedSHA256: "bbd7bdc0fb121d414fb61085e77211cc1fdd9a3b6c6b285c54380f70e56c9923")
    XCTAssertEqual(homebrew?.contains("quarantine"), true)

    let localBuild = ArkForgeToolchainPin.mismatchExplanation(
      reportedSHA256: "038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611")
    XCTAssertEqual(localBuild?.contains("libusb"), true)

    let unsigned = ArkForgeToolchainPin.mismatchExplanation(
      reportedSHA256: ArkForgeToolchainPin.unsignedSHA256)
    XCTAssertEqual(unsigned?.contains("unsigned ingest"), true)

    XCTAssertEqual(
      ArkForgeToolchainPin.mismatchExplanation(reportedSHA256: "")?.contains("no tool bound"),
      true)
  }

  func testTheLiveDaemonHandshakeMatchesThePin() throws {
    // The captured HelloAck above came from a daemon started with this exact
    // pin, so the two must agree — this is the assertion that would have
    // failed had the rehearsal build been kept.
    let ack = try ArkForgeHelloAck.decode(bytes(Self.helloAckHexForPinTest))
    XCTAssertEqual(ack.toolchainID, ArkForgeToolchainPin.toolchainID)
    XCTAssertTrue(ArkForgeToolchainPin.matchesPin(reportedSHA256: ack.toolchainSHA256))
    XCTAssertNil(ArkForgeToolchainPin.mismatchExplanation(reportedSHA256: ack.toolchainSHA256))
  }

  private static let helloAckHexForPinTest =
    "080118022205302e312e303a134e4f5f5041495245445f415554484f52495459420d726b6465"
    + "76656c6f70746f6f6c4a40323331613035656639616165313766396338623864333830316233"
    + "65633266346134363533323931373832303231666536353531373631306161313163373965"

  private func bytes(_ hex: String) -> Data {
    var out = [UInt8]()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      out.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
    return Data(out)
  }
}

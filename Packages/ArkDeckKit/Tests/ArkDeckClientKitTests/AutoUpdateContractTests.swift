import ArkDeckCore
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import ArkDeckClientKit

struct AutoUpdateContractTests {
  private let now = ISO8601Timestamps.parseCanonicalPlain("2026-07-24T00:00:00Z")!

  /// The UI fixture exists so the Settings scene can be rendered by a test
  /// without the real updater deciding what it shows. The property that
  /// matters is the boundary: a launch that does not ask for it gets nothing,
  /// so no production run can render a declared update state.
  @Test func theUpdateUIFixtureIsUnreachableWithoutItsOwnArgument() {
    #expect(!AutoUpdateUIFixture.isSelected(arguments: []))
    #expect(AutoUpdateUIFixture.state(arguments: []) == nil)
    #expect(
      !AutoUpdateUIFixture.isSelected(arguments: [
        "/Applications/ArkDeck.app", "--ui-test-hdc-diagnostics", "--ui-test-runtime-history",
      ]),
      "another surface's fixture must not select this one")
    #expect(
      AutoUpdateUIFixture.state(arguments: ["--arkdeck-hdc-user-configured-path", "/usr/bin/true"])
        == nil)

    #expect(AutoUpdateUIFixture.state(arguments: ["--ui-test-auto-update-idle"]) == .idle)
    #expect(
      AutoUpdateUIFixture.state(arguments: ["--ui-test-auto-update-failed"]) == .failed(.feed))
    // An argument in the family but with no state of its own still selects the
    // fixture, so a launch can never fall back to the real updater by typo.
    #expect(AutoUpdateUIFixture.state(arguments: ["--ui-test-auto-update"]) == .idle)
  }

  @Test func TEST_AU_CONTRACT_001_productionTrustPinAndValidFeed() throws {
    let trust = try UpdateFeedTrust.production
    #expect(trust.keyID == "arkdeck-update-2026-07-b949b102")
    #expect(
      trust.rawPublicKey.base64EncodedString()
        == "c5Ho0xkWFQ3Ovzjx98dQhF3n5sytJjffqD3a+ftgP8c=")
    let spkiPrefix = Data([
      0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
    ])
    #expect(
      UpdateFeedCodec.sha256(spkiPrefix + trust.rawPublicKey)
        == UpdateFeedTrust.productionSPKISHA256)

    let fixture = try signedFixture()
    let result = try verifier(trust: fixture.trust).verify(
      fixture.envelope, context: verificationContext(), now: now)
    guard case .update(let verified) = result else {
      Issue.record("expected a verified update")
      return
    }
    #expect(verified.payload.version == "2.0.0")
    #expect(verified.payloadSHA256 == UpdateFeedCodec.sha256(fixture.payload))
  }

  @Test func TEST_AU_CONTRACT_001_feedSignatureAndCanonicalShapeFailClosed() throws {
    let signingKey = Curve25519.Signing.PrivateKey()
    let fixture = try signedFixture(privateKey: signingKey)

    var brokenSignature = fixture.signature
    brokenSignature[0] ^= 0xff
    assertFeedError(
      try UpdateFeedCodec.assemble(
        canonicalPayload: fixture.payload, signature: brokenSignature,
        keyID: fixture.trust.keyID),
      trust: fixture.trust, expected: .invalidSignature)

    let wrongSigner = Curve25519.Signing.PrivateKey()
    let wrongSignature = try wrongSigner.signature(
      for: UpdateFeedCodec.signatureInput(
        payload: fixture.payload, keyID: fixture.trust.keyID))
    assertFeedError(
      try UpdateFeedCodec.assemble(
        canonicalPayload: fixture.payload, signature: wrongSignature,
        keyID: fixture.trust.keyID),
      trust: fixture.trust, expected: .invalidSignature)

    let missingSignature = Data(
      """
      {"keyId":"\(fixture.trust.keyID)","payload":"\(fixture.payload.base64EncodedString())","schemaVersion":1}
      """.utf8)
    assertFeedError(missingSignature, trust: fixture.trust, expected: .malformedEnvelope)

    let wrongKey = try UpdateFeedCodec.assemble(
      canonicalPayload: fixture.payload, signature: fixture.signature,
      keyID: "unknown-update-key")
    assertFeedError(wrongKey, trust: fixture.trust, expected: .unknownKey)

    var nonCanonical = fixture.envelope
    nonCanonical.append(0x0a)
    assertFeedError(nonCanonical, trust: fixture.trust, expected: .nonCanonicalEnvelope)

    var object = try #require(
      try JSONSerialization.jsonObject(with: fixture.envelope) as? [String: Any])
    object["unknown"] = true
    let unknownMember = try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    assertFeedError(unknownMember, trust: fixture.trust, expected: .nonCanonicalEnvelope)

    let duplicateMember = Data(
      String(decoding: fixture.envelope, as: UTF8.self)
        .replacingOccurrences(of: #"{"keyId":"#, with: #"{"schemaVersion":1,"keyId":"#)
        .utf8)
    assertFeedError(duplicateMember, trust: fixture.trust, expected: .nonCanonicalEnvelope)

    var payloadObject = try #require(
      try JSONSerialization.jsonObject(with: fixture.payload) as? [String: Any])
    payloadObject["unknown"] = true
    let unknownPayload = try JSONSerialization.data(
      withJSONObject: payloadObject, options: [.sortedKeys, .withoutEscapingSlashes])
    let unknownPayloadSignature = try signingKey.signature(
      for: UpdateFeedCodec.signatureInput(
        payload: unknownPayload, keyID: fixture.trust.keyID))
    assertFeedError(
      try UpdateFeedCodec.assemble(
        canonicalPayload: unknownPayload, signature: unknownPayloadSignature,
        keyID: fixture.trust.keyID),
      trust: fixture.trust, expected: .nonCanonicalPayload)

    let duplicatePayload = Data(
      String(decoding: fixture.payload, as: UTF8.self)
        .replacingOccurrences(of: #"{"architectures":["#, with: #"{"sequence":1,"architectures":["#)
        .utf8)
    let duplicatePayloadSignature = try signingKey.signature(
      for: UpdateFeedCodec.signatureInput(
        payload: duplicatePayload, keyID: fixture.trust.keyID))
    assertFeedError(
      try UpdateFeedCodec.assemble(
        canonicalPayload: duplicatePayload, signature: duplicatePayloadSignature,
        keyID: fixture.trust.keyID),
      trust: fixture.trust, expected: .nonCanonicalPayload)
  }

  @Test func TEST_AU_CONTRACT_001_replayDowngradeExpiryAndURLMatrix() throws {
    let key = Curve25519.Signing.PrivateKey()
    let trust = try UpdateFeedTrust(
      keyID: "test-update-key", rawPublicKey: key.publicKey.rawRepresentation)
    let store = MemoryReplayStore()
    let verifier = UpdateFeedVerifier(trust: trust, replayStore: store)

    let first = try signedFixture(privateKey: key, sequence: 2, version: "2.0.0")
    _ = try verifier.verify(first.envelope, context: verificationContext(), now: now)
    let idempotent = try verifier.verify(
      first.envelope, context: verificationContext(), now: now)
    guard case .update = idempotent else {
      Issue.record("expected idempotent update")
      return
    }

    let replay = try signedFixture(privateKey: key, sequence: 1, version: "1.9.0")
    assertVerificationError(replay.envelope, verifier: verifier, expected: .replay)

    let conflict = try signedFixture(
      privateKey: key, sequence: 2, version: "2.0.0", notes: "different")
    assertVerificationError(conflict.envelope, verifier: verifier, expected: .sequenceConflict)

    let nonIncreasing = try signedFixture(privateKey: key, sequence: 3, version: "2.0.0")
    assertVerificationError(
      nonIncreasing.envelope, verifier: verifier, expected: .nonIncreasingRelease)

    let downgrade = try signedFixture(privateKey: key, sequence: 4, version: "1.0.0")
    assertVerificationError(
      downgrade.envelope,
      verifier: self.verifier(trust: trust),
      context: verificationContext(installed: "2.0.0"),
      expected: .downgrade)

    let expired = try signedFixture(
      privateKey: key, sequence: 5, issuedAt: "2026-06-20T00:00:00Z",
      expiresAt: "2026-07-20T00:00:00Z")
    assertVerificationError(
      expired.envelope, verifier: self.verifier(trust: trust), expected: .feedExpired)

    let expiresExactlyNow = try signedFixture(
      privateKey: key, sequence: 6, issuedAt: "2026-07-23T00:00:00Z",
      expiresAt: "2026-07-24T00:00:00Z")
    assertVerificationError(
      expiresExactlyNow.envelope, verifier: self.verifier(trust: trust),
      expected: .feedExpired)

    let future = try signedFixture(
      privateKey: key, sequence: 7, issuedAt: "2026-07-25T00:00:00Z",
      expiresAt: "2026-08-01T00:00:00Z")
    assertVerificationError(
      future.envelope, verifier: self.verifier(trust: trust), expected: .feedNotYetValid)

    for invalidURL in [
      "http://github.com/ArkDeck/ArkDeck/releases/download/v2/ArkDeck.dmg",
      "https://evil.example/ArkDeck.dmg",
      "https://127.0.0.1/ArkDeck.dmg",
      "https://user@github.com/ArkDeck.dmg",
      "https://github.com/ArkDeck.dmg#fragment",
      "https://github.com/ArkDeck.zip",
    ] {
      let invalid = try signedFixture(
        privateKey: key, sequence: 8, artifactURL: invalidURL)
      assertVerificationError(
        invalid.envelope, verifier: self.verifier(trust: trust),
        expected: .invalidArtifactURL)
    }
  }

  @Test func TEST_AU_CONTRACT_001_replayTransactionKeepsHighestAcrossStoresAndReopen()
    async throws
  {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-replay-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstStore = FileUpdateReplayStore(directory: root)
    let secondStore = FileUpdateReplayStore(directory: root)
    let sequenceOne = UpdateReplayRecord(
      sequence: 1, payloadSHA256: String(repeating: "1", count: 64), version: "1.0.0")
    let sequenceTwo = UpdateReplayRecord(
      sequence: 2, payloadSHA256: String(repeating: "2", count: 64), version: "2.0.0")
    let sequenceThree = UpdateReplayRecord(
      sequence: 3, payloadSHA256: String(repeating: "3", count: 64), version: "3.0.0")
    #expect(try firstStore.validateAndCommit(sequenceOne) == .accepted)

    let start = ConcurrentStartGate(participants: 2)
    let lowerWriter = Task.detached {
      start.arriveAndWait()
      return try firstStore.validateAndCommit(sequenceTwo)
    }
    let higherWriter = Task.detached {
      start.arriveAndWait()
      return try secondStore.validateAndCommit(sequenceThree)
    }
    let lowerDecision = try await lowerWriter.value
    let higherDecision = try await higherWriter.value
    #expect([UpdateReplayDecision.accepted, .replay].contains(lowerDecision))
    #expect(higherDecision == .accepted)

    let reopened = FileUpdateReplayStore(directory: root)
    #expect(try reopened.loadCurrentRecord() == sequenceThree)
    #expect(try reopened.validateAndCommit(sequenceTwo) == .replay)
    #expect(try reopened.validateAndCommit(sequenceThree) == .accepted)
    #expect(
      try !FileManager.default.contentsOfDirectory(atPath: root.path)
        .contains(where: { $0.hasSuffix(".part") }))
  }

  @Test func TEST_AU_CONTRACT_001_prepareRejectsInvalidUnsignedPayloadBeforeSigning() throws {
    #expect(throws: Never.self) {
      try UpdateFeedVerifier.validateUnsignedPayloadForSigning(
        payloadModel(
          issuedAt: "2026-07-01T00:00:00Z",
          expiresAt: "2026-07-31T00:00:00Z"))
    }

    assertUnsignedPayloadError(payloadModel(version: "2.0"), expected: .invalidVersion)
    assertUnsignedPayloadError(
      payloadModel(issuedAt: "2026-07-23 00:00:00Z"), expected: .invalidTimestamp)
    assertUnsignedPayloadError(
      payloadModel(
        issuedAt: "2026-07-01T00:00:00Z",
        expiresAt: "2026-08-01T00:00:00Z"),
      expected: .invalidValidityWindow)
    assertUnsignedPayloadError(
      payloadModel(artifactURL: "https://evil.example/ArkDeck.dmg"),
      expected: .invalidArtifactURL)
  }

  @Test func TEST_AU_PRIVACY_001_requestAndRedirectAllowlist() throws {
    let identity = UpdateProductIdentity(
      appVersion: "1.2.3", osVersion: "14.4.1", architecture: "arm64")
    let request = try UpdateRequestFactory.feedRequest(identity: identity)
    #expect(request.httpMethod == "GET")
    #expect(request.httpBody == nil)
    #expect(!request.httpShouldHandleCookies)
    #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    #expect(
      request.allHTTPHeaderFields
        == [
          "Accept": UpdateNetworkContract.acceptHeader,
          "User-Agent": UpdateNetworkContract.userAgentHeader,
        ])
    let requestURL = try #require(request.url)
    let queryItems = try #require(
      URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(
      Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
        == ["appVersion": "1.2.3", "osVersion": "14.4.1", "arch": "arm64"])

    var proposed = URLRequest(
      url: URL(
        string:
          "https://release-assets.githubusercontent.com/object?appVersion=1.2.3&osVersion=14.4.1&arch=arm64&token=public"
      )!)
    proposed.setValue("secret", forHTTPHeaderField: "Authorization")
    proposed.setValue("secret", forHTTPHeaderField: "Cookie")
    let redirected = try UpdateRedirectPolicy.redirectedRequest(
      proposed: proposed, redirectCount: 1)
    #expect(redirected.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(redirected.value(forHTTPHeaderField: "Cookie") == nil)
    let redirectedItems =
      URLComponents(url: redirected.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(redirectedItems == [URLQueryItem(name: "token", value: "public")])
    #expect(redirected.allHTTPHeaderFields == request.allHTTPHeaderFields)

    for value in [
      "http://github.com/asset",
      "https://evil.example/asset",
      "https://127.0.0.1/asset",
      "https://user@github.com/asset",
      "https://github.com/asset#fragment",
    ] {
      #expect(throws: (any Error).self) {
        try UpdateRedirectPolicy.redirectedRequest(
          proposed: URLRequest(url: URL(string: value)!), redirectCount: 1)
      }
    }
    #expect(throws: UpdateNetworkError.redirectLimitExceeded) {
      try UpdateRedirectPolicy.redirectedRequest(
        proposed: proposed, redirectCount: UpdateNetworkContract.maximumRedirects + 1)
    }
  }

  @Test func TEST_AU_PRIVACY_001_URLProtocolCapturesActualInitialRequest() async throws {
    CapturingUpdateURLProtocol.reset()
    let streamer = URLSessionUpdateHTTPStreamer(protocolClasses: [CapturingUpdateURLProtocol.self])
    let request = try UpdateRequestFactory.feedRequest(
      identity: UpdateProductIdentity(
        appVersion: "1.2.3", osVersion: "14.4.1", architecture: "arm64"))
    var body = Data()
    for try await chunk in streamer.stream(for: request, maximumBytes: 16) {
      body.append(chunk)
    }
    #expect(body == Data("ok".utf8))
    let captured = try #require(CapturingUpdateURLProtocol.capturedRequest())
    let capturedURL = try #require(captured.url)
    let components = try #require(
      URLComponents(url: capturedURL, resolvingAgainstBaseURL: false))
    #expect(
      Set(components.queryItems?.map(\.name) ?? [])
        == [
          "appVersion", "osVersion", "arch",
        ])
    #expect(captured.httpMethod == "GET")
    #expect(captured.httpBody == nil)
    #expect(captured.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(captured.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(
      captured.value(forHTTPHeaderField: "Accept") == UpdateNetworkContract.acceptHeader)
    #expect(
      captured.value(forHTTPHeaderField: "User-Agent") == UpdateNetworkContract.userAgentHeader)
    #expect(
      Set(captured.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? [])
        == ["accept", "user-agent"])

    CapturingUpdateURLProtocol.reset()
    let signedArtifactURL =
      "https://github.com/ArkDeck/ArkDeck/releases/download/v2.0.0/ArkDeck.dmg?asset=1"
    var artifactBody = Data()
    for try await chunk in streamer.stream(
      for: try UpdateRequestFactory.artifactRequest(signedURL: signedArtifactURL),
      maximumBytes: 16
    ) {
      artifactBody.append(chunk)
    }
    #expect(artifactBody == Data("ok".utf8))
    let capturedArtifact = try #require(CapturingUpdateURLProtocol.capturedRequest())
    #expect(capturedArtifact.url?.absoluteString == signedArtifactURL)
    #expect(capturedArtifact.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(capturedArtifact.value(forHTTPHeaderField: "Authorization") == nil)
  }

  @Test func TEST_AU_PRIVACY_001_URLProtocolCapturesSanitizedRedirectRequest() async throws {
    RedirectingUpdateURLProtocol.reset()
    let streamer = URLSessionUpdateHTTPStreamer(
      protocolClasses: [RedirectingUpdateURLProtocol.self])
    let request = try UpdateRequestFactory.feedRequest(
      identity: UpdateProductIdentity(
        appVersion: "1.2.3", osVersion: "14.4.1", architecture: "arm64"))
    var body = Data()
    for try await chunk in streamer.stream(for: request, maximumBytes: 16) {
      body.append(chunk)
    }
    #expect(body == Data("ok".utf8))
    let requests = RedirectingUpdateURLProtocol.capturedRequests()
    #expect(requests.count == 2)
    let redirected = try #require(requests.last)
    #expect(redirected.url?.host == "release-assets.githubusercontent.com")
    let names = Set(
      URLComponents(url: redirected.url!, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name)
        ?? [])
    #expect(names == ["token"])
    #expect(redirected.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(redirected.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(
      Set(redirected.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? [])
        == ["accept", "user-agent"])
  }

  @Test func TEST_AU_CONTRACT_001_downloadLengthDigestInterruptionAndCleanup() async throws {
    let fixture = try temporaryArtifactStore()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let bytes = Data("verified-dmg-fixture".utf8)
    let digest = UpdateFeedCodec.sha256(bytes)
    let artifact = try await fixture.store.writeVerified(
      stream: stream([Data(bytes.prefix(5)), Data(bytes.dropFirst(5))]),
      expectedLength: UInt64(bytes.count),
      expectedSHA256: digest)
    #expect(artifact.url.pathExtension == "dmg")
    #expect(
      (try FileManager.default.attributesOfItem(atPath: artifact.url.path)[.posixPermissions]
        as? NSNumber)
        == NSNumber(value: 0o400))
    #expect(
      try UpdateArtifactStore.verifyFile(
        at: artifact.url, expectedLength: UInt64(bytes.count), expectedSHA256: digest)
        == artifact.identity)
    #expect(artifact.identity.mode == 0o400)

    #expect(Darwin.chmod(artifact.url.path, 0o600) == 0)
    #expect(throws: UpdateDownloadError.unsafeArtifact) {
      try UpdateArtifactStore.verifyFile(
        at: artifact.url, expectedLength: UInt64(bytes.count), expectedSHA256: digest)
    }

    for failure in DownloadFailureFixture.allCases {
      let next = try temporaryArtifactStore()
      defer { try? FileManager.default.removeItem(at: next.root) }
      do {
        switch failure {
        case .truncated:
          _ = try await next.store.writeVerified(
            stream: stream([Data("short".utf8)]), expectedLength: 10,
            expectedSHA256: UpdateFeedCodec.sha256(Data("short".utf8)))
        case .overflow:
          _ = try await next.store.writeVerified(
            stream: stream([Data("too-long".utf8)]), expectedLength: 2,
            expectedSHA256: digest)
        case .digest:
          _ = try await next.store.writeVerified(
            stream: stream([bytes]), expectedLength: UInt64(bytes.count),
            expectedSHA256: String(repeating: "0", count: 64))
        case .interrupted:
          _ = try await next.store.writeVerified(
            stream: failingStream(
              bytes: Data("partial".utf8), error: URLError(.networkConnectionLost)),
            expectedLength: UInt64(bytes.count), expectedSHA256: digest)
        case .cancelled:
          _ = try await next.store.writeVerified(
            stream: failingStream(bytes: Data(), error: CancellationError()),
            expectedLength: UInt64(bytes.count), expectedSHA256: digest)
        }
        Issue.record("expected \(failure) to fail")
      } catch {}
      let residue = try FileManager.default.contentsOfDirectory(atPath: next.store.directory.path)
      #expect(residue.isEmpty, "\(failure) left untrusted cache: \(residue)")
    }
  }

  @Test func TEST_AU_CONTRACT_001_cancelTerminatesDownloadAndLateCatchCannotClobberRestart()
    async throws
  {
    let signed = try signedFixture()
    let storage = try temporaryArtifactStore()
    defer { try? FileManager.default.removeItem(at: storage.root) }
    let streamer = CancellableArtifactStreamer(
      feed: signed.envelope,
      partialArtifact: Data(signed.artifactBytes.prefix(5)))
    let service = AutoUpdateService(
      streamer: streamer,
      verifier: UpdateFeedVerifier(
        trust: signed.trust, replayStore: MemoryReplayStore()),
      artifactStore: storage.store,
      artifactValidator: FakeArtifactValidator(),
      preferences: MemoryUpdatePreferences())

    _ = try await service.checkManually(identity: verificationIdentity(), now: now)
    let download = Task {
      try await service.downloadAvailableUpdate()
    }
    try await waitUntil { streamer.artifactStarted }
    await service.cancel()

    let restarted = try await service.checkManually(identity: verificationIdentity(), now: now)
    guard case .available = restarted else {
      Issue.record("the replacement check must remain active")
      return
    }
    let result = await download.result
    switch result {
    case .success:
      Issue.record("cancelled download unexpectedly succeeded")
    case .failure(let error):
      #expect(error as? UpdateDownloadError == .cancelled)
    }
    try await waitUntil { streamer.artifactTerminated }
    guard case .available = await service.state else {
      Issue.record("late completion from the cancelled download clobbered the replacement check")
      return
    }
    #expect(try cachedArtifacts(in: storage.store).isEmpty)
  }

  @Test func TEST_AU_CONTRACT_001_developerIDRequirementAppliesToRunningAppAndArtifact()
    async throws
  {
    let storage = try temporaryArtifactStore()
    defer { try? FileManager.default.removeItem(at: storage.root) }
    let bytes = Data("verified-dmg-fixture".utf8)
    let artifact = try await storage.store.writeVerified(
      stream: stream([bytes]), expectedLength: UInt64(bytes.count),
      expectedSHA256: UpdateFeedCodec.sha256(bytes))
    let codeSigning = RecordingCodeSigningChecker(
      runningTeam: "ABCDEFGHIJ", artifactTeam: "ABCDEFGHIJ")
    let validated = try SystemUpdateArtifactValidator(codeSigning: codeSigning).validate(artifact)
    #expect(validated.teamIdentifier == "ABCDEFGHIJ")

    let expected =
      "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
      + " and certificate leaf[subject.OU] = \"ABCDEFGHIJ\""
    #expect(codeSigning.runningRequirements == [expected])
    #expect(codeSigning.artifactRequirements == [expected])
    #expect(throws: (any Error).self) {
      try SystemUpdateArtifactValidator.developerIDApplicationRequirementSource(
        teamIdentifier: "invalid team")
    }
  }

  @Test func TEST_AU_CONTRACT_001_ownerWritableArtifactFailsFinalReverification()
    async throws
  {
    let signed = try signedFixture()
    let storage = try temporaryArtifactStore()
    defer { try? FileManager.default.removeItem(at: storage.root) }
    let streamer = FakeUpdateStreamer(feed: signed.envelope, artifact: signed.artifactBytes)
    let revealer = RecordingArtifactRevealer()
    let service = AutoUpdateService(
      streamer: streamer,
      verifier: UpdateFeedVerifier(
        trust: signed.trust, replayStore: MemoryReplayStore()),
      artifactStore: storage.store,
      artifactValidator: SnapshotArtifactValidator(),
      preferences: MemoryUpdatePreferences())
    _ = try await service.checkManually(identity: verificationIdentity(), now: now)
    let awaiting = try await service.downloadAvailableUpdate()
    guard case .awaitingConsent(_, let approved) = awaiting else {
      Issue.record("expected final-consent state")
      return
    }
    #expect(Darwin.chmod(approved.downloaded.url.path, 0o600) == 0)

    await #expect(
      throws: UpdateDownloadError.unsafeArtifact,
      "owner-writable artifact must fail final verification"
    ) {
      _ = try await service.handoff(explicitConsent: true, revealer: revealer)
    }
    #expect(revealer.count == 0)
    let failedState = await service.state
    #expect(failedState == .failed(.handoff))
    #expect(try cachedArtifacts(in: storage.store).isEmpty)
  }

  @Test func TEST_AU_CONTRACT_001_teamUnsignedReplacementAndConsentHaveZeroHandoff()
    async throws
  {
    for securityError in [
      UpdateArtifactSecurityError.differentTeam,
      UpdateArtifactSecurityError.unsignedOrInvalidArtifact,
    ] {
      let fixture = try serviceFixture(validator: FakeArtifactValidator(error: securityError))
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let installed = fixture.root.appending(path: "installed-app-bytes")
      let installedBytes = Data("do-not-touch-installed-app".utf8)
      try installedBytes.write(to: installed)
      _ = try await fixture.service.checkManually(identity: verificationIdentity(), now: now)
      await #expect(throws: securityError, "expected artifact security failure") {
        _ = try await fixture.service.downloadAvailableUpdate()
      }
      let failedState = await fixture.service.state
      let handoffCount = fixture.revealer.count
      #expect(failedState == .failed(.artifact))
      #expect(handoffCount == 0)
      #expect(try cachedArtifacts(in: fixture.store).isEmpty)
      #expect(try Data(contentsOf: installed) == installedBytes)
    }

    let validator = FakeArtifactValidator()
    let fixture = try serviceFixture(validator: validator)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let installed = fixture.root.appending(path: "installed-app-bytes")
    let installedBytes = Data("do-not-touch-installed-app".utf8)
    try installedBytes.write(to: installed)
    _ = try await fixture.service.checkManually(identity: verificationIdentity(), now: now)
    _ = try await fixture.service.downloadAvailableUpdate()
    await #expect(
      throws: AutoUpdateServiceError.explicitConsentRequired,
      "handoff must require consent"
    ) {
      _ = try await fixture.service.handoff(
        explicitConsent: false, revealer: fixture.revealer)
    }
    let countBeforeReplacement = fixture.revealer.count
    #expect(countBeforeReplacement == 0)

    validator.failAfterFirstValidation = true
    await #expect(
      throws: UpdateArtifactSecurityError.artifactReplaced,
      "replacement at final verification must fail"
    ) {
      _ = try await fixture.service.handoff(
        explicitConsent: true, revealer: fixture.revealer)
    }
    let countAfterReplacement = fixture.revealer.count
    let replacementState = await fixture.service.state
    #expect(countAfterReplacement == 0)
    #expect(replacementState == .failed(.handoff))
    #expect(try Data(contentsOf: installed) == installedBytes)
  }

  @Test func TEST_AU_CONTRACT_001_positiveHandoffNeedsTwoUserActionsAndNoAutomaticDownload()
    async throws
  {
    let fixture = try serviceFixture(validator: FakeArtifactValidator())
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let state = try await fixture.service.checkAutomaticallyIfDue(
      identity: verificationIdentity(), now: now)
    guard case .available = state else {
      Issue.record("expected available")
      return
    }
    #expect(fixture.streamer.artifactRequestCount == 0)
    #expect(try cachedArtifacts(in: fixture.store).isEmpty)

    await #expect(
      throws: AutoUpdateServiceError.automaticCheckNotDue,
      "automatic check must be rate limited"
    ) {
      _ = try await fixture.service.checkAutomaticallyIfDue(
        identity: verificationIdentity(), now: now.addingTimeInterval(60))
    }
    #expect(fixture.streamer.feedRequestCount == 1)

    let awaitingConsent = try await fixture.service.downloadAvailableUpdate()
    guard case .awaitingConsent(let feed, _) = awaitingConsent else {
      Issue.record("expected final-consent state")
      return
    }
    #expect(feed.payload.releaseNotesSummary == "Security and reliability improvements.")
    #expect(fixture.streamer.artifactRequestCount == 1)
    let countBeforeHandoff = fixture.revealer.count
    #expect(countBeforeHandoff == 0)
    _ = try await fixture.service.handoff(
      explicitConsent: true, revealer: fixture.revealer)
    let countAfterHandoff = fixture.revealer.count
    let handedOffState = await fixture.service.state
    #expect(countAfterHandoff == 1)
    guard case .handedOff = handedOffState else {
      Issue.record("expected handed off")
      return
    }
  }

  @Test func TEST_AU_CONTRACT_001_automaticChecksPersistDefaultOnAndUserOptOut() throws {
    let suiteName = "ArkDeckAutoUpdateContractTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.removePersistentDomain(forName: suiteName)

    let preferences = UserDefaultsAutoUpdatePreferences(defaults: defaults)
    #expect(preferences.automaticChecksEnabled())
    preferences.setAutomaticChecksEnabled(false)
    #expect(!preferences.automaticChecksEnabled())
    let attempt = try #require(
      ISO8601Timestamps.parseCanonicalPlain("2026-07-24T00:00:00Z"))
    preferences.recordCheckAttempt(attempt)
    #expect(preferences.lastCheckAttempt() == attempt)
    #expect(AutoUpdateApplicationFacade.normalizedApplicationVersion("1.4") == "1.4.0")
    #expect(AutoUpdateApplicationFacade.normalizedApplicationVersion("1.4.2") == "1.4.2")
    #expect(AutoUpdateApplicationFacade.normalizedApplicationVersion("01.4") == "01.4")
  }

  @Test func TEST_AU_CONTRACT_001_entitlementsDependenciesSecretsAndDisclosure() throws {
    let repository = repoRoot
    let entitlementData = try Data(
      contentsOf: repository.appending(path: "ArkDeckApp/ArkDeckApp.entitlements"))
    let entitlementPlist = try #require(
      try PropertyListSerialization.propertyList(from: entitlementData, format: nil)
        as? [String: Any])
    let entitlements = entitlementPlist.compactMapValues { $0 as? Bool }
    #expect(
      Set(entitlements.keys)
        == [
          "com.apple.security.app-sandbox",
          "com.apple.security.device.serial",
          "com.apple.security.device.usb",
          "com.apple.security.files.bookmarks.app-scope",
          "com.apple.security.files.user-selected.read-write",
          "com.apple.security.network.client",
        ])
    #expect(entitlements.values.allSatisfy { $0 })

    // Every non-boolean entitlement is value-pinned. The App Sandbox classifies
    // AF_UNIX connect() as its own operation, so the daemon's Unix socket is
    // unreachable from this container under every file entitlement (measured);
    // a mach-lookup exception naming a launchd-vended service is the only
    // transport that works. The SSH exception is intentionally file-exact and
    // read-only: it cannot enumerate ~/.ssh or read config, known_hosts, agent
    // sockets, public keys, or other identity names.
    let machLookupKey = "com.apple.security.temporary-exception.mach-lookup.global-name"
    #expect(
      entitlementPlist[machLookupKey] as? [String] == ["com.arkdeck.agentd"],
      "the mach-lookup exception must name exactly the daemon's read-only XPC door")
    let systemSSHIdentityKey =
      "com.apple.security.temporary-exception.files.home-relative-path.read-only"
    #expect(
      entitlementPlist[systemSSHIdentityKey] as? [String]
        == ["/.ssh/id_rsa", "/.ssh/id_ed25519"],
      "system-default SSH access must remain read-only and identity-file exact")
    #expect(
      Set(entitlementPlist.keys)
        == Set(entitlements.keys).union([machLookupKey, systemSSHIdentityKey]),
      "the App's entitlement set is closed; adding one is a privilege decision")

    let package = try String(
      contentsOf: repository.appending(path: "Packages/ArkDeckKit/Package.swift"),
      encoding: .utf8)
    let arkTraceRevision = "9172c9525f954ec397e0555d7d03cd4367f3efcf"
    #expect(
      package.components(separatedBy: ".package(").count - 1 == 6,
      "the package's direct remote-source dependency set is closed")
    // The ArkForge Swift SDK left with the Swift Runtime (CHG-2026-074).
    #expect(!package.contains("ArkDeck/ArkForge"))
    #expect(package.contains("https://github.com/ArkDeck/ArkTrace.git"))
    #expect(package.contains("revision: \"\(arkTraceRevision)\""))
    for dependency in [
      ("https://github.com/orlandos-nl/Citadel.git", "0.12.1"),
      ("https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4"),
      ("https://github.com/apple/swift-nio.git", "2.101.3"),
      ("https://github.com/apple/swift-crypto.git", "3.15.1"),
      ("https://github.com/apple/swift-log.git", "1.15.0"),
    ] {
      #expect(package.contains(dependency.0))
      #expect(package.contains("exact: \"\(dependency.1)\""))
    }
    let packageResolution =
      try JSONSerialization.jsonObject(
        with: Data(
          contentsOf: repository.appending(path: "Packages/ArkDeckKit/Package.resolved")))
      as? [String: Any]
    let pins = try #require(packageResolution?["pins"] as? [[String: Any]])
    let expectedPins: [String: (location: String, revision: String, version: String?)] = [
      "arktrace": (
        "https://github.com/ArkDeck/ArkTrace.git",
        arkTraceRevision, nil),
      "bigint": (
        "https://github.com/attaswift/BigInt.git",
        "e07e00fa1fd435143a2dcf8b7eec9a7710b2fdfe", "5.7.0"),
      "citadel": (
        "https://github.com/orlandos-nl/Citadel.git",
        "ae8562f895de06ccb86fdb1cbb65fd99c8976e12", "0.12.1"),
      "swift-asn1": (
        "https://github.com/apple/swift-asn1.git",
        "a9a5efd40eaf558a2bcd48d64b1d1646be686008", "1.7.1"),
      "swift-atomics": (
        "https://github.com/apple/swift-atomics.git",
        "0442cb5a3f98ab802acb777929fdb446bda11a34", "1.3.1"),
      "swift-collections": (
        "https://github.com/apple/swift-collections.git",
        "a0cb0954ecb21e4e31b0070e6ed5674e8556685a", "1.6.0"),
      "swift-crypto": (
        "https://github.com/apple/swift-crypto.git",
        "95ba0316a9b733e92bb6b071255ff46263bbe7dc", "3.15.1"),
      "swift-log": (
        "https://github.com/apple/swift-log.git",
        "3ffafb9722d5d918c614feb496c8789a3b59d222", "1.15.0"),
      "swift-nio": (
        "https://github.com/apple/swift-nio.git",
        "0b18836bd8b0162e7e17a995a3fbee20ed8f3b2b", "2.101.3"),
      "swift-nio-ssh": (
        "https://github.com/Wellz26/swift-nio-ssh.git",
        "b93961a2988607a756cbc21a811f406f27aa9ab6", "0.3.4"),
      "swift-system": (
        "https://github.com/apple/swift-system.git",
        "869129b7bf4ecc57b97d0193ad29690ca2134750", "1.8.1"),
    ]
    let pinsByIdentity = Dictionary(
      uniqueKeysWithValues: try pins.map { pin in
        (try #require(pin["identity"] as? String), pin)
      })
    #expect(Set(pinsByIdentity.keys) == Set(expectedPins.keys))
    for (identity, expected) in expectedPins {
      let pin = try #require(pinsByIdentity[identity])
      #expect(pin["location"] as? String == expected.location, "\(identity)")
      let state = try #require(pin["state"] as? [String: Any])
      #expect(state["revision"] as? String == expected.revision, "\(identity)")
      #expect(state["version"] as? String == expected.version, "\(identity)")
    }
    let arkTracePin = try #require(pinsByIdentity["arktrace"])
    #expect(
      arkTracePin["location"] as? String
        == "https://github.com/ArkDeck/ArkTrace.git")
    #expect(
      (arkTracePin["state"] as? [String: Any])?["revision"] as? String
        == arkTraceRevision)
    let project = try String(
      contentsOf: repository.appending(path: "ArkDeck.xcodeproj/project.pbxproj"),
      encoding: .utf8)
    #expect(project.contains("XCRemoteSwiftPackageReference \"ArkTrace\""))
    #expect(project.contains("revision = \(arkTraceRevision);"))
    let marketingVersions = project.split(separator: "\n").compactMap { line -> String? in
      guard line.contains("MARKETING_VERSION =") else { return nil }
      return line.split(separator: "=", maxSplits: 1)[1]
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
    }
    #expect(!marketingVersions.isEmpty)
    #expect(marketingVersions.allSatisfy { UpdateSemanticVersion($0) != nil })
    #expect(
      !FileManager.default.fileExists(
        atPath: repository.appending(path: "Package.resolved").path))

    let privateMarker = ["-----BEGIN", "PRIVATE KEY-----"].joined(separator: " ")
    for relativePath in [
      "ArkDeckApp/App/ArkDeckApp.swift",
      "Packages/ArkDeckKit/Sources/ArkDeckClientKit/AutoUpdate",
    ] {
      #expect(
        try !sourceTree(at: repository.appending(path: relativePath)).contains(privateMarker),
        "private-key material marker found under \(relativePath)")
    }
    let localization = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/Resources/Localizable.xcstrings"),
      encoding: .utf8)
    #expect(localization.contains("\"update.privacyDisclosure\""))
    #expect(localization.contains("ArkDeck version, macOS version, and CPU architecture"))
    #expect(localization.contains("No device ID, user path, locale, telemetry"))
    #expect(localization.contains("does not install, replace itself, update on quit"))
    #expect(localization.contains("\"update.status.automaticCheckIncomplete\""))
    #expect(localization.contains("automatic update check did not complete"))
    let appSource = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/App/ArkDeckApp.swift"),
      encoding: .utf8)
    #expect(appSource.contains("update.status.automaticCheckIncomplete"))
    #expect(appSource.contains("if case .failed(.network) = await service.state"))
    #expect(appSource.contains("Integrity, replay and local-state failures"))
    #expect(!appSource.contains("artifact.downloaded.url.lastPathComponent"))
    let feedSource = try String(
      contentsOf: repository.appending(
        path: "Packages/ArkDeckKit/Sources/ArkDeckClientKit/AutoUpdate/UpdateFeed.swift"),
      encoding: .utf8)
    #expect(feedSource.contains("UpdateNetworkContract.allowedHosts.contains(host)"))
    #expect(!feedSource.contains("allowedArtifactHosts"))
    let releaseProcedure = try String(
      contentsOf: repository.appending(path: "docs/release/macos-auto-update.md"),
      encoding: .utf8)
    #expect(releaseProcedure.contains("openssl pkeyutl -sign -rawin"))
    #expect(releaseProcedure.contains("最后才发布签名 feed"))
    #expect(releaseProcedure.contains("不得成为 CLI 参数、环境变量"))
    #expect(releaseProcedure.contains("30 天有效期是强制 freshness 边界"))
    #expect(releaseProcedure.contains("不支持同版本续期"))
  }

  // MARK: - Fixtures

  private func payloadModel(
    sequence: UInt64 = 1,
    version: String = "2.0.0",
    issuedAt: String = "2026-07-23T00:00:00Z",
    expiresAt: String = "2026-08-01T00:00:00Z",
    artifactURL: String =
      "https://github.com/ArkDeck/ArkDeck/releases/download/v2.0.0/ArkDeck.dmg",
    notes: String = "Security and reliability improvements."
  ) -> UpdateFeedPayload {
    let artifactBytes = Data("verified-dmg-fixture".utf8)
    return UpdateFeedPayload(
      sequence: sequence, version: version, minimumSystemVersion: "14.0.0",
      architectures: ["arm64"], issuedAt: issuedAt, expiresAt: expiresAt,
      artifact: UpdateArtifactDescriptor(
        url: artifactURL, byteLength: UInt64(artifactBytes.count),
        sha256: UpdateFeedCodec.sha256(artifactBytes)),
      releaseNotesSummary: notes)
  }

  private func signedFixture(
    privateKey: Curve25519.Signing.PrivateKey = .init(),
    sequence: UInt64 = 1,
    version: String = "2.0.0",
    issuedAt: String = "2026-07-23T00:00:00Z",
    expiresAt: String = "2026-08-01T00:00:00Z",
    artifactURL: String =
      "https://github.com/ArkDeck/ArkDeck/releases/download/v2.0.0/ArkDeck.dmg",
    notes: String = "Security and reliability improvements."
  ) throws -> SignedFixture {
    let trust = try UpdateFeedTrust(
      keyID: "test-update-key", rawPublicKey: privateKey.publicKey.rawRepresentation)
    let artifactBytes = Data("verified-dmg-fixture".utf8)
    let payload = try UpdateFeedCodec.canonicalPayload(
      payloadModel(
        sequence: sequence, version: version, issuedAt: issuedAt, expiresAt: expiresAt,
        artifactURL: artifactURL, notes: notes))
    let signature = try privateKey.signature(
      for: UpdateFeedCodec.signatureInput(payload: payload, keyID: trust.keyID))
    return SignedFixture(
      trust: trust, payload: payload, signature: signature,
      envelope: try UpdateFeedCodec.assemble(
        canonicalPayload: payload, signature: signature, keyID: trust.keyID),
      artifactBytes: artifactBytes)
  }

  private func verifier(trust: UpdateFeedTrust) -> UpdateFeedVerifier {
    UpdateFeedVerifier(trust: trust, replayStore: MemoryReplayStore())
  }

  private func verificationContext(installed: String = "1.0.0") -> UpdateVerificationContext {
    UpdateVerificationContext(
      installedVersion: installed, systemVersion: "14.4.1", architecture: "arm64")
  }

  private func verificationIdentity() -> UpdateProductIdentity {
    UpdateProductIdentity(appVersion: "1.0.0", osVersion: "14.4.1", architecture: "arm64")
  }

  private func assertFeedError(
    _ data: Data,
    trust: UpdateFeedTrust,
    expected: UpdateFeedError,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(throws: expected, sourceLocation: sourceLocation) {
      try UpdateFeedCodec.decodeAndVerify(data, trust: trust)
    }
  }

  private func assertVerificationError(
    _ data: Data,
    verifier: UpdateFeedVerifier,
    context: UpdateVerificationContext? = nil,
    expected: UpdateFeedError,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(throws: expected, sourceLocation: sourceLocation) {
      try verifier.verify(data, context: context ?? verificationContext(), now: now)
    }
  }

  private func assertUnsignedPayloadError(
    _ payload: UpdateFeedPayload,
    expected: UpdateFeedError,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(throws: expected, sourceLocation: sourceLocation) {
      try UpdateFeedVerifier.validateUnsignedPayloadForSigning(payload)
    }
  }

  @Test func runtimeUpdateFacadeContinuesOneLifecycleAcrossFreshOwners() async throws {
    let signed = try signedFixture()
    let storage = try temporaryArtifactStore()
    defer { try? FileManager.default.removeItem(at: storage.root) }
    let stateDirectory = storage.root.appending(path: "Lifecycle", directoryHint: .isDirectory)
    let streamer = FakeUpdateStreamer(feed: signed.envelope, artifact: signed.artifactBytes)
    let replayStore = MemoryReplayStore()
    let preferences = MemoryUpdatePreferences()
    let validator = FakeArtifactValidator()
    let revealer = RecordingArtifactRevealer()
    let fixedNow = now

    func facade() throws -> RuntimeUpdateApplicationFacade {
      try RuntimeUpdateApplicationFacade(
        streamer: streamer,
        verifier: UpdateFeedVerifier(trust: signed.trust, replayStore: replayStore),
        artifactStore: storage.store,
        artifactValidator: validator,
        preferences: preferences,
        stateStore: RuntimeUpdateStateStore(directory: stateDirectory, now: { fixedNow }))
    }

    let first = try facade()
    guard case .available = try await first.checkManually(
      identity: verificationIdentity(), now: fixedNow)
    else {
      Issue.record("check must publish a durable available state")
      return
    }

    let second = try facade()
    let availableStatus = try await second.status()
    #expect(availableStatus.phase == "available")
    guard case .awaitingConsent = try await second.downloadAvailableUpdate() else {
      Issue.record("a fresh owner must continue the durable download transition")
      return
    }

    let third = try facade()
    let awaiting = try await third.status()
    #expect(awaiting.phase == "awaitingConsent")
    #expect(awaiting.artifactSHA256 == UpdateFeedCodec.sha256(signed.artifactBytes))
    #expect(!String(describing: awaiting).contains(storage.root.path))
    guard case .handedOff = try await third.handoff(
      explicitConsent: true, revealer: revealer)
    else {
      Issue.record("a third owner must continue the consent-bound handoff")
      return
    }
    #expect(revealer.count == 1)
    let handedOffStatus = try await third.status()
    #expect(handedOffStatus.phase == "handedOff")
  }

  @Test func runtimeUpdateFacadeObservesCrossProcessCancellationAndSettlesDurably()
    async throws
  {
    let signed = try signedFixture()
    let storage = try temporaryArtifactStore()
    defer { try? FileManager.default.removeItem(at: storage.root) }
    let stateDirectory = storage.root.appending(path: "Lifecycle", directoryHint: .isDirectory)
    let fixedNow = now
    let stateStore = RuntimeUpdateStateStore(directory: stateDirectory, now: { fixedNow })
    let streamer = CancellableArtifactStreamer(
      feed: signed.envelope,
      partialArtifact: Data(signed.artifactBytes.prefix(5)))
    let facade = try RuntimeUpdateApplicationFacade(
      streamer: streamer,
      verifier: UpdateFeedVerifier(
        trust: signed.trust, replayStore: MemoryReplayStore()),
      artifactStore: storage.store,
      artifactValidator: FakeArtifactValidator(),
      preferences: MemoryUpdatePreferences(),
      stateStore: stateStore)
    _ = try await facade.checkManually(identity: verificationIdentity(), now: now)

    let download = Task { try await facade.downloadAvailableUpdate() }
    try await waitUntil { streamer.artifactStarted }
    let cancellation = try RuntimeUpdateStateStore(directory: stateDirectory)
      .requestCancellation()
    #expect(cancellation.cancellationRequested)

    switch await download.result {
    case .success:
      Issue.record("a cross-process cancellation must not publish a verified artifact")
    case .failure(let error):
      #expect(error as? UpdateDownloadError == .cancelled)
    }
    try await waitUntil { streamer.artifactTerminated }
    let settled = try await facade.status()
    #expect(settled.phase == "cancelled")
    #expect(!settled.isBusy)
    #expect(!settled.cancellationRequested)
    #expect(try cachedArtifacts(in: storage.store).isEmpty)
  }

  @Test func runtimeUpdateFacadeRecoversCrashedVerificationOwnerWithoutLivenessGuessing()
    async throws
  {
    let signed = try signedFixture()
    let storage = try temporaryArtifactStore()
    defer { try? FileManager.default.removeItem(at: storage.root) }
    let downloaded = try await storage.store.writeVerified(
      stream: stream([signed.artifactBytes]),
      expectedLength: UInt64(signed.artifactBytes.count),
      expectedSHA256: UpdateFeedCodec.sha256(signed.artifactBytes))
    let stateDirectory = storage.root.appending(path: "Lifecycle", directoryHint: .isDirectory)
    let stateStore = RuntimeUpdateStateStore(directory: stateDirectory)
    _ = try stateStore.replace(
      expectedGeneration: 0,
      state: .verifying(downloaded),
      activeOperationID: UUID())

    let facade = try RuntimeUpdateApplicationFacade(
      streamer: FakeUpdateStreamer(feed: signed.envelope, artifact: signed.artifactBytes),
      verifier: UpdateFeedVerifier(
        trust: signed.trust, replayStore: MemoryReplayStore()),
      artifactStore: storage.store,
      artifactValidator: FakeArtifactValidator(),
      preferences: MemoryUpdatePreferences(),
      stateStore: RuntimeUpdateStateStore(directory: stateDirectory))
    try await facade.recoverOrphanPartials()

    let recovered = try await facade.status()
    #expect(recovered.phase == "cancelled")
    #expect(!recovered.isBusy)
    #expect(try cachedArtifacts(in: storage.store).isEmpty)
  }

  @Test func runtimeUpdateFacadeReportsHandoffWhenCancellationArrivesAfterFinderReveal()
    async throws
  {
    let signed = try signedFixture()
    let storage = try temporaryArtifactStore()
    defer { try? FileManager.default.removeItem(at: storage.root) }
    let stateDirectory = storage.root.appending(path: "Lifecycle", directoryHint: .isDirectory)
    let stateStore = RuntimeUpdateStateStore(directory: stateDirectory)
    let facade = try RuntimeUpdateApplicationFacade(
      streamer: FakeUpdateStreamer(feed: signed.envelope, artifact: signed.artifactBytes),
      verifier: UpdateFeedVerifier(
        trust: signed.trust, replayStore: MemoryReplayStore()),
      artifactStore: storage.store,
      artifactValidator: FakeArtifactValidator(),
      preferences: MemoryUpdatePreferences(),
      stateStore: stateStore)
    _ = try await facade.checkManually(identity: verificationIdentity(), now: now)
    _ = try await facade.downloadAvailableUpdate()

    let revealer = CancellingArtifactRevealer(stateStore: stateStore)
    guard case .handedOff = try await facade.handoff(
      explicitConsent: true, revealer: revealer)
    else {
      Issue.record("a reveal that completed is a handed-off outcome")
      return
    }
    let settled = try await facade.status()
    #expect(settled.phase == "handedOff")
    #expect(!settled.isBusy)
    #expect(!settled.cancellationRequested)
    #expect(revealer.count == 1)
  }

  @Test func runtimeUpdateCleanupExplicitlyDiscardsAwaitingConsentArtifact() async throws {
    let signed = try signedFixture()
    let storage = try temporaryArtifactStore()
    defer { try? FileManager.default.removeItem(at: storage.root) }
    let foreignDMG = storage.store.directory.appending(path: "keep-me.dmg")
    try Data("not updater-owned".utf8).write(to: foreignDMG)
    let stateDirectory = storage.root.appending(path: "Lifecycle", directoryHint: .isDirectory)
    let facade = try RuntimeUpdateApplicationFacade(
      streamer: FakeUpdateStreamer(feed: signed.envelope, artifact: signed.artifactBytes),
      verifier: UpdateFeedVerifier(
        trust: signed.trust, replayStore: MemoryReplayStore()),
      artifactStore: storage.store,
      artifactValidator: FakeArtifactValidator(),
      preferences: MemoryUpdatePreferences(),
      stateStore: RuntimeUpdateStateStore(directory: stateDirectory))
    _ = try await facade.checkManually(identity: verificationIdentity(), now: now)
    _ = try await facade.downloadAvailableUpdate()
    #expect(try cachedArtifacts(in: storage.store).filter { $0.hasSuffix(".dmg") }.count == 2)

    let receipt = try await facade.cleanup()

    #expect(receipt.status.phase == "idle")
    #expect(receipt.removedVerifiedArtifacts == 1)
    #expect(try cachedArtifacts(in: storage.store) == ["keep-me.dmg"])
  }

  private func waitUntil(
    attempts: Int = 2_000,
    condition: () -> Bool
  ) async throws {
    for _ in 0..<attempts {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    throw URLError(.timedOut)
  }

  private func stream(_ chunks: [Data]) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
      for chunk in chunks { continuation.yield(chunk) }
      continuation.finish()
    }
  }

  private func failingStream(
    bytes: Data,
    error: any Error
  ) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
      if !bytes.isEmpty { continuation.yield(bytes) }
      continuation.finish(throwing: error)
    }
  }

  private func temporaryArtifactStore() throws -> (root: URL, store: UpdateArtifactStore) {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-update-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let store = UpdateArtifactStore(
      directory: root.appending(path: "Updates", directoryHint: .isDirectory))
    try store.removeOrphanPartials()
    return (root, store)
  }

  private func serviceFixture(
    validator: FakeArtifactValidator
  ) throws -> ServiceFixture {
    let signed = try signedFixture()
    let storage = try temporaryArtifactStore()
    let streamer = FakeUpdateStreamer(feed: signed.envelope, artifact: signed.artifactBytes)
    let preferences = MemoryUpdatePreferences()
    let revealer = RecordingArtifactRevealer()
    return ServiceFixture(
      root: storage.root,
      store: storage.store,
      streamer: streamer,
      revealer: revealer,
      service: AutoUpdateService(
        streamer: streamer,
        verifier: UpdateFeedVerifier(
          trust: signed.trust, replayStore: MemoryReplayStore()),
        artifactStore: storage.store,
        artifactValidator: validator,
        preferences: preferences))
  }

  private func cachedArtifacts(in store: UpdateArtifactStore) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
  }

  private var repoRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func sourceTree(at url: URL) throws -> String {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      return ""
    }
    if !isDirectory.boolValue { return try String(contentsOf: url, encoding: .utf8) }
    let files = try FileManager.default.contentsOfDirectory(
      at: url, includingPropertiesForKeys: nil)
    return try files.sorted(by: { $0.path < $1.path }).map(sourceTree(at:)).joined()
  }

  /// PR #1276 review: replay-state durability is split — regular files take
  /// the strict fsync+F_FULLFSYNC pair, directories take plain fsync — and
  /// both spellings fail loudly on a dead descriptor.
  @Test func replayStateSyncSpellingsFailLoudlyAndSucceedOnLiveDescriptors() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-update-sync-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appending(path: "watermark.json")
    let fileDescriptor = open(fileURL.path, O_RDWR | O_CREAT, 0o600)
    #expect(fileDescriptor >= 0)
    #expect(throws: Never.self) { try FileUpdateReplayStore.strictFileSync(fileDescriptor) }
    close(fileDescriptor)

    let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY)
    #expect(directoryDescriptor >= 0)
    #expect(throws: Never.self) { try FileUpdateReplayStore.syncDirectory(directoryDescriptor) }
    close(directoryDescriptor)

    #expect(throws: (any Error).self) { try FileUpdateReplayStore.strictFileSync(-1) }
    #expect(throws: (any Error).self) { try FileUpdateReplayStore.syncDirectory(-1) }
  }
}

private struct SignedFixture {
  let trust: UpdateFeedTrust
  let payload: Data
  let signature: Data
  let envelope: Data
  let artifactBytes: Data
}

private enum DownloadFailureFixture: CaseIterable {
  case truncated
  case overflow
  case digest
  case interrupted
  case cancelled
}

private final class MemoryReplayStore: UpdateReplayStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var record: UpdateReplayRecord?

  func validateAndCommit(
    _ candidate: UpdateReplayRecord
  ) throws -> UpdateReplayDecision {
    lock.withLock {
      let decision = UpdateReplayPolicy.decision(previous: record, candidate: candidate)
      if decision == .accepted { record = candidate }
      return decision
    }
  }
}

private final class ConcurrentStartGate: @unchecked Sendable {
  private let condition = NSCondition()
  private let participants: Int
  private var arrivals = 0

  init(participants: Int) {
    self.participants = participants
  }

  func arriveAndWait() {
    condition.lock()
    arrivals += 1
    if arrivals == participants {
      condition.broadcast()
    } else {
      while arrivals < participants { condition.wait() }
    }
    condition.unlock()
  }
}

private final class MemoryUpdatePreferences: AutoUpdatePreferenceStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var enabled = true
  private var lastAttempt: Date?

  func automaticChecksEnabled() -> Bool { lock.withLock { enabled } }
  func setAutomaticChecksEnabled(_ enabled: Bool) {
    lock.withLock { self.enabled = enabled }
  }
  func lastCheckAttempt() -> Date? { lock.withLock { lastAttempt } }
  func recordCheckAttempt(_ date: Date) {
    lock.withLock { lastAttempt = date }
  }
}

private final class FakeUpdateStreamer: UpdateHTTPStreaming, @unchecked Sendable {
  private let feed: Data
  private let artifact: Data
  private let lock = NSLock()
  private var feedCount = 0
  private var artifactCount = 0

  init(feed: Data, artifact: Data) {
    self.feed = feed
    self.artifact = artifact
  }

  var feedRequestCount: Int { lock.withLock { feedCount } }
  var artifactRequestCount: Int { lock.withLock { artifactCount } }

  func stream(
    for request: URLRequest,
    maximumBytes: UInt64
  ) -> AsyncThrowingStream<Data, any Error> {
    let data: Data
    if request.url?.path.hasSuffix(".dmg") == true {
      lock.withLock { artifactCount += 1 }
      data = artifact
    } else {
      lock.withLock { feedCount += 1 }
      data = feed
    }
    return AsyncThrowingStream { continuation in
      continuation.yield(data)
      continuation.finish()
    }
  }
}

private final class CancellableArtifactStreamer: UpdateHTTPStreaming, @unchecked Sendable {
  private let feed: Data
  private let partialArtifact: Data
  private let lock = NSLock()
  private var started = false
  private var terminated = false

  init(feed: Data, partialArtifact: Data) {
    self.feed = feed
    self.partialArtifact = partialArtifact
  }

  var artifactStarted: Bool { lock.withLock { started } }
  var artifactTerminated: Bool { lock.withLock { terminated } }

  func stream(
    for request: URLRequest,
    maximumBytes: UInt64
  ) -> AsyncThrowingStream<Data, any Error> {
    guard request.url?.path.hasSuffix(".dmg") == true else {
      return AsyncThrowingStream { continuation in
        continuation.yield(feed)
        continuation.finish()
      }
    }
    return AsyncThrowingStream { continuation in
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        self.lock.withLock { self.terminated = true }
      }
      lock.withLock { started = true }
      continuation.yield(partialArtifact)
    }
  }
}

private final class RecordingCodeSigningChecker: UpdateCodeSigningChecking, @unchecked Sendable {
  private let lock = NSLock()
  private let runningTeam: String
  private let artifactTeam: String?
  private var recordedRunningRequirements: [String] = []
  private var recordedArtifactRequirements: [String] = []

  init(runningTeam: String, artifactTeam: String?) {
    self.runningTeam = runningTeam
    self.artifactTeam = artifactTeam
  }

  var runningRequirements: [String] {
    lock.withLock { recordedRunningRequirements }
  }

  var artifactRequirements: [String] {
    lock.withLock { recordedArtifactRequirements }
  }

  func runningApplicationTeamIdentifier() throws -> String {
    runningTeam
  }

  func validateRunningApplication(requirementSource: String) throws {
    lock.withLock { recordedRunningRequirements.append(requirementSource) }
  }

  func validateArtifact(at url: URL, requirementSource: String) throws -> String? {
    lock.withLock { recordedArtifactRequirements.append(requirementSource) }
    return artifactTeam
  }
}

private struct SnapshotArtifactValidator: UpdateArtifactValidating {
  func validate(_ artifact: DownloadedUpdateArtifact) throws -> ValidatedUpdateArtifact {
    let identity = try UpdateArtifactStore.verifyFile(
      at: artifact.url, expectedLength: artifact.byteLength,
      expectedSHA256: artifact.sha256)
    guard identity == artifact.identity else {
      throw UpdateArtifactSecurityError.artifactReplaced
    }
    return ValidatedUpdateArtifact(
      downloaded: artifact, teamIdentifier: "ABCDEFGHIJ")
  }
}

private final class FakeArtifactValidator: UpdateArtifactValidating, @unchecked Sendable {
  private let lock = NSLock()
  private let error: UpdateArtifactSecurityError?
  private var validations = 0
  var failAfterFirstValidation = false

  init(error: UpdateArtifactSecurityError? = nil) {
    self.error = error
  }

  func validate(_ artifact: DownloadedUpdateArtifact) throws -> ValidatedUpdateArtifact {
    try lock.withLock {
      validations += 1
      if let error { throw error }
      if failAfterFirstValidation, validations > 1 {
        throw UpdateArtifactSecurityError.artifactReplaced
      }
      return ValidatedUpdateArtifact(
        downloaded: artifact, teamIdentifier: "ABCDEFGHIJ")
    }
  }
}

private final class RecordingArtifactRevealer: UpdateArtifactRevealing, @unchecked Sendable {
  private let lock = NSLock()
  var count: Int { lock.withLock { internalCount } }
  private var internalCount = 0

  @MainActor
  func revealInFinder(_ url: URL) throws {
    lock.withLock { internalCount += 1 }
  }
}

private final class CancellingArtifactRevealer: UpdateArtifactRevealing, @unchecked Sendable {
  private let lock = NSLock()
  private let stateStore: RuntimeUpdateStateStore
  private var internalCount = 0
  var count: Int { lock.withLock { internalCount } }

  init(stateStore: RuntimeUpdateStateStore) {
    self.stateStore = stateStore
  }

  @MainActor
  func revealInFinder(_ url: URL) throws {
    lock.withLock { internalCount += 1 }
    _ = try stateStore.requestCancellation()
  }
}

private struct ServiceFixture {
  let root: URL
  let store: UpdateArtifactStore
  let streamer: FakeUpdateStreamer
  let revealer: RecordingArtifactRevealer
  let service: AutoUpdateService
}

private final class CapturingUpdateURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var captured: URLRequest?

  static func reset() {
    lock.withLock { captured = nil }
  }

  static func capturedRequest() -> URLRequest? {
    lock.withLock { captured }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.withLock { Self.captured = request }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Length": "2"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data("ok".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private final class RedirectingUpdateURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var requests: [URLRequest] = []

  static func reset() {
    lock.withLock { requests = [] }
  }

  static func capturedRequests() -> [URLRequest] {
    lock.withLock { requests }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let index = Self.lock.withLock {
      Self.requests.append(request)
      return Self.requests.count
    }
    if index == 1 {
      var redirected = URLRequest(
        url: URL(
          string:
            "https://release-assets.githubusercontent.com/object?appVersion=1.2.3&osVersion=14.4.1&arch=arm64&token=public"
        )!)
      redirected.setValue("secret", forHTTPHeaderField: "Authorization")
      redirected.setValue("secret", forHTTPHeaderField: "Cookie")
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
        headerFields: ["Location": redirected.url!.absoluteString])!
      client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
      return
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Length": "2"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data("ok".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

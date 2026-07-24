import ArkDeckRuntime
import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class AutoUpdateContractTests: XCTestCase {
  private let now = ISO8601DateFormatter().date(from: "2026-07-24T00:00:00Z")!

  func testTEST_AU_CONTRACT_001_productionTrustPinAndValidFeed() throws {
    let trust = try UpdateFeedTrust.production
    XCTAssertEqual(trust.keyID, "arkdeck-update-2026-07-b949b102")
    XCTAssertEqual(
      trust.rawPublicKey.base64EncodedString(),
      "c5Ho0xkWFQ3Ovzjx98dQhF3n5sytJjffqD3a+ftgP8c=")
    let spkiPrefix = Data([
      0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
    ])
    XCTAssertEqual(
      UpdateFeedCodec.sha256(spkiPrefix + trust.rawPublicKey),
      UpdateFeedTrust.productionSPKISHA256)

    let fixture = try signedFixture()
    let result = try verifier(trust: fixture.trust).verify(
      fixture.envelope, context: verificationContext(), now: now)
    guard case .update(let verified) = result else {
      return XCTFail("expected a verified update")
    }
    XCTAssertEqual(verified.payload.version, "2.0.0")
    XCTAssertEqual(verified.payloadSHA256, UpdateFeedCodec.sha256(fixture.payload))
  }

  func testTEST_AU_CONTRACT_001_feedSignatureAndCanonicalShapeFailClosed() throws {
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

    var object = try XCTUnwrap(
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

    var payloadObject = try XCTUnwrap(
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

  func testTEST_AU_CONTRACT_001_replayDowngradeExpiryAndURLMatrix() throws {
    let key = Curve25519.Signing.PrivateKey()
    let trust = try UpdateFeedTrust(
      keyID: "test-update-key", rawPublicKey: key.publicKey.rawRepresentation)
    let store = MemoryReplayStore()
    let verifier = UpdateFeedVerifier(trust: trust, replayStore: store)

    let first = try signedFixture(privateKey: key, sequence: 2, version: "2.0.0")
    _ = try verifier.verify(first.envelope, context: verificationContext(), now: now)
    let idempotent = try verifier.verify(
      first.envelope, context: verificationContext(), now: now)
    guard case .update = idempotent else { return XCTFail("expected idempotent update") }

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

    let future = try signedFixture(
      privateKey: key, sequence: 6, issuedAt: "2026-07-25T00:00:00Z",
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
        privateKey: key, sequence: 7, artifactURL: invalidURL)
      assertVerificationError(
        invalid.envelope, verifier: self.verifier(trust: trust),
        expected: .invalidArtifactURL)
    }
  }

  func testTEST_AU_CONTRACT_001_prepareRejectsInvalidUnsignedPayloadBeforeSigning() throws {
    XCTAssertNoThrow(
      try UpdateFeedVerifier.validateUnsignedPayloadForSigning(
        payloadModel(
          issuedAt: "2026-07-01T00:00:00Z",
          expiresAt: "2026-07-31T00:00:00Z")))

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

  func testTEST_AU_PRIVACY_001_requestAndRedirectAllowlist() throws {
    let identity = UpdateProductIdentity(
      appVersion: "1.2.3", osVersion: "14.4.1", architecture: "arm64")
    let request = try UpdateRequestFactory.feedRequest(identity: identity)
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertNil(request.httpBody)
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
    XCTAssertEqual(
      request.allHTTPHeaderFields,
      [
        "Accept": UpdateNetworkContract.acceptHeader,
        "User-Agent": UpdateNetworkContract.userAgentHeader,
      ])
    let queryItems = try XCTUnwrap(
      URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") }),
      ["appVersion": "1.2.3", "osVersion": "14.4.1", "arch": "arm64"])

    var proposed = URLRequest(
      url: URL(
        string:
          "https://release-assets.githubusercontent.com/object?appVersion=1.2.3&osVersion=14.4.1&arch=arm64&token=public"
      )!)
    proposed.setValue("secret", forHTTPHeaderField: "Authorization")
    proposed.setValue("secret", forHTTPHeaderField: "Cookie")
    let redirected = try UpdateRedirectPolicy.redirectedRequest(
      proposed: proposed, redirectCount: 1)
    XCTAssertNil(redirected.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(redirected.value(forHTTPHeaderField: "Cookie"))
    let redirectedItems =
      URLComponents(url: redirected.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    XCTAssertEqual(redirectedItems, [URLQueryItem(name: "token", value: "public")])
    XCTAssertEqual(redirected.allHTTPHeaderFields, request.allHTTPHeaderFields)

    for value in [
      "http://github.com/asset",
      "https://evil.example/asset",
      "https://127.0.0.1/asset",
      "https://user@github.com/asset",
      "https://github.com/asset#fragment",
    ] {
      XCTAssertThrowsError(
        try UpdateRedirectPolicy.redirectedRequest(
          proposed: URLRequest(url: URL(string: value)!), redirectCount: 1))
    }
    XCTAssertThrowsError(
      try UpdateRedirectPolicy.redirectedRequest(
        proposed: proposed, redirectCount: UpdateNetworkContract.maximumRedirects + 1)
    ) { error in
      XCTAssertEqual(error as? UpdateNetworkError, .redirectLimitExceeded)
    }
  }

  func testTEST_AU_PRIVACY_001_URLProtocolCapturesActualInitialRequest() async throws {
    CapturingUpdateURLProtocol.reset()
    let streamer = URLSessionUpdateHTTPStreamer(protocolClasses: [CapturingUpdateURLProtocol.self])
    let request = try UpdateRequestFactory.feedRequest(
      identity: UpdateProductIdentity(
        appVersion: "1.2.3", osVersion: "14.4.1", architecture: "arm64"))
    var body = Data()
    for try await chunk in streamer.stream(for: request, maximumBytes: 16) {
      body.append(chunk)
    }
    XCTAssertEqual(body, Data("ok".utf8))
    let captured = try XCTUnwrap(CapturingUpdateURLProtocol.capturedRequest())
    let components = try XCTUnwrap(
      URLComponents(url: try XCTUnwrap(captured.url), resolvingAgainstBaseURL: false))
    XCTAssertEqual(
      Set(components.queryItems?.map(\.name) ?? []),
      [
        "appVersion", "osVersion", "arch",
      ])
    XCTAssertEqual(captured.httpMethod, "GET")
    XCTAssertNil(captured.httpBody)
    XCTAssertNil(captured.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(captured.value(forHTTPHeaderField: "Authorization"))
    XCTAssertEqual(
      captured.value(forHTTPHeaderField: "Accept"), UpdateNetworkContract.acceptHeader)
    XCTAssertEqual(
      captured.value(forHTTPHeaderField: "User-Agent"), UpdateNetworkContract.userAgentHeader)
    XCTAssertEqual(
      Set(captured.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? []),
      ["accept", "user-agent"])

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
    XCTAssertEqual(artifactBody, Data("ok".utf8))
    let capturedArtifact = try XCTUnwrap(CapturingUpdateURLProtocol.capturedRequest())
    XCTAssertEqual(capturedArtifact.url?.absoluteString, signedArtifactURL)
    XCTAssertNil(capturedArtifact.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(capturedArtifact.value(forHTTPHeaderField: "Authorization"))
  }

  func testTEST_AU_PRIVACY_001_URLProtocolCapturesSanitizedRedirectRequest() async throws {
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
    XCTAssertEqual(body, Data("ok".utf8))
    let requests = RedirectingUpdateURLProtocol.capturedRequests()
    XCTAssertEqual(requests.count, 2)
    let redirected = try XCTUnwrap(requests.last)
    XCTAssertEqual(redirected.url?.host, "release-assets.githubusercontent.com")
    let names = Set(
      URLComponents(url: redirected.url!, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name)
        ?? [])
    XCTAssertEqual(names, ["token"])
    XCTAssertNil(redirected.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(redirected.value(forHTTPHeaderField: "Authorization"))
    XCTAssertEqual(
      Set(redirected.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? []),
      ["accept", "user-agent"])
  }

  func testTEST_AU_CONTRACT_001_downloadLengthDigestInterruptionAndCleanup() async throws {
    let fixture = try temporaryArtifactStore()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let bytes = Data("verified-dmg-fixture".utf8)
    let digest = UpdateFeedCodec.sha256(bytes)
    let artifact = try await fixture.store.writeVerified(
      stream: stream([Data(bytes.prefix(5)), Data(bytes.dropFirst(5))]),
      expectedLength: UInt64(bytes.count),
      expectedSHA256: digest)
    XCTAssertEqual(artifact.url.pathExtension, "dmg")
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: artifact.url.path)[.posixPermissions]
        as? NSNumber,
      NSNumber(value: 0o400))
    XCTAssertEqual(
      try UpdateArtifactStore.verifyFile(
        at: artifact.url, expectedLength: UInt64(bytes.count), expectedSHA256: digest),
      artifact.identity)

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
        XCTFail("expected \(failure) to fail")
      } catch {}
      let residue = try FileManager.default.contentsOfDirectory(atPath: next.store.directory.path)
      XCTAssertTrue(residue.isEmpty, "\(failure) left untrusted cache: \(residue)")
    }
  }

  func testTEST_AU_CONTRACT_001_cancelTerminatesDownloadAndLateCatchCannotClobberRestart()
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
      return XCTFail("the replacement check must remain active")
    }
    let result = await download.result
    switch result {
    case .success:
      XCTFail("cancelled download unexpectedly succeeded")
    case .failure(let error):
      XCTAssertEqual(error as? UpdateDownloadError, .cancelled)
    }
    try await waitUntil { streamer.artifactTerminated }
    guard case .available = await service.state else {
      return XCTFail("late completion from the cancelled download clobbered the replacement check")
    }
    XCTAssertTrue(try cachedArtifacts(in: storage.store).isEmpty)
  }

  func testTEST_AU_CONTRACT_001_teamUnsignedReplacementAndConsentHaveZeroHandoff()
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
      do {
        _ = try await fixture.service.downloadAvailableUpdate()
        XCTFail("expected artifact security failure")
      } catch {
        XCTAssertEqual(error as? UpdateArtifactSecurityError, securityError)
      }
      let failedState = await fixture.service.state
      let handoffCount = fixture.revealer.count
      XCTAssertEqual(failedState, .failed(.artifact))
      XCTAssertEqual(handoffCount, 0)
      XCTAssertTrue(try cachedArtifacts(in: fixture.store).isEmpty)
      XCTAssertEqual(try Data(contentsOf: installed), installedBytes)
    }

    let validator = FakeArtifactValidator()
    let fixture = try serviceFixture(validator: validator)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let installed = fixture.root.appending(path: "installed-app-bytes")
    let installedBytes = Data("do-not-touch-installed-app".utf8)
    try installedBytes.write(to: installed)
    _ = try await fixture.service.checkManually(identity: verificationIdentity(), now: now)
    _ = try await fixture.service.downloadAvailableUpdate()
    do {
      _ = try await fixture.service.handoff(
        explicitConsent: false, revealer: fixture.revealer)
      XCTFail("handoff must require consent")
    } catch {
      XCTAssertEqual(error as? AutoUpdateServiceError, .explicitConsentRequired)
    }
    let countBeforeReplacement = fixture.revealer.count
    XCTAssertEqual(countBeforeReplacement, 0)

    validator.failAfterFirstValidation = true
    do {
      _ = try await fixture.service.handoff(
        explicitConsent: true, revealer: fixture.revealer)
      XCTFail("replacement at final verification must fail")
    } catch {
      XCTAssertEqual(error as? UpdateArtifactSecurityError, .artifactReplaced)
    }
    let countAfterReplacement = fixture.revealer.count
    let replacementState = await fixture.service.state
    XCTAssertEqual(countAfterReplacement, 0)
    XCTAssertEqual(replacementState, .failed(.handoff))
    XCTAssertEqual(try Data(contentsOf: installed), installedBytes)
  }

  func testTEST_AU_CONTRACT_001_positiveHandoffNeedsTwoUserActionsAndNoAutomaticDownload()
    async throws
  {
    let fixture = try serviceFixture(validator: FakeArtifactValidator())
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let state = try await fixture.service.checkAutomaticallyIfDue(
      identity: verificationIdentity(), now: now)
    guard case .available = state else { return XCTFail("expected available") }
    XCTAssertEqual(fixture.streamer.artifactRequestCount, 0)
    XCTAssertTrue(try cachedArtifacts(in: fixture.store).isEmpty)

    do {
      _ = try await fixture.service.checkAutomaticallyIfDue(
        identity: verificationIdentity(), now: now.addingTimeInterval(60))
      XCTFail("automatic check must be rate limited")
    } catch {
      XCTAssertEqual(error as? AutoUpdateServiceError, .automaticCheckNotDue)
    }
    XCTAssertEqual(fixture.streamer.feedRequestCount, 1)

    let awaitingConsent = try await fixture.service.downloadAvailableUpdate()
    guard case .awaitingConsent(let feed, _) = awaitingConsent else {
      return XCTFail("expected final-consent state")
    }
    XCTAssertEqual(feed.payload.releaseNotesSummary, "Security and reliability improvements.")
    XCTAssertEqual(fixture.streamer.artifactRequestCount, 1)
    let countBeforeHandoff = fixture.revealer.count
    XCTAssertEqual(countBeforeHandoff, 0)
    _ = try await fixture.service.handoff(
      explicitConsent: true, revealer: fixture.revealer)
    let countAfterHandoff = fixture.revealer.count
    let handedOffState = await fixture.service.state
    XCTAssertEqual(countAfterHandoff, 1)
    guard case .handedOff = handedOffState else {
      return XCTFail("expected handed off")
    }
  }

  func testTEST_AU_CONTRACT_001_automaticChecksPersistDefaultOnAndUserOptOut() throws {
    let suiteName = "ArkDeckAutoUpdateContractTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.removePersistentDomain(forName: suiteName)

    let preferences = UserDefaultsAutoUpdatePreferences(defaults: defaults)
    XCTAssertTrue(preferences.automaticChecksEnabled())
    preferences.setAutomaticChecksEnabled(false)
    XCTAssertFalse(preferences.automaticChecksEnabled())
    let attempt = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-07-24T00:00:00Z"))
    preferences.recordCheckAttempt(attempt)
    XCTAssertEqual(preferences.lastCheckAttempt(), attempt)
    XCTAssertEqual(AutoUpdateApplicationFacade.normalizedApplicationVersion("1.4"), "1.4.0")
    XCTAssertEqual(AutoUpdateApplicationFacade.normalizedApplicationVersion("1.4.2"), "1.4.2")
    XCTAssertEqual(AutoUpdateApplicationFacade.normalizedApplicationVersion("01.4"), "01.4")
  }

  func testTEST_AU_CONTRACT_001_entitlementsDependenciesSecretsAndDisclosure() throws {
    let repository = repoRoot
    let entitlementData = try Data(
      contentsOf: repository.appending(path: "ArkDeckApp/ArkDeckApp.entitlements"))
    let entitlements = try XCTUnwrap(
      try PropertyListSerialization.propertyList(from: entitlementData, format: nil)
        as? [String: Bool])
    XCTAssertEqual(
      Set(entitlements.keys),
      [
        "com.apple.security.app-sandbox",
        "com.apple.security.device.serial",
        "com.apple.security.device.usb",
        "com.apple.security.files.bookmarks.app-scope",
        "com.apple.security.files.user-selected.read-write",
        "com.apple.security.network.client",
      ])
    XCTAssertTrue(entitlements.values.allSatisfy { $0 })

    let package = try String(
      contentsOf: repository.appending(path: "Packages/ArkDeckKit/Package.swift"),
      encoding: .utf8)
    XCTAssertFalse(package.contains(".package("))
    let project = try String(
      contentsOf: repository.appending(path: "ArkDeck.xcodeproj/project.pbxproj"),
      encoding: .utf8)
    XCTAssertFalse(project.contains("XCRemoteSwiftPackageReference"))
    let marketingVersions = project.split(separator: "\n").compactMap { line -> String? in
      guard line.contains("MARKETING_VERSION =") else { return nil }
      return line.split(separator: "=", maxSplits: 1)[1]
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
    }
    XCTAssertFalse(marketingVersions.isEmpty)
    XCTAssertTrue(marketingVersions.allSatisfy { UpdateSemanticVersion($0) != nil })
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: repository.appending(path: "Package.resolved").path))

    let privateMarker = ["-----BEGIN", "PRIVATE KEY-----"].joined(separator: " ")
    for relativePath in [
      "ArkDeckApp/App/ArkDeckApp.swift",
      "Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckCLIMain.swift",
      "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AutoUpdate",
    ] {
      XCTAssertFalse(
        try sourceTree(at: repository.appending(path: relativePath)).contains(privateMarker),
        "private-key material marker found under \(relativePath)")
    }
    let localization = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/Resources/Localizable.xcstrings"),
      encoding: .utf8)
    XCTAssertTrue(localization.contains("\"update.privacyDisclosure\""))
    XCTAssertTrue(localization.contains("ArkDeck version, macOS version, and CPU architecture"))
    XCTAssertTrue(localization.contains("No device ID, user path, locale, telemetry"))
    XCTAssertTrue(localization.contains("does not install, replace itself, update on quit"))
    XCTAssertTrue(localization.contains("\"update.status.automaticCheckIncomplete\""))
    XCTAssertTrue(localization.contains("automatic update check did not complete"))
    let appSource = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/App/ArkDeckApp.swift"),
      encoding: .utf8)
    XCTAssertTrue(appSource.contains("update.status.automaticCheckIncomplete"))
    XCTAssertFalse(appSource.contains("artifact.downloaded.url.lastPathComponent"))
    let cliSource = try String(
      contentsOf: repository.appending(
        path: "Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckCLIMain.swift"),
      encoding: .utf8)
    XCTAssertTrue(cliSource.contains("validateUnsignedPayloadForSigning(payload)"))
    let feedSource = try String(
      contentsOf: repository.appending(
        path: "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AutoUpdate/UpdateFeed.swift"),
      encoding: .utf8)
    XCTAssertTrue(feedSource.contains("UpdateNetworkContract.allowedHosts.contains(host)"))
    XCTAssertFalse(feedSource.contains("allowedArtifactHosts"))
    let releaseProcedure = try String(
      contentsOf: repository.appending(path: "docs/release/macos-auto-update.md"),
      encoding: .utf8)
    XCTAssertTrue(releaseProcedure.contains("openssl pkeyutl -sign -rawin"))
    XCTAssertTrue(releaseProcedure.contains("最后才发布签名 feed"))
    XCTAssertTrue(releaseProcedure.contains("不得成为 CLI 参数、环境变量"))
    XCTAssertTrue(releaseProcedure.contains("30 天有效期是强制 freshness 边界"))
    XCTAssertTrue(releaseProcedure.contains("不支持同版本续期"))
  }

  func testTEST_AU_CONTRACT_001_updateDiagnosticsUseClosedPublicEventsOnly() throws {
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
    XCTAssertTrue(bytes.contains(Data("\"eventName\":\"update.check\"".utf8)))
    XCTAssertTrue(bytes.contains(Data("\"eventName\":\"update.download\"".utf8)))
    XCTAssertTrue(bytes.contains(Data("\"eventName\":\"update.verification\"".utf8)))
    XCTAssertTrue(bytes.contains(Data("\"eventName\":\"update.handoff\"".utf8)))
    XCTAssertFalse(bytes.contains(Data("/Users/".utf8)))
    XCTAssertFalse(bytes.contains(Data("github.com".utf8)))
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
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try UpdateFeedCodec.decodeAndVerify(data, trust: trust), file: file, line: line
    ) { error in
      XCTAssertEqual(error as? UpdateFeedError, expected, file: file, line: line)
    }
  }

  private func assertVerificationError(
    _ data: Data,
    verifier: UpdateFeedVerifier,
    context: UpdateVerificationContext? = nil,
    expected: UpdateFeedError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try verifier.verify(data, context: context ?? verificationContext(), now: now),
      file: file, line: line
    ) { error in
      XCTAssertEqual(error as? UpdateFeedError, expected, file: file, line: line)
    }
  }

  private func assertUnsignedPayloadError(
    _ payload: UpdateFeedPayload,
    expected: UpdateFeedError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try UpdateFeedVerifier.validateUnsignedPayloadForSigning(payload),
      file: file, line: line
    ) { error in
      XCTAssertEqual(error as? UpdateFeedError, expected, file: file, line: line)
    }
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
    URL(fileURLWithPath: #filePath)
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

  func load() throws -> UpdateReplayRecord? {
    lock.withLock { record }
  }

  func save(_ record: UpdateReplayRecord) throws {
    lock.withLock { self.record = record }
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

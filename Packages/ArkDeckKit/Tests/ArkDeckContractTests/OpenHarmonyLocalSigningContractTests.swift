import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security
import XCTest

@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class OpenHarmonyLocalSigningContractTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path:
        "arkdeck-local-signing-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  func testSigningStepAcceptsRegisteredPresetReferencesAndTheLegacyConstant() throws {
    // The closed set of signing presets is the provider's: a preset registered
    // through `workspace preset register` is a `preset-` reference, the
    // legacy credential preset is `openharmony-release@1`. The step only
    // holds the argument to that grammar; anything else is refused before any
    // provider work.
    func step(_ preset: String) throws -> WorkflowStep {
      try WorkflowStep(
        id: "sign-hap", kind: .signWorkspaceOpenHarmonyHap, declaredEffect: .hostOnly,
        declaredCancellation: .atSafeBoundary, declaredBindingRequirement: .none,
        arguments: [
          "projectRef": .string("demo-app"),
          "signingPresetRef": .string(preset),
          "inputArtifactId": .string("ART-input"),
          "inputSha256": .string(String(repeating: "a", count: 64)),
        ])
    }
    XCTAssertNoThrow(try step("preset-4ad8fe99f82867e9e1a94e5d"))
    XCTAssertNoThrow(try step("openharmony-release@1"))
    for rejected in ["waterflow-release", "preset-", "preset-../x", "openharmony-release@2", ""] {
      XCTAssertThrowsError(try step(rejected), "\(rejected) must not name a signing preset") {
        error in
        XCTAssertTrue("\(error)".contains("signingPresetRef"), "\(error)")
      }
    }
  }

  func testCredentialOwnerPublishesPathFreeReferenceAndPinsExactOwners() throws {
    let fixture = try makeFixture(mode: "success")
    let owner = OpenHarmonySigningCredentialOwner(store: fixture.store)
    let (receipt, installed) = try owner.replace {
      try fixture.store.install(
        configuration: fixture.configuration,
        keystorePassword: Data("keystore-secret".utf8),
        keyPassword: Data("key-secret".utf8))
    }

    XCTAssertTrue(installed.credentialRef.hasPrefix("credential:sha256-"))
    XCTAssertEqual(installed.credentialRef.utf8.count, 82)
    XCTAssertEqual(installed.projectRef, receipt.projectRef)
    XCTAssertEqual(installed.referenceCount, 0)
    XCTAssertEqual(try owner.current(), installed)
    let publicBytes = try PortableCanonicalJSON.canonicalBytes(installed.projection)
    let publicText = String(decoding: publicBytes, as: UTF8.self)
    XCTAssertFalse(publicText.contains(root.path))
    XCTAssertFalse(publicText.contains(receipt.keystore.path))
    XCTAssertFalse(publicText.contains("keystore-secret"))
    XCTAssertFalse(publicText.contains("key-secret"))

    let presetRef = "preset-signing-fixture"
    try owner.acquire(installed.credentialRef, owner: presetRef)
    try owner.acquire(installed.credentialRef, owner: presetRef)
    XCTAssertEqual(try owner.current().referenceCount, 1)
    XCTAssertEqual(
      try owner.resolve(installed.credentialRef, owner: presetRef), receipt)
    XCTAssertThrowsError(
      try owner.resolve(installed.credentialRef, owner: "preset-not-an-owner"))
    try owner.release(installed.credentialRef, owner: presetRef)
    XCTAssertEqual(try owner.current().referenceCount, 0)
  }

  func testCredentialOwnerBlocksReplacementAndRemovalWhilePinned() throws {
    let fixture = try makeFixture(mode: "success")
    let owner = OpenHarmonySigningCredentialOwner(store: fixture.store)
    let (_, installed) = try owner.replace {
      try fixture.store.install(
        configuration: fixture.configuration,
        keystorePassword: Data("keystore-secret".utf8),
        keyPassword: Data("key-secret".utf8))
    }
    try owner.acquire(installed.credentialRef, owner: "preset-signing-fixture")

    var replacementRan = false
    XCTAssertThrowsError(
      try owner.replace {
        replacementRan = true
      } as (Void, OpenHarmonySigningCredentialResource))
    XCTAssertFalse(replacementRan)
    var removalRan = false
    XCTAssertThrowsError(
      try owner.remove {
        removalRan = true
      } as Void)
    XCTAssertFalse(removalRan)
    XCTAssertEqual(try owner.current().credentialRef, installed.credentialRef)
  }

  func testCredentialOwnerRecoversMutationMarkerAndRejectsLedgerDrift() throws {
    let fixture = try makeFixture(mode: "success")
    let owner = OpenHarmonySigningCredentialOwner(store: fixture.store)
    let (_, installed) = try owner.replace {
      try fixture.store.install(
        configuration: fixture.configuration,
        keystorePassword: Data("keystore-secret".utf8),
        keyPassword: Data("key-secret".utf8))
    }
    let ledgerURL = fixture.store.credentialOwnerRootURL.appending(
      path: "credential-owner-v1.json")
    var document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any])
    document["state"] = "replacing"
    try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(
      to: ledgerURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: ledgerURL.path)
    XCTAssertEqual(try owner.current().credentialRef, installed.credentialRef)

    document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any])
    document["credentialRef"] = "credential:sha256-" + String(repeating: "0", count: 64)
    try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(
      to: ledgerURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: ledgerURL.path)
    XCTAssertThrowsError(try owner.current()) { error in
      XCTAssertTrue("\(error)".contains("ledger does not match"), "\(error)")
    }
  }

  /// The two shapes an unsupported receipt can be found in, and the answer
  /// both used to get.
  ///
  /// Every read the owner did collapsed "no credential is installed" and "a
  /// credential is installed that this build cannot read" into one `nil`, and
  /// two of those reads then *wrote* that answer down: the first read of a
  /// root whose ledger is missing, and the recovery of an interrupted
  /// `replace`. Either one published `state: stable` with no credential
  /// reference over a receipt, a Keychain envelope and signing material that
  /// were all still on disk — after which `replace` and `remove` were free to
  /// run against them, and `current()` told the user nothing was installed.
  func testAnUnreadableReceiptIsNeverPublishedAsAnEmptyStableOwner() throws {
    let fixture = try makeFixture(mode: "success")
    let owner = OpenHarmonySigningCredentialOwner(store: fixture.store)
    let (receipt, installed) = try owner.replace {
      try fixture.store.install(
        configuration: fixture.configuration,
        keystorePassword: Data("keystore-secret".utf8),
        keyPassword: Data("key-secret".utf8))
    }
    let receiptURL = URL(filePath: fixture.store.receiptPath)
    let ledgerURL = fixture.store.credentialOwnerRootURL.appending(
      path: "credential-owner-v1.json")
    let envelopeAccount = try XCTUnwrap(receipt.secretEnvelopeAccount)

    // A receipt on a storage form this build retired. It is present, it is
    // not usable, and it is not absent.
    var retired = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
    retired["keychainAccessSchema"] = "trusted-applications-v3"
    let retiredBytes = try JSONSerialization.data(
      withJSONObject: retired, options: [.sortedKeys])
    try retiredBytes.write(to: receiptURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
    guard case .unusable = fixture.store.receiptState() else {
      return XCTFail("a present-but-unsupported receipt is not an absent one")
    }

    // Combination one: an unusable receipt with no owner ledger beside it.
    try FileManager.default.removeItem(at: ledgerURL)
    XCTAssertThrowsError(try owner.current()) { error in
      XCTAssertNotEqual(
        error as? OpenHarmonySigningError,
        .receiptUnavailable("signing credential is not installed"),
        "an unreadable credential must not be reported as an uninstalled one")
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: ledgerURL.path),
      "refusing to read must not durably publish an owner either")

    // Combination two: an unusable receipt found mid-`replace`.
    let interrupted: [String: Any] = [
      "schemaVersion": "arkdeck.signing-credential-owner/1",
      "state": "replacing",
      "credentialRef": installed.credentialRef,
      "presetOwners": [String](),
    ]
    try JSONSerialization.data(withJSONObject: interrupted, options: [.sortedKeys]).write(
      to: ledgerURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: ledgerURL.path)
    XCTAssertThrowsError(try owner.current())
    let settled = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any])
    XCTAssertEqual(
      settled["state"] as? String, "replacing",
      "an interrupted replace must not settle into a stable owner with no credential")
    XCTAssertEqual(settled["credentialRef"] as? String, installed.credentialRef)

    // Nothing was zeroed, replaced or deleted by any of it.
    XCTAssertEqual(try Data(contentsOf: receiptURL), retiredBytes)
    XCTAssertTrue(fixture.secrets.contains(account: envelopeAccount))
    XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.keystore.path))

    // The way out stays open. An explicit reinstall is a mutation, so it is
    // gated on ownership — which the ledger records by itself — and not on
    // re-reading the credential it is about to replace.
    let pinnedLedger: [String: Any] = [
      "schemaVersion": "arkdeck.signing-credential-owner/1",
      "state": "stable",
      "credentialRef": installed.credentialRef,
      "presetOwners": ["preset-signing-fixture"],
    ]
    try JSONSerialization.data(withJSONObject: pinnedLedger, options: [.sortedKeys]).write(
      to: ledgerURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: ledgerURL.path)
    var pinnedBodyRan = false
    XCTAssertThrowsError(
      try owner.replace { pinnedBodyRan = true } as (Void, OpenHarmonySigningCredentialResource))
    XCTAssertFalse(pinnedBodyRan, "a pinned credential is never replaced underneath its preset")

    try FileManager.default.removeItem(at: ledgerURL)
    let (_, reinstalled) = try owner.replace {
      try fixture.store.install(
        configuration: fixture.configuration,
        keystorePassword: Data("keystore-secret-2".utf8),
        keyPassword: Data("key-secret-2".utf8))
    }
    // The reference is content-derived, so reinstalling the same material
    // republishes the same identity — the point is that it is readable again.
    XCTAssertEqual(reinstalled.credentialRef, installed.credentialRef)
    XCTAssertEqual(try owner.current(), reinstalled)
    guard case .installed = fixture.store.receiptState() else {
      return XCTFail("an explicit reinstall must leave a receipt this build can honour")
    }

    // A genuinely empty root still adopts an empty owner: absence is the one
    // state that licenses publishing one.
    try FileManager.default.removeItem(at: receiptURL)
    try FileManager.default.removeItem(at: ledgerURL)
    guard case .absent = fixture.store.receiptState() else {
      return XCTFail("a root with no receipt is absent")
    }
    XCTAssertThrowsError(try owner.current()) { error in
      XCTAssertEqual(
        error as? OpenHarmonySigningError,
        .receiptUnavailable("signing credential is not installed"), "\(error)")
    }
  }

  /// Uninstall has to clear every envelope this preset ever wrote, including
  /// one a reinstall rotated away.
  ///
  /// A reinstall reuses the installed account only while the Keychain confirms
  /// it is there, and that probe answers `false` both for "gone" and for "this
  /// process may not look". So a reinstall during a moment the store cannot be
  /// read mints a new account beside a live item that still holds the user's
  /// passwords. The receipt records the account it rotated away so `remove`
  /// can finish the job; nothing ever reads from it.
  func testUninstallClearsAnEnvelopeThatAReinstallRotatedAway() throws {
    let fixture = try makeFixture(mode: "success")
    let first = try fixture.store.install(
      configuration: fixture.configuration,
      keystorePassword: Data("keystore-secret".utf8),
      keyPassword: Data("key-secret".utf8))
    let firstAccount = try XCTUnwrap(first.secretEnvelopeAccount)
    XCTAssertNil(first.supersededEnvelopeAccounts)

    // The store is momentarily unreadable, so reuse cannot be proven.
    fixture.secrets.keychainUnreadable = true
    let second = try fixture.store.install(
      configuration: fixture.configuration,
      keystorePassword: Data("keystore-secret-2".utf8),
      keyPassword: Data("key-secret-2".utf8))
    fixture.secrets.keychainUnreadable = false
    let secondAccount = try XCTUnwrap(second.secretEnvelopeAccount)
    XCTAssertNotEqual(secondAccount, firstAccount)
    XCTAssertEqual(second.supersededEnvelopeAccounts, [firstAccount])
    XCTAssertTrue(
      fixture.secrets.contains(account: firstAccount),
      "the rotated-away item is preserved, not deleted behind the user's back")

    let removal = try fixture.store.remove()
    XCTAssertTrue(removal.removedReceipt)
    XCTAssertFalse(fixture.secrets.contains(account: firstAccount))
    XCTAssertFalse(fixture.secrets.contains(account: secondAccount))
  }

  func testWorkspaceSigningPresetResolvesOnlyItsPinnedCredentialReference() throws {
    let fixture = try makeFixture(mode: "success")
    let owner = OpenHarmonySigningCredentialOwner(store: fixture.store)
    let (receipt, resource) = try owner.replace {
      try fixture.store.install(
        configuration: fixture.configuration,
        keystorePassword: Data("keystore-secret".utf8),
        keyPassword: Data("key-secret".utf8))
    }
    let workspacePresetRef = "preset-signing-owned"
    try owner.acquire(resource.credentialRef, owner: workspacePresetRef)
    let configured = try WorkspaceSigningPreset(
      presetID: workspacePresetRef, credentialRef: resource.credentialRef,
      timeoutSeconds: 600)
    let attempts = try OpenHarmonySigningAttemptStore(
      rootURL: root.appending(path: "owned-signing-attempts"))
    let provider = try makeProvider(
      store: fixture.store, attemptStore: attempts,
      credentialOwner: owner, workspaceSigningPreset: configured)
    let input = root.appending(path: "owned-signing-input.hap")
    let bytes = Data([0x50, 0x4b, 0x03, 0x04]) + Data("input".utf8)
    try bytes.write(to: input)
    let context = ProviderExecutionContext(
      jobID: "job-owned-signing", stepID: "sign-workspace-hap",
      targetID: "TGT-SIGN", bindingRevision: nil,
      nowUTC: "2026-08-10T00:00:00Z",
      resolvedInputArtifact: ProviderResolvedInputArtifact(
        artifactID: "ART-INPUT", fileURL: input,
        sha256: sha256(bytes), byteCount: bytes.count))

    let action = try signingAction(
      provider: provider.provider, context: context,
      presetRef: workspacePresetRef)
    guard case .workspace(.signOpenHarmonyHap(let signing)) = action else {
      return XCTFail("expected exact signing action")
    }
    XCTAssertEqual(signing.selectedSigningPresetRef, workspacePresetRef)
    XCTAssertEqual(signing.preset, receipt)
    XCTAssertThrowsError(
      try signingAction(
        provider: provider.provider, context: context,
        presetRef: receipt.presetID))
  }

  func testRegisteredProfileWithoutSigningPresetNeverFallsBackToFixedReceipt() throws {
    let fixture = try makeFixture(mode: "success")
    try installSecrets(in: fixture)
    let attempts = try OpenHarmonySigningAttemptStore(
      rootURL: root.appending(path: "registered-no-signing-attempts"))
    let provider = try makeProvider(
      store: fixture.store, attemptStore: attempts,
      allowsLegacySigningPresetFallback: false)
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(
        reference: OpenHarmonyLocalSigning.operationReference))
    XCTAssertEqual(
      provider.provider.runtimeAvailability(for: descriptor),
      .unavailable(
        code: .workspacePresetUnavailable,
        reason: "workspace.presetUnavailable"))

    let input = root.appending(path: "registered-no-signing-input.hap")
    let bytes = Data([0x50, 0x4b, 0x03, 0x04]) + Data("input".utf8)
    try bytes.write(to: input)
    let context = ProviderExecutionContext(
      jobID: "job-registered-no-signing", stepID: "sign-workspace-hap",
      targetID: "TGT-SIGN", bindingRevision: nil,
      nowUTC: "2026-08-10T00:00:00Z",
      resolvedInputArtifact: ProviderResolvedInputArtifact(
        artifactID: "ART-INPUT", fileURL: input,
        sha256: sha256(bytes), byteCount: bytes.count))
    XCTAssertThrowsError(
      try signingAction(provider: provider.provider, context: context)) { error in
        XCTAssertTrue("\(error)".contains("workspace.presetUnavailable"), "\(error)")
      }
  }

  func testLoginKeychainReadsUseOnlyModernNonInteractiveAuthenticationContext() throws {
    let options = LoginKeychainSigningSecretStore.nonInteractiveReadOptions()
    let context = try XCTUnwrap(
      options[kSecUseAuthenticationContext as String] as? LAContext)
    XCTAssertTrue(context.interactionNotAllowed)
    XCTAssertNil(options[kSecUseAuthenticationUI as String])
  }

  func testDataProtectionKeychainPresenceProbeIsGroupBoundAndNeverRequestsSecretData() throws {
    let query = LoginKeychainSigningSecretStore.presenceQuery(account: "fixture-account")
    XCTAssertEqual(query[kSecAttrAccount as String] as? String, "fixture-account")
    XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
    XCTAssertEqual(query[kSecReturnData as String] as? Bool, false)
    XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
    XCTAssertEqual(
      query[kSecAttrAccessGroup as String] as? String,
      ArkDeckHelperIdentity.keychainAccessGroup)
    let context = try XCTUnwrap(
      query[kSecUseAuthenticationContext as String] as? LAContext)
    XCTAssertTrue(context.interactionNotAllowed)
    XCTAssertNil(query[kSecUseAuthenticationUI as String])
  }

  func testExistingKeychainSecretUpdateDoesNotChurnAccessGroupIdentity() throws {
    let value = Data("replacement".utf8)
    let update = LoginKeychainSigningSecretStore.existingItemValueUpdate(value)
    XCTAssertEqual(update.count, 1)
    XCTAssertEqual(update[kSecValueData as String] as? Data, value)
    XCTAssertNil(update[kSecAttrAccess as String])
  }

  func testDaemonFingerprintChangesWhenDaemonBytesChange() throws {
    let opaqueIdentity = Data("same-designated-application".utf8)
    let firstExecutable = Data(SHA256.hash(data: Data("daemon-v1".utf8)))
    let secondExecutable = Data(SHA256.hash(data: Data("daemon-v2".utf8)))

    let first = LoginKeychainSigningSecretStore.daemonFingerprint(
      applicationIdentity: opaqueIdentity, executableSHA256: firstExecutable)
    let repeated = LoginKeychainSigningSecretStore.daemonFingerprint(
      applicationIdentity: opaqueIdentity, executableSHA256: firstExecutable)
    let replacement = LoginKeychainSigningSecretStore.daemonFingerprint(
      applicationIdentity: opaqueIdentity, executableSHA256: secondExecutable)

    XCTAssertEqual(first, repeated)
    XCTAssertNotEqual(
      first, replacement,
      "an unchanged code-signing identity must not hide rebuilt daemon bytes")
    XCTAssertEqual(first.utf8.count, 64)
  }

  func testSDKReleasePresetUpdatesDaemonReceiptWithoutReadingOrReplacingKeychainItem()
    async throws
  {
    let fixture = try makeSDKReleaseFixture(mode: "success")
    fixture.secrets.trustedDaemonIdentity = "stable-installed-daemon"
    let fixedNow = Date(timeIntervalSince1970: 1_786_406_400)
    let installer = OpenHarmonySDKReleasePresetInstaller(
      store: fixture.store, materialParentURL: fixture.presetRoot,
      now: { fixedNow })
    let configuration = OpenHarmonySDKReleasePresetConfiguration(
      projectRef: "demo-app", bundleName: "com.example.waterflowdemo",
      javaExecutable: fixture.java, sdkRoot: fixture.sdkRoot)

    let first = try await installer.install(configuration: configuration)
    XCTAssertEqual(first.presetID, OpenHarmonyLocalSigning.defaultPresetID)
    XCTAssertEqual(first.projectRef, "demo-app")
    XCTAssertEqual(first.keyAlias, "openharmony application release")
    XCTAssertEqual(first.signingAlgorithm, "SHA256withECDSA")
    XCTAssertEqual(
      first.keychainAccessSchema, OpenHarmonyLocalSigning.keychainAccessSchema)
    var runtimePair = try fixture.store.secretPair(for: first)
    XCTAssertEqual(
      runtimePair.keystore, OpenHarmonyLocalSigning.publicSDKReleasePassword())
    XCTAssertEqual(runtimePair.key, OpenHarmonyLocalSigning.publicSDKReleasePassword())
    XCTAssertEqual(
      fixture.secrets.secretReadCount, 0,
      "the official public SDK credential must not decrypt Keychain on the Runtime hot path")
    runtimePair.keystore.resetBytes(in: 0..<runtimePair.keystore.count)
    runtimePair.key.resetBytes(in: 0..<runtimePair.key.count)
    let firstAccount = try XCTUnwrap(first.secretEnvelopeAccount)
    let firstMaterial = URL(
      filePath: try XCTUnwrap(first.managedMaterialDirectory), directoryHint: .isDirectory)
    XCTAssertEqual(firstMaterial.deletingLastPathComponent().path, fixture.presetRoot.path)
    XCTAssertEqual(try permissions(firstMaterial.path) & 0o777, 0o700)
    for path in [first.keystore.path, first.appCertificate.path, first.signedProfile.path] {
      XCTAssertEqual(try permissions(path) & 0o777, 0o600)
      XCTAssertEqual(URL(filePath: path).deletingLastPathComponent(), firstMaterial)
    }
    let applicationCertificateChain = try String(
      contentsOf: URL(filePath: first.appCertificate.path), encoding: .utf8)
    XCTAssertEqual(
      applicationCertificateChain.components(separatedBy: "-----BEGIN CERTIFICATE-----").count - 1,
      3,
      "the managed app certificate must be the complete SDK root/CA/application chain")
    XCTAssertTrue(applicationCertificateChain.contains("fixture-application-root"))
    XCTAssertTrue(applicationCertificateChain.contains("fixture-application-ca"))
    XCTAssertTrue(applicationCertificateChain.contains("fixture-release-certificate"))
    XCTAssertFalse(applicationCertificateChain.contains("fixture-profile-release"))
    let profile = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(
          contentsOf: URL(
            filePath: first.signedProfile.path))) as? [String: Any])
    XCTAssertEqual(profile["type"] as? String, "release")
    XCTAssertNil(profile["debug-info"])
    let bundle = try XCTUnwrap(profile["bundle-info"] as? [String: Any])
    XCTAssertEqual(bundle["bundle-name"] as? String, "com.example.waterflowdemo")
    let validity = try XCTUnwrap(profile["validity"] as? [String: Any])
    XCTAssertEqual(
      (validity["not-before"] as? NSNumber)?.int64Value,
      Int64(fixedNow.timeIntervalSince1970) - 300)
    XCTAssertEqual(
      (validity["not-after"] as? NSNumber)?.int64Value,
      Int64(fixedNow.timeIntervalSince1970) + 365 * 24 * 60 * 60)
    XCTAssertTrue(fixture.store.status().ready)

    let receiptURL = URL(filePath: fixture.store.receiptPath)
    var legacyDocument = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
    legacyDocument["keychainAccessSchema"] = "trusted-applications-v2"
    try JSONSerialization.data(
      withJSONObject: legacyDocument, options: [.prettyPrinted, .sortedKeys]
    ).write(to: receiptURL, options: .atomic)
    XCTAssertFalse(
      fixture.store.status().ready,
      "ordinary Runtime readiness must not accept an obsolete ACL schema")

    fixture.secrets.trustedDaemonIdentity = "replacement-installed-daemon"
    // A receipt on a storage form this build does not support is refused by
    // name. It is not upgraded in place: no secret is read, the Keychain item
    // is left exactly where it is, and the material on disk is untouched.
    XCTAssertThrowsError(try fixture.store.refreshDaemonKeychainIdentity()) { error in
      // The refusal names the entry that fixes it, so an operator is never
      // told only that something is wrong.
      XCTAssertTrue(
        "\(error)".contains("arkdeck runtime signing install"), "\(error)")
    }
    XCTAssertEqual(fixture.secrets.secretReadCount, 0)
    XCTAssertTrue(fixture.secrets.contains(account: firstAccount))
    XCTAssertTrue(FileManager.default.fileExists(atPath: firstMaterial.path))

    // The way back is the current supported entry, stated explicitly.
    let second = try await installer.install(configuration: configuration)
    let reboundAccount = try XCTUnwrap(second.secretEnvelopeAccount)
    XCTAssertNotEqual(reboundAccount, firstAccount)
    XCTAssertEqual(
      second.keychainAccessSchema, OpenHarmonyLocalSigning.keychainAccessSchema)
    let secondMaterial = try XCTUnwrap(second.managedMaterialDirectory)
    XCTAssertNotEqual(secondMaterial, firstMaterial.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: secondMaterial))
    // The material the unusable receipt pointed at is left on disk. Reclaiming
    // it would mean deleting installed material on the strength of a document
    // this build could not read, which is the one thing reconfiguration is not
    // allowed to do; the user removes it when they choose to.
    XCTAssertTrue(FileManager.default.fileExists(atPath: firstMaterial.path))

    let removal = try fixture.store.remove()
    XCTAssertTrue(removal.removedReceipt)
    XCTAssertTrue(removal.removedKeystorePassword)
    XCTAssertTrue(removal.removedKeyPassword)
    XCTAssertTrue(removal.removedManagedMaterial)
    XCTAssertTrue(removal.preservedSourcePaths.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: secondMaterial))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: fixture.sdkRoot.appending(
          path:
            "toolchains/lib/OpenHarmony.p12"
        ).path),
      "removing ArkDeck's preset must preserve the SDK source bundle")
  }

  func testSDKReleaseInstallRepublishesOverARetiredACLReceiptWithoutMigratingIt()
    async throws
  {
    let fixture = try makeSDKReleaseFixture(mode: "success")
    fixture.secrets.trustedDaemonIdentity = "stable-installed-daemon"
    let installer = OpenHarmonySDKReleasePresetInstaller(
      store: fixture.store, materialParentURL: fixture.presetRoot)
    let configuration = OpenHarmonySDKReleasePresetConfiguration(
      bundleName: "com.example.waterflowdemo",
      javaExecutable: fixture.java, sdkRoot: fixture.sdkRoot)
    let first = try await installer.install(configuration: configuration)
    let firstAccount = try XCTUnwrap(first.secretEnvelopeAccount)

    // Forward-readable receipts written before the access schema marker may
    // carry an ACL that exposes attributes to the CLI but denies value reads
    // to the LaunchAgent. An explicit reinstall must not trust that markerless
    // item merely because the daemon's designated requirement is unchanged.
    let retired = OpenHarmonySigningPresetReceipt(
      schemaVersion: first.schemaVersion, installedAtUTC: first.installedAtUTC,
      presetID: first.presetID, projectRef: first.projectRef,
      javaExecutable: first.javaExecutable, signerJAR: first.signerJAR,
      keystore: first.keystore, appCertificate: first.appCertificate,
      signedProfile: first.signedProfile, keyAlias: first.keyAlias,
      signingAlgorithm: first.signingAlgorithm,
      keystorePasswordAccount: first.keystorePasswordAccount,
      keyPasswordAccount: first.keyPasswordAccount,
      secretEnvelopeAccount: first.secretEnvelopeAccount,
      trustedDaemonApplicationSHA256: first.trustedDaemonApplicationSHA256,
      keychainAccessSchema: nil,
      managedMaterialDirectory: first.managedMaterialDirectory)
    try JSONEncoder().encode(retired).write(
      to: URL(filePath: fixture.store.receiptPath), options: .atomic)

    // Nothing reads it and nothing repairs it: absent a marker this build
    // supports, the preset is simply unusable until it is reinstalled.
    XCTAssertFalse(fixture.store.status().ready)
    XCTAssertThrowsError(try fixture.store.loadValidated(requireSecrets: false))
    guard case .unusable = fixture.store.receiptState() else {
      return XCTFail("a receipt that is present but unsupported is not an absent one")
    }

    let republished = try await installer.install(configuration: configuration)
    XCTAssertNotEqual(republished.secretEnvelopeAccount, firstAccount)
    XCTAssertEqual(
      republished.keychainAccessSchema, OpenHarmonyLocalSigning.keychainAccessSchema)
    // The item the retired receipt named is left in place. Reconfiguration
    // publishes a new credential; it never deletes material the user still has.
    XCTAssertTrue(fixture.secrets.contains(account: firstAccount))
    XCTAssertTrue(fixture.store.status().ready)
  }

  func testSDKReleasePresetFailurePreservesPreviousReceiptAndMaterial() async throws {
    let marker = root.appending(path: "sdk-profile-verified-once")
    let fixture = try makeSDKReleaseFixture(
      mode: "verify-profile-succeed-once:\(marker.path)")
    fixture.secrets.trustedDaemonIdentity = "stable-installed-daemon"
    let installer = OpenHarmonySDKReleasePresetInstaller(
      store: fixture.store, materialParentURL: fixture.presetRoot)
    let configuration = OpenHarmonySDKReleasePresetConfiguration(
      bundleName: "com.example.waterflowdemo",
      javaExecutable: fixture.java, sdkRoot: fixture.sdkRoot)
    let previous = try await installer.install(configuration: configuration)
    let previousMaterial = try XCTUnwrap(previous.managedMaterialDirectory)

    do {
      _ = try await installer.install(configuration: configuration)
      XCTFail("a failed exact profile readback must not replace the ready preset")
    } catch {
      XCTAssertTrue("\(error)".contains("verify-profile readback"), "\(error)")
    }
    XCTAssertEqual(try fixture.store.loadValidated(), previous)
    XCTAssertTrue(FileManager.default.fileExists(atPath: previousMaterial))
    let managedDirectories = try FileManager.default.contentsOfDirectory(
      at: fixture.presetRoot, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("sdk-release-") }
    XCTAssertEqual(
      managedDirectories.map { $0.resolvingSymlinksInPath().path },
      [URL(filePath: previousMaterial).resolvingSymlinksInPath().path])
  }

  func testSDKReleaseCLIRequiresExplicitAbsoluteSDKAndJavaPaths() async throws {
    let fixture = try makeSDKReleaseFixture(mode: "success")
    do {
      try await RuntimeCLI.runSigningAsync(
        [
          "install-sdk-release", "--sdk", "relative-sdk",
          "--java", fixture.java.path,
          "--bundle-name", "com.example.waterflowdemo", "--json",
        ], store: fixture.store, materialParentURL: fixture.presetRoot)
      XCTFail("the maintenance CLI must not guess a relative SDK path")
    } catch {
      XCTAssertTrue("\(error)".contains("--sdk must be an absolute path"), "\(error)")
    }
    do {
      try await RuntimeCLI.runSigningAsync(
        [
          "install-sdk-release", "--sdk", fixture.sdkRoot.path,
          "--java", "java",
          "--bundle-name", "com.example.waterflowdemo", "--json",
        ], store: fixture.store, materialParentURL: fixture.presetRoot)
      XCTFail("the maintenance CLI must not guess Java through PATH")
    } catch {
      XCTAssertTrue("\(error)".contains("--java must be an absolute path"), "\(error)")
    }
  }

  func testDevEcoMigrationRejectsABuildDaemonPathBeforeKeychainAccess() throws {
    XCTAssertThrowsError(
      try RuntimeCLI.runSigning([
        "migrate-deveco",
        "--build-profile", root.appending(path: "missing.json5").path,
        "--daemon", root.appending(path: "build/arkdeck-agentd").path,
        "--json",
      ])
    ) { error in
      XCTAssertTrue(
        String(describing: error).contains("canonical installed LaunchAgent daemon"),
        "unexpected error: \(error)")
    }
  }

  /// Replacing the daemon must stay repairable by the process that replaced it.
  ///
  /// `agentd update` installs a new daemon and then calls
  /// `refreshDaemonKeychainIdentity` to re-record the trusted identity the
  /// receipt pins. That re-record is a receipt-file write — it neither reads
  /// nor rewrites the secret envelope — but it used to sit behind
  /// `contains(account:)`, which answers `false` both for "the envelope is
  /// gone" and for "this process may not look". The maintenance CLI runs
  /// without the shared Keychain access group, so it always got the second and
  /// was told the first: the update swapped the daemon, aborted the repair,
  /// and left the preset permanently drifted with no supported way back —
  /// every signing operation unavailable from then on.
  func testDaemonIdentityRebindSurvivesAKeychainThisProcessCannotRead() throws {
    let fixture = try makeFixture(mode: "success")
    fixture.secrets.trustedDaemonIdentity = "daemon-before-update"
    let receipt = try fixture.store.install(
      configuration: fixture.configuration,
      keystorePassword: Data("keystore-secret".utf8),
      keyPassword: Data("key-secret".utf8))
    let envelope = try XCTUnwrap(receipt.secretEnvelopeAccount)
    XCTAssertEqual(receipt.trustedDaemonApplicationSHA256, "daemon-before-update")

    // The daemon was replaced, and the repairing process cannot see the
    // Keychain at all — the envelope is still there, it just cannot be probed.
    fixture.secrets.trustedDaemonIdentity = "daemon-after-update"
    fixture.secrets.keychainUnreadable = true
    try fixture.store.refreshDaemonKeychainIdentity()
    fixture.secrets.keychainUnreadable = false
    let rebound = try fixture.store.loadValidated()
    XCTAssertEqual(rebound.trustedDaemonApplicationSHA256, "daemon-after-update")
    XCTAssertEqual(rebound.secretEnvelopeAccount, envelope, "the envelope is untouched")
    XCTAssertEqual(fixture.secrets.secretReadCount, 0, "no secret was read to rebind")

    // And an envelope the Keychain positively says is gone still refuses:
    // that is a broken preset, not an unreadable one.
    fixture.secrets.trustedDaemonIdentity = "daemon-after-second-update"
    XCTAssertTrue(try fixture.secrets.remove(account: envelope))
    XCTAssertThrowsError(try fixture.store.refreshDaemonKeychainIdentity()) { error in
      XCTAssertTrue(
        String(describing: error).contains("envelope is absent"),
        "unexpected error: \(error)")
    }
    XCTAssertEqual(
      try fixture.store.loadValidated(requireSecrets: false)
        .trustedDaemonApplicationSHA256,
      "daemon-after-update",
      "a refused rebind must not have rewritten the receipt")
  }

  func testPresetInstallStatusDriftAndRemovalArePrivateAndReversible() throws {
    let fixture = try makeFixture(mode: "success")
    fixture.secrets.trustedDaemonIdentity = "stable-daemon-v1"
    let receipt = try fixture.store.install(
      configuration: fixture.configuration,
      keystorePassword: Data("keystore-secret".utf8),
      keyPassword: Data("key-secret".utf8))

    let status = fixture.store.status()
    XCTAssertTrue(status.installed)
    XCTAssertTrue(status.ready, status.diagnostics.joined(separator: " | "))
    XCTAssertTrue(status.keystorePasswordPresent)
    XCTAssertTrue(status.keyPasswordPresent)
    XCTAssertEqual(status.javaSHA256, receipt.javaExecutable.sha256)
    XCTAssertEqual(status.signerJARSHA256, receipt.signerJAR.sha256)
    XCTAssertEqual(status.keystoreSHA256, receipt.keystore.sha256)
    XCTAssertEqual(status.appCertificateSHA256, receipt.appCertificate.sha256)
    XCTAssertEqual(status.signedProfileSHA256, receipt.signedProfile.sha256)
    let receiptBytes = try Data(contentsOf: URL(filePath: status.receiptPath))
    XCTAssertFalse(receiptBytes.contains(Data("keystore-secret".utf8)))
    XCTAssertFalse(receiptBytes.contains(Data("key-secret".utf8)))
    XCTAssertEqual(try permissions(status.receiptPath) & 0o777, 0o600)
    XCTAssertEqual(try permissions(root.appending(path: "preset").path) & 0o777, 0o700)
    let envelopeAccount = try XCTUnwrap(receipt.secretEnvelopeAccount)
    XCTAssertTrue(fixture.secrets.contains(account: envelopeAccount))
    XCTAssertFalse(fixture.secrets.contains(account: receipt.keystorePasswordAccount))
    XCTAssertFalse(fixture.secrets.contains(account: receipt.keyPasswordAccount))
    try fixture.store.refreshDaemonKeychainIdentity()
    XCTAssertEqual(fixture.secrets.secretReadCount, 0)
    fixture.secrets.trustedDaemonIdentity = "stable-daemon-v2"
    try fixture.store.refreshDaemonKeychainIdentity()
    let rebound = try fixture.store.loadValidated()
    XCTAssertEqual(rebound.secretEnvelopeAccount, envelopeAccount)
    XCTAssertEqual(fixture.secrets.secretReadCount, 0)
    XCTAssertEqual(rebound.trustedDaemonApplicationSHA256, "stable-daemon-v2")
    var reboundPair = try fixture.store.secretPair(for: rebound)
    XCTAssertEqual(reboundPair.keystore, Data("keystore-secret".utf8))
    XCTAssertEqual(reboundPair.key, Data("key-secret".utf8))
    reboundPair.keystore.resetBytes(in: 0..<reboundPair.keystore.count)
    reboundPair.key.resetBytes(in: 0..<reboundPair.key.count)

    try Data("drifted".utf8).write(to: URL(filePath: receipt.signerJAR.path))
    let drifted = fixture.store.status()
    XCTAssertFalse(drifted.ready)
    XCTAssertTrue(drifted.diagnostics.joined().contains("drift"))

    let removal = try fixture.store.remove()
    XCTAssertTrue(removal.removedReceipt)
    XCTAssertTrue(removal.removedKeystorePassword)
    XCTAssertTrue(removal.removedKeyPassword)
    XCTAssertFalse(removal.removedManagedMaterial)
    for path in removal.preservedSourcePaths {
      XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
    XCTAssertFalse(fixture.store.status().installed)
  }

  /// A DevEco auto-signing fixture: the `material/` tree beside the keystore
  /// that binds DevEco's password ciphertext, one encrypted password, and the
  /// plaintext it decodes to.
  private func makeDevEcoPasswordFixture(
    directory: String = "deveco-config"
  ) throws -> (config: URL, keystore: URL, encrypted: String, expected: Data) {
    let config = root.appending(path: directory, directoryHint: .isDirectory)
    let material = config.appending(path: "material", directoryHint: .isDirectory)
    let fd = material.appending(path: "fd", directoryHint: .isDirectory)
    let ac = material.appending(path: "ac", directoryHint: .isDirectory)
    let ce = material.appending(path: "ce", directoryHint: .isDirectory)
    for directory in [fd, ac, ce] {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    }
    let parts = [
      Data(repeating: 0x11, count: 16),
      Data(repeating: 0x42, count: 16),
      Data(repeating: 0xA5, count: 16),
    ]
    for (index, part) in parts.enumerated() {
      let slot = fd.appending(path: "\(index)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: slot, withIntermediateDirectories: false)
      try part.write(to: slot.appending(path: "part-\(index)"))
    }
    let salt = Data((0..<16).map(UInt8.init))
    try salt.write(to: ac.appending(path: "salt"))
    let fixedComponent = Data([
      49, 243, 9, 115, 214, 175, 91, 184,
      211, 190, 177, 88, 101, 131, 192, 119,
    ])
    var combined = parts[0]
    for part in parts.dropFirst() { xorTestBytes(part, into: &combined) }
    xorTestBytes(fixedComponent, into: &combined)
    let passwordMaterial = Data(String(decoding: combined, as: UTF8.self).utf8)
    let rootKey = testPBKDF2SHA256(
      password: passwordMaterial, salt: salt, iterations: 10_000,
      outputByteCount: 16)
    let workKey = Data((0..<16).map { UInt8(0xD0 + $0) })
    try testDevEcoEnvelope(
      workKey, key: rootKey, nonceByte: 0x21
    ).write(to: ce.appending(path: "work-key"))
    let expected = Data("deveco-plaintext-password".utf8)
    let encrypted = try testDevEcoEnvelope(
      expected, key: workKey, nonceByte: 0x37
    )
    .map { String(format: "%02x", $0) }.joined()
    let keystore = config.appending(path: "release.p12")
    try Data("fixture".utf8).write(to: keystore)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: keystore.path)
    return (config, keystore, encrypted, expected)
  }

  func testDevEcoEncryptedPasswordsDecodeOnlyAtTheInstallAndRekeyBoundaries() throws {
    let (config, keystore, encrypted, expected) = try makeDevEcoPasswordFixture()
    let ce = config.appending(path: "material", directoryHint: .isDirectory)
      .appending(path: "ce", directoryHint: .isDirectory)

    XCTAssertEqual(
      try OpenHarmonyDevEcoPasswordDecoder.decodeIfNeeded(
        Data(encrypted.utf8), keystore: keystore),
      expected)
    let ordinary = Data("ordinary-plaintext".utf8)
    XCTAssertEqual(
      try OpenHarmonyDevEcoPasswordDecoder.decodeIfNeeded(
        ordinary, keystore: keystore),
      ordinary)
    let longHexPlaintext = Data(String(repeating: "a", count: 64).utf8)
    XCTAssertEqual(
      try OpenHarmonyDevEcoPasswordDecoder.decodeIfNeeded(
        longHexPlaintext, keystore: keystore),
      longHexPlaintext)

    let jar = config.appending(path: "hap-sign-tool.jar")
    let certificate = config.appending(path: "release.cer")
    let profile = config.appending(path: "release.p7b")
    try Data("jar".utf8).write(to: jar)
    try Data("certificate".utf8).write(to: certificate)
    try Data("profile".utf8).write(to: profile)
    let secrets = MemorySigningSecretStore()
    let store = OpenHarmonySigningPresetStore(
      rootURL: root.appending(path: "normalized-preset"),
      secrets: secrets,
      nowUTC: { "2026-08-10T00:00:00Z" })
    let receipt = try store.install(
      configuration: OpenHarmonySigningPresetConfiguration(
        javaExecutable: productsDirectory.appending(
          path:
            "ArkDeckFakeHapSignerFixture"
        ).resolvingSymlinksInPath(),
        signerJAR: jar, keystore: keystore,
        appCertificate: certificate, signedProfile: profile,
        keyAlias: "test-key"),
      // Decoded at the boundary, exactly as the interactive and
      // `--build-profile` install paths decode before they reach the store.
      // There is no in-place repair entry behind them: what is stored is what
      // the boundary produced.
      keystorePassword: expected,
      keyPassword: expected)
    var installedPair = try store.secretPair(for: store.loadValidated())
    XCTAssertEqual(installedPair.keystore, expected)
    XCTAssertEqual(installedPair.key, expected)
    installedPair.keystore.resetBytes(in: 0..<installedPair.keystore.count)
    installedPair.key.resetBytes(in: 0..<installedPair.key.count)

    let buildProfile = config.appending(path: "build-profile.json5")
    try Data(
      """
      {
        app: {
          signingConfigs: [{
            storePassword: "\(encrypted)",
            keyPassword: "\(encrypted)",
            storeFile: "\(keystore.path)"
          }]
        }
      }
      """.utf8
    ).write(to: buildProfile, options: .atomic)
    try RuntimeCLI.runSigning(
      [
        "migrate-deveco", "--build-profile", buildProfile.path,
        "--daemon", productsDirectory.appending(path: "arkdeck-agentd").path,
        "--key-alias", "debugkey",
        "--json",
      ], store: store)
    let rekeyedReceipt = try store.loadValidated()
    XCTAssertEqual(rekeyedReceipt.keyAlias, "debugkey")
    let envelopeAccount = try XCTUnwrap(rekeyedReceipt.secretEnvelopeAccount)
    // Re-keying rewrites the value of the preset's one envelope item; it does
    // not mint a second account or leave a retired one behind.
    XCTAssertEqual(envelopeAccount, receipt.secretEnvelopeAccount)
    XCTAssertTrue(secrets.contains(account: envelopeAccount))
    var rekeyedPair = try store.secretPair(for: rekeyedReceipt)
    XCTAssertEqual(rekeyedPair.keystore, expected)
    XCTAssertEqual(rekeyedPair.key, expected)
    rekeyedPair.keystore.resetBytes(in: 0..<rekeyedPair.keystore.count)
    rekeyedPair.key.resetBytes(in: 0..<rekeyedPair.key.count)
    let rekeyedStatus = store.status()
    XCTAssertTrue(rekeyedStatus.ready, rekeyedStatus.diagnostics.joined(separator: " | "))
    XCTAssertTrue(rekeyedStatus.keystorePasswordPresent)
    XCTAssertTrue(rekeyedStatus.keyPasswordPresent)
    try store.refreshDaemonKeychainIdentity()
    XCTAssertEqual(try store.loadValidated().secretEnvelopeAccount, envelopeAccount)

    try RuntimeCLI.runSigning(
      [
        "migrate-deveco", "--build-profile", buildProfile.path,
        "--daemon", productsDirectory.appending(path: "arkdeck-agentd").path,
        "--json",
      ], store: store)
    XCTAssertEqual(try store.loadValidated().secretEnvelopeAccount, envelopeAccount)
    XCTAssertEqual(try store.loadValidated().keyAlias, "debugkey")

    let replacement = try store.replaceSecretEnvelope(
      keystorePassword: Data("replacement-keystore-secret".utf8),
      keyPassword: Data("replacement-key-secret".utf8))
    XCTAssertFalse(replacement.createdEnvelopeItem)
    XCTAssertEqual(replacement.envelopeAccount, envelopeAccount)
    var replacementPair = try store.secretPair(for: store.loadValidated())
    XCTAssertEqual(replacementPair.keystore, Data("replacement-keystore-secret".utf8))
    XCTAssertEqual(replacementPair.key, Data("replacement-key-secret".utf8))
    replacementPair.keystore.resetBytes(in: 0..<replacementPair.keystore.count)
    replacementPair.key.resetBytes(in: 0..<replacementPair.key.count)

    XCTAssertThrowsError(
      try store.replaceSecretEnvelope(
        keystorePassword: Data("replacement-keystore-secret".utf8),
        keyPassword: Data("replacement-key-secret".utf8),
        keyAlias: "invalid/alias"))
    XCTAssertEqual(try store.loadValidated().keyAlias, "debugkey")

    secrets.trustedDaemonIdentity = "installed-daemon-v2"
    try RuntimeCLI.runSigning(
      [
        "migrate-deveco", "--build-profile", buildProfile.path,
        "--daemon", productsDirectory.appending(path: "arkdeck-agentd").path,
        "--json",
      ], store: store)
    let reboundReceipt = try store.loadValidated()
    XCTAssertEqual(reboundReceipt.secretEnvelopeAccount, envelopeAccount)
    XCTAssertEqual(
      reboundReceipt.trustedDaemonApplicationSHA256, "installed-daemon-v2")

    let mismatchedKeystore = config.appending(path: "mismatched.p12")
    try Data("different-keystore".utf8).write(to: mismatchedKeystore)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: mismatchedKeystore.path)
    let mismatchedProfile = config.appending(path: "mismatched-build-profile.json5")
    try Data(
      """
      {
        app: {
          signingConfigs: [{
            storePassword: "\(encrypted)",
            keyPassword: "\(encrypted)",
            storeFile: "\(mismatchedKeystore.path)"
          }]
        }
      }
      """.utf8
    ).write(to: mismatchedProfile, options: .atomic)
    let receiptBeforeMismatch = try store.loadValidated()
    XCTAssertThrowsError(
      try RuntimeCLI.runSigning(
        [
          "migrate-deveco", "--build-profile", mismatchedProfile.path,
          "--daemon", productsDirectory.appending(path: "arkdeck-agentd").path,
          "--json",
        ], store: store)
    ) { error in
      XCTAssertTrue("\(error)".contains("does not match the installed preset"), "\(error)")
    }
    XCTAssertEqual(try store.loadValidated(), receiptBeforeMismatch)
    let missingProfile = config.appending(path: "missing-build-profile.json5")
    try Data(
      """
      {
        app: {
          signingConfigs: [{
            storePassword: "\(encrypted)",
            keyPassword: "\(encrypted)",
            storeFile: "\(config.appending(path: "missing.p12").path)"
          }]
        }
      }
      """.utf8
    ).write(to: missingProfile, options: .atomic)
    XCTAssertThrowsError(
      try RuntimeCLI.runSigning(
        [
          "migrate-deveco", "--build-profile", missingProfile.path,
          "--daemon", productsDirectory.appending(path: "arkdeck-agentd").path,
          "--json",
        ], store: store))
    XCTAssertEqual(try store.loadValidated(), receiptBeforeMismatch)

    try Data(repeating: 0, count: 48).write(
      to: ce.appending(path: "work-key"), options: .atomic)
    XCTAssertThrowsError(
      try OpenHarmonyDevEcoPasswordDecoder.decodeIfNeeded(
        Data(encrypted.utf8), keystore: keystore))
  }

  func testSigningInstallReadsDevEcoPasswordsFromABuildProfileWithoutATTY() throws {
    // DevEco auto-signing passwords are machine-generated ciphertext a person
    // never sees, so a headless host cannot type them. `signing install
    // --build-profile` reads them from the DevEco build profile that names
    // this exact keystore and decodes them at the same boundary the
    // interactive install uses; a build profile naming another storeFile is
    // refused before any secret is touched.
    let (config, keystore, encrypted, expected) = try makeDevEcoPasswordFixture(
      directory: "deveco-headless-config")
    let jar = config.appending(path: "hap-sign-tool.jar")
    let certificate = config.appending(path: "release.cer")
    let profile = config.appending(path: "release.p7b")
    try Data("jar".utf8).write(to: jar)
    try Data("certificate".utf8).write(to: certificate)
    try Data("profile".utf8).write(to: profile)
    let buildProfile = config.appending(path: "build-profile.json5")
    try Data(
      """
      {
        app: {
          signingConfigs: [{
            storePassword: "\(encrypted)",
            keyPassword: "\(encrypted)",
            storeFile: "\(keystore.path)"
          }]
        }
      }
      """.utf8
    ).write(to: buildProfile, options: .atomic)
    let java = productsDirectory.appending(path: "ArkDeckFakeHapSignerFixture")
      .resolvingSymlinksInPath()
    let store = OpenHarmonySigningPresetStore(
      rootURL: root.appending(path: "headless-preset"),
      secrets: MemorySigningSecretStore(),
      nowUTC: { "2026-09-02T00:00:00Z" })

    let otherKeystore = config.appending(path: "other.p12")
    try Data("other".utf8).write(to: otherKeystore)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: otherKeystore.path)
    XCTAssertThrowsError(
      try RuntimeCLI.runSigning(
        [
          "install", "--java", java.path, "--jar", jar.path,
          "--keystore", otherKeystore.path, "--certificate", certificate.path,
          "--profile", profile.path, "--key-alias", "debugkey",
          "--build-profile", buildProfile.path, "--json",
        ], store: store)
    ) { error in
      XCTAssertTrue("\(error)".contains("different storeFile"), "\(error)")
    }
    XCTAssertFalse(store.status().installed)

    try RuntimeCLI.runSigning(
      [
        "install", "--java", java.path, "--jar", jar.path,
        "--keystore", keystore.path, "--certificate", certificate.path,
        "--profile", profile.path, "--key-alias", "debugkey",
        "--build-profile", buildProfile.path, "--json",
      ], store: store)
    let receipt = try store.loadValidated()
    XCTAssertEqual(receipt.keyAlias, "debugkey")
    var pair = try store.secretPair(for: receipt)
    XCTAssertEqual(pair.keystore, expected, "the DevEco ciphertext must be decoded, not stored")
    XCTAssertEqual(pair.key, expected)
    pair.keystore.resetBytes(in: 0..<pair.keystore.count)
    pair.key.resetBytes(in: 0..<pair.key.count)
    XCTAssertTrue(store.status().ready, store.status().diagnostics.joined(separator: " | "))
  }

  func testPresetRejectsSymlinkAndPermissionWideningAndReceiptFieldDrift() throws {
    let symlinkFixture = try makeFixture(mode: "success")
    let linkedJAR = root.appending(path: "linked-signer.jar")
    try FileManager.default.createSymbolicLink(
      at: linkedJAR, withDestinationURL: symlinkFixture.configuration.signerJAR)
    let linkedConfiguration = OpenHarmonySigningPresetConfiguration(
      javaExecutable: symlinkFixture.configuration.javaExecutable,
      signerJAR: linkedJAR,
      keystore: symlinkFixture.configuration.keystore,
      appCertificate: symlinkFixture.configuration.appCertificate,
      signedProfile: symlinkFixture.configuration.signedProfile,
      keyAlias: symlinkFixture.configuration.keyAlias)
    XCTAssertThrowsError(
      try symlinkFixture.store.install(
        configuration: linkedConfiguration,
        keystorePassword: Data("keystore-secret".utf8),
        keyPassword: Data("key-secret".utf8)))

    let fixture = try makeFixture(mode: "success")
    _ = try fixture.store.install(
      configuration: fixture.configuration,
      keystorePassword: Data("keystore-secret".utf8),
      keyPassword: Data("key-secret".utf8))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: fixture.configuration.keystore.path)
    XCTAssertFalse(fixture.store.status().ready)

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: fixture.configuration.keystore.path)
    let receiptURL = URL(filePath: fixture.store.receiptPath)
    var receipt =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: receiptURL)) as! [String: Any]
    receipt["signingAlgorithm"] = "caller-selected-algorithm"
    try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(
      to: receiptURL)
    XCTAssertFalse(fixture.store.status().ready)
  }

  func testPresetUpdateRestoresExistingKeychainSecretsWhenReceiptReplacementFails() throws {
    let fixture = try makeFixture(mode: "success")
    let receipt = try fixture.store.install(
      configuration: fixture.configuration,
      keystorePassword: Data("old-keystore-secret".utf8),
      keyPassword: Data("old-key-secret".utf8))
    let receiptURL = URL(filePath: fixture.store.receiptPath)
    try FileManager.default.removeItem(at: receiptURL)
    try FileManager.default.createDirectory(at: receiptURL, withIntermediateDirectories: false)

    XCTAssertThrowsError(
      try fixture.store.install(
        configuration: fixture.configuration,
        keystorePassword: Data("replacement-keystore-secret".utf8),
        keyPassword: Data("replacement-key-secret".utf8)))
    var restored = try fixture.store.secretPair(for: receipt)
    XCTAssertEqual(restored.keystore, Data("old-keystore-secret".utf8))
    XCTAssertEqual(restored.key, Data("old-key-secret".utf8))
    restored.keystore.resetBytes(in: 0..<restored.keystore.count)
    restored.key.resetBytes(in: 0..<restored.key.count)
  }

  func testJARDriftAfterPlanMaterializationRefusesBeforeSpawn() async throws {
    let fixture = try makeFixture(mode: "success")
    try installSecrets(in: fixture)
    let attempts = try OpenHarmonySigningAttemptStore(
      rootURL: root.appending(path: "jar-drift-attempts"))
    let provider = try makeProvider(store: fixture.store, attemptStore: attempts)
    let input = root.appending(path: "jar-drift-input.hap")
    let bytes = Data([0x50, 0x4b, 0x03, 0x04]) + Data("input".utf8)
    try bytes.write(to: input)
    let context = ProviderExecutionContext(
      jobID: "job-jar-drift", stepID: "sign-workspace-hap",
      targetID: "TGT-SIGN", bindingRevision: nil,
      nowUTC: "2026-08-10T00:00:00Z",
      resolvedInputArtifact: ProviderResolvedInputArtifact(
        artifactID: "ART-INPUT", fileURL: input,
        sha256: sha256(bytes), byteCount: bytes.count))
    let action = try signingAction(provider: provider.provider, context: context)
    guard case .workspace(.signOpenHarmonyHap(let signingAction)) = action else {
      return XCTFail("expected signing action")
    }
    XCTAssertTrue(signingAction.verifyArguments.contains("-outCertChain"))
    XCTAssertFalse(signingAction.verifyArguments.contains("-outCertchain"))
    let plan = try provider.provider.lower(action: action, context: context)
    try Data("drift-after-materialization".utf8).write(
      to: fixture.configuration.signerJAR)
    let generic = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: provider.profile))
    let dispatcher = OpenHarmonySigningWorkspaceDispatcher(
      fallback: generic, presetStore: fixture.store)
    do {
      _ = try await dispatcher.dispatch(plan)
      XCTFail("JAR drift must refuse before the signer process")
    } catch {
      XCTAssertTrue("\(error)".contains("before dispatch"), "\(error)")
    }
    let paths = attempts.paths(jobID: context.jobID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.directory))
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.signedHAP))
  }

  func testSigningPlanUsesStandardHAPModeWithInteractivePasswordsOnly() throws {
    let fixture = try makeFixture(mode: "success")
    try installSecrets(in: fixture)
    let attempts = try OpenHarmonySigningAttemptStore(
      rootURL: root.appending(path: "standard-hap-attempts"))
    let provider = try makeProvider(
      store: fixture.store,
      attemptStore: attempts)
    // Runtime Artifact payloads deliberately use only their Artifact ID and
    // therefore do not carry the original `.hap` suffix.
    let input = root.appending(path: "ART-INPUT")
    let bytes = Data([0x50, 0x4b, 0x03, 0x04]) + Data("input".utf8)
    try bytes.write(to: input)
    let context = ProviderExecutionContext(
      jobID: "job-standard-hap", stepID: "sign-workspace-hap",
      targetID: "TGT-SIGN", bindingRevision: nil,
      nowUTC: "2026-08-10T00:00:00Z",
      resolvedInputArtifact: ProviderResolvedInputArtifact(
        artifactID: "ART-INPUT", fileURL: input,
        sha256: sha256(bytes), byteCount: bytes.count))
    let action = try signingAction(provider: provider.provider, context: context)
    let plan = try provider.provider.lower(action: action, context: context)
    guard case .process(_, let arguments, _) = plan.kind else {
      return XCTFail("signing must lower to a closed process plan")
    }
    XCTAssertFalse(arguments.contains("-signCode"))
    XCTAssertFalse(arguments.contains("-keyPwd"))
    XCTAssertFalse(arguments.contains("-keystorePwd"))
    let inputIndex = try XCTUnwrap(arguments.firstIndex(of: "-inFile"))
    XCTAssertEqual(
      arguments[inputIndex + 1],
      attempts.paths(jobID: context.jobID).stagedUnsignedHAP)
    XCTAssertTrue(
      attempts.paths(jobID: context.jobID).certificateChainReadback.hasSuffix(".cer"),
      "hapsigner verify-app only accepts a certificate-chain output with its supported .cer suffix")
    XCTAssertEqual(Array(arguments.suffix(2)), ["-pwdInputMode", "1"])
  }

  func testSigningIsUnavailableBeforeAdmissionWithoutRuntimeArtifactStore() async throws {
    let fixture = try makeFixture(mode: "success")
    try installSecrets(in: fixture)
    let provider = try makeProvider(
      store: fixture.store,
      attemptStore: try OpenHarmonySigningAttemptStore(
        rootURL: root.appending(path: "missing-artifact-store-attempts")))
    let generic = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: provider.profile))
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: root.appending(path: "missing-artifact-engine")),
      providers: DeviceProviderRegistry(providers: [provider.provider]),
      dispatcher: RuntimeProcessDispatcherRouter(
        hdc: generic, rockchip: generic,
        workspace: OpenHarmonySigningWorkspaceDispatcher(
          fallback: generic, presetStore: fixture.store)),
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: root.appending(path: "missing-artifact-capabilities")),
      nowUTC: { "2026-08-10T00:00:00Z" })
    let availabilities = await engine.operationAvailability()
    let availability = try XCTUnwrap(
      availabilities.first {
        $0.reference == OpenHarmonyLocalSigning.operationReference
      })
    XCTAssertEqual(availability.state, .unavailable)
    XCTAssertTrue(availability.reasons.contains("runtime.artifactStoreUnavailable"))

    let request = try RuntimeOperationRequest(
      requestID: "request-no-artifact-store",
      idempotencyKey: "idempotency-no-artifact-store",
      target: DurableTargetReference(targetID: "TGT-SIGN"),
      operation: RuntimeOperationReference(
        id: "workspace.sign-openharmony-hap", version: 1),
      inputs: [
        "projectRef": .string(OpenHarmonyLocalSigning.defaultProjectRef),
        "signingPresetRef": .string(OpenHarmonyLocalSigning.defaultPresetID),
        "unsignedHapArtifactLease": .string("lease-v1:missing:artifact"),
      ])
    do {
      _ = try await engine.submit(try JSONEncoder().encode(request))
      XCTFail("signing must refuse before Job admission without an Artifact store")
    } catch {
      XCTAssertTrue("\(error)".contains("runtime.artifactStoreUnavailable"), "\(error)")
    }
  }

  func testPromptAndVerifyFaultsNeverProduceAVerifiedResult() async throws {
    for mode in ["unknown-prompt", "repeat-prompt", "verify-failure", "empty-profile"] {
      let fixture = try makeFixture(mode: mode)
      try installSecrets(in: fixture)
      let attempts = try OpenHarmonySigningAttemptStore(
        rootURL: root.appending(path: "fault-attempts-\(mode)"))
      let provider = try makeProvider(store: fixture.store, attemptStore: attempts)
      let input = root.appending(path: "fault-input-\(mode).hap")
      let bytes = Data([0x50, 0x4b, 0x03, 0x04]) + Data("input".utf8)
      try bytes.write(to: input)
      let context = ProviderExecutionContext(
        jobID: "job-fault-\(mode)", stepID: "sign-workspace-hap",
        targetID: "TGT-SIGN", bindingRevision: nil,
        nowUTC: "2026-08-10T00:00:00Z",
        resolvedInputArtifact: ProviderResolvedInputArtifact(
          artifactID: "ART-INPUT", fileURL: input,
          sha256: sha256(bytes), byteCount: bytes.count))
      let action = try signingAction(provider: provider.provider, context: context)
      let generic = DescriptorBoundProcessDispatcher(
        resolver: WorkspaceActionExecutableResolver(profile: provider.profile))
      let dispatcher = OpenHarmonySigningWorkspaceDispatcher(
        fallback: generic, presetStore: fixture.store)
      do {
        _ = try await dispatcher.dispatch(
          try provider.provider.lower(action: action, context: context))
        XCTFail("\(mode) must not verify")
      } catch {
        let message = "\(error)"
        XCTAssertTrue(
          message.contains("requires readback") || message.contains("requires recovery"),
          "\(mode): \(error)")
      }
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: attempts.paths(jobID: context.jobID).resultRecord), mode)
    }
  }

  func testTypedRuntimeSignsPublishesReportAndPreservesSourceBindingWithoutSecrets()
    async throws
  {
    let fixture = try makeFixture(mode: "success")
    try installSecrets(in: fixture)
    let artifacts = try RuntimeArtifactStore(
      rootURL: root.appending(path: "artifacts"),
      nowUTC: { "2026-08-10T00:00:00Z" })
    let sourceURL = root.appending(path: "unsigned.hap")
    let sourceBytes = Data([0x50, 0x4b, 0x03, 0x04]) + Data("unsigned-body".utf8)
    try sourceBytes.write(to: sourceURL)
    let sourceSHA = sha256(sourceBytes)
    let source = try await artifacts.publishFile(
      RuntimeArtifactFilePublicationRequest(
        jobID: "import-job", sessionID: "import-session", stepID: "import-hap",
        name: "unsigned.hap", mediaType: "application/vnd.openharmony.hap",
        privacy: .standard, retentionClass: .pinnedUntilVerified,
        sourceOperation: "artifact.import-hap", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-SIGN", bindingRevision: 7,
          stableIdentitySHA256: String(repeating: "a", count: 64)),
        sourceFileURL: sourceURL, expectedByteCount: sourceBytes.count,
        expectedSHA256: sourceSHA))
    let sourceLease = try await artifacts.leaseReference(
      jobID: source.jobID, artifactID: source.artifactID)

    let attempts = try OpenHarmonySigningAttemptStore(
      rootURL: root.appending(path: "signing-attempts"))
    let provider = try makeProvider(
      store: fixture.store, attemptStore: attempts)
    let generic = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: provider.profile))
    let signing = OpenHarmonySigningWorkspaceDispatcher(
      fallback: generic, presetStore: fixture.store)
    let engineState = root.appending(path: "engine")
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: engineState),
      providers: DeviceProviderRegistry(providers: [provider.provider]),
      dispatcher: RuntimeProcessDispatcherRouter(
        hdc: generic, rockchip: generic, workspace: signing),
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: root.appending(path: "capabilities")),
      artifactStore: artifacts,
      nowUTC: { "2026-08-10T00:00:00Z" })
    let request = try RuntimeOperationRequest(
      requestID: "request-sign", idempotencyKey: "idempotency-sign",
      target: DurableTargetReference(targetID: "TGT-SIGN"),
      operation: RuntimeOperationReference(
        id: "workspace.sign-openharmony-hap", version: 1),
      inputs: [
        "projectRef": .string(OpenHarmonyLocalSigning.defaultProjectRef),
        "signingPresetRef": .string(OpenHarmonyLocalSigning.defaultPresetID),
        "unsignedHapArtifactLease": .string(sourceLease),
      ])
    let accepted = try await engine.submit(try JSONEncoder().encode(request))
    let status = try await engine.run(jobID: accepted.jobID)
    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))

    let published = try await artifacts.list(jobID: accepted.jobID)
    let signed = try XCTUnwrap(published.first { $0.name == "signed.hap" })
    let report = try XCTUnwrap(published.first { $0.name == "signing-report.json" })
    XCTAssertTrue(signed.status.isPublished)
    XCTAssertTrue(report.status.isPublished)
    XCTAssertEqual(signed.bindingSnapshot, source.bindingSnapshot)
    XCTAssertEqual(report.bindingSnapshot, source.bindingSnapshot)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: attempts.paths(jobID: accepted.jobID).directory),
      "a known terminal must remove its bounded provider-owned signing directory")
    let signedLease = try await artifacts.leaseReference(
      jobID: signed.jobID, artifactID: signed.artifactID)
    let resolvedSigned = try await artifacts.resolveLease(signedLease)
    XCTAssertTrue(
      try Data(contentsOf: resolvedSigned.fileURL).starts(with: [0x50, 0x4b, 0x03, 0x04]))

    let durableFiles = try regularFiles(below: root)
    for url in durableFiles {
      let bytes = (try? Data(contentsOf: url)) ?? Data()
      XCTAssertFalse(bytes.contains(Data("keystore-secret".utf8)), url.path)
      XCTAssertFalse(bytes.contains(Data("key-secret".utf8)), url.path)
    }

    let wrongTarget = try RuntimeOperationRequest(
      requestID: "request-sign-wrong-target",
      idempotencyKey: "idempotency-sign-wrong-target",
      target: DurableTargetReference(targetID: "TGT-OTHER"),
      operation: RuntimeOperationReference(
        id: "workspace.sign-openharmony-hap", version: 1),
      inputs: request.inputs)
    do {
      _ = try await engine.submit(try JSONEncoder().encode(wrongTarget))
      XCTFail("a source Artifact from another target must be rejected")
    } catch {
      XCTAssertTrue("\(error)".contains("target/binding/identity"), "\(error)")
    }
  }

  func testPTYSecretEchoFailsClosedWithoutSignedOutputOrResult() async throws {
    let fixture = try makeFixture(mode: "echo-secret")
    try installSecrets(in: fixture)
    let attempts = try OpenHarmonySigningAttemptStore(
      rootURL: root.appending(path: "echo-attempts"))
    let provider = try makeProvider(store: fixture.store, attemptStore: attempts)
    let input = root.appending(path: "echo-input.hap")
    let bytes = Data([0x50, 0x4b, 0x03, 0x04]) + Data("input".utf8)
    try bytes.write(to: input)
    let context = ProviderExecutionContext(
      jobID: "job-secret-echo", stepID: "sign-workspace-hap",
      targetID: "TGT-SIGN", bindingRevision: nil,
      nowUTC: "2026-08-10T00:00:00Z",
      resolvedInputArtifact: ProviderResolvedInputArtifact(
        artifactID: "ART-INPUT", fileURL: input,
        sha256: sha256(bytes), byteCount: bytes.count))
    let action = try signingAction(provider: provider.provider, context: context)
    let plan = try provider.provider.lower(action: action, context: context)
    let generic = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: provider.profile))
    let dispatcher = OpenHarmonySigningWorkspaceDispatcher(
      fallback: generic, presetStore: fixture.store)
    do {
      _ = try await dispatcher.dispatch(plan)
      XCTFail("a signer that echoes a secret must fail closed")
    } catch {
      XCTAssertTrue("\(error)".contains("privacyFailure"), "\(error)")
    }
    let paths = attempts.paths(jobID: context.jobID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.signedHAP))
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.resultRecord))
  }

  func testSignerNonzeroExitReportsOnlyClosedPTYDiagnostics() async throws {
    let fixture = try makeFixture(mode: "sign-failure")
    try installSecrets(in: fixture)
    let attempts = try OpenHarmonySigningAttemptStore(
      rootURL: root.appending(path: "nonzero-attempts"))
    let provider = try makeProvider(store: fixture.store, attemptStore: attempts)
    let input = root.appending(path: "nonzero-input.hap")
    let bytes = Data([0x50, 0x4b, 0x03, 0x04]) + Data("input".utf8)
    try bytes.write(to: input)
    let context = ProviderExecutionContext(
      jobID: "job-nonzero", stepID: "sign-workspace-hap",
      targetID: "TGT-SIGN", bindingRevision: nil,
      nowUTC: "2026-08-10T00:00:00Z",
      resolvedInputArtifact: ProviderResolvedInputArtifact(
        artifactID: "ART-INPUT", fileURL: input,
        sha256: sha256(bytes), byteCount: bytes.count))
    let action = try signingAction(provider: provider.provider, context: context)
    let generic = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: provider.profile))
    let dispatcher = OpenHarmonySigningWorkspaceDispatcher(
      fallback: generic, presetStore: fixture.store)
    do {
      _ = try await dispatcher.dispatch(
        try provider.provider.lower(action: action, context: context))
      XCTFail("a signer nonzero exit must not verify")
    } catch {
      let message = "\(error)"
      XCTAssertTrue(message.contains("termination=exit:74"), message)
      XCTAssertTrue(message.contains("completedPrompts=2"), message)
      XCTAssertTrue(message.contains("observedOutputBytes="), message)
      XCTAssertTrue(message.contains("diagnosticCode=keystorePasswordRejected"), message)
      XCTAssertFalse(message.contains("keystore-secret"), message)
      XCTAssertFalse(message.contains("key-secret"), message)
    }
    let paths = attempts.paths(jobID: context.jobID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.signedHAP))
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.resultRecord))
  }

  func testSignerCertificateChainFailureUsesClosedDiagnostic() async throws {
    let fixture = try makeFixture(mode: "certificate-chain-failure")
    try installSecrets(in: fixture)
    let attempts = try OpenHarmonySigningAttemptStore(
      rootURL: root.appending(path: "certificate-chain-attempts"))
    let provider = try makeProvider(store: fixture.store, attemptStore: attempts)
    let input = root.appending(path: "certificate-chain-input.hap")
    let bytes = Data([0x50, 0x4b, 0x03, 0x04]) + Data("input".utf8)
    try bytes.write(to: input)
    let context = ProviderExecutionContext(
      jobID: "job-certificate-chain", stepID: "sign-workspace-hap",
      targetID: "TGT-SIGN", bindingRevision: nil,
      nowUTC: "2026-08-10T00:00:00Z",
      resolvedInputArtifact: ProviderResolvedInputArtifact(
        artifactID: "ART-INPUT", fileURL: input,
        sha256: sha256(bytes), byteCount: bytes.count))
    let action = try signingAction(provider: provider.provider, context: context)
    let generic = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: provider.profile))
    let dispatcher = OpenHarmonySigningWorkspaceDispatcher(
      fallback: generic, presetStore: fixture.store)
    do {
      _ = try await dispatcher.dispatch(
        try provider.provider.lower(action: action, context: context))
      XCTFail("an incomplete application certificate chain must not verify")
    } catch {
      let message = "\(error)"
      XCTAssertTrue(message.contains("diagnosticCode=certificateChainRejected"), message)
      XCTAssertFalse(message.contains("keystore-secret"), message)
      XCTAssertFalse(message.contains("key-secret"), message)
    }
    let paths = attempts.paths(jobID: context.jobID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.signedHAP))
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.resultRecord))
  }

  func testRecoveryVerifiesExistingOutputWithoutReplayingSign() async throws {
    let fixture = try makeFixture(mode: "success")
    try installSecrets(in: fixture)
    let attempts = try OpenHarmonySigningAttemptStore(
      rootURL: root.appending(path: "recovery-attempts"))
    let provider = try makeProvider(store: fixture.store, attemptStore: attempts)
    let input = root.appending(path: "recovery-input.hap")
    let bytes = Data([0x50, 0x4b, 0x03, 0x04]) + Data("input".utf8)
    try bytes.write(to: input)
    let context = ProviderExecutionContext(
      jobID: "job-recovery", stepID: "sign-workspace-hap",
      targetID: "TGT-SIGN", bindingRevision: nil,
      nowUTC: "2026-08-10T00:00:00Z",
      resolvedInputArtifact: ProviderResolvedInputArtifact(
        artifactID: "ART-INPUT", fileURL: input,
        sha256: sha256(bytes), byteCount: bytes.count))
    let action = try signingAction(provider: provider.provider, context: context)
    let generic = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: provider.profile))
    let dispatcher = OpenHarmonySigningWorkspaceDispatcher(
      fallback: generic, presetStore: fixture.store)
    _ = try await dispatcher.dispatch(
      try provider.provider.lower(action: action, context: context))
    guard case .workspace(.signOpenHarmonyHap(let signingAction)) = action else {
      return XCTFail("expected signing action")
    }
    let original = try Data(contentsOf: URL(filePath: signingAction.output.signedHAP))
    try FileManager.default.removeItem(atPath: signingAction.output.resultRecord)
    let legacyOutput = OpenHarmonySigningAttemptPaths(
      directory: signingAction.output.directory,
      signedHAP: signingAction.output.signedHAP,
      certificateChainReadback: URL(filePath: signingAction.output.directory)
        .appending(path: "certificate-chain.pem").path,
      profileReadback: signingAction.output.profileReadback,
      resultRecord: signingAction.output.resultRecord)
    let legacyAction = TypedProviderAction.workspace(
      .signOpenHarmonyHap(
        WorkspaceOpenHarmonySigningAction(
          jobID: signingAction.jobID, projectRef: signingAction.projectRef,
          signingPresetRef: nil, preset: signingAction.preset,
          inputArtifactID: signingAction.inputArtifactID,
          inputFilePath: signingAction.inputFilePath, inputSHA256: signingAction.inputSHA256,
          inputByteCount: signingAction.inputByteCount, output: legacyOutput)))
    let recovered = try await provider.provider.reconcile(
      intent: ProviderDurableIntentReference(
        jobID: context.jobID, stepID: context.stepID,
        intentEventID: "intent-recovery", action: legacyAction),
      context: context)
    guard case .confirmedCompleted(let summary) = recovered else {
      return XCTFail("verified existing output should recover: \(recovered)")
    }
    XCTAssertEqual(summary["verification"], "verified")
    XCTAssertEqual(
      try Data(contentsOf: URL(filePath: signingAction.output.signedHAP)), original)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: legacyOutput.supportedCertificateChainReadback))
    XCTAssertTrue(FileManager.default.fileExists(atPath: signingAction.output.resultRecord))
  }

  func testRuntimeRecoveryPublishesVerifiedOutputThenResumesWithoutReplay() async throws {
    let marker = root.appending(path: "verify-failed-once")
    let fixture = try makeFixture(mode: "verify-once:\(marker.path)")
    try installSecrets(in: fixture)
    let artifacts = try RuntimeArtifactStore(
      rootURL: root.appending(path: "recovery-artifacts"),
      nowUTC: { "2026-08-10T00:00:00Z" })
    let sourceURL = root.appending(path: "runtime-recovery-unsigned.hap")
    let sourceBytes = Data([0x50, 0x4b, 0x03, 0x04]) + Data("unsigned-body".utf8)
    try sourceBytes.write(to: sourceURL)
    let source = try await artifacts.publishFile(
      RuntimeArtifactFilePublicationRequest(
        jobID: "recovery-import", sessionID: "recovery-import-session",
        stepID: "import-hap", name: "unsigned.hap",
        mediaType: "application/vnd.openharmony.hap", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "artifact.import-hap", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-RECOVERY", bindingRevision: 9,
          stableIdentitySHA256: String(repeating: "b", count: 64)),
        sourceFileURL: sourceURL, expectedByteCount: sourceBytes.count,
        expectedSHA256: sha256(sourceBytes)))
    let sourceLease = try await artifacts.leaseReference(
      jobID: source.jobID, artifactID: source.artifactID)
    let attempts = try OpenHarmonySigningAttemptStore(
      rootURL: root.appending(path: "runtime-recovery-attempts"))
    let provider = try makeProvider(store: fixture.store, attemptStore: attempts)
    let generic = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: provider.profile))
    let signing = OpenHarmonySigningWorkspaceDispatcher(
      fallback: generic, presetStore: fixture.store)
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: root.appending(path: "recovery-engine")),
      providers: DeviceProviderRegistry(providers: [provider.provider]),
      dispatcher: RuntimeProcessDispatcherRouter(
        hdc: generic, rockchip: generic, workspace: signing),
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: root.appending(path: "recovery-capabilities")),
      artifactStore: artifacts,
      nowUTC: { "2026-08-10T00:00:00Z" })
    let request = try RuntimeOperationRequest(
      requestID: "request-runtime-recovery",
      idempotencyKey: "idempotency-runtime-recovery",
      target: DurableTargetReference(targetID: "TGT-RECOVERY"),
      operation: RuntimeOperationReference(
        id: "workspace.sign-openharmony-hap", version: 1),
      inputs: [
        "projectRef": .string(OpenHarmonyLocalSigning.defaultProjectRef),
        "signingPresetRef": .string(OpenHarmonyLocalSigning.defaultPresetID),
        "unsignedHapArtifactLease": .string(sourceLease),
      ])
    let accepted = try await engine.submit(try JSONEncoder().encode(request))
    let first = try await engine.run(jobID: accepted.jobID)
    XCTAssertEqual(first.state, "waitingForRecovery")
    XCTAssertTrue(first.outcomeUnknown)
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: attempts.paths(jobID: accepted.jobID).signedHAP))
    let beforeRecoveryArtifacts = try await artifacts.list(jobID: accepted.jobID)
    XCTAssertTrue(beforeRecoveryArtifacts.isEmpty)

    let reconciled = try await engine.reconcile(jobID: accepted.jobID)
    XCTAssertEqual(reconciled.state, "resumeAtConfirmedSafeBoundary")
    XCTAssertFalse(reconciled.outcomeUnknown)
    let recoveredArtifacts = try await artifacts.list(jobID: accepted.jobID)
    XCTAssertEqual(Set(recoveredArtifacts.map(\.name)), ["signed.hap", "signing-report.json"])
    XCTAssertTrue(recoveredArtifacts.allSatisfy { $0.bindingSnapshot == source.bindingSnapshot })

    let terminal = try await engine.run(jobID: accepted.jobID)
    XCTAssertEqual(terminal.state, "succeeded", terminal.timeline.joined(separator: " | "))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: attempts.paths(jobID: accepted.jobID).directory))
  }

  private struct SigningFixture {
    let store: OpenHarmonySigningPresetStore
    let secrets: MemorySigningSecretStore
    let configuration: OpenHarmonySigningPresetConfiguration
  }

  private struct SDKReleaseFixture {
    let store: OpenHarmonySigningPresetStore
    let secrets: MemorySigningSecretStore
    let presetRoot: URL
    let sdkRoot: URL
    let java: URL
  }

  private struct SigningProvider {
    let profile: WorkspaceProjectProfile
    let provider: WorkspaceOperationsProvider
  }

  private func makeFixture(mode: String) throws -> SigningFixture {
    let materials = root.appending(path: "materials-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
    let jar = materials.appending(path: "hap-sign-tool.jar")
    let keystore = materials.appending(path: "release.p12")
    let certificate = materials.appending(path: "release.cer")
    let profile = materials.appending(path: "release.p7b")
    try Data(mode.utf8).write(to: jar)
    try Data("keystore-fixture".utf8).write(to: keystore)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: keystore.path)
    try Data("certificate-fixture".utf8).write(to: certificate)
    try Data("profile-fixture".utf8).write(to: profile)
    let secrets = MemorySigningSecretStore()
    let store = OpenHarmonySigningPresetStore(
      rootURL: root.appending(path: "preset"),
      secrets: secrets,
      nowUTC: { "2026-08-10T00:00:00Z" })
    return SigningFixture(
      store: store, secrets: secrets,
      configuration: OpenHarmonySigningPresetConfiguration(
        javaExecutable: productsDirectory.appending(
          path:
            "ArkDeckFakeHapSignerFixture"
        ).resolvingSymlinksInPath(),
        signerJAR: jar, keystore: keystore,
        appCertificate: certificate, signedProfile: profile,
        keyAlias: "test-key"))
  }

  private func makeSDKReleaseFixture(mode: String) throws -> SDKReleaseFixture {
    let sdkRoot = root.appending(
      path:
        "openharmony-sdk-\(UUID().uuidString)", directoryHint: .isDirectory)
    let library = sdkRoot.appending(path: "toolchains/lib", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try Data(mode.utf8).write(to: library.appending(path: "hap-sign-tool.jar"))
    let keystore = library.appending(path: "OpenHarmony.p12")
    try Data("sdk-release-keystore-fixture".utf8).write(to: keystore)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: keystore.path)
    let profileCertificate = """
      -----BEGIN CERTIFICATE-----
      fixture-application-root
      -----END CERTIFICATE-----
      -----BEGIN CERTIFICATE-----
      fixture-application-ca
      -----END CERTIFICATE-----
      -----BEGIN CERTIFICATE-----
      fixture-profile-release
      -----END CERTIFICATE-----

      """
    try Data(profileCertificate.utf8).write(
      to: library.appending(path: "OpenHarmonyProfileRelease.pem"))
    let certificate =
      "-----BEGIN CERTIFICATE-----\nfixture-release-certificate\n-----END CERTIFICATE-----\n"
    let template: [String: Any] = [
      "type": "release",
      "app-distribution-type": "os_integration",
      "issuer": "pki_internal",
      "bundle-info": [
        "bundle-name": "com.example.replace",
        "apl": "normal",
        "app-feature": "hos_normal_app",
        "distribution-certificate": certificate,
      ],
      "uuid": "00000000-0000-0000-0000-000000000000",
      "validity": ["not-before": 0, "not-after": 1],
    ]
    try JSONSerialization.data(withJSONObject: template, options: [.sortedKeys]).write(
      to: library.appending(path: "UnsgnedReleasedProfileTemplate.json"))
    let presetRoot = root.appending(
      path:
        "sdk-release-preset-\(UUID().uuidString)", directoryHint: .isDirectory)
    let secrets = MemorySigningSecretStore()
    return SDKReleaseFixture(
      store: OpenHarmonySigningPresetStore(
        rootURL: presetRoot, secrets: secrets,
        nowUTC: { "2026-08-11T00:00:00Z" }),
      secrets: secrets, presetRoot: presetRoot, sdkRoot: sdkRoot,
      java: productsDirectory.appending(
        path:
          "ArkDeckFakeHapSignerFixture"
      ).resolvingSymlinksInPath())
  }

  private func installSecrets(in fixture: SigningFixture) throws {
    _ = try fixture.store.install(
      configuration: fixture.configuration,
      keystorePassword: Data("keystore-secret".utf8),
      keyPassword: Data("key-secret".utf8))
  }

  private func makeProvider(
    store: OpenHarmonySigningPresetStore,
    attemptStore: OpenHarmonySigningAttemptStore,
    credentialOwner: OpenHarmonySigningCredentialOwner? = nil,
    workspaceSigningPreset: WorkspaceSigningPreset? = nil,
    allowsLegacySigningPresetFallback: Bool = true
  ) throws -> SigningProvider {
    let workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let tool = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/printf")
    let inspection = try WorkspaceCommandPreset(
      presetID: "inspect", executable: tool, fixedArguments: [], timeoutSeconds: 10)
    let patch = try WorkspaceCommandPreset(
      presetID: "patch", executable: tool, fixedArguments: [], timeoutSeconds: 10)
    let profile = try WorkspaceProjectProfile(
      profileID: "signing-test@1",
      projectRef: OpenHarmonyLocalSigning.defaultProjectRef,
      projectRoot: workspace.path, allowedFileGlobs: ["Sources/**"],
      inspectionPreset: inspection, patchPreset: patch,
      buildPresets: [:], testPresets: [:], symbolPresets: [:],
      signingPresets: workspaceSigningPreset.map { [$0.presetID: $0] } ?? [:],
      allowsLegacySigningPresetFallback: allowsLegacySigningPresetFallback)
    return SigningProvider(
      profile: profile,
      provider: WorkspaceOperationsProvider(
        profile: profile,
        attemptStore: try WorkspacePatchAttemptStore(
          rootURL: root.appending(path: "patch-attempts-\(UUID().uuidString)")),
        signingPresetStore: store, signingCredentialOwner: credentialOwner,
        signingAttemptStore: attemptStore,
        nowUTC: { "2026-08-10T00:00:00Z" }))
  }

  private func signingAction(
    provider: WorkspaceOperationsProvider,
    context: ProviderExecutionContext,
    presetRef: String = OpenHarmonyLocalSigning.defaultPresetID
  ) throws -> TypedProviderAction {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(
        reference: OpenHarmonyLocalSigning.operationReference))
    return try provider.action(
      for: try XCTUnwrap(descriptor.steps.first), operation: descriptor,
      inputs: [
        "projectRef": .string(OpenHarmonyLocalSigning.defaultProjectRef),
        "signingPresetRef": .string(presetRef),
        "unsignedHapArtifactLease": .string("lease-v1:test:input"),
      ], context: context)
  }

  private func permissions(_ path: String) throws -> mode_t {
    var info = stat()
    guard path.withCString({ lstat($0, &info) }) == 0 else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    return info.st_mode
  }

  private func regularFiles(below root: URL) throws -> [URL] {
    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: keys)
    else { return [] }
    return try enumerator.compactMap { item in
      guard let url = item as? URL,
        try url.resourceValues(forKeys: Set(keys)).isRegularFile == true
      else { return nil }
      return url
    }
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func testDevEcoEnvelope(
    _ plaintext: Data, key: Data, nonceByte: UInt8
  ) throws -> Data {
    let nonce = try AES.GCM.Nonce(data: Data(repeating: nonceByte, count: 12))
    let sealed = try AES.GCM.seal(
      plaintext, using: SymmetricKey(data: key), nonce: nonce)
    var sealedCount = UInt32(sealed.ciphertext.count + sealed.tag.count).bigEndian
    var result = Data()
    withUnsafeBytes(of: &sealedCount) { result.append(contentsOf: $0) }
    result.append(contentsOf: nonce)
    result.append(sealed.ciphertext)
    result.append(sealed.tag)
    return result
  }

  private func testPBKDF2SHA256(
    password: Data, salt: Data, iterations: Int, outputByteCount: Int
  ) -> Data {
    let key = SymmetricKey(data: password)
    var derived = Data()
    var block: UInt32 = 1
    while derived.count < outputByteCount {
      var bigEndian = block.bigEndian
      var input = salt
      withUnsafeBytes(of: &bigEndian) { input.append(contentsOf: $0) }
      var u = Data(HMAC<SHA256>.authenticationCode(for: input, using: key))
      var accumulated = u
      for _ in 1..<iterations {
        u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
        xorTestBytes(u, into: &accumulated)
      }
      derived.append(accumulated)
      block += 1
    }
    return Data(derived.prefix(outputByteCount))
  }

  private func xorTestBytes(_ source: Data, into destination: inout Data) {
    for index in destination.indices { destination[index] ^= source[index] }
  }

  private var productsDirectory: URL {
    #if os(macOS)
      for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        return bundle.bundleURL.deletingLastPathComponent()
      }
    #endif
    return Bundle.main.bundleURL
  }
}

private final class MemorySigningSecretStore: OpenHarmonySigningSecretStoring,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var values: [String: Data] = [:]
  private var reads = 0
  var trustedDaemonIdentity: String?

  var secretReadCount: Int { lock.withLock { reads } }

  func set(_ data: Data, account: String) throws {
    lock.withLock { values[account] = data }
  }

  func read(account: String) throws -> Data {
    try lock.withLock {
      reads += 1
      guard let value = values[account] else {
        throw OpenHarmonySigningError.secretUnavailable("missing test secret")
      }
      return value
    }
  }

  /// Simulates a Keychain this process is not allowed to interrogate. The
  /// maintenance CLI's real situation: `SecItemCopyMatching` fails alike for
  /// every query, so the boolean probe reports "not there" for an item that
  /// is, and only the three-way probe can tell the caller it never looked.
  var keychainUnreadable = false

  func contains(account: String) -> Bool {
    if keychainUnreadable { return false }
    return lock.withLock { values[account] != nil }
  }

  func presence(of account: String) -> OpenHarmonySigningSecretPresence {
    if keychainUnreadable { return .unreadable }
    return lock.withLock { values[account] != nil } ? .present : .absent
  }

  func trustedDaemonApplicationSHA256() throws -> String? {
    lock.withLock { trustedDaemonIdentity }
  }

  @discardableResult
  func remove(account: String) throws -> Bool {
    lock.withLock { values.removeValue(forKey: account) != nil }
  }
}

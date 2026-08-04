import ArkDeckCore
import ArkDeckOpenHarmony
import ArkDeckProcess
import ArkDeckStorage
import CryptoKit
import Darwin
import Foundation
import IOKit
import Security

public struct RockchipToolInstallationReceipt: Sendable, Equatable {
  public let executableSHA256: String
  public let codeTrust: RockchipPlatformCodeTrust
  public let quarantinePresent: Bool

  public init(
    executableSHA256: String,
    codeTrust: RockchipPlatformCodeTrust,
    quarantinePresent: Bool
  ) {
    self.executableSHA256 = executableSHA256
    self.codeTrust = codeTrust
    self.quarantinePresent = quarantinePresent
  }
}

public enum RockchipToolInstallation {
  /// Installs the pinned ordinary bookmark and records a fresh platform-trust assessment.
  /// A quarantined tool remains blocked; this entry point never removes quarantine implicitly.
  @discardableResult
  public static func install(executableURL: URL) throws -> RockchipToolInstallationReceipt {
    try RockchipProductToolInstaller.production.install(executableURL: executableURL)
  }

  /// Performs the explicit host trust transition for the one reviewed executable identity.
  /// The caller must repeat the full pinned digest; no arbitrary executable can be de-quarantined.
  @discardableResult
  public static func trustAndInstall(
    executableURL: URL,
    expectedSHA256: String
  ) throws -> RockchipToolInstallationReceipt {
    try RockchipProductToolInstaller.production.trustAndInstall(
      executableURL: executableURL,
      expectedSHA256: expectedSHA256)
  }
}

public struct RockchipDeviceBindingInstallationReceipt: Sendable, Equatable {
  public let revision: Int
  public let usbTopology: String
  public let serialDigestSHA256: String
  public let created: Bool

  public init(
    revision: Int,
    usbTopology: String,
    serialDigestSHA256: String,
    created: Bool
  ) {
    self.revision = revision
    self.usbTopology = usbTopology
    self.serialDigestSHA256 = serialDigestSHA256
    self.created = created
  }
}

public enum RockchipDeviceBindingInstallation {
  /// Reads IOKit only, requires exactly one DAYU200 in registered HDC-normal or Loader mode,
  /// and durably adopts that cross-mode identity.  The HDC-normal branch does not reboot here:
  /// the transition remains inside the later authorized `enterUpdater` intent.
  /// This entry point never launches rkdeveloptool and has no device-mutation surface.
  @discardableResult
  public static func installCurrentTarget() throws -> RockchipDeviceBindingInstallationReceipt {
    let manager = FileManager.default
    let applicationSupport = try manager.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    let root = applicationSupport.appending(path: "ArkDeck", directoryHint: .isDirectory)
    return try RockchipProductBindingBootstrap(
      probe: { try RockchipProductUSBProbe().singleDAYU200() },
      store: RockchipProductBindingStore(rootURL: root)
    ).installCurrentTarget()
  }

  /// Source-compatible name retained for clients built against the Loader-only bootstrap.
  @discardableResult
  public static func installCurrentLoader() throws -> RockchipDeviceBindingInstallationReceipt {
    try installCurrentTarget()
  }
}

/// Protected-main HDC tuple already registered by the Rockchip Loader-transition integration.
/// It is deliberately not configurable by CLI/environment/PATH.
enum RockchipHDCIntegrationProfile {
  static let executableURL = URL(
    fileURLWithPath:
      "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc")
  static let executableSHA256 =
    "05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83"
  static let reportedVersion = "3.2.0f"
  static let dayu200NormalProductID: UInt16 = 0x5000

  static func enterLoaderArguments(connectKey: String) -> [String] {
    // The HDC service owns boot-mode changes.  Keep this as a fixed typed
    // argv rather than asking a normal-mode shell to interpret `reboot
    // loader`: the latter was observed to complete without a Loader
    // transition on the current DAYU200/HDC combination.
    ["-t", connectKey, "target", "boot", "-bootloader"]
  }
}

/// Production composition for the campaign lane's admission. The in-process
/// flash executor this enum also used to assemble has been retired (T25);
/// what remains is the one assembly the nine-gate admission needs, shared by
/// every caller instead of duplicated per lane.
enum RockchipProductionExecutionComposition {
  static func makeAdmissionPort(
    settings: RockchipProductExecutionSettings
  ) throws -> RockchipProductionAdmissionPort {
    RockchipProductionAdmissionPort(
      agentUsageLedger: try AgentAuthorityUsageLedger(root: settings.usageRoot),
      campaignLedger: try RockchipEvolutionCampaignLedger(
        root: settings.usageRoot.appending(
          path: "evolution-campaigns", directoryHint: .isDirectory)),
      binding: settings.binding,
      tool: settings.tool, toolWorkingDirectory: settings.toolWorkingDirectory,
      clock: RockchipContinuousAdmissionClock(),
      usbProbe: RockchipProductUSBProbe())
  }
}

struct RockchipProductionStorageComposition: Sendable {
  let context: SessionStorageExecutionContext

  static func make(
    runtime: SessionStorageApplicationRuntime = .production
  ) throws -> RockchipProductionStorageComposition {
    RockchipProductionStorageComposition(context: try runtime.makeExecutionContext())
  }
}

package struct RockchipProductBindingSnapshot: Codable, Sendable, Equatable {
  package let revision: Int
  package let serial: String
  let usbTopology: String
  let evidence: [String]

  /// Converts the owner-only Rockchip rebind evidence into the one adjacent
  /// edge the generic Runtime target store may apply. Revision 1 has no edge
  /// to apply. Later revisions must carry one unambiguous previous identity,
  /// previous revision/topology and the explicit rebind confirmation digest;
  /// incomplete or invented lineage never reaches the target store.
  package func runtimeTargetLineageAdvance()
    throws -> RuntimeTargetBindingLineageAdvance?
  {
    let currentIdentity = SHA256.hash(data: Data(serial.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    let currentIdentities = values(prefix: "identity:serial-sha256=")
    guard currentIdentities == [currentIdentity] else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "durable binding current identity evidence is missing or ambiguous")
    }
    if revision == 1 { return nil }

    let previousIdentities = values(prefix: "identity:previous-serial-sha256=")
    let previousRevisions = values(prefix: "binding:previous-revision=")
    let previousTopologies = values(prefix: "binding:previous-usb-topology=")
    let confirmations = values(prefix: "rebind:chat-confirmation-sha256=")
    guard previousIdentities.count == 1,
      previousRevisions.count == 1,
      previousTopologies.count == 1,
      confirmations.count == 1,
      let previousIdentity = previousIdentities.first,
      let previousRevisionText = previousRevisions.first,
      let previousRevision = Int(previousRevisionText),
      let previousTopology = previousTopologies.first,
      let confirmation = confirmations.first,
      RockchipStandingAuthorization.isCanonicalSHA256(previousIdentity),
      RockchipStandingAuthorization.isCanonicalSHA256(confirmation),
      previousIdentity != currentIdentity,
      previousRevision > 0,
      revision == previousRevision + 1,
      !previousTopology.isEmpty,
      previousTopology.utf8.allSatisfy({ (48...57).contains($0) }),
      previousTopology == "0" || previousTopology.first != "0"
    else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "durable binding previous identity lineage is invalid or ambiguous")
    }
    return RuntimeTargetBindingLineageAdvance(
      previousStableIdentitySHA256: previousIdentity,
      previousRevision: previousRevision,
      currentStableIdentitySHA256: currentIdentity,
      currentRevision: revision)
  }

  /// A DAYU200 changes both its USB serial and its IOKit topology while moving
  /// between HDC-normal and Loader on the production board.  Revision 2 keeps
  /// the Loader identity as the stable campaign identity, but the immediately
  /// preceding HDC-normal identity remains the only address from which the
  /// typed `enter-loader` step can start.  Accept that alias only when the
  /// owner-only binding carries the complete, explicitly confirmed adjacent
  /// lineage edge.  A digest without its paired topology, a Loader claiming
  /// the previous HDC identity, or any older/unrelated identity remains a
  /// mismatch.
  func matchesConfirmedLiveIdentity(
    _ identity: RockchipProductUSBIdentity
  ) throws -> Bool {
    guard identity.isRegisteredDAYU200Mode else { return false }
    let currentIdentity = SHA256.hash(data: Data(serial.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    let liveIdentity = SHA256.hash(data: Data(identity.serial.utf8)).map {
      String(format: "%02x", $0)
    }.joined()

    // Validate the current evidence and, for revision > 1, the whole adjacent
    // edge before accepting either personality.  This prevents a malformed
    // lineage document from becoming useful merely because the device happens
    // to be in its latest mode.
    let advance = try runtimeTargetLineageAdvance()
    if liveIdentity == currentIdentity, identity.topology == usbTopology {
      return true
    }
    guard identity.isHDCNormal,
      evidence.contains("product:e0-iokit-single-loader-readback"),
      let advance,
      liveIdentity == advance.previousStableIdentitySHA256,
      let previousTopology = values(prefix: "binding:previous-usb-topology=").first,
      identity.topology == previousTopology
    else { return false }
    return true
  }

  func confirmedHDCConnectKey(
    for identity: RockchipProductUSBIdentity
  ) throws -> String? {
    guard identity.isHDCNormal, try matchesConfirmedLiveIdentity(identity) else { return nil }
    return identity.serial
  }

  private func values(prefix: String) -> [String] {
    evidence.compactMap {
      $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil
    }
  }
}

package struct RockchipProductBindingStore: Sendable {
  package init(rootURL: URL) { self.rootURL = rootURL }

  static let bindingFileName = "rockchip-binding.json"
  static let lockFileName = ".rockchip-binding.lock"
  static let maximumDocumentBytes = 64 * 1_024

  let rootURL: URL

  package func loadExisting() throws -> RockchipProductBindingSnapshot {
    try prepareRoot()
    let rootDescriptor = Darwin.open(
      rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard rootDescriptor >= 0 else { throw configurationError("binding root cannot be opened") }
    defer { Darwin.close(rootDescriptor) }
    guard let snapshot = try load(rootDescriptor: rootDescriptor) else {
      throw configurationError("durable Rockchip binding is not installed")
    }
    return snapshot
  }

  package func loadIfPresent() throws -> RockchipProductBindingSnapshot? {
    try prepareRoot()
    let rootDescriptor = Darwin.open(
      rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard rootDescriptor >= 0 else { throw configurationError("binding root cannot be opened") }
    defer { Darwin.close(rootDescriptor) }
    return try load(rootDescriptor: rootDescriptor)
  }

  func install(_ candidate: RockchipProductBindingSnapshot)
    throws -> (snapshot: RockchipProductBindingSnapshot, created: Bool)
  {
    try validate(candidate)
    try prepareRoot()
    let rootDescriptor = Darwin.open(
      rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard rootDescriptor >= 0 else { throw configurationError("binding root cannot be opened") }
    defer { Darwin.close(rootDescriptor) }

    let lockDescriptor = Darwin.openat(
      rootDescriptor, Self.lockFileName,
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard lockDescriptor >= 0 else { throw configurationError("binding lock cannot be opened") }
    defer { Darwin.close(lockDescriptor) }
    try validateOwnedRegularFile(lockDescriptor, permissions: 0o600, label: "binding lock")
    guard flock(lockDescriptor, LOCK_EX) == 0 else {
      throw configurationError("binding lock cannot be acquired")
    }
    defer { _ = flock(lockDescriptor, LOCK_UN) }

    if let existing = try load(rootDescriptor: rootDescriptor) {
      guard existing.serial == candidate.serial,
        existing.usbTopology == candidate.usbTopology
      else {
        throw configurationError(
          "durable binding differs from the only connected Loader; explicit rebind is required")
      }
      return (existing, false)
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var document = try encoder.encode(candidate)
    document.append(0x0A)
    guard document.count <= Self.maximumDocumentBytes else {
      throw configurationError("binding document exceeds its product limit")
    }

    let temporaryName = ".rockchip-binding.\(UUID().uuidString.lowercased()).part"
    let temporaryDescriptor = Darwin.openat(
      rootDescriptor, temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard temporaryDescriptor >= 0 else {
      throw configurationError("binding temporary file cannot be created")
    }
    var temporaryOpen = true
    defer {
      if temporaryOpen { Darwin.close(temporaryDescriptor) }
      _ = unlinkat(rootDescriptor, temporaryName, 0)
    }
    do {
      try writeAll(document, descriptor: temporaryDescriptor)
      guard fchmod(temporaryDescriptor, S_IRUSR | S_IWUSR) == 0,
        Darwin.fsync(temporaryDescriptor) == 0,
        Darwin.fcntl(temporaryDescriptor, F_FULLFSYNC) == 0
      else { throw configurationError("binding temporary file cannot be synchronized") }
      guard Darwin.close(temporaryDescriptor) == 0 else {
        throw configurationError("binding temporary file cannot be closed")
      }
      temporaryOpen = false
      guard
        renameatx_np(
          rootDescriptor, temporaryName, rootDescriptor, Self.bindingFileName,
          UInt32(RENAME_EXCL)) == 0
      else { throw configurationError("binding publication cannot be committed") }
      guard Darwin.fsync(rootDescriptor) == 0 else {
        throw configurationError("binding directory cannot be synchronized")
      }
    } catch let error as RockchipFlashExecutionError {
      throw error
    } catch {
      throw configurationError("binding publication failed")
    }

    guard let readback = try load(rootDescriptor: rootDescriptor), readback == candidate else {
      throw configurationError("binding write-readback failed")
    }
    return (readback, true)
  }

  private func prepareRoot() throws {
    guard rootURL.isFileURL, rootURL.path.hasPrefix("/") else {
      throw configurationError("binding root must be an absolute file URL")
    }
    var existing = stat()
    if lstat(rootURL.path, &existing) == 0, existing.st_mode & S_IFMT == S_IFLNK {
      throw configurationError("binding root cannot be a symbolic link")
    }
    do {
      try FileManager.default.createDirectory(
        at: rootURL, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw configurationError("binding root cannot be created")
    }
    guard chmod(rootURL.path, 0o700) == 0 else {
      throw configurationError("binding root must be owner-only")
    }
  }

  private func load(rootDescriptor: Int32) throws -> RockchipProductBindingSnapshot? {
    let descriptor = Darwin.openat(
      rootDescriptor, Self.bindingFileName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw configurationError("durable binding cannot be opened")
    }
    defer { Darwin.close(descriptor) }
    try validateOwnedRegularFile(descriptor, permissions: 0o600, label: "durable binding")
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_size > 0,
      metadata.st_size <= Self.maximumDocumentBytes
    else { throw configurationError("durable binding size is invalid") }
    let document = try readAll(descriptor: descriptor, byteCount: Int(metadata.st_size))
    guard
      let object = try JSONSerialization.jsonObject(with: document) as? [String: Any],
      Set(object.keys) == ["revision", "serial", "usbTopology", "evidence"]
    else { throw configurationError("durable binding schema is invalid") }
    let snapshot: RockchipProductBindingSnapshot
    do {
      snapshot = try JSONDecoder().decode(RockchipProductBindingSnapshot.self, from: document)
    } catch {
      throw configurationError("durable binding cannot be decoded")
    }
    try validate(snapshot)
    return snapshot
  }

  private func validate(_ snapshot: RockchipProductBindingSnapshot) throws {
    guard snapshot.revision > 0,
      !snapshot.serial.isEmpty,
      !snapshot.usbTopology.isEmpty,
      snapshot.usbTopology.utf8.allSatisfy({ (48...57).contains($0) }),
      !snapshot.evidence.isEmpty,
      snapshot.evidence.allSatisfy({ !$0.isEmpty && !$0.contains(snapshot.serial) })
    else { throw configurationError("durable binding snapshot is invalid") }
  }

  private func validateOwnedRegularFile(
    _ descriptor: Int32,
    permissions: mode_t,
    label: String
  ) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_nlink == 1,
      metadata.st_uid == getuid(),
      metadata.st_mode & 0o777 == permissions
    else { throw configurationError("\(label) must be an owner-only regular file") }
  }

  private func readAll(descriptor: Int32, byteCount: Int) throws -> Data {
    var result = Data()
    result.reserveCapacity(byteCount)
    var buffer = [UInt8](repeating: 0, count: min(4_096, byteCount))
    while result.count < byteCount {
      let count = Darwin.read(descriptor, &buffer, min(buffer.count, byteCount - result.count))
      if count < 0 {
        if errno == EINTR { continue }
        throw configurationError("durable binding cannot be read")
      }
      guard count > 0 else { throw configurationError("durable binding was truncated") }
      result.append(contentsOf: buffer.prefix(count))
    }
    return result
  }

  private func writeAll(_ data: Data, descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
        if written < 0 {
          if errno == EINTR { continue }
          throw configurationError("binding temporary file cannot be written")
        }
        guard written > 0 else {
          throw configurationError("binding temporary file cannot be written")
        }
        offset += written
      }
    }
  }

  private func configurationError(_ detail: String) -> RockchipFlashExecutionError {
    .productionConfigurationUnavailable(detail)
  }
}

struct RockchipProductBindingBootstrap: Sendable {
  let probe: @Sendable () throws -> RockchipProductUSBIdentity
  let store: RockchipProductBindingStore

  func installCurrentTarget() throws -> RockchipDeviceBindingInstallationReceipt {
    let identity = try probe()
    guard identity.isRegisteredDAYU200Mode,
      !identity.serial.isEmpty,
      !identity.topology.isEmpty,
      identity.topology.utf8.allSatisfy({ (48...57).contains($0) })
    else {
      throw RockchipFlashExecutionError.admissionRejected(
        "the single USB identity is not a registered DAYU200 mode")
    }
    let serialDigest = SHA256.hash(data: Data(identity.serial.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let candidate = RockchipProductBindingSnapshot(
      revision: 1,
      serial: identity.serial,
      usbTopology: identity.topology,
      evidence: [
        "product:e0-iokit-single-dayu200-readback",
        "usb:vendor=\(RockchipProbeEvidence.rockUSBVendorID),profile=dayu200-cross-mode",
        "identity:serial-sha256=\(serialDigest)",
      ])
    let result = try store.install(candidate)
    let storedDigest = SHA256.hash(data: Data(result.snapshot.serial.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return RockchipDeviceBindingInstallationReceipt(
      revision: result.snapshot.revision,
      usbTopology: result.snapshot.usbTopology,
      serialDigestSHA256: storedDigest,
      created: result.created)
  }

  /// Compatibility seam retained for existing contracts and callers.  It now
  /// has the same cross-mode behavior as the product entry point.
  func installCurrentLoader() throws -> RockchipDeviceBindingInstallationReceipt {
    try installCurrentTarget()
  }
}

struct RockchipToolBookmarkPreferences {
  let object: (String) -> Any?
  let setObject: (Any, String) throws -> Void
  let removeObject: (String) throws -> Void

  static func userDefaults(_ defaults: UserDefaults) -> RockchipToolBookmarkPreferences {
    RockchipToolBookmarkPreferences(
      object: { defaults.object(forKey: $0) },
      setObject: { value, key in defaults.set(value, forKey: key) },
      removeObject: { defaults.removeObject(forKey: $0) })
  }
}

struct RockchipOrdinaryBookmarkCodec: Sendable {
  let create: @Sendable (URL) throws -> Data
  let resolve: @Sendable (Data) throws -> RockchipBookmarkResolution

  static let foundation = RockchipOrdinaryBookmarkCodec(
    create: {
      try $0.bookmarkData(
        options: [],
        includingResourceValuesForKeys: nil,
        relativeTo: nil)
    },
    resolve: {
      var isStale = false
      let url = try URL(
        resolvingBookmarkData: $0,
        options: [.withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale)
      return RockchipBookmarkResolution(url: url, isStale: isStale)
    })
}

struct RockchipPinnedExecutableVerifier: Sendable {
  let verify: @Sendable (URL) throws -> Void

  static let production = RockchipPinnedExecutableVerifier { executableURL in
    let request = ProcessIdentityBoundRequest(
      process: ProcessRequest(executable: executableURL),
      expectedSHA256: RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256)
    let prepared = try FoundationProcessExecutor().prepareIdentityBoundLaunch(request)
    prepared.close()
  }
}

struct RockchipProductToolTrustInspector: Sendable {
  let assess: @Sendable (URL) throws -> RockchipPlatformTrustReceipt
  let clearQuarantine: @Sendable (URL) throws -> Void

  static let production = RockchipProductToolTrustInspector(
    assess: { executableURL in
      let quarantinePresent: Bool
      errno = 0
      let size = getxattr(
        executableURL.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
      if size >= 0 {
        quarantinePresent = true
      } else if errno == ENOATTR {
        quarantinePresent = false
      } else {
        throw RockchipFlashExecutionError.productionConfigurationUnavailable(
          "rkdeveloptool quarantine cannot be assessed")
      }

      var staticCode: SecStaticCode?
      var status = SecStaticCodeCreateWithPath(
        executableURL as CFURL, SecCSFlags(), &staticCode)
      guard status == errSecSuccess, let staticCode else {
        return RockchipPlatformTrustReceipt(
          codeTrust: .unsigned, quarantinePresent: quarantinePresent)
      }
      status = SecStaticCodeCheckValidity(
        staticCode,
        SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
        nil)
      guard status == errSecSuccess else {
        return RockchipPlatformTrustReceipt(
          codeTrust: .rejected, quarantinePresent: quarantinePresent)
      }
      var rawInformation: CFDictionary?
      status = SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInformation)
      guard status == errSecSuccess,
        let information = rawInformation as? [CFString: Any],
        let flags = information[kSecCodeInfoFlags] as? NSNumber
      else {
        return RockchipPlatformTrustReceipt(
          codeTrust: .unknown, quarantinePresent: quarantinePresent)
      }
      let codeTrust: RockchipPlatformCodeTrust
      if flags.uint32Value & 0x0000_0002 != 0 {
        codeTrust = .adHoc
      } else if let team = information[kSecCodeInfoTeamIdentifier] as? String,
        !team.isEmpty
      {
        codeTrust = .developerID
      } else {
        codeTrust = .unknown
      }
      return RockchipPlatformTrustReceipt(
        codeTrust: codeTrust, quarantinePresent: quarantinePresent)
    },
    clearQuarantine: { executableURL in
      guard
        removexattr(
          executableURL.path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0
          || errno == ENOATTR
      else {
        throw RockchipFlashExecutionError.productionConfigurationUnavailable(
          "rkdeveloptool quarantine could not be removed")
      }
    })
}

struct RockchipToolTrustFactStore {
  static let codeTrustKey = "ArkDeck.Rockchip.ToolCodeTrust"
  static let quarantineKey = "ArkDeck.Rockchip.ToolQuarantinePresent"

  let preferences: RockchipToolBookmarkPreferences

  func persist(_ receipt: RockchipPlatformTrustReceipt) throws {
    guard receipt.permitsPinnedDiscovery,
      let quarantinePresent = receipt.quarantinePresent
    else {
      throw configurationError("rkdeveloptool platform trust is not permitted")
    }
    let previousCodeTrust = preferences.object(Self.codeTrustKey)
    let previousQuarantine = preferences.object(Self.quarantineKey)
    do {
      try preferences.setObject(receipt.codeTrust.rawValue, Self.codeTrustKey)
      try preferences.setObject(quarantinePresent, Self.quarantineKey)
      guard preferences.object(Self.codeTrustKey) as? String == receipt.codeTrust.rawValue,
        preferences.object(Self.quarantineKey) as? Bool == quarantinePresent
      else { throw configurationError("tool trust facts failed write-readback") }
    } catch {
      restore(previousCodeTrust, key: Self.codeTrustKey)
      restore(previousQuarantine, key: Self.quarantineKey)
      if let error = error as? RockchipFlashExecutionError { throw error }
      throw configurationError("tool trust facts could not be persisted")
    }
  }

  private func restore(_ value: Any?, key: String) {
    if let value {
      try? preferences.setObject(value, key)
    } else {
      try? preferences.removeObject(key)
    }
  }

  private func configurationError(_ detail: String) -> RockchipFlashExecutionError {
    .productionConfigurationUnavailable(detail)
  }
}

struct RockchipInstalledToolLocator {
  let executableURL: URL
  let bookmarkData: Data
}

struct RockchipProductToolBookmarkStore {
  static let legacyKey = "ArkDeck.Rockchip.ToolBookmark"
  static let ordinaryKey = "ArkDeck.Rockchip.ToolOrdinaryBookmarkV1"

  let preferences: RockchipToolBookmarkPreferences
  let codec: RockchipOrdinaryBookmarkCodec
  let verifier: RockchipPinnedExecutableVerifier

  static var production: RockchipProductToolBookmarkStore {
    RockchipProductToolBookmarkStore(
      preferences: .userDefaults(.standard),
      codec: .foundation,
      verifier: .production)
  }

  func install(executableURL: URL) throws {
    let canonicalURL = try canonicalInstallURL(executableURL)
    do {
      try verifier.verify(canonicalURL)
    } catch {
      throw configurationError("pinned rkdeveloptool executable validation failed")
    }

    let bookmark: Data
    do {
      bookmark = try codec.create(canonicalURL)
      _ = try resolve(bookmark, expectedURL: canonicalURL)
    } catch let error as RockchipFlashExecutionError {
      throw error
    } catch {
      throw configurationError("ordinary rkdeveloptool bookmark self-check failed")
    }

    let previousNewValue = preferences.object(Self.ordinaryKey)
    do {
      try preferences.setObject(bookmark, Self.ordinaryKey)
      guard let readback = preferences.object(Self.ordinaryKey) as? Data,
        readback == bookmark
      else {
        throw configurationError("ordinary rkdeveloptool bookmark write-readback failed")
      }
      _ = try resolve(readback, expectedURL: canonicalURL)
    } catch {
      restoreOrdinaryValue(previousNewValue)
      if let error = error as? RockchipFlashExecutionError { throw error }
      throw configurationError("ordinary rkdeveloptool bookmark persistence failed")
    }

    guard preferences.object(Self.legacyKey) != nil else { return }
    do {
      try preferences.removeObject(Self.legacyKey)
      guard preferences.object(Self.legacyKey) == nil else {
        throw configurationError("legacy rkdeveloptool bookmark deletion failed")
      }
    } catch let error as RockchipFlashExecutionError {
      // A dual-key crash/fault state is intentionally retained. `load()` rejects it,
      // and rerunning this installer can finish the migration.
      throw error
    } catch {
      throw configurationError("legacy rkdeveloptool bookmark deletion failed")
    }
  }

  func load() throws -> RockchipInstalledToolLocator {
    let legacyPresent = preferences.object(Self.legacyKey) != nil
    let newValue = preferences.object(Self.ordinaryKey)
    if legacyPresent {
      let detail =
        newValue == nil
        ? "legacy pinned rkdeveloptool bookmark requires product reinstall"
        : "conflicting legacy and ordinary rkdeveloptool bookmarks require product reinstall"
      throw configurationError(detail)
    }
    guard let newValue else {
      throw configurationError("pinned rkdeveloptool ordinary bookmark is not installed")
    }
    guard let bookmark = newValue as? Data else {
      throw configurationError("pinned rkdeveloptool ordinary bookmark has the wrong type")
    }
    let executableURL = try resolve(bookmark, expectedURL: nil)
    return RockchipInstalledToolLocator(executableURL: executableURL, bookmarkData: bookmark)
  }

  private func canonicalInstallURL(_ url: URL) throws -> URL {
    guard url.isFileURL, url.path.hasPrefix("/") else {
      throw configurationError("rkdeveloptool install path must be an absolute file URL")
    }
    let standardized = url.standardizedFileURL
    let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
    guard url.path == standardized.path, standardized.path == canonical.path else {
      throw configurationError("rkdeveloptool install path must be canonical and non-symlinked")
    }
    return canonical
  }

  private func resolve(_ bookmark: Data, expectedURL: URL?) throws -> URL {
    let resolution: RockchipBookmarkResolution
    do {
      resolution = try codec.resolve(bookmark)
    } catch {
      throw configurationError("pinned rkdeveloptool ordinary bookmark is corrupt or inaccessible")
    }
    let standardized = resolution.url.standardizedFileURL
    let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
    guard !resolution.isStale, resolution.url.isFileURL, resolution.url.path.hasPrefix("/"),
      standardized.path == canonical.path
    else {
      throw configurationError("pinned rkdeveloptool ordinary bookmark is stale or non-canonical")
    }
    if let expectedURL {
      guard canonical == expectedURL.resolvingSymlinksInPath().standardizedFileURL else {
        throw configurationError("pinned rkdeveloptool ordinary bookmark path mismatched")
      }
    }
    return canonical
  }

  private func restoreOrdinaryValue(_ previousValue: Any?) {
    if let previousValue {
      try? preferences.setObject(previousValue, Self.ordinaryKey)
    } else {
      try? preferences.removeObject(Self.ordinaryKey)
    }
  }

  private func configurationError(_ detail: String) -> RockchipFlashExecutionError {
    .productionConfigurationUnavailable(detail)
  }
}

struct RockchipProductToolInstaller {
  let bookmarks: RockchipProductToolBookmarkStore
  let trustInspector: RockchipProductToolTrustInspector
  let trustFacts: RockchipToolTrustFactStore

  static var production: RockchipProductToolInstaller {
    let preferences = RockchipToolBookmarkPreferences.userDefaults(.standard)
    return RockchipProductToolInstaller(
      bookmarks: RockchipProductToolBookmarkStore(
        preferences: preferences,
        codec: .foundation,
        verifier: .production),
      trustInspector: .production,
      trustFacts: RockchipToolTrustFactStore(preferences: preferences))
  }

  func install(executableURL: URL) throws -> RockchipToolInstallationReceipt {
    try bookmarks.install(executableURL: executableURL)
    let assessment = try trustInspector.assess(executableURL)
    guard assessment.quarantinePresent == false else {
      throw configurationError(
        "rkdeveloptool is quarantined; use the exact-digest trust-tool entry after explicit trust")
    }
    try trustFacts.persist(assessment)
    return receipt(assessment)
  }

  func trustAndInstall(
    executableURL: URL,
    expectedSHA256: String
  ) throws -> RockchipToolInstallationReceipt {
    let pinned = RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256
    guard expectedSHA256 == pinned else {
      throw configurationError("trust-tool digest does not equal the product pin")
    }
    // The first install is an identity-bound, prepared-only hash check. Quarantine removal is
    // unreachable until that exact descriptor identity has passed the product pin.
    try bookmarks.install(executableURL: executableURL)
    let before = try trustInspector.assess(executableURL)
    if before.quarantinePresent == true {
      try trustInspector.clearQuarantine(executableURL)
    }
    // Re-verify the post-transition file and assess the platform facts from live metadata.
    try bookmarks.install(executableURL: executableURL)
    let after = try trustInspector.assess(executableURL)
    guard after.quarantinePresent == false else {
      throw configurationError("rkdeveloptool remains quarantined after trust transition")
    }
    try trustFacts.persist(after)
    return receipt(after)
  }

  private func receipt(_ assessment: RockchipPlatformTrustReceipt)
    -> RockchipToolInstallationReceipt
  {
    RockchipToolInstallationReceipt(
      executableSHA256: RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256,
      codeTrust: assessment.codeTrust,
      quarantinePresent: assessment.quarantinePresent ?? true)
  }

  private func configurationError(_ detail: String) -> RockchipFlashExecutionError {
    .productionConfigurationUnavailable(detail)
  }
}

enum RockchipProductToolRuntimeDirectory {
  static let directoryName = "RockchipToolRuntime"
  static let configurationFileName = "config.ini"
  static let logDirectoryName = "log"

  /// Upstream rkdeveloptool reads `config.ini` and writes `log/` relative to
  /// its current directory.  Bind those implicit files to product-owned state
  /// so an E2 run cannot depend on, or contaminate, the caller's Git worktree.
  static func prepare(root: URL) throws -> URL {
    guard root.isFileURL, root.path.hasPrefix("/") else {
      throw configurationError("Rockchip tool runtime root must be absolute")
    }
    let runtime = root.appending(path: directoryName, directoryHint: .isDirectory)
      .standardizedFileURL
    let rootPrefix = root.standardizedFileURL.path.hasSuffix("/")
      ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
    guard runtime.path.hasPrefix(rootPrefix) else {
      throw configurationError("Rockchip tool runtime escaped Application Support")
    }
    try prepareOwnerOnlyDirectory(runtime)
    try prepareOwnerOnlyDirectory(
      runtime.appending(path: logDirectoryName, directoryHint: .isDirectory))
    try prepareEmptyConfiguration(
      runtime.appending(path: configurationFileName, directoryHint: .notDirectory))
    return runtime
  }

  private static func prepareOwnerOnlyDirectory(_ url: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw configurationError("Rockchip tool runtime directory cannot be created")
    }
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == getuid()
    else {
      throw configurationError("Rockchip tool runtime directory is not owner-controlled")
    }
    guard chmod(url.path, 0o700) == 0 else {
      throw configurationError("Rockchip tool runtime directory must be owner-only")
    }
  }

  private static func prepareEmptyConfiguration(_ url: URL) throws {
    let descriptor = Darwin.open(
      url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw configurationError("Rockchip tool config cannot be opened")
    }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_nlink == 1,
      metadata.st_uid == getuid(),
      metadata.st_size == 0,
      fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
      fsync(descriptor) == 0
    else {
      throw configurationError("Rockchip tool config must be an empty owner-only regular file")
    }
  }

  private static func configurationError(_ detail: String) -> RockchipFlashExecutionError {
    .productionConfigurationUnavailable(detail)
  }
}

final class RockchipProductExecutionSettings: @unchecked Sendable {
  let usageRoot: URL
  let tool: RockchipSelectedDiscoveryTool
  let binding: RockchipProductBindingSnapshot
  let toolWorkingDirectory: URL

  private init(
    usageRoot: URL,
    tool: RockchipSelectedDiscoveryTool,
    binding: RockchipProductBindingSnapshot,
    toolWorkingDirectory: URL
  ) {
    self.usageRoot = usageRoot
    self.tool = tool
    self.binding = binding
    self.toolWorkingDirectory = toolWorkingDirectory
  }

  static func load() throws -> RockchipProductExecutionSettings {
    let manager = FileManager.default
    let applicationSupport = try manager.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    let root = applicationSupport.appending(path: "ArkDeck", directoryHint: .isDirectory)
    let usage = root.appending(path: "AuthorizationUsage", directoryHint: .isDirectory)
    for directory in [root, usage] {
      try manager.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      guard chmod(directory.path, 0o700) == 0 else {
        throw RockchipFlashExecutionError.productionConfigurationUnavailable(
          "owner-only Application Support directory")
      }
    }

    let defaults = UserDefaults.standard
    let locator = try RockchipProductToolBookmarkStore(
      preferences: .userDefaults(defaults),
      codec: .foundation,
      verifier: .production
    ).load()
    let executableURL = locator.executableURL
    let trustRaw = defaults.string(forKey: RockchipToolTrustFactStore.codeTrustKey)
    let trust = trustRaw.flatMap(RockchipPlatformCodeTrust.init(rawValue:)) ?? .unknown
    guard defaults.object(forKey: RockchipToolTrustFactStore.quarantineKey) != nil else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "tool quarantine assessment is absent")
    }
    let quarantine = defaults.bool(forKey: RockchipToolTrustFactStore.quarantineKey)
    let liveTrust = try RockchipProductToolTrustInspector.production.assess(executableURL)
    guard liveTrust.codeTrust == trust,
      liveTrust.quarantinePresent == quarantine,
      liveTrust.permitsPinnedDiscovery
    else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "live rkdeveloptool platform trust differs from its installed facts")
    }
    let selectedTool = RockchipSelectedDiscoveryTool(
      executableURL: executableURL, pathSource: .installedOrdinaryBookmark,
      bookmarkData: locator.bookmarkData,
      reportedVersion: RockchipDiscoveryIntegrationProfile.pinnedProduction.reportedToolVersion,
      sha256: RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256,
      platformTrust: RockchipPlatformTrustReceipt(
        codeTrust: trust, quarantinePresent: quarantine))
    let binding = try RockchipProductBindingStore(rootURL: root).loadExisting()
    let toolWorkingDirectory = try RockchipProductToolRuntimeDirectory.prepare(root: root)
    return RockchipProductExecutionSettings(
      usageRoot: usage, tool: selectedTool, binding: binding,
      toolWorkingDirectory: toolWorkingDirectory)
  }

  fileprivate static func productKeychainToken() throws -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: "dev.arkdeck.github-provenance",
      kSecAttrAccount: "protected-main-reader",
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else {
      throw RockchipFlashExecutionError.productionConfigurationUnavailable(
        "Keychain provenance credential cannot be read")
    }
    return String(data: data, encoding: .utf8)
  }
}

struct RockchipProductUSBIdentity: Sendable, Equatable {
  let serial: String
  let vendorID: UInt16
  let productID: UInt16
  let topology: String
  let productName: String?

  init(
    serial: String,
    vendorID: UInt16,
    productID: UInt16,
    topology: String,
    productName: String? = nil
  ) {
    self.serial = serial
    self.vendorID = vendorID
    self.productID = productID
    self.topology = topology
    self.productName = productName
  }

  var isLoader: Bool {
    vendorID == RockchipProbeEvidence.rockUSBVendorID
      && productID == RockchipProbeEvidence.dayu200LoaderProductID
  }

  var isHDCNormal: Bool {
    guard vendorID == RockchipProbeEvidence.rockUSBVendorID,
      productID == RockchipHDCIntegrationProfile.dayu200NormalProductID,
      let productName
    else { return false }
    return productName.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) == "HDC Device"
  }

  var isRegisteredDAYU200Mode: Bool { isLoader || isHDCNormal }
}

struct RockchipProductUSBProbe: Sendable {
  private enum Requirement {
    case loader
    case hdcNormal
    case registeredDAYU200
  }

  private let identitySource: @Sendable () throws -> [RockchipProductUSBIdentity]

  init(
    identitySource: @escaping @Sendable () throws -> [RockchipProductUSBIdentity] = {
      try Self.systemIdentities()
    }
  ) {
    self.identitySource = identitySource
  }

  func singleLoader(selector: String? = nil) throws -> RockchipProductUSBIdentity {
    try single(selector: selector, serialDigestSHA256: nil, requirement: .loader)
  }

  func singleLoader(
    stableIdentitySHA256: String
  ) throws -> RockchipProductUSBIdentity {
    try single(
      selector: nil, serialDigestSHA256: stableIdentitySHA256,
      requirement: .loader)
  }

  func singleLoader(
    selector: String,
    stableIdentitySHA256: String
  ) throws -> RockchipProductUSBIdentity {
    try single(
      selector: selector, serialDigestSHA256: stableIdentitySHA256,
      requirement: .loader)
  }

  func singleDAYU200(
    selector: String? = nil,
    stableIdentitySHA256: String? = nil
  ) throws -> RockchipProductUSBIdentity {
    try single(
      selector: selector, serialDigestSHA256: stableIdentitySHA256,
      requirement: .registeredDAYU200)
  }

  /// Selects one live DAYU200 personality from the exact current/previous
  /// identities proven by the durable binding.  This differs from accepting
  /// an arbitrary serial alias: the previous identity is usable only as the
  /// HDC-normal side of the one confirmed adjacent lineage edge.
  func singleDAYU200(
    selector: String,
    binding: RockchipProductBindingSnapshot
  ) throws -> RockchipProductUSBIdentity {
    // Fail closed on malformed owner-only lineage even when the host currently
    // has no matching USB device.
    _ = try binding.runtimeTargetLineageAdvance()
    let matches = try identitySource().filter { identity in
      guard identity.topology == selector else { return false }
      return try binding.matchesConfirmedLiveIdentity(identity)
    }
    guard matches.count == 1, let match = matches.first else {
      throw RockchipFlashExecutionError.admissionRejected(
        matches.isEmpty ? "DAYU200 target unavailable" : "DAYU200 target ambiguous")
    }
    return match
  }

  func singleConnected(selector: String? = nil) throws -> RockchipProductUSBIdentity {
    try single(
      selector: selector, serialDigestSHA256: nil,
      requirement: .hdcNormal)
  }

  func singleConnected(
    stableIdentitySHA256: String
  ) throws -> RockchipProductUSBIdentity {
    try single(
      selector: nil, serialDigestSHA256: stableIdentitySHA256,
      requirement: .hdcNormal)
  }

  private func single(
    selector: String?,
    serialDigestSHA256: String?,
    requirement: Requirement
  ) throws
    -> RockchipProductUSBIdentity
  {
    let identities = try identitySource()
    var matches: [RockchipProductUSBIdentity] = []
    for identity in identities {
      let modeMatches: Bool
      switch requirement {
      case .loader: modeMatches = identity.isLoader
      case .hdcNormal: modeMatches = identity.isHDCNormal
      case .registeredDAYU200: modeMatches = identity.isRegisteredDAYU200Mode
      }
      guard modeMatches else { continue }
      let digest = SHA256.hash(data: Data(identity.serial.utf8))
        .map { String(format: "%02x", $0) }.joined()
      if (selector == nil || selector == identity.topology)
        && (serialDigestSHA256 == nil || serialDigestSHA256 == digest)
      {
        matches.append(identity)
      }
    }
    guard matches.count == 1, let match = matches.first else {
      throw RockchipFlashExecutionError.admissionRejected(
        matches.isEmpty ? "DAYU200 target unavailable" : "DAYU200 target ambiguous")
    }
    return match
  }

  static func systemIdentities() throws -> [RockchipProductUSBIdentity] {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS
    else { throw RockchipFlashExecutionError.admissionRejected("USB registry unavailable") }
    defer { IOObjectRelease(iterator) }
    var identities: [RockchipProductUSBIdentity] = []
    while true {
      let service = IOIteratorNext(iterator)
      if service == 0 { break }
      defer { IOObjectRelease(service) }
      guard let vendor = number(service, "idVendor"),
        let product = number(service, "idProduct"),
        let location = number(service, "locationID"),
        let serial = string(service, "USB Serial Number")
          ?? string(service, "kUSBSerialNumberString")
      else { continue }
      let identity = RockchipProductUSBIdentity(
        serial: serial, vendorID: vendor.uint16Value,
        productID: product.uint16Value, topology: String(location.uint64Value),
        productName: string(service, "USB Product Name"))
      identities.append(identity)
    }
    return identities
  }

  private static func number(_ service: io_registry_entry_t, _ key: String) -> NSNumber? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? NSNumber
  }

  private static func string(_ service: io_registry_entry_t, _ key: String) -> String? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? String
  }
}

private struct RockchipProductBindingPort: RockchipDurableBindingFactPort {
  let sessionID: String
  let jobID: String
  let targetID: String
  let snapshot: RockchipProductBindingSnapshot

  func currentDurableBinding() async throws -> RockchipTrustedDurableBindingFact {
    let identity = try DeviceIdentitySnapshot(attributes: [
      "serial": .string(snapshot.serial), "usbTopology": .string(snapshot.usbTopology),
    ])
    let binding = try CurrentDeviceBinding(
      revision: snapshot.revision, connectKey: snapshot.usbTopology, transport: .usb,
      identitySnapshot: identity, evidence: snapshot.evidence, confirmedBy: .corePolicy,
      channelProtection: .unverifiedAssumeUnprotected)
    return RockchipTrustedDurableBindingFact(
      sessionID: sessionID, jobID: jobID, targetID: targetID,
      receipt: try DurableCurrentDeviceBinding(
        reference: DeviceBindingReference(targetID: targetID, revision: snapshot.revision),
        binding: binding))
  }
}

private struct RockchipProductPrerequisitePort: RockchipPrerequisiteFactPort {
  let sessionID: String
  let jobID: String
  let targetID: String
  let selector: String
  let probe: RockchipProductUSBProbe

  func probePrerequisites() async throws -> RockchipTrustedPrerequisiteFact {
    _ = try probe.singleLoader(selector: selector)
    return RockchipTrustedPrerequisiteFact(
      sessionID: sessionID, jobID: jobID, targetID: targetID,
      observations: [
        RockchipPrerequisiteObservation(identifier: .loader, status: .satisfied),
        RockchipPrerequisiteObservation(identifier: .recoveryPath, status: .satisfied),
        RockchipPrerequisiteObservation(identifier: .unlocked, status: .satisfied),
      ])
  }
}

private struct RockchipProductIdentityReadbackPort: RockchipIdentityReadbackFactPort {
  let sessionID: String
  let jobID: String
  let targetID: String
  let selector: String
  let observationSequence: UInt64
  let probe: RockchipProductUSBProbe
  let clock: any RockchipAdmissionClock

  func readIdentity() async throws -> RockchipTrustedIdentityReadbackFact {
    let identity = try probe.singleLoader(selector: selector)
    let reading = clock.now()
    return RockchipTrustedIdentityReadbackFact(
      sessionID: sessionID, jobID: jobID, targetID: targetID,
      observationSequence: observationSequence,
      observedAtMonotonicNanoseconds: reading.monotonicNanoseconds,
      deadlineMonotonicNanoseconds: reading.monotonicNanoseconds
        + RockchipAuthorizationFactCollector.maximumReadbackLifetimeNanoseconds,
      observedAtTimestamp: reading.auditTimestamp,
      serialDigestSHA256: SHA256.hash(data: Data(identity.serial.utf8)).map {
        String(format: "%02x", $0)
      }.joined(),
      usbVendorID: identity.vendorID, usbProductID: identity.productID,
      usbTopology: identity.topology)
  }
}

/// Admission collector for the normal HDC USB personality.  No mutation is
/// performed here: it proves the durable serial/topology, the exact external
/// Rockchip and HDC executable descriptors, and that the already-published
/// execute plan contains the closed `rockusb.enter-loader` intent.  The
/// reboot itself happens only after the selected E2 admission is consumed and the
/// step intent is durable.
private struct RockchipProductHDCNormalAuthorizationFactCollector:
  RockchipAuthorizationFactCollecting
{
  let planPort: RockchipProductExecutePlanFactPort
  let bindingPort: RockchipProductBindingPort
  let bindingSnapshot: RockchipProductBindingSnapshot
  let liveIdentity: RockchipProductUSBIdentity
  let tool: RockchipSelectedDiscoveryTool
  let toolWorkingDirectory: URL
  let clock: any RockchipAdmissionClock


  func collect(
    request: RockchipAuthorizationFactRequest,
    expectation: RockchipAuthorizationFactExpectation
  ) async throws -> RockchipTrustedAuthorizationFacts {
    for (field, value) in [
      ("sessionID", request.sessionID), ("jobID", request.jobID),
      ("targetID", request.targetID),
    ] where !Self.isIdentifier(value) {
      throw RockchipAuthorizationFactError.invalidRequest(field: field)
    }
    guard request.archiveURL.isFileURL, request.archiveURL.path.hasPrefix("/") else {
      throw RockchipAuthorizationFactError.invalidRequest(field: "archiveURL")
    }

    let plan: RockchipFlashPlan
    let binding: RockchipTrustedDurableBindingFact
    do { plan = try await planPort.makeValidatedExecutePlan(archiveURL: request.archiveURL) } catch
    {
      throw RockchipAuthorizationFactError.factPortFailed(name: "plan")
    }
    do { binding = try await bindingPort.currentDurableBinding() } catch {
      throw RockchipAuthorizationFactError.factPortFailed(name: "binding")
    }
    guard plan.executionMode == .execute,
      plan.steps.contains(where: {
        $0.kind == .enterUpdater
          && $0.arguments["providerOperationId"] == .string("rockusb.enter-loader")
      })
    else { throw RockchipAuthorizationFactError.planMismatch(field: "enterUpdater") }
    for (field, matches) in [
      ("targetModel", expectation.targetModel == RockchipFlashProfile.targetDeviceModel),
      ("firmwareArchiveSHA256", expectation.firmwareArchiveSHA256 == plan.archiveSHA256),
      ("transport", expectation.transport == "usb"),
      (
        "toolchainFingerprint",
        expectation.toolchainFingerprint == RockchipFlashProfile.pinnedToolchainFingerprint
      ),
      (
        "providerIdentity",
        expectation.providerIdentity == RockchipRockUSBFlashProvider.providerIdentity
      ),
      ("planDigestSHA256", expectation.planDigestSHA256 == plan.planDigestSHA256),
      ("stepSetDigestSHA256", expectation.stepSetDigestSHA256 == plan.stepSetDigestSHA256),
    ] where !matches {
      throw RockchipAuthorizationFactError.planMismatch(field: field)
    }

    guard binding.sessionID == request.sessionID,
      binding.jobID == request.jobID,
      binding.targetID == request.targetID,
      binding.receipt.reference.targetID == request.targetID,
      binding.receipt.reference.revision == expectation.bindingRevision,
      binding.receipt.binding.transport == .usb,
      case .string(let serial)? =
        binding.receipt.binding.identitySnapshot.attributes["serial"],
      case .string(let topology)? =
        binding.receipt.binding.identitySnapshot.attributes["usbTopology"],
      Self.isCanonicalTopology(topology), topology == bindingSnapshot.usbTopology,
      liveIdentity.isHDCNormal,
      request.targetLocationSelector == nil
        || request.targetLocationSelector == liveIdentity.topology,
      let hdcConnectKey = try bindingSnapshot.confirmedHDCConnectKey(for: liveIdentity)
    else { throw RockchipAuthorizationFactError.bindingMismatch(field: "binding") }
    let serialDigest = Self.sha256Hex(Data(serial.utf8))
    guard serialDigest == expectation.serialDigestSHA256 else {
      throw RockchipAuthorizationFactError.bindingMismatch(field: "serialDigestSHA256")
    }

    let processExecutor = FoundationProcessExecutor()
    let toolPrepared: ProcessPreparedIdentityBoundLaunch
    do {
      toolPrepared = try processExecutor.prepareIdentityBoundLaunch(
        ProcessIdentityBoundRequest(
          process: ProcessRequest(
            executable: tool.executableURL, arguments: ["ld"],
            workingDirectory: toolWorkingDirectory, timeout: 5),
          expectedSHA256: RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256))
    } catch {
      throw RockchipAuthorizationFactError.factPortFailed(name: "rockchipExecutableIdentity")
    }
    let executableIdentity = toolPrepared.executableIdentity
    toolPrepared.close()
    guard
      executableIdentity.sha256
        == RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256
    else { throw RockchipAuthorizationFactError.toolMismatch(field: "executableIdentity") }

    // Open and hash the exact HDC descriptor before an authority reservation.
    // It is opened again at the durable step boundary; this early check keeps
    // a missing/drifted HDC installation at zero device dispatch and zero
    // chat-confirmation consumption.
    let hdcPrepared: ProcessPreparedIdentityBoundLaunch
    do {
      hdcPrepared = try processExecutor.prepareIdentityBoundLaunch(
        ProcessIdentityBoundRequest(
          process: ProcessRequest(
            executable: RockchipHDCIntegrationProfile.executableURL,
            arguments: RockchipHDCIntegrationProfile.enterLoaderArguments(
              connectKey: hdcConnectKey),
            timeout: 20),
          expectedSHA256: RockchipHDCIntegrationProfile.executableSHA256))
    } catch {
      throw RockchipAuthorizationFactError.factPortFailed(name: "hdcExecutableIdentity")
    }
    hdcPrepared.close()

    let reading = clock.now()
    guard RockchipStandingAuthorization.isCanonicalTimestamp(reading.auditTimestamp),
      let now = RockchipStandingAuthorization.parseTimestamp(reading.auditTimestamp),
      let validUntil = RockchipStandingAuthorization.parseTimestamp(expectation.validUntil),
      now < validUntil
    else { throw RockchipAuthorizationFactError.authorizationExpired }
    let targetDigest = Self.sha256Hex(
      Data(
        [
          expectation.targetModel, serialDigest,
          String(binding.receipt.reference.revision), liveIdentity.topology,
          String(liveIdentity.vendorID), String(liveIdentity.productID),
        ].joined(separator: "|").utf8))
    return RockchipTrustedAuthorizationFacts(
      plan: plan, executableIdentity: executableIdentity,
      bindingReference: binding.receipt.reference,
      targetDigestSHA256: targetDigest, serialDigestSHA256: serialDigest,
      usbTopology: liveIdentity.topology, observationSequence: 1,
      readbackDeadlineMonotonicNanoseconds: reading.monotonicNanoseconds
        + RockchipAuthorizationFactCollector.maximumReadbackLifetimeNanoseconds,
      authorizationValidUntil: expectation.validUntil,
      collectedAtTimestamp: reading.auditTimestamp)
  }

  private static func isIdentifier(_ value: String) -> Bool {
    value.range(
      of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression)
      == value.startIndex..<value.endIndex
  }

  private static func isCanonicalTopology(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy({ (48...57).contains($0) })
      && (value == "0" || value.first != "0")
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

enum RockchipProductionDiscoveryComposition {
  static func admissionDiscoveryAdapter(
    toolWorkingDirectory: URL
  ) -> RockchipDeviceDiscoveryAdapter {
    RockchipDeviceDiscoveryAdapter(
      profile: .pinnedProduction, workingDirectory: toolWorkingDirectory)
  }
}

/// Internal rather than private so the engine lane's attempt admitter can
/// reach the same nine gates. Both lanes must mint their reservation here or
/// the two lanes are not the same authority (CHG-2026-025 r16).
final class RockchipProductionAdmissionPort: @unchecked Sendable,
  RockchipExecutionAdmissionPort
{
  private let agentUsageLedger: AgentAuthorityUsageLedger
  private let campaignLedger: RockchipEvolutionCampaignLedger
  private let binding: RockchipProductBindingSnapshot
  private let tool: RockchipSelectedDiscoveryTool
  private let toolWorkingDirectory: URL
  private let clock: any RockchipAdmissionClock
  private let usbProbe: RockchipProductUSBProbe

  init(
    agentUsageLedger: AgentAuthorityUsageLedger,
    campaignLedger: RockchipEvolutionCampaignLedger,
    binding: RockchipProductBindingSnapshot,
    tool: RockchipSelectedDiscoveryTool,
    toolWorkingDirectory: URL,
    clock: any RockchipAdmissionClock,
    usbProbe: RockchipProductUSBProbe
  ) {
    self.agentUsageLedger = agentUsageLedger
    self.campaignLedger = campaignLedger
    self.binding = binding
    self.tool = tool
    self.toolWorkingDirectory = toolWorkingDirectory
    self.clock = clock
    self.usbProbe = usbProbe
  }

  func admit(
    request: RockchipFlashExecutionRequest,
    sessionID: String,
    jobID: String,
    targetID: String
  ) async throws -> RockchipExecutionAdmission {
    let sequence: UInt64 = 1
    let serialDigest = SHA256.hash(data: Data(binding.serial.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    let liveIdentity = try usbProbe.singleDAYU200(
      selector: request.targetLocationSelector, binding: binding)
    let bindingPort = RockchipProductBindingPort(
      sessionID: sessionID, jobID: jobID, targetID: targetID, snapshot: binding)
    let collector: any RockchipAuthorizationFactCollecting
    if liveIdentity.isLoader {
      collector = RockchipAuthorizationFactCollector(
        planPort: RockchipProductExecutePlanFactPort(),
        bindingPort: bindingPort,
        toolDevicePort: RockchipDiscoveryToolDeviceFactPort(
          sessionID: sessionID, jobID: jobID, targetID: targetID,
          observationSequence: sequence,
          adapter: RockchipProductionDiscoveryComposition.admissionDiscoveryAdapter(
            toolWorkingDirectory: toolWorkingDirectory),
          tool: tool, clock: clock),
        prerequisitePort: RockchipProductPrerequisitePort(
          sessionID: sessionID, jobID: jobID, targetID: targetID,
          selector: request.targetLocationSelector, probe: usbProbe),
        identityReadbackPort: RockchipProductIdentityReadbackPort(
          sessionID: sessionID, jobID: jobID, targetID: targetID,
          selector: request.targetLocationSelector, observationSequence: sequence,
          probe: usbProbe, clock: clock),
        clock: clock)
    } else if liveIdentity.isHDCNormal {
      collector = RockchipProductHDCNormalAuthorizationFactCollector(
        planPort: RockchipProductExecutePlanFactPort(), bindingPort: bindingPort,
        bindingSnapshot: binding, liveIdentity: liveIdentity,
        tool: tool, toolWorkingDirectory: toolWorkingDirectory, clock: clock)
    } else {
      throw RockchipFlashExecutionError.admissionRejected(
        "durably bound DAYU200 is not in a registered execution mode")
    }
    let factRequest = RockchipAuthorizationFactRequest(
      archiveURL: request.archiveURL, sessionID: sessionID, jobID: jobID,
      targetID: targetID, targetLocationSelector: request.targetLocationSelector)
    switch request.authority {
    case .standingAuthorization:
      // The standing lane no longer executes in this process; its runtime
      // equivalent is a maintainer-issued exact-plan capability, which the
      // engine admits on its own. Reaching here means a caller built the wrong
      // request, so it fails closed rather than falling through to a lane.
      throw RockchipFlashExecutionError.admissionRejected(
        "standing authorization is not admitted here; use an exact-plan capability "
          + "on the runtime job lane")
    case .evolutionCampaign(let permit):
      let startingMode: RockchipEvolutionStartingMode = liveIdentity.isLoader ? .loader : .hdcNormal
      let service = RockchipEvolutionCampaignAdmissionService(
        factCollector: collector, usageLedger: agentUsageLedger,
        campaignLedger: campaignLedger, clock: clock,
        bindingSerialDigestSHA256: serialDigest, bindingRevision: binding.revision)
      let token = try await service.admit(
        permit: permit, facts: factRequest, sessionID: sessionID,
        startingMode: startingMode)
      return RockchipExecutionAdmission(
        backing: .evolutionCampaign(token), plan: token.facts.plan,
        authorityReference: .agent(token.authorizationReference),
        usageReservationID: token.usageReservation.reservationID,
        targetID: targetID, bindingRevision: token.facts.bindingReference.revision,
        targetDigestSHA256: token.facts.targetDigestSHA256,
        serialDigestSHA256: token.facts.serialDigestSHA256,
        usbTopology: token.facts.usbTopology,
        executableIdentity: token.facts.executableIdentity,
        evidenceClass: .production,
        evolutionStrategy: permit.candidate.strategy)
    }
  }

  // authorizeAndConsume/closeUsage lived here for the in-process executor:
  // it consumed the admission token and wrote the reservation's terminal
  // itself. On the engine lane both belong to the engine (#992) — it
  // re-proves the subject before the first mutation and closes the
  // reservation with the job's terminal — so neither has a caller here.
}

// MARK: - Fresh protected-main GitHub provenance

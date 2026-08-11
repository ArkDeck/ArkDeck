import ArkDeckCore
import CryptoKit
import Darwin
import Foundation

/// Reads only Runtime-owned typed action records to recover the narrow proof
/// needed when an advanced target was displaced from the singleton active
/// binding. It neither writes Runtime state nor observes/dispatches a device.
///
/// Two independently durable facts are required:
/// - a current-revision `wait-for-hdc` intent binding the exact target,
///   revision, stable Loader identity and retained HDC connect key; and
/// - a confirmed `observeHDCNormalUSB` reconciliation receipt for that same
///   target/connect key with one unambiguous USB topology.
///
/// Missing, malformed, conflicting or non-owner-only records return no proof
/// (or fail closed for an invalid storage root). Success strings, Job terminal
/// state and legacy authorization records are deliberately not consulted.
package struct RockchipRuntimeBindingReactivationProofSource:
  RockchipBindingReactivationProving, Sendable
{
  private static let maximumEntries = 16_384
  private static let maximumRecordBytes = 1_048_576

  package let rootURL: URL

  package init(rootURL: URL) {
    self.rootURL = rootURL
  }

  package func proof(
    for target: RuntimeTargetRecord
  ) throws -> RockchipBindingReactivationProof? {
    guard target.bindingRevision > 1,
      Self.isSHA256(target.stablePhysicalIdentitySHA256),
      !target.connectKey.isEmpty
    else { return nil }
    guard try validateRootIfPresent() else { return nil }

    let jobDirectories = try childDirectories(
      of: rootURL, where: { $0.hasPrefix("job-") })
    var currentRoutes: [CurrentRoute] = []
    var confirmedRoutes: [ConfirmedRoute] = []

    for jobDirectory in jobDirectories {
      let jobID = jobDirectory.lastPathComponent
      let waitDirectory = jobDirectory.appendingPathComponent(
        "wait-for-hdc", isDirectory: true)
      if let record = try? readIntent(
        from: waitDirectory.appendingPathComponent("intent.json")),
        record.value.jobID == jobID,
        record.value.stepID == "wait-for-hdc",
        record.value.targetID == target.targetID,
        record.value.bindingRevision == target.bindingRevision,
        record.value.stableIdentitySHA256 == target.stablePhysicalIdentitySHA256,
        let route = try currentRoute(from: record.value, bytes: record.bytes),
        route.connectKey == target.connectKey
      {
        currentRoutes.append(route)
      }

      let actionDirectories = try childDirectories(
        of: jobDirectory,
        where: { $0.hasPrefix("reconcile-enter-loader-mode-") })
      for actionDirectory in actionDirectories {
        guard
          let intent = try? readIntent(
            from: actionDirectory.appendingPathComponent("intent.json")),
          intent.value.jobID == jobID,
          intent.value.stepID == actionDirectory.lastPathComponent,
          intent.value.targetID == target.targetID,
          intent.value.bindingRevision == target.bindingRevision - 1,
          Self.isSHA256(intent.value.stableIdentitySHA256),
          let connectKey = Self.string(
            "connectKey", in: intent.value.action.arguments),
          intent.value.action.kind == "rockchip.observeHDCNormalUSB",
          Set(intent.value.action.arguments.keys) == ["connectKey"],
          connectKey == target.connectKey,
          try validActionHash(intent.value),
          let receipt = try? readReceipt(
            from: actionDirectory.appendingPathComponent("receipt.json")),
          receipt.value.matches(intent.value),
          receipt.value.isWellFormed,
          receipt.value.summary["usbState"] == "hdc-normal",
          let hdcIdentity = receipt.value.summary["hdcNormalIdentitySha256"],
          hdcIdentity == Self.sha256(connectKey),
          let topology = receipt.value.summary["usbTopology"],
          Self.isTopology(topology)
        else { continue }
        confirmedRoutes.append(
          ConfirmedRoute(
            connectKey: connectKey,
            identitySHA256: hdcIdentity,
            topology: topology,
            providerExecutableSHA256: intent.value.providerExecutableSHA256,
            receiptSHA256: Self.sha256(receipt.bytes)))
      }
    }

    guard !currentRoutes.isEmpty, !confirmedRoutes.isEmpty else { return nil }
    let currentKeys = Set(currentRoutes.map(\.connectKey))
    let directTopologies = Set(currentRoutes.compactMap(\.topology))
    let currentProviders = Set(currentRoutes.map(\.providerExecutableSHA256))
    guard currentProviders.count == 1, let currentProvider = currentProviders.first else {
      return nil
    }
    // A retained route from an older provider binary is not evidence for the
    // current revision, but it also must not poison a newer exact pair. Anchor
    // correlation in the current-revision intent's provider, then require the
    // adjacent confirmed receipt to have been produced by that same binary.
    let matchingConfirmedRoutes = confirmedRoutes.filter {
      $0.providerExecutableSHA256 == currentProvider
    }
    let confirmedKeys = Set(matchingConfirmedRoutes.map(\.connectKey))
    let identities = Set(matchingConfirmedRoutes.map(\.identitySHA256))
    let topologies = Set(matchingConfirmedRoutes.map(\.topology))
    guard currentKeys == [target.connectKey],
      confirmedKeys == [target.connectKey],
      identities == [Self.sha256(target.connectKey)],
      topologies.count == 1,
      directTopologies.isEmpty || directTopologies == topologies,
      let topology = topologies.first,
      let currentIntentDigest = currentRoutes.map(\.intentSHA256).sorted().first,
      let routeReceiptDigest = matchingConfirmedRoutes.map(\.receiptSHA256).sorted().first
    else { return nil }

    return RockchipBindingReactivationProof(
      targetID: target.targetID,
      bindingRevision: target.bindingRevision,
      stableLoaderIdentitySHA256: target.stablePhysicalIdentitySHA256,
      hdcConnectKey: target.connectKey,
      hdcIdentitySHA256: Self.sha256(target.connectKey),
      hdcUSBTopology: topology,
      currentBindingIntentSHA256: currentIntentDigest,
      hdcRouteReceiptSHA256: routeReceiptDigest)
  }

  private struct CurrentRoute {
    let connectKey: String
    let topology: String?
    let providerExecutableSHA256: String
    let intentSHA256: String
  }

  private struct ConfirmedRoute {
    let connectKey: String
    let identitySHA256: String
    let topology: String
    let providerExecutableSHA256: String
    let receiptSHA256: String
  }

  private struct IntentRecord: Codable {
    let schemaVersion: String
    let jobID: String
    let stepID: String
    let targetID: String
    let bindingRevision: Int
    let stableIdentitySHA256: String
    let providerExecutableSHA256: String
    let actionSHA256: String
    let action: PersistedTypedProviderAction
  }

  private struct ReceiptRecord: Codable {
    let schemaVersion: String
    let jobID: String
    let stepID: String
    let targetID: String
    let bindingRevision: Int
    let stableIdentitySHA256: String
    let providerExecutableSHA256: String
    let actionSHA256: String
    let summary: [String: String]
    let stdoutSHA256: String
    let stdoutByteCount: Int
    let stderrSHA256: String
    let stderrByteCount: Int
    let stdoutTruncated: Bool
    let subprocessCount: Int

    func matches(_ intent: IntentRecord) -> Bool {
      schemaVersion == "1.0.0"
        && jobID == intent.jobID
        && stepID == intent.stepID
        && targetID == intent.targetID
        && bindingRevision == intent.bindingRevision
        && stableIdentitySHA256 == intent.stableIdentitySHA256
        && providerExecutableSHA256 == intent.providerExecutableSHA256
        && actionSHA256 == intent.actionSHA256
    }

    var isWellFormed: Bool {
      SelfValid.sha256(stdoutSHA256)
        && SelfValid.sha256(stderrSHA256)
        && stdoutByteCount >= 0
        && stderrByteCount >= 0
        && subprocessCount >= 0
        && !stdoutTruncated
        && Set(summary.keys) == [
          "hdcNormalIdentitySha256", "usbState", "usbTopology",
        ]
    }
  }

  private enum SelfValid {
    static func sha256(_ value: String) -> Bool {
      value.count == 64
        && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
  }

  private func currentRoute(
    from intent: IntentRecord,
    bytes: Data
  ) throws -> CurrentRoute? {
    guard intent.schemaVersion == "1.0.0",
      Self.isSHA256(intent.providerExecutableSHA256),
      Self.isSHA256(intent.actionSHA256),
      try validActionHash(intent)
    else { return nil }
    switch intent.action.kind {
    case "rockchip.waitForHDCReconnect":
      guard Set(intent.action.arguments.keys) == ["connectKey"],
        let connectKey = Self.string("connectKey", in: intent.action.arguments),
        !connectKey.isEmpty
      else { return nil }
      return CurrentRoute(
        connectKey: connectKey,
        topology: nil,
        providerExecutableSHA256: intent.providerExecutableSHA256,
        intentSHA256: Self.sha256(bytes))
    case "rockchip.waitForBoundHDCReconnect":
      guard Set(intent.action.arguments.keys) == [
        "previousConnectKey", "previousIdentitySha256", "usbTopology",
      ],
        let connectKey = Self.string(
          "previousConnectKey", in: intent.action.arguments),
        let identity = Self.string(
          "previousIdentitySha256", in: intent.action.arguments),
        identity == Self.sha256(connectKey),
        let topology = Self.string("usbTopology", in: intent.action.arguments),
        Self.isTopology(topology)
      else { return nil }
      return CurrentRoute(
        connectKey: connectKey,
        topology: topology,
        providerExecutableSHA256: intent.providerExecutableSHA256,
        intentSHA256: Self.sha256(bytes))
    default:
      return nil
    }
  }

  private func validActionHash(_ intent: IntentRecord) throws -> Bool {
    let encoder = CanonicalJSONEncoders.canonical()
        return Self.sha256(try encoder.encode(intent.action)) == intent.actionSHA256
  }

  private func validateRootIfPresent() throws -> Bool {
    var metadata = stat()
    if lstat(rootURL.path, &metadata) != 0 {
      if errno == ENOENT { return false }
      throw failure("Runtime reactivation record root cannot be inspected")
    }
    guard rootURL.isFileURL,
      rootURL.path.hasPrefix("/"),
      rootURL.standardizedFileURL.path == rootURL.path,
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == getuid(),
      metadata.st_mode & 0o077 == 0
    else { throw failure("Runtime reactivation record root is not owner-only") }
    return true
  }

  private func childDirectories(
    of parent: URL,
    where predicate: (String) -> Bool
  ) throws -> [URL] {
    guard (try? validateDirectory(parent)) == true else { return [] }
    let entries = try FileManager.default.contentsOfDirectory(
      at: parent,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles])
      .filter { predicate($0.lastPathComponent) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard entries.count <= Self.maximumEntries else {
      throw failure("Runtime reactivation record directory exceeds its bound")
    }
    return entries.filter { (try? validateDirectory($0)) == true }
  }

  private func validateDirectory(_ url: URL) throws -> Bool {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == getuid(),
      metadata.st_mode & 0o077 == 0
    else { return false }
    return true
  }

  private func readIntent(from url: URL) throws -> (value: IntentRecord, bytes: Data) {
    let bytes = try readOwnerOnlyRecord(url)
    guard try exactKeys(bytes) == [
      "schemaVersion", "jobID", "stepID", "targetID", "bindingRevision",
      "stableIdentitySHA256", "providerExecutableSHA256", "actionSHA256", "action",
    ] else { throw failure("Runtime reactivation intent schema is invalid") }
    return (try JSONDecoder().decode(IntentRecord.self, from: bytes), bytes)
  }

  private func readReceipt(from url: URL) throws -> (value: ReceiptRecord, bytes: Data) {
    let bytes = try readOwnerOnlyRecord(url)
    guard try exactKeys(bytes) == [
      "schemaVersion", "jobID", "stepID", "targetID", "bindingRevision",
      "stableIdentitySHA256", "providerExecutableSHA256", "actionSHA256", "summary",
      "stdoutSHA256", "stdoutByteCount", "stderrSHA256", "stderrByteCount",
      "stdoutTruncated", "subprocessCount",
    ] else { throw failure("Runtime reactivation receipt schema is invalid") }
    return (try JSONDecoder().decode(ReceiptRecord.self, from: bytes), bytes)
  }

  private func readOwnerOnlyRecord(_ url: URL) throws -> Data {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw failure("Runtime reactivation record cannot be opened") }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_nlink == 1,
      metadata.st_uid == getuid(),
      metadata.st_mode & 0o777 == 0o600,
      metadata.st_size > 0,
      metadata.st_size <= Self.maximumRecordBytes
    else { throw failure("Runtime reactivation record is not owner-only and bounded") }
    var data = Data(count: Int(metadata.st_size))
    try data.withUnsafeMutableBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.read(
          descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count > 0 { offset += count }
        else if count < 0, errno == EINTR { continue }
        else { throw failure("Runtime reactivation record is truncated") }
      }
    }
    return data
  }

  private func exactKeys(_ data: Data) throws -> Set<String> {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw failure("Runtime reactivation record is not a JSON object") }
    return Set(object.keys)
  }

  private static func string(
    _ key: String,
    in arguments: [String: JSONValue]
  ) -> String? {
    guard case .string(let value)? = arguments[key] else { return nil }
    return value
  }

  private static func isSHA256(_ value: String) -> Bool {
    SelfValid.sha256(value)
  }

  private static func isTopology(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.allSatisfy { (48...57).contains($0) }
      && (value == "0" || value.first != "0")
  }

  private static func sha256(_ text: String) -> String {
    sha256(Data(text.utf8))
  }

  private static func sha256(_ data: Data) -> String {
    SHA256Hex.string(of: data)
  }

  private func failure(_ detail: String) -> RockchipFlashExecutionError {
    .productionConfigurationUnavailable(detail)
  }
}

import ArkDeckCore
import Darwin
import Foundation

/// A bounded registration owner for an installed DevEco Studio toolchain.
///
/// Unlike the native HDC registry, this owner does not copy the multi-gigabyte
/// SDK. It pins the no-follow root identity, validates versioned manifests and
/// the closed child roles that ArkDeck may later use, and remeasures all of
/// them before returning a private Runtime resolution. Public values never
/// contain the root or a child path.
package final class BootstrapDevEcoToolchainRegistry: @unchecked Sendable {
  private typealias Files = BootstrapBundleFiles
  package typealias ReferenceOwner = BootstrapBundleRegistry.ReferenceOwner

  package struct ResolvedToolchain: Sendable, Equatable {
    package struct Resource: Sendable, Equatable {
      package let url: URL
      package let sha256: String
      package let byteCount: Int
      package let requireExecutable: Bool
    }

    package let toolchainRef: String
    package let generation: UInt64
    package let contentsRoot: URL
    package let sdkRoot: URL
    package let nodeExecutable: URL
    package let hvigorScript: URL
    package let productVersion: String
    package let sdkVersion: String
    package let verifiedResources: [Resource]
  }

  private struct RootIdentity: Codable, Equatable {
    let path: String
    let device: UInt64
    let inode: UInt64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let changedSeconds: Int64
    let changedNanos: Int64
  }

  private struct ChildIdentity: Codable, Equatable {
    let role: String
    let relativePath: String
    let device: UInt64
    let inode: UInt64
    let byteCount: Int64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let changedSeconds: Int64
    let changedNanos: Int64
    let sha256: String
    let executable: Bool
    let trust: BootstrapToolTrust?

    var publicValue: JSONValue {
      .object([
        "role": .string(role),
        "sha256": .string(sha256),
        "byteCount": .string(String(byteCount)),
        "executable": .bool(executable),
        "trust": trust.map { $0.projection() } ?? .null,
      ])
    }
  }

  private struct Record: Codable, Equatable {
    let reference: String
    let contentDigest: String
    let root: RootIdentity
    let productVersion: String
    let buildNumber: String
    let sdkVersion: String
    let apiVersion: String
    let registeredAtUTC: String
    let bundleTrust: BootstrapToolTrust
    let children: [ChildIdentity]
    var generation: UInt64
    var state: String
    var references: [ReferenceOwner]
  }

  private struct Index: Codable {
    var schemaVersion = "arkdeck.bootstrap-deveco-toolchains/1"
    var records: [Record] = []
  }

  private struct ProductInfo: Decodable {
    struct Launch: Decodable { let os: String; let arch: String }
    let name: String
    let version: String
    let buildNumber: String
    let productCode: String
    let productVendor: String
    let launch: [Launch]
  }

  private struct SDKPackage: Decodable {
    struct DataFields: Decodable {
      let apiVersion: String
      let platformVersion: String
      let version: String
    }
    let data: DataFields
  }

  private static let indexName = "deveco-toolchains.json"
  private static let maximumRecords = 32
  private static let maximumReferences = 1_024
  private static let productManifest = "Resources/product-info.json"
  private static let sdkManifest = "sdk/default/sdk-pkg.json"
  private static let signedResourceEnvelope = "_CodeSignature/CodeResources"
  private static let nodeRole = "tools/node/bin/node"
  private static let hvigorRole = "tools/hvigor/bin/hvigorw.js"
  private static let sdkRole = "sdk/default/openharmony"

  private let owner: BootstrapBundleRegistry
  private let inspectTrust: (URL) throws -> BootstrapToolTrust
  private let inspectPublisherTrust: (URL) throws -> BootstrapToolTrust
  private let verifySignedResources: (URL, [String: String]) throws -> Void
  private let nowUTC: () -> String

  package convenience init() throws {
    self.init(owner: try BootstrapBundleRegistry())
  }

  package init(
    owner: BootstrapBundleRegistry,
    inspectTrust: @escaping (URL) throws -> BootstrapToolTrust = BootstrapToolTrust.inspect,
    inspectPublisherTrust: @escaping (URL) throws -> BootstrapToolTrust = BootstrapToolTrust.inspectCodeOnly,
    verifySignedResources: @escaping (URL, [String: String]) throws -> Void = BootstrapDevEcoToolchainRegistry.verifySignedResourceEnvelope,
    nowUTC: @escaping () -> String = { ISO8601DateFormatter().string(from: Date()) }
  ) {
    self.owner = owner
    self.inspectTrust = inspectTrust
    self.inspectPublisherTrust = inspectPublisherTrust
    self.verifySignedResources = verifySignedResources
    self.nowUTC = nowUTC
  }

  package func register(root: URL) throws -> JSONValue {
    try owner.withSharedStore { directory, registryRoot in
      var index = try readIndex(directory)
      let candidate = try inspectRoot(root)
      if let existing = index.records.first(where: { $0.reference == candidate.reference }) {
        guard existing.state == "available", existing.root == candidate.root else {
          throw Files.failure(
            "resourceConflict",
            "this exact DevEco content is retired or already registered from another root")
        }
        try verify(existing)
        return value(existing)
      }
      guard index.records.count < Self.maximumRecords else {
        throw Files.failure("quotaExceeded", "DevEco toolchain registration limit is reached")
      }
      var record = candidate
      record = Record(
        reference: record.reference, contentDigest: record.contentDigest, root: record.root,
        productVersion: record.productVersion, buildNumber: record.buildNumber,
        sdkVersion: record.sdkVersion, apiVersion: record.apiVersion,
        registeredAtUTC: nowUTC(), bundleTrust: record.bundleTrust,
        children: record.children, generation: 1, state: "available", references: [])
      index.records.append(record)
      index.records.sort { $0.reference < $1.reference }
      try saveIndex(index, directory: directory, root: registryRoot)
      return value(record)
    }
  }

  package func inspect(_ reference: String) throws -> JSONValue {
    try owner.withSharedStore { directory, _ in
      let record = try find(reference, in: readIndex(directory))
      if record.state == "available" { try verify(record) }
      return value(record)
    }
  }

  package func listValues() throws -> [JSONValue] {
    try owner.withSharedStore { directory, _ in
      try listValuesLocked(directory)
    }
  }

  package func combinedInventory(
    with nativeTools: BootstrapToolRegistry
  ) throws -> (snapshotDirectory: URL, values: [JSONValue]) {
    try owner.withSharedStore { directory, root in
      let hdc = try nativeTools.listValuesLocked(directory, root: root)
      let deveco = try listValuesLocked(directory)
      return (root.appending(path: "tool-snapshots"), hdc + deveco)
    }
  }

  package func listValuesLocked(_ directory: Int32) throws -> [JSONValue] {
    let index = try readIndex(directory)
    for record in index.records where record.state == "available" { try verify(record) }
    return index.records.map(value)
  }

  package func remove(
    _ reference: String, expectedGeneration: String
  ) throws -> JSONValue {
    try owner.withSharedStore { directory, registryRoot in
      var index = try readIndex(directory)
      var record = try find(reference, in: index)
      guard expectedGeneration == "1" else {
        throw Files.failure("resourceConflict", "DevEco toolchain generation does not match")
      }
      if record.state == "removed" { return value(record) }
      try verify(record)
      guard record.references.isEmpty else {
        throw Files.failure(
          "resourceConflict", "DevEco toolchain is retained by a workspace preset")
      }
      record.state = "removed"
      record.generation = 2
      replace(record, in: &index)
      try saveIndex(index, directory: directory, root: registryRoot)
      return value(record)
    }
  }

  package func acquire(
    _ reference: String, expectedGeneration: String = "1", owner dependency: ReferenceOwner
  ) throws -> JSONValue {
    try owner.withSharedStore { directory, registryRoot in
      var index = try readIndex(directory)
      var record = try find(reference, in: index)
      guard record.state == "available", expectedGeneration == String(record.generation) else {
        throw Files.failure("resourceConflict", "DevEco toolchain is retired or changed")
      }
      try verify(record)
      if !record.references.contains(dependency) {
        guard record.references.count < Self.maximumReferences else {
          throw Files.failure("quotaExceeded", "DevEco toolchain reference bound is reached")
        }
        record.references.append(dependency)
        record.references.sort { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) }
        replace(record, in: &index)
        try saveIndex(index, directory: directory, root: registryRoot)
      }
      return value(record)
    }
  }

  package func release(_ reference: String, owner dependency: ReferenceOwner) throws {
    try owner.withSharedStore { directory, registryRoot in
      var index = try readIndex(directory)
      var record = try find(reference, in: index)
      try verify(record)
      if record.references.contains(dependency) {
        record.references.removeAll { $0 == dependency }
        replace(record, in: &index)
        try saveIndex(index, directory: directory, root: registryRoot)
      }
    }
  }

  package func resolve(
    _ reference: String, expectedGeneration: String = "1", owner dependency: ReferenceOwner
  ) throws -> ResolvedToolchain {
    try owner.withSharedStore { directory, _ in
      let record = try find(reference, in: readIndex(directory))
      guard record.state == "available", expectedGeneration == String(record.generation),
        record.references.contains(dependency)
      else {
        throw Files.failure(
          "resourceConflict", "DevEco resolution requires an exact workspace-preset pin")
      }
      try verify(record)
      let root = URL(filePath: record.root.path, directoryHint: .isDirectory)
      return ResolvedToolchain(
        toolchainRef: record.reference, generation: record.generation,
        contentsRoot: root,
        sdkRoot: root.appending(path: "sdk", directoryHint: .isDirectory),
        nodeExecutable: root.appending(path: Self.nodeRole),
        hvigorScript: root.appending(path: Self.hvigorRole),
        productVersion: record.productVersion, sdkVersion: record.sdkVersion,
        verifiedResources: record.children.compactMap { child in
          guard child.role != "node" else { return nil }
          return ResolvedToolchain.Resource(
            url: root.appending(path: child.relativePath), sha256: child.sha256,
            byteCount: Int(child.byteCount), requireExecutable: child.executable)
        })
    }
  }

  private func inspectRoot(_ supplied: URL) throws -> Record {
    let path = try Files.physicalPath(supplied)
    let root = URL(filePath: path, directoryHint: .isDirectory)
    guard root.lastPathComponent == "Contents", root.deletingLastPathComponent().pathExtension == "app" else {
      throw Files.failure(
        "invalidInput", "DevEco registration requires the app bundle's absolute Contents root")
    }
    let rootFD = try openRootDirectory(root)
    defer { close(rootFD) }
    let rootStatus = try Files.status(rootFD)
    let rootIdentity = Self.rootIdentity(path: path, status: rootStatus)
    let product = try readChild(
      rootFD: rootFD, root: root, role: "productManifest",
      relativePath: Self.productManifest, maximumBytes: 64 * 1_024, executable: false,
      nativeTrust: false)
    let sdk = try readChild(
      rootFD: rootFD, root: root, role: "sdkManifest",
      relativePath: Self.sdkManifest, maximumBytes: 64 * 1_024, executable: false,
      nativeTrust: false)
    let node = try readChild(
      rootFD: rootFD, root: root, role: "node",
      relativePath: Self.nodeRole, maximumBytes: 256 * 1_024 * 1_024, executable: true,
      nativeTrust: true)
    let hvigor = try readChild(
      rootFD: rootFD, root: root, role: "hvigor",
      relativePath: Self.hvigorRole, maximumBytes: 8 * 1_024 * 1_024, executable: false,
      nativeTrust: false)
    let resourceEnvelope = try readChild(
      rootFD: rootFD, root: root, role: "signedResourceEnvelope",
      relativePath: Self.signedResourceEnvelope, maximumBytes: 32 * 1_024 * 1_024,
      executable: false, nativeTrust: false)
    let sdkDirectory = try openDirectory(rootFD: rootFD, relativePath: Self.sdkRole)
    defer { close(sdkDirectory) }
    let productData = try readData(rootFD: rootFD, relativePath: Self.productManifest, maximum: 64 * 1_024)
    let sdkData = try readData(rootFD: rootFD, relativePath: Self.sdkManifest, maximum: 64 * 1_024)
    guard SHA256Hex.string(of: productData) == product.sha256,
      SHA256Hex.string(of: sdkData) == sdk.sha256
    else {
      throw Files.failure("fileIdentityChanged", "DevEco manifests changed during registration")
    }
    var productValidator = StrictJSONDuplicateValidator(data: productData)
    try productValidator.validate()
    var sdkValidator = StrictJSONDuplicateValidator(data: sdkData)
    try sdkValidator.validate()
    let productInfo = try JSONDecoder().decode(ProductInfo.self, from: productData)
    let sdkInfo = try JSONDecoder().decode(SDKPackage.self, from: sdkData)
    guard productInfo.name == "DevEco Studio", productInfo.productCode == "DS",
      productInfo.productVendor == "Huawei", Self.version(productInfo.version),
      Self.identifier(productInfo.buildNumber),
      productInfo.launch.contains(where: { $0.os == "macOS" && ["aarch64", "x86_64"].contains($0.arch) }),
      Self.version(sdkInfo.data.version), Self.version(sdkInfo.data.platformVersion),
      Self.identifier(sdkInfo.data.apiVersion), node.trust?.signature == "verified"
    else {
      throw Files.failure(
        "admissionDenied", "DevEco manifests, platform, version or native trust are unsupported")
    }
    let bundleTrust = try inspectPublisherTrust(root.deletingLastPathComponent())
    guard bundleTrust.signature == "verified", bundleTrust.identifier == "com.huawei.devecostudio.ds",
      bundleTrust.teamIdentifier == "TZEA3TN37Q"
    else {
      throw Files.failure("admissionDenied", "DevEco app signature does not match the supported publisher")
    }
    try verifySignedResources(root, Dictionary(uniqueKeysWithValues: [
      product, sdk, node, hvigor,
    ].map { ($0.relativePath, $0.sha256) }))
    try requireLinkedRoot(rootFD, url: root)
    let children = [product, sdk, node, hvigor, resourceEnvelope]
    let digest = try SHA256Hex.string(of: PortableCanonicalJSON.canonicalBytes(.object([
      "schemaVersion": .string("arkdeck.deveco-toolchain-content/2"),
      "kind": .string("deveco"),
      "productVersion": .string(productInfo.version),
      "buildNumber": .string(productInfo.buildNumber),
      "sdkVersion": .string(sdkInfo.data.version),
      "apiVersion": .string(sdkInfo.data.apiVersion),
      "bundleTrust": bundleTrust.projection(),
      "children": .array(children.map(\.publicValue)),
    ])))
    return Record(
      reference: "toolchain:sha256:" + digest, contentDigest: digest,
      root: rootIdentity, productVersion: productInfo.version,
      buildNumber: productInfo.buildNumber, sdkVersion: sdkInfo.data.version,
      apiVersion: sdkInfo.data.apiVersion, registeredAtUTC: "1970-01-01T00:00:00Z",
      bundleTrust: bundleTrust, children: children,
      generation: 1, state: "available", references: [])
  }

  private func verify(_ record: Record) throws {
    let measured = try inspectRoot(URL(filePath: record.root.path, directoryHint: .isDirectory))
    guard measured.reference == record.reference, measured.contentDigest == record.contentDigest,
      measured.root == record.root, measured.productVersion == record.productVersion,
      measured.buildNumber == record.buildNumber, measured.sdkVersion == record.sdkVersion,
      measured.apiVersion == record.apiVersion, measured.bundleTrust == record.bundleTrust,
      measured.children == record.children
    else {
      throw Files.failure(
        "recordUnreadable", "registered DevEco root, manifests or child tools changed")
    }
  }

  private func value(_ record: Record) -> JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.runtime-tool/1"),
      "toolRef": .string(record.reference),
      "kind": .string("deveco"),
      "platform": .string("macos"),
      "source": .string("registeredRoot"),
      "generation": .string(String(record.generation)),
      "state": .string(record.state),
      "contentDigest": .string(record.contentDigest),
      "digestAlgorithm": .string("sha256-jcs"),
      "contentSchemaVersion": .string("arkdeck.deveco-toolchain-content/2"),
      "productVersion": .string(record.productVersion),
      "buildNumber": .string(record.buildNumber),
      "sdkVersion": .string(record.sdkVersion),
      "apiVersion": .string(record.apiVersion),
      "trust": record.bundleTrust.projection(),
      "childTools": .array(record.children.map(\.publicValue)),
      "selected": .bool(false),
      "references": .array(record.references.map {
        .object(["kind": .string($0.kind.rawValue), "id": .string($0.id)])
      }),
      "contentRetained": .bool(false),
    ])
  }

  private func readChild(
    rootFD: Int32, root: URL, role: String, relativePath: String,
    maximumBytes: Int, executable: Bool, nativeTrust: Bool
  ) throws -> ChildIdentity {
    let (fd, parent, name) = try openFile(rootFD: rootFD, relativePath: relativePath)
    defer { close(fd); close(parent) }
    let before = try Files.status(fd)
    guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
      before.st_size > 0, before.st_size <= maximumBytes,
      before.st_uid == geteuid() || before.st_uid == 0,
      before.st_mode & 0o022 == 0,
      !executable || before.st_mode & 0o111 != 0
    else {
      throw Files.failure("admissionDenied", "DevEco child role has an unsafe file identity")
    }
    let data = try Files.read(fd, maximum: maximumBytes)
    guard data.count == before.st_size else {
      throw Files.failure("fileIdentityChanged", "DevEco child role changed while reading")
    }
    var linked = stat()
    guard fstatat(parent, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
      Files.Identity(try Files.status(fd)) == Files.Identity(before),
      Files.Identity(linked) == Files.Identity(before)
    else {
      throw Files.failure("fileIdentityChanged", "DevEco child role was replaced")
    }
    let trust = nativeTrust ? try inspectTrust(root.appending(path: relativePath)) : nil
    return ChildIdentity(
      role: role, relativePath: relativePath,
      device: UInt64(before.st_dev), inode: UInt64(before.st_ino),
      byteCount: Int64(before.st_size),
      modifiedSeconds: Int64(before.st_mtimespec.tv_sec),
      modifiedNanos: Int64(before.st_mtimespec.tv_nsec),
      changedSeconds: Int64(before.st_ctimespec.tv_sec),
      changedNanos: Int64(before.st_ctimespec.tv_nsec),
      sha256: SHA256Hex.string(of: data),
      executable: before.st_mode & 0o111 != 0, trust: trust)
  }

  /// The resource envelope is itself sealed by the code directory validated
  /// by `inspectCodeOnly`. Require every Runtime allowlisted child role to be
  /// present in that publisher-owned envelope with its exact SHA-256. Other
  /// SDK-manager resources may move without turning an unrelated mutation
  /// into trust for one of ArkDeck's executable inputs.
  private static func verifySignedResourceEnvelope(
    root: URL, expected: [String: String]
  ) throws {
    let envelopeURL = root.appending(path: Self.signedResourceEnvelope)
    let data: Data
    do {
      let values = try envelopeURL.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        let byteCount = values.fileSize, (1...(32 * 1_024 * 1_024)).contains(byteCount)
      else {
        throw Files.failure(
          "admissionDenied", "DevEco signed resource envelope has an unsafe identity")
      }
      data = try Data(contentsOf: envelopeURL, options: [.mappedIfSafe])
      guard data.count == byteCount else {
        throw Files.failure(
          "fileIdentityChanged", "DevEco signed resource envelope changed while reading")
      }
    } catch let failure as AgentExecutionControlFailure {
      throw failure
    } catch {
      throw Files.failure(
        "admissionDenied", "DevEco signed resource envelope cannot be read")
    }
    let rootObject: Any
    do {
      rootObject = try PropertyListSerialization.propertyList(
        from: data, options: [], format: nil)
    } catch {
      throw Files.failure(
        "admissionDenied", "DevEco signed resource envelope is malformed")
    }
    guard let rootFields = rootObject as? [String: Any],
      let resources = rootFields["files2"] as? [String: Any]
    else {
      throw Files.failure(
        "admissionDenied", "DevEco signed resource envelope has no SHA-256 table")
    }
    for (relativePath, digest) in expected {
      let raw = resources[relativePath]
      let sealed: Data?
      if let direct = raw as? Data {
        sealed = direct
      } else if let fields = raw as? [String: Any] {
        sealed = fields["hash2"] as? Data
      } else {
        sealed = nil
      }
      guard let sealed, sealed.count == 32,
        sealed.map({ String(format: "%02x", $0) }).joined() == digest
      else {
        throw Files.failure(
          "admissionDenied",
          "DevEco child role is not bound by the publisher resource envelope")
      }
    }
  }

  private func readData(
    rootFD: Int32, relativePath: String, maximum: Int
  ) throws -> Data {
    let (fd, parent, _) = try openFile(rootFD: rootFD, relativePath: relativePath)
    defer { close(fd); close(parent) }
    return try Files.read(fd, maximum: maximum)
  }

  private func openFile(
    rootFD: Int32, relativePath: String
  ) throws -> (Int32, Int32, String) {
    let parts = relativePath.split(separator: "/").map(String.init)
    guard parts.count >= 2 else {
      throw Files.failure("invalidInput", "DevEco child role path is malformed")
    }
    var parent = openat(rootFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard parent >= 0 else { throw Files.failure("ioFailure", "cannot duplicate DevEco root") }
    do {
      for component in parts.dropLast() {
        let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard next >= 0 else {
          throw Files.failure("fileIdentityChanged", "DevEco child directory cannot be opened safely")
        }
        close(parent)
        parent = next
        let status = try Files.status(parent)
        guard status.st_mode & S_IFMT == S_IFDIR,
          (status.st_uid == geteuid() || status.st_uid == 0), status.st_mode & 0o022 == 0
        else {
          throw Files.failure("admissionDenied", "DevEco child directory is unsafe")
        }
      }
      let name = parts.last!
      let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
      guard fd >= 0 else {
        throw Files.failure("fileIdentityChanged", "DevEco child role cannot be opened safely")
      }
      return (fd, parent, name)
    } catch {
      close(parent)
      throw error
    }
  }

  private func openRootDirectory(_ url: URL) throws -> Int32 {
    let path = try Files.physicalPath(url)
    var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard current >= 0 else {
      throw Files.failure("ioFailure", "cannot open the DevEco root ancestry")
    }
    var traversed = ""
    do {
      for component in path.split(separator: "/") {
        let name = String(component)
        let next = openat(
          current, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard next >= 0 else {
          throw Files.failure(
            "fileIdentityChanged", "DevEco root ancestry cannot be opened without links")
        }
        close(current)
        current = next
        traversed += "/" + name
        let status = try Files.status(current)
        let standardApplicationsDirectory = traversed == "/Applications"
          && status.st_uid == 0 && status.st_gid == 80
          && status.st_mode & 0o002 == 0
        let standardTemporaryDirectory = traversed == "/private/tmp"
          && status.st_uid == 0 && status.st_gid == 0
          && status.st_mode & 0o1000 != 0
        guard status.st_mode & S_IFMT == S_IFDIR,
          (status.st_uid == geteuid() || status.st_uid == 0),
          status.st_mode & 0o022 == 0 || standardApplicationsDirectory
            || standardTemporaryDirectory
        else {
          throw Files.failure(
            "admissionDenied", "DevEco root ancestry has unsafe ownership or permissions")
        }
      }
      return current
    } catch {
      close(current)
      throw error
    }
  }

  private func requireLinkedRoot(_ descriptor: Int32, url: URL) throws {
    let reopened = try openRootDirectory(url)
    defer { close(reopened) }
    let before = try Files.status(descriptor)
    let after = try Files.status(reopened)
    guard before.st_dev == after.st_dev, before.st_ino == after.st_ino else {
      throw Files.failure("fileIdentityChanged", "DevEco root changed during inspection")
    }
  }

  private func openDirectory(rootFD: Int32, relativePath: String) throws -> Int32 {
    let parts = relativePath.split(separator: "/").map(String.init)
    var current = openat(rootFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard current >= 0 else { throw Files.failure("ioFailure", "cannot duplicate DevEco root") }
    do {
      for component in parts {
        let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard next >= 0 else {
          throw Files.failure("fileIdentityChanged", "DevEco SDK directory cannot be opened safely")
        }
        close(current)
        current = next
        let status = try Files.status(current)
        guard status.st_mode & S_IFMT == S_IFDIR,
          (status.st_uid == geteuid() || status.st_uid == 0),
          status.st_mode & 0o022 == 0
        else {
          throw Files.failure(
            "admissionDenied", "DevEco SDK directory has unsafe ownership or permissions")
        }
      }
      return current
    } catch {
      close(current)
      throw error
    }
  }

  private func find(_ reference: String, in index: Index) throws -> Record {
    guard reference.hasPrefix("toolchain:sha256:"),
      BootstrapToolTrust.digest(String(reference.dropFirst("toolchain:sha256:".count)))
    else {
      throw Files.failure("invalidInput", "expected a content-addressed toolchain reference")
    }
    guard let record = index.records.first(where: { $0.reference == reference }) else {
      throw Files.failure("resourceNotFound", "toolchain reference does not exist")
    }
    return record
  }

  private func replace(_ record: Record, in index: inout Index) {
    index.records[index.records.firstIndex { $0.reference == record.reference }!] = record
  }

  private func readIndex(_ directory: Int32) throws -> Index {
    let fd = openat(
      directory, Self.indexName, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0, errno == ENOENT {
      let initial = Index()
      try saveIndex(initial, directory: directory, root: nil)
      return initial
    }
    guard fd >= 0 else {
      throw Files.failure("recordUnreadable", "DevEco toolchain index cannot be opened")
    }
    defer { close(fd) }
    do {
      let before = try Files.status(fd)
      guard before.st_mode & S_IFMT == S_IFREG, before.st_uid == geteuid(),
        before.st_nlink == 1, before.st_mode & 0o077 == 0
      else { throw Files.failure("DevEco toolchain index is unsafe") }
      let data = try Files.read(fd, maximum: Files.maximumMetadataBytes)
      guard Files.Identity(try Files.status(fd)) == Files.Identity(before) else {
        throw Files.failure("DevEco toolchain index changed while reading")
      }
      let raw = try ControlProtocolNegotiation.decodeObject(
        data, maximumBytes: Files.maximumMetadataBytes)
      let index = try JSONDecoder().decode(Index.self, from: data)
      let encoded = try CanonicalJSONEncoders.canonical().encode(index)
      let roundtrip = try ControlProtocolNegotiation.decodeObject(
        encoded, maximumBytes: Files.maximumMetadataBytes)
      guard raw == roundtrip,
        index.schemaVersion == "arkdeck.bootstrap-deveco-toolchains/1",
        index.records.count <= Self.maximumRecords,
        index.records.map(\.reference) == index.records.map(\.reference).sorted(),
        Set(index.records.map(\.reference)).count == index.records.count
      else { throw Files.failure("DevEco toolchain index schema is invalid") }
      for record in index.records {
        guard record.reference == "toolchain:sha256:" + record.contentDigest,
          BootstrapToolTrust.digest(record.contentDigest), record.root.path.hasPrefix("/"),
          Self.version(record.productVersion), Self.identifier(record.buildNumber),
          Self.version(record.sdkVersion), Self.identifier(record.apiVersion),
          record.bundleTrust.isWellFormed,
          record.children.count == 5,
          Set(record.children.map(\.role))
            == Set([
              "productManifest", "sdkManifest", "node", "hvigor",
              "signedResourceEnvelope",
            ]),
          record.children.allSatisfy({ BootstrapToolTrust.digest($0.sha256) && $0.byteCount > 0 }),
          (record.state == "available" && record.generation == 1)
            || (record.state == "removed" && record.generation == 2 && record.references.isEmpty),
          record.references.count <= Self.maximumReferences,
          Set(record.references.map { $0.kind.rawValue + ":" + $0.id }).count
            == record.references.count,
          record.references.allSatisfy({ AgentExecutionIntent.validIdentifier($0.id) }),
          ISO8601DateFormatter().date(from: record.registeredAtUTC) != nil
        else { throw Files.failure("DevEco toolchain record is invalid") }
      }
      return index
    } catch {
      throw Files.failure(
        "recordUnreadable", "DevEco toolchain index failed schema or identity validation")
    }
  }

  private func saveIndex(_ index: Index, directory: Int32, root: URL?) throws {
    let data = try CanonicalJSONEncoders.canonical().encode(index)
    guard data.count <= Files.maximumMetadataBytes else {
      throw Files.failure("quotaExceeded", "DevEco toolchain index exceeds its storage bound")
    }
    let temporary = ".deveco-index-\(UUID().uuidString.lowercased())"
    let fd = openat(
      directory, temporary,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else {
      throw Files.failure("ioFailure", "cannot create DevEco toolchain index transaction")
    }
    defer { close(fd); unlinkat(directory, temporary, 0) }
    try Files.write(data, to: fd)
    try Files.sync(fd)
    if let root { try Files.requireLinkedDirectory(directory, url: root) }
    guard renameat(directory, temporary, directory, Self.indexName) == 0 else {
      throw Files.failure("ioFailure", "cannot publish DevEco toolchain index")
    }
    do { try Files.sync(directory) }
    catch {
      throw Files.failure(
        "outcomeUnknown", "DevEco toolchain index was published but durability is unconfirmed")
    }
  }

  private static func rootIdentity(path: String, status: stat) -> RootIdentity {
    RootIdentity(
      path: path, device: UInt64(status.st_dev), inode: UInt64(status.st_ino),
      modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
      modifiedNanos: Int64(status.st_mtimespec.tv_nsec),
      changedSeconds: Int64(status.st_ctimespec.tv_sec),
      changedNanos: Int64(status.st_ctimespec.tv_nsec))
  }

  private static func identifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
      && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
        || (97...122).contains($0) || [45, 46, 95].contains($0) }
  }

  private static func version(_ value: String) -> Bool {
    identifier(value) && value.contains(where: { $0.isNumber })
  }
}

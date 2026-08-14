import ArkDeckCore
import ArkDeckProcess
import CryptoKit
import Darwin
import Foundation
import Security

package enum ArkTraceSummaryProfileError: Error, Equatable, CustomStringConvertible {
  case notFound
  case descriptorInvalid
  case manifestDrift
  case contractMismatch
  case toolDrift
  case parserDrift
  case selfTestFailed

  package var reason: String {
    switch self {
    case .notFound: return "analyzer.arktraceNotFound"
    case .descriptorInvalid: return "analyzer.arktraceDescriptorInvalid"
    case .manifestDrift: return "analyzer.arktraceManifestDrift"
    case .contractMismatch: return "analyzer.arktraceContractMismatch"
    case .toolDrift: return "analyzer.arktraceToolDrift"
    case .parserDrift: return "analyzer.arktraceParserDrift"
    case .selfTestFailed: return "analyzer.arktraceSelfTestFailed"
    }
  }

  package var description: String { reason }
}

package struct ArkTraceDoctorContract: Sendable, Equatable {
  package let executable: ResolvedExecutable
  package let productVersion: String
  package let timeoutSeconds: Int
  package let outputByteBudget: Int
}

package protocol ArkTraceDoctorProbing: Sendable {
  func probe(_ contract: ArkTraceDoctorContract) async -> Bool
}

package struct ArkTraceDistributionTrustContract: Sendable, Equatable {
  package let appPath: String
  package let helperPath: String
  package let resourcePath: String
  package let productVersion: String
  package let productBuild: String
  package let bundleIdentifier: String
  package let teamIdentifier: String
  package let signingIdentity: String
  package let certificateSHA1: String
  package let appCodeDirectoryHash: String
  package let helperCodeDirectoryHash: String
  package let appTreeSHA256: String
  package let resourceTreeSHA256: String
}

package protocol ArkTraceDistributionTrustChecking: Sendable {
  func validate(_ contract: ArkTraceDistributionTrustContract) throws
    -> ArkTraceDistributionTrustEvidence
}

package struct ArkTraceDistributionTrustEvidence: Sendable, Equatable {
  package let pinnedFiles: [AnalyzerPinnedFile]
  package let pinnedTrees: [AnalyzerPinnedTree]

  package init(
    pinnedFiles: [AnalyzerPinnedFile] = [],
    pinnedTrees: [AnalyzerPinnedTree] = []
  ) {
    self.pinnedFiles = pinnedFiles
    self.pinnedTrees = pinnedTrees
  }
}

/// Production-only trust boundary for an ArkTrace distribution. Manifest
/// strings are not evidence: the exact App and nested helper must satisfy a
/// Developer ID + notarization requirement, expose the reviewed leaf
/// certificate/CDHashes, and reproduce both reviewed tree projections.
package struct ProductionArkTraceDistributionTrustChecker:
  ArkTraceDistributionTrustChecking
{
  package init() {}

  package func validate(
    _ contract: ArkTraceDistributionTrustContract
  ) throws -> ArkTraceDistributionTrustEvidence {
    guard Self.isTeamIdentifier(contract.teamIdentifier),
      Self.isSHA1(contract.certificateSHA1),
      Self.isCodeDirectoryHash(contract.appCodeDirectoryHash),
      Self.isCodeDirectoryHash(contract.helperCodeDirectoryHash)
    else { throw ArkTraceSummaryProfileError.contractMismatch }

    let requirement =
      "anchor apple generic"
      + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
      + " and certificate leaf[subject.OU] = \"\(contract.teamIdentifier)\""
      + " and notarized"
    try Self.validateCode(
      at: URL(filePath: contract.appPath, directoryHint: .isDirectory),
      requirement: requirement,
      identity: contract.signingIdentity,
      teamIdentifier: contract.teamIdentifier,
      certificateSHA1: contract.certificateSHA1,
      codeDirectoryHash: contract.appCodeDirectoryHash,
      checksNestedCode: true,
      expectedIdentifier: contract.bundleIdentifier)
    try Self.validateCode(
      at: URL(filePath: contract.helperPath),
      requirement: requirement,
      identity: contract.signingIdentity,
      teamIdentifier: contract.teamIdentifier,
      certificateSHA1: contract.certificateSHA1,
      codeDirectoryHash: contract.helperCodeDirectoryHash,
      checksNestedCode: false,
      expectedIdentifier: nil)

    let appTree = try ArkTraceDistributionTreeHasher.snapshot(rootPath: contract.appPath)
    let resourceTree = try ArkTraceDistributionTreeHasher.snapshot(
      rootPath: contract.resourcePath)
    guard appTree.sha256 == contract.appTreeSHA256,
      resourceTree.sha256 == contract.resourceTreeSHA256
    else { throw ArkTraceSummaryProfileError.contractMismatch }

    let infoPath = URL(filePath: contract.appPath)
      .appending(path: "Contents/Info.plist").path
    let info = try ArkTraceProfileFileReader.read(
      path: infoPath, maximumByteCount: 64 * 1024).data
    guard let plist = try PropertyListSerialization.propertyList(
      from: info, options: [], format: nil)
      as? [String: Any],
      plist["CFBundleIdentifier"] as? String == contract.bundleIdentifier,
      plist["CFBundleShortVersionString"] as? String == contract.productVersion,
      String(describing: plist["CFBundleVersion"] ?? "") == contract.productBuild
    else { throw ArkTraceSummaryProfileError.contractMismatch }

    // A stapled application carries a bounded physical ticket at this exact
    // location. The `notarized` code requirement above validates the ticket's
    // trust semantics; this check prevents a manifest-only claim.
    let ticketPath = URL(filePath: contract.appPath)
      .appending(path: "Contents/CodeResources").path
    let ticket = try ArkTraceProfileFileReader.read(
      path: ticketPath, maximumByteCount: 1024 * 1024)
    guard !ticket.data.isEmpty else { throw ArkTraceSummaryProfileError.contractMismatch }
    return ArkTraceDistributionTrustEvidence(
      pinnedFiles: appTree.pinnedFiles,
      pinnedTrees: [
        AnalyzerPinnedTree(path: contract.appPath, sha256: appTree.sha256)
      ])
  }

  private static func validateCode(
    at url: URL,
    requirement: String,
    identity: String,
    teamIdentifier: String,
    certificateSHA1: String,
    codeDirectoryHash: String,
    checksNestedCode: Bool,
    expectedIdentifier: String?
  ) throws {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
      let staticCode
    else { throw ArkTraceSummaryProfileError.contractMismatch }
    var staticRequirement: SecRequirement?
    guard SecRequirementCreateWithString(
      requirement as CFString, SecCSFlags(), &staticRequirement) == errSecSuccess,
      let staticRequirement
    else { throw ArkTraceSummaryProfileError.contractMismatch }
    var rawFlags = kSecCSStrictValidate | kSecCSCheckAllArchitectures
    if checksNestedCode { rawFlags |= kSecCSCheckNestedCode }
    guard SecStaticCodeCheckValidity(
      staticCode, SecCSFlags(rawValue: rawFlags), staticRequirement) == errSecSuccess
    else { throw ArkTraceSummaryProfileError.contractMismatch }

    var rawInformation: CFDictionary?
    guard SecCodeCopySigningInformation(
      staticCode,
      SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation),
      &rawInformation) == errSecSuccess,
      let information = rawInformation as? [String: Any],
      information[kSecCodeInfoTeamIdentifier as String] as? String == teamIdentifier,
      let codeFlags = information[kSecCodeInfoFlags as String] as? NSNumber,
      codeFlags.uint32Value & 0x0001_0000 != 0,
      let unique = information[kSecCodeInfoUnique as String] as? Data,
      unique.map({ String(format: "%02x", $0) }).joined() == codeDirectoryHash,
      let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate],
      let leaf = certificates.first,
      SecCertificateCopySubjectSummary(leaf) as String? == identity,
      Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
        .map({ String(format: "%02X", $0) }).joined() == certificateSHA1
    else { throw ArkTraceSummaryProfileError.contractMismatch }
    if let expectedIdentifier {
      guard information[kSecCodeInfoIdentifier as String] as? String == expectedIdentifier else {
        throw ArkTraceSummaryProfileError.contractMismatch
      }
    }
  }

  private static func isTeamIdentifier(_ value: String) -> Bool {
    value.count == 10 && value.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isUppercase) })
  }

  private static func isSHA1(_ value: String) -> Bool {
    value.count == 40 && value.allSatisfy({ $0.isHexDigit && !$0.isLowercase })
  }

  private static func isCodeDirectoryHash(_ value: String) -> Bool {
    value.count == 40 && value.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
  }
}

package struct ProductionArkTraceDoctorProbe: ArkTraceDoctorProbing {
  private let homeURL: URL
  private let executor: FoundationProcessExecutor

  package init(homeURL: URL, executor: FoundationProcessExecutor = FoundationProcessExecutor()) {
    self.homeURL = homeURL
    self.executor = executor
  }

  package func probe(_ contract: ArkTraceDoctorContract) async -> Bool {
    do {
      try preparePrivateHome()
      let verifiedNamespace = try contract.executable.canonicalNamespaceRoot.map {
        try VerifiedDirectoryDescriptor.openOwnerOnly(path: URL(filePath: $0))
      }
      defer { verifiedNamespace?.close() }
      guard contract.executable.verifiedTrees.allSatisfy({
        ArkTraceDistributionTreeHasher.matches(
          rootPath: $0.path, expectedSHA256: $0.sha256)
      }) else { return false }
      let verifiedResources = try contract.executable.verifiedResources.map {
        let descriptor = try VerifiedRegularFileDescriptor.open(
          path: URL(filePath: $0.path), expectedSHA256: $0.sha256,
          maximumBytes: $0.byteCount, requireExecutable: $0.requireExecutable)
        guard descriptor.byteCount == $0.byteCount else {
          descriptor.close()
          throw VerifiedRegularFileError.identityChanged
        }
        return descriptor
      }
      defer { verifiedResources.forEach { $0.close() } }
      let result = try await executor.executeIdentityBound(
        ProcessIdentityBoundRequest(
          process: ProcessRequest(
            executable: URL(filePath: contract.executable.path),
            arguments: [
              "doctor", "--self-test", "--json", "--no-cache", "--timeout-ms",
              String(contract.timeoutSeconds * 1_000), "--max-output-bytes",
              String(contract.outputByteBudget),
            ],
            environment: [
              "CFFIXED_USER_HOME": homeURL.path,
              "HOME": homeURL.path,
            ],
            timeout: TimeInterval(contract.timeoutSeconds + 5),
            executableLaunchMode: .verifiedCanonicalPath),
          expectedSHA256: contract.executable.sha256),
        verifiedResources: verifiedResources,
        verifiedNamespace: verifiedNamespace,
        captureLimit: contract.outputByteBudget)
      guard result.execution.termination == .exited(0),
        !result.execution.stdout.wasTruncated,
        result.execution.stdout.totalByteCount == result.execution.stdout.data.count,
        result.execution.stderr.data.isEmpty,
        ArkTraceDoctorEnvelopeValidator.validate(
          result.execution.stdout.data, contract: contract)
      else { return false }
      return true
    } catch {
      return false
    }
  }

  private func preparePrivateHome() throws {
    let directories = [
      homeURL,
      homeURL.appending(path: "Library", directoryHint: .isDirectory),
      homeURL.appending(path: "Library/Caches", directoryHint: .isDirectory),
      homeURL.appending(path: "Library/Application Support", directoryHint: .isDirectory),
    ]
    for directory in directories {
      var metadata = stat()
      if lstat(directory.path, &metadata) == 0 {
        guard metadata.st_mode & S_IFMT == S_IFDIR,
          try ArkTraceProfileFileReader.hasNoSymlinkComponent(directory.path)
        else { throw ArkTraceSummaryProfileError.selfTestFailed }
      } else {
        guard errno == ENOENT else { throw ArkTraceSummaryProfileError.selfTestFailed }
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
      }
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
      guard try ArkTraceProfileFileReader.isPhysicalDirectory(directory.path) else {
        throw ArkTraceSummaryProfileError.selfTestFailed
      }
    }
  }
}

private enum ArkTraceDoctorEnvelopeValidator {
  static func validate(_ data: Data, contract: ArkTraceDoctorContract) -> Bool {
    do {
      var duplicate = StrictJSONDuplicateValidator(data: data)
      try duplicate.validate()
      var integers = StrictJSONIntegerTokenValidator(data: data)
      try integers.validate()
      guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        keys(root) == [
          "schemaVersion", "tool", "request", "trace", "provenance", "limits",
          "dataQuality", "truncation", "result",
        ],
        root["schemaVersion"] as? String == "1.0",
        root["trace"] is NSNull, root["provenance"] is NSNull,
        let tool = root["tool"] as? [String: Any],
        keys(tool) == ["name", "version", "buildRevision"],
        tool["name"] as? String == "arktrace",
        tool["version"] as? String == contract.productVersion,
        tool["buildRevision"] as? String == contract.executable.sha256,
        let request = root["request"] as? [String: Any],
        keys(request) == ["command", "parameters"],
        request["command"] as? String == "doctor",
        let parameters = request["parameters"] as? [String: Any],
        keys(parameters) == ["selfTest"], boolean(parameters["selfTest"]) == true,
        let limits = root["limits"] as? [String: Any],
        keys(limits) == ["timeoutMs", "maxRows", "maxEvents", "maxOutputBytes"],
        integer(limits["timeoutMs"]) == Int64(contract.timeoutSeconds * 1_000),
        integer(limits["maxRows"]) == 10_000,
        integer(limits["maxEvents"]) == 10_000,
        integer(limits["maxOutputBytes"]) == Int64(contract.outputByteBudget),
        let quality = root["dataQuality"] as? [String: Any],
        keys(quality) == ["status", "warnings"], quality["status"] as? String == "ok",
        (quality["warnings"] as? [Any])?.isEmpty == true,
        let truncation = root["truncation"] as? [String: Any],
        keys(truncation) == ["truncated", "sections"],
        boolean(truncation["truncated"]) == false,
        (truncation["sections"] as? [Any])?.isEmpty == true,
        let result = root["result"] as? [String: Any],
        keys(result) == ["checks", "selfTest"], boolean(result["selfTest"]) == true,
        let checks = result["checks"] as? [[String: Any]], checks.count == 9
      else { return false }
      let expectedCodes = [
        "tool", "os", "architecture", "parserManifest", "parserIdentity",
        "sqlite", "cache", "schemaAdapter", "selfTest",
      ]
      return zip(checks, expectedCodes).allSatisfy { check, expectedCode in
        keys(check) == ["code", "name", "status"]
          && check["code"] as? String == expectedCode
          && check["status"] as? String == "ok"
          && (check["name"] as? String).map(safeName) == true
      }
    } catch {
      return false
    }
  }

  private static func keys(_ value: [String: Any]) -> Set<String> { Set(value.keys) }

  private static func boolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber,
      String(cString: number.objCType) == "c"
    else { return nil }
    return number.boolValue
  }

  private static func integer(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber,
      String(cString: number.objCType) != "c"
    else { return nil }
    return number.int64Value
  }

  private static func safeName(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
      && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }
}

package struct ArkTraceSummaryAnalyzerProfileLoader: Sendable {
  private let doctor: any ArkTraceDoctorProbing
  private let trustChecker: any ArkTraceDistributionTrustChecking
  private let snapshotRootURL: URL?
  private let snapshotRootBoundHook: @Sendable () throws -> Void
  private let beforeSnapshotPublicationHook: @Sendable (_ finalName: String) throws -> Void

  package init(
    doctor: any ArkTraceDoctorProbing,
    trustChecker: any ArkTraceDistributionTrustChecking =
      ProductionArkTraceDistributionTrustChecker(),
    snapshotRootURL: URL? = nil,
    snapshotRootBoundHook: @escaping @Sendable () throws -> Void = {},
    beforeSnapshotPublicationHook:
      @escaping @Sendable (_ finalName: String) throws -> Void = { _ in }
  ) {
    self.doctor = doctor
    self.trustChecker = trustChecker
    self.snapshotRootURL = snapshotRootURL
    self.snapshotRootBoundHook = snapshotRootBoundHook
    self.beforeSnapshotPublicationHook = beforeSnapshotPublicationHook
  }

  package func load(descriptorURL: URL) async throws -> AnalyzerProfile {
    guard descriptorURL.path.hasPrefix("/") else {
      throw ArkTraceSummaryProfileError.descriptorInvalid
    }
    var descriptorMetadata = stat()
    if lstat(descriptorURL.path, &descriptorMetadata) != 0, errno == ENOENT {
      throw ArkTraceSummaryProfileError.notFound
    }
    guard (try? ArkTraceProfileFileReader.validateOwnerOnlyAuthority(
      path: descriptorURL.path, leafIsDirectory: false)) != nil
    else { throw ArkTraceSummaryProfileError.descriptorInvalid }
    let descriptorData: Data
    do {
      descriptorData = try ArkTraceProfileFileReader.read(
        path: descriptorURL.path, maximumByteCount: 16 * 1024).data
    } catch ArkTraceProfileFileReader.ReaderError.open {
      throw ArkTraceSummaryProfileError.notFound
    } catch ArkTraceProfileFileReader.ReaderError.physicalPath {
      var descriptorMetadata = stat()
      if lstat(descriptorURL.path, &descriptorMetadata) != 0, errno == ENOENT {
        throw ArkTraceSummaryProfileError.notFound
      }
      throw ArkTraceSummaryProfileError.descriptorInvalid
    } catch {
      throw ArkTraceSummaryProfileError.descriptorInvalid
    }
    try validateDuplicateFreeJSON(descriptorData)
    guard
      let descriptorObject = try JSONSerialization.jsonObject(with: descriptorData)
        as? [String: Any],
      Set(descriptorObject.keys) == ["formatVersion", "distributionRoot", "manifestSHA256"],
      descriptorObject["formatVersion"] as? Int == 1,
      let rootPath = descriptorObject["distributionRoot"] as? String,
      rootPath.hasPrefix("/"),
      let manifestSHA256 = descriptorObject["manifestSHA256"] as? String,
      Self.isSHA256(manifestSHA256)
    else {
      throw ArkTraceSummaryProfileError.descriptorInvalid
    }

    let root = URL(filePath: rootPath, directoryHint: .isDirectory)
    guard try ArkTraceProfileFileReader.isPhysicalDirectory(root.path) else {
      throw ArkTraceSummaryProfileError.notFound
    }
    guard (try? ArkTraceProfileFileReader.validateOwnerOnlyAuthority(
      path: root.path, leafIsDirectory: true)) != nil
    else { throw ArkTraceSummaryProfileError.descriptorInvalid }
    let manifestURL = root.appending(path: "distribution-manifest.json")
    let manifestSnapshot: ArkTraceProfileFileReader.Snapshot
    do {
      manifestSnapshot = try ArkTraceProfileFileReader.read(
        path: manifestURL.path, maximumByteCount: 64 * 1024)
    } catch {
      throw ArkTraceSummaryProfileError.manifestDrift
    }
    guard AnalyzerProvider.sha256(manifestSnapshot.data) == manifestSHA256 else {
      throw ArkTraceSummaryProfileError.manifestDrift
    }
    try validateDuplicateFreeJSON(manifestSnapshot.data)
    try Self.validateManifestKeyClosure(manifestSnapshot.data)
    let manifest: DistributionManifest
    do {
      manifest = try JSONDecoder().decode(DistributionManifest.self, from: manifestSnapshot.data)
    } catch {
      throw ArkTraceSummaryProfileError.contractMismatch
    }
    try Self.validateContract(manifest)

    let sourceExecutablePath = try Self.physicalPath(
      root: root, relative: manifest.layout.executable)
    let sourceParserPath = try Self.physicalPath(
      root: root, relative: manifest.layout.parserExecutable)
    let sourceParserManifestPath = try Self.physicalPath(
      root: root, relative: manifest.layout.parserManifest)
    let sourceSigningRecordPath = try Self.physicalPath(
      root: root, relative: manifest.layout.parserSigningRecord)
    let sourceReceiptPath = try Self.physicalPath(
      root: root, relative: manifest.notarization.receipt)
    let receiptSnapshot: ArkTraceProfileFileReader.Snapshot
    do {
      receiptSnapshot = try ArkTraceProfileFileReader.read(
        path: sourceReceiptPath, maximumByteCount: 1024 * 1024)
    } catch {
      throw ArkTraceSummaryProfileError.parserDrift
    }

    guard ArkTraceProfileFileReader.matches(
      path: sourceExecutablePath, sha256: manifest.tool.binarySHA256,
      byteCount: manifest.tool.byteCount, maximumByteCount: 128 * 1024 * 1024,
      requireExecutable: true)
    else { throw ArkTraceSummaryProfileError.toolDrift }
    guard ArkTraceProfileFileReader.matches(
      path: sourceParserPath, sha256: manifest.traceStreamer.binarySHA256,
      byteCount: manifest.traceStreamer.byteCount, maximumByteCount: 128 * 1024 * 1024,
      requireExecutable: true),
      ArkTraceProfileFileReader.matches(
        path: sourceParserManifestPath, sha256: manifest.traceStreamer.manifestSHA256,
        byteCount: manifest.traceStreamer.manifestByteCount, maximumByteCount: 64 * 1024),
      ArkTraceProfileFileReader.matches(
        path: sourceSigningRecordPath, sha256: manifest.traceStreamer.signingRecordSHA256,
        byteCount: manifest.traceStreamer.signingRecordByteCount, maximumByteCount: 64 * 1024),
      AnalyzerProvider.sha256(receiptSnapshot.data) == manifest.notarization.receiptSHA256
    else { throw ArkTraceSummaryProfileError.parserDrift }

    let sourceAppPath = try Self.physicalPath(root: root, relative: manifest.layout.bundle)
    let sourceResourcePath = try Self.physicalPath(
      root: root, relative: manifest.layout.resourceBundle)
    let sourceTrustEvidence = try trustChecker.validate(
      ArkTraceDistributionTrustContract(
        appPath: sourceAppPath,
        helperPath: sourceParserPath,
        resourcePath: sourceResourcePath,
        productVersion: manifest.product.version,
        productBuild: manifest.product.build,
        bundleIdentifier: manifest.product.bundleIdentifier,
        teamIdentifier: manifest.signing.teamIdentifier,
        signingIdentity: manifest.signing.identity,
        certificateSHA1: manifest.signing.certificateSHA1,
        appCodeDirectoryHash: manifest.integrity.appCodeDirectoryHash,
        helperCodeDirectoryHash: manifest.traceStreamer.codeDirectoryHash,
        appTreeSHA256: manifest.integrity.appTreeSHA256,
        resourceTreeSHA256: manifest.integrity.resourceTreeSHA256))

    // A signed bundle must keep its canonical path so Bundle.main can locate
    // Helpers and Resources. Rather than trusting the selected install path
    // after SIGCONT, production materializes one bounded descriptor-copy in a
    // daemon-private generation directory. No upgrade mutates that namespace;
    // a new distribution produces a different generation and daemon restart.
    let runtimeRoot: URL
    if let snapshotRootURL {
      runtimeRoot = try materializePrivateSnapshot(
        sourceRoot: root, snapshotRoot: snapshotRootURL)
    } else {
      runtimeRoot = root
    }
    let runtimeManifestURL: URL
    let executablePath: String
    let parserPath: String
    let parserManifestPath: String
    let signingRecordPath: String
    let receiptPath: String
    let appPath: String
    let resourcePath: String
    if snapshotRootURL == nil {
      runtimeManifestURL = manifestURL
      executablePath = sourceExecutablePath
      parserPath = sourceParserPath
      parserManifestPath = sourceParserManifestPath
      signingRecordPath = sourceSigningRecordPath
      receiptPath = sourceReceiptPath
      appPath = sourceAppPath
      resourcePath = sourceResourcePath
    } else {
      runtimeManifestURL = runtimeRoot.appending(path: "distribution-manifest.json")
      executablePath = try Self.physicalPath(
        root: runtimeRoot, relative: manifest.layout.executable)
      parserPath = try Self.physicalPath(
        root: runtimeRoot, relative: manifest.layout.parserExecutable)
      parserManifestPath = try Self.physicalPath(
        root: runtimeRoot, relative: manifest.layout.parserManifest)
      signingRecordPath = try Self.physicalPath(
        root: runtimeRoot, relative: manifest.layout.parserSigningRecord)
      receiptPath = try Self.physicalPath(
        root: runtimeRoot, relative: manifest.notarization.receipt)
      appPath = try Self.physicalPath(root: runtimeRoot, relative: manifest.layout.bundle)
      resourcePath = try Self.physicalPath(
        root: runtimeRoot, relative: manifest.layout.resourceBundle)
    }
    guard ArkTraceProfileFileReader.matches(
      path: runtimeManifestURL.path, sha256: manifestSHA256,
      byteCount: manifestSnapshot.data.count, maximumByteCount: 64 * 1024),
      ArkTraceProfileFileReader.matches(
        path: receiptPath, sha256: manifest.notarization.receiptSHA256,
        byteCount: receiptSnapshot.data.count, maximumByteCount: 1024 * 1024)
    else { throw ArkTraceSummaryProfileError.manifestDrift }
    let trustEvidence: ArkTraceDistributionTrustEvidence
    if snapshotRootURL == nil {
      trustEvidence = sourceTrustEvidence
    } else {
      trustEvidence = try trustChecker.validate(
        ArkTraceDistributionTrustContract(
          appPath: appPath,
          helperPath: parserPath,
          resourcePath: resourcePath,
          productVersion: manifest.product.version,
          productBuild: manifest.product.build,
          bundleIdentifier: manifest.product.bundleIdentifier,
          teamIdentifier: manifest.signing.teamIdentifier,
          signingIdentity: manifest.signing.identity,
          certificateSHA1: manifest.signing.certificateSHA1,
          appCodeDirectoryHash: manifest.integrity.appCodeDirectoryHash,
          helperCodeDirectoryHash: manifest.traceStreamer.codeDirectoryHash,
          appTreeSHA256: manifest.integrity.appTreeSHA256,
          resourceTreeSHA256: manifest.integrity.resourceTreeSHA256))
    }

    var pinnedFiles = [
      AnalyzerPinnedFile(
        path: runtimeManifestURL.path, sha256: manifestSHA256,
        byteCount: manifestSnapshot.data.count),
      AnalyzerPinnedFile(
        path: parserPath, sha256: manifest.traceStreamer.binarySHA256,
        byteCount: manifest.traceStreamer.byteCount, requireExecutable: true),
      AnalyzerPinnedFile(
        path: parserManifestPath, sha256: manifest.traceStreamer.manifestSHA256,
        byteCount: manifest.traceStreamer.manifestByteCount),
      AnalyzerPinnedFile(
        path: signingRecordPath, sha256: manifest.traceStreamer.signingRecordSHA256,
        byteCount: manifest.traceStreamer.signingRecordByteCount),
      AnalyzerPinnedFile(
        path: receiptPath, sha256: manifest.notarization.receiptSHA256,
        byteCount: receiptSnapshot.data.count),
    ]
    for pin in trustEvidence.pinnedFiles {
      if let existing = pinnedFiles.first(where: { $0.path == pin.path }) {
        guard existing.sha256 == pin.sha256, existing.byteCount == pin.byteCount else {
          throw ArkTraceSummaryProfileError.contractMismatch
        }
      } else {
        pinnedFiles.append(pin)
      }
    }
    pinnedFiles.sort { Data($0.path.utf8).lexicographicallyPrecedes(Data($1.path.utf8)) }

    let outputByteBudget = 8 * 1024 * 1024
    let summaryTimeoutSeconds = 30
    let executable = ResolvedExecutable(
      path: executablePath,
      sha256: manifest.tool.binarySHA256,
      verifiedResources: pinnedFiles.map {
        ResolvedExecutableResource(
          path: $0.path, sha256: $0.sha256, byteCount: max(1, $0.byteCount),
          requireExecutable: $0.requireExecutable)
      },
      verifiedTrees: trustEvidence.pinnedTrees.map {
        ResolvedExecutableTreeResource(path: $0.path, sha256: $0.sha256)
      },
      canonicalNamespaceRoot: appPath)
    guard await doctor.probe(
      ArkTraceDoctorContract(
        executable: executable,
        productVersion: manifest.product.version,
        timeoutSeconds: 120,
        outputByteBudget: 256 * 1024))
    else { throw ArkTraceSummaryProfileError.selfTestFailed }

    // The doctor may take minutes. Rebind every path immediately before the
    // profile becomes admissible so a distribution/root replacement during
    // the probe cannot enter the availability cache as a valid generation.
    guard (try? ArkTraceProfileFileReader.validateOwnerOnlyAuthority(
      path: descriptorURL.path, leafIsDirectory: false)) != nil,
      (try? ArkTraceProfileFileReader.validateOwnerOnlyAuthority(
        path: root.path, leafIsDirectory: true)) != nil,
      ArkTraceProfileFileReader.matches(
      path: executablePath, sha256: manifest.tool.binarySHA256,
      byteCount: manifest.tool.byteCount, maximumByteCount: 128 * 1024 * 1024,
      requireExecutable: true),
      pinnedFiles.allSatisfy({
        ArkTraceProfileFileReader.matches(
          path: $0.path, sha256: $0.sha256, byteCount: $0.byteCount,
          maximumByteCount: 128 * 1024 * 1024,
          requireExecutable: $0.requireExecutable)
      }),
      trustEvidence.pinnedTrees.allSatisfy({
        ArkTraceDistributionTreeHasher.matches(
          rootPath: $0.path, expectedSHA256: $0.sha256)
      })
    else { throw ArkTraceSummaryProfileError.manifestDrift }

    return AnalyzerProfile(
      analyzerRef: "trace-summary@1",
      analyzerVersion: "\(manifest.product.version)+\(manifest.product.build)",
      executablePath: executablePath,
      executableSHA256: manifest.tool.binarySHA256,
      canonicalNamespaceRoot: appPath,
      fixedArguments: [
        "summary", "--json", "--no-cache",
        "--timeout-ms", String(summaryTimeoutSeconds * 1_000),
        "--max-rows", "1000",
        "--max-events", "10000",
        "--max-output-bytes", String(outputByteBudget),
      ],
      timeoutSeconds: summaryTimeoutSeconds,
      outputByteBudget: outputByteBudget,
      pinnedFiles: pinnedFiles,
      pinnedTrees: trustEvidence.pinnedTrees,
      arkTraceSummaryContract: ArkTraceSummaryInvocationContract(
        toolVersion: manifest.product.version,
        parserVersion: manifest.traceStreamer.reportedVersion,
        parserUpstreamRevision: manifest.traceStreamer.upstreamRevision,
        parserSHA256: manifest.traceStreamer.binarySHA256,
        parserBuildRecipeVersion: manifest.traceStreamer.buildRecipeVersion,
        parserAdapterVersion: "1",
        schemaAdapterVersion: "2",
        indexSchemaVersion: 2))
  }

  private func materializePrivateSnapshot(
    sourceRoot: URL,
    snapshotRoot: URL
  ) throws -> URL {
    guard snapshotRoot.isFileURL, snapshotRoot.path.hasPrefix("/") else {
      throw ArkTraceSummaryProfileError.contractMismatch
    }
    let snapshotRootDescriptor = try ArkTraceProfileFileReader
      .openOrCreateOwnerPrivateDirectory(snapshotRoot.path)
    defer { Darwin.close(snapshotRootDescriptor) }
    try snapshotRootBoundHook()

    let selected = try ArkTraceDistributionTreeHasher.snapshot(rootPath: sourceRoot.path)
    let finalName = selected.sha256
    let finalRoot = snapshotRoot.appending(path: finalName, directoryHint: .isDirectory)
    if let existing = try Self.openRelativeDirectoryIfPresent(
      parent: snapshotRootDescriptor, name: finalName)
    {
      defer { Darwin.close(existing) }
      guard ArkTraceDistributionTreeHasher.matches(
        directoryDescriptor: existing, rootPath: finalRoot.path,
        expectedSHA256: selected.sha256),
        Self.path(snapshotRoot.path, stillNames: snapshotRootDescriptor)
      else { throw ArkTraceSummaryProfileError.contractMismatch }
      return finalRoot
    }

    let partialName = ".\(selected.sha256).\(UUID().uuidString.lowercased()).partial"
    let partialRoot = snapshotRoot.appending(path: partialName, directoryHint: .isDirectory)
    let copied: ArkTraceDistributionTreeHasher.TreeSnapshot
    do {
      copied = try ArkTraceDistributionTreeHasher.copySnapshot(
        rootPath: sourceRoot.path,
        destinationParent: snapshotRootDescriptor,
        destinationName: partialName,
        destinationDisplayPath: partialRoot.path)
    } catch {
      try? ArkTraceDistributionTreeHasher.removeSnapshot(
        parentDescriptor: snapshotRootDescriptor, name: partialName)
      throw error
    }
    guard copied.sha256 == selected.sha256 else {
      try? ArkTraceDistributionTreeHasher.removeSnapshot(
        parentDescriptor: snapshotRootDescriptor, name: partialName)
      throw ArkTraceSummaryProfileError.contractMismatch
    }
    do {
      try beforeSnapshotPublicationHook(finalName)
    } catch {
      try? ArkTraceDistributionTreeHasher.removeSnapshot(
        parentDescriptor: snapshotRootDescriptor, name: partialName)
      throw error
    }
    let publicationStatus = partialName.withCString { partial in
      finalName.withCString { final in
        renameatx_np(
          snapshotRootDescriptor, partial,
          snapshotRootDescriptor, final, UInt32(RENAME_EXCL))
      }
    }
    if publicationStatus != 0 {
      guard errno == EEXIST,
        let existing = try Self.openRelativeDirectoryIfPresent(
          parent: snapshotRootDescriptor, name: finalName)
      else {
        try? ArkTraceDistributionTreeHasher.removeSnapshot(
          parentDescriptor: snapshotRootDescriptor, name: partialName)
        throw ArkTraceSummaryProfileError.contractMismatch
      }
      defer { Darwin.close(existing) }
      guard ArkTraceDistributionTreeHasher.matches(
        directoryDescriptor: existing, rootPath: finalRoot.path,
        expectedSHA256: selected.sha256)
      else {
        try? ArkTraceDistributionTreeHasher.removeSnapshot(
          parentDescriptor: snapshotRootDescriptor, name: partialName)
        throw ArkTraceSummaryProfileError.contractMismatch
      }
      try ArkTraceDistributionTreeHasher.removeSnapshot(
        parentDescriptor: snapshotRootDescriptor, name: partialName)
    }
    guard let published = try Self.openRelativeDirectoryIfPresent(
      parent: snapshotRootDescriptor, name: finalName)
    else { throw ArkTraceSummaryProfileError.contractMismatch }
    defer { Darwin.close(published) }
    guard ArkTraceDistributionTreeHasher.matches(
      directoryDescriptor: published, rootPath: finalRoot.path,
      expectedSHA256: selected.sha256),
      Self.path(snapshotRoot.path, stillNames: snapshotRootDescriptor)
    else { throw ArkTraceSummaryProfileError.contractMismatch }
    return finalRoot
  }

  private static func openRelativeDirectoryIfPresent(
    parent: Int32,
    name: String
  ) throws -> Int32? {
    guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
      throw ArkTraceSummaryProfileError.contractMismatch
    }
    let descriptor = name.withCString {
      Darwin.openat(
        parent, $0,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    }
    if descriptor >= 0 { return descriptor }
    if errno == ENOENT { return nil }
    throw ArkTraceSummaryProfileError.contractMismatch
  }

  private static func path(_ path: String, stillNames retained: Int32) -> Bool {
    guard let current = try? ArkTraceProfileFileReader.openPhysicalDirectoryDescriptor(path)
    else { return false }
    defer { Darwin.close(current) }
    var retainedMetadata = stat()
    var currentMetadata = stat()
    return fstat(retained, &retainedMetadata) == 0
      && fstat(current, &currentMetadata) == 0
      && retainedMetadata.st_dev == currentMetadata.st_dev
      && retainedMetadata.st_ino == currentMetadata.st_ino
      && retainedMetadata.st_uid == currentMetadata.st_uid
      && retainedMetadata.st_mode == currentMetadata.st_mode
  }

  private func validateDuplicateFreeJSON(_ data: Data) throws {
    do {
      var validator = StrictJSONDuplicateValidator(data: data)
      try validator.validate()
    } catch {
      throw ArkTraceSummaryProfileError.contractMismatch
    }
  }

  private static func physicalPath(root: URL, relative: String) throws -> String {
    guard !relative.hasPrefix("/"),
      !relative.split(separator: "/").contains(".."),
      !relative.split(separator: "/").contains(".")
    else {
      throw ArkTraceSummaryProfileError.contractMismatch
    }
    let candidate = root.appending(path: relative)
    guard candidate.path.hasPrefix(root.path + "/"),
      try ArkTraceProfileFileReader.hasNoSymlinkComponent(candidate.path)
    else { throw ArkTraceSummaryProfileError.contractMismatch }
    return candidate.path
  }

  private static func validateContract(_ manifest: DistributionManifest) throws {
    guard manifest.formatVersion == 1,
      manifest.product.name == "arktrace",
      manifest.product.version == "0.1.0",
      manifest.product.build == "1",
      manifest.product.architecture == "arm64",
      manifest.product.bundleIdentifier == "com.arktrace.ArkTrace.CLI",
      manifest.product.jsonContract.major == 1,
      manifest.product.jsonContract.minor == 0,
      manifest.layout.bundle == "ArkTraceCLI.app",
      manifest.layout.executable == "ArkTraceCLI.app/Contents/MacOS/arktrace",
      manifest.layout.parserExecutable == "ArkTraceCLI.app/Contents/Helpers/trace_streamer",
      manifest.layout.parserManifest
        == "ArkTraceCLI.app/Contents/Resources/TraceStreamer/manifest.json",
      manifest.layout.parserSigningRecord
        == "ArkTraceCLI.app/Contents/Resources/TraceStreamer/distribution-signing.json",
      manifest.signing.policy == "developer-id-runtime-timestamp",
      Self.isSHA1(manifest.signing.certificateSHA1),
      manifest.notarization.status == "Accepted",
      manifest.notarization.stapledTicketValidated,
      manifest.notarization.gatekeeperAssessment == "accepted",
      manifest.upgradePolicy.identity == "distribution-manifest+tool-parser-hashes",
      manifest.upgradePolicy.installMode == "versioned-directory",
      manifest.upgradePolicy.pathSelection == "reviewed-absolute-descriptor-only",
      manifest.upgradePolicy.rollback == "retain-prior-exact-directory",
      Self.isSHA256(manifest.source.treeSHA256),
      Self.isSHA256(manifest.tool.binarySHA256),
      Self.isSHA256(manifest.traceStreamer.binarySHA256),
      Self.isSHA256(manifest.traceStreamer.manifestSHA256),
      Self.isSHA256(manifest.traceStreamer.signingRecordSHA256),
      Self.isSHA256(manifest.notarization.receiptSHA256),
      manifest.tool.byteCount > 0,
      manifest.traceStreamer.byteCount > 0,
      manifest.traceStreamer.manifestByteCount > 0,
      manifest.traceStreamer.signingRecordByteCount > 0
    else { throw ArkTraceSummaryProfileError.contractMismatch }
  }

  private static func validateManifestKeyClosure(_ data: Data) throws {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(root.keys) == [
        "formatVersion", "source", "product", "layout", "tool", "traceStreamer", "signing",
        "notarization", "integrity", "attribution", "upgradePolicy",
      ],
      Self.keys(root["source"]) == ["revision", "treeSHA256"],
      Self.keys(root["product"]) == [
        "name", "version", "build", "architecture", "bundleIdentifier", "jsonContract",
      ],
      Self.keys((root["product"] as? [String: Any])?["jsonContract"]) == ["major", "minor"],
      Self.keys(root["layout"]) == [
        "bundle", "executable", "parserExecutable", "parserManifest", "parserSigningRecord",
        "resourceBundle",
      ],
      Self.keys(root["tool"]) == ["binarySHA256", "byteCount", "codeDirectoryHash"],
      Self.keys(root["traceStreamer"]) == [
        "unsignedBinarySHA256", "binarySHA256", "byteCount", "codeDirectoryHash",
        "manifestSHA256", "manifestByteCount", "signingRecordSHA256",
        "signingRecordByteCount", "reportedVersion", "upstreamRevision", "buildRecipeVersion",
      ],
      Self.keys(root["signing"]) == [
        "teamIdentifier", "identity", "certificateSHA1", "policy",
      ],
      Self.keys(root["notarization"]) == [
        "status", "submissionID", "receipt", "receiptSHA256", "stapledTicketValidated",
        "gatekeeperAssessment",
      ],
      Self.keys(root["integrity"]) == [
        "appTreeSHA256", "resourceTreeSHA256", "appCodeDirectoryHash",
      ],
      Self.keys(root["attribution"]) == [
        "license", "licenseSHA256", "licenseByteCount", "notice", "noticeSHA256",
        "noticeByteCount", "inventory", "inventorySHA256", "inventoryByteCount",
        "licenseFileCount", "selfTestFixture", "selfTestFixtureSHA256",
        "selfTestFixtureByteCount",
      ],
      Self.keys(root["upgradePolicy"]) == [
        "identity", "installMode", "pathSelection", "rollback",
      ]
    else { throw ArkTraceSummaryProfileError.contractMismatch }
  }

  private static func keys(_ value: Any?) -> Set<String>? {
    (value as? [String: Any]).map { Set($0.keys) }
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
  }

  private static func isSHA1(_ value: String) -> Bool {
    value.count == 40 && value.allSatisfy({ $0.isHexDigit && !$0.isLowercase })
  }
}

package enum ArkTraceProfileFileReader {
  package enum ReaderError: Error, Equatable {
    case physicalPath
    case open
    case initialMetadata
    case shortRead
    case growth
    case finalIdentity
  }

  package struct Snapshot {
    package let data: Data
    package let mode: mode_t
  }

  package static func matches(
    path: String,
    sha256: String,
    byteCount: Int?,
    maximumByteCount: Int,
    requireExecutable: Bool = false
  ) -> Bool {
    do {
      let snapshot = try read(path: path, maximumByteCount: maximumByteCount)
      return (byteCount == nil || snapshot.data.count == byteCount)
        && AnalyzerProvider.sha256(snapshot.data) == sha256
        && (!requireExecutable || snapshot.mode & 0o111 != 0)
    } catch {
      return false
    }
  }

  package static func read(path: String, maximumByteCount: Int) throws -> Snapshot {
    guard maximumByteCount > 0 else { throw ReaderError.physicalPath }
    let descriptor = try openPhysicalAbsolutePath(
      path, flags: O_RDONLY | O_NONBLOCK)
    defer { Darwin.close(descriptor) }
    var initial = stat()
    guard fstat(descriptor, &initial) == 0,
      initial.st_mode & S_IFMT == S_IFREG,
      initial.st_size >= 0,
      initial.st_size <= maximumByteCount
    else { throw ReaderError.initialMetadata }

    let expected = Int(initial.st_size)
    var bytes = Data()
    bytes.reserveCapacity(expected)
    var buffer = [UInt8](repeating: 0, count: min(64 * 1024, max(1, expected)))
    while bytes.count < expected {
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, min($0.count, expected - bytes.count))
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw ReaderError.shortRead }
      bytes.append(buffer, count: count)
    }
    var extra: UInt8 = 0
    let extraCount = Darwin.read(descriptor, &extra, 1)
    guard extraCount == 0 else { throw ReaderError.growth }
    var final = stat()
    guard fstat(descriptor, &final) == 0,
      initial.st_dev == final.st_dev, initial.st_ino == final.st_ino,
      initial.st_size == final.st_size,
      initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
      initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec
    else { throw ReaderError.finalIdentity }
    let current = try openPhysicalAbsolutePath(path, flags: O_RDONLY | O_NONBLOCK)
    defer { Darwin.close(current) }
    var linked = stat()
    guard fstat(current, &linked) == 0,
      initial.st_dev == linked.st_dev, initial.st_ino == linked.st_ino,
      linked.st_mode & S_IFMT == S_IFREG
    else { throw ReaderError.finalIdentity }
    return Snapshot(data: bytes, mode: initial.st_mode)
  }

  package static func isPhysicalDirectory(_ path: String) throws -> Bool {
    let descriptor: Int32
    do {
      descriptor = try openPhysicalAbsolutePath(
        path, flags: O_RDONLY | O_DIRECTORY | O_NONBLOCK)
    } catch {
      return false
    }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    return fstat(descriptor, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFDIR
  }

  package static func hasNoSymlinkComponent(_ path: String) throws -> Bool {
    let descriptor: Int32
    do {
      descriptor = try openPhysicalAbsolutePath(path, flags: O_RDONLY | O_NONBLOCK)
    } catch {
      return false
    }
    Darwin.close(descriptor)
    return true
  }

  package static func openPhysicalDirectoryDescriptor(_ path: String) throws -> Int32 {
    try openPhysicalAbsolutePath(
      path, flags: O_RDONLY | O_DIRECTORY | O_NONBLOCK)
  }

  /// Opens (and, below an already owner-only ancestor, creates) a private
  /// directory without ever mutating a pathname before it is descriptor
  /// bound. Existing symlink leaves/ancestors fail at `openat(O_NOFOLLOW)`;
  /// only the final retained fd is chmodded.
  package static func openOrCreateOwnerPrivateDirectory(_ path: String) throws -> Int32 {
    guard path.hasPrefix("/") else { throw ReaderError.physicalPath }
    let physicalPath: String
    if path == "/var" || path.hasPrefix("/var/") {
      physicalPath = "/private" + path
    } else if path == "/tmp" || path.hasPrefix("/tmp/") {
      physicalPath = "/private" + path
    } else if path == "/etc" || path.hasPrefix("/etc/") {
      physicalPath = "/private" + path
    } else {
      physicalPath = path
    }
    let components = physicalPath.split(
      separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw ReaderError.physicalPath }

    var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard directory >= 0 else { throw ReaderError.open }
    do {
      for (index, component) in components.enumerated() {
        let isLeaf = index == components.count - 1
        var next = component.withCString {
          Darwin.openat(
            directory, $0,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        if next < 0, errno == ENOENT {
          let creationStatus = component.withCString { mkdirat(directory, $0, 0o700) }
          guard creationStatus == 0 || errno == EEXIST else { throw ReaderError.open }
          next = component.withCString {
            Darwin.openat(
              directory, $0,
              O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
          }
        }
        guard next >= 0 else { throw ReaderError.open }
        var metadata = stat()
        guard fstat(next, &metadata) == 0,
          metadata.st_mode & S_IFMT == S_IFDIR,
          metadata.st_uid == geteuid() || metadata.st_uid == 0
        else {
          Darwin.close(next)
          throw ReaderError.physicalPath
        }
        let rootStickyDirectory = metadata.st_uid == 0
          && metadata.st_mode & mode_t(S_ISVTX) != 0
        guard metadata.st_mode & 0o022 == 0 || rootStickyDirectory else {
          Darwin.close(next)
          throw ReaderError.physicalPath
        }
        if isLeaf {
          guard metadata.st_uid == geteuid(), fchmod(next, 0o700) == 0,
            fstat(next, &metadata) == 0,
            metadata.st_uid == geteuid(), metadata.st_mode & 0o777 == 0o700
          else {
            Darwin.close(next)
            throw ReaderError.physicalPath
          }
        }
        Darwin.close(directory)
        directory = next
      }
      let retained = directory
      directory = -1
      return retained
    } catch {
      if directory >= 0 { Darwin.close(directory) }
      throw error
    }
  }

  /// Verifies the descriptor/install authority one namespace component at a
  /// time. User-owned components must be non-group/world-writable. Root-owned
  /// components follow the same rule, except for sticky system temporary
  /// directories (for example `/private/tmp`), where the kernel prevents one
  /// user from replacing another user's owned child.
  package static func validateOwnerOnlyAuthority(
    path: String,
    leafIsDirectory: Bool
  ) throws {
    guard path.hasPrefix("/") else { throw ReaderError.physicalPath }
    let physicalPath: String
    if path == "/var" || path.hasPrefix("/var/") {
      physicalPath = "/private" + path
    } else if path == "/tmp" || path.hasPrefix("/tmp/") {
      physicalPath = "/private" + path
    } else if path == "/etc" || path.hasPrefix("/etc/") {
      physicalPath = "/private" + path
    } else {
      physicalPath = path
    }
    let components = physicalPath.split(
      separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw ReaderError.physicalPath }

    var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard directory >= 0 else { throw ReaderError.open }
    defer { if directory >= 0 { Darwin.close(directory) } }
    for (index, component) in components.enumerated() {
      let isLeaf = index == components.count - 1
      let flags =
        isLeaf && !leafIsDirectory
        ? O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        : O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      let next = component.withCString { Darwin.openat(directory, $0, flags) }
      guard next >= 0 else { throw ReaderError.open }
      var metadata = stat()
      guard fstat(next, &metadata) == 0 else {
        Darwin.close(next)
        throw ReaderError.initialMetadata
      }
      let expectedType: mode_t = isLeaf && !leafIsDirectory ? S_IFREG : S_IFDIR
      let ownerIsAuthority = metadata.st_uid == geteuid() || metadata.st_uid == 0
      let writableByOthers = metadata.st_mode & 0o022 != 0
      let rootStickyDirectory = metadata.st_uid == 0
        && metadata.st_mode & S_IFMT == S_IFDIR
        && metadata.st_mode & mode_t(S_ISVTX) != 0
      guard metadata.st_mode & S_IFMT == expectedType,
        ownerIsAuthority,
        !writableByOthers || rootStickyDirectory
      else {
        Darwin.close(next)
        throw ReaderError.physicalPath
      }
      Darwin.close(directory)
      directory = next
    }
  }

  private static func openPhysicalAbsolutePath(
    _ path: String,
    flags: Int32
  ) throws -> Int32 {
    guard path.hasPrefix("/") else {
      throw ReaderError.physicalPath
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw ReaderError.physicalPath }

    var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard directory >= 0 else { throw ReaderError.open }
    do {
      for component in components.dropLast() {
        let next = component.withCString {
          Darwin.openat(
            directory, $0,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard next >= 0 else { throw ReaderError.open }
        Darwin.close(directory)
        directory = next
      }
      let descriptor = components.last!.withCString {
        Darwin.openat(directory, $0, flags | O_CLOEXEC | O_NOFOLLOW)
      }
      guard descriptor >= 0 else { throw ReaderError.open }
      Darwin.close(directory)
      directory = -1
      return descriptor
    } catch {
      if directory >= 0 { Darwin.close(directory) }
      throw error
    }
  }
}

package enum ArkTraceDistributionTreeHasher {
  private static let maximumFileBytes = 128 * 1024 * 1024
  private static let maximumTreeBytes = 256 * 1024 * 1024
  private static let maximumFiles = 256
  private static let maximumEntries = 512
  private static let maximumDepth = 32
  private static let maximumRelativePathBytes = 1_024

  private struct FileRecord {
    let path: Data
    let digest: String
    let byteCount: Int
    let mode: mode_t
  }

  package struct TreeSnapshot {
    package let sha256: String
    package let pinnedFiles: [AnalyzerPinnedFile]
  }

  private struct DescriptorState: Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let owner: uid_t
    let size: off_t
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
  }

  package static func matches(rootPath: String, expectedSHA256: String) -> Bool {
    guard expectedSHA256.count == 64,
      expectedSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
    else { return false }
    return (try? digest(rootPath: rootPath)) == expectedSHA256
  }

  package static func digest(rootPath: String) throws -> String {
    try snapshot(rootPath: rootPath).sha256
  }

  /// Copies one already bounded physical tree through retained directory
  /// descriptors. The destination must not exist and must live below a
  /// daemon-private directory. Every source component is opened with
  /// `openat(O_NOFOLLOW)`, every file is read to its initial exact size, and
  /// the source directory generation is rechecked after its children have
  /// been copied. Thus an installed App cannot be swapped between trust
  /// validation and the private runtime generation.
  package static func copySnapshot(
    rootPath: String,
    destinationParent: Int32,
    destinationName: String,
    destinationDisplayPath: String
  ) throws -> TreeSnapshot {
    guard destinationParent >= 0, !destinationName.isEmpty,
      !destinationName.contains("/"), destinationName != ".", destinationName != "..",
      destinationDisplayPath.hasPrefix("/")
    else {
      throw ArkTraceSummaryProfileError.contractMismatch
    }
    let source = try ArkTraceProfileFileReader.openPhysicalDirectoryDescriptor(rootPath)
    defer { Darwin.close(source) }
    guard destinationName.withCString({ mkdirat(destinationParent, $0, 0o700) }) == 0 else {
      throw ArkTraceSummaryProfileError.contractMismatch
    }
    var destination = destinationName.withCString {
      Darwin.openat(
        destinationParent, $0,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    }
    guard destination >= 0 else {
      throw ArkTraceSummaryProfileError.contractMismatch
    }
    do {
      var totalBytes = 0
      var entryCount = 1
      try copyWalk(
        sourceDirectory: source, destinationDirectory: destination,
        depth: 0, totalBytes: &totalBytes, entryCount: &entryCount)
      guard fsync(destination) == 0 else {
        throw ArkTraceSummaryProfileError.contractMismatch
      }
      let sourceSnapshot = try snapshot(rootPath: rootPath)
      let copiedSnapshot = try snapshot(
        directoryDescriptor: destination, rootPath: destinationDisplayPath)
      guard copiedSnapshot.sha256 == sourceSnapshot.sha256 else {
        throw ArkTraceSummaryProfileError.contractMismatch
      }
      Darwin.close(destination)
      destination = -1
      return copiedSnapshot
    } catch {
      if destination >= 0 { Darwin.close(destination) }
      throw error
    }
  }

  package static func matches(
    directoryDescriptor: Int32,
    rootPath: String,
    expectedSHA256: String
  ) -> Bool {
    guard expectedSHA256.count == 64,
      expectedSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
    else { return false }
    return (try? snapshot(
      directoryDescriptor: directoryDescriptor, rootPath: rootPath).sha256)
      == expectedSHA256
  }

  /// Removes only a relative tree below the retained daemon-private root.
  /// No absolute pathname is resolved, so a public snapshot-root replacement
  /// cannot redirect cleanup into a foreign directory.
  package static func removeSnapshot(
    parentDescriptor: Int32,
    name: String
  ) throws {
    guard parentDescriptor >= 0, !name.isEmpty, !name.contains("/"),
      name != ".", name != ".."
    else { throw ArkTraceSummaryProfileError.contractMismatch }
    let directory = name.withCString {
      Darwin.openat(
        parentDescriptor, $0,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    }
    if directory < 0, errno == ENOENT { return }
    guard directory >= 0 else { throw ArkTraceSummaryProfileError.contractMismatch }
    do {
      try removeContents(directory)
      guard name.withCString({ unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }) == 0 else {
        throw ArkTraceSummaryProfileError.contractMismatch
      }
      Darwin.close(directory)
    } catch {
      Darwin.close(directory)
      throw error
    }
  }

  private static func removeContents(_ directory: Int32) throws {
    let entries = try directoryEntries(directory)
    for entry in entries {
      var metadata = stat()
      guard entry.name.withCString({
        fstatat(directory, $0, &metadata, AT_SYMLINK_NOFOLLOW)
      }) == 0 else { throw ArkTraceSummaryProfileError.contractMismatch }
      switch metadata.st_mode & S_IFMT {
      case S_IFDIR:
        let child = entry.name.withCString {
          Darwin.openat(
            directory, $0,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard child >= 0 else { throw ArkTraceSummaryProfileError.contractMismatch }
        do {
          try removeContents(child)
          Darwin.close(child)
        } catch {
          Darwin.close(child)
          throw error
        }
        guard entry.name.withCString({ unlinkat(directory, $0, AT_REMOVEDIR) }) == 0 else {
          throw ArkTraceSummaryProfileError.contractMismatch
        }
      case S_IFREG:
        guard entry.name.withCString({ unlinkat(directory, $0, 0) }) == 0 else {
          throw ArkTraceSummaryProfileError.contractMismatch
        }
      default:
        throw ArkTraceSummaryProfileError.contractMismatch
      }
    }
  }

  package static func snapshot(rootPath: String) throws -> TreeSnapshot {
    let root = try ArkTraceProfileFileReader.openPhysicalDirectoryDescriptor(rootPath)
    defer { Darwin.close(root) }
    return try snapshot(directoryDescriptor: root, rootPath: rootPath)
  }

  package static func snapshot(
    directoryDescriptor root: Int32,
    rootPath: String
  ) throws -> TreeSnapshot {
    var records: [FileRecord] = []
    var totalBytes = 0
    var entryCount = 1
    try walk(
      directory: root, prefix: Data(), depth: 0, records: &records,
      totalBytes: &totalBytes, entryCount: &entryCount)
    records.sort { $0.path.lexicographicallyPrecedes($1.path) }
    var hasher = SHA256()
    for record in records {
      hasher.update(data: Data("F\0".utf8))
      hasher.update(data: Data(String(record.mode, radix: 8).utf8))
      hasher.update(data: Data([0]))
      hasher.update(data: record.path)
      hasher.update(data: Data([0]))
      hasher.update(data: Data(String(record.byteCount).utf8))
      hasher.update(data: Data([0]))
      hasher.update(data: Data(record.digest.utf8))
      hasher.update(data: Data([0]))
    }
    let digest = hasher.finalize().map({ String(format: "%02x", $0) }).joined()
    let pins = records.map {
      AnalyzerPinnedFile(
        path: rootPath + "/" + String(decoding: $0.path, as: UTF8.self),
        sha256: $0.digest, byteCount: $0.byteCount,
        requireExecutable: $0.mode & 0o111 != 0)
    }
    return TreeSnapshot(sha256: digest, pinnedFiles: pins)
  }

  private static func walk(
    directory: Int32,
    prefix: Data,
    depth: Int,
    records: inout [FileRecord],
    totalBytes: inout Int,
    entryCount: inout Int
  ) throws {
    guard depth <= maximumDepth else { throw ArkTraceSummaryProfileError.contractMismatch }
    let initial = try descriptorState(directory)
    try validateAuthority(initial, expectedType: S_IFDIR)
    let entries = try directoryEntries(directory)
    guard entryCount + entries.count <= maximumEntries else {
      throw ArkTraceSummaryProfileError.contractMismatch
    }
    entryCount += entries.count
    for entry in entries {
      let relative = prefix.isEmpty
        ? entry.bytes
        : prefix + Data([UInt8(ascii: "/")]) + entry.bytes
      guard relative.count <= maximumRelativePathBytes else {
        throw ArkTraceSummaryProfileError.contractMismatch
      }
      var metadata = stat()
      let status = entry.name.withCString {
        fstatat(directory, $0, &metadata, AT_SYMLINK_NOFOLLOW)
      }
      guard status == 0 else { throw ArkTraceSummaryProfileError.contractMismatch }
      let entryState = descriptorState(metadata)
      switch metadata.st_mode & S_IFMT {
      case S_IFDIR:
        try validateAuthority(entryState, expectedType: S_IFDIR)
        let child = entry.name.withCString {
          Darwin.openat(
            directory, $0,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard child >= 0 else { throw ArkTraceSummaryProfileError.contractMismatch }
        defer { Darwin.close(child) }
        try walk(
          directory: child, prefix: relative, depth: depth + 1, records: &records,
          totalBytes: &totalBytes, entryCount: &entryCount)
      case S_IFREG:
        try validateAuthority(entryState, expectedType: S_IFREG)
        let descriptor = entry.name.withCString {
          Darwin.openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw ArkTraceSummaryProfileError.contractMismatch }
        defer { Darwin.close(descriptor) }
        let snapshot = try readFile(descriptor)
        records.append(
          FileRecord(
            path: relative, digest: AnalyzerProvider.sha256(snapshot.data),
            byteCount: snapshot.data.count, mode: snapshot.mode & 0o7777))
        totalBytes += snapshot.data.count
        guard records.count <= maximumFiles, totalBytes <= maximumTreeBytes else {
          throw ArkTraceSummaryProfileError.contractMismatch
        }
      default:
        throw ArkTraceSummaryProfileError.contractMismatch
      }
    }
    guard try descriptorState(directory) == initial,
      try directoryEntries(directory).map(\.bytes) == entries.map(\.bytes)
    else { throw ArkTraceSummaryProfileError.contractMismatch }
  }

  private static func copyWalk(
    sourceDirectory: Int32,
    destinationDirectory: Int32,
    depth: Int,
    totalBytes: inout Int,
    entryCount: inout Int
  ) throws {
    guard depth <= maximumDepth else { throw ArkTraceSummaryProfileError.contractMismatch }
    let initial = try descriptorState(sourceDirectory)
    try validateAuthority(initial, expectedType: S_IFDIR)
    let entries = try directoryEntries(sourceDirectory)
    guard entryCount + entries.count <= maximumEntries else {
      throw ArkTraceSummaryProfileError.contractMismatch
    }
    entryCount += entries.count
    for entry in entries {
      var metadata = stat()
      guard entry.name.withCString({
        fstatat(sourceDirectory, $0, &metadata, AT_SYMLINK_NOFOLLOW)
      }) == 0 else { throw ArkTraceSummaryProfileError.contractMismatch }
      let entryState = descriptorState(metadata)
      switch metadata.st_mode & S_IFMT {
      case S_IFDIR:
        try validateAuthority(entryState, expectedType: S_IFDIR)
        guard entry.name.withCString({ mkdirat(destinationDirectory, $0, 0o700) }) == 0
        else { throw ArkTraceSummaryProfileError.contractMismatch }
        let sourceChild = entry.name.withCString {
          Darwin.openat(
            sourceDirectory, $0,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        let destinationChild = entry.name.withCString {
          Darwin.openat(
            destinationDirectory, $0,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard sourceChild >= 0, destinationChild >= 0 else {
          if sourceChild >= 0 { Darwin.close(sourceChild) }
          if destinationChild >= 0 { Darwin.close(destinationChild) }
          throw ArkTraceSummaryProfileError.contractMismatch
        }
        defer {
          Darwin.close(sourceChild)
          Darwin.close(destinationChild)
        }
        try copyWalk(
          sourceDirectory: sourceChild, destinationDirectory: destinationChild,
          depth: depth + 1, totalBytes: &totalBytes, entryCount: &entryCount)
        guard fsync(destinationChild) == 0 else {
          throw ArkTraceSummaryProfileError.contractMismatch
        }
      case S_IFREG:
        try validateAuthority(entryState, expectedType: S_IFREG)
        let sourceFile = entry.name.withCString {
          Darwin.openat(
            sourceDirectory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard sourceFile >= 0 else { throw ArkTraceSummaryProfileError.contractMismatch }
        defer { Darwin.close(sourceFile) }
        let snapshot = try readFile(sourceFile)
        totalBytes += snapshot.data.count
        guard totalBytes <= maximumTreeBytes else {
          throw ArkTraceSummaryProfileError.contractMismatch
        }
        let destinationFile = entry.name.withCString {
          Darwin.openat(
            destinationDirectory, $0,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600))
        }
        guard destinationFile >= 0 else {
          throw ArkTraceSummaryProfileError.contractMismatch
        }
        do {
          var offset = 0
          while offset < snapshot.data.count {
            let written = snapshot.data.withUnsafeBytes { bytes in
              Darwin.write(
                destinationFile, bytes.baseAddress!.advanced(by: offset),
                snapshot.data.count - offset)
            }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { throw ArkTraceSummaryProfileError.contractMismatch }
            offset += written
          }
          guard fchmod(destinationFile, snapshot.mode & 0o7777) == 0,
            fsync(destinationFile) == 0
          else { throw ArkTraceSummaryProfileError.contractMismatch }
          Darwin.close(destinationFile)
        } catch {
          Darwin.close(destinationFile)
          throw error
        }
      default:
        throw ArkTraceSummaryProfileError.contractMismatch
      }
    }
    guard try descriptorState(sourceDirectory) == initial,
      try directoryEntries(sourceDirectory).map(\.bytes) == entries.map(\.bytes)
    else { throw ArkTraceSummaryProfileError.contractMismatch }
  }

  private static func directoryEntries(
    _ descriptor: Int32
  ) throws -> [(bytes: Data, name: String)] {
    // `dup` shares the directory stream offset, so a second enumeration
    // would start at EOF and make the stability check fail. Reopen `.` below
    // the already verified descriptor to obtain an independent description.
    let duplicate = Darwin.openat(
      descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard duplicate >= 0 else {
      throw ArkTraceSummaryProfileError.contractMismatch
    }
    guard let stream = fdopendir(duplicate) else {
      Darwin.close(duplicate)
      throw ArkTraceSummaryProfileError.contractMismatch
    }
    defer { closedir(stream) }
    var result: [(Data, String)] = []
    while let entry = readdir(stream) {
      let name: String? = withUnsafePointer(to: entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(validatingCString: $0)
        }
      }
      guard let name else { throw ArkTraceSummaryProfileError.contractMismatch }
      if name == "." || name == ".." { continue }
      let bytes = Data(name.utf8)
      guard !bytes.isEmpty, bytes.count <= Int(MAXNAMLEN), result.count < maximumEntries else {
        throw ArkTraceSummaryProfileError.contractMismatch
      }
      result.append((bytes, name))
    }
    result.sort { $0.0.lexicographicallyPrecedes($1.0) }
    guard Set(result.map(\.0)).count == result.count else {
      throw ArkTraceSummaryProfileError.contractMismatch
    }
    return result
  }

  private static func readFile(_ descriptor: Int32) throws -> (data: Data, mode: mode_t) {
    let initial = try descriptorState(descriptor)
    guard initial.mode & S_IFMT == S_IFREG, initial.size > 0,
      initial.size <= maximumFileBytes
    else { throw ArkTraceSummaryProfileError.contractMismatch }
    let expected = Int(initial.size)
    var data = Data()
    data.reserveCapacity(expected)
    var offset: off_t = 0
    var buffer = [UInt8](repeating: 0, count: min(1024 * 1024, expected))
    while data.count < expected {
      let count = buffer.withUnsafeMutableBytes {
        pread(descriptor, $0.baseAddress, min($0.count, expected - data.count), offset)
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw ArkTraceSummaryProfileError.contractMismatch }
      data.append(buffer, count: count)
      offset += off_t(count)
    }
    var extra: UInt8 = 0
    guard pread(descriptor, &extra, 1, offset) == 0,
      try descriptorState(descriptor) == initial
    else { throw ArkTraceSummaryProfileError.contractMismatch }
    return (data, initial.mode)
  }

  private static func descriptorState(_ descriptor: Int32) throws -> DescriptorState {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      throw ArkTraceSummaryProfileError.contractMismatch
    }
    return descriptorState(metadata)
  }

  private static func descriptorState(_ metadata: stat) -> DescriptorState {
    DescriptorState(
      device: metadata.st_dev, inode: metadata.st_ino, mode: metadata.st_mode,
      owner: metadata.st_uid,
      size: metadata.st_size,
      modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
      modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
      changeSeconds: Int64(metadata.st_ctimespec.tv_sec),
      changeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec))
  }

  private static func validateAuthority(
    _ state: DescriptorState,
    expectedType: mode_t
  ) throws {
    guard state.mode & S_IFMT == expectedType,
      (state.owner == geteuid() || state.owner == 0),
      state.mode & 0o022 == 0
    else { throw ArkTraceSummaryProfileError.contractMismatch }
  }
}

private struct DistributionManifest: Decodable {
  let formatVersion: Int
  let source: Source
  let product: Product
  let layout: Layout
  let tool: Tool
  let traceStreamer: TraceStreamer
  let signing: Signing
  let notarization: Notarization
  let integrity: Integrity
  let attribution: Attribution
  let upgradePolicy: UpgradePolicy

  struct Source: Decodable { let revision: String; let treeSHA256: String }
  struct Product: Decodable {
    let name: String; let version: String; let build: String; let architecture: String
    let bundleIdentifier: String; let jsonContract: JSONContract
  }
  struct JSONContract: Decodable { let major: Int; let minor: Int }
  struct Layout: Decodable {
    let bundle: String; let executable: String; let parserExecutable: String
    let parserManifest: String; let parserSigningRecord: String; let resourceBundle: String
  }
  struct Tool: Decodable { let binarySHA256: String; let byteCount: Int; let codeDirectoryHash: String }
  struct TraceStreamer: Decodable {
    let unsignedBinarySHA256: String; let binarySHA256: String; let byteCount: Int
    let codeDirectoryHash: String; let manifestSHA256: String; let manifestByteCount: Int
    let signingRecordSHA256: String; let signingRecordByteCount: Int; let reportedVersion: String
    let upstreamRevision: String; let buildRecipeVersion: String
  }
  struct Signing: Decodable {
    let teamIdentifier: String; let identity: String; let certificateSHA1: String; let policy: String
  }
  struct Notarization: Decodable {
    let status: String; let submissionID: String; let receipt: String; let receiptSHA256: String
    let stapledTicketValidated: Bool; let gatekeeperAssessment: String
  }
  struct Integrity: Decodable {
    let appTreeSHA256: String; let resourceTreeSHA256: String; let appCodeDirectoryHash: String
  }
  struct Attribution: Decodable {
    let license: String; let licenseSHA256: String; let licenseByteCount: Int
    let notice: String; let noticeSHA256: String; let noticeByteCount: Int
    let inventory: String; let inventorySHA256: String; let inventoryByteCount: Int
    let licenseFileCount: Int; let selfTestFixture: String; let selfTestFixtureSHA256: String
    let selfTestFixtureByteCount: Int
  }
  struct UpgradePolicy: Decodable {
    let identity: String; let installMode: String; let pathSelection: String; let rollback: String
  }
}

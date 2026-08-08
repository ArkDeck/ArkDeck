// Task-owned candidate build/sandbox and admission pipeline
// (CHG-2026-025 r8, TASK-AIN-019).

import ArkDeckCore
import ArkDeckProcess
import CryptoKit
import Darwin
import Foundation

public struct RockchipEvolutionCandidateBuild: Sendable, Equatable {
  public let pin: RockchipEvolutionCandidatePin

  public init(pin: RockchipEvolutionCandidatePin) {
    self.pin = pin
  }
}

public protocol RockchipEvolutionCandidateBuilding: Sendable {
  func build(
    assertion: RockchipEvolutionCampaignConfirmationAssertion,
    strategy: RockchipEvolutionTypedStrategy
  ) async throws -> RockchipEvolutionCandidateBuild
}

/// Identity-bound fixed-command builder.  The caller cannot supply a source
/// path, executable, argv, build target, scratch path or sandbox profile.
public final class ProductRockchipEvolutionCandidateBuilder: @unchecked Sendable,
  RockchipEvolutionCandidateBuilding
{
  public static let producerID = "task-owned-evolution-candidate-builder@1"
  public static let maximumCandidateDiffBytes = 512 * 1_024

  private let sourceRoot: URL
  private let stateRoot: URL
  private let executor: FoundationProcessExecutor
  private let gitURL = URL(fileURLWithPath: "/usr/bin/git")
  private let sandboxURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")

  public convenience init(stateRoot: URL) throws {
    try self.init(sourceRoot: Self.configuredSourceRoot(), stateRoot: stateRoot)
  }

  /// The candidate workspace used to be whatever directory the caller happened
  /// to be launched from, so a campaign started from anywhere but the checkout
  /// top level died inside `git` with nothing naming the expected location.
  /// `ARKDECK_EVOLUTION_SOURCE_ROOT` states it instead. The top-level check in
  /// `build()` is unchanged and still applies: this decides where the root is
  /// read from, not what counts as a valid root.
  static func configuredSourceRoot(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let configured = environment["ARKDECK_EVOLUTION_SOURCE_ROOT"],
      configured.hasPrefix("/")
    {
      return URL(fileURLWithPath: configured, isDirectory: true)
    }
    return URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  }

  package init(
    sourceRoot: URL,
    stateRoot: URL,
    executor: FoundationProcessExecutor = FoundationProcessExecutor()
  ) throws {
    guard sourceRoot.isFileURL, sourceRoot.path.hasPrefix("/"),
      stateRoot.isFileURL, stateRoot.path.hasPrefix("/")
    else { throw RockchipEvolutionCampaignError.candidateRejected("workspaceRoot") }
    self.sourceRoot = sourceRoot.standardizedFileURL
    self.stateRoot = stateRoot.standardizedFileURL
    self.executor = executor
    try FileManager.default.createDirectory(
      at: self.stateRoot, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }

  public func build(
    assertion: RockchipEvolutionCampaignConfirmationAssertion,
    strategy proposedStrategy: RockchipEvolutionTypedStrategy
  ) async throws -> RockchipEvolutionCandidateBuild {
    guard assertion.isValid(at: Self.timestamp()) else {
      throw RockchipEvolutionCampaignError.expired
    }
    let gitSHA = try Self.executableSHA256(gitURL)
    let sandboxSHA = try Self.executableSHA256(sandboxURL)
    let swiftBuild = try await Self.swiftBuildPreset(
      executor: executor, sourceRoot: sourceRoot)
    let topLevel = try await runText(
      executable: gitURL, sha256: gitSHA,
      arguments: ["rev-parse", "--show-toplevel"], timeout: 15)
    guard URL(fileURLWithPath: topLevel, isDirectory: true).standardizedFileURL == sourceRoot else {
      // The candidate diff below uses `-- .`, so a source root below the top
      // level would silently scope the diff to a subtree and miss changes the
      // budget is supposed to bound. The requirement stays; only the operator's
      // ability to see which two paths disagreed is new.
      throw RockchipEvolutionCampaignError.candidateRejected(
        "taskOwnedWorkspace: source root \(sourceRoot.path) is not the "
          + "repository top level \(topLevel)")
    }
    do {
      _ = try await run(
        executable: gitURL, sha256: gitSHA,
        arguments: ["cat-file", "-e", "\(assertion.baseCommitOID)^{commit}"], timeout: 15)
      _ = try await run(
        executable: gitURL, sha256: gitSHA,
        arguments: ["merge-base", "--is-ancestor", assertion.baseCommitOID, "origin/main"],
        timeout: 15)
    } catch {
      throw RockchipEvolutionCampaignError.candidateRejected("protectedMainBase")
    }

    let tracked = try await run(
      executable: gitURL, sha256: gitSHA,
      arguments: [
        "diff", "--name-only", "--diff-filter=ACDMRTUXB", "-z",
        assertion.baseCommitOID, "--", ".",
      ], timeout: 30
    ).stdout.data
    let untracked = try await run(
      executable: gitURL, sha256: gitSHA,
      arguments: ["ls-files", "--others", "--exclude-standard", "-z"], timeout: 30
    )
    .stdout.data
    let changedFiles = Array(Set(Self.nulSeparated(tracked + untracked))).sorted()
    guard changedFiles.allSatisfy(Self.isCandidateSource),
      changedFiles.count <= assertion.maxChangedFiles
    else { throw RockchipEvolutionCampaignError.candidateRejected("scopeDrift") }

    let diff = try await run(
      executable: gitURL, sha256: gitSHA,
      arguments: ["diff", "--no-ext-diff", "--binary", assertion.baseCommitOID, "--", "."],
      timeout: 60, captureLimit: Self.maximumCandidateDiffBytes + 1
    ).stdout
    guard !diff.wasTruncated else {
      throw RockchipEvolutionCampaignError.candidateRejected("diffBytes")
    }
    var candidateDiff = diff.data
    let trackedFiles = Set(Self.nulSeparated(tracked))
    for path in changedFiles where !trackedFiles.contains(path) {
      let bytes = try safeSourceBytes(path)
      candidateDiff.append(Data("\n--- /dev/null\n+++ b/\(path)\n".utf8))
      candidateDiff.append(bytes)
      candidateDiff.append(Data("\n".utf8))
      guard candidateDiff.count <= Self.maximumCandidateDiffBytes else {
        throw RockchipEvolutionCampaignError.candidateRejected("diffBytes")
      }
    }
    let proposedStrategyData = try JSONEncoder.sorted.encode(proposedStrategy)
    candidateDiff.append(
      Data(
        "\n--- /dev/null\n+++ b/Packages/ArkDeckKit/Sources/ArkDeckHarness/Candidate/strategy-proposal.json\n+"
          .utf8))
    candidateDiff.append(proposedStrategyData)
    candidateDiff.append(Data("\n".utf8))
    guard candidateDiff.count <= Self.maximumCandidateDiffBytes else {
      throw RockchipEvolutionCampaignError.candidateRejected("diffBytes")
    }
    let changedLines = Self.changedLineCount(candidateDiff)
    guard changedLines <= assertion.maxDiffLines else {
      throw RockchipEvolutionCampaignError.candidateRejected("diffLineBudget")
    }

    let sourceTreeDigest = try sourceDigest(
      baseCommitOID: assertion.baseCommitOID, files: changedFiles)
    let diffDigest = RockchipEvolutionCampaignConfirmationAssertion.sha256(candidateDiff)
    let allowedPathDigest = RockchipEvolutionCampaignConfirmationAssertion.sha256(
      RockchipEvolutionCampaignConfirmationAssertion.canonicalData([
        "allowedPaths": .array(assertion.allowedPaths.map(JSONValue.string))
      ]))
    let candidateSeed = Data(
      [sourceTreeDigest, diffDigest, allowedPathDigest].joined(separator: "|").utf8)
    let candidateDigest = RockchipEvolutionCampaignConfirmationAssertion.sha256(candidateSeed)
    let candidateID = "ECAND-\(candidateDigest.prefix(24).uppercased())"

    let toolchainDigest = try await Self.toolchainDigest(
      executor: executor, sourceRoot: sourceRoot, swiftBuild: swiftBuild)
    guard toolchainDigest == assertion.candidateToolchainDigestSHA256 else {
      throw RockchipEvolutionCampaignError.candidateRejected("toolchainDrift")
    }

    let candidateRoot =
      stateRoot
      .appending(path: assertion.campaignID, directoryHint: .isDirectory)
      .appending(path: candidateID, directoryHint: .isDirectory)
    let scratch = candidateRoot.appending(path: "build", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: scratch, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let build = try await run(
      executable: URL(fileURLWithPath: swiftBuild.executable.path),
      sha256: swiftBuild.executable.sha256, argumentZero: swiftBuild.argumentZero,
      arguments: swiftBuild.fixedArguments + [
        "--scratch-path", scratch.path, "--product",
        RockchipEvolutionCampaignConfirmationAssertion.candidateBuildTarget,
      ], timeout: 900, captureLimit: 1 * 1_024 * 1_024)
    guard build.termination == .exited(0), !build.stdout.wasTruncated,
      !build.stderr.wasTruncated
    else { throw RockchipEvolutionCampaignError.candidateRejected("buildFailed") }
    let binPath = try await runText(
      executable: URL(fileURLWithPath: swiftBuild.executable.path),
      sha256: swiftBuild.executable.sha256, argumentZero: swiftBuild.argumentZero,
      arguments: swiftBuild.fixedArguments + [
        "--scratch-path", scratch.path, "--show-bin-path",
      ], timeout: 120)
    let candidateURL = URL(fileURLWithPath: binPath, isDirectory: true)
      .appending(path: RockchipEvolutionCampaignConfirmationAssertion.candidateBuildTarget)
      .standardizedFileURL
    let executableDigest = try Self.executableSHA256(candidateURL)

    let requestURL = candidateRoot.appending(path: "candidate-request.json")
    let request = RockchipEvolutionCampaignConfirmationAssertion.canonicalData([
      "archiveDigestSHA256": .string(assertion.archiveDigestSHA256),
      "deviceProfileReference": .string("dayu200"),
      "operationReference": .string(
        RockchipEvolutionCampaignConfirmationAssertion.operationReference),
      "stepSetDigestSHA256": .string(assertion.stepSetDigestSHA256),
      "strategy": try JSONDecoder().decode(JSONValue.self, from: proposedStrategyData),
      "userdataImpact": .string(RockchipEvolutionCampaignConfirmationAssertion.dataImpact),
    ])
    try Self.writeOwnerOnly(request, to: requestURL)
    let sandboxProfile = Self.sandboxProfile(
      candidateURL: candidateURL, requestURL: requestURL)
    let candidateExecution = try await run(
      executable: sandboxURL, sha256: sandboxSHA,
      arguments: [
        "-p", sandboxProfile, candidateURL.path, "--request", requestURL.path,
      ], timeout: 30, captureLimit: 128 * 1_024)
    guard candidateExecution.termination == .exited(0),
      !candidateExecution.stdout.wasTruncated, !candidateExecution.stderr.wasTruncated
    else { throw RockchipEvolutionCampaignError.candidateRejected("sandboxExecution") }
    let strategy: RockchipEvolutionTypedStrategy
    do {
      strategy = try JSONDecoder().decode(
        RockchipEvolutionTypedStrategy.self, from: candidateExecution.stdout.data)
    } catch {
      throw RockchipEvolutionCampaignError.candidateRejected("strategyOutput")
    }
    guard strategy.archiveDigestSHA256 == assertion.archiveDigestSHA256,
      strategy.stepSetDigestSHA256 == assertion.stepSetDigestSHA256,
      strategy == proposedStrategy,
      try Self.executableSHA256(candidateURL) == executableDigest,
      try sourceDigest(baseCommitOID: assertion.baseCommitOID, files: changedFiles)
        == sourceTreeDigest
    else { throw RockchipEvolutionCampaignError.candidateRejected("immutablePinDrift") }

    let diffArtifactID = "\(candidateID.lowercased())-diff.patch"
    let buildArtifactID = "\(candidateID.lowercased())-build.json"
    let testArtifactID = "\(candidateID.lowercased())-strategy.json"
    try Self.writeOwnerOnly(candidateDiff, to: candidateRoot.appending(path: diffArtifactID))
    try Self.writeOwnerOnly(
      RockchipEvolutionCampaignConfirmationAssertion.canonicalData([
        "executableDigestSHA256": .string(executableDigest),
        "sourceTreeDigestSHA256": .string(sourceTreeDigest),
        "status": .string("passed"),
        "toolchainDigestSHA256": .string(toolchainDigest),
      ]), to: candidateRoot.appending(path: buildArtifactID))
    let strategyData = try JSONEncoder.sorted.encode(strategy)
    try Self.writeOwnerOnly(strategyData, to: candidateRoot.appending(path: testArtifactID))

    let pin = try RockchipEvolutionCandidatePin(
      candidateID: candidateID, producerID: Self.producerID,
      baseCommitOID: assertion.baseCommitOID,
      sourceTreeDigestSHA256: sourceTreeDigest, diffDigestSHA256: diffDigest,
      allowedPathSetDigestSHA256: allowedPathDigest,
      executableDigestSHA256: executableDigest, toolchainDigestSHA256: toolchainDigest,
      changedFiles: changedFiles, changedLines: changedLines,
      diffArtifactID: diffArtifactID, buildEvidenceArtifactID: buildArtifactID,
      testEvidenceArtifactID: testArtifactID, strategy: strategy)
    return RockchipEvolutionCandidateBuild(pin: pin)
  }

  public static func currentToolchainDigest() async throws -> String {
    return try await currentToolchainDigest(
      sourceRoot: configuredSourceRoot().standardizedFileURL)
  }

  package static func currentToolchainDigest(sourceRoot: URL) async throws -> String {
    let root = sourceRoot.resolvingSymlinksInPath().standardizedFileURL
    let executor = FoundationProcessExecutor()
    let swiftBuild = try await swiftBuildPreset(executor: executor, sourceRoot: root)
    return try await toolchainDigest(
      executor: executor, sourceRoot: root, swiftBuild: swiftBuild)
  }

  public static func currentProtectedMainBaseCommitOID() async throws -> String {
    let root = configuredSourceRoot().standardizedFileURL
    let git = URL(fileURLWithPath: "/usr/bin/git")
    let result = try await FoundationProcessExecutor().executeIdentityBound(
      ProcessIdentityBoundRequest(
        process: ProcessRequest(
          executable: git, arguments: ["rev-parse", "origin/main^{commit}"],
          environment: ["NO_COLOR": "1"], workingDirectory: root, timeout: 30),
        expectedSHA256: executableSHA256(git)), captureLimit: 4 * 1_024)
    let value = String(decoding: result.execution.stdout.data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    // "git could not run here" and "origin/main is not a commit" both used to
    // surface as a bare `protectedMainBase`, which reads as a governance
    // rejection when the real cause is usually a source root that is not a
    // checkout at all.
    guard result.execution.termination == .exited(0) else {
      throw RockchipEvolutionCampaignError.candidateRejected(
        "protectedMainBase: git rev-parse in \(root.path) terminated "
          + "\(result.execution.termination)")
    }
    guard RockchipEvolutionCampaignConfirmationAssertion.isOID(value) else {
      throw RockchipEvolutionCampaignError.candidateRejected(
        "protectedMainBase: origin/main did not resolve to a commit OID")
    }
    return value
  }

  public static func currentBrokerExecutableDigest() throws -> String {
    guard let executable = CommandLine.arguments.first, !executable.isEmpty else {
      throw RockchipEvolutionCampaignError.candidateRejected("brokerExecutable")
    }
    let executableURL: URL
    if executable.hasPrefix("/") {
      executableURL = URL(fileURLWithPath: executable)
    } else {
      executableURL = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
      ).appending(path: executable)
    }
    return try executableSHA256(
      executableURL.resolvingSymlinksInPath().standardizedFileURL)
  }

  private static func toolchainDigest(
    executor: FoundationProcessExecutor,
    sourceRoot: URL,
    swiftBuild: WorkspaceCommandPreset
  ) async throws -> String {
    let result = try await executor.executeIdentityBound(
      ProcessIdentityBoundRequest(
        process: ProcessRequest(
          executable: URL(fileURLWithPath: swiftBuild.executable.path),
          argumentZero: swiftBuild.argumentZero, arguments: ["--version"],
          environment: ["NO_COLOR": "1"], workingDirectory: sourceRoot, timeout: 30),
        expectedSHA256: swiftBuild.executable.sha256), captureLimit: 64 * 1_024)
    guard result.execution.termination == .exited(0), !result.execution.stdout.wasTruncated else {
      throw RockchipEvolutionCampaignError.candidateRejected("toolchainUnavailable")
    }
    return RockchipEvolutionCampaignConfirmationAssertion.sha256(
      RockchipEvolutionCampaignConfirmationAssertion.canonicalData([
        "argumentZero": .string(swiftBuild.argumentZero ?? ""),
        "executablePath": .string(swiftBuild.executable.path),
        "executableSHA256": .string(swiftBuild.executable.sha256),
        "versionOutput": .string(
          String(decoding: result.execution.stdout.data, as: UTF8.self)),
      ]))
  }

  /// Resolve the system-selected Developer root with a fixed identity-bound
  /// command, then pin only the SwiftPM executable and role beneath that root.
  /// Apple's xcrun derives its dispatch role from the executable image path,
  /// so launching it through the identity-bound `/.vol` path makes it treat
  /// the inode as a tool name. `xcode-select` and `swift-package` both support
  /// the identity-bound launch contract; no caller can supply either path.
  private static func swiftBuildPreset(
    executor: FoundationProcessExecutor,
    sourceRoot: URL
  ) async throws -> WorkspaceCommandPreset {
    do {
      let xcodeSelect = URL(fileURLWithPath: "/usr/bin/xcode-select")
      let selected = try await executor.executeIdentityBound(
        ProcessIdentityBoundRequest(
          process: ProcessRequest(
            executable: xcodeSelect, arguments: ["-p"],
            environment: ["NO_COLOR": "1"], workingDirectory: sourceRoot, timeout: 30),
          expectedSHA256: executableSHA256(xcodeSelect)), captureLimit: 16 * 1_024)
      let selectedPath = String(decoding: selected.execution.stdout.data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard selected.execution.termination == .exited(0),
        !selected.execution.stdout.wasTruncated, selectedPath.hasPrefix("/"),
        !selectedPath.contains("\0")
      else {
        throw RockchipEvolutionCampaignError.candidateRejected("toolchainUnavailable")
      }
      let developerRoot = URL(fileURLWithPath: selectedPath, isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(
        atPath: developerRoot.path, isDirectory: &isDirectory), isDirectory.boolValue
      else {
        throw RockchipEvolutionCampaignError.candidateRejected("toolchainUnavailable")
      }
      let candidates = [
        developerRoot.appending(
          path: "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-package"),
        developerRoot.appending(path: "usr/bin/swift-package"),
      ]
      guard
        let executable = candidates.first(where: {
          FileManager.default.isExecutableFile(atPath: $0.path)
        })?.standardizedFileURL
      else {
        throw RockchipEvolutionCampaignError.candidateRejected("toolchainUnavailable")
      }
      let argumentZero = executable.deletingLastPathComponent().appending(path: "swift-build")
      guard FileManager.default.fileExists(atPath: argumentZero.path),
        argumentZero.resolvingSymlinksInPath().standardizedFileURL
          == executable.resolvingSymlinksInPath().standardizedFileURL
      else {
        throw RockchipEvolutionCampaignError.candidateRejected("toolchainUnavailable")
      }
      return try WorkspaceCommandPreset(
        presetID: "arkdeck-debug",
        executable: WorkspaceExecutableIdentity.hashing(path: executable.path),
        argumentZero: argumentZero.path,
        fixedArguments: [
          "--package-path",
          sourceRoot.appending(path: "Packages/ArkDeckKit", directoryHint: .isDirectory).path,
        ],
        timeoutSeconds: 900)
    } catch let error as RockchipEvolutionCampaignError {
      throw error
    } catch {
      throw RockchipEvolutionCampaignError.candidateRejected("toolchainUnavailable")
    }
  }

  private func run(
    executable: URL,
    sha256: String,
    argumentZero: String? = nil,
    arguments: [String],
    timeout: TimeInterval,
    captureLimit: Int = 256 * 1_024
  ) async throws -> ProcessExecutionResult {
    let result = try await executor.executeIdentityBound(
      ProcessIdentityBoundRequest(
        process: ProcessRequest(
          executable: executable, argumentZero: argumentZero, arguments: arguments,
          environment: ["NO_COLOR": "1"], workingDirectory: sourceRoot, timeout: timeout),
        expectedSHA256: sha256), captureLimit: captureLimit)
    guard result.execution.termination == .exited(0) else {
      // A bare `process:git` could not separate "not a repository" from a
      // timeout, a signal or a real git failure, so a campaign that refused
      // before touching the device left the operator nothing to act on.
      throw RockchipEvolutionCampaignError.candidateRejected(
        "process:\(executable.lastPathComponent) "
          + "\(arguments.first ?? "") terminated \(result.execution.termination)")
    }
    return result.execution
  }

  private func runText(
    executable: URL, sha256: String, argumentZero: String? = nil,
    arguments: [String], timeout: TimeInterval
  ) async throws -> String {
    let result = try await run(
      executable: executable, sha256: sha256, argumentZero: argumentZero,
      arguments: arguments, timeout: timeout)
    guard !result.stdout.wasTruncated else {
      throw RockchipEvolutionCampaignError.candidateRejected("processOutput")
    }
    let text = String(decoding: result.stdout.data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      throw RockchipEvolutionCampaignError.candidateRejected("processOutput")
    }
    return text
  }

  private func sourceDigest(baseCommitOID: String, files: [String]) throws -> String {
    var material = Data("base:\(baseCommitOID)\n".utf8)
    for path in files {
      material.append(Data("path:\(path)\n".utf8))
      do { material.append(try safeSourceBytes(path)) } catch CocoaError.fileReadNoSuchFile {
        material.append(Data("<deleted>".utf8))
      }
      material.append(Data("\n".utf8))
    }
    return RockchipEvolutionCampaignConfirmationAssertion.sha256(material)
  }

  private func safeSourceBytes(_ path: String) throws -> Data {
    guard Self.isCandidateSource(path) else {
      throw RockchipEvolutionCampaignError.candidateRejected("scopeDrift")
    }
    let url = sourceRoot.appending(path: path).standardizedFileURL
    let prefix = sourceRoot.path.hasSuffix("/") ? sourceRoot.path : sourceRoot.path + "/"
    guard url.path.hasPrefix(prefix) else {
      throw RockchipEvolutionCampaignError.candidateRejected("workspaceEscape")
    }
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
      metadata.st_size >= 0, metadata.st_size <= Self.maximumCandidateDiffBytes
    else {
      if errno == ENOENT { throw CocoaError(.fileReadNoSuchFile) }
      throw RockchipEvolutionCampaignError.candidateRejected("unsafeSourceEntry")
    }
    return try Data(contentsOf: url, options: [.mappedIfSafe])
  }

  private static func isCandidateSource(_ path: String) -> Bool {
    let prefix = "Packages/ArkDeckKit/Sources/ArkDeckHarness/Candidate/"
    return path.hasPrefix(prefix) && path.count > prefix.count && !path.contains("..")
      && !path.contains("\\")
      && !path.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      })
  }

  private static func nulSeparated(_ data: Data) -> [String] {
    data.split(separator: 0).compactMap { bytes in
      let value = String(decoding: bytes, as: UTF8.self)
      return value.isEmpty ? nil : value
    }
  }

  private static func changedLineCount(_ diff: Data) -> Int {
    String(decoding: diff, as: UTF8.self).split(separator: "\n").reduce(0) { count, line in
      guard
        (line.hasPrefix("+") && !line.hasPrefix("+++"))
          || (line.hasPrefix("-") && !line.hasPrefix("---"))
      else { return count }
      return count + 1
    }
  }

  package static func sandboxProfile(candidateURL: URL, requestURL: URL) -> String {
    func escaped(_ value: String) -> String {
      value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    }
    return """
      (version 1)
      (deny default)
      (import "dyld-support.sb")
      (allow process-exec (literal "\(escaped(candidateURL.path))"))
      (allow process-info*)
      (allow sysctl-read)
      (allow file-read-metadata)
      (allow file-read* (subpath "/System") (subpath "/usr/lib")
        (subpath "/private/var/db/dyld")
        (literal "\(escaped(candidateURL.path))")
        (literal "\(escaped(requestURL.path))"))
      (allow file-write-data (literal "/dev/stdout") (literal "/dev/stderr"))
      """
  }

  private static func executableSHA256(_ url: URL) throws -> String {
    guard FileManager.default.isExecutableFile(atPath: url.path) else {
      throw RockchipEvolutionCampaignError.candidateRejected("executableUnavailable")
    }
    return RockchipEvolutionCampaignConfirmationAssertion.sha256(try Data(contentsOf: url))
  }

  private static func writeOwnerOnly(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    _ = Darwin.unlink(url.path)
    let descriptor = Darwin.open(
      url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw RockchipEvolutionCampaignError.persistenceRejected("candidateArtifact")
    }
    defer { Darwin.close(descriptor) }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw RockchipEvolutionCampaignError.persistenceRejected("candidateArtifact")
        }
        offset += count
      }
    }
    guard Darwin.fsync(descriptor) == 0 else {
      throw RockchipEvolutionCampaignError.persistenceRejected("candidateArtifact")
    }
  }

  private static func timestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
  }
}

public struct RockchipEvolutionFailureObservation: Sendable, Equatable {
  public let attemptOrdinal: Int
  public let failureCode: String

  public init(attemptOrdinal: Int, failureCode: String) throws {
    guard attemptOrdinal > 0,
      failureCode.range(
        of: #"^[a-z][a-zA-Z0-9._:-]{0,127}$"#, options: .regularExpression)
        == failureCode.startIndex..<failureCode.endIndex
    else { throw RockchipEvolutionCampaignError.candidateRejected("failureObservation") }
    self.attemptOrdinal = attemptOrdinal
    self.failureCode = failureCode
  }
}

public protocol RockchipEvolutionStrategyRepairing: Sendable {
  var repairerID: String { get }
  func propose(
    assertion: RockchipEvolutionCampaignConfirmationAssertion,
    observation: RockchipEvolutionFailureObservation?,
    priorCandidates: [RockchipEvolutionCandidatePin]
  ) async throws -> RockchipEvolutionTypedStrategy
}

/// The vendor-free strategy source.
///
/// A repairer is the campaign's *repair* lane, but it was also the only source
/// of the very first strategy, so a host without a configured model vendor
/// refused to start a campaign at all — flashing a bound device required an
/// external agent binary that the first attempt never consults. This supplies
/// that first candidate from what the confirmation already pins plus the
/// published timing defaults, so the published strategy needs no vendor.
///
/// It refuses to answer a repair. An observation or a prior candidate means the
/// published strategy has already failed, and inventing a second one without a
/// repairer would be the campaign guessing at a device it cannot observe; the
/// host stops the campaign instead.
public struct PublishedRockchipEvolutionStrategyRepairer:
  RockchipEvolutionStrategyRepairing
{
  public let repairerID = "published-strategy@1"

  public init() {}

  public func propose(
    assertion: RockchipEvolutionCampaignConfirmationAssertion,
    observation: RockchipEvolutionFailureObservation?,
    priorCandidates: [RockchipEvolutionCandidatePin]
  ) async throws -> RockchipEvolutionTypedStrategy {
    guard observation == nil, priorCandidates.isEmpty else {
      throw RockchipEvolutionCampaignError.candidateRejected("repairerUnavailable")
    }
    return try RockchipEvolutionTypedStrategy(
      operationReference: RockchipEvolutionCampaignConfirmationAssertion.operationReference,
      deviceProfileReference: "dayu200",
      archiveDigestSHA256: assertion.archiveDigestSHA256,
      stepSetDigestSHA256: assertion.stepSetDigestSHA256,
      allowedStartingModes: RockchipEvolutionStartingMode.allCases,
      userdataImpact: RockchipEvolutionCampaignConfirmationAssertion.dataImpact)
  }
}

extension JSONEncoder {
  fileprivate static var sorted: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}

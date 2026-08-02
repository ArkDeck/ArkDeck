// Task-owned candidate build/sandbox and independent review pipeline
// (CHG-2026-025 r8, TASK-AIN-019).

import ArkDeckCore
import ArkDeckHarness
import ArkDeckProcess
import CryptoKit
import Darwin
import Foundation

public struct RockchipEvolutionCandidateBuild: Sendable, Equatable {
  public let pin: RockchipEvolutionCandidatePin
  /// Bounded immutable diff bytes handed only to the read-only reviewer.
  public let reviewDiff: Data

  public init(pin: RockchipEvolutionCandidatePin, reviewDiff: Data) {
    self.pin = pin
    self.reviewDiff = reviewDiff
  }
}

public protocol RockchipEvolutionCandidateBuilding: Sendable {
  func build(
    assertion: RockchipEvolutionCampaignConfirmationAssertion
  ) async throws -> RockchipEvolutionCandidateBuild
}

public struct RockchipEvolutionAdversarialReviewRequest: Sendable, Equatable {
  public let assertion: RockchipEvolutionCampaignConfirmationAssertion
  public let candidate: RockchipEvolutionCandidatePin
  public let immutableDiff: Data
  public let priorAttempts: [RockchipEvolutionCampaignEvent]

  public init(
    assertion: RockchipEvolutionCampaignConfirmationAssertion,
    candidate: RockchipEvolutionCandidatePin,
    immutableDiff: Data,
    priorAttempts: [RockchipEvolutionCampaignEvent]
  ) {
    self.assertion = assertion
    self.candidate = candidate
    self.immutableDiff = immutableDiff
    self.priorAttempts = priorAttempts
  }
}

public protocol RockchipEvolutionAdversarialReviewing: Sendable {
  var reviewerID: String { get }
  func review(_ request: RockchipEvolutionAdversarialReviewRequest) async throws
    -> RockchipEvolutionReviewReceipt
}

/// Identity-bound fixed-command builder.  The caller cannot supply a source
/// path, executable, argv, build target, scratch path or sandbox profile.
public final class ProductRockchipEvolutionCandidateBuilder: @unchecked Sendable,
  RockchipEvolutionCandidateBuilding
{
  public static let producerID = "task-owned-evolution-candidate-builder@1"
  public static let maximumReviewDiffBytes = 512 * 1_024

  private let sourceRoot: URL
  private let stateRoot: URL
  private let executor: FoundationProcessExecutor
  private let gitURL = URL(fileURLWithPath: "/usr/bin/git")
  private let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  private let sandboxURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")

  public convenience init(stateRoot: URL) throws {
    try self.init(
      sourceRoot: URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
      stateRoot: stateRoot)
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
    assertion: RockchipEvolutionCampaignConfirmationAssertion
  ) async throws -> RockchipEvolutionCandidateBuild {
    guard assertion.isValid(at: Self.timestamp()) else {
      throw RockchipEvolutionCampaignError.expired
    }
    let gitSHA = try Self.executableSHA256(gitURL)
    let xcrunSHA = try Self.executableSHA256(xcrunURL)
    let sandboxSHA = try Self.executableSHA256(sandboxURL)
    let topLevel = try await runText(
      executable: gitURL, sha256: gitSHA,
      arguments: ["rev-parse", "--show-toplevel"], timeout: 15)
    guard URL(fileURLWithPath: topLevel, isDirectory: true).standardizedFileURL == sourceRoot else {
      throw RockchipEvolutionCampaignError.candidateRejected("taskOwnedWorkspace")
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
    guard !changedFiles.isEmpty else {
      throw RockchipEvolutionCampaignError.candidateRejected("noCandidateDiff")
    }
    guard changedFiles.allSatisfy(Self.isCandidateSource),
      changedFiles.count <= assertion.maxChangedFiles
    else { throw RockchipEvolutionCampaignError.candidateRejected("scopeDrift") }

    let diff = try await run(
      executable: gitURL, sha256: gitSHA,
      arguments: ["diff", "--no-ext-diff", "--binary", assertion.baseCommitOID, "--", "."],
      timeout: 60, captureLimit: Self.maximumReviewDiffBytes + 1
    ).stdout
    guard !diff.wasTruncated else {
      throw RockchipEvolutionCampaignError.candidateRejected("diffBytes")
    }
    var reviewDiff = diff.data
    let trackedFiles = Set(Self.nulSeparated(tracked))
    for path in changedFiles where !trackedFiles.contains(path) {
      let bytes = try safeSourceBytes(path)
      reviewDiff.append(Data("\n--- /dev/null\n+++ b/\(path)\n".utf8))
      reviewDiff.append(bytes)
      reviewDiff.append(Data("\n".utf8))
      guard reviewDiff.count <= Self.maximumReviewDiffBytes else {
        throw RockchipEvolutionCampaignError.candidateRejected("diffBytes")
      }
    }
    let changedLines = Self.changedLineCount(reviewDiff)
    guard changedLines <= assertion.maxDiffLines else {
      throw RockchipEvolutionCampaignError.candidateRejected("diffLineBudget")
    }

    let sourceTreeDigest = try sourceDigest(
      baseCommitOID: assertion.baseCommitOID, files: changedFiles)
    let diffDigest = RockchipEvolutionCampaignConfirmationAssertion.sha256(reviewDiff)
    let allowedPathDigest = RockchipEvolutionCampaignConfirmationAssertion.sha256(
      RockchipEvolutionCampaignConfirmationAssertion.canonicalData([
        "allowedPaths": .array(assertion.allowedPaths.map(JSONValue.string))
      ]))
    let candidateSeed = Data(
      [sourceTreeDigest, diffDigest, allowedPathDigest].joined(separator: "|").utf8)
    let candidateDigest = RockchipEvolutionCampaignConfirmationAssertion.sha256(candidateSeed)
    let candidateID = "ECAND-\(candidateDigest.prefix(24).uppercased())"

    let toolchainDigest = try await Self.toolchainDigest(
      executor: executor, sourceRoot: sourceRoot, xcrunURL: xcrunURL, xcrunSHA: xcrunSHA)
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
    let packagePath = sourceRoot.appending(path: "Packages/ArkDeckKit", directoryHint: .isDirectory)
    let build = try await run(
      executable: xcrunURL, sha256: xcrunSHA,
      arguments: [
        "swift", "build", "--package-path", packagePath.path,
        "--scratch-path", scratch.path, "--product",
        RockchipEvolutionCampaignConfirmationAssertion.candidateBuildTarget,
      ], timeout: 900, captureLimit: 1 * 1_024 * 1_024)
    guard build.termination == .exited(0), !build.stdout.wasTruncated,
      !build.stderr.wasTruncated
    else { throw RockchipEvolutionCampaignError.candidateRejected("buildFailed") }
    let binPath = try await runText(
      executable: xcrunURL, sha256: xcrunSHA,
      arguments: [
        "swift", "build", "--package-path", packagePath.path,
        "--scratch-path", scratch.path, "--show-bin-path",
      ], timeout: 120)
    let candidateURL = URL(fileURLWithPath: binPath, isDirectory: true)
      .appending(path: RockchipEvolutionCampaignConfirmationAssertion.candidateBuildTarget)
      .standardizedFileURL
    let executableDigest = try Self.executableSHA256(candidateURL)

    let requestURL = candidateRoot.appending(path: "candidate-request.json")
    let request = RockchipEvolutionCampaignConfirmationAssertion.canonicalData([
      "archiveDigestSHA256": .string(assertion.archiveDigestSHA256),
      "deviceProfileReference": .string("dayu200@2"),
      "operationReference": .string(
        RockchipEvolutionCampaignConfirmationAssertion.operationReference),
      "stepSetDigestSHA256": .string(assertion.stepSetDigestSHA256),
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
      try Self.executableSHA256(candidateURL) == executableDigest,
      try sourceDigest(baseCommitOID: assertion.baseCommitOID, files: changedFiles)
        == sourceTreeDigest
    else { throw RockchipEvolutionCampaignError.candidateRejected("immutablePinDrift") }

    let diffArtifactID = "\(candidateID.lowercased())-diff.patch"
    let buildArtifactID = "\(candidateID.lowercased())-build.json"
    let testArtifactID = "\(candidateID.lowercased())-strategy.json"
    try Self.writeOwnerOnly(reviewDiff, to: candidateRoot.appending(path: diffArtifactID))
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
    return RockchipEvolutionCandidateBuild(pin: pin, reviewDiff: reviewDiff)
  }

  public static func currentToolchainDigest() async throws -> String {
    let root = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true
    )
    .standardizedFileURL
    let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    return try await toolchainDigest(
      executor: FoundationProcessExecutor(), sourceRoot: root, xcrunURL: xcrun,
      xcrunSHA: executableSHA256(xcrun))
  }

  public static func currentProtectedMainBaseCommitOID() async throws -> String {
    let root = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true
    )
    .standardizedFileURL
    let git = URL(fileURLWithPath: "/usr/bin/git")
    let result = try await FoundationProcessExecutor().executeIdentityBound(
      ProcessIdentityBoundRequest(
        process: ProcessRequest(
          executable: git, arguments: ["rev-parse", "origin/main^{commit}"],
          environment: ["NO_COLOR": "1"], workingDirectory: root, timeout: 30),
        expectedSHA256: executableSHA256(git)), captureLimit: 4 * 1_024)
    let value = String(decoding: result.execution.stdout.data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.execution.termination == .exited(0),
      RockchipEvolutionCampaignConfirmationAssertion.isOID(value)
    else { throw RockchipEvolutionCampaignError.candidateRejected("protectedMainBase") }
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
    xcrunURL: URL,
    xcrunSHA: String
  ) async throws -> String {
    let result = try await executor.executeIdentityBound(
      ProcessIdentityBoundRequest(
        process: ProcessRequest(
          executable: xcrunURL, arguments: ["swift", "--version"],
          environment: ["NO_COLOR": "1"], workingDirectory: sourceRoot, timeout: 30),
        expectedSHA256: xcrunSHA), captureLimit: 64 * 1_024)
    guard result.execution.termination == .exited(0), !result.execution.stdout.wasTruncated else {
      throw RockchipEvolutionCampaignError.candidateRejected("toolchainUnavailable")
    }
    return RockchipEvolutionCampaignConfirmationAssertion.sha256(
      Data(xcrunSHA.utf8) + result.execution.stdout.data)
  }

  private func run(
    executable: URL,
    sha256: String,
    arguments: [String],
    timeout: TimeInterval,
    captureLimit: Int = 256 * 1_024
  ) async throws -> ProcessExecutionResult {
    let result = try await executor.executeIdentityBound(
      ProcessIdentityBoundRequest(
        process: ProcessRequest(
          executable: executable, arguments: arguments,
          environment: ["NO_COLOR": "1"], workingDirectory: sourceRoot, timeout: timeout),
        expectedSHA256: sha256), captureLimit: captureLimit)
    guard result.execution.termination == .exited(0) else {
      throw RockchipEvolutionCampaignError.candidateRejected(
        "process:\(executable.lastPathComponent)")
    }
    return result.execution
  }

  private func runText(
    executable: URL, sha256: String, arguments: [String], timeout: TimeInterval
  ) async throws -> String {
    let result = try await run(
      executable: executable, sha256: sha256, arguments: arguments, timeout: timeout)
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
      metadata.st_size >= 0, metadata.st_size <= Self.maximumReviewDiffBytes
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

/// Codex runs in its existing read-only ephemeral mode and sees only the
/// immutable candidate diff/pins and bounded attempt history.  This adapter
/// has no Runtime, device, repair or authority dependency.
public struct CodexRockchipEvolutionAdversarialReviewer:
  RockchipEvolutionAdversarialReviewing
{
  public let reviewerID: String
  private let executablePath: String
  private let executableSHA256: String
  private let modelName: String
  private let workingDirectory: String
  private let transport: any HarnessCodexTransport

  public init(
    executablePath: String,
    modelName: String,
    workingDirectory: String,
    transport: any HarnessCodexTransport = CodexCLIProcessTransport()
  ) throws {
    let executableURL = URL(fileURLWithPath: executablePath)
      .resolvingSymlinksInPath().standardizedFileURL
    let workingURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL
    var isDirectory: ObjCBool = false
    guard executablePath.hasPrefix("/"), executableURL.path == executablePath,
      FileManager.default.isExecutableFile(atPath: executablePath),
      workingDirectory.hasPrefix("/"), workingURL.path == workingDirectory,
      FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
      isDirectory.boolValue,
      !modelName.isEmpty, modelName.utf8.count <= 200,
      modelName.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._:-".contains($0)) })
    else { throw RockchipEvolutionCampaignError.reviewRejected("reviewerConfiguration") }
    self.executablePath = executablePath
    executableSHA256 = RockchipEvolutionCampaignConfirmationAssertion.sha256(
      try Data(contentsOf: executableURL))
    self.modelName = modelName
    self.workingDirectory = workingDirectory
    self.transport = transport
    reviewerID =
      "codex-evolution-reviewer@1:"
      + String(
        RockchipEvolutionCampaignConfirmationAssertion.sha256(
          Data("\(executableSHA256)|\(modelName)".utf8)
        ).prefix(16))
  }

  public func review(_ request: RockchipEvolutionAdversarialReviewRequest) async throws
    -> RockchipEvolutionReviewReceipt
  {
    guard
      request.immutableDiff.count
        <= ProductRockchipEvolutionCandidateBuilder
        .maximumReviewDiffBytes
    else { throw RockchipEvolutionCampaignError.reviewRejected("diffBytes") }
    let candidateData = try JSONEncoder.sorted.encode(request.candidate)
    let history = request.priorAttempts.suffix(24).map { event in
      "\(event.sequence):\(event.kind.rawValue):\(event.ordinal.map(String.init) ?? "-"):"
        + "\(event.disposition?.rawValue ?? "-")"
    }.joined(separator: "\n")
    let prompt = """
      You are the independent read-only adversarial reviewer for one bounded E2 firmware
      campaign candidate. You have no repair, Runtime, device or authority port. Review only
      the immutable diff and pins below. Reject any attempt to add network, USB/HDC/RockUSB,
      raw shell, arbitrary executable/argv/path, authorization access, Catalog/profile/broker
      changes, target/budget widening, or unbounded behavior. Answer one JSON object only:
      {"result":"PASS|REJECT","issues":[{"severity":"LOW|MEDIUM|HIGH|CRITICAL","code":"UPPER_CODE"}]}
      PASS is legal only with zero HIGH/CRITICAL issues.
      planDigest=\(request.assertion.planDigestSHA256)
      archiveDigest=\(request.assertion.archiveDigestSHA256)
      stepSetDigest=\(request.assertion.stepSetDigestSHA256)
      candidate=\(String(decoding: candidateData, as: UTF8.self))
      history:\n\(history)
      immutableDiff:\n\(String(decoding: request.immutableDiff, as: UTF8.self))
      """
    let response = try await transport.send(
      HarnessCodexProcessRequest(
        executablePath: executablePath, executableSHA256: executableSHA256,
        arguments: [
          "exec", "--ephemeral", "--ignore-user-config", "--ignore-rules",
          "--sandbox", "read-only", "--skip-git-repo-check", "-C", workingDirectory,
          "--color", "never", "--model", modelName, prompt,
        ], workingDirectory: workingDirectory, timeoutSeconds: 300))
    guard let root = try? JSONDecoder().decode(JSONValue.self, from: response),
      case .object(let object) = root, Set(object.keys) == ["result", "issues"],
      case .string(let resultText)? = object["result"],
      let result = RockchipEvolutionReviewVerdict(rawValue: resultText),
      case .array(let issueValues)? = object["issues"]
    else { throw RockchipEvolutionCampaignError.reviewRejected("responseShape") }
    let issues = try issueValues.map { value -> RockchipEvolutionReviewIssue in
      guard case .object(let fields) = value, Set(fields.keys) == ["severity", "code"],
        case .string(let severityText)? = fields["severity"],
        let severity = RockchipEvolutionReviewSeverity(rawValue: severityText),
        case .string(let code)? = fields["code"]
      else { throw RockchipEvolutionCampaignError.reviewRejected("issueShape") }
      return try RockchipEvolutionReviewIssue(severity: severity, code: code)
    }
    let responseDigest = RockchipEvolutionCampaignConfirmationAssertion.sha256(response)
    let receipt = try RockchipEvolutionReviewReceipt(
      reviewID: "EREVIEW-\(responseDigest.prefix(24).uppercased())",
      reviewerID: reviewerID, candidateID: request.candidate.candidateID,
      candidateExecutableDigestSHA256: request.candidate.executableDigestSHA256,
      planDigestSHA256: request.assertion.planDigestSHA256,
      result: result, issues: issues, createdAt: ISO8601DateFormatter().string(from: Date()))
    try receipt.validate(candidate: request.candidate)
    return receipt
  }
}

extension JSONEncoder {
  fileprivate static var sorted: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}

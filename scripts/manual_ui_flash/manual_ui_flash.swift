#!/usr/bin/env swift

// Manual, real-device GJ-4 driver. This file is intentionally outside every
// XCTest/UI-test target because a flash attempt can take several minutes.
//
// The driver exercises ArkDeck's real Accessibility surface, verifies the
// exact plan and userdata impact shown by the UI, and presses the App's
// one-click typed Runtime submit control. Runtime creates/consumes the
// capability; this driver has no authority or capability administration
// surface.

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CryptoKit
import Darwin
import Foundation

enum DriverFailure: Error, CustomStringConvertible {
  case message(String)

  var description: String {
    switch self {
    case .message(let message): message
    }
  }
}

private struct CandidateCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int? = nil

  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}

private enum CandidateApplicationActivation: String, Codable {
  case activateOnly
  case activateAndRaise
}

private enum CandidateControlDelivery: String, Codable {
  case accessibilityPress
  case pointerClick
}

private enum CandidateUIActionKind: String, Codable {
  case perform
  case waitForPresence
  case waitForAbsence
  case waitForEnabled
  case waitForDisabled
  case waitForSelected
  case choosePinnedArchive
  case selectPinnedTarget
  case waitForPinnedPlan
}

/// One composable, pre-submit UI effect. Candidate programs may change the
/// order and delivery mechanics without teaching protected main about a new
/// problem or repair kind. Raw values are deliberately absent: archive,
/// target and plan facts are supplied only by the protected invocation.
private struct CandidateUIAction: Codable, Equatable {
  let kind: CandidateUIActionKind
  let identifier: String?
  let delivery: CandidateControlDelivery?
  let fallbackStrings: [String]?

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case kind
    case identifier
    case delivery
    case fallbackStrings
  }

  init(from decoder: any Decoder) throws {
    let dynamic = try decoder.container(keyedBy: CandidateCodingKey.self)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decode(CandidateUIActionKind.self, forKey: .kind)

    let expectedKeys: Set<String>
    switch kind {
    case .perform:
      expectedKeys = ["kind", "identifier", "delivery", "fallbackStrings"]
      identifier = try container.decode(String.self, forKey: .identifier)
      delivery = try container.decode(CandidateControlDelivery.self, forKey: .delivery)
      fallbackStrings = try container.decode([String].self, forKey: .fallbackStrings)
    case .waitForPresence, .waitForAbsence, .waitForEnabled, .waitForDisabled,
      .waitForSelected:
      expectedKeys = ["kind", "identifier"]
      identifier = try container.decode(String.self, forKey: .identifier)
      delivery = nil
      fallbackStrings = nil
    case .choosePinnedArchive:
      expectedKeys = ["kind", "delivery"]
      identifier = nil
      delivery = try container.decode(CandidateControlDelivery.self, forKey: .delivery)
      fallbackStrings = nil
    case .selectPinnedTarget, .waitForPinnedPlan:
      expectedKeys = ["kind"]
      identifier = nil
      delivery = nil
      fallbackStrings = nil
    }

    guard Set(dynamic.allKeys.map(\.stringValue)) == expectedKeys else {
      throw DriverFailure.message("candidate UI action must have its exact effect shape")
    }
    if let identifier {
      guard identifier.range(
        of: "^(app\\.navigation\\.flash|flash\\.[A-Za-z0-9._-]{1,112})$",
        options: .regularExpression) != nil,
        !identifier.hasPrefix("flash.execute.")
      else {
        throw DriverFailure.message(
          "candidate UI action escaped the exact Flash pre-submit surface")
      }
    }
    if let fallbackStrings {
      guard fallbackStrings.count <= 4,
        fallbackStrings.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
        fallbackStrings.isEmpty || identifier == "app.navigation.flash"
      else {
        throw DriverFailure.message("candidate UI fallback strings are outside bounds")
      }
    }
  }

}

/// Untrusted pre-admission program interpreted by the reviewed actuator. This
/// is a stable effect grammar rather than an enumeration of known UI failure
/// modes. It can reach only the exact ArkDeck Flash UI before submit; the
/// protected actuator alone supplies request values, verifies the complete
/// typed plan and performs the single Runtime submit.
private struct ManualUIFlashCandidateProgram: Codable, Equatable {
  static let documentType = "manual-ui-flash-candidate-program"
  static let schemaVersion = "2.0.0"

  let documentType: String
  let schemaVersion: String
  let applicationActivation: CandidateApplicationActivation
  let activationSettleMilliseconds: Int
  let controlTimeoutSeconds: Int
  let planTimeoutSeconds: Int
  let actions: [CandidateUIAction]

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case documentType
    case schemaVersion
    case applicationActivation
    case activationSettleMilliseconds
    case controlTimeoutSeconds
    case planTimeoutSeconds
    case actions
  }

  init(from decoder: any Decoder) throws {
    let dynamic = try decoder.container(keyedBy: CandidateCodingKey.self)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard Set(dynamic.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.stringValue))
    else {
      throw DriverFailure.message("candidate UI program must have the exact published shape")
    }
    documentType = try container.decode(String.self, forKey: .documentType)
    schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
    applicationActivation = try container.decode(
      CandidateApplicationActivation.self, forKey: .applicationActivation)
    activationSettleMilliseconds = try container.decode(
      Int.self, forKey: .activationSettleMilliseconds)
    controlTimeoutSeconds = try container.decode(Int.self, forKey: .controlTimeoutSeconds)
    planTimeoutSeconds = try container.decode(Int.self, forKey: .planTimeoutSeconds)
    actions = try container.decode([CandidateUIAction].self, forKey: .actions)
    guard documentType == Self.documentType,
      schemaVersion == Self.schemaVersion,
      (50...2_000).contains(activationSettleMilliseconds),
      (5...60).contains(controlTimeoutSeconds),
      (30...300).contains(planTimeoutSeconds),
      (1...64).contains(actions.count)
    else {
      throw DriverFailure.message("candidate UI program is outside the invariant bounds")
    }
  }
}

private struct LoadedManualUICandidate {
  let program: ManualUIFlashCandidateProgram
  let programSHA256: String
  let actuatorSHA256: String
}

private func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private let manualUIAOTChildArgument = "--manual-ui-aot-child"
private let manualUIAOTCompilerPath = "/usr/bin/swiftc"

private struct ManualUIAOTPaths {
  let source: URL
  let digestDirectory: URL
  let moduleCache: URL
  let executable: URL
}

private func manualUIAOTPaths() throws -> ManualUIAOTPaths {
  let source = URL(fileURLWithPath: #filePath).standardizedFileURL
  let sourceData = try Data(contentsOf: source)
  guard !sourceData.isEmpty, sourceData.count <= 2 * 1_024 * 1_024 else {
    throw DriverFailure.message("manual UI actuator source is outside the AOT size bound")
  }
  let root = FileManager.default.temporaryDirectory.standardizedFileURL
    .appendingPathComponent("arkdeck-manual-ui-flash-aot", isDirectory: true)
  let digestDirectory = root.appendingPathComponent(sha256(sourceData), isDirectory: true)
  return ManualUIAOTPaths(
    source: source,
    digestDirectory: digestDirectory,
    moduleCache: digestDirectory.appendingPathComponent("modules", isDirectory: true),
    executable: digestDirectory.appendingPathComponent("manual_ui_flash", isDirectory: false))
}

private func manualUIFileStatus(_ url: URL) throws -> stat {
  var value = stat()
  let result = url.path.withCString { lstat($0, &value) }
  guard result == 0 else {
    throw DriverFailure.message(
      "could not inspect AOT path \(url.path): \(String(cString: strerror(errno)))")
  }
  return value
}

private func ensureOwnerPrivateDirectory(_ url: URL) throws {
  let result = url.path.withCString { mkdir($0, S_IRWXU) }
  guard result == 0 || errno == EEXIST else {
    throw DriverFailure.message(
      "could not create AOT directory \(url.path): \(String(cString: strerror(errno)))")
  }
  let value = try manualUIFileStatus(url)
  guard value.st_mode & S_IFMT == S_IFDIR, value.st_uid == geteuid(),
    value.st_mode & (S_IRWXG | S_IRWXO) == 0
  else {
    throw DriverFailure.message("AOT directory is not an owner-private real directory: \(url.path)")
  }
}

private func validateManualUIAOTExecutable(_ url: URL) throws {
  let value = try manualUIFileStatus(url)
  guard value.st_mode & S_IFMT == S_IFREG, value.st_uid == geteuid(),
    value.st_mode & (S_IWGRP | S_IWOTH) == 0,
    value.st_mode & S_IXUSR != 0
  else {
    throw DriverFailure.message("AOT actuator is not an owner-controlled executable: \(url.path)")
  }
}

private func compileManualUIAOT() throws -> URL {
  let paths = try manualUIAOTPaths()
  let root = paths.digestDirectory.deletingLastPathComponent()
  try ensureOwnerPrivateDirectory(root)
  try ensureOwnerPrivateDirectory(paths.digestDirectory)
  try ensureOwnerPrivateDirectory(paths.moduleCache)

  let staging = paths.digestDirectory.appendingPathComponent(
    ".manual_ui_flash.\(UUID().uuidString).tmp", isDirectory: false)
  defer { try? FileManager.default.removeItem(at: staging) }

  let errors = Pipe()
  let compiler = Process()
  compiler.executableURL = URL(fileURLWithPath: manualUIAOTCompilerPath)
  compiler.arguments = [
    "-module-cache-path", paths.moduleCache.path,
    paths.source.path,
    "-o", staging.path,
  ]
  compiler.environment = [
    "PATH": "/usr/bin:/bin",
    "LC_ALL": "C",
    "TMPDIR": FileManager.default.temporaryDirectory.path,
  ]
  compiler.standardOutput = FileHandle.nullDevice
  compiler.standardError = errors
  try compiler.run()
  let errorData = errors.fileHandleForReading.readDataToEndOfFile()
  compiler.waitUntilExit()
  guard compiler.terminationStatus == 0 else {
    let detail = String(decoding: errorData.prefix(4_096), as: UTF8.self)
    throw DriverFailure.message("could not AOT-compile XPC bridge: \(detail)")
  }
  guard staging.path.withCString({ chmod($0, S_IRWXU) }) == 0 else {
    throw DriverFailure.message(
      "could not protect AOT actuator: \(String(cString: strerror(errno)))")
  }
  try validateManualUIAOTExecutable(staging)
  guard staging.path.withCString({ sourcePath in
    paths.executable.path.withCString { destinationPath in
      rename(sourcePath, destinationPath)
    }
  }) == 0 else {
    throw DriverFailure.message(
      "could not publish AOT actuator: \(String(cString: strerror(errno)))")
  }
  try validateManualUIAOTExecutable(paths.executable)
  removeStaleManualUIAOTDigests(in: root, keeping: paths.digestDirectory)
  return paths.executable
}

/// The AOT root keys every compiled actuator by the digest of its source, so
/// each edit of this file added a digest directory (its module cache alone is
/// about seventy megabytes) and nothing removed the previous ones. Once the
/// current digest is published its siblings are stale: no source names them,
/// and an actuator still running from one keeps its executable alive through
/// the kernel's own reference, not the path. Removal is best effort and limited
/// to owner-private real directories with a digest-shaped name; the root itself
/// was verified owner-private before compilation.
private func removeStaleManualUIAOTDigests(in root: URL, keeping current: URL) {
  let currentName = current.lastPathComponent
  guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
    return
  }
  for name in names where name != currentName && isManualUIAOTDigestName(name) {
    let candidate = root.appendingPathComponent(name, isDirectory: true)
    guard let status = try? manualUIFileStatus(candidate),
      status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid()
    else { continue }
    try? FileManager.default.removeItem(at: candidate)
  }
}

private func isManualUIAOTDigestName(_ name: String) -> Bool {
  name.count == 64 && name.allSatisfy { $0.isHexDigit && !$0.isUppercase }
}

private func manualUIAOTInvocation(_ arguments: [String]) throws -> (
  isAOTChild: Bool, arguments: [String]
) {
  guard arguments.first == manualUIAOTChildArgument else {
    return (false, arguments)
  }
  let paths = try manualUIAOTPaths()
  try ensureOwnerPrivateDirectory(paths.digestDirectory.deletingLastPathComponent())
  try ensureOwnerPrivateDirectory(paths.digestDirectory)
  try ensureOwnerPrivateDirectory(paths.moduleCache)
  let executable = paths.executable.standardizedFileURL
  guard URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL == executable else {
    throw DriverFailure.message("manual UI AOT child marker did not match the compiled actuator")
  }
  try validateManualUIAOTExecutable(executable)
  return (true, Array(arguments.dropFirst()))
}

private func reexecManualUIAOT(arguments: [String]) throws -> Never {
  let executable = try compileManualUIAOT()
  var argv: [UnsafeMutablePointer<CChar>?] =
    ([executable.path, manualUIAOTChildArgument] + arguments).map { strdup($0) }
  guard !argv.contains(where: { $0 == nil }) else {
    for case let pointer? in argv { free(pointer) }
    throw DriverFailure.message("could not allocate AOT actuator arguments")
  }
  argv.append(nil)
  defer {
    for case let pointer? in argv { free(pointer) }
  }
  let result = executable.path.withCString { execv($0, &argv) }
  throw DriverFailure.message(
    "could not exec AOT actuator (\(result)): \(String(cString: strerror(errno)))")
}

private func canonicalData<T: Encodable>(_ value: T) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return try encoder.encode(value)
}

private func protectedMainActuatorCommit() throws -> String {
  let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
  let repositoryRoot = scriptURL.deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

  func git(_ arguments: [String], maximumBytes: Int) throws -> Data {
    let output = Pipe()
    let errors = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", repositoryRoot.path] + arguments
    process.environment = [
      "PATH": "/usr/bin:/bin",
      "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_CONFIG_GLOBAL": "/dev/null",
      "LC_ALL": "C",
    ]
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, data.count <= maximumBytes else {
      let detail = String(decoding: errorData.prefix(1_024), as: UTF8.self)
      throw DriverFailure.message("could not verify protected-main actuator: \(detail)")
    }
    return data
  }

  let rootData = try git(["rev-parse", "--show-toplevel"], maximumBytes: 4_096)
  let root = String(decoding: rootData, as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard URL(fileURLWithPath: root).standardizedFileURL == repositoryRoot else {
    throw DriverFailure.message("manual UI actuator is not at the repository top level")
  }
  let oidData = try git(["rev-parse", "origin/main^{commit}"], maximumBytes: 256)
  let oid = String(decoding: oidData, as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard oid.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil else {
    throw DriverFailure.message("origin/main did not resolve to a commit")
  }
  let reviewed = try git(
    [
      "show", "--no-ext-diff", "--no-textconv",
      "origin/main:scripts/manual_ui_flash/manual_ui_flash.swift",
    ],
    maximumBytes: 2 * 1_024 * 1_024)
  let current = try Data(contentsOf: scriptURL)
  guard reviewed == current else {
    throw DriverFailure.message(
      "device/UI execution requires the exact actuator from origin/main; "
        + "use candidate JSON or an isolated App build instead of running an unmerged driver")
  }
  return oid
}

private func loadCandidateProgram(at url: URL) throws -> LoadedManualUICandidate {
  let data = try Data(contentsOf: url)
  guard !data.isEmpty, data.count <= 64 * 1_024 else {
    throw DriverFailure.message("candidate UI program must be 1...65536 bytes")
  }
  let program: ManualUIFlashCandidateProgram
  do {
    program = try JSONDecoder().decode(ManualUIFlashCandidateProgram.self, from: data)
  } catch let failure as DriverFailure {
    throw failure
  } catch {
    throw DriverFailure.message("candidate UI program is invalid: \(error)")
  }
  let normalized = try canonicalData(program)
  let actuatorURL = URL(fileURLWithPath: #filePath).standardizedFileURL
  return LoadedManualUICandidate(
    program: program,
    programSHA256: sha256(normalized),
    actuatorSHA256: sha256(try Data(contentsOf: actuatorURL)))
}

private func applicationExecutableSHA256(_ appURL: URL) throws -> String {
  guard let executableURL = Bundle(url: appURL)?.executableURL,
    executableURL.standardizedFileURL.path.hasPrefix(appURL.standardizedFileURL.path + "/"),
    FileManager.default.isExecutableFile(atPath: executableURL.path)
  else {
    throw DriverFailure.message("candidate app has no in-bundle executable")
  }
  return sha256(try Data(contentsOf: executableURL))
}

@objc private protocol ManualFlashXPCProtocol {
  func sendRequestFrame(
    _ frame: Data,
    with reply: @escaping @Sendable (Data?, String?) -> Void)
}

private func validateManualFlashXPCInterface() {
  _ = NSXPCInterface(with: ManualFlashXPCProtocol.self)
  print("XPC_INTERFACE_VALID: aot")
}

/// Manual-only adapter for a daemon that is already running from a shell and
/// therefore cannot itself check in to launchd's Mach service. It forwards
/// the same closed App allowlist to that daemon's private Unix socket.
/// This keeps the UI attached to the real Runtime state without stopping an
/// existing job or copying a target record into a fixture store.
private final class ManualFlashXPCBridge: NSObject, NSXPCListenerDelegate,
  ManualFlashXPCProtocol, @unchecked Sendable
{
  private enum Admission {
    case direct
    case flashSubmit(requestID: String, debugSeed: Data)
    case flashRun(jobID: String)
  }

  private static let directMethods: Set<String> = [
    "artifact.importFlashBundle.abort", "artifact.importFlashBundle.append",
    "artifact.importFlashBundle.begin", "artifact.importFlashBundle.commit",
    "artifact.inspect", "artifact.list", "job.evidence", "job.list",
    "job.list-page", "job.plan", "job.status", "operation.list", "target.list",
  ]

  private let socketPath: String
  private let captureDebugSeedURL: URL?
  private let listener = NSXPCListener(machServiceName: "com.arkdeck.agentd")
  private let jobLock = NSLock()
  private var runnableJobIDs: Set<String> = []

  init(socketPath: String, captureDebugSeedURL: URL?) {
    self.socketPath = socketPath
    self.captureDebugSeedURL = captureDebugSeedURL
    super.init()
    listener.delegate = self
  }

  func run() -> Never {
    listener.resume()
    dispatchMain()
  }

  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    connection.exportedInterface = NSXPCInterface(with: ManualFlashXPCProtocol.self)
    connection.exportedObject = self
    connection.resume()
    return true
  }

  func sendRequestFrame(
    _ frame: Data,
    with reply: @escaping @Sendable (Data?, String?) -> Void
  ) {
    guard let admission = Self.admission(of: frame) else {
      reply(nil, "malformedFrame")
      return
    }
    if case .flashRun(let jobID) = admission, !consume(jobID: jobID) {
      reply(nil, "methodNotAllowlisted")
      return
    }
    let socketPath = self.socketPath
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let response = try forward(frame: frame, socketPath: socketPath)
        if case .flashSubmit(let requestID, let debugSeed) = admission,
          let jobID = Self.successfulSubmittedJobID(in: response, requestID: requestID)
        {
          self.record(jobID: jobID)
          if let captureURL = self.captureDebugSeedURL {
            do {
              try Self.persistDebugSeed(debugSeed, to: captureURL)
              print(
                "RUNTIME_DEBUG_SEED: job=\(jobID) path=\(captureURL.path) "
                  + "sha256=\(sha256(debugSeed))")
            } catch {
              fputs(
                "manual_ui_flash: Runtime debug seed capture failed after Job admission: "
                  + "\(error)\n",
                stderr)
            }
          }
        }
        reply(response, nil)
      } catch {
        reply(nil, "appBridgeFailure: \(error)")
      }
    }
  }

  private static func admission(of frame: Data) -> Admission? {
    guard
      let request = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
      request["protocolVersion"] as? String == "1.0.0",
      let requestID = request["id"] as? String,
      let method = request["method"] as? String
    else { return nil }
    if directMethods.contains(method) { return .direct }

    guard let params = request["params"] as? [String: Any], params.count == 1 else {
      return nil
    }
    switch method {
    case "job.submit":
      guard
        let requestJSON = params["requestJson"] as? String,
        let data = requestJSON.data(using: .utf8),
        let typed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        typed["documentType"] as? String == "runtime-operation-request",
        typed["schemaVersion"] as? String == "1.0.0",
        typed["authorization"] == nil,
        typed["campaignReservation"] == nil,
        let operation = typed["operation"] as? [String: Any],
        operation["id"] as? String == "flash.full-restore",
        operation["version"] as? Int == 1,
        let context = typed["clientContext"] as? [String: Any],
        context["clientName"] as? String == "ArkDeckApp.FlashWorkspace"
      else { return nil }
      var debugSeed = typed
      debugSeed.removeValue(forKey: "clientContext")
      guard let debugSeedData = try? JSONSerialization.data(
        withJSONObject: debugSeed, options: [.sortedKeys])
      else { return nil }
      return .flashSubmit(requestID: requestID, debugSeed: debugSeedData)
    case "job.run":
      guard let jobID = params["jobId"] as? String,
        !jobID.isEmpty, jobID.count <= 128
      else { return nil }
      return .flashRun(jobID: jobID)
    default:
      return nil
    }
  }

  private static func successfulSubmittedJobID(in response: Data, requestID: String) -> String? {
    guard
      let wire = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
      wire["id"] as? String == requestID,
      wire["ok"] as? Bool == true,
      let result = wire["result"] as? [String: Any],
      let jobID = result["jobId"] as? String,
      !jobID.isEmpty, jobID.count <= 128
    else { return nil }
    return jobID
  }

  private static func persistDebugSeed(_ data: Data, to url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular,
        try Data(contentsOf: url) == data
      else {
        throw DriverFailure.message("capture destination already contains a different seed")
      }
      return
    }
    let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw DriverFailure.message("could not create owner-only Runtime debug seed: errno \(errno)")
    }
    defer { close(descriptor) }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        guard count > 0 else {
          throw DriverFailure.message("could not write Runtime debug seed: errno \(errno)")
        }
        offset += count
      }
    }
  }

  private func record(jobID: String) {
    jobLock.lock()
    runnableJobIDs.insert(jobID)
    jobLock.unlock()
  }

  private func consume(jobID: String) -> Bool {
    jobLock.lock()
    let removed = runnableJobIDs.remove(jobID) != nil
    jobLock.unlock()
    return removed
  }
}

private func forward(frame: Data, socketPath: String) throws -> Data {
  let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
  guard descriptor >= 0 else { throw DriverFailure.message("could not create Unix socket") }
  defer { close(descriptor) }

  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
    throw DriverFailure.message("Runtime socket path is too long")
  }
  withUnsafeMutableBytes(of: &address.sun_path) { destination in
    socketPath.utf8CString.withUnsafeBytes { source in
      destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(destination.count)))
    }
  }
  let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  guard connected == 0 else {
    throw DriverFailure.message("could not connect to Runtime socket: errno \(errno)")
  }

  var request = frame
  request.append(0x0A)
  try request.withUnsafeBytes { bytes in
    var offset = 0
    while offset < bytes.count {
      let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
      guard count > 0 else {
        throw DriverFailure.message("could not write Runtime request: errno \(errno)")
      }
      offset += count
    }
  }

  var response = Data()
  var buffer = [UInt8](repeating: 0, count: 64 * 1024)
  while response.count <= 8 * 1024 * 1024 {
    let count = Darwin.read(descriptor, &buffer, buffer.count)
    guard count >= 0 else {
      throw DriverFailure.message("could not read Runtime response: errno \(errno)")
    }
    if count == 0 { break }
    response.append(contentsOf: buffer.prefix(count))
    if response.last == 0x0A { break }
  }
  guard !response.isEmpty, response.count <= 8 * 1024 * 1024 else {
    throw DriverFailure.message("Runtime response is empty or oversized")
  }
  if response.last == 0x0A { response.removeLast() }
  return response
}

struct Options {
  let appURL: URL
  let archiveURL: URL
  let candidateURL: URL
  let debugSessionURL: URL?
  let expectedPlanDigest: String
  let expectedArchiveDigest: String
  let expectedStepSetDigest: String
  let expectedTargetID: String
  let expectedBindingRevision: Int
  let timeoutSeconds: TimeInterval
  let stopBeforeSubmit: Bool

  static func parse(_ arguments: [String]) throws -> Options {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    let valueArguments: Set<String> = [
      "--app", "--archive", "--candidate-file", "--debug-session-file",
      "--expected-plan-digest-sha256", "--expected-archive-digest-sha256",
      "--expected-step-set-digest-sha256", "--expected-target",
      "--expected-binding-revision", "--timeout-seconds",
    ]
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if argument == "--stop-before-submit" {
        guard !flags.contains(argument) else {
          throw DriverFailure.message("duplicate argument: \(argument)")
        }
        flags.insert(argument)
        index += 1
        continue
      }
      guard valueArguments.contains(argument), values[argument] == nil,
        index + 1 < arguments.count
      else {
        throw DriverFailure.message("invalid or missing value for argument: \(argument)")
      }
      values[argument] = arguments[index + 1]
      index += 2
    }

    func required(_ name: String) throws -> String {
      guard let value = values[name], !value.isEmpty else {
        throw DriverFailure.message("missing required argument \(name)")
      }
      return value
    }
    func digest(_ name: String) throws -> String {
      let value = try required(name).lowercased()
      guard value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
        throw DriverFailure.message("\(name) must be a lowercase SHA-256 digest")
      }
      return value
    }
    func existingFile(_ name: String) throws -> URL {
      let url = URL(fileURLWithPath: try required(name)).standardizedFileURL
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else {
        throw DriverFailure.message("\(name) is not a readable file: \(url.path)")
      }
      return url
    }

    let appURL = URL(fileURLWithPath: try required("--app")).standardizedFileURL
    guard appURL.pathExtension == "app",
      FileManager.default.fileExists(atPath: appURL.path)
    else {
      throw DriverFailure.message("--app must name an existing .app bundle")
    }
    let revisionText = try required("--expected-binding-revision")
    guard let revision = Int(revisionText), revision > 0 else {
      throw DriverFailure.message("--expected-binding-revision must be a positive integer")
    }

    let timeoutSeconds = values["--timeout-seconds"].flatMap(TimeInterval.init) ?? 7_200
    guard timeoutSeconds >= 60, timeoutSeconds <= 14_400 else {
      throw DriverFailure.message("--timeout-seconds must be between 60 and 14400")
    }

    let defaultCandidateURL = URL(fileURLWithPath: #filePath).standardizedFileURL
      .deletingLastPathComponent()
      .appendingPathComponent("manual_ui_flash_candidate.json")
    let candidateURL: URL
    if let path = values["--candidate-file"] {
      candidateURL = URL(fileURLWithPath: path).standardizedFileURL
      var isDirectory: ObjCBool = false
      guard path.hasPrefix("/"),
        FileManager.default.fileExists(atPath: candidateURL.path, isDirectory: &isDirectory),
        !isDirectory.boolValue,
        values["--debug-session-file"] != nil
      else {
        throw DriverFailure.message(
          "an external --candidate-file requires an absolute readable file and "
            + "--debug-session-file")
      }
    } else {
      candidateURL = defaultCandidateURL
    }
    var debugSessionURL: URL?
    if let path = values["--debug-session-file"] {
      let url = URL(fileURLWithPath: path).standardizedFileURL
      let parent = url.deletingLastPathComponent()
      var isDirectory: ObjCBool = false
      guard path.hasPrefix("/"),
        FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        throw DriverFailure.message(
          "--debug-session-file requires an absolute path in an existing directory")
      }
      debugSessionURL = url
    }

    return Options(
      appURL: appURL,
      archiveURL: try existingFile("--archive"),
      candidateURL: candidateURL,
      debugSessionURL: debugSessionURL,
      expectedPlanDigest: try digest("--expected-plan-digest-sha256"),
      expectedArchiveDigest: try digest("--expected-archive-digest-sha256"),
      expectedStepSetDigest: try digest("--expected-step-set-digest-sha256"),
      expectedTargetID: try required("--expected-target"),
      expectedBindingRevision: revision,
      timeoutSeconds: timeoutSeconds,
      stopBeforeSubmit: flags.contains("--stop-before-submit"))
  }
}

private struct ManualUIDebugAttempt: Codable {
  let ordinal: Int
  let candidateProgramSHA256: String
  let candidateActuatorSHA256: String
  let candidateAppExecutableSHA256: String
  let startedAtUTC: String
  var state: String
  var detail: String
  var jobID: String?
  var runtimeState: String?
}

private struct ManualUIDebugSessionDocument: Codable {
  static let documentType = "manual-ui-flash-debug-session"
  static let schemaVersion = "3.0.0"

  let documentType: String
  let schemaVersion: String
  let invocationID: String
  var state: String
  let protectedMainCommitOID: String
  let appPath: String
  let archiveSHA256: String
  let planSHA256: String
  let stepSetSHA256: String
  let targetID: String
  let bindingRevision: Int
  let createdAtUTC: String
  let expiresAtUTC: String
  var destructiveEpochsUsed: Int
  var attempts: [ManualUIDebugAttempt]
}

/// Non-authoritative, durable product-debug loop record. It cannot authorize a
/// Job; it prevents a host candidate from silently replaying after the UI has
/// requested submission without a terminal observation and bounds the number
/// of destructive submits independently from pre-admission repair attempts.
private final class ManualUIDebugSessionRecorder {
  static let maximumAttempts = 64
  static let maximumDestructiveEpochs = 16
  static let maximumDuration: TimeInterval = 4 * 60 * 60

  private let url: URL
  private var document: ManualUIDebugSessionDocument
  private var attemptIndex: Int

  init(
    url: URL,
    options: Options,
    candidate: LoadedManualUICandidate,
    appExecutableSHA256: String,
    protectedMainCommitOID: String
  ) throws {
    self.url = url
    let formatter = ISO8601DateFormatter()
    let now = Date()
    if FileManager.default.fileExists(atPath: url.path) {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw DriverFailure.message("debug session must be a regular file, not a symlink")
      }
      let storedData = try Data(contentsOf: url)
      guard storedData.count <= 1 * 1_024 * 1_024 else {
        throw DriverFailure.message("debug session is oversized")
      }
      document = try JSONDecoder().decode(
        ManualUIDebugSessionDocument.self, from: storedData)
      guard document.documentType == ManualUIDebugSessionDocument.documentType,
        document.schemaVersion == ManualUIDebugSessionDocument.schemaVersion,
        document.protectedMainCommitOID == protectedMainCommitOID,
        document.appPath == options.appURL.path,
        document.archiveSHA256 == options.expectedArchiveDigest,
        document.planSHA256 == options.expectedPlanDigest,
        document.stepSetSHA256 == options.expectedStepSetDigest,
        document.targetID == options.expectedTargetID,
        document.bindingRevision == options.expectedBindingRevision,
        document.destructiveEpochsUsed <= Self.maximumDestructiveEpochs,
        let expiry = formatter.date(from: document.expiresAtUTC), now <= expiry
      else {
        throw DriverFailure.message("debug session identity drifted or expired")
      }
      guard document.state == "active" else {
        throw DriverFailure.message(
          "debug session is \(document.state); reconcile Runtime or start a new exact session")
      }
      if let last = document.attempts.last,
        ["submissionRequested", "submissionOutcomeUnknown"].contains(last.state)
      {
        throw DriverFailure.message(
          "prior UI submission outcome is not terminal; refusing another candidate")
      }
      if let last = document.attempts.last,
        last.candidateProgramSHA256 == candidate.programSHA256,
        last.candidateActuatorSHA256 == candidate.actuatorSHA256,
        last.candidateAppExecutableSHA256 == appExecutableSHA256,
        ["preparingUI", "uiReady"].contains(last.state)
      {
        attemptIndex = document.attempts.count - 1
        document.attempts[attemptIndex].state = "preparingUI"
        document.attempts[attemptIndex].detail = "resumed exact pre-admission candidate"
        try persist()
        return
      }
      guard document.attempts.count < Self.maximumAttempts else {
        throw DriverFailure.message("debug session exhausted its 64 pre-admission candidates")
      }
    } else {
      document = ManualUIDebugSessionDocument(
        documentType: ManualUIDebugSessionDocument.documentType,
        schemaVersion: ManualUIDebugSessionDocument.schemaVersion,
        invocationID: "ui-debug-\(UUID().uuidString.lowercased())",
        state: "active",
        protectedMainCommitOID: protectedMainCommitOID,
        appPath: options.appURL.path,
        archiveSHA256: options.expectedArchiveDigest,
        planSHA256: options.expectedPlanDigest,
        stepSetSHA256: options.expectedStepSetDigest,
        targetID: options.expectedTargetID,
        bindingRevision: options.expectedBindingRevision,
        createdAtUTC: formatter.string(from: now),
        expiresAtUTC: formatter.string(from: now.addingTimeInterval(Self.maximumDuration)),
        destructiveEpochsUsed: 0,
        attempts: [])
    }
    document.attempts.append(
      ManualUIDebugAttempt(
        ordinal: document.attempts.count + 1,
        candidateProgramSHA256: candidate.programSHA256,
        candidateActuatorSHA256: candidate.actuatorSHA256,
        candidateAppExecutableSHA256: appExecutableSHA256,
        startedAtUTC: formatter.string(from: now),
        state: "preparingUI",
        detail: "candidate admitted to protected UI actuator",
        jobID: nil,
        runtimeState: nil))
    attemptIndex = document.attempts.count - 1
    try persist()
  }

  var invocationID: String { document.invocationID }
  var requiresFreshCandidateApp: Bool { document.attempts[attemptIndex].ordinal > 1 }

  func markUIReady() throws {
    document.attempts[attemptIndex].state = "uiReady"
    document.attempts[attemptIndex].detail =
      "exact plan and impact are visible; external dispatch remains zero"
    try persist()
  }

  func markSubmissionRequested() throws {
    guard document.destructiveEpochsUsed < Self.maximumDestructiveEpochs else {
      throw DriverFailure.message(
        "debug session exhausted its 16 destructive epochs; externalDispatch=0")
    }
    // Persist the budget charge before the click. A crash after this point
    // cannot make an attempted destructive dispatch disappear from the
    // session's accounting.
    document.destructiveEpochsUsed += 1
    document.attempts[attemptIndex].state = "submissionRequested"
    document.attempts[attemptIndex].detail =
      "protected-main UI submit requested; destructive epoch "
      + "\(document.destructiveEpochsUsed)/\(Self.maximumDestructiveEpochs)"
    try persist()
  }

  func markRuntimeTerminal(jobID: String, state: String) throws {
    document.attempts[attemptIndex].state = "runtimeTerminal"
    document.attempts[attemptIndex].detail = "Runtime returned durable terminal \(state)"
    document.attempts[attemptIndex].jobID = jobID
    document.attempts[attemptIndex].runtimeState = state
    document.state = state == "succeeded" ? "active" : "runtimeContinuationRequired"
    try persist()
  }

  func markProductVerified() throws {
    guard document.attempts[attemptIndex].state == "runtimeTerminal",
      document.attempts[attemptIndex].runtimeState == "succeeded"
    else {
      throw DriverFailure.message(
        "product verification requires a known succeeded Runtime terminal")
    }
    document.attempts[attemptIndex].state = "productVerified"
    document.attempts[attemptIndex].detail =
      "Runtime terminal and mandatory App postflight semantics both passed"
    document.state = "succeeded"
    try persist()
  }

  func recordFailure(_ error: Error) {
    let previous = document.attempts[attemptIndex].state
    if previous == "submissionRequested" {
      document.attempts[attemptIndex].state = "submissionOutcomeUnknown"
      document.attempts[attemptIndex].detail = String(describing: error)
      document.state = "runtimeContinuationRequired"
    } else if previous == "runtimeTerminal",
      document.attempts[attemptIndex].runtimeState == "succeeded"
    {
      document.attempts[attemptIndex].state = "productVerificationFailed"
      document.attempts[attemptIndex].detail = String(describing: error)
      document.state = "active"
    } else if previous != "runtimeTerminal" {
      document.attempts[attemptIndex].state = "refused"
      document.attempts[attemptIndex].detail = String(describing: error)
    }
    try? persist()
  }

  private func persist() throws {
    let data = try canonicalData(document)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

private final class AccessibilityDriver {
  private static let appKitFilePanelServiceBundleIdentifier =
    "com.apple.appkit.xpc.openAndSavePanelService"

  private let application: AXUIElement
  private let runningApplication: NSRunningApplication
  private let candidate: ManualUIFlashCandidateProgram

  init(processIdentifier: pid_t, candidate: ManualUIFlashCandidateProgram) throws {
    guard AXIsProcessTrusted() else {
      throw DriverFailure.message(
        "Accessibility access is required for the executable running this script")
    }
    guard let runningApplication = NSRunningApplication(processIdentifier: processIdentifier) else {
      throw DriverFailure.message("ArkDeck process is no longer running")
    }
    application = AXUIElementCreateApplication(processIdentifier)
    self.runningApplication = runningApplication
    self.candidate = candidate
  }

  func perform(
    _ identifier: String,
    delivery: CandidateControlDelivery,
    fallbackStrings: [String] = [],
    timeout: TimeInterval
  ) throws {
    switch delivery {
    case .accessibilityPress:
      try press(identifier, timeout: timeout)
    case .pointerClick:
      try click(identifier, fallbackStrings: fallbackStrings, timeout: timeout)
    }
  }

  func press(_ identifier: String, timeout: TimeInterval = 20) throws {
    try activateApplication()
    let element = try waitForElement(identifier: identifier, timeout: timeout)
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else {
      throw DriverFailure.message("could not press \(identifier): AX error \(result.rawValue)")
    }
  }

  /// Clicks the visual centre of an accessibility element.
  ///
  /// SwiftUI controls can report a successful AXPress without delivering the
  /// operator gesture. A real pointer click matches the interaction exercised
  /// by this manual, real-device driver.
  func click(
    _ identifier: String, fallbackStrings: [String] = [], timeout: TimeInterval = 20
  ) throws {
    let element = try waitForElement(
      identifier: identifier, fallbackStrings: fallbackStrings, timeout: timeout)
    try click(element, identifier: identifier)
  }

  /// Scrolls the element's containing area to the bottom before clicking it.
  func revealAndClick(_ identifier: String, timeout: TimeInterval = 20) throws {
    try activateApplication()
    let element = try waitForElement(identifier: identifier, timeout: timeout)
    try scrollToBottom(containing: element)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    try click(element, identifier: identifier)
  }

  /// Delivers the submit gesture exactly once. SwiftUI on macOS can expose a
  /// Button whose AX frame does not hit its visual action. In that case the
  /// same, now-visible AXButton receives AXPress, but only after proving the
  /// pointer path did not synchronously disable the control.
  func submit(_ identifier: String, timeout: TimeInterval = 20) throws {
    try activateApplication()
    let element = try waitForElement(identifier: identifier, timeout: timeout)
    try scrollToBottom(containing: element)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    try click(element, identifier: identifier)
    if observesSubmitStarted(identifier: identifier, timeout: 2) { return }

    let current = try waitForElement(identifier: identifier, timeout: 2)
    let pressed = AXUIElementPerformAction(current, kAXPressAction as CFString)
    guard pressed == .success,
      observesSubmitStarted(identifier: identifier, timeout: 10)
    else {
      let role = stringAttribute(current, kAXRoleAttribute as CFString) ?? "unknown"
      var rawActions: CFArray?
      AXUIElementCopyActionNames(current, &rawActions)
      let actions = (rawActions as? [String]) ?? []
      throw DriverFailure.message(
        "UI submit action was not delivered; role=\(role) frame=\(String(describing: frame(of: current))) "
          + "actions=\(actions) AXPress=\(pressed.rawValue)")
    }
  }

  private func observesSubmitStarted(identifier: String, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if element(identifier: "flash.execute.failure") != nil
        || element(identifier: "flash.execute.terminal") != nil
      {
        return true
      }
      guard let element = element(identifier: identifier) else { return true }
      if attribute(element, kAXEnabledAttribute as CFString) as? Bool == false { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    return false
  }

  private func click(_ element: AXUIElement, identifier: String) throws {
    try activateApplication()
    if let frame = frame(of: element), frame.width > 0, frame.height > 0 {
      let point = CGPoint(x: frame.midX, y: frame.midY)
      guard
        let down = CGEvent(
          mouseEventSource: nil, mouseType: .leftMouseDown,
          mouseCursorPosition: point, mouseButton: .left),
        let up = CGEvent(
          mouseEventSource: nil, mouseType: .leftMouseUp,
          mouseCursorPosition: point, mouseButton: .left)
      else {
        throw DriverFailure.message("could not create pointer events for \(identifier)")
      }
      down.post(tap: .cghidEventTap)
      up.post(tap: .cghidEventTap)
      return
    }

    // macOS 26 can flatten a SwiftUI NavigationSplitView label into an AXRow
    // whose visual frame is omitted even though it remains actionable. Keep
    // the native action/settable-selection fallback bounded to the exact
    // element found by identifier or localized visible text.
    let pressed = AXUIElementPerformAction(element, kAXPressAction as CFString)
    if pressed == .success { return }
    let selected = AXUIElementSetAttributeValue(
      element, kAXSelectedAttribute as CFString, kCFBooleanTrue)
    if selected == .success { return }

    let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? "unknown"
    throw DriverFailure.message(
      "UI element has no clickable frame or native selection action: \(identifier) "
        + "role=\(role) AXPress=\(pressed.rawValue) AXSelected=\(selected.rawValue)")
  }

  func setValue(_ value: String, identifier: String, timeout: TimeInterval = 20) throws {
    let element = try waitForElement(identifier: identifier, timeout: timeout)
    let result = AXUIElementSetAttributeValue(
      element, kAXValueAttribute as CFString, value as CFTypeRef)
    guard result == .success else {
      throw DriverFailure.message("could not set \(identifier): AX error \(result.rawValue)")
    }
  }

  func selectPickerValue(_ value: String, identifier: String) throws {
    try activateApplication()
    let element = try waitForElement(identifier: identifier, timeout: 20)
    if stringAttribute(element, kAXValueAttribute as CFString) == value { return }

    let role = stringAttribute(element, kAXRoleAttribute as CFString)
    if role == (kAXPopUpButtonRole as String) {
      let pressed = AXUIElementPerformAction(element, kAXPressAction as CFString)
      guard pressed == .success else {
        throw DriverFailure.message("could not open picker \(identifier)")
      }
      try type(value)
      try key(virtualCode: CGKeyCode(kVK_Return))
    } else {
      let direct = AXUIElementSetAttributeValue(
        element, kAXValueAttribute as CFString, value as CFTypeRef)
      guard direct == .success else {
        throw DriverFailure.message("could not set picker \(identifier)")
      }
    }

    guard observesPickerValue(value, identifier: identifier, timeout: 5) else {
      let observed = self.element(identifier: identifier).flatMap {
        stringAttribute($0, kAXValueAttribute as CFString)
      } ?? "unavailable"
      throw DriverFailure.message(
        "picker \(identifier) did not select \(value); observed \(observed)")
    }
  }

  private func observesPickerValue(
    _ expected: String, identifier: String, timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if let current = element(identifier: identifier),
        stringAttribute(current, kAXValueAttribute as CFString) == expected
      {
        return true
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    return false
  }

  func waitForFacts(_ facts: [String], timeout: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeout)
    var missing = facts
    repeat {
      let visible = allStrings()
      missing = facts.filter { fact in !visible.contains(where: { $0.contains(fact) }) }
      if missing.isEmpty { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    } while Date() < deadline
    throw DriverFailure.message(
      "UI did not expose expected facts before timeout: \(missing.joined(separator: ", "))")
  }

  func waitForValue(
    _ expected: String, identifier: String, timeout: TimeInterval
  ) throws {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if let current = element(identifier: identifier),
        stringAttribute(current, kAXValueAttribute as CFString) == expected
      {
        return
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    } while Date() < deadline
    throw DriverFailure.message(
      "UI element \(identifier) did not expose the expected value")
  }

  func waitForPresence(_ identifier: String, timeout: TimeInterval) throws {
    _ = try waitForElement(identifier: identifier, timeout: timeout)
  }

  func waitForSelected(_ identifier: String, timeout: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if let element = element(identifier: identifier) {
        let selected = attribute(element, kAXSelectedAttribute as CFString) as? Bool
        let numericValue = attribute(element, kAXValueAttribute as CFString) as? NSNumber
        if selected == true || numericValue?.boolValue == true { return }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    throw DriverFailure.message("UI element did not become selected: \(identifier)")
  }

  func waitForAbsence(_ identifier: String, timeout: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if element(identifier: identifier) == nil { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    } while Date() < deadline
    throw DriverFailure.message("UI element remained present: \(identifier)")
  }

  func waitForEnabled(_ identifier: String, timeout: TimeInterval) throws {
    try waitForEnabledState(true, identifier: identifier, timeout: timeout)
  }

  func waitForDisabled(_ identifier: String, timeout: TimeInterval) throws {
    try waitForEnabledState(false, identifier: identifier, timeout: timeout)
  }

  private func waitForEnabledState(
    _ expected: Bool, identifier: String, timeout: TimeInterval
  ) throws {
    if observesEnabledState(expected, identifier: identifier, timeout: timeout) { return }
    throw DriverFailure.message(
      "UI element \(identifier) did not become \(expected ? "enabled" : "disabled")")
  }

  private func observesEnabledState(
    _ expected: Bool, identifier: String, timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if let element = element(identifier: identifier),
        attribute(element, kAXEnabledAttribute as CFString) as? Bool == expected
      {
        return true
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    } while Date() < deadline
    return false
  }

  func openGoToFolder(timeout: TimeInterval) throws {
    try waitForExactApplicationOwnedFilePanel(
      containing: "OKButton", timeout: timeout)
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if element(identifier: "PathTextField") != nil { return }
      try keyForExactApplicationOwnedFilePanel(
        virtualCode: CGKeyCode(kVK_ANSI_G), flags: [.maskCommand, .maskShift],
        containing: "OKButton")
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    } while Date() < deadline
    throw DriverFailure.message("file picker did not open the Go to Folder path field")
  }

  func commitGoToFolder(timeout: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if element(identifier: "PathTextField") == nil { return }
      try keyForExactApplicationOwnedFilePanel(
        virtualCode: CGKeyCode(kVK_Return), containing: "PathTextField")
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    } while Date() < deadline
    throw DriverFailure.message("file picker did not accept the Go to Folder path")
  }

  /// Waits only on the post-submit presentation owned by the current review.
  /// Historical Runtime cards deliberately do not participate in this check.
  func waitForFlashSubmission(timeout: TimeInterval) throws -> (jobID: String, state: String) {
    let deadline = Date().addingTimeInterval(timeout)
    let terminalStates = ["succeeded", "failed", "waitingForRecovery", "cancelled"]
    repeat {
      if let failure = element(identifier: "flash.execute.failure") {
        let detail = strings(near: failure)
          .filter { !$0.isEmpty && $0 != "flash.execute.failure" }
          .joined(separator: " | ")
        throw DriverFailure.message(
          "Runtime Flash submission failed before returning a Job: \(detail)")
      }
      if let job = element(identifier: "flash.execute.jobId"),
        let terminal = element(identifier: "flash.execute.terminal")
      {
        let jobID = strings(near: job).first { $0.hasPrefix("job-") }
        let terminalStrings = strings(near: terminal)
        let state = terminalStates.first { state in
          terminalStrings.contains(where: { $0 == state || $0.contains(state) })
        }
        if let jobID, let state { return (jobID, state) }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    } while Date() < deadline
    throw DriverFailure.message(
      "current UI submission did not return a terminal Runtime Flash result before timeout")
  }

  /// Runtime success proves the device operation. It does not prove that the
  /// candidate App presents the resulting build and rebinding correctly. Both
  /// semantic rows are mandatory product criteria owned by the protected
  /// driver, so an untrusted candidate cannot omit them from its program.
  func waitForProductPostflight(timeout: TimeInterval) throws {
    try waitForPresence("flash.postflight", timeout: timeout)
    try waitForPresence("flash.postflight.build.match", timeout: timeout)
    try waitForPresence("flash.postflight.binding.match", timeout: timeout)
    if element(identifier: "flash.postflight.build.mismatch") != nil
      || element(identifier: "flash.postflight.binding.mismatch") != nil
    {
      throw DriverFailure.message(
        "Runtime succeeded but the candidate App presented a postflight mismatch")
    }
  }

  func assertNoFlashSubmission() throws {
    let forbidden = [
      "flash.execute.failure", "flash.execute.jobId", "flash.execute.terminal",
    ]
    if let exposed = forbidden.first(where: { element(identifier: $0) != nil }) {
      throw DriverFailure.message(
        "Flash UI exposed \(exposed) before the one-click submit action")
    }
  }

  /// Keeps a repeated manual validation idempotent when the exact archive is
  /// already selected in the same App workspace. The filename is only a
  /// reason to skip reopening the system panel: the plan, archive and step-set
  /// digests are still verified below before submit can become eligible.
  func chooseFileIfNeeded(
    _ url: URL, delivery: CandidateControlDelivery, timeout: TimeInterval
  ) throws {
    if let current = element(identifier: "flash.image.value"),
      stringAttribute(current, kAXValueAttribute as CFString) == url.lastPathComponent
    {
      return
    }
    try chooseFile(url, delivery: delivery, timeout: timeout)
  }

  func chooseFile(
    _ url: URL, delivery: CandidateControlDelivery, timeout: TimeInterval
  ) throws {
    try perform("flash.image.choose", delivery: delivery, timeout: timeout)
    // On macOS 26 NSSavePanel is hosted by a remote view. Its undocumented
    // `open-panel` identifier is no longer a descendant of the owning App,
    // even though the button action has synchronously entered runModal().
    // The Go-to-Folder field and OK button are the stable, actionable panel
    // contract. If the pointer action did not open a panel, this bounded
    // shortcut probe fails without selecting or submitting anything.
    try openGoToFolder(timeout: timeout)
    try setValue(url.path, identifier: "PathTextField")
    try commitGoToFolder(timeout: timeout)
    try waitForEnabled("OKButton", timeout: timeout)
    try pressExactApplicationOwnedFilePanel("OKButton", timeout: timeout)
    // Prove that the owning workspace accepted the pinned file. Merely seeing
    // the filename in the remote panel would be a false positive.
    try waitForValue(
      url.lastPathComponent, identifier: "flash.image.value", timeout: max(timeout, 30))
  }

  private func waitForElement(
    identifier: String, fallbackStrings: [String] = [], timeout: TimeInterval
  ) throws -> AXUIElement {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if let element = element(identifier: identifier) { return element }
      if let element = element(displayingNavigationFallback: fallbackStrings) { return element }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    } while Date() < deadline
    throw DriverFailure.message("UI element not found: \(identifier)")
  }

  private func element(identifier: String) -> AXUIElement? {
    descendants(of: application).first {
      stringAttribute($0, kAXIdentifierAttribute as CFString) == identifier
    }
  }

  /// Finds the one localized sidebar destination admitted by the candidate
  /// grammar when SwiftUI does not publish its accessibility identifier.
  ///
  /// macOS 26 can flatten a NavigationLink into an AXRow whose computed label
  /// includes its symbol or surrounding whitespace.  Match only selectable
  /// control roles, prefer rows, and inspect their bounded descendant strings;
  /// a window or workspace paragraph containing the word "Flash" must never
  /// become the click target.
  private func element(displayingNavigationFallback fallbackStrings: [String]) -> AXUIElement? {
    guard !fallbackStrings.isEmpty else { return nil }
    let expected = fallbackStrings.map(normalizedNavigationText)
    let candidates = descendants(of: application)
    let permittedRoles = [
      kAXRowRole as String, kAXButtonRole as String,
    ]

    for role in permittedRoles {
      for element in candidates
      where stringAttribute(element, kAXRoleAttribute as CFString) == role {
        let observed = strings(near: element).map(normalizedNavigationText)
        if observed.contains(where: { value in
          expected.contains(where: { value == $0 || value.contains($0) })
        }) {
          return element
        }
      }
    }
    return nil
  }

  private func normalizedNavigationText(_ value: String) -> String {
    value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func descendants(of root: AXUIElement) -> [AXUIElement] {
    var result: [AXUIElement] = [root]
    var visited: Set<CFHashCode> = [CFHash(root)]
    var cursor = 0
    while cursor < result.count, result.count < 10_000 {
      if let children = attribute(result[cursor], kAXChildrenAttribute as CFString)
        as? [AXUIElement]
      {
        for child in children where visited.insert(CFHash(child)).inserted {
          result.append(child)
        }
      }
      cursor += 1
    }
    return result
  }

  private func allStrings() -> [String] {
    let attributes = [
      kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
      kAXValueAttribute, kAXHelpAttribute,
    ].map { $0 as CFString }
    return descendants(of: application).flatMap { element in
      attributes.compactMap { stringAttribute(element, $0) }
    }
  }

  private func strings(near element: AXUIElement) -> [String] {
    let attributes = [
      kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
      kAXValueAttribute, kAXHelpAttribute,
    ].map { $0 as CFString }
    return descendants(of: element).flatMap { descendant in
      attributes.compactMap { stringAttribute(descendant, $0) }
    }
  }

  private func frame(of element: AXUIElement) -> CGRect? {
    guard
      let positionValue = attribute(element, kAXPositionAttribute as CFString),
      CFGetTypeID(positionValue) == AXValueGetTypeID(),
      let sizeValue = attribute(element, kAXSizeAttribute as CFString),
      CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else { return nil }

    var position = CGPoint.zero
    var size = CGSize.zero
    guard
      AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
      AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: position, size: size)
  }

  private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value
  }

  private func activateApplication() throws {
    guard runningApplication.activate(options: [.activateAllWindows]) else {
      throw DriverFailure.message("could not activate the exact ArkDeck application")
    }
    let frontmostSet = AXUIElementSetAttributeValue(
      application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    guard frontmostSet == .success else {
      throw DriverFailure.message(
        "could not make the exact ArkDeck application frontmost: AX error \(frontmostSet.rawValue)")
    }

    var raiseResult: AXError?
    if candidate.applicationActivation == .activateAndRaise {
      var window: AXUIElement?
      if let rawFocused = attribute(application, kAXFocusedWindowAttribute as CFString),
        CFGetTypeID(rawFocused) == AXUIElementGetTypeID()
      {
        window = (rawFocused as! AXUIElement)
      } else if let rawWindows = attribute(application, kAXWindowsAttribute as CFString),
        let windows = rawWindows as? [AXUIElement]
      {
        window = windows.first
      }
      guard let window else {
        throw DriverFailure.message("the exact ArkDeck application has no interactive window")
      }
      raiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
    RunLoop.current.run(
      until: Date().addingTimeInterval(
        TimeInterval(candidate.activationSettleMilliseconds) / 1_000))
    let observedFrontmost = attribute(application, kAXFrontmostAttribute as CFString) as? Bool
    let raiseDetail = raiseResult.map { String($0.rawValue) } ?? "notRequested"
    do {
      try requireExactApplicationFrontmost()
    } catch {
      throw DriverFailure.message(
        "the exact ArkDeck application did not remain frontmost "
          + "[isActive=\(runningApplication.isActive) "
          + "frontmost=\(String(describing: observedFrontmost)) "
          + "AXRaise=\(raiseDetail)]")
    }
  }

  private func requireExactApplicationFrontmost() throws {
    let observedFrontmost = attribute(application, kAXFrontmostAttribute as CFString) as? Bool
    guard runningApplication.isActive, observedFrontmost == true,
      NSWorkspace.shared.frontmostApplication?.processIdentifier
        == runningApplication.processIdentifier
    else {
      throw DriverFailure.message(
        "exact ArkDeck process did not become frontmost; no global input was dispatched")
    }
  }

  /// macOS 26 hosts NSSavePanel in AppKit's open/save XPC service. Opening the
  /// remote panel may leave some other application reported as frontmost even
  /// though the panel and its controls remain in the exact ArkDeck AX tree.
  /// Before dispatching a global shortcut, raise the AXWindow that owns the
  /// stable panel control, activate the exact reviewed App, and prove that the
  /// same owned window became focused. This retains the exact-App boundary
  /// without trusting stale NSWorkspace foreground state.
  private func requireExactApplicationOwnedFilePanel(containing identifier: String) throws {
    guard !runningApplication.isTerminated,
      let okButton = element(identifier: "OKButton"),
      let requiredControl = element(identifier: identifier),
      let panel = elementAttribute(okButton, kAXWindowAttribute as CFString),
      let requiredWindow = elementAttribute(requiredControl, kAXWindowAttribute as CFString),
      isSameExactApplicationWindow(panel, requiredWindow)
    else {
      throw DriverFailure.message(
        "exact ArkDeck application does not own the expected system file panel")
    }

    let raised = AXUIElementPerformAction(panel, kAXRaiseAction as CFString)
    if raised != .success {
      throw DriverFailure.message(
        "could not focus the exact ArkDeck system file panel")
    }
    guard runningApplication.activate(options: [.activateAllWindows]) else {
      throw DriverFailure.message(
        "could not focus the exact ArkDeck system file panel")
    }
    RunLoop.current.run(
      until: Date().addingTimeInterval(
        TimeInterval(candidate.activationSettleMilliseconds) / 1_000))

    guard
      let focusedWindow = elementAttribute(application, kAXFocusedWindowAttribute as CFString),
      isSameExactApplicationWindow(panel, focusedWindow)
    else {
      throw DriverFailure.message(
        "exact ArkDeck system file panel did not become the focused App window")
    }

    guard let frontmost = NSWorkspace.shared.frontmostApplication,
      frontmost.processIdentifier == runningApplication.processIdentifier
        || frontmost.bundleIdentifier == Self.appKitFilePanelServiceBundleIdentifier
    else {
      throw DriverFailure.message(
        "an unrelated application remained frontmost; no file-panel input was dispatched")
    }
  }

  private func elementAttribute(_ element: AXUIElement, _ name: CFString) -> AXUIElement? {
    guard let raw = attribute(element, name),
      CFGetTypeID(raw) == AXUIElementGetTypeID()
    else { return nil }
    return (raw as! AXUIElement)
  }

  private func isSameExactApplicationWindow(
    _ lhs: AXUIElement, _ rhs: AXUIElement
  ) -> Bool {
    var lhsPID: pid_t = 0
    var rhsPID: pid_t = 0
    guard AXUIElementGetPid(lhs, &lhsPID) == .success,
      AXUIElementGetPid(rhs, &rhsPID) == .success,
      lhsPID == runningApplication.processIdentifier,
      rhsPID == runningApplication.processIdentifier,
      stringAttribute(lhs, kAXRoleAttribute as CFString) == (kAXWindowRole as String),
      stringAttribute(rhs, kAXRoleAttribute as CFString) == (kAXWindowRole as String),
      let lhsIdentifier = stringAttribute(lhs, kAXIdentifierAttribute as CFString),
      !lhsIdentifier.isEmpty,
      lhsIdentifier == stringAttribute(rhs, kAXIdentifierAttribute as CFString),
      stringAttribute(lhs, kAXTitleAttribute as CFString)
        == stringAttribute(rhs, kAXTitleAttribute as CFString)
    else { return false }
    return true
  }

  private func waitForExactApplicationOwnedFilePanel(
    containing identifier: String, timeout: TimeInterval
  ) throws {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if (try? requireExactApplicationOwnedFilePanel(containing: identifier)) != nil { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    } while Date() < deadline
    throw DriverFailure.message(
      "exact ArkDeck application did not expose its system file panel before timeout")
  }

  private func keyForExactApplicationOwnedFilePanel(
    virtualCode: CGKeyCode, flags: CGEventFlags = [], containing identifier: String
  ) throws {
    try requireExactApplicationOwnedFilePanel(containing: identifier)
    let down = CGEvent(keyboardEventSource: nil, virtualKey: virtualCode, keyDown: true)
    down?.flags = flags
    down?.post(tap: .cghidEventTap)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: virtualCode, keyDown: false)
    up?.flags = flags
    up?.post(tap: .cghidEventTap)
  }

  private func pressExactApplicationOwnedFilePanel(
    _ identifier: String, timeout: TimeInterval
  ) throws {
    try waitForExactApplicationOwnedFilePanel(containing: identifier, timeout: timeout)
    try requireExactApplicationOwnedFilePanel(containing: identifier)
    let element = try waitForElement(identifier: identifier, timeout: timeout)
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else {
      throw DriverFailure.message(
        "could not press owned file-panel control \(identifier): AX error \(result.rawValue)")
    }
  }

  private func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
    let value = attribute(element, name)
    if let string = value as? String { return string }
    if let attributed = value as? NSAttributedString { return attributed.string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
  }

  private func key(virtualCode: CGKeyCode, flags: CGEventFlags = []) throws {
    try requireExactApplicationFrontmost()
    let down = CGEvent(keyboardEventSource: nil, virtualKey: virtualCode, keyDown: true)
    down?.flags = flags
    down?.post(tap: .cghidEventTap)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: virtualCode, keyDown: false)
    up?.flags = flags
    up?.post(tap: .cghidEventTap)
  }

  private func scrollDown() throws {
    try requireExactApplicationFrontmost()
    CGEvent(
      scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
      wheel1: -6, wheel2: 0, wheel3: 0
    )?.post(tap: .cghidEventTap)
  }

  private func scrollToBottom(containing element: AXUIElement) throws {
    var current: AXUIElement? = element
    for _ in 0..<30 {
      guard let scope = current else { break }
      if stringAttribute(scope, kAXRoleAttribute as CFString) == (kAXScrollAreaRole as String),
        let rawScrollBar = attribute(scope, kAXVerticalScrollBarAttribute as CFString),
        CFGetTypeID(rawScrollBar) == AXUIElementGetTypeID()
      {
        let scrollBar = rawScrollBar as! AXUIElement
        if AXUIElementSetAttributeValue(
          scrollBar, kAXValueAttribute as CFString, NSNumber(value: 1)) == .success
        {
          return
        }
      }
      if let parent = attribute(scope, kAXParentAttribute as CFString),
        CFGetTypeID(parent) == AXUIElementGetTypeID()
      {
        current = (parent as! AXUIElement)
      } else {
        current = nil
      }
    }
    try scrollDown()
  }

  private func type(_ text: String) throws {
    try requireExactApplicationFrontmost()
    let units = Array(text.utf16)
    let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
    units.withUnsafeBufferPointer { buffer in
      event?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
    }
    event?.post(tap: .cghidEventTap)
  }
}

private func isSameApplication(_ lhs: URL, _ rhs: URL) -> Bool {
  let lhs = lhs.standardizedFileURL.resolvingSymlinksInPath()
  let rhs = rhs.standardizedFileURL.resolvingSymlinksInPath()
  if lhs == rhs { return true }

  let key = URLResourceKey.fileResourceIdentifierKey
  let lhsIdentifier = try? lhs.resourceValues(forKeys: [key]).fileResourceIdentifier
  let rhsIdentifier = try? rhs.resourceValues(forKeys: [key]).fileResourceIdentifier
  guard let lhsIdentifier, let rhsIdentifier else { return false }
  return lhsIdentifier.isEqual(rhsIdentifier)
}

func launch(_ appURL: URL, requireFreshCandidate: Bool) throws -> pid_t {
  if let running = NSWorkspace.shared.runningApplications.first(where: {
    guard let bundleURL = $0.bundleURL else { return false }
    return isSameApplication(bundleURL, appURL)
  }) {
    let executableModified = Bundle(url: appURL)?.executableURL.flatMap {
      try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
    let loadedCandidateIsStale = running.launchDate.map { launchDate in
      executableModified.map { $0 > launchDate } ?? false
    } ?? false
    if requireFreshCandidate || loadedCandidateIsStale {
      guard running.terminate() else {
        throw DriverFailure.message("could not terminate the exact stale candidate App")
      }
      let deadline = Date().addingTimeInterval(10)
      while !running.isTerminated, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
      }
      guard running.isTerminated else {
        throw DriverFailure.message("exact stale candidate App did not terminate cleanly")
      }
    } else {
      running.activate(options: [.activateAllWindows])
      return running.processIdentifier
    }
  }

  let semaphore = DispatchSemaphore(value: 0)
  var launched: NSRunningApplication?
  var launchError: Error?
  let configuration = NSWorkspace.OpenConfiguration()
  configuration.activates = true
  NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
    launched = app
    launchError = error
    semaphore.signal()
  }
  semaphore.wait()
  if let launchError { throw launchError }
  guard let launched else { throw DriverFailure.message("ArkDeck did not launch") }
  guard let launchedURL = launched.bundleURL,
    isSameApplication(launchedURL, appURL)
  else {
    throw DriverFailure.message(
      "Launch Services opened a different ArkDeck instance; close duplicate bundle IDs and retry")
  }
  return launched.processIdentifier
}

func run() throws {
  let protectedMainCommitOID = try protectedMainActuatorCommit()
  let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
  let candidate = try loadCandidateProgram(at: options.candidateURL)
  let appExecutableSHA256 = try applicationExecutableSHA256(options.appURL)
  let session = try options.debugSessionURL.map {
    try ManualUIDebugSessionRecorder(
      url: $0, options: options, candidate: candidate,
      appExecutableSHA256: appExecutableSHA256,
      protectedMainCommitOID: protectedMainCommitOID)
  }
  do {
    if let session {
      print(
        "AGENT_DEBUG_CANDIDATE: invocation=\(session.invocationID) "
          + "program=\(candidate.programSHA256) app=\(appExecutableSHA256) "
          + "protectedMain=\(protectedMainCommitOID) externalDispatch=0")
    }
    let controlTimeout = TimeInterval(candidate.program.controlTimeoutSeconds)
    let planTimeout = TimeInterval(candidate.program.planTimeoutSeconds)
    let pid = try launch(
      options.appURL, requireFreshCandidate: session?.requiresFreshCandidateApp == true)
    guard try applicationExecutableSHA256(options.appURL) == appExecutableSHA256 else {
      throw DriverFailure.message("candidate App executable changed before UI activation")
    }
    let driver = try AccessibilityDriver(
      processIdentifier: pid, candidate: candidate.program)

    // The candidate composes only pre-submit UI effects. It cannot supply a
    // target, archive, plan value or submit action; those values are injected
    // below from the protected invocation and independently re-verified after
    // the program completes.
    for action in candidate.program.actions {
      switch action.kind {
      case .perform:
        try driver.perform(
          action.identifier!, delivery: action.delivery!,
          fallbackStrings: action.fallbackStrings!, timeout: controlTimeout)
      case .waitForPresence:
        try driver.waitForPresence(action.identifier!, timeout: controlTimeout)
      case .waitForAbsence:
        try driver.waitForAbsence(action.identifier!, timeout: controlTimeout)
      case .waitForEnabled:
        try driver.waitForEnabled(action.identifier!, timeout: controlTimeout)
      case .waitForDisabled:
        try driver.waitForDisabled(action.identifier!, timeout: controlTimeout)
      case .waitForSelected:
        try driver.waitForSelected(action.identifier!, timeout: controlTimeout)
      case .choosePinnedArchive:
        try driver.chooseFileIfNeeded(
          options.archiveURL, delivery: action.delivery!, timeout: controlTimeout)
      case .selectPinnedTarget:
        try driver.selectPickerValue(options.expectedTargetID, identifier: "flash.target")
      case .waitForPinnedPlan:
        try driver.waitForFacts(
          [
            options.archiveURL.lastPathComponent,
            options.expectedPlanDigest,
            options.expectedArchiveDigest,
            options.expectedStepSetDigest,
            options.expectedTargetID,
            String(options.expectedBindingRevision),
          ],
          timeout: planTimeout)
      }
    }

    try driver.waitForFacts(
      [
        options.expectedPlanDigest,
        options.expectedArchiveDigest,
        options.expectedStepSetDigest,
        options.expectedTargetID,
      ],
      timeout: controlTimeout)
    try driver.waitForPresence("flash.impact.userdata", timeout: controlTimeout)
    try driver.waitForAbsence("flash.confirm.sheet", timeout: 1)
    try driver.waitForPresence("flash.execute.submit", timeout: controlTimeout)
    try driver.waitForEnabled("flash.execute.submit", timeout: controlTimeout)
    try driver.assertNoFlashSubmission()
    guard try applicationExecutableSHA256(options.appURL) == appExecutableSHA256 else {
      throw DriverFailure.message("candidate App executable changed before submit barrier")
    }
    try session?.markUIReady()
    if options.stopBeforeSubmit {
      print(
        "UI_REVIEW_PASS: exact typed Flash request is ready for one-click submit; "
          + "no Runtime Job is exposed before the button is pressed")
      return
    }
    print("UI_REVIEW_PASS: submitting the exact typed Flash request with one ArkDeck UI click")
    try session?.markSubmissionRequested()
    try driver.submit("flash.execute.submit")
    let submission = try driver.waitForFlashSubmission(timeout: options.timeoutSeconds)
    try session?.markRuntimeTerminal(jobID: submission.jobID, state: submission.state)
    guard submission.state == "succeeded" else {
      throw DriverFailure.message(
        "Runtime Flash Job \(submission.jobID) stopped in \(submission.state); "
          + "continue through the captured Runtime debug seed without an intermediate PR")
    }
    try driver.waitForProductPostflight(timeout: controlTimeout)
    try session?.markProductVerified()
    print(
      "REAL_DEVICE_PASS: ArkDeck UI Flash Runtime Job \(submission.jobID) succeeded "
        + "and mandatory App postflight semantics matched")
  } catch {
    session?.recordFailure(error)
    throw error
  }
}

func runFlashBridge(_ arguments: [String]) throws -> Never {
  let protectedMainCommitOID = try protectedMainActuatorCommit()
  var values: [String: String] = [:]
  var index = 0
  while index < arguments.count {
    let key = arguments[index]
    guard ["--socket", "--capture-debug-seed"].contains(key),
      values[key] == nil, index + 1 < arguments.count
    else {
      throw DriverFailure.message(
        "usage: manual_ui_flash --xpc-flash-bridge --socket <existing-agentd.sock> "
          + "[--capture-debug-seed <absolute-request.json>]")
    }
    values[key] = arguments[index + 1]
    index += 2
  }
  guard let socketPath = values["--socket"] else {
    throw DriverFailure.message(
      "usage: manual_ui_flash --xpc-flash-bridge --socket <existing-agentd.sock> "
        + "[--capture-debug-seed <absolute-request.json>]")
  }
  guard socketPath.hasPrefix("/"), FileManager.default.fileExists(atPath: socketPath) else {
    throw DriverFailure.message("Flash bridge requires an existing absolute Runtime socket")
  }
  var captureURL: URL?
  if let path = values["--capture-debug-seed"] {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let parent = url.deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    guard path.hasPrefix("/"),
      FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw DriverFailure.message(
        "--capture-debug-seed requires an absolute path in an existing directory")
    }
    captureURL = url
  }
  print(
    "manual_ui_flash: bounded App XPC bridge -> \(socketPath) "
      + "protectedMain=\(protectedMainCommitOID)")
  return ManualFlashXPCBridge(
    socketPath: socketPath, captureDebugSeedURL: captureURL
  ).run()
}

func validateCandidate(_ arguments: [String]) throws {
  guard arguments.count == 1, arguments[0].hasPrefix("/") else {
    throw DriverFailure.message(
      "usage: manual_ui_flash --validate-candidate <absolute-candidate.json>")
  }
  let loaded = try loadCandidateProgram(
    at: URL(fileURLWithPath: arguments[0]).standardizedFileURL)
  print(
    "CANDIDATE_VALID: program=\(loaded.programSHA256) "
      + "protectedActuator=\(loaded.actuatorSHA256)")
}

func printDebugSessionStatus(_ arguments: [String]) throws {
  guard arguments.count == 1, arguments[0].hasPrefix("/") else {
    throw DriverFailure.message(
      "usage: manual_ui_flash --debug-session-status <absolute-session.json>")
  }
  let url = URL(fileURLWithPath: arguments[0]).standardizedFileURL
  let document = try JSONDecoder().decode(
    ManualUIDebugSessionDocument.self, from: Data(contentsOf: url))
  FileHandle.standardOutput.write(try canonicalData(document))
  FileHandle.standardOutput.write(Data("\n".utf8))
}

func requestAccessibilityPermission() -> Never {
  let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
  let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
  if trusted {
    print("manual_ui_flash: Accessibility access is already enabled")
    exit(0)
  }
  fputs(
    "manual_ui_flash: enable Manual UI Flash Driver in System Settings > "
      + "Privacy & Security > Accessibility, then run the driver again\n",
    stderr)
  exit(3)
}

do {
  let invocation = try manualUIAOTInvocation(Array(CommandLine.arguments.dropFirst()))
  let arguments = invocation.arguments
  if arguments == ["--request-accessibility"] {
    requestAccessibilityPermission()
  } else if arguments.first == "--xpc-flash-bridge" {
    if !invocation.isAOTChild {
      _ = try protectedMainActuatorCommit()
      try reexecManualUIAOT(arguments: arguments)
    }
    try runFlashBridge(Array(arguments.dropFirst()))
  } else if arguments == ["--validate-xpc-interface"] {
    if !invocation.isAOTChild {
      try reexecManualUIAOT(arguments: arguments)
    }
    validateManualFlashXPCInterface()
  } else if arguments.first == "--validate-candidate" {
    try validateCandidate(Array(arguments.dropFirst()))
  } else if arguments.first == "--debug-session-status" {
    try printDebugSessionStatus(Array(arguments.dropFirst()))
  } else {
    try run()
  }
} catch {
  fputs("manual_ui_flash: \(error)\n", stderr)
  exit(2)
}

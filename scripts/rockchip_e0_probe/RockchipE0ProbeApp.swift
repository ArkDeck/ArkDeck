import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

private let pinnedExecutableSHA256 =
  "bbd7bdc0fb121d414fb61085e77211cc1fdd9a3b6c6b285c54380f70e56c9923"
private let exactArguments = ["ld"]

private struct ProbeEnvelope: Codable {
  let schemaVersion: String
  let selectionCompleted: Bool
  let selectedPath: String?
  let bookmarkCreated: Bool
  let securityScopeStarted: Bool
  let executableSHA256: String?
  let signatureIntegrityValid: Bool?
  let quarantinePresent: Bool?
  let preflightFailure: String?
  let exactArguments: [String]
  let childLaunchAttempted: Bool
  let termination: String?
  let exitCode: Int32?
  let stdoutBase64: String
  let stderrBase64: String
  let launchErrorDomain: String?
  let launchErrorCode: Int?
}

private enum ProbeOutputStream {
  case stdout
  case stderr
}

private final class ProbeOutputCapture: @unchecked Sendable {
  private static let maximumStoredBytes = 64 * 1024 + 1

  private let lock = NSLock()
  private var stdout = Data()
  private var stderr = Data()

  func append(_ bytes: Data, to stream: ProbeOutputStream) {
    lock.lock()
    defer { lock.unlock() }

    let remaining = max(0, Self.maximumStoredBytes - stdout.count - stderr.count)
    guard remaining > 0 else { return }
    let storedBytes = bytes.prefix(remaining)
    switch stream {
    case .stdout: stdout.append(contentsOf: storedBytes)
    case .stderr: stderr.append(contentsOf: storedBytes)
    }
  }

  func snapshot() -> (stdout: Data, stderr: Data) {
    lock.lock()
    defer { lock.unlock() }
    return (stdout, stderr)
  }
}

@main
private enum RockchipE0ProbeApp {
  static func main() {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    application.activate()

    let panel = NSOpenPanel()
    panel.title = "Select the pinned rkdeveloptool for the E0 read-only probe"
    panel.message = "The signed Sandbox target will invoke only: rkdeveloptool ld"
    panel.prompt = "Select rkdeveloptool"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    if CommandLine.arguments.count == 2 {
      let initialDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
      if initialDirectory.path.hasPrefix("/") { panel.directoryURL = initialDirectory }
    }

    guard panel.runModal() == .OK, let selectedURL = panel.url else {
      emit(
        ProbeEnvelope(
          schemaVersion: "1.0.0", selectionCompleted: false, selectedPath: nil,
          bookmarkCreated: false, securityScopeStarted: false, executableSHA256: nil,
          signatureIntegrityValid: nil, quarantinePresent: nil,
          preflightFailure: "selectionCancelled", exactArguments: exactArguments,
          childLaunchAttempted: false, termination: nil, exitCode: nil,
          stdoutBase64: "", stderrBase64: "", launchErrorDomain: nil,
          launchErrorCode: nil))
      return
    }

    let selectedScope = selectedURL.startAccessingSecurityScopedResource()
    defer {
      if selectedScope { selectedURL.stopAccessingSecurityScopedResource() }
    }

    do {
      let bookmark = try selectedURL.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil)
      var stale = false
      let resolvedURL = try URL(
        resolvingBookmarkData: bookmark,
        options: [.withSecurityScope, .withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &stale)
      guard !stale else {
        emitPreflightFailure(
          selectedURL: selectedURL, scopeStarted: selectedScope,
          failure: "securityScopedBookmarkStale")
        return
      }
      guard
        resolvedURL.resolvingSymlinksInPath().standardizedFileURL
          == selectedURL.resolvingSymlinksInPath().standardizedFileURL
      else {
        emitPreflightFailure(
          selectedURL: selectedURL, scopeStarted: selectedScope,
          failure: "securityScopedBookmarkPathMismatch")
        return
      }

      let resolvedScope = resolvedURL.startAccessingSecurityScopedResource()
      defer {
        if resolvedScope { resolvedURL.stopAccessingSecurityScopedResource() }
      }
      let executableHash = try sha256(of: resolvedURL)
      let signatureValid = signatureIntegrityIsValid(at: resolvedURL)
      let hasQuarantine = quarantineIsPresent(at: resolvedURL)
      guard executableHash == pinnedExecutableSHA256 else {
        emitPreflightFailure(
          selectedURL: selectedURL, scopeStarted: selectedScope || resolvedScope,
          executableHash: executableHash, signatureValid: signatureValid,
          quarantinePresent: hasQuarantine, failure: "executableHashMismatch")
        return
      }
      guard signatureValid else {
        emitPreflightFailure(
          selectedURL: selectedURL, scopeStarted: selectedScope || resolvedScope,
          executableHash: executableHash, signatureValid: false,
          quarantinePresent: hasQuarantine, failure: "signatureIntegrityInvalid")
        return
      }
      guard !hasQuarantine else {
        emitPreflightFailure(
          selectedURL: selectedURL, scopeStarted: selectedScope || resolvedScope,
          executableHash: executableHash, signatureValid: true,
          quarantinePresent: true, failure: "quarantinePresent")
        return
      }
      runReadOnlyProbe(
        selectedURL: selectedURL,
        executableURL: resolvedURL,
        scopeStarted: selectedScope || resolvedScope,
        executableHash: executableHash,
        signatureValid: signatureValid,
        quarantinePresent: hasQuarantine)
    } catch let error as NSError {
      emit(
        ProbeEnvelope(
          schemaVersion: "1.0.0", selectionCompleted: true,
          selectedPath: selectedURL.path, bookmarkCreated: false,
          securityScopeStarted: selectedScope, executableSHA256: nil,
          signatureIntegrityValid: nil, quarantinePresent: nil,
          preflightFailure: "bookmarkCreationOrResolutionFailed",
          exactArguments: exactArguments, childLaunchAttempted: false,
          termination: nil, exitCode: nil, stdoutBase64: "", stderrBase64: "",
          launchErrorDomain: error.domain, launchErrorCode: error.code))
    }
  }

  private static func runReadOnlyProbe(
    selectedURL: URL,
    executableURL: URL,
    scopeStarted: Bool,
    executableHash: String,
    signatureValid: Bool,
    quarantinePresent: Bool
  ) {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = exactArguments
    process.environment = [:]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    do {
      try process.run()
      try? stdout.fileHandleForWriting.close()
      try? stderr.fileHandleForWriting.close()

      let outputCapture = ProbeOutputCapture()
      let readers = DispatchGroup()
      startReader(
        for: stdout.fileHandleForReading, stream: .stdout,
        capture: outputCapture, group: readers)
      startReader(
        for: stderr.fileHandleForReading, stream: .stderr,
        capture: outputCapture, group: readers)

      let deadline = Date().addingTimeInterval(5)
      while process.isRunning && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
      }
      var termination = "exited"
      if process.isRunning {
        termination = "timedOut"
        process.terminate()
        let terminationDeadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < terminationDeadline {
          RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      }
      process.waitUntilExit()
      readers.wait()
      let output = outputCapture.snapshot()
      emit(
        ProbeEnvelope(
          schemaVersion: "1.0.0", selectionCompleted: true,
          selectedPath: selectedURL.path, bookmarkCreated: true,
          securityScopeStarted: scopeStarted, executableSHA256: executableHash,
          signatureIntegrityValid: signatureValid, quarantinePresent: quarantinePresent,
          preflightFailure: nil, exactArguments: exactArguments,
          childLaunchAttempted: true, termination: termination,
          exitCode: process.terminationStatus,
          stdoutBase64: output.stdout.base64EncodedString(),
          stderrBase64: output.stderr.base64EncodedString(),
          launchErrorDomain: nil, launchErrorCode: nil))
    } catch let error as NSError {
      emit(
        ProbeEnvelope(
          schemaVersion: "1.0.0", selectionCompleted: true,
          selectedPath: selectedURL.path, bookmarkCreated: true,
          securityScopeStarted: scopeStarted, executableSHA256: executableHash,
          signatureIntegrityValid: signatureValid, quarantinePresent: quarantinePresent,
          preflightFailure: nil, exactArguments: exactArguments,
          childLaunchAttempted: true, termination: "launchFailed", exitCode: nil,
          stdoutBase64: "", stderrBase64: "", launchErrorDomain: error.domain,
          launchErrorCode: error.code))
    }
  }

  private static func startReader(
    for handle: FileHandle,
    stream: ProbeOutputStream,
    capture: ProbeOutputCapture,
    group: DispatchGroup
  ) {
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      defer { group.leave() }
      while let bytes = try? handle.read(upToCount: 4 * 1024), !bytes.isEmpty {
        capture.append(bytes, to: stream)
      }
    }
  }

  private static func emitPreflightFailure(
    selectedURL: URL,
    scopeStarted: Bool,
    executableHash: String? = nil,
    signatureValid: Bool? = nil,
    quarantinePresent: Bool? = nil,
    failure: String
  ) {
    emit(
      ProbeEnvelope(
        schemaVersion: "1.0.0", selectionCompleted: true,
        selectedPath: selectedURL.path, bookmarkCreated: true,
        securityScopeStarted: scopeStarted, executableSHA256: executableHash,
        signatureIntegrityValid: signatureValid, quarantinePresent: quarantinePresent,
        preflightFailure: failure, exactArguments: exactArguments,
        childLaunchAttempted: false, termination: nil, exitCode: nil,
        stdoutBase64: "", stderrBase64: "", launchErrorDomain: nil,
        launchErrorCode: nil))
  }

  private static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let bytes = try handle.read(upToCount: 64 * 1024), !bytes.isEmpty {
      hasher.update(data: bytes)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func signatureIntegrityIsValid(at url: URL) -> Bool {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
      let code
    else { return false }
    return SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
  }

  private static func quarantineIsPresent(at url: URL) -> Bool {
    url.path.withCString { path in
      "com.apple.quarantine".withCString { attribute in
        getxattr(path, attribute, nil, 0, 0, 0) >= 0
      }
    }
  }

  private static func emit(_ envelope: ProbeEnvelope) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let bytes = try? encoder.encode(envelope) else { return }
    FileHandle.standardOutput.write(bytes)
    FileHandle.standardOutput.write(Data([0x0a]))
  }
}

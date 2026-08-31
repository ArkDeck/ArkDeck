import ArkDeckAgentClient
import ArkDeckCore
import CryptoKit
import Darwin
import Foundation

extension RuntimeCLI {
  static func runDurableImport(_ arguments: [String]) throws {
    guard let verb = arguments.first else { throw CLIError(exitCode: 64, message: "Import subcommand is required") }
    var rest = Array(arguments.dropFirst())
    var session = runtimeSession(&rest, command: "artifact.import.\(verb)")
    let options = try CLIOptions(rest)
    let cancellation = AgentClientWaitCancellation()
    let observer = CLIWaitSignalObserver(cancellation: cancellation); defer { observer.stop() }
    guard let duration = CLIDuration.parse(options.value("--timeout") ?? "1h", maximumMilliseconds: 86_400_000) else {
      throw session.fail(.invalidInput, "invalid Import timeout")
    }
    let deadline = try AgentClientWaitDeadline(milliseconds: duration.milliseconds, cancellation: cancellation)
    session.client = session.client.bounded(by: deadline)
    let requestID = options.value("--import-request-id")
    do {
      let method = ["list", "inspect", "abort"].contains(verb) ? "artifact.import.\(verb)" : "artifact.import.begin"
      try session.negotiate(requiredMajor: 2, forMethod: method)
      if verb == "list" {
        var fields: [String: JSONValue] = [:]
        for (flag, key) in [("--target", "target"), ("--state", "state"), ("--cursor", "cursor")] {
          if let text = options.value(flag) { fields[key] = .string(text) }
        }
        if let number = options.value("--page-size").flatMap(Int64.init) { fields["pageSize"] = .integer(number) }
        let value = try session.request(method, fields)
        try CLIImportProjection.validatePage(value)
        session.emit(value); return
      }
      if verb == "inspect" || verb == "abort" {
        var fields: [String: JSONValue] = [:]
        if let id = options.value("--import") { fields["importId"] = .string(id) }
        if let requestID { fields["importRequestId"] = .string(requestID) }
        if verb == "abort", let generation = options.value("--expected-generation") { fields["generation"] = .string(generation) }
        let value = try session.request(method, fields)
        _ = try CLIImportProjection(value)
        session.emit(value); return
      }
      guard let requestID, let target = options.value("--target"), let path = options.value("--file") else {
        throw session.fail(.invalidInput, "Import requires a stable request identity, target and file")
      }
      let maximum = verb == "flash-bundle" ? 8 * 1024 * 1024 * 1024 : verb == "workspace-patch" ? 512 * 1024 : 64 * 1024 * 1024
      let source = try CLIImportSource(path: path, maximumBytes: maximum, deadline: deadline)
      let existing: CLIImportProjection?
      do { existing = try CLIImportProjection(session.request("artifact.import.inspect", ["importRequestId": .string(requestID)])) }
      catch let error as CLIRegistryError where error.code == .resourceNotFound { existing = nil }
      let revision: Int
      if let existing { revision = existing.intent.bindingRevision }
      else {
        guard case .object(let current) = try session.request("target.show", ["targetId": .string(target)]),
          current["schemaVersion"] == .string("arkdeck.target/1"), current["targetId"] == .string(target),
          case .integer(let value)? = current["bindingRevision"], value > 0, let exact = Int(exactly: value) else {
          throw session.fail(.recordUnreadable, "target has no exact current binding reference")
        }
        revision = exact
      }
      let metadata = try ArtifactImportIntent([
        "schemaVersion": .string(ArtifactImportIntent.schemaVersion), "importRequestId": .string(requestID),
        "kind": .string(verb), "targetId": .string(target), "bindingRevision": .string(String(revision)),
        "deviceProfile": verb == "flash-bundle" ? .string(options.value("--device-profile") ?? "dayu200") : .null,
        "name": .string(verb == "flash-bundle" ? "images.tar.gz"
          : verb == "native-library" ? try canonicalNativeLibraryImportName(source.name) : source.name),
        "byteCount": .string(String(source.byteCount)), "sha256": .string(source.sha256),
      ])
      if let existing, existing.intent != metadata {
        if existing.intent.kind == metadata.kind, existing.intent.targetID == metadata.targetID,
          existing.intent.name == metadata.name, existing.intent.deviceProfile == metadata.deviceProfile,
          existing.intent.sha256 != metadata.sha256 || existing.intent.byteCount != metadata.byteCount {
          throw session.fail(.artifactIntegrityFailed, "Import source changed; staged data was not overwritten or aborted")
        }
        throw session.fail(.idempotencyConflict, "Import request identity already names different metadata")
      }
      guard case .object(let fields) = metadata.projection else { throw session.fail(.invalidInput, "invalid Import metadata") }
      var current: CLIImportProjection
      if let existing { current = existing }
      else {
        do { current = try CLIImportProjection(session.request("artifact.import.begin", fields)) }
        catch let error as CLIRegistryError where error.code == .outcomeUnknown || error.code == .runtimeUnavailable {
          try deadline.check()
          do { current = try CLIImportProjection(session.request("artifact.import.inspect", ["importRequestId": .string(requestID)])) }
          catch let lookup as CLIRegistryError where lookup.code == .resourceNotFound {
            current = try CLIImportProjection(session.request("artifact.import.begin", fields))
          }
        }
      }
      guard current.intent == metadata else { throw session.fail(.recordUnreadable, "Import receipt changed the upload metadata") }
      var recoveredResponses = 0
      while current.state == "inProgress", current.nextOffset < source.byteCount {
        try deadline.check()
        let offset = current.nextOffset
        let chunk = try source.chunk(offset: offset, count: min(current.maximumChunkBytes, source.byteCount - offset), deadline: deadline)
        do {
          let next = try CLIImportProjection(session.request("artifact.import.append", ["importId": .string(current.id),
            "generation": .string(String(current.generation)), "offset": .string(String(offset)), "byteCount": .string(String(chunk.count)),
            "sha256": .string(SHA256Hex.string(of: chunk)), "base64": .string(chunk.base64EncodedString())]))
          guard next.id == current.id, next.intent == metadata, next.nextOffset == offset + chunk.count else { throw session.fail(.recordUnreadable, "Import append returned another owner or offset") }
          current = next
        } catch let error as CLIRegistryError where (error.code == .outcomeUnknown || error.code == .runtimeUnavailable) && recoveredResponses < 2 {
          recoveredResponses += 1; try deadline.check()
          let recovered = try CLIImportProjection(session.request("artifact.import.inspect", ["importRequestId": .string(requestID)]))
          guard recovered.id == current.id, recovered.intent == metadata, recovered.nextOffset >= offset else { throw session.fail(.recordUnreadable, "Import recovery changed its owner or committed prefix") }
          current = recovered
        }
      }
      try source.checkIdentity()
      if ["inProgress", "committing"].contains(current.state) {
        let owner = current.id
        let request: [String: JSONValue] = ["importId": .string(owner), "generation": .string(String(current.generation))]
        do { current = try CLIImportProjection(session.request("artifact.import.commit", request)) }
        catch let error as CLIRegistryError where error.code == .outcomeUnknown || error.code == .runtimeUnavailable {
          try deadline.check()
          current = try CLIImportProjection(session.request("artifact.import.inspect", ["importRequestId": .string(requestID)]))
          if current.id == owner, current.intent == metadata, ["inProgress", "committing"].contains(current.state) {
            current = try CLIImportProjection(session.request("artifact.import.commit", request))
          }
        }
        guard current.id == owner, current.intent == metadata else { throw session.fail(.recordUnreadable, "Import commit returned another owner") }
      }
      guard ["committed", "aborted"].contains(current.state) else { throw session.fail(.resultNotReady, "Import remains resumable; retry with the same request identity") }
      session.emit(current.value)
      if current.state == "aborted" { throw CLIError(exitCode: 1, message: "Import request was aborted; it cannot be resurrected") }
    } catch {
      let details: [String: JSONValue] = requestID.map { ["importRequestId": .string($0)] } ?? [:]
      if cancellation.isCancelled { throw session.fail(.clientInterrupted, "Import client interrupted; staged data remains resumable", details: details) }
      if deadline.remainingMilliseconds == 0 { throw session.fail(.clientTimeout, "Import client timed out; inspect or retry the same request identity", details: details) }
      if let failure = error as? AgentExecutionControlFailure { throw session.fail(CLIErrorCode(rawValue: failure.code) ?? .invalidInput, failure.message, details: details) }
      if var failure = error as? CLIRegistryError {
        failure.details.merge(details) { existing, _ in existing }; throw session.stamped(failure)
      }
      throw error
    }
  }
}

typealias CLIImportProjection = ArtifactImportProjection

private final class CLIImportSource {
  let descriptor: Int32
  let url: URL
  let name: String
  let byteCount: Int
  let sha256: String
  private let initial: stat
  init(path: String, maximumBytes: Int, deadline: AgentClientWaitDeadline) throws {
    url = URL(filePath: path).standardizedFileURL; name = url.lastPathComponent
    let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw CLIRegistryError(code: .invalidInput, message: "Import source cannot be opened") }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= maximumBytes else {
      close(descriptor); throw CLIRegistryError(code: .invalidInput, message: "Import source exceeds its registered regular-file bound")
    }
    self.descriptor = descriptor; initial = info; byteCount = Int(info.st_size)
    do {
      var hash = SHA256(); var offset = 0
      while offset < byteCount {
        try deadline.check()
        let chunk = try Self.read(descriptor, offset: offset, count: min(1024 * 1024, byteCount - offset))
        hash.update(data: chunk); offset += chunk.count
      }
      sha256 = SHA256Hex.hexString(hash.finalize())
    } catch { close(descriptor); throw error }
    try checkIdentity()
  }
  deinit { close(descriptor) }
  func checkIdentity() throws {
    var current = stat(); var named = stat()
    guard fstat(descriptor, &current) == 0, lstat(url.path, &named) == 0,
      named.st_mode & S_IFMT == S_IFREG, named.st_dev == initial.st_dev, named.st_ino == initial.st_ino,
      current.st_size == initial.st_size, current.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
      current.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
      current.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec, current.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec else {
      throw CLIRegistryError(code: .artifactIntegrityFailed, message: "Import source changed; staged data was not overwritten or aborted")
    }
  }
  func chunk(offset: Int, count: Int, deadline: AgentClientWaitDeadline) throws -> Data {
    try deadline.check(); try checkIdentity()
    let value = try Self.read(descriptor, offset: offset, count: count)
    try checkIdentity(); return value
  }
  private static func read(_ descriptor: Int32, offset: Int, count: Int) throws -> Data {
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { bytes in
      var read = 0
      while read < count {
        let n = pread(descriptor, bytes.baseAddress!.advanced(by: read), count - read, off_t(offset + read))
        if n < 0, errno == EINTR { continue }
        guard n > 0 else { throw CLIRegistryError(code: .artifactIntegrityFailed, message: "Import source could not be read completely") }
        read += n
      }
    }
    return data
  }
}

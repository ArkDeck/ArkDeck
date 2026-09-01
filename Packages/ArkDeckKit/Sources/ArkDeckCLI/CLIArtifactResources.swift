import ArkDeckAgentClient
import ArkDeckCore
import Foundation

extension RuntimeCLI {
  static func usesArtifactResource(_ verb: String, rest: [String]) -> Bool {
    ["list", "inspect", "read", "export"].contains(verb)
      && rest.contains { ["--import", "--require-protocol", "--page-size", "--cursor", "--timeout", "--overwrite"].contains($0) }
  }

  static func runArtifactResource(
    _ verb: String,
    rest original: [String],
    command: String? = nil,
    requiredSourceOperation: String? = nil
  ) throws {
    var rest = original
    var session = runtimeSession(
      &rest,
      command: command ?? "artifact.\(verb)")
    let options = try CLIOptions(rest.filter { !["--allow-sensitive", "--raw", "--overwrite"].contains($0) })
    let cancellation = AgentClientWaitCancellation()
    let observer = CLIWaitSignalObserver(cancellation: cancellation)
    defer { observer.stop() }
    guard let duration = CLIDuration.parse(options.value("--timeout") ?? "1h", maximumMilliseconds: 86_400_000) else {
      throw session.fail(.invalidInput, "Artifact timeout must be a bounded duration")
    }
    let deadline = try AgentClientWaitDeadline(milliseconds: duration.milliseconds, cancellation: cancellation)
    session.client = session.client.bounded(by: deadline)
    do {
      let job = options.value("--job"); let imported = options.value("--import")
      guard (job == nil) != (imported == nil) else { throw session.fail(.invalidInput, "select exactly one Job or Import owner") }
      let owner = try ArtifactOwnerReference(.object(["kind": .string(job == nil ? "import" : "job"), "id": .string(job ?? imported!)]))
      guard !(verb == "list" && options.value("--artifact") != nil),
        !(["list", "inspect"].contains(verb) && rest.contains("--allow-sensitive")) else {
        throw session.fail(.invalidInput, "Artifact metadata queries do not accept content-access or item-filter options")
      }
      let method = "artifact.\(verb)"
      try session.negotiate(requiredMajor: 2, forMethod: method)
      var fields: [String: JSONValue] = ["owner": owner.value]
      if verb == "list" {
        let size = Int(options.value("--page-size") ?? "100") ?? 100
        fields["pageSize"] = .integer(Int64(size))
        if let cursor = options.value("--cursor") { fields["cursor"] = .string(cursor) }
        let value = try session.request(method, fields)
        try ArtifactResourceProjection.validatePage(value, owner: owner, pageSize: size)
        session.emit(value); return
      }
      guard let id = options.value("--artifact"), AgentExecutionIntent.validIdentifier(id) else {
        throw session.fail(.invalidInput, "exact Artifact identity is required")
      }
      fields["artifactId"] = .string(id)
      let metadata = try ArtifactResourceProjection(session.request("artifact.inspect", fields))
      guard metadata.owner == owner, metadata.id == id else { throw session.fail(.recordUnreadable, "Artifact metadata belongs to another owner or identity") }
      if let requiredSourceOperation {
        guard case .object(let inventory) = metadata.value,
          inventory["sourceOperation"] == .string(requiredSourceOperation)
        else {
          throw session.fail(
            .invalidInput,
            "selected Artifact does not belong to \(requiredSourceOperation)")
        }
      }
      if verb == "inspect" { session.emit(metadata.value); return }
      fields["allowSensitive"] = .bool(rest.contains("--allow-sensitive"))
      if verb == "read" {
        let offset = Int(options.value("--offset") ?? "0") ?? 0
        let maximum = Int(options.value("--max-bytes") ?? "1048576") ?? 1_048_576
        fields["offset"] = .integer(Int64(offset)); fields["maxBytes"] = .integer(Int64(maximum))
        let read = try ArtifactReadProjection(session.request(method, fields))
        guard read.artifactID == id, read.digest == metadata.digest, read.totalByteCount == metadata.byteCount,
          read.offset == offset, read.bytes.count <= maximum else { throw session.fail(.recordUnreadable, "Artifact range differs from the selected metadata or requested bound") }
        if rest.contains("--raw") { FileHandle.standardOutput.write(read.bytes) }
        else { session.emit(read.value) }
        return
      }
      guard verb == "export", let destination = options.value("--destination") else { throw session.fail(.invalidInput, "export requires an explicit host destination directory") }
      let directory = URL(filePath: destination, directoryHint: .isDirectory).standardizedFileURL.path
      fields["destinationDirectory"] = .string(directory); fields["overwrite"] = .bool(rest.contains("--overwrite"))
      let value = try session.request(method, fields)
      guard case .object(let result) = value,
        Set(result.keys) == ["schemaVersion", "owner", "artifactId", "artifactDigest", "byteCount", "privacy", "exportedPath", "overwritten"],
        result["schemaVersion"] == .string("arkdeck.artifact-export/1"), result["owner"] == owner.value,
        result["artifactId"] == .string(id), metadata.digest.map(JSONValue.string) == result["artifactDigest"],
        ArtifactReadProjection.count(result["byteCount"]) == metadata.byteCount,
        case .object(let inventory) = metadata.value, result["privacy"] == inventory["privacy"],
        case .string(let name)? = inventory["name"], case .string(let exported)? = result["exportedPath"],
        case .bool(let overwritten)? = result["overwritten"], !overwritten || rest.contains("--overwrite") else {
        throw session.fail(.outcomeUnknown, "Artifact export returned an invalid receipt; inspect the destination before retrying")
      }
      var physical = directory
      for prefix in ["/var", "/tmp", "/etc"] where directory == prefix || directory.hasPrefix(prefix + "/") { physical = "/private" + directory }
      let safeName = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
      guard exported == URL(filePath: physical).appending(path: "\(id)-\(safeName)").path else {
        throw session.fail(.outcomeUnknown, "Artifact export receipt names a different destination; publication is unconfirmed")
      }
      session.emit(value)
    } catch let failure as AgentExecutionControlFailure {
      throw session.fail(CLIErrorCode(rawValue: failure.code) ?? .recordUnreadable, failure.message)
    } catch let failure as CLIRegistryError { throw session.stamped(failure) }
  }
}

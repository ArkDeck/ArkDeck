// Runtime client commands (CHG-2026-048, T09/T11).
//
// `arkdeck doctor`, `arkdeck operation list`, `arkdeck device list|adopt|show` and
// `arkdeck job submit|status` are thin daemon clients: they construct a
// typed request or a control-plane call and print the response. No HDC,
// no argv, no executor lives here - the CLI cannot execute a device
// operation even in principle, only ask the daemon to.

import ArkDeckAgentClient
import ArkDeckCore
import ArkDeckRuntime
import ArkDeckWorkflows
import CryptoKit
import Darwin
import Foundation

enum RuntimeCLI {
  static func defaultSocketPath() -> String {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ArkDeck/Agentd/agentd.sock").path
  }

  static func client(_ arguments: inout [String]) -> AgentClient {
    var socketPath = defaultSocketPath()
    if let index = arguments.firstIndex(of: "--socket"), index + 1 < arguments.count {
      socketPath = arguments[index + 1]
      arguments.removeSubrange(index...(index + 1))
    }
    return AgentClient(socketPath: socketPath)
  }

  static func emit(_ value: JSONValue, json: Bool) {
    if json {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
      if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
        print(text)
        return
      }
    }
    print(render(value, indent: 0))
  }

  private static func render(_ value: JSONValue, indent: Int) -> String {
    let pad = String(repeating: "  ", count: indent)
    switch value {
    case .object(let fields):
      return fields.keys.sorted().map { key in
        "\(pad)\(key): \(render(fields[key] ?? .null, indent: indent + 1).trimmingCharacters(in: .whitespaces))"
      }.joined(separator: "\n")
    case .array(let items):
      if items.isEmpty { return "\(pad)(none)" }
      return items.map {
        "\(pad)- \(render($0, indent: indent + 1).trimmingCharacters(in: .whitespaces))"
      }
      .joined(separator: "\n")
    case .string(let text): return "\(pad)\(text)"
    case .integer(let number): return "\(pad)\(number)"
    case .unsignedInteger(let number): return "\(pad)\(number)"
    case .number(let number): return "\(pad)\(number)"
    case .bool(let flag): return "\(pad)\(flag)"
    case .null: return "\(pad)-"
    }
  }

  static func runDoctor(_ arguments: [String]) throws {
    var rest = arguments
    let json = rest.contains("--json")
    let client = client(&rest)
    emit(try client.request(method: "doctor"), json: json)
  }

  static func runOperation(_ arguments: [String]) throws {
    guard arguments.first == "list" else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "usage: arkdeck operation list [--socket <path>] [--json]")
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    rest.removeAll { $0 == "--json" }
    let client = client(&rest)
    guard rest.isEmpty else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "operation list received unsupported arguments")
    }
    emit(try client.request(method: "operation.list"), json: json)
  }

  static func runDevice(_ arguments: [String]) throws {
    guard let subcommand = arguments.first else {
      throw CLIError(exitCode: EX_USAGE, message: "missing device subcommand (list|adopt|show)")
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    let client = client(&rest)
    switch subcommand {
    case "list", "show":
      emit(try client.request(method: "target.list"), json: json)
    case "adopt":
      var params: [String: JSONValue] = [:]
      if let index = rest.firstIndex(of: "--candidate"), index + 1 < rest.count {
        params["candidate"] = .string(rest[index + 1])
      }
      emit(try client.request(method: "target.adopt", params: params), json: json)
    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported device subcommand")
    }
  }

  /// `arkdeck agent run|resume` - the Device Runtime Agent entry point.
  /// A persisted resume token keeps physical assistance inside the same
  /// execution instead of asking a maintainer to restart host commands.
  static func runAgent(_ arguments: [String]) throws {
    guard let subcommand = arguments.first, subcommand == "run" || subcommand == "resume" else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "usage: arkdeck agent run --operation <id@v> | agent resume --resume-token <token>"
      )
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    let client = client(&rest)
    let executor = AgentRuntimeExecutor(client: client, nowUTC: RuntimeCLI.utcNow)
    let outcome: RuntimeAgentExecutionOutcome

    if subcommand == "resume" {
      guard let tokenIndex = rest.firstIndex(of: "--resume-token"),
        tokenIndex + 1 < rest.count
      else {
        throw CLIError(exitCode: EX_USAGE, message: "agent resume requires --resume-token")
      }
      var selection: String?
      if let index = rest.firstIndex(of: "--selection"), index + 1 < rest.count {
        selection = rest[index + 1]
      }
      outcome = try executor.resume(
        resumeToken: rest[tokenIndex + 1], selection: selection)
    } else {
      guard let operationIndex = rest.firstIndex(of: "--operation"),
        operationIndex + 1 < rest.count
      else {
        throw CLIError(exitCode: EX_USAGE, message: "agent run requires --operation <id@version>")
      }
      let parts = rest[operationIndex + 1].split(separator: "@")
      guard parts.count == 2, let version = Int(parts[1]) else {
        throw CLIError(exitCode: EX_USAGE, message: "operation must be <id>@<version>")
      }
      var inputs: [String: JSONValue] = [:]
      if let index = rest.firstIndex(of: "--inputs-file"), index + 1 < rest.count {
        let url = URL(fileURLWithPath: rest[index + 1])
        guard let data = try? Data(contentsOf: url),
          let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else {
          throw CLIError(exitCode: EX_USAGE, message: "cannot read typed inputs from \(url.path)")
        }
        inputs = decoded
      }
      var capability: String?
      if let index = rest.firstIndex(of: "--capability"), index + 1 < rest.count {
        capability = rest[index + 1]
      }
      var target: String?
      if let index = rest.firstIndex(of: "--target"), index + 1 < rest.count {
        target = rest[index + 1]
      }
      var executionID: String?
      if let index = rest.firstIndex(of: "--execution-id"), index + 1 < rest.count {
        executionID = rest[index + 1]
      }

      outcome = try executor.run(
        RuntimeAgentExecutionRequest(
          operationID: String(parts[0]), operationVersion: version, inputs: inputs,
          capabilityReference: capability, targetID: target,
          executionID: executionID ?? UUID().uuidString.lowercased()))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]

    switch outcome {
    case .completed(let receipt):
      if json, let data = try? encoder.encode(receipt),
        let text = String(data: data, encoding: .utf8)
      {
        print(text)
      } else {
        print("completed \(receipt.operationReference) job=\(receipt.jobID ?? "-")")
      }
    case .awaitingHumanAction(let action, let receipt):
      if json, let data = try? encoder.encode(receipt),
        let text = String(data: data, encoding: .utf8)
      {
        print(text)
      }
      FileHandle.standardError.write(
        Data(
          """
          human action required (\(action.kind.rawValue)): \(action.prompt)
          \(action.selectionOptions.map { "selection options: \($0.joined(separator: ", "))\n" } ?? "")\
          resume with: arkdeck agent resume --resume-token \(action.resumeToken)

          """.utf8))
      throw CLIError(exitCode: 75, message: "paused for physical assistance")
    case .failed(let reason, let receipt):
      if json, let data = try? encoder.encode(receipt),
        let text = String(data: data, encoding: .utf8)
      {
        print(text)
      }
      throw CLIError(exitCode: 1, message: reason)
    }
  }

  static func utcNow() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: Date())
  }

  static func runCapability(_ arguments: [String]) throws {
    guard let subcommand = arguments.first else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "missing capability subcommand (list|inspect|draft|install|revoke)")
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    let client = client(&rest)
    switch subcommand {
    case "list":
      emit(try client.request(method: "capability.list"), json: json)
    case "inspect":
      guard let index = rest.firstIndex(of: "--capability"), index + 1 < rest.count else {
        throw CLIError(
          exitCode: EX_USAGE, message: "capability inspect requires --capability <id>")
      }
      emit(
        try client.request(
          method: "capability.inspect",
          params: ["capabilityId": .string(rest[index + 1])]),
        json: json)
    case "draft":
      guard let targetIndex = rest.firstIndex(of: "--target"),
        targetIndex + 1 < rest.count,
        let operationIndex = rest.firstIndex(of: "--operation"),
        operationIndex + 1 < rest.count,
        let outputIndex = rest.firstIndex(of: "--output-directory"),
        outputIndex + 1 < rest.count
      else {
        throw CLIError(
          exitCode: EX_USAGE,
          message:
            "capability draft requires --target <id> --operation <id@version> "
            + "--output-directory <path>")
      }
      let operationParts = rest[operationIndex + 1].split(separator: "@")
      guard operationParts.count == 2, let operationVersion = Int(operationParts[1]) else {
        throw CLIError(exitCode: EX_USAGE, message: "operation must be <id>@<version>")
      }
      var inputs: [String: JSONValue] = [:]
      if let index = rest.firstIndex(of: "--inputs-file"), index + 1 < rest.count {
        let url = URL(fileURLWithPath: rest[index + 1])
        guard let data = try? Data(contentsOf: url),
          let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else {
          throw CLIError(exitCode: EX_USAGE, message: "cannot read typed inputs from \(url.path)")
        }
        inputs = decoded
      }
      let executionID: String
      if let index = rest.firstIndex(of: "--execution-id"), index + 1 < rest.count {
        executionID = rest[index + 1]
      } else {
        executionID = UUID().uuidString.lowercased()
      }
      let validitySeconds: Int
      if let index = rest.firstIndex(of: "--validity-seconds"), index + 1 < rest.count {
        guard let parsed = Int(rest[index + 1]) else {
          throw CLIError(exitCode: EX_USAGE, message: "validity-seconds must be an integer")
        }
        validitySeconds = parsed
      } else {
        validitySeconds = 3_600
      }
      let maximumUses: Int
      if let index = rest.firstIndex(of: "--maximum-uses"), index + 1 < rest.count {
        guard let parsed = Int(rest[index + 1]), (1...32).contains(parsed) else {
          throw CLIError(
            exitCode: EX_USAGE, message: "maximum-uses must be an integer between 1 and 32")
        }
        maximumUses = parsed
      } else {
        maximumUses = 1
      }
      let request = try RuntimeOperationRequest(
        requestID: "agent-request-\(executionID)",
        idempotencyKey: "agent-execution-\(executionID)",
        target: try RuntimeOperationRequest.capabilityDraftTarget(
          targetID: rest[targetIndex + 1],
          operationID: String(operationParts[0]),
          version: operationVersion,
          currentDeviceBindingRevision: {
            try bindingRevision(targetID: rest[targetIndex + 1], client: client)
          }),
        operation: RuntimeOperationReference(
          id: String(operationParts[0]), version: operationVersion),
        inputs: inputs)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let requestData = try encoder.encode(request)
      guard let requestJSON = String(data: requestData, encoding: .utf8) else {
        throw CLIError(exitCode: EX_SOFTWARE, message: "cannot encode capability draft request")
      }
      let draft = try client.request(
        method: "capability.draft",
        params: [
          "requestJson": .string(requestJSON),
          "validitySeconds": .integer(Int64(validitySeconds)),
          "maximumUses": .integer(Int64(maximumUses)),
        ])
      guard case .object(var draftFields) = draft,
        case .object(let capabilityFields)? = draftFields["capability"],
        case .string(let capabilityID)? = capabilityFields["capabilityID"]
      else {
        throw AgentClientError.malformedResponse(
          "capability.draft returned no capability document")
      }
      let outputDirectory = URL(
        fileURLWithPath: rest[outputIndex + 1], isDirectory: true
      ).standardizedFileURL
      try FileManager.default.createDirectory(
        at: outputDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let outputURL = outputDirectory.appendingPathComponent("\(capabilityID).json")
      guard !FileManager.default.fileExists(atPath: outputURL.path) else {
        throw CLIError(
          exitCode: EX_CANTCREAT,
          message: "refusing to overwrite existing capability draft \(outputURL.path)")
      }
      let capabilityData = try encoder.encode(JSONValue.object(capabilityFields))
      try capabilityData.write(to: outputURL, options: [.atomic])
      draftFields["draftFile"] = .string(outputURL.path)
      draftFields["executionID"] = .string(executionID)
      emit(.object(draftFields), json: json)
    case "install":
      guard let index = rest.firstIndex(of: "--file"), index + 1 < rest.count else {
        throw CLIError(exitCode: EX_USAGE, message: "capability install requires --file <path>")
      }
      let url = URL(fileURLWithPath: rest[index + 1])
      guard let document = try? String(contentsOf: url, encoding: .utf8) else {
        throw CLIError(exitCode: EX_USAGE, message: "cannot read \(url.path)")
      }
      emit(
        try client.request(
          method: "capability.install", params: ["capabilityJson": .string(document)]),
        json: json)
    case "revoke":
      guard let index = rest.firstIndex(of: "--capability"), index + 1 < rest.count else {
        throw CLIError(
          exitCode: EX_USAGE, message: "capability revoke requires --capability <id>")
      }
      emit(
        try client.request(
          method: "capability.revoke", params: ["capabilityId": .string(rest[index + 1])]),
        json: json)
    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported capability subcommand")
    }
  }

  private static func bindingRevision(targetID: String, client: AgentClient) throws -> Int {
    guard case .array(let targets) = try client.request(method: "target.list"),
      let match = targets.first(where: { value in
        guard case .object(let fields) = value,
          case .string(let listed)? = fields["targetId"]
        else {
          return false
        }
        return listed == targetID
      }),
      case .object(let fields) = match,
      case .integer(let revision)? = fields["bindingRevision"],
      let exact = Int(exactly: revision),
      exact > 0
    else {
      throw CLIError(
        exitCode: EX_DATAERR,
        message: "target \(targetID) has no durable binding revision")
    }
    return exact
  }

  static func runArtifact(_ arguments: [String]) throws {
    guard let subcommand = arguments.first else {
      throw CLIError(
        exitCode: EX_USAGE,
        message:
          "missing artifact subcommand "
          + "(import-hap|import-flash-bundle|import-native-library|list|inspect|read|export)")
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    let client = client(&rest)
    if subcommand == "import-flash-bundle" {
      try importFlashBundle(rest, client: client, json: json)
      return
    }
    if subcommand == "import-hap" {
      guard let targetIndex = rest.firstIndex(of: "--target"), targetIndex + 1 < rest.count,
        let fileIndex = rest.firstIndex(of: "--file"), fileIndex + 1 < rest.count
      else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "artifact import-hap requires --target <id> --file <signed.hap>")
      }
      let targetID = rest[targetIndex + 1]
      let payload = try readHAPImportPayload(path: rest[fileIndex + 1])
      let begin = try client.request(
        method: "artifact.importHap.begin",
        params: [
          "targetId": .string(targetID),
          "name": .string(payload.name),
          "byteCount": .integer(Int64(payload.contents.count)),
          "sha256": .string(payload.sha256),
        ])
      guard case .object(let beginFields) = begin,
        case .string(let uploadID)? = beginFields["uploadId"],
        case .integer(let maximumChunkValue)? = beginFields["maximumChunkBytes"],
        maximumChunkValue > 0, maximumChunkValue <= Int64(Int.max)
      else {
        throw AgentClientError.malformedResponse(
          "artifact.importHap.begin returned no bounded upload identity")
      }
      var committed = false
      defer {
        if !committed {
          _ = try? client.request(
            method: "artifact.importHap.abort",
            params: ["uploadId": .string(uploadID)])
        }
      }
      let maximumChunk = Int(maximumChunkValue)
      var offset = 0
      while offset < payload.contents.count {
        let end = min(payload.contents.count, offset + maximumChunk)
        let chunk = payload.contents.subdata(in: offset..<end)
        let appended = try client.request(
          method: "artifact.importHap.append",
          params: [
            "uploadId": .string(uploadID),
            "offset": .integer(Int64(offset)),
            "base64": .string(chunk.base64EncodedString()),
          ])
        guard case .object(let fields) = appended,
          case .integer(let nextOffset)? = fields["nextOffset"],
          nextOffset == Int64(end)
        else {
          throw AgentClientError.malformedResponse(
            "artifact.importHap.append returned a mismatched offset")
        }
        offset = end
      }
      let result = try client.request(
        method: "artifact.importHap.commit",
        params: ["uploadId": .string(uploadID)])
      committed = true
      emit(result, json: json)
      return
    }
    if subcommand == "import-native-library" {
      guard let targetIndex = rest.firstIndex(of: "--target"),
        targetIndex + 1 < rest.count,
        let fileIndex = rest.firstIndex(of: "--file"),
        fileIndex + 1 < rest.count
      else {
        throw CLIError(
          exitCode: EX_USAGE,
          message:
            "artifact import-native-library requires "
            + "--target <id> --file <libname.so>")
      }
      let targetID = rest[targetIndex + 1]
      let payload = try readNativeLibraryImportPayload(
        path: rest[fileIndex + 1])
      let begin = try client.request(
        method: "artifact.importNativeLibrary.begin",
        params: [
          "targetId": .string(targetID),
          "name": .string(payload.name),
          "byteCount": .integer(Int64(payload.contents.count)),
          "sha256": .string(payload.sha256),
        ])
      guard case .object(let beginFields) = begin,
        case .string(let uploadID)? = beginFields["uploadId"],
        case .integer(let maximumChunkValue)? =
          beginFields["maximumChunkBytes"],
        maximumChunkValue > 0, maximumChunkValue <= Int64(Int.max)
      else {
        throw AgentClientError.malformedResponse(
          "artifact.importNativeLibrary.begin returned no bounded upload identity")
      }
      var committed = false
      defer {
        if !committed {
          _ = try? client.request(
            method: "artifact.importNativeLibrary.abort",
            params: ["uploadId": .string(uploadID)])
        }
      }
      let maximumChunk = Int(maximumChunkValue)
      var offset = 0
      while offset < payload.contents.count {
        let end = min(payload.contents.count, offset + maximumChunk)
        let chunk = payload.contents.subdata(in: offset..<end)
        let appended = try client.request(
          method: "artifact.importNativeLibrary.append",
          params: [
            "uploadId": .string(uploadID),
            "offset": .integer(Int64(offset)),
            "base64": .string(chunk.base64EncodedString()),
          ])
        guard case .object(let fields) = appended,
          case .integer(let nextOffset)? = fields["nextOffset"],
          nextOffset == Int64(end)
        else {
          throw AgentClientError.malformedResponse(
            "artifact.importNativeLibrary.append returned a mismatched offset")
        }
        offset = end
      }
      let result = try client.request(
        method: "artifact.importNativeLibrary.commit",
        params: ["uploadId": .string(uploadID)])
      committed = true
      emit(result, json: json)
      return
    }
    guard let jobIndex = rest.firstIndex(of: "--job"), jobIndex + 1 < rest.count else {
      throw CLIError(exitCode: EX_USAGE, message: "artifact commands require --job <id>")
    }
    var params: [String: JSONValue] = ["jobId": .string(rest[jobIndex + 1])]
    if let index = rest.firstIndex(of: "--artifact"), index + 1 < rest.count {
      params["artifactId"] = .string(rest[index + 1])
    }
    if rest.contains("--allow-sensitive") { params["allowSensitive"] = .bool(true) }
    switch subcommand {
    case "list":
      emit(try client.request(method: "artifact.list", params: params), json: json)
    case "inspect":
      guard params["artifactId"] != nil else {
        throw CLIError(exitCode: EX_USAGE, message: "artifact inspect requires --artifact <id>")
      }
      emit(try client.request(method: "artifact.inspect", params: params), json: json)
    case "read":
      guard params["artifactId"] != nil else {
        throw CLIError(exitCode: EX_USAGE, message: "artifact read requires --artifact <id>")
      }
      emit(try client.request(method: "artifact.read", params: params), json: json)
    case "export":
      guard params["artifactId"] != nil else {
        throw CLIError(exitCode: EX_USAGE, message: "artifact export requires --artifact <id>")
      }
      guard let index = rest.firstIndex(of: "--destination"), index + 1 < rest.count else {
        throw CLIError(
          exitCode: EX_USAGE, message: "artifact export requires --destination <directory>")
      }
      params["destinationDirectory"] = .string(rest[index + 1])
      emit(try client.request(method: "artifact.export", params: params), json: json)
    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported artifact subcommand")
    }
  }

  private static func importFlashBundle(
    _ arguments: [String],
    client: AgentClient,
    json: Bool
  ) throws {
    guard let targetIndex = arguments.firstIndex(of: "--target"),
      targetIndex + 1 < arguments.count,
      let fileIndex = arguments.firstIndex(of: "--file"),
      fileIndex + 1 < arguments.count
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message:
          "artifact import-flash-bundle requires "
          + "--target <id> --file <images.tar.gz> "
          + "[--device-profile <dayu200@1|dayu200@2>]")
    }
    let targetID = arguments[targetIndex + 1]
    let url = URL(fileURLWithPath: arguments[fileIndex + 1]).standardizedFileURL
    guard url.lastPathComponent == "images.tar.gz" else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "flash bundle file must have the exact basename images.tar.gz")
    }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "cannot open flash bundle file (errno \(errno))")
    }
    defer { Darwin.close(descriptor) }
    let profileReference: String
    if let profileIndex = arguments.firstIndex(of: "--device-profile"),
      profileIndex + 1 < arguments.count
    {
      profileReference = arguments[profileIndex + 1]
    } else {
      profileReference = "dayu200@1"
    }
    guard let profile = RockchipFlashProfile.profile(reference: profileReference) else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "unsupported DAYU200 device profile \(profileReference)")
    }
    var before = stat()
    guard fstat(descriptor, &before) == 0,
      before.st_mode & S_IFMT == S_IFREG,
      before.st_size == profile.archiveSizeBytes
    else {
      throw CLIError(
        exitCode: EX_DATAERR,
        message:
          "flash bundle must be the pinned DAYU200 regular archive of "
          + "\(profile.archiveSizeBytes) bytes")
    }

    let begin = try client.request(
      method: "artifact.importFlashBundle.begin",
      params: [
        "targetId": .string(targetID),
        "name": .string("images.tar.gz"),
        "byteCount": .integer(profile.archiveSizeBytes),
        "sha256": .string(profile.archiveSHA256),
      ])
    guard case .object(let beginFields) = begin,
      case .string(let uploadID)? = beginFields["uploadId"],
      case .integer(let maximumChunkValue)? = beginFields["maximumChunkBytes"],
      maximumChunkValue > 0, maximumChunkValue <= Int64(Int.max)
    else {
      throw AgentClientError.malformedResponse(
        "artifact.importFlashBundle.begin returned no bounded upload identity")
    }
    var committed = false
    defer {
      if !committed {
        _ = try? client.request(
          method: "artifact.importFlashBundle.abort",
          params: ["uploadId": .string(uploadID)])
      }
    }

    let maximumChunk = Int(maximumChunkValue)
    var buffer = [UInt8](repeating: 0, count: maximumChunk)
    var hasher = SHA256()
    var offset = 0
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else {
        throw CLIError(
          exitCode: EX_IOERR,
          message: "flash bundle read failed (errno \(errno))")
      }
      if count == 0 { break }
      let chunk = Data(buffer[0..<count])
      hasher.update(data: chunk)
      let appended = try client.request(
        method: "artifact.importFlashBundle.append",
        params: [
          "uploadId": .string(uploadID),
          "offset": .integer(Int64(offset)),
          "base64": .string(chunk.base64EncodedString()),
        ])
      let expectedNextOffset = offset + count
      guard case .object(let fields) = appended,
        case .integer(let nextOffset)? = fields["nextOffset"],
        nextOffset == Int64(expectedNextOffset)
      else {
        throw AgentClientError.malformedResponse(
          "artifact.importFlashBundle.append returned a mismatched offset")
      }
      offset = expectedNextOffset
    }
    var after = stat()
    let digest =
      hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard offset == Int(profile.archiveSizeBytes),
      digest == profile.archiveSHA256,
      fstat(descriptor, &after) == 0,
      after.st_dev == before.st_dev,
      after.st_ino == before.st_ino,
      after.st_size == before.st_size,
      after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
      after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
      after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
      after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
    else {
      throw CLIError(
        exitCode: EX_DATAERR,
        message:
          "flash bundle changed during import or does not match the pinned DAYU200 SHA-256")
    }
    let result = try client.request(
      method: "artifact.importFlashBundle.commit",
      params: ["uploadId": .string(uploadID)])
    committed = true
    emit(result, json: json)
  }

  private struct HAPImportPayload {
    let name: String
    let contents: Data
    let sha256: String
  }

  private static func readHAPImportPayload(path: String) throws -> HAPImportPayload {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let name = url.lastPathComponent
    guard name.count <= 128,
      name.range(
        of: #"^[A-Za-z0-9][A-Za-z0-9._-]*\.hap$"#,
        options: .regularExpression) != nil
    else {
      throw CLIError(
        exitCode: EX_USAGE, message: "HAP file must have a safe .hap basename")
    }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw CLIError(
        exitCode: EX_USAGE, message: "cannot open HAP file (errno \(errno))")
    }
    defer { Darwin.close(descriptor) }
    var before = stat()
    let maximumBytes = 64 * 1_024 * 1_024
    guard fstat(descriptor, &before) == 0,
      before.st_mode & S_IFMT == S_IFREG,
      before.st_size > 0,
      before.st_size <= maximumBytes
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "HAP must be a non-empty regular file no larger than \(maximumBytes) bytes")
    }
    var contents = Data()
    contents.reserveCapacity(Int(before.st_size))
    var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else {
        throw CLIError(
          exitCode: EX_USAGE, message: "HAP read failed (errno \(errno))")
      }
      if count == 0 { break }
      contents.append(contentsOf: buffer[0..<count])
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      contents.count == Int(before.st_size),
      after.st_dev == before.st_dev,
      after.st_ino == before.st_ino,
      after.st_size == before.st_size,
      after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
      after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
      after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
      after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
    else {
      throw CLIError(
        exitCode: EX_USAGE, message: "HAP changed while it was being imported")
    }
    guard contents.starts(with: [0x50, 0x4b, 0x03, 0x04]) else {
      throw CLIError(
        exitCode: EX_USAGE, message: "HAP is not a ZIP-based .hap container")
    }
    let digest = SHA256.hash(data: contents)
      .map { String(format: "%02x", $0) }.joined()
    return HAPImportPayload(name: name, contents: contents, sha256: digest)
  }

  private static func readNativeLibraryImportPayload(
    path: String
  ) throws -> HAPImportPayload {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let name = url.lastPathComponent
    guard name.count <= 128,
      name.range(
        of: #"^lib[A-Za-z0-9_.-]+\.so$"#,
        options: .regularExpression) != nil
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "native library file must have a safe lib*.so basename")
    }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "cannot open native library file (errno \(errno))")
    }
    defer { Darwin.close(descriptor) }
    var before = stat()
    let maximumBytes = NativeLibraryArtifactValidator.maximumBytes
    guard fstat(descriptor, &before) == 0,
      before.st_mode & S_IFMT == S_IFREG,
      before.st_size >= 64,
      before.st_size <= maximumBytes
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message:
          "native library must be a regular file of 64...\(maximumBytes) bytes")
    }
    var contents = Data()
    contents.reserveCapacity(Int(before.st_size))
    var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "native library read failed (errno \(errno))")
      }
      if count == 0 { break }
      contents.append(contentsOf: buffer[0..<count])
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      contents.count == Int(before.st_size),
      after.st_dev == before.st_dev,
      after.st_ino == before.st_ino,
      after.st_size == before.st_size,
      after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
      after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
      after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
      after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "native library changed while it was being imported")
    }
    do {
      _ = try NativeLibraryArtifactValidator.validate(
        contents, requireOpenHarmonyCodeSignature: true)
    } catch {
      throw CLIError(
        exitCode: EX_DATAERR,
        message: "native library failed ELF validation: \(error)")
    }
    let digest = SHA256.hash(data: contents)
      .map { String(format: "%02x", $0) }.joined()
    return HAPImportPayload(name: name, contents: contents, sha256: digest)
  }

  private static func json2Bool(_ arguments: [String]) -> Bool {
    arguments.contains("--json")
  }

  /// `arkdeck cleanup-debt list|continue` — the operator surface for cleanup
  /// that ran and did not take effect, whether it left a remote file or an
  /// installed bundle (CHG-2026-049 r3). The engine records the debt with the *exact typed
  /// action* it could not complete; `continue` only re-runs that recorded
  /// action, so `--remote-path` is a lookup key into the ledger, never a
  /// device path a caller gets to choose. The daemon has owned these two
  /// methods since MU-4 and nothing could call them.
  static func runCleanupDebt(_ arguments: [String]) throws {
    guard let subcommand = arguments.first else {
      throw CLIError(
        exitCode: EX_USAGE, message: "missing cleanup-debt subcommand (list|continue)")
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    let client = client(&rest)
    switch subcommand {
    case "list":
      emit(try client.request(method: "cleanupDebt.list"), json: json)
    case "continue":
      var residue: (key: String, value: String)?
      if let index = rest.firstIndex(of: "--remote-path"), index + 1 < rest.count {
        residue = ("remotePath", rest[index + 1])
      } else if let index = rest.firstIndex(of: "--bundle"), index + 1 < rest.count {
        residue = ("bundleName", rest[index + 1])
      }
      guard let jobIndex = rest.firstIndex(of: "--job"), jobIndex + 1 < rest.count,
        let residue
      else {
        throw CLIError(
          exitCode: EX_USAGE,
          message:
            "cleanup-debt continue requires --job <id> and one of "
            + "--remote-path <recorded path> / --bundle <recorded bundle>")
      }
      emit(
        try client.request(
          method: "cleanupDebt.continue",
          params: [
            "jobId": .string(rest[jobIndex + 1]),
            .init(residue.key): .string(residue.value),
          ]),
        json: json)
    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported cleanup-debt subcommand")
    }
  }

  static func runJob(_ arguments: [String]) throws {
    guard let subcommand = arguments.first else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "missing job subcommand (plan|submit|status|list|run|reconcile)")
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    let client = client(&rest)
    switch subcommand {
    case "plan":
      guard let fileIndex = rest.firstIndex(of: "--request-file"),
        fileIndex + 1 < rest.count
      else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "job plan requires --request-file <typed-request.json>")
      }
      let url = URL(fileURLWithPath: rest[fileIndex + 1])
      guard let requestJSON = try? String(contentsOf: url, encoding: .utf8) else {
        throw CLIError(exitCode: EX_USAGE, message: "cannot read \(url.path)")
      }
      emit(
        try client.request(
          method: "job.plan", params: ["requestJson": .string(requestJSON)]),
        json: json)
    case "list":
      emit(try client.request(method: "job.list"), json: json)
    case "status":
      guard let index = rest.firstIndex(of: "--job"), index + 1 < rest.count else {
        throw CLIError(exitCode: EX_USAGE, message: "job status requires --job <id>")
      }
      emit(
        try client.request(method: "job.status", params: ["jobId": .string(rest[index + 1])]),
        json: json)
    case "run":
      // Resuming a reconciled job is what settles its authorization lineage.
      // `reconcile` deliberately leaves a `confirmedCompleted` decision
      // holding its reservation — the job still owns it until the remaining
      // plan (cleanup, finalize) runs — but nothing could run it: `job.run`
      // accepts `resumeAtConfirmedSafeBoundary` and the CLI only ever
      // reached it through `submit --wait`. Without this, every reconciled
      // job left the target blocked for automatic E1 forever.
      guard let index = rest.firstIndex(of: "--job"), index + 1 < rest.count else {
        throw CLIError(exitCode: EX_USAGE, message: "job run requires --job <id>")
      }
      emit(
        try client.request(method: "job.run", params: ["jobId": .string(rest[index + 1])]),
        json: json)
    case "reconcile":
      // The daemon has owned `job.reconcile` since MU-4; the CLI did not
      // expose it, so a job left in `waitingForRecovery` had no operator
      // path to resolution — and an unresolved mutation use blocks every
      // later automatic E1 on that target (2026-07-31 device window). This
      // asks the daemon to run the read-only readback that settles the
      // outstanding intent; it never redispatches the mutation.
      guard let index = rest.firstIndex(of: "--job"), index + 1 < rest.count else {
        throw CLIError(exitCode: EX_USAGE, message: "job reconcile requires --job <id>")
      }
      emit(
        try client.request(method: "job.reconcile", params: ["jobId": .string(rest[index + 1])]),
        json: json)
    case "submit":
      // A prepared request file carries typed inputs the flag form cannot
      // express; it is passed through verbatim so the daemon, not the CLI,
      // remains the validator.
      if let fileIndex = rest.firstIndex(of: "--request-file"), fileIndex + 1 < rest.count {
        let url = URL(fileURLWithPath: rest[fileIndex + 1])
        guard let json = try? String(contentsOf: url, encoding: .utf8) else {
          throw CLIError(exitCode: EX_USAGE, message: "cannot read \(url.path)")
        }
        let submitted = try client.request(
          method: "job.submit", params: ["requestJson": .string(json)])
        emit(submitted, json: json2Bool(rest))
        if rest.contains("--wait"), case .object(let fields) = submitted,
          case .string(let jobID)? = fields["jobId"]
        {
          emit(
            try client.request(method: "job.run", params: ["jobId": .string(jobID)]),
            json: json2Bool(rest))
        }
        return
      }
      guard let targetIndex = rest.firstIndex(of: "--target"), targetIndex + 1 < rest.count,
        let operationIndex = rest.firstIndex(of: "--operation"), operationIndex + 1 < rest.count
      else {
        throw CLIError(
          exitCode: EX_USAGE,
          message:
            "job submit requires --target <id> --operation <id@version>, "
            + "or --request-file <path> for typed inputs")
      }
      let reference = rest[operationIndex + 1]
      let parts = reference.split(separator: "@")
      guard parts.count == 2, let version = Int(parts[1]) else {
        throw CLIError(exitCode: EX_USAGE, message: "operation must be <id>@<version>")
      }
      // The CLI builds a typed v2 request: no governance identifiers exist
      // in this surface to pass along even by accident. The document itself is
      // built by the request model, which refuses a device-bound operation
      // whose binding revision was not pinned - the flag form used to hand
      // that request to the daemon and get a generic `evidenceIncomplete`
      // back (2026-07-31 GJ-5 window, first leg).
      var pinnedRevision: Int?
      if let index = rest.firstIndex(of: "--expected-binding-revision"), index + 1 < rest.count {
        guard let parsed = Int(rest[index + 1]), parsed >= 1 else {
          throw CLIError(
            exitCode: EX_USAGE, message: "--expected-binding-revision takes a positive integer")
        }
        pinnedRevision = parsed
      }
      let request: RuntimeOperationRequest
      do {
        request = try RuntimeOperationRequest.operatorFlagForm(
          targetID: rest[targetIndex + 1],
          expectedBindingRevision: pinnedRevision,
          operationID: String(parts[0]),
          version: version,
          requestID: "cli-\(UUID().uuidString.prefix(8).lowercased())",
          idempotencyKey: "cli-\(UUID().uuidString.lowercased())")
      } catch let rejection as RuntimeOperationRequestRejection {
        throw CLIError(exitCode: EX_USAGE, message: rejection.message)
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      guard let requestJSON = String(data: try encoder.encode(request), encoding: .utf8) else {
        throw CLIError(exitCode: 1, message: "could not encode the operation request")
      }
      let submitted = try client.request(
        method: "job.submit", params: ["requestJson": .string(requestJSON)])
      emit(submitted, json: json)
      if rest.contains("--wait"), case .object(let fields) = submitted,
        case .string(let jobID)? = fields["jobId"]
      {
        emit(
          try client.request(method: "job.run", params: ["jobId": .string(jobID)]), json: json)
      }
    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported job subcommand")
    }
  }

  // `arkdeck task` (CHG-2026-054, TASK-HTP-001): the autonomous debug face.
  //
  // A caller states a target and a goal. There is no flag here that can
  // carry an operation argv, a remote path or a device selector - the
  // daemon's harness decides the next typed operation, one per wake, and
  // the engine still owns admission and execution.
  static func runTask(_ arguments: [String]) throws {
    guard let subcommand = arguments.first else {
      throw CLIError(
        exitCode: EX_USAGE,
        message:
          "missing task subcommand (submit|list|status|result|events|evaluations|"
          + "attempts|humanActions|memory|reconcile|propose-patch|pause|resume|cancel)")
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    let client = client(&rest)

    func value(_ flag: String) -> String? {
      guard let index = rest.firstIndex(of: flag), index + 1 < rest.count else { return nil }
      return rest[index + 1]
    }
    func requiredTask() throws -> String {
      guard let id = value("--task") else {
        throw CLIError(exitCode: EX_USAGE, message: "task \(subcommand) requires --task <HTASK-id>")
      }
      return id
    }

    switch subcommand {
    case "submit":
      guard let target = value("--target"), let goal = value("--goal") else {
        throw CLIError(
          exitCode: EX_USAGE, message: "task submit requires --target <id> --goal <text>")
      }
      var params: [String: JSONValue] = [
        "targetId": .string(target),
        "goal": .string(goal),
      ]
      let obsoleteWorkspaceFlags = [
        "--execution-mode", "--evolution-allowed-paths", "--evolution-allowed-operations",
      ]
      if let obsolete = obsoleteWorkspaceFlags.first(where: rest.contains) {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "\(obsolete) was removed; workspace policy is now the default Agent path")
      }
      if let paths = value("--workspace-allowed-paths") {
        params["allowedPaths"] = .array(
          paths.split(separator: ",").map {
            .string($0.trimmingCharacters(in: .whitespaces))
          })
      }
      if let operations = value("--workspace-allowed-operations") {
        params["evolutionAllowedOperations"] = .array(
          operations.split(separator: ",").map {
            .string($0.trimmingCharacters(in: .whitespaces))
          })
      }
      if let attempts = value("--max-attempts"), let parsed = Int64(attempts) {
        params["maxAttempts"] = .integer(parsed)
      }
      if let files = value("--max-changed-files"), let parsed = Int64(files) {
        params["maxChangedFiles"] = .integer(parsed)
      }
      if let lines = value("--max-diff-lines"), let parsed = Int64(lines) {
        params["maxDiffLines"] = .integer(parsed)
      }
      if let intake = value("--intake") { params["intake"] = .string(intake) }
      if let signature = value("--crash-signature") {
        params["crashSignature"] = .string(signature)
      }
      if let project = value("--project") { params["projectRef"] = .string(project) }
      if let bundle = value("--bundle-name") { params["bundleName"] = .string(bundle) }
      if let ability = value("--ability-name") { params["abilityName"] = .string(ability) }
      if let process = value("--process-name") { params["processName"] = .string(process) }
      if let lease = value("--baseline-hap-artifact-lease") {
        params["baselineHapArtifactLease"] = .string(lease)
      }
      if let preset = value("--build-preset") { params["buildPresetRef"] = .string(preset) }
      if let preset = value("--test-preset") { params["testPresetRef"] = .string(preset) }
      if let profile = value("--device-profile") {
        params["deviceProfile"] = .string(profile)
      }
      if let revision = value("--base-workspace-revision") {
        params["baseWorkspaceRevision"] = .string(revision)
      }
      if let component = value("--component") {
        params["component"] = .string(component)
      }
      if let rounds = value("--max-rounds"), let parsed = Int64(rounds) {
        params["maxRounds"] = .integer(parsed)
      }
      if let seconds = value("--max-wall-clock-seconds"), let parsed = Int64(seconds) {
        params["maxWallClockSeconds"] = .integer(parsed)
      }
      if let rounds = value("--max-no-progress-rounds"), let parsed = Int64(rounds) {
        params["maxNoProgressRounds"] = .integer(parsed)
      }
      if let retries = value("--max-action-retries-per-run"), let parsed = Int64(retries) {
        params["maxActionRetriesPerRun"] = .integer(parsed)
      }
      if let mutations = value("--max-e1-mutations"), let parsed = Int64(mutations) {
        params["maxE1Mutations"] = .integer(parsed)
      }
      if let calls = value("--max-model-calls"), let parsed = Int64(calls) {
        params["maxModelCalls"] = .integer(parsed)
      }
      if let revision = value("--expected-binding-revision"), let parsed = Int64(revision) {
        params["expectedBindingRevision"] = .integer(parsed)
      }
      emit(try client.request(method: "task.submit", params: params), json: json)
    case "list":
      emit(try client.request(method: "task.list"), json: json)
    case "status", "result", "events", "evaluations", "attempts", "humanActions", "memory",
      "reconcile", "pause", "cancel":
      emit(
        try client.request(
          method: "task.\(subcommand)", params: ["htaskId": .string(try requiredTask())]),
        json: json)
    case "resume":
      guard let resolution = value("--resolution") else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "task resume requires --resolution <typed reason>: a human block is only left "
            + "through a recorded decision")
      }
      emit(
        try client.request(
          method: "task.resume",
          params: [
            "htaskId": .string(try requiredTask()), "resolution": .string(resolution),
          ]),
        json: json)
    case "propose-patch":
      let maximumProposalBytes = 512 * 1024
      guard let path = value("--proposal-file") else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "task propose-patch requires --proposal-file <proposal.json>")
      }
      let url = URL(fileURLWithPath: path).standardizedFileURL
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values?.isRegularFile == true,
        let size = values?.fileSize, size > 0,
        size <= maximumProposalBytes,
        let proposalJSON = try? String(contentsOf: url, encoding: .utf8)
      else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "proposal must be a non-empty regular UTF-8 JSON file no larger than "
            + "\(maximumProposalBytes) bytes")
      }
      emit(
        try client.request(
          method: "task.proposePatch",
          params: [
            "htaskId": .string(try requiredTask()),
            "proposalJson": .string(proposalJSON),
          ]),
        json: json)
    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported task subcommand")
    }
  }
}

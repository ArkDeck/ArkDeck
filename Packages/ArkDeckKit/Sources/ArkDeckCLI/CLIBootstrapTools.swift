import ArkDeckAgentClient
import ArkDeckCore
import ArkDeckLaunchAgent
import ArkDeckWorkflows
import Foundation

extension RuntimeCLI {
  static func runBootstrapTool(_ arguments: [String], registry supplied: BootstrapToolRegistry? = nil) throws {
    guard let verb = arguments.first else { throw CLIError(exitCode: 64, message: "tool subcommand is required") }
    var rest = Array(arguments.dropFirst())
    var session = runtimeSession(
      &rest, command: "runtime.tool.\(verb)", connectsToRuntime: verb == "select")
    do {
      let options = try CLIOptions(rest)
      if verb == "select" {
        var fields: [String: JSONValue] = [:]
        for (flag, key) in [
          ("--tool", "tool"),
          ("--expected-active-generation", "expectedActiveGeneration"),
          ("--action-request-id", "actionRequestId"),
        ] {
          guard let value = options.value(flag) else {
            throw session.fail(
              .invalidInput,
              "select requires an exact tool, active generation and action request ID")
          }
          fields[key] = .string(value)
        }
        do { _ = try RuntimeToolSelectionIntent(fields) }
        catch {
          throw session.fail(.invalidInput, "tool-selection intent failed validation")
        }
        if let text = options.value("--timeout") {
          guard let duration = CLIDuration.parse(
            text, maximumMilliseconds: 86_400_000)
          else { throw session.fail(.invalidInput, "invalid bounded control timeout") }
          session.client = session.client.bounded(
            by: try AgentClientWaitDeadline(milliseconds: duration.milliseconds))
        }
        try session.negotiate(requiredMajor: 2, forMethod: "runtime.tool.select")
        session.emit(try session.request("runtime.tool.select", fields))
        return
      }
      let registry = try supplied ?? BootstrapToolRegistry(knownIdentity: { sha256 in
        HeadlessHDCBootstrapIdentity.lookup(sha256: sha256).map {
          BootstrapToolRegistry.PublishedIdentity(version: $0.version, profileReferences: $0.profileReferences)
        }
      })
      switch verb {
      case "register":
        guard options.value("--kind") == "hdc", let path = options.value("--file"), path.hasPrefix("/"),
          !path.utf8.contains(0), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
          throw session.fail(.invalidInput, "HDC registration requires an absolute local --file path")
        }
        session.emit(try registry.register(file: URL(filePath: path)))
      case "inspect":
        guard let reference = options.value("--tool") else { throw session.fail(.invalidInput, "exact --tool reference is required") }
        session.emit(try registry.inspect(reference))
      case "remove":
        guard let reference = options.value("--tool"), let generation = options.value("--expected-generation") else {
          throw session.fail(.invalidInput, "remove requires exact --tool and --expected-generation")
        }
        session.emit(try registry.remove(reference, expectedGeneration: generation))
      case "list":
        let size = Int(options.value("--page-size") ?? "100") ?? 0
        let result = try registry.list { directory, items in
          try RuntimeSnapshotPager(directory: directory).page(method: "runtime.tool.list", filters: [:],
            order: "toolRef:asc", pageSize: size, cursor: options.value("--cursor"), items: { items })
        }
        session.emit(result)
      default: throw session.fail(.invalidCommand, "unsupported tool subcommand")
      }
    } catch let error as CLIRegistryError { throw session.stamped(error) }
    catch let error as AgentExecutionControlFailure {
      throw session.fail(CLIErrorCode(rawValue: error.code) ?? .recordUnreadable, error.message,
        details: ["newDispatchCount": .integer(0)])
    } catch {
      throw session.fail(.ioFailure, "host tool registration could not complete: \(error)",
        details: ["newDispatchCount": .integer(0)])
    }
  }
}

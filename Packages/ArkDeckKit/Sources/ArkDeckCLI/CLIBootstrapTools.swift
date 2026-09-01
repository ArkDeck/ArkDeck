import ArkDeckCore
import ArkDeckLaunchAgent
import ArkDeckWorkflows
import Foundation

extension RuntimeCLI {
  static func runBootstrapTool(_ arguments: [String], registry supplied: BootstrapToolRegistry? = nil) throws {
    guard let verb = arguments.first else { throw CLIError(exitCode: 64, message: "tool subcommand is required") }
    var rest = Array(arguments.dropFirst())
    let session = runtimeSession(&rest, command: "runtime.tool.\(verb)", connectsToRuntime: false)
    do {
      let options = try CLIOptions(rest)
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

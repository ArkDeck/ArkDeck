import ArkDeckBootstrap
import ArkDeckCore
import ArkDeckLaunchAgent
import ArkDeckWorkflows
import Foundation

extension RuntimeCLI {
  static func runBootstrapBundle(_ arguments: [String], registry supplied: BootstrapBundleRegistry? = nil) throws {
    guard let verb = arguments.first else { throw CLIError(exitCode: 64, message: "bundle subcommand is required") }
    var rest = Array(arguments.dropFirst())
    let session = runtimeSession(&rest, command: "runtime.bundle.\(verb)", connectsToRuntime: false)
    do {
      let options = try CLIOptions(rest)
      let registry = try supplied ?? BootstrapBundleRegistry(validateBundle: { candidate in
        _ = try LaunchAgentService.validateProductionDaemonBundle(
          candidate, fileManager: .default)
      })
      switch verb {
      case "register":
        guard options.value("--kind") == "daemon-bundle", let path = options.value("--file"), path.hasPrefix("/"), !path.utf8.contains(0),
          !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
          throw session.fail(.invalidInput, "daemon-bundle registration requires an absolute local --file path")
        }
        session.emit(try registry.register(file: URL(filePath: path)))
      case "inspect":
        guard let reference = options.value("--bundle") else { throw session.fail(.invalidInput, "exact --bundle reference is required") }
        session.emit(try registry.inspect(reference))
      case "remove":
        guard let reference = options.value("--bundle"), let generation = options.value("--expected-generation") else {
          throw session.fail(.invalidInput, "remove requires exact --bundle and --expected-generation")
        }
        session.emit(try registry.remove(reference, expectedGeneration: generation))
      case "list":
        let size = Int(options.value("--page-size") ?? "100") ?? 0
        let cursor = options.value("--cursor")
        let result = try registry.list { directory, items in
          try RuntimeSnapshotPager(directory: directory).page(method: "runtime.bundle.list", filters: [:],
            order: "bundleRef:asc", pageSize: size, cursor: cursor, items: { items })
        }
        session.emit(result)
      default: throw session.fail(.invalidCommand, "unsupported bundle subcommand")
      }
    } catch let error as CLIRegistryError { throw session.stamped(error) }
    catch let error as AgentExecutionControlFailure {
      throw session.fail(CLIErrorCode(rawValue: error.code) ?? .recordUnreadable, error.message,
        details: ["newDispatchCount": .integer(0)])
    } catch let error as LaunchAgentServiceError {
      throw session.fail(.admissionDenied, "bundle did not pass the installed helper trust policy: \(error)",
        details: ["newDispatchCount": .integer(0)])
    } catch {
      throw session.fail(.recordUnreadable, "bootstrap bundle operation could not complete: \(error)",
        details: ["newDispatchCount": .integer(0)])
    }
  }
}

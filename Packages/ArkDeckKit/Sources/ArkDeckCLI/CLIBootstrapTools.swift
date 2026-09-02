import ArkDeckAgentClient
import ArkDeckBootstrap
import ArkDeckCore
import ArkDeckLaunchAgent
import ArkDeckWorkflows
import Foundation

extension RuntimeCLI {
  static func runBootstrapTool(
    _ arguments: [String],
    registry supplied: BootstrapToolRegistry? = nil,
    devecoRegistry suppliedDevEco: BootstrapDevEcoToolchainRegistry? = nil
  ) throws {
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
      let devecoRegistry = suppliedDevEco
        ?? BootstrapDevEcoToolchainRegistry(owner: registry.sharedOwner)
      switch verb {
      case "register":
        let kind = options.value("--kind")
        let file = options.value("--file")
        let root = options.value("--root")
        guard [file, root].compactMap({ $0 }).allSatisfy({ path in
          path.hasPrefix("/") && !path.utf8.contains(0)
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        }) else {
          throw session.fail(.invalidInput, "tool registration paths must be canonical absolute local paths")
        }
        switch (kind, file, root) {
        case ("hdc", .some(let path), nil):
          session.emit(try registry.register(file: URL(filePath: path)))
        case ("deveco", nil, .some(let path)):
          session.emit(try devecoRegistry.register(root: URL(filePath: path, directoryHint: .isDirectory)))
        default:
          throw session.fail(
            .invalidInput,
            "HDC registration requires only --file; DevEco registration requires only --root")
        }
      case "inspect":
        guard let reference = options.value("--tool") else { throw session.fail(.invalidInput, "exact --tool reference is required") }
        session.emit(
          try reference.hasPrefix("toolchain:sha256:")
            ? devecoRegistry.inspect(reference) : registry.inspect(reference))
      case "remove":
        guard let reference = options.value("--tool"), let generation = options.value("--expected-generation") else {
          throw session.fail(.invalidInput, "remove requires exact --tool and --expected-generation")
        }
        session.emit(
          try reference.hasPrefix("toolchain:sha256:")
            ? devecoRegistry.remove(reference, expectedGeneration: generation)
            : registry.remove(reference, expectedGeneration: generation))
      case "list":
        let size = Int(options.value("--page-size") ?? "100") ?? 0
        let inventory = try devecoRegistry.combinedInventory(with: registry)
        let items = try inventory.values.sorted { left, right in
          guard case .object(let leftFields) = left, case .string(let leftRef)? = leftFields["toolRef"],
            case .object(let rightFields) = right, case .string(let rightRef)? = rightFields["toolRef"]
          else { throw session.fail(.recordUnreadable, "tool inventory contains a malformed reference") }
          return leftRef < rightRef
        }
        let result = try RuntimeSnapshotPager(directory: inventory.snapshotDirectory).page(
          method: "runtime.tool.list", filters: [:], order: "toolRef:asc",
          pageSize: size, cursor: options.value("--cursor"), items: { items })
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

import ArkDeckCore
import Foundation

/// Help, the registry projection and completion scripts, all generated from
/// `CLICommandRegistry`.
///
/// The 90-line usage literal this replaces was the third hand-maintained copy
/// of the command surface, and the one that drifted first: it is the copy
/// nothing executes. Generating it means a command that exists is documented
/// and completable by construction, which is what §5.1 asks for.
enum CLIHelpRenderer {

  // MARK: Root

  static func root() -> String {
    var lines: [String] = []
    lines.append("arkdeck \(CLIProductVersion.product) — headless product face of the")
    lines.append("Device Agent Runtime. Decisions come from your own agent; ArkDeck executes.")
    lines.append("")
    lines.append("usage: arkdeck <command> [subcommand] [options]")
    lines.append("")
    lines.append("the usual path:")
    for highlight in CLICommandRegistry.rootHelpHighlights {
      let summary = summary(forPath: highlight) ?? ""
      lines.append("  " + pad("arkdeck " + highlight, 34) + summary)
    }
    lines.append("")
    lines.append("commands:")
    for node in CLICommandRegistry.nodes {
      lines.append("  " + pad(node.token, 34) + node.summary)
    }
    lines.append("")
    lines.append("registry:")
    for leaf in CLICommandRegistry.rootLeaves {
      lines.append("  " + pad(leaf.token, 34) + leaf.summary)
    }
    lines.append("")
    lines.append("  " + pad("--version", 34) + "product, registry, protocol and contract versions")
    lines.append("  " + pad("--help, -h", 34) + "help for any command path")
    lines.append("")
    lines.append("`arkdeck operation describe` is the fact source for an operation's typed")
    lines.append("inputs; this help never restates them. Every device effect crosses the")
    lines.append("Runtime's admission — the CLI holds no HDC, executor or capability writer.")
    lines.append("")
    lines.append("Real-device validation defaults to `arkdeck agent run`; use the App only when")
    lines.append("the acceptance criterion is specifically about its UI. UI acknowledgement is")
    lines.append("never a prerequisite or authority for headless execution.")
    return lines.joined(separator: "\n")
  }

  // MARK: Node and leaf

  static func node(_ node: CLINodeSpec) -> String {
    var lines: [String] = ["\(node.token) — \(node.summary)", "", "subcommands:"]
    for leaf in node.leaves where !leaf.token.isEmpty {
      lines.append("  " + pad(leaf.token, 26) + leaf.summary + statusSuffix(leaf))
    }
    lines.append("")
    lines.append("`arkdeck help \(node.token) <subcommand>` describes one of them.")
    return lines.joined(separator: "\n")
  }

  static func leaf(path: [String], leaf: CLILeafSpec) -> String {
    let name = path.joined(separator: " ")
    var lines: [String] = ["arkdeck \(name) — \(leaf.summary)"]

    switch leaf.kind {
    case .tombstone(let tombstone):
      lines.append("")
      if let pattern = tombstone.replacementArgvPattern {
        lines.append("retired. use `\(pattern)`.")
      } else {
        lines.append("retired. \(tombstone.reason ?? "nothing replaces it").")
      }
      if let removedIn = tombstone.removalVersion {
        lines.append("removed in \(removedIn).")
      }
      lines.append("recognised so the old spelling gets a stable answer; it cannot dispatch.")
      return lines.joined(separator: "\n")
    case .refused(let reason):
      lines.append("")
      lines.append("not caller-facing: \(reason).")
      return lines.joined(separator: "\n")
    case .executable:
      break
    }

    lines.append("")
    lines.append("usage: " + usage(path: path, leaf: leaf))

    let published = leaf.options.filter(\.isPublished)
    if !published.isEmpty {
      lines.append("")
      lines.append("options:")
      for option in published {
        let head = option.name + (option.takesValue ? " " + placeholder(option) : "")
        lines.append(
          "  " + pad(head, 34) + option.summary + (option.isRequired ? " (required)" : ""))
      }
    }
    for spec in leaf.positionals {
      lines.append("")
      lines.append("  " + pad("<\(spec.name)>", 34) + spec.summary)
    }
    for group in leaf.requiresExactlyOneOf {
      lines.append("")
      lines.append("exactly one of: " + group.joined(separator: ", "))
    }
    for group in leaf.mutuallyExclusive {
      lines.append("at most one of: " + group.joined(separator: ", "))
    }
    if !leaf.outputModes.isEmpty {
      lines.append("")
      lines.append("output modes: " + leaf.outputModes.map(\.rawValue).joined(separator: ", "))
    }
    if leaf.connectsToRuntime {
      lines.append("")
      lines.append("talks to arkdeck-agentd over the current user's private local socket.")
      lines.append("typed operation inputs come from `arkdeck operation describe`, not here.")
    }
    return lines.joined(separator: "\n")
  }

  static func usage(path: [String], leaf: CLILeafSpec) -> String {
    var parts = ["arkdeck"] + path
    for spec in leaf.positionals {
      let token = spec.isVariadic ? "<\(spec.name)…>" : "<\(spec.name)>"
      parts.append(spec.isRequired ? token : "[\(token)]")
    }
    for option in leaf.options where option.isPublished {
      let head = option.name + (option.takesValue ? " " + placeholder(option) : "")
      parts.append(option.isRequired ? head : "[\(head)]")
    }
    return parts.joined(separator: " ")
  }

  // MARK: Version

  /// §12: every independently versioned contract, reported separately, and a
  /// build identity. These are this client's own capabilities — nothing here
  /// connects to a daemon, so none of it is a negotiated protocol version.
  static func versionResult() -> JSONValue {
    var fields: [String: JSONValue] = [
      "cliProductVersion": .string(CLIProductVersion.product),
      "commandRegistrySchemaVersion": .string(CLIProductVersion.commandRegistrySchema),
      "preferredControlProtocolVersion": .string(CLIProductVersion.preferredControlProtocol),
      "supportedControlProtocolExactVersions": .array(
        CLIProductVersion.supportedControlProtocolExactVersions.map(JSONValue.string)),
      "machineContractVersion": .string(CLIProductVersion.machineContract),
      "buildIdentity": CLIBuildIdentity.current().map(JSONValue.string) ?? .null,
    ]
    for (key, value) in versionComponents {
      fields[key] = value.map(JSONValue.string) ?? .null
    }
    return .object(fields)
  }

  /// The individually pinned components, in the order §12 lists them. A `nil`
  /// is a component this build does not publish, not an omission.
  private static var versionComponents: [(String, String?)] {
    [
      ("resultSchemaVersion", CLIProductVersion.resultSchema),
      ("pageSchemaVersion", CLIProductVersion.pageSchema),
      ("eventSchemaVersion", CLIProductVersion.eventSchema),
      ("nextActionSchemaVersion", CLIProductVersion.nextActionSchema),
      ("errorRegistryVersion", CLIProductVersion.errorRegistry),
      ("canonicalJsonVersion", CLIProductVersion.canonicalJson),
    ]
  }

  /// §12 requires human mode to list the same set, not just a build banner.
  static func versionHuman() -> String {
    var lines = [
      "arkdeck \(CLIProductVersion.product)",
      pad("  command registry schema", 34)
        + CLIProductVersion.commandRegistrySchema,
      pad("  control protocol preferred", 34) + CLIProductVersion.preferredControlProtocol,
      pad("  control protocol supported", 34)
        + CLIProductVersion.supportedControlProtocolExactVersions.joined(separator: ", "),
      pad("  machine contract", 34) + CLIProductVersion.machineContract,
    ]
    for (key, value) in versionComponents {
      lines.append(pad("    " + key, 34) + (value ?? "not published by this build"))
    }
    lines.append(pad("  build identity", 34) + (CLIBuildIdentity.current() ?? "unavailable"))
    return lines.joined(separator: "\n")
  }

  // MARK: Helpers

  private static func summary(forPath path: String) -> String? {
    let tokens = path.split(separator: " ").map(String.init)
    guard let first = tokens.first else { return nil }
    if let leaf = CLICommandRegistry.rootLeaf(first), tokens.count == 1 { return leaf.summary }
    guard let node = CLICommandRegistry.node(first) else { return nil }
    if tokens.count == 1 {
      if let only = node.leaves.first, node.leaves.count == 1, only.token.isEmpty {
        return only.summary
      }
      return node.summary
    }
    return node.leaves.first { $0.token == tokens[1] }?.summary
  }

  private static func statusSuffix(_ leaf: CLILeafSpec) -> String {
    switch leaf.kind {
    case .executable: return ""
    case .tombstone: return "  (retired)"
    case .refused: return "  (not caller-facing)"
    }
  }

  private static func placeholder(_ option: CLIOptionSpec) -> String {
    if case .value(let placeholder, _) = option.form { return "<\(placeholder)>" }
    return ""
  }

  private static func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
  }
}

/// The machine projection an external agent reads instead of parsing help
/// text (§10).
enum CLIRegistryProjection {
  static func result() -> JSONValue {
    var commands: [JSONValue] = []
    for (path, leaf) in CLICommandRegistry.allLeaves() {
      commands.append(project(path: path, leaf: leaf))
    }
    return .object([
      "commandRegistrySchemaVersion": .string(CLICommandRegistry.schemaVersion),
      "commands": .array(commands),
    ])
  }

  private static func project(path: [String], leaf: CLILeafSpec) -> JSONValue {
    var fields: [String: JSONValue] = [
      "command": .string(leaf.canonicalCommand),
      "path": .array(path.map(JSONValue.string)),
      "summary": .string(leaf.summary),
      "connectsToRuntime": .bool(leaf.connectsToRuntime),
      "outputModes": .array(leaf.outputModes.map { .string($0.rawValue) }),
      "options": .array(leaf.options.map(project(option:))),
      "positionals": .array(leaf.positionals.map(project(positional:))),
      "mutuallyExclusive": .array(
        leaf.mutuallyExclusive.map { .array($0.map(JSONValue.string)) }),
      "requiresExactlyOneOf": .array(
        leaf.requiresExactlyOneOf.map { .array($0.map(JSONValue.string)) }),
    ]
    switch leaf.kind {
    case .executable:
      fields["kind"] = .string("executable")
    case .tombstone(let tombstone):
      fields["kind"] = .string("tombstone")
      fields["lifecycleStatus"] = .string("removed")
      fields["replacementArgvPattern"] =
        tombstone.replacementArgvPattern.map(JSONValue.string) ?? .null
      fields["removalVersion"] = tombstone.removalVersion.map(JSONValue.string) ?? .null
      if let reason = tombstone.reason { fields["replacementReason"] = .string(reason) }
    case .refused(let reason):
      fields["kind"] = .string("refused")
      fields["refusalReason"] = .string(reason)
    }
    return .object(fields)
  }

  private static func project(option: CLIOptionSpec) -> JSONValue {
    var fields: [String: JSONValue] = [
      "name": .string(option.name),
      "required": .bool(option.isRequired),
      "published": .bool(option.isPublished),
      "summary": .string(option.summary),
    ]
    switch option.form {
    case .flag:
      fields["form"] = .string("flag")
    case .value(let placeholder, let grammar):
      fields["form"] = .string("value")
      fields["placeholder"] = .string(placeholder)
      fields["grammar"] = project(grammar: grammar)
    }
    switch option.stability {
    case .standard: fields["stability"] = .string("standard")
    case .macosCompatibilityOnly: fields["stability"] = .string("macosCompatibilityOnly")
    case .refusedByName: fields["stability"] = .string("refusedByName")
    }
    return .object(fields)
  }

  private static func project(positional: CLIPositionalSpec) -> JSONValue {
    .object([
      "name": .string(positional.name),
      "summary": .string(positional.summary),
      "required": .bool(positional.isRequired),
      "variadic": .bool(positional.isVariadic),
      "grammar": project(grammar: positional.grammar),
    ])
  }

  private static func project(grammar: CLIValueGrammar) -> JSONValue {
    switch grammar {
    case .opaque:
      return .object(["kind": .string("opaque")])
    case .positiveInteger(let range):
      var fields: [String: JSONValue] = [
        "kind": .string("positiveInteger"),
        "minimum": .integer(Int64(range.lowerBound)),
      ]
      if range.upperBound != Int.max { fields["maximum"] = .integer(Int64(range.upperBound)) }
      return .object(fields)
    case .enumeration(let allowed):
      return .object([
        "kind": .string("enumeration"),
        "values": .array(allowed.map(JSONValue.string)),
      ])
    }
  }

  /// Human rendering of the same projection: one line per command.
  static func human() -> String {
    CLICommandRegistry.allLeaves().map { path, leaf in
      let status: String
      switch leaf.kind {
      case .executable: status = ""
      case .tombstone: status = "  (retired)"
      case .refused: status = "  (not caller-facing)"
      }
      return path.joined(separator: " ") + status
    }.joined(separator: "\n")
  }
}

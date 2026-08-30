import ArkDeckCore
import Foundation

/// What an argv array asked for, once the registry has judged it.
enum CLIInvocation {
  case rootHelp
  case nodeHelp(CLINodeSpec)
  case leafHelp(path: [String], leaf: CLILeafSpec)
  case version(mode: CLIOutputMode)
  case commands(mode: CLIOutputMode)
  case completion(shell: String)
  /// A product command that passed every registry check. `handlerArguments` is
  /// the argv slice starting at the first path token, which is the shape the
  /// existing family handlers already take.
  case dispatch(path: [String], leaf: CLILeafSpec, handlerArguments: [String])
}

/// The only thing allowed to interpret argv.
///
/// Every rule here is a registry lookup rather than a literal, so a command
/// added to `CLICommandRegistry` is parseable, helpable and completable without
/// touching this file. CLI-REQ-005 is what it enforces: unknown, repeated,
/// valueless, mutually exclusive and inapplicable arguments are refused, never
/// dropped.
enum CLIArgumentParser {

  // MARK: Renderer bootstrap (§8.1)

  /// Picks the renderer for a failure that happens before — or instead of —
  /// a successful parse.
  ///
  /// It deliberately does not validate anything else: an agent that mistyped a
  /// flag still needs the refusal in the machine shape it asked for, and that
  /// decision has to be made before the command path is known. A malformed
  /// `--output` is answered in `human` on purpose; emitting a machine frame
  /// while unsure which mode the caller wanted is how a consumer ends up
  /// parsing a document it never requested.
  static func bootstrapOutputMode(_ argv: [String]) -> CLIOutputMode {
    let positions = argv.indices.filter { argv[$0] == CLICommandRegistry.outputOption.name }
    guard positions.count == 1, let position = positions.first,
      position + 1 < argv.count,
      let mode = CLIOutputMode(rawValue: argv[position + 1]),
      mode != .human
    else {
      return .human
    }
    return mode
  }

  /// §8.1: the correlation identity used for this invocation, chosen before
  /// the parse so an argv failure still carries one.
  ///
  /// Exactly one syntactically valid value is echoed. A missing, repeated or
  /// malformed one produces a fresh bounded identity rather than putting
  /// unvalidated caller bytes into machine output.
  static func bootstrapControlRequestID(_ argv: [String]) -> String {
    let positions = argv.indices.filter { argv[$0] == CLICommandRegistry.controlRequestIDOption.name
    }
    guard positions.count == 1, let position = positions.first, position + 1 < argv.count,
      CLIControlRequestID.isValid(argv[position + 1])
    else {
      return CLIControlRequestID.generated()
    }
    return argv[position + 1]
  }

  // MARK: Parse

  static func parse(_ argv: [String]) -> Result<CLIInvocation, CLIRegistryError> {
    guard !argv.isEmpty else { return .success(.rootHelp) }

    var state = ParseState()
    var index = 0

    // Phase 1 — global options ahead of the command path (§5.1).
    while index < argv.count, argv[index].hasPrefix("-") {
      switch consumeGlobal(argv, at: &index, into: &state) {
      case .consumed: continue
      case .notGlobal:
        return .failure(
          CLIRegistryError(
            code: .invalidOption,
            message:
              "unknown option \(argv[index]) before the command path; "
              + "run `arkdeck commands` to list the published surface",
            details: ["option": .string(argv[index])]))
      case .failed(let error): return .failure(error)
      }
    }

    // A bare `--version` or `--help` is a complete request.
    if index == argv.count {
      if state.sawVersion { return finishVersion(state) }
      if let refusal = helpIsNotMachineReadable(state) { return .failure(refusal) }
      return .success(.rootHelp)
    }

    // Phase 2 — the command path.
    let pathStart = index
    let resolution = resolvePath(argv, from: &index, state: &state)
    switch resolution {
    case .failure(let error): return .failure(error)
    case .success(.node(let path, let node)):
      // A node is not a command. `--help` makes it a help request; anything
      // else is an incomplete command path.
      if state.sawHelp {
        if let refusal = helpIsNotMachineReadable(state) { return .failure(refusal) }
        return .success(.nodeHelp(node))
      }
      return .failure(
        CLIRegistryError(
          code: .invalidCommand,
          message:
            "`\(path.joined(separator: " "))` needs a subcommand: "
            + node.childTokens.joined(separator: "|"),
          details: ["command": .string(path.joined(separator: "."))]))
    case .success(.leaf(let path, let leaf)):
      return parseLeaf(
        argv, path: path, leaf: leaf, from: index, pathStart: pathStart, state: state)
    }
  }

  // MARK: - Internals

  private struct ParseState {
    var sawHelp = false
    var sawVersion = false
    var outputRaw: String?
  }

  private enum GlobalOutcome {
    case consumed
    case notGlobal
    case failed(CLIRegistryError)
  }

  /// Consumes one global-position option. `--help`/`-h`/`--version` are the
  /// options every node answers; `--output` is position-global but still has to
  /// be applicable to whatever the path resolves to (§5.2).
  private static func consumeGlobal(
    _ argv: [String], at index: inout Int, into state: inout ParseState
  ) -> GlobalOutcome {
    let token = argv[index]
    if CLICommandRegistry.helpOptionNames.contains(token) {
      if state.sawHelp { return .failed(duplicate(token)) }
      state.sawHelp = true
      index += 1
      return .consumed
    }
    if token == CLICommandRegistry.versionOptionName {
      if state.sawVersion { return .failed(duplicate(token)) }
      state.sawVersion = true
      index += 1
      return .consumed
    }
    if token == CLICommandRegistry.outputOption.name {
      if state.outputRaw != nil { return .failed(duplicate(token)) }
      guard index + 1 < argv.count else { return .failed(missingValue(token)) }
      state.outputRaw = argv[index + 1]
      index += 2
      return .consumed
    }
    return .notGlobal
  }

  private enum PathTarget {
    /// A group, with the tokens that reached it — an incomplete path has to be
    /// reported as the caller typed it, not as the last token alone.
    case node(path: [String], node: CLINodeSpec)
    case leaf(path: [String], leaf: CLILeafSpec)
  }

  private static func resolvePath(
    _ argv: [String], from index: inout Int, state: inout ParseState
  ) -> Result<PathTarget, CLIRegistryError> {
    let first = argv[index]
    index += 1

    if let leaf = CLICommandRegistry.rootLeaf(first) {
      return .success(.leaf(path: [first], leaf: leaf))
    }
    guard var node = CLICommandRegistry.node(first) else {
      return .failure(
        CLIRegistryError(
          code: .invalidCommand,
          message:
            "unknown command `\(first)`; run `arkdeck commands` to list the published surface",
          details: ["command": .string(first)]))
    }

    // Groups nest, so walk down until a leaf token matches or the path runs
    // out. `doctor` is the degenerate case: a node whose single leaf has an
    // empty token *is* the command.
    var path = [first]
    while true {
      if node.leaves.count == 1, let only = node.leaves.first, only.token.isEmpty {
        return .success(.leaf(path: path, leaf: only))
      }
      guard index < argv.count else { return .success(.node(path: path, node: node)) }

      let next = argv[index]
      if next.hasPrefix("-") {
        // §5.1: global options never sit between path tokens. `--help` is the
        // one token that can complete the request here, because a node with no
        // subcommand is exactly when a caller needs to be shown its children.
        if CLICommandRegistry.helpOptionNames.contains(next) {
          if state.sawHelp { return .failure(duplicate(next)) }
          state.sawHelp = true
          index += 1
          return .success(.node(path: path, node: node))
        }
        return .failure(
          CLIRegistryError(
            code: .invalidOption,
            message:
              "`\(path.joined(separator: " "))` needs a subcommand before any option: "
              + node.childTokens.joined(separator: "|"),
            details: [
              "command": .string(path.joined(separator: ".")), "option": .string(next),
            ]))
      }
      index += 1
      path.append(next)
      if let leaf = node.leaves.first(where: { $0.token == next }) {
        return .success(.leaf(path: path, leaf: leaf))
      }
      guard let group = node.groups.first(where: { $0.token == next }) else {
        return .failure(
          CLIRegistryError(
            code: .invalidCommand,
            message:
              "unknown `\(path.dropLast().joined(separator: " "))` subcommand `\(next)`: "
              + node.childTokens.joined(separator: "|"),
            details: [
              "command": .string(path.dropLast().joined(separator: ".")),
              "subcommand": .string(next),
            ]))
      }
      node = group
    }
  }

  private static func parseLeaf(
    _ argv: [String],
    path: [String],
    leaf: CLILeafSpec,
    from start: Int,
    pathStart: Int,
    state initialState: ParseState
  ) -> Result<CLIInvocation, CLIRegistryError> {
    var state = initialState

    // A tombstone or a permanent refusal answers by name. Parsing its old
    // flags strictly would answer a caller who typed the retired command
    // *with its retired flags* by naming the flag, which tells them nothing
    // about the command being gone.
    if case .executable = leaf.kind {} else {
      let asksForHelp =
        state.sawHelp
        || argv[start...].contains { CLICommandRegistry.helpOptionNames.contains($0) }
      if asksForHelp {
        if let refusal = helpIsNotMachineReadable(state) { return .failure(refusal) }
        return .success(.leafHelp(path: path, leaf: leaf))
      }
      switch leaf.kind {
      case .tombstone(let tombstone):
        return .failure(removedError(path: path, leaf: leaf, tombstone: tombstone))
      case .refused(let reason):
        return .failure(
          CLIRegistryError(
            code: .invalidCommand,
            message: "`\(path.joined(separator: " "))` is not caller-facing: \(reason)",
            details: ["command": .string(leaf.canonicalCommand)],
            command: leaf.canonicalCommand))
      case .executable:
        break
      }
    }

    var provided: [String: String?] = [:]
    var positionals: [String] = []
    var index = start

    while index < argv.count {
      let token = argv[index]
      if token.hasPrefix("-"), token != "-" {
        if let option = leaf.options.first(where: { $0.name == token }) {
          if provided.keys.contains(token) { return .failure(duplicate(token, command: leaf)) }
          if option.takesValue {
            guard index + 1 < argv.count else {
              return .failure(missingValue(token, command: leaf))
            }
            provided[token] = argv[index + 1]
            index += 2
          } else {
            provided[token] = String?.none
            index += 1
          }
          continue
        }
        // Not a leaf option — the trailing global region (§5.1).
        switch consumeGlobal(argv, at: &index, into: &state) {
        case .consumed: continue
        case .failed(let error): return .failure(error)
        case .notGlobal:
          return .failure(
            CLIRegistryError(
              code: .invalidOption,
              message:
                "`\(path.joined(separator: " "))` does not accept \(token); "
                + "run `arkdeck help \(path.joined(separator: " "))` for its options",
              details: ["command": .string(leaf.canonicalCommand), "option": .string(token)],
              command: leaf.canonicalCommand))
        }
      }
      positionals.append(token)
      index += 1
    }

    if state.sawHelp {
      if let refusal = helpIsNotMachineReadable(state) { return .failure(refusal) }
      return .success(.leafHelp(path: path, leaf: leaf))
    }
    if state.sawVersion { return finishVersion(state) }

    // `--output` is position-global but leaf-scoped: a leaf that does not
    // declare it must refuse it rather than drop it (§5.2). A leaf that does
    // declare it captures it as one of its own options, so both spellings end
    // up here — and giving it twice, once in each region, is still a duplicate.
    var outputMode = CLIOutputMode.human
    if let leafOutput = provided[CLICommandRegistry.outputOption.name] {
      if state.outputRaw != nil {
        return .failure(duplicate(CLICommandRegistry.outputOption.name, command: leaf))
      }
      state.outputRaw = leafOutput
    }
    if let raw = state.outputRaw {
      guard leaf.options.contains(where: { $0.name == CLICommandRegistry.outputOption.name })
      else {
        return .failure(
          CLIRegistryError(
            code: .invalidOption,
            message:
              "`\(path.joined(separator: " "))` does not accept --output in this release; "
              + (leaf.options.contains(where: { $0.name == "--json" })
                ? "use --json" : "it renders one human summary"),
            details: ["command": .string(leaf.canonicalCommand)],
            command: leaf.canonicalCommand))
      }
      guard let mode = CLIOutputMode(rawValue: raw), leaf.outputModes.contains(mode) else {
        return .failure(
          CLIRegistryError(
            code: .invalidOption,
            message:
              "--output must be one of "
              + leaf.outputModes.map(\.rawValue).joined(separator: "|"),
            details: ["command": .string(leaf.canonicalCommand), "value": .string(raw)],
            command: leaf.canonicalCommand))
      }
      outputMode = mode
    }

    if let error = validate(leaf: leaf, path: path, provided: provided, positionals: positionals) {
      return .failure(error)
    }

    switch leaf.canonicalCommand {
    case "commands": return .success(.commands(mode: outputMode))
    case "completion": return .success(.completion(shell: positionals[0]))
    case "help":
      return helpInvocation(for: positionals)
    default:
      return .success(
        .dispatch(path: path, leaf: leaf, handlerArguments: Array(argv[pathStart...])))
    }
  }

  private static func helpInvocation(
    for path: [String]
  ) -> Result<CLIInvocation, CLIRegistryError> {
    guard let first = path.first else { return .success(.rootHelp) }
    if let leaf = CLICommandRegistry.rootLeaf(first), path.count == 1 {
      return .success(.leafHelp(path: [first], leaf: leaf))
    }
    guard let node = CLICommandRegistry.node(first) else {
      return .failure(
        CLIRegistryError(
          code: .invalidCommand,
          message: "unknown command `\(first)`",
          details: ["command": .string(first)],
          command: "help"))
    }
    if node.leaves.count == 1, let only = node.leaves.first, only.token.isEmpty, path.count == 1 {
      return .success(.leafHelp(path: [node.token], leaf: only))
    }
    if path.count == 1 { return .success(.nodeHelp(node)) }
    var walked = node
    for (offset, token) in path.dropFirst().enumerated() {
      if let leaf = walked.leaves.first(where: { $0.token == token }),
        offset == path.count - 2
      {
        return .success(.leafHelp(path: path, leaf: leaf))
      }
      guard let group = walked.groups.first(where: { $0.token == token }) else { break }
      walked = group
      if offset == path.count - 2 { return .success(.nodeHelp(walked)) }
    }
    return .failure(
      CLIRegistryError(
        code: .invalidCommand,
        message: "unknown command path `\(path.joined(separator: " "))`",
        details: ["command": .string(path.joined(separator: " "))],
        command: "help"))
  }

  private static func validate(
    leaf: CLILeafSpec,
    path: [String],
    provided: [String: String?],
    positionals: [String]
  ) -> CLIRegistryError? {
    let name = path.joined(separator: " ")

    for option in leaf.options {
      guard let recorded = provided[option.name] else {
        if option.isRequired {
          return CLIRegistryError(
            code: .invalidOption,
            message: "`\(name)` requires \(option.name) \(placeholder(option))",
            details: ["command": .string(leaf.canonicalCommand), "option": .string(option.name)],
            command: leaf.canonicalCommand)
        }
        continue
      }
      guard case .value(_, let grammar) = option.form, let value = recorded else { continue }
      if let error = check(grammar, value: value, label: option.name, leaf: leaf, name: name) {
        return error
      }
    }

    for group in leaf.mutuallyExclusive {
      let present = group.filter { provided.keys.contains($0) }
      if present.count > 1 {
        return CLIRegistryError(
          code: .invalidOption,
          message: "`\(name)` accepts only one of \(present.sorted().joined(separator: ", "))",
          details: [
            "command": .string(leaf.canonicalCommand),
            "options": .array(present.sorted().map(JSONValue.string)),
          ],
          command: leaf.canonicalCommand)
      }
    }

    for group in leaf.requiresExactlyOneOf {
      let present = group.filter { provided.keys.contains($0) }
      if present.count != 1 {
        return CLIRegistryError(
          code: .invalidOption,
          message: "`\(name)` requires exactly one of \(group.joined(separator: ", "))",
          details: [
            "command": .string(leaf.canonicalCommand),
            "options": .array(group.map(JSONValue.string)),
          ],
          command: leaf.canonicalCommand)
      }
    }

    var remaining = positionals
    for spec in leaf.positionals {
      if spec.isVariadic {
        remaining = []
        continue
      }
      guard !remaining.isEmpty else {
        if spec.isRequired {
          return CLIRegistryError(
            code: .invalidOption,
            message: "`\(name)` requires a \(spec.name) argument (\(spec.summary))",
            details: ["command": .string(leaf.canonicalCommand)],
            command: leaf.canonicalCommand)
        }
        continue
      }
      let value = remaining.removeFirst()
      if let error = check(spec.grammar, value: value, label: spec.name, leaf: leaf, name: name) {
        return error
      }
    }
    if !remaining.isEmpty {
      return CLIRegistryError(
        code: .invalidOption,
        message: "`\(name)` does not take the argument `\(remaining[0])`",
        details: ["command": .string(leaf.canonicalCommand)],
        command: leaf.canonicalCommand)
    }
    return nil
  }

  private static func check(
    _ grammar: CLIValueGrammar, value: String, label: String, leaf: CLILeafSpec, name: String
  ) -> CLIRegistryError? {
    switch grammar {
    case .opaque:
      // Whether the value means anything is the receiving contract's judgement,
      // not the parser's. Re-deriving a Runtime rule here is how two validators
      // start disagreeing about the same input.
      return nil
    case .nonNegativeInteger(let range):
      if value == "0" { return range.contains(0) ? nil : outOfRange(range, value, label, leaf, name) }
      return check(.positiveInteger(range), value: value, label: label, leaf: leaf, name: name)
    case .positiveInteger(let range):
      // No sign, no leading zero, no whitespace: `Int(_:)` alone accepts `+7`
      // and `007`, which are two more spellings of the same value than a
      // portable fixture can afford.
      let isPlainDigits =
        !value.isEmpty && value.allSatisfy(\.isASCII) && value.allSatisfy(\.isNumber)
        && value.first != "0"
      guard isPlainDigits, let parsed = Int(value), range.contains(parsed) else {
        return outOfRange(range, value, label, leaf, name)
      }
      return nil
    case .controlRequestID:
      guard CLIControlRequestID.isValid(value) else {
        return CLIRegistryError(
          code: .invalidOption,
          message:
            "`\(name)` \(label) must match ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$",
          details: [
            "command": .string(leaf.canonicalCommand), "option": .string(label),
          ],
          command: leaf.canonicalCommand)
      }
      return nil
    case .hexDigest(let length):
      let isLowercaseHex =
        value.count == length
        && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
      guard isLowercaseHex else {
        return CLIRegistryError(
          code: .invalidOption,
          message: "`\(name)` \(label) must be \(length) lowercase hex digits",
          details: [
            "command": .string(leaf.canonicalCommand), "option": .string(label),
          ],
          command: leaf.canonicalCommand)
      }
      return nil
    case .enumeration(let allowed):
      guard allowed.contains(value) else {
        return CLIRegistryError(
          code: .invalidOption,
          message: "`\(name)` \(label) must be one of \(allowed.joined(separator: "|"))",
          details: [
            "command": .string(leaf.canonicalCommand), "option": .string(label),
            "value": .string(value),
          ],
          command: leaf.canonicalCommand)
      }
      return nil
    }
  }

  /// §12 fixes the shape of a removed token's answer: a lifecycle status, the
  /// exact argv pattern that replaces it (or an explicit `null`), and the
  /// version that removed it. "Retired" alone would leave an agent guessing.
  private static func outOfRange(
    _ range: ClosedRange<Int>, _ value: String, _ label: String, _ leaf: CLILeafSpec,
    _ name: String
  ) -> CLIRegistryError {
    // An open-ended range has to read as a lower bound. "must be 0" would tell
    // a caller the only accepted offset is zero.
    let bound =
      range.upperBound == Int.max
      ? "\(range.lowerBound) or greater" : "\(range.lowerBound)...\(range.upperBound)"
    return CLIRegistryError(
      code: .invalidOption,
      message: "`\(name)` \(label) must be \(bound)",
      details: [
        "command": .string(leaf.canonicalCommand), "option": .string(label),
        "value": .string(value),
      ],
      command: leaf.canonicalCommand)
  }

  private static func removedError(
    path: [String], leaf: CLILeafSpec, tombstone: CLITombstone
  ) -> CLIRegistryError {
    var details: [String: JSONValue] = [
      "command": .string(leaf.canonicalCommand),
      "lifecycleStatus": .string("removed"),
      "replacementArgvPattern": tombstone.replacementArgvPattern.map(JSONValue.string) ?? .null,
      "removalVersion": tombstone.removalVersion.map(JSONValue.string) ?? .null,
    ]
    let sentence: String
    if let pattern = tombstone.replacementArgvPattern {
      sentence = "use `\(pattern)`"
    } else {
      let reason = tombstone.reason ?? "nothing replaces it"
      details["reason"] = .string(reason)
      sentence = reason
    }
    return CLIRegistryError(
      code: .commandRemoved,
      message: "`\(path.joined(separator: " "))` is retired: \(sentence)",
      details: details,
      command: leaf.canonicalCommand)
  }

  /// Help is prose. Asking for it in a machine mode has to be refused rather
  /// than answered with text the caller cannot parse — the machine projection
  /// of the surface is `commands --output json`.
  private static func helpIsNotMachineReadable(_ state: ParseState) -> CLIRegistryError? {
    guard state.outputRaw != nil else { return nil }
    return CLIRegistryError(
      code: .invalidOption,
      message:
        "help renders human text only; use `arkdeck commands --output json` for the "
        + "machine projection of the command surface")
  }

  private static func finishVersion(
    _ state: ParseState
  ) -> Result<CLIInvocation, CLIRegistryError> {
    guard let raw = state.outputRaw else { return .success(.version(mode: .human)) }
    guard let mode = CLIOutputMode(rawValue: raw), mode != .jsonl else {
      return .failure(
        CLIRegistryError(
          code: .invalidOption,
          message: "--version --output must be human|json",
          details: ["value": .string(raw)]))
    }
    return .success(.version(mode: mode))
  }

  private static func placeholder(_ option: CLIOptionSpec) -> String {
    if case .value(let placeholder, _) = option.form { return "<\(placeholder)>" }
    return ""
  }

  private static func duplicate(_ token: String, command leaf: CLILeafSpec? = nil)
    -> CLIRegistryError
  {
    CLIRegistryError(
      code: .invalidOption,
      message: "\(token) was given more than once",
      details: ["option": .string(token)],
      command: leaf?.canonicalCommand)
  }

  private static func missingValue(_ token: String, command leaf: CLILeafSpec? = nil)
    -> CLIRegistryError
  {
    CLIRegistryError(
      code: .invalidOption,
      message: "\(token) requires a value",
      details: ["option": .string(token)],
      command: leaf?.canonicalCommand)
  }
}

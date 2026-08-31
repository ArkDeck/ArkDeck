import Foundation

/// The one description of what `arkdeck` accepts.
///
/// Before this file the command surface existed three times: a hand-written
/// `switch` per family that read flags by scanning for them, a 90-line usage
/// string, and a contract test that scraped both for `--tokens`. The three
/// disagreed — eleven flags were accepted and never published (fixed by
/// `CLIUsageOptionCoverageContractTests`), and on the Runtime families an
/// unknown, duplicated or inapplicable flag was silently dropped instead of
/// refused, because `firstIndex(of:)` finds what it is looking for and never
/// looks at the rest.
///
/// The product spec (`docs/design/arkdeck-cli-product-spec.md` §5.1) makes the
/// registry the single generator for parser, help, completion and the option
/// tests, and CLI-REQ-005 makes every unknown, repeated, valueless, mutually
/// exclusive or inapplicable argument an error. Both need one machine-readable
/// description of the surface rather than three hand-maintained ones, so this
/// is that description; `CLIArgumentParser` is the only consumer allowed to
/// interpret argv.
///
/// It deliberately does not describe *operation* inputs. `operation describe`
/// is the fact source for those (§10), and a second copy here would drift
/// against the Catalog.

// MARK: - Model

/// How an option carries its value.
enum CLIOptionForm: Equatable {
  /// Present or absent; never followed by a value.
  case flag
  /// Followed by exactly one value token.
  case value(placeholder: String, grammar: CLIValueGrammar)
}

/// The local check applied to an option value before anything is dispatched.
///
/// Values that only the daemon or the Catalog can judge stay `.opaque` here —
/// re-deriving a Runtime rule in the client is how two validators start
/// disagreeing about the same input.
enum CLIValueGrammar: Equatable {
  /// Non-empty; meaning belongs to the receiving contract.
  case opaque
  /// `^[1-9][0-9]*$` inside the closed range, no leading zero or sign.
  case positiveInteger(ClosedRange<Int>)
  /// The same, plus a bare `0`. A byte offset starts at zero, and reusing the
  /// positive grammar for it would refuse the first read of every artifact.
  case nonNegativeInteger(ClosedRange<Int>)
  /// One of a closed set of tokens, compared byte for byte.
  case enumeration([String])
  /// Exactly `length` lowercase hex digits. §11.3 fixes digests as lowercase
  /// hex, and accepting both cases would make the same digest two tokens.
  case hexDigest(length: Int)
  /// §8.1's correlation identity: `^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`.
  case controlRequestID
  /// §5.2's duration: `^[1-9][0-9]*(ms|s|m|h)$`, no larger than the ceiling.
  ///
  /// The unit is part of the value rather than a convention, because a bare
  /// integer means different things to different commands and the difference
  /// between 30 seconds and 30 minutes is not something to infer. Zero,
  /// negatives, decimals, compound units and whitespace are all refused: each
  /// of them is a caller meaning something the receiving contract cannot
  /// represent, and accepting any of them would round it silently.
  ///
  /// The ceiling is in milliseconds and is declared per option, because a
  /// wait budget's sane maximum belongs to the command that waits.
  case duration(maximumMilliseconds: Int)
}

/// One parsed §5.2 duration.
///
/// Kept as milliseconds because that is the smallest unit the grammar admits,
/// so every legal value is an exact integer here and no conversion rounds.
struct CLIDuration: Equatable {
  let milliseconds: Int

  var seconds: Double { Double(milliseconds) / 1000 }

  /// Parses §5.2's grammar, refusing anything that would overflow the ceiling
  /// rather than clamping to it. A caller who asked for a week and got an hour
  /// would be told nothing, and would blame the wrong thing when the wait
  /// ended early.
  static func parse(_ text: String, maximumMilliseconds: Int) -> CLIDuration? {
    let units: [(suffix: String, scale: Int)] = [
      ("ms", 1), ("s", 1000), ("m", 60_000), ("h", 3_600_000),
    ]
    // Longest suffix first: `ms` also ends in `s`, and matching `s` would read
    // `500ms` as 500 000 ms.
    guard let unit = units.first(where: { text.hasSuffix($0.suffix) }) else { return nil }
    let digits = String(text.dropLast(unit.suffix.count))
    guard !digits.isEmpty, digits.first != "0",
      digits.allSatisfy({ $0.isASCII && $0.isNumber }),
      let magnitude = Int(digits)
    else { return nil }
    // Checked before multiplying: the product of a legal-looking magnitude and
    // an hour is exactly where a duration overflows into a negative wait.
    let (milliseconds, overflowed) = magnitude.multipliedReportingOverflow(by: unit.scale)
    guard !overflowed, milliseconds <= maximumMilliseconds else { return nil }
    return CLIDuration(milliseconds: milliseconds)
  }
}

/// Why an option exists on this leaf, which decides whether help publishes it.
enum CLIOptionStability: Equatable {
  /// Part of the published product surface.
  case standard
  /// Accepted on macOS only, and never advertised.
  ///
  /// §11.1 pins `--socket` as `macosCompatibilityOnly`: a Windows parser must
  /// recognise the metadata and answer `unsupportedOnPlatform` rather than
  /// read the value as a named-pipe path. Marking it in the registry is what
  /// lets a native port inherit that refusal without re-reading Swift.
  case macosCompatibilityOnly
  /// Read only so it can be refused by name.
  ///
  /// Muscle memory for a retired flag deserves a real answer; publishing it in
  /// help would advertise configuration that no longer exists.
  case refusedByName
}

/// A single option on one leaf.
struct CLIOptionSpec: Equatable {
  let name: String
  let form: CLIOptionForm
  let summary: String
  var isRequired: Bool = false
  var stability: CLIOptionStability = .standard

  var takesValue: Bool {
    if case .value = form { return true }
    return false
  }

  var isPublished: Bool { stability == .standard }
}

/// What a leaf does when it is reached.
enum CLILeafKind: Equatable {
  /// Runs.
  case executable
  /// Recognised so the old token gets a stable answer, never dispatched.
  ///
  /// §5.1 forbids a tombstone from holding a Runtime method or operation
  /// mapping: it exists to name the replacement, not to keep the old path
  /// alive behind a rename.
  case tombstone(CLITombstone)
  /// Recognised and permanently refused — the capability is Runtime-owned and
  /// is not going to gain a caller-facing form.
  case refused(reason: String)
}

/// The machine half of a tombstone answer (§12).
///
/// A removed token answers with a lifecycle status, the exact argv pattern that
/// replaces it, and the version that removed it. "Retired" on its own leaves an
/// agent guessing, which is the failure mode the contract exists to prevent.
struct CLITombstone: Equatable {
  /// The exact argv pattern that does this now, or `nil` when nothing does.
  let replacementArgvPattern: String?
  /// Why there is no replacement. Only meaningful when the pattern is `nil`.
  var reason: String?
  /// The CLI product version that removed the token.
  ///
  /// `nil` for verbs retired before the command registry existed: §12 forbids
  /// guessing a version, and inventing one here would put a fabricated fact in
  /// a machine contract. Every tombstone added from now on carries its exact
  /// removal version.
  var removalVersion: String?

  static func replacedBy(_ pattern: String) -> CLITombstone {
    CLITombstone(replacementArgvPattern: pattern)
  }

  static func noReplacement(reason: String) -> CLITombstone {
    CLITombstone(replacementArgvPattern: nil, reason: reason)
  }
}

/// One executable (or deliberately non-executable) command.
struct CLILeafSpec {
  /// The last path token, e.g. `status`.
  let token: String
  /// The dotted identity used by machine output as `command`, e.g. `job.status`.
  let canonicalCommand: String
  let summary: String
  var kind: CLILeafKind = .executable
  var options: [CLIOptionSpec] = []
  /// Positional arguments, in order. Only meta-commands use these; every
  /// product input is a named option so that argv order never carries meaning.
  var positionals: [CLIPositionalSpec] = []
  /// Groups where at most one member may appear.
  var mutuallyExclusive: [[String]] = []
  /// Groups where exactly one member must appear.
  var requiresExactlyOneOf: [[String]] = []
  /// True when reaching this leaf opens the local control connection. §5.2
  /// scopes `--endpoint`/`--socket` to exactly these leaves; a leaf that
  /// never connects must refuse them rather than drop them.
  var connectsToRuntime: Bool = false
  /// Output modes this leaf can render. §8.1 requires the registry, not the
  /// renderer, to decide this.
  var outputModes: [CLIOutputMode] = [.human]
  /// §12 lifecycle. `legacy` marks an explicit compatibility leaf: it works,
  /// but its request, response and effect are the frozen 1.x ones, so it does
  /// not count as target conformance.
  var lifecycle: CLILifecycleStatus = .current
  /// The exact published Catalog reference this leaf submits.
  ///
  /// §6.2 requires a domain command to declare its mapping in the registry
  /// rather than build a request of its own: the leaf is a name for an
  /// operation, not a second way to reach a device.
  var catalogOperation: String?
  /// The argv pattern that supersedes this leaf, when one is published.
  ///
  /// Independent of `lifecycle`, because the two answer different questions: a
  /// leaf can be a frozen 1.x surface *and* have a replacement (`device list`
  /// is both), and it can be superseded without its own shape being frozen
  /// (`cleanup-debt` is a plain alias). Folding them into one field would make
  /// `legacy` mean two things.
  var replacementArgvPattern: String?
}

struct CLIPositionalSpec: Equatable {
  let name: String
  let summary: String
  var grammar: CLIValueGrammar = .opaque
  /// Consumes every remaining non-option token (used by `help <path…>`).
  var isVariadic: Bool = false
  var isRequired: Bool = true
}

/// §8.1 output modes. Only the modes a leaf declares are accepted.
enum CLIOutputMode: String, Equatable, CaseIterable {
  case human
  case json
  case jsonl
}

/// A group of commands, e.g. `job`.
///
/// Groups nest: §6.3's platform surface is three tokens deep (`runtime hdc
/// status`, `runtime tool register`), so a two-level tree would have forced
/// those into hyphenated leaf names that disagree with the published command
/// tree.
struct CLINodeSpec {
  let token: String
  let summary: String
  var leaves: [CLILeafSpec] = []
  var groups: [CLINodeSpec] = []

  /// Everything reachable from this node, as `(pathSuffix, leaf)`.
  func reachableLeaves() -> [(path: [String], leaf: CLILeafSpec)] {
    var found: [(path: [String], leaf: CLILeafSpec)] = []
    for leaf in leaves {
      found.append((leaf.token.isEmpty ? [token] : [token, leaf.token], leaf))
    }
    for group in groups {
      for reachable in group.reachableLeaves() {
        found.append(([token] + reachable.path, reachable.leaf))
      }
    }
    return found
  }

  /// The child tokens a caller may type next, in declaration order.
  var childTokens: [String] {
    leaves.map(\.token).filter { !$0.isEmpty } + groups.map(\.token)
  }
}

// MARK: - Registry

enum CLICommandRegistry {
  /// Bumped when the shape of the registry projection changes, independently
  /// of the CLI product version and the control protocol (§12).
  static let schemaVersion = "arkdeck.cli.command-registry/1"

  /// Options accepted in the global positions of §5.1 — before the first path
  /// token, or after the leaf's own arguments.
  ///
  /// "Global" is a statement about *position*, not applicability: §5.2 is
  /// explicit that a leaf still refuses a global option it does not declare.
  /// `--help`/`-h`/`--version` are the exceptions that every node answers.
  static let helpOptionNames: Set<String> = ["--help", "-h"]
  static let versionOptionName = "--version"

  /// `--output`. The grammar spells every mode the registry can express; which
  /// of them a given leaf accepts is `outputModes` on that leaf.
  ///
  /// The two layers answer different questions and are worth keeping apart. A
  /// value outside this set is not a mode at all and gets "not one of the
  /// modes"; a real mode the leaf does not offer gets "not one of *this
  /// command's* modes", which is the message that tells a caller asking
  /// `job list --output jsonl` that streaming is a property of the command
  /// rather than a typo. Folding jsonl out of the grammar, as this did while
  /// nothing streamed, made the second message unreachable.
  static let outputOption = CLIOptionSpec(
    name: "--output",
    form: .value(
      placeholder: "human|json",
      grammar: .enumeration(CLIOutputMode.allCases.map(\.rawValue))),
    summary: "output mode; machine modes emit one arkdeck.cli.result/1 document")

  /// §12 keeps `--json` exactly as it was: the daemon reply, pretty-printed,
  /// with no envelope. Changing what an existing flag prints is a breaking
  /// change that belongs to the next CLI major, so `--output json` is the new
  /// contract and this one is the compatibility mode beside it.
  static let jsonOption = CLIOptionSpec(
    name: "--json",
    form: .flag,
    summary: "legacy: print the raw reply as JSON, without the result envelope")

  /// §8.1/§8.2: a caller-supplied correlation identity for one invocation. It
  /// is not a Runtime idempotency key and nothing is derived from it.
  static let controlRequestIDOption = CLIOptionSpec(
    name: "--control-request-id",
    form: .value(placeholder: "id", grammar: .controlRequestID),
    summary: "correlate this control-plane call; not a Job or request identity")

  /// §11.1: recognised on macOS, never advertised, never a business parameter.
  static let socketOption = CLIOptionSpec(
    name: "--socket",
    form: .value(placeholder: "absolute-path", grammar: .opaque),
    summary: "macOS-only compatibility alias for the local Runtime endpoint",
    stability: .macosCompatibilityOnly)

  private static func runtimeClientOptions(_ own: [CLIOptionSpec]) -> [CLIOptionSpec] {
    own + [outputOption, jsonOption, controlRequestIDOption, socketOption]
  }

  /// The two machine-output spellings are exclusive: one invocation prints one
  /// document, in one shape.
  static let outputAndJSONAreExclusive = ["--output", "--json"]

  // MARK: Meta commands

  private static let helpLeaf = CLILeafSpec(
    token: "help",
    canonicalCommand: "help",
    summary: "print help for a command path",
    positionals: [
      CLIPositionalSpec(
        name: "path",
        summary: "command path, e.g. `job status`; omit for root help",
        isVariadic: true,
        isRequired: false)
    ])

  private static let commandsLeaf = CLILeafSpec(
    token: "commands",
    canonicalCommand: "commands",
    summary: "print the command registry projection; the machine discovery entry",
    options: [outputOption],
    outputModes: [.human, .json])

  private static let completionLeaf = CLILeafSpec(
    token: "completion",
    canonicalCommand: "completion",
    summary: "print a static completion script generated from this registry",
    positionals: [
      CLIPositionalSpec(
        name: "shell",
        summary: "bash|zsh|fish|powershell",
        grammar: .enumeration(["bash", "zsh", "fish", "powershell"]))
    ])

  /// Meta-commands are leaves at the root, not a resource namespace (§5.1).
  static let rootLeaves: [CLILeafSpec] = [helpLeaf, commandsLeaf, completionLeaf].map(normalized)

  // MARK: Product commands

  static let nodes: [CLINodeSpec] = declaredNodes.map(normalized(node:))

  private static func normalized(node: CLINodeSpec) -> CLINodeSpec {
    var normalizedNode = node
    normalizedNode.leaves = node.leaves.map(normalized)
    normalizedNode.groups = node.groups.map(normalized(node:))
    return normalizedNode
  }

  /// Facts that follow from a leaf's own declaration, applied once rather than
  /// repeated on every leaf. A leaf that takes `--output` renders `json` by
  /// definition, and the two machine-output spellings exclude each other by
  /// definition; writing both out per leaf is how one of them gets forgotten.
  /// §12's migration table names these as explicit legacy-compatibility
  /// leaves for the current major: they keep the frozen 1.x request, response
  /// and effect, and the target spellings (`target list/show/adopt`,
  /// `recovery flash-invocation ...`, `artifact import <kind>`) arrive on the
  /// negotiated 2.x control protocol. `legacy flash ...` is the exception that
  /// proves the rule: it is published, and it is still `legacy`, because
  /// moving a decode-only archive surface to a clearer name does not turn it
  /// into a target one.
  ///
  /// Marking them is not cosmetic: §12 forbids counting a legacy leaf as
  /// target conformance, and a machine caller has to be able to see which
  /// surface it is driving without reading this file.
  /// The argv pattern that supersedes each superseded leaf.
  ///
  /// A leaf appears here only once its replacement is a real, executable
  /// command — the same rule the tombstones follow, and
  /// `testEveryPublishedReplacementResolvesToALeaf` enforces it. `device adopt`
  /// and the `artifact import-*` verbs are absent because their targets
  /// (`target adopt` with observation identity, `artifact import <kind>`) are
  /// not published yet; naming them now would send a caller from a deprecation
  /// warning into an `invalidCommand`.
  ///
  /// The families §12 renames wholesale — `agentd`, `signing`, `update-feed`
  /// and the two `flash` archive leaves — are not listed here either, because
  /// `compatibilitySpelling` derives their replacement from the target
  /// spelling. A table entry would be a second place to get the same string
  /// right.
  private static let replacementArgvPatterns: [String: String] = [
    "device.list": "arkdeck target list",
    "device.show": "arkdeck target show --target <id>",
    "cleanup-debt.list": "arkdeck recovery cleanup list",
    "cleanup-debt.continue": "arkdeck recovery cleanup continue --job <id> ...",
    "debug.start": "arkdeck recovery flash-invocation start --request-file <path>",
    "debug.evaluate": "arkdeck recovery flash-invocation evaluate --invocation <id> ...",
    "debug.status": "arkdeck recovery flash-invocation status --invocation <id>",
  ]

  private static let legacyCompatibilityCommands: Set<String> = [
    "device.list", "device.show", "device.adopt",
    "debug.start", "debug.evaluate", "debug.status",
    "artifact.import-hap", "artifact.import-workspace-patch",
    "artifact.import-flash-bundle", "artifact.import-native-library",
    "flash.install-binding", "flash.status", "flash.reconcile",
    "legacy.flash.status", "legacy.flash.reconcile",
  ]

  /// The compatibility spelling of a family §12 is migrating.
  ///
  /// §12's migration table keeps every renamed family working under its old
  /// name for the whole of this CLI major — same options, same positionals,
  /// same effect, with a human-mode warning and machine lifecycle metadata.
  /// The target spelling is the declaration and the alias is derived from it,
  /// so the two cannot drift: an option added to `runtime service install`
  /// is on `agentd install` in the same commit. Writing the alias out by hand
  /// is exactly how a family ends up accepting an option under one name and
  /// refusing it under the other, which is the failure §12 is trying to
  /// prevent by keeping the alias at all.
  ///
  /// Three things differ, and each is derived rather than restated: the
  /// canonical command the leaf reports, the lifecycle it carries, and the
  /// argv that supersedes it. The next major deletes one call.
  private static func compatibilitySpelling(
    of leaves: [CLILeafSpec], as legacyToken: String, replacedBy targetArgv: String
  ) -> [CLILeafSpec] {
    leaves.map { leaf in
      var alias = CLILeafSpec(
        token: leaf.token,
        canonicalCommand: "\(legacyToken).\(leaf.token)",
        summary: leaf.summary,
        kind: leaf.kind,
        options: leaf.options,
        positionals: leaf.positionals,
        mutuallyExclusive: leaf.mutuallyExclusive,
        requiresExactlyOneOf: leaf.requiresExactlyOneOf,
        connectsToRuntime: leaf.connectsToRuntime,
        outputModes: leaf.outputModes,
        catalogOperation: leaf.catalogOperation)
      alias.replacementArgvPattern = "arkdeck \(targetArgv) \(leaf.token)"
      // Being renamed does not turn a frozen 1.x compatibility surface into a
      // target one, so a `legacy` leaf stays `legacy` under both spellings.
      // Everything else is merely superseded.
      alias.lifecycle = leaf.lifecycle == .legacy ? .legacy : .deprecated
      return alias
    }
  }

  private static func normalized(_ leaf: CLILeafSpec) -> CLILeafSpec {
    var normalized = leaf
    if legacyCompatibilityCommands.contains(leaf.canonicalCommand) {
      normalized.lifecycle = .legacy
    }
    if let replacement = replacementArgvPatterns[leaf.canonicalCommand] {
      normalized.replacementArgvPattern = replacement
      // A leaf that is merely superseded, without its own shape being frozen,
      // is deprecated rather than legacy: `cleanup-debt` is a plain alias for
      // the same call.
      if normalized.lifecycle == .current { normalized.lifecycle = .deprecated }
    }
    guard leaf.options.contains(where: { $0.name == outputOption.name }) else { return normalized }
    // Declaring `--output` implies `json` for every leaf that did not say
    // otherwise, which is all but one. `job watch` says otherwise: §8.1 scopes
    // its machine mode to `jsonl`, and forcing `json` on would publish a
    // single-document shape for a command whose whole contract is a stream.
    if normalized.outputModes == [.human] { normalized.outputModes.append(.json) }
    if leaf.options.contains(where: { $0.name == jsonOption.name }),
      !normalized.mutuallyExclusive.contains(outputAndJSONAreExclusive)
    {
      normalized.mutuallyExclusive.append(outputAndJSONAreExclusive)
    }
    return normalized
  }

  private static let declaredNodes: [CLINodeSpec] = [
    doctorNode, runtimeNode, operationNode, deviceNode, targetNode, targetlessTraceNode,
    jobNode, artifactNode, agentNode, humanActionNode, capabilityNode, recoveryNode, screenNode, inputNode,
    diagnosticsNode, analyzeNode, portForwardNode, workspaceNode, cleanupDebtNode, debugNode,
    flashNode, legacyNode, maintainerNode, uiDumpNode, agentdNode, signingNode, updateFeedNode,
  ]

  /// A first-class name for one published operation (§6.2).
  ///
  /// Every one takes the same arguments, because the operation's own typed
  /// inputs come from `operation describe` — §10 forbids a domain command from
  /// carrying a second copy of the input definition, which is precisely the
  /// copy that drifts when the descriptor changes.
  private static func domainLeaf(
    _ token: String, _ command: String, _ operation: String, _ summary: String
  ) -> CLILeafSpec {
    CLILeafSpec(
      token: token,
      canonicalCommand: command,
      summary: summary,
      options: runtimeClientOptions([
        CLIOptionSpec(
          name: "--target",
          form: .value(placeholder: "target-id", grammar: .opaque),
          summary: "durable target; omitted lets typed discovery choose"),
        CLIOptionSpec(
          name: "--inputs-file",
          form: .value(placeholder: "path", grammar: .opaque),
          summary: "typed inputs; `arkdeck operation describe` publishes the schema"),
        CLIOptionSpec(
          name: "--capability",
          form: .value(placeholder: "CAP-RT-...", grammar: .opaque),
          summary: "reference to an existing Runtime capability; never a document"),
        CLIOptionSpec(
          name: "--execution-id",
          form: .value(placeholder: "id", grammar: .opaque),
          summary: "caller-stable execution identity for safe re-entry"),
      ]),
      connectsToRuntime: true,
      catalogOperation: operation)
  }

  private static let screenNode = CLINodeSpec(
    token: "screen",
    summary: "screen capture and recording",
    leaves: [
      domainLeaf(
        "record", "screen.record", "capture.screen-sequence@1",
        "capture a bounded screen sequence")
    ])

  private static let inputNode = CLINodeSpec(
    token: "input",
    summary: "typed synthetic input",
    leaves: [
      domainLeaf("tap", "input.tap", "input.tap@1", "tap at typed coordinates"),
      domainLeaf(
        "long-press", "input.long-press", "input.long-press@1",
        "long-press at typed coordinates"),
      domainLeaf("swipe", "input.swipe", "input.swipe@1", "swipe between typed coordinates"),
    ])

  private static let diagnosticsNode = CLINodeSpec(
    token: "diagnostics",
    summary: "bounded diagnostic capture",
    leaves: [
      domainLeaf(
        "capture", "diagnostics.capture", "capture.diagnostics@1",
        "capture bounded HiLog, UI dump and trace with a structured artifact index")
    ])

  private static let analyzeNode = CLINodeSpec(
    token: "analyze",
    summary: "host-only analysis of captured artifacts",
    leaves: [
      domainLeaf("trace", "analyze.trace", "analyzer.analyze-trace@1", "analyze a trace"),
      domainLeaf(
        "trace-summary", "analyze.trace-summary", "analyzer.summarize-trace@1",
        "summarize a trace"),
      domainLeaf(
        "hilog-summary", "analyze.hilog-summary", "analyzer.summarize-hilog@1",
        "summarize a HiLog capture"),
      domainLeaf(
        "crash-signature", "analyze.crash-signature", "analyzer.extract-crash-signature@1",
        "extract a crash signature"),
    ])

  private static let portForwardNode = CLINodeSpec(
    token: "port-forward",
    summary: "typed port forwarding",
    leaves: [
      domainLeaf(
        "create", "port-forward.create", "port-forward.create@1", "create a typed forward"),
      domainLeaf(
        "remove", "port-forward.remove", "port-forward.remove@1", "remove a typed forward"),
    ])

  private static let workspaceNode = CLINodeSpec(
    token: "workspace",
    summary: "registered workspace inspection, build and test",
    leaves: [
      domainLeaf(
        "status", "workspace.status", "workspace.inspect-git-status@1", "inspect git status"),
      domainLeaf("diff", "workspace.diff", "workspace.inspect-diff@1", "inspect a diff"),
      domainLeaf(
        "inspect", "workspace.inspect", "workspace.inspect-source@1", "inspect source"),
      domainLeaf(
        "read", "workspace.read", "workspace.read-source-range@1", "read a typed source range"),
      domainLeaf(
        "isolate", "workspace.isolate", "workspace.prepare-isolated-copy@1",
        "prepare an isolated copy"),
      domainLeaf(
        "checkpoint", "workspace.checkpoint", "workspace.create-checkpoint@1",
        "create a checkpoint"),
      domainLeaf("patch", "workspace.patch", "workspace.apply-patch@1", "apply a patch"),
      domainLeaf("revert", "workspace.revert", "workspace.revert-patch@1", "revert a patch"),
      domainLeaf(
        "build", "workspace.build", "workspace.build-openharmony@1", "build for OpenHarmony"),
      domainLeaf("test", "workspace.test", "workspace.run-tests@1", "run tests"),
      domainLeaf("sign", "workspace.sign", "workspace.sign-openharmony-hap@1", "sign a HAP"),
      domainLeaf(
        "symbolize", "workspace.symbolize", "workspace.symbolize-crash@1", "symbolize a crash"),
      domainLeaf(
        "sweep", "workspace.sweep", "workspace.sweep-isolated-copies@1",
        "sweep isolated copies"),
    ],
    // §7.9's discovery half. Every leaf above needs a `--project` reference,
    // and until these existed there was no way to learn one: §7.9 is explicit
    // that the free-form strings and examples in Catalog descriptors are not
    // discoverability. These read the daemon's current registered
    // configuration and publish references, kinds and availability — never the
    // host root, the executable or its arguments.
    groups: [
      CLINodeSpec(
        token: "project",
        summary: "registered workspace projects, by reference",
        leaves: [
          CLILeafSpec(
            token: "list",
            canonicalCommand: "workspace.project.list",
            summary: "every project this Runtime has registered, with availability",
            options: runtimeClientOptions([]),
            connectsToRuntime: true),
          CLILeafSpec(
            token: "show",
            canonicalCommand: "workspace.project.show",
            summary: "one project: kind, availability, preset refs and supported operations",
            options: runtimeClientOptions([workspaceProjectRefOption]),
            connectsToRuntime: true),
        ]),
      CLINodeSpec(
        token: "preset",
        summary: "kind-tagged preset references inside one registered project",
        leaves: [
          CLILeafSpec(
            token: "list",
            canonicalCommand: "workspace.preset.list",
            summary: "preset references, optionally narrowed to one kind",
            options: runtimeClientOptions([
              workspaceProjectRefOption,
              CLIOptionSpec(
                name: "--kind",
                form: .value(
                  placeholder: "build|test|signing|symbol",
                  grammar: .enumeration(["build", "test", "signing", "symbol"])),
                summary: "narrow to one preset kind"),
            ]),
            connectsToRuntime: true),
          CLILeafSpec(
            token: "show",
            canonicalCommand: "workspace.preset.show",
            summary: "one preset reference and its typed constraints",
            options: runtimeClientOptions([
              workspaceProjectRefOption,
              CLIOptionSpec(
                name: "--preset",
                form: .value(placeholder: "preset-ref", grammar: .opaque),
                summary: "preset reference from `workspace preset list`",
                isRequired: true),
            ]),
            connectsToRuntime: true),
        ]),
    ])

  private static let workspaceProjectRefOption = CLIOptionSpec(
    name: "--project",
    form: .value(placeholder: "project-ref", grammar: .opaque),
    summary: "registered project reference from `workspace project list`",
    isRequired: true)

  /// §6.1's recovery surface.
  ///
  /// Two things live here that were previously spelled as something else.
  /// `cleanup-debt` was a top-level noun for what is really one kind of
  /// recovery, and `debug` was the protected destructive Flash recovery
  /// invocation — a name that collides head-on with the ordinary Debug product
  /// §6.2 describes (§13.2 records the collision). Both keep working as
  /// aliases for this major; this is where they are supposed to be read from.
  private static let recoveryNode = CLINodeSpec(
    token: "recovery",
    summary: "typed cleanup residue and protected Flash recovery invocations",
    groups: [
      CLINodeSpec(
        token: "cleanup",
        summary: "cleanup residue the Runtime recorded",
        leaves: [
          CLILeafSpec(
            token: "list",
            canonicalCommand: "recovery.cleanup.list",
            summary: "list typed cleanup residue",
            options: runtimeClientOptions([]),
            connectsToRuntime: true),
          CLILeafSpec(
            token: "continue",
            canonicalCommand: "recovery.cleanup.continue",
            summary: "continue a recorded cleanup inside its owner boundary",
            options: runtimeClientOptions([
              jobIDOption,
              CLIOptionSpec(
                name: "--remote-path",
                form: .value(placeholder: "recorded-path", grammar: .opaque),
                summary: "residue path exactly as the Runtime recorded it"),
              CLIOptionSpec(
                name: "--bundle",
                form: .value(placeholder: "recorded-bundle", grammar: .opaque),
                summary: "residue bundle exactly as the Runtime recorded it"),
            ]),
            requiresExactlyOneOf: [["--remote-path", "--bundle"]],
            connectsToRuntime: true),
        ]),
      CLINodeSpec(
        token: "flash-invocation",
        summary: "protected destructive Flash recovery decision documents",
        leaves: [
          CLILeafSpec(
            token: "start",
            canonicalCommand: "recovery.flash-invocation.start",
            summary: "create the closed recovery decision document",
            options: runtimeClientOptions([
              CLIOptionSpec(
                name: "--request-file",
                form: .value(placeholder: "path", grammar: .opaque),
                summary: "destructive flash request document",
                isRequired: true)
            ]),
            connectsToRuntime: true),
          CLILeafSpec(
            token: "evaluate",
            canonicalCommand: "recovery.flash-invocation.evaluate",
            summary: "evaluate an effect action inside one invocation owner",
            options: runtimeClientOptions([
              invocationIDOption,
              CLIOptionSpec(
                name: "--action-file",
                form: .value(placeholder: "path", grammar: .opaque),
                summary: "typed effect action document",
                isRequired: true),
              CLIOptionSpec(
                name: "--source-sha256",
                form: .value(placeholder: "sha256", grammar: .hexDigest(length: 64)),
                summary: "source digest pinned by the invocation",
                isRequired: true),
              CLIOptionSpec(
                name: "--build-sha256",
                form: .value(placeholder: "sha256", grammar: .hexDigest(length: 64)),
                summary: "build digest pinned by the invocation",
                isRequired: true),
            ]),
            connectsToRuntime: true),
          CLILeafSpec(
            token: "status",
            canonicalCommand: "recovery.flash-invocation.status",
            summary: "read one invocation owner",
            options: runtimeClientOptions([invocationIDOption]),
            connectsToRuntime: true),
        ]),
    ])

  private static let invocationIDOption = CLIOptionSpec(
    name: "--invocation",
    form: .value(placeholder: "invocation-id", grammar: .opaque),
    summary: "exact invocation identity",
    isRequired: true)

  /// §6.3's platform surface. Only the two read-only observations exist today;
  /// `service`, `tool`, `bundle`, `signing`, `storage`, `support-bundle` and
  /// `update` join this node as they are resourced, which is why it is a group
  /// rather than a pair of hyphenated leaves.
  private static let runtimeNode = CLINodeSpec(
    token: "runtime",
    summary: "the local Runtime service, its tools and its health",
    leaves: [
      CLILeafSpec(
        token: "health",
        canonicalCommand: "runtime.health",
        summary: "control protocol, catalog digest and provider health",
        options: runtimeClientOptions([
          CLIOptionSpec(
            name: "--require-protocol",
            form: .value(placeholder: "1|2", grammar: .enumeration(["1", "2"])),
            summary: "negotiate this exact protocol major before reading health; never downgrade")
        ]),
        connectsToRuntime: true)
    ],
    groups: [
      CLINodeSpec(
        token: "hdc",
        summary: "the HDC server the Runtime manages",
        leaves: [
          CLILeafSpec(
            token: "status",
            canonicalCommand: "runtime.hdc.status",
            summary: "exact tool and server facts for the managed HDC runtime",
            options: runtimeClientOptions([
              CLIOptionSpec(name: "--require-protocol", form: .value(placeholder: "1|2", grammar: .enumeration(["1", "2"])),
                summary: "default 2 reads fresh facts; explicit 1 reads the frozen startup projection")
            ]),
            connectsToRuntime: true)
        ]),
      runtimeServiceNode,
      runtimeSigningNode,
    ])

  /// §6.1's durable target surface. `device list/show/adopt` stay as the
  /// frozen 1.x legacy spellings beside it (§12).
  private static let targetNode = CLINodeSpec(
    token: "target",
    summary: "durable device targets and their bindings",
    leaves: [
      CLILeafSpec(
        token: "adopt",
        canonicalCommand: "target.adopt",
        summary: "reobserve one exact candidate snapshot and establish its durable target",
        options: runtimeClientOptions(observationReferenceOptions),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "list",
        canonicalCommand: "target.list",
        summary: "list durable targets and their binding revisions",
        options: runtimeClientOptions([]),
        connectsToRuntime: true),
      domainLeaf(
        "observe", "target.observe", "observe.device@1",
        "read and verify tool, device and binding facts"),
      CLILeafSpec(
        token: "show",
        canonicalCommand: "target.show",
        summary: "one target: binding, physical identity, last confirmed facts and live state",
        options: runtimeClientOptions([
          CLIOptionSpec(
            name: "--target",
            form: .value(placeholder: "target-id", grammar: .opaque),
            summary: "durable target identity",
            isRequired: true)
        ]),
        connectsToRuntime: true),
      // §7.2 forbids the shape this command looks like it should have: the CLI
      // must not issue several reads and decide from them that a device is
      // usable. So this is one Runtime call, and the aggregate is assembled
      // where the facts are — the leaf only names it.
      CLILeafSpec(
        token: "availability",
        canonicalCommand: "target.availability",
        summary: "one Runtime-owned aggregate of binding, presence, tool and operation facts",
        options: runtimeClientOptions([
          CLIOptionSpec(
            name: "--target",
            form: .value(placeholder: "target-id", grammar: .opaque),
            summary: "durable target identity",
            isRequired: true)
        ]),
        connectsToRuntime: true),
    ])

  // `doctor` is a leaf, but the tree is uniform: a one-leaf node whose token
  // equals the leaf token renders as `arkdeck doctor`.
  private static let doctorNode = CLINodeSpec(
    token: "doctor",
    summary: "read-only Runtime, Catalog, provider and storage health summary",
    leaves: [
      CLILeafSpec(
        token: "",
        canonicalCommand: "doctor",
        summary: "read-only Runtime, Catalog, provider and storage health summary",
        options: runtimeClientOptions([]),
        connectsToRuntime: true)
    ])

  private static let operationNode = CLINodeSpec(
    token: "operation",
    summary: "published Catalog operations",
    leaves: [
      CLILeafSpec(
        token: "list",
        canonicalCommand: "operation.list",
        summary: "list published operation references and availability",
        options: runtimeClientOptions([]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "example",
        canonicalCommand: "operation.example",
        summary: "print a submittable request for this operation; dispatches nothing",
        options: runtimeClientOptions([
          CLIOptionSpec(
            name: "--operation",
            form: .value(placeholder: "id@version", grammar: .opaque),
            summary: "exact published operation reference",
            isRequired: true)
        ]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "validate",
        canonicalCommand: "operation.validate",
        summary: "check typed inputs against the descriptor; touches no device",
        options: runtimeClientOptions([
          CLIOptionSpec(
            name: "--operation",
            form: .value(placeholder: "id@version", grammar: .opaque),
            summary: "exact published operation reference",
            isRequired: true),
          CLIOptionSpec(
            name: "--inputs-file",
            form: .value(placeholder: "path|-", grammar: .opaque),
            summary: "typed inputs to check; `-` reads one JSON document from stdin",
            isRequired: true),
        ]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "describe",
        canonicalCommand: "operation.describe",
        summary: "print one operation descriptor, its typed inputs and an example request",
        options: runtimeClientOptions([
          CLIOptionSpec(
            name: "--operation",
            form: .value(placeholder: "id@version", grammar: .opaque),
            summary: "exact published operation reference",
            isRequired: true)
        ]),
        connectsToRuntime: true),
    ])

  private static let deviceNode = CLINodeSpec(
    token: "device",
    summary: "live devices and durable targets",
    leaves: [
      CLILeafSpec(
        token: "wait",
        canonicalCommand: "device.wait",
        summary: "wait on one proved device observation; never adopt or follow a replacement",
        options: runtimeClientOptions(observationReferenceOptions + [
          CLIOptionSpec(
            name: "--state",
            form: .value(
              placeholder: "connected|unauthorized|offline",
              grammar: .enumeration(["connected", "unauthorized", "offline"])),
            summary: "exact authorization state to wait for", isRequired: true),
          CLIOptionSpec(
            name: "--timeout",
            form: .value(placeholder: "30s", grammar: .duration(maximumMilliseconds: 86_400_000)),
            summary: "total client wait including negotiation and IO; default 30s, maximum 24h"),
        ]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "list",
        canonicalCommand: "device.list",
        summary: "list durable targets and their binding revisions",
        options: runtimeClientOptions([]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "show",
        canonicalCommand: "device.show",
        summary: "list durable targets and their binding revisions",
        options: runtimeClientOptions([]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "candidates",
        canonicalCommand: "device.candidates",
        summary: "live HDC candidates, their authorization state and any adopted target",
        options: runtimeClientOptions([
          CLIOptionSpec(
            name: "--require-protocol",
            form: .value(placeholder: "2", grammar: .enumeration(["2"])),
            summary: "read v2 physical observation references for target adopt; never downgrade"),
          CLIOptionSpec(
            name: "--snapshot",
            form: .flag,
            summary:
              "return a snapshot object with generation and observation IDs instead of an array"),
          CLIOptionSpec(
            name: "--use-warm-snapshot",
            form: .flag,
            summary: "read the Runtime's warm snapshot instead of forcing a fresh device read"),
        ]),
        mutuallyExclusive: [["--require-protocol", "--snapshot"], ["--require-protocol", "--use-warm-snapshot"]],
        connectsToRuntime: true),
      CLILeafSpec(
        token: "adopt",
        canonicalCommand: "device.adopt",
        summary: "establish or update a durable binding from an observed candidate",
        options: runtimeClientOptions([
          CLIOptionSpec(
            name: "--candidate",
            form: .value(placeholder: "connect-key", grammar: .opaque),
            summary: "exact observed candidate key")
        ]),
        connectsToRuntime: true),
    ])

  private static let observationReferenceOptions: [CLIOptionSpec] = [
    CLIOptionSpec(
      name: "--candidate", form: .value(placeholder: "key", grammar: .opaque),
      summary: "exact candidate key from the Runtime observation", isRequired: true),
    CLIOptionSpec(
      name: "--observation", form: .value(placeholder: "observation-id", grammar: .opaque),
      summary: "Runtime-issued physical observation identity", isRequired: true),
    CLIOptionSpec(
      name: "--observation-generation",
      form: .value(placeholder: "generation", grammar: .positiveInteger(1...Int.max)),
      summary: "exact snapshot generation from discovery", isRequired: true),
  ]

  private static let targetlessTraceNode = CLINodeSpec(
    token: "trace",
    summary: "trace capability observation",
    leaves: [
      CLILeafSpec(
        token: "probe",
        canonicalCommand: "trace.probe",
        summary: "read-only trace capability portrait for one durable target",
        options: runtimeClientOptions([
          CLIOptionSpec(
            name: "--target",
            form: .value(placeholder: "target-id", grammar: .opaque),
            summary: "durable target identity",
            isRequired: true)
        ]),
        connectsToRuntime: true)
    ])

  /// Shared by `job plan` and `job submit`: either a complete request document
  /// or the typed fields the CLI wraps into one. The two forms are exclusive
  /// (§5.3).
  private static let jobRequestOptions: [CLIOptionSpec] = [
    CLIOptionSpec(
      name: "--request-file",
      form: .value(placeholder: "path", grammar: .opaque),
      summary: "complete typed request document, passed through verbatim"),
    CLIOptionSpec(
      name: "--target",
      form: .value(placeholder: "target-id", grammar: .opaque),
      summary: "durable target identity"),
    CLIOptionSpec(
      name: "--operation",
      form: .value(placeholder: "id@version", grammar: .opaque),
      summary: "exact published operation reference"),
    CLIOptionSpec(
      name: "--inputs-file",
      form: .value(placeholder: "path", grammar: .opaque),
      summary: "typed operation inputs the CLI wraps in a request envelope"),
    CLIOptionSpec(
      name: "--expected-binding-revision",
      form: .value(placeholder: "n", grammar: .positiveInteger(1...Int.max)),
      summary: "binding revision the caller expects; a drift fails closed"),
    // §5.3: the flag form has to let a caller fix these. Without them the CLI
    // generated a fresh random pair per invocation, so a retried submit created
    // a second job instead of returning the first — which is the one thing an
    // unattended caller cannot afford to get wrong.
    CLIOptionSpec(
      name: "--request-id",
      form: .value(placeholder: "id", grammar: .opaque),
      summary: "caller-stable request identity; omitted, one is generated per invocation"),
    CLIOptionSpec(
      name: "--idempotency-key",
      form: .value(placeholder: "key", grammar: .opaque),
      summary: "caller-stable idempotency key; the same key returns the same job"),
  ]

  /// `--request-file` carries the whole document, so every flag-form field is
  /// exclusive with it (§5.3).
  private static let requestFileExclusions: [[String]] = [
    ["--request-file", "--target"], ["--request-file", "--operation"],
    ["--request-file", "--inputs-file"], ["--request-file", "--expected-binding-revision"],
    ["--request-file", "--request-id"], ["--request-file", "--idempotency-key"],
  ]

  private static let jobNode = CLINodeSpec(
    token: "job",
    summary: "typed Runtime jobs",
    leaves: [
      CLILeafSpec(
        token: "plan",
        canonicalCommand: "job.plan",
        summary: "materialize the exact plan without dispatching it",
        options: runtimeClientOptions(jobRequestOptions),
        mutuallyExclusive: requestFileExclusions,
        connectsToRuntime: true),
      CLILeafSpec(
        token: "submit",
        canonicalCommand: "job.submit",
        summary: "create a job idempotently; does not implicitly run it",
        options: runtimeClientOptions(
          jobRequestOptions + [
            CLIOptionSpec(
              name: "--wait",
              form: .flag,
              summary: "poll the submitted job until it settles")
          ]),
        mutuallyExclusive: requestFileExclusions,
        connectsToRuntime: true),
      CLILeafSpec(
        token: "status",
        canonicalCommand: "job.status",
        summary: "compact job state, progress and unknown-outcome flag",
        options: runtimeClientOptions([jobIDOption, targetProtocolOption, waitTimeoutOption]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "show",
        canonicalCommand: "job.show",
        summary: "read the complete typed Job snapshot without running it",
        options: runtimeClientOptions([jobIDOption, targetProtocolOption, waitTimeoutOption]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "timeline",
        canonicalCommand: "job.timeline",
        summary: "read a bounded fixed snapshot of Job timeline entries",
        options: runtimeClientOptions([jobIDOption, targetProtocolOption, waitTimeoutOption,
          eventPageSizeOption, CLIOptionSpec(name: "--cursor", form: .value(placeholder: "token", grammar: .opaque),
            summary: "opaque continuation cursor from this timeline query")]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "wait",
        canonicalCommand: "job.wait",
        summary: "wait for terminal, human action or unknown outcome; never cancels",
        options: runtimeClientOptions([jobIDOption, waitTimeoutOption, targetProtocolOption, eventCursorOption, eventPageSizeOption]),
        connectsToRuntime: true,
        outputModes: [.human, .json, .jsonl]),
      CLILeafSpec(
        token: "events",
        canonicalCommand: "job.events",
        summary: "read one page of retained durable Job events",
        options: runtimeClientOptions([jobIDOption, targetProtocolOption, eventCursorOption, eventPageSizeOption, waitTimeoutOption]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "watch",
        canonicalCommand: "job.watch",
        summary: "follow durable Job events until timeout or interruption; never runs or cancels",
        options: runtimeClientOptions([jobIDOption, targetProtocolOption, eventCursorOption, eventPageSizeOption, waitTimeoutOption]),
        connectsToRuntime: true,
        outputModes: [.human, .jsonl]),
      CLILeafSpec(
        token: "list",
        canonicalCommand: "job.list",
        summary: "list jobs, newest first",
        options: runtimeClientOptions([
          CLIOptionSpec(
            name: "--page-size",
            form: .value(placeholder: "1...1000", grammar: .positiveInteger(1...1000)),
            summary: "page size"),
          CLIOptionSpec(
            name: "--cursor",
            form: .value(placeholder: "token", grammar: .opaque),
            summary: "opaque continuation cursor from a previous page"),
          CLIOptionSpec(
            name: "--order",
            form: .value(
              placeholder: "createdAtDescJobIdAsc|createdAtAscJobIdAsc",
              grammar: .enumeration(["oldestFirst", "newestFirst", "createdAtDescJobIdAsc", "createdAtAscJobIdAsc"])),
            summary: "v2 defaults to createdAtDescJobIdAsc; legacy order tokens require v1"),
          CLIOptionSpec(
            name: "--include-current",
            form: .flag,
            summary: "include Runtime current-state overlays; all durable Jobs remain discoverable"),
          CLIOptionSpec(
            name: "--include-timeline",
            form: .flag,
            summary: "include each job's timeline entries"),
          targetProtocolOption, waitTimeoutOption,
          CLIOptionSpec(name: "--state", form: .value(placeholder: "state", grammar: .opaque),
            summary: "filter by exact Job state"),
          CLIOptionSpec(name: "--operation", form: .value(placeholder: "id@version", grammar: .opaque),
            summary: "filter by exact operation reference"),
          CLIOptionSpec(name: "--target", form: .value(placeholder: "target-id", grammar: .opaque),
            summary: "filter by exact target identity"),
          CLIOptionSpec(name: "--thread", form: .value(placeholder: "thread-id", grammar: .opaque),
            summary: "filter by exact conversation identity"),
        ]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "run",
        canonicalCommand: "job.run",
        summary: "run a fresh job, or resume one from a Runtime-proven safe boundary",
        options: runtimeClientOptions([jobIDOption]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "cancel",
        canonicalCommand: "job.cancel",
        summary: "ask the Runtime to cancel at an allowed boundary",
        options: runtimeClientOptions([jobIDOption]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "evidence",
        canonicalCommand: "job.evidence",
        summary: "verify and return trusted result evidence; creates no new facts",
        options: runtimeClientOptions([jobIDOption, targetProtocolOption, waitTimeoutOption]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "result",
        canonicalCommand: "job.result",
        summary: "terminal status, verified evidence, artifact inventory and cleanup residue",
        options: runtimeClientOptions([jobIDOption, targetProtocolOption, waitTimeoutOption]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "reconcile",
        canonicalCommand: "job.reconcile",
        summary: "settle an unknown outcome by readback; never replays the effect",
        options: runtimeClientOptions([jobIDOption]),
        connectsToRuntime: true),
    ])

  /// §5.2: how long this CLI process waits, and nothing else.
  ///
  /// It cannot extend an operation, plan or capability budget — those live in
  /// the Runtime and outlast this process. The ceiling is a day because a wait
  /// longer than that is a caller who meant to detach, and the honest answer
  /// to that is `job status` on a schedule rather than a process held open
  /// across a laptop suspending.
  private static let eventCursorOption = CLIOptionSpec(
    name: "--after-cursor", form: .value(placeholder: "cursor", grammar: .opaque),
    summary: "resume after this opaque cursor; omission reads from the retained origin")
  private static let eventPageSizeOption = CLIOptionSpec(
    name: "--page-size", form: .value(placeholder: "1...1000", grammar: .positiveInteger(1...1000)),
    summary: "maximum event count per unary page")

  private static let waitTimeoutOption = CLIOptionSpec(
    name: "--timeout",
    form: .value(placeholder: "30s", grammar: .duration(maximumMilliseconds: 86_400_000)),
    summary: "how long to wait before giving up; the job keeps running")

  private static let jobIDOption = CLIOptionSpec(
    name: "--job",
    form: .value(placeholder: "job-id", grammar: .opaque),
    summary: "durable job identity",
    isRequired: true)

  private static let artifactImportOptions: [CLIOptionSpec] = [
    CLIOptionSpec(
      name: "--target",
      form: .value(placeholder: "target-id", grammar: .opaque),
      summary: "durable target the import is scoped to",
      isRequired: true),
    CLIOptionSpec(
      name: "--file",
      form: .value(placeholder: "path", grammar: .opaque),
      summary: "host file to import; validated by identity and digest",
      isRequired: true),
  ]

  private static let allowSensitiveOption = CLIOptionSpec(
    name: "--allow-sensitive",
    form: .flag,
    summary: "explicit opt-in required before sensitive content is read or exported")

  private static let artifactIDOption = CLIOptionSpec(
    name: "--artifact",
    form: .value(placeholder: "artifact-id", grammar: .opaque),
    summary: "exact artifact identity")

  private static let artifactNode = CLINodeSpec(
    token: "artifact",
    summary: "immutable Runtime-managed content",
    leaves: [
      CLILeafSpec(
        token: "import-hap",
        canonicalCommand: "artifact.import-hap",
        summary: "import a .hap/.hsp package as a typed input artifact",
        options: runtimeClientOptions(artifactImportOptions),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "import-workspace-patch",
        canonicalCommand: "artifact.import-workspace-patch",
        summary: "import a workspace patch as a typed input artifact",
        options: runtimeClientOptions(artifactImportOptions),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "import-flash-bundle",
        canonicalCommand: "artifact.import-flash-bundle",
        summary: "import a firmware image archive as a typed input artifact",
        options: runtimeClientOptions(
          artifactImportOptions + [
            CLIOptionSpec(
              name: "--device-profile",
              form: .value(placeholder: "dayu200", grammar: .opaque),
              summary: "published device profile reference")
          ]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "import-native-library",
        canonicalCommand: "artifact.import-native-library",
        summary: "import a native library as a typed input artifact",
        options: runtimeClientOptions(artifactImportOptions),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "quota",
        canonicalCommand: "artifact.quota",
        summary: "store total, used and remaining bytes; the store refuses rather than evicts",
        options: runtimeClientOptions([]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "list",
        canonicalCommand: "artifact.list",
        summary: "list the artifacts a job owns",
        options: runtimeClientOptions([jobIDOption, artifactIDOption, allowSensitiveOption]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "inspect",
        canonicalCommand: "artifact.inspect",
        summary: "owner, media type, privacy, byte count, digest and publish state",
        options: runtimeClientOptions([
          jobIDOption, requiredArtifactIDOption, allowSensitiveOption,
        ]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "read",
        canonicalCommand: "artifact.read",
        summary: "bounded range read of artifact content",
        options: runtimeClientOptions([
          jobIDOption, requiredArtifactIDOption, allowSensitiveOption,
          CLIOptionSpec(
            name: "--offset",
            form: .value(
              placeholder: "byte-offset", grammar: .nonNegativeInteger(0...Int.max)),
            summary: "first byte to read; 0 is the start of the artifact"),
          CLIOptionSpec(
            name: "--max-bytes",
            form: .value(
              placeholder: "1...4194304",
              grammar: .positiveInteger(1...artifactReadMaximumBytes)),
            summary: "upper bound on the bytes returned by this read"),
          CLIOptionSpec(
            name: "--raw",
            form: .flag,
            summary: "write the decoded bytes to stdout and nothing else"),
        ]),
        mutuallyExclusive: [["--raw", "--output"], ["--raw", "--json"]],
        connectsToRuntime: true),
      CLILeafSpec(
        token: "export",
        canonicalCommand: "artifact.export",
        summary: "export artifact content to an explicit host directory",
        options: runtimeClientOptions([
          jobIDOption, requiredArtifactIDOption, allowSensitiveOption,
          CLIOptionSpec(
            name: "--destination",
            form: .value(placeholder: "directory", grammar: .opaque),
            summary: "existing host directory to write into",
            isRequired: true),
        ]),
        connectsToRuntime: true),
    ], groups: [durableImportNode])

  private static let importRequestOption = CLIOptionSpec(
    name: "--import-request-id", form: .value(placeholder: "id", grammar: .controlRequestID),
    summary: "caller-stable identity retained across retries")

  private static let durableImportNode = CLINodeSpec(
    token: "import", summary: "durable, resumable typed input uploads; no device dispatch",
    leaves: ["hap", "workspace-patch", "flash-bundle", "native-library"].map { kind in
      CLILeafSpec(token: kind, canonicalCommand: "artifact.import.\(kind)",
        summary: "upload and commit a registered \(kind) input; retry the same identity to resume",
        options: runtimeClientOptions([
          CLIOptionSpec(name: "--import-request-id", form: .value(placeholder: "id", grammar: .controlRequestID),
            summary: "stable Import identity; never reused for different metadata", isRequired: true),
          targetIDOption,
          CLIOptionSpec(name: "--file", form: .value(placeholder: "path", grammar: .opaque),
            summary: "stable local regular file", isRequired: true),
          waitTimeoutOption, targetProtocolOption,
        ] + (kind == "flash-bundle" ? [CLIOptionSpec(name: "--device-profile",
          form: .value(placeholder: "dayu200", grammar: .enumeration(["dayu200"])),
          summary: "registered archive validator; defaults to dayu200")] : [])),
        connectsToRuntime: true)
    } + [
      CLILeafSpec(token: "list", canonicalCommand: "artifact.import.list", summary: "fixed snapshot of durable Imports",
        options: runtimeClientOptions(snapshotPageOptions + [waitTimeoutOption, targetProtocolOption,
          CLIOptionSpec(name: "--target", form: .value(placeholder: "id", grammar: .opaque), summary: "filter target identity"),
          CLIOptionSpec(name: "--state", form: .value(placeholder: "state", grammar: .enumeration(["inProgress", "committing", "committed", "aborted", "released"])), summary: "filter Import state")]),
        connectsToRuntime: true),
      CLILeafSpec(token: "inspect", canonicalCommand: "artifact.import.inspect", summary: "recover an Import and its durable receipt",
        options: runtimeClientOptions([importRequestOption,
          CLIOptionSpec(name: "--import", form: .value(placeholder: "id", grammar: .opaque), summary: "Runtime-assigned Import identity"),
          waitTimeoutOption, targetProtocolOption]), requiresExactlyOneOf: [["--import", "--import-request-id"]],
        connectsToRuntime: true),
      CLILeafSpec(token: "release", canonicalCommand: "artifact.import.release", summary: "release an unused Import lease under its original generation",
        options: runtimeClientOptions([
          CLIOptionSpec(name: "--import", form: .value(placeholder: "id", grammar: .opaque),
            summary: "exact committed Import owner", isRequired: true),
          CLIOptionSpec(name: "--generation", form: .value(placeholder: "generation", grammar: .positiveInteger(1...9_007_199_254_740_991)),
            summary: "original committed generation to release", isRequired: true), waitTimeoutOption, targetProtocolOption]),
        connectsToRuntime: true),
      CLILeafSpec(token: "abort", canonicalCommand: "artifact.import.abort", summary: "discard staging and retain an irreversible request tombstone",
        options: runtimeClientOptions([
          CLIOptionSpec(name: "--import-request-id", form: .value(placeholder: "id", grammar: .controlRequestID),
            summary: "exact request identity to abort", isRequired: true), generationOption, waitTimeoutOption, targetProtocolOption]),
        connectsToRuntime: true),
    ])

  private static let targetIDOption = CLIOptionSpec(
    name: "--target",
    form: .value(placeholder: "target-id", grammar: .opaque),
    summary: "durable target identity",
    isRequired: true)

  private static let deviceProfileOption = CLIOptionSpec(
    name: "--device-profile",
    form: .value(placeholder: "dayu200", grammar: .opaque),
    summary: "published device profile reference",
    isRequired: true)

  private static let requiredArtifactIDOption = CLIOptionSpec(
    name: "--artifact",
    form: .value(placeholder: "artifact-id", grammar: .opaque),
    summary: "exact artifact identity",
    isRequired: true)

  private static let executionIDOption = CLIOptionSpec(
    name: "--execution-id", form: .value(placeholder: "id", grammar: .opaque),
    summary: "caller-stable durable execution identity")

  private static let targetProtocolOption = CLIOptionSpec(
    name: "--require-protocol", form: .value(placeholder: "2", grammar: .enumeration(["2"])),
    summary: "use Runtime-owned v2 resources; never downgrade")

  private static let generationOption = CLIOptionSpec(
    name: "--expected-generation", form: .value(placeholder: "n", grammar: .positiveInteger(1...Int.max)),
    summary: "exact current generation; drift refuses the mutation", isRequired: true)

  private static let snapshotPageOptions: [CLIOptionSpec] = [
    CLIOptionSpec(name: "--page-size", form: .value(placeholder: "100", grammar: .positiveInteger(1...1000)),
      summary: "maximum items in a fixed snapshot page"),
    CLIOptionSpec(name: "--cursor", form: .value(placeholder: "opaque-cursor", grammar: .opaque),
      summary: "continue the same immutable query and page size"),
  ]

  private static let physicalSelectionOptions: [CLIOptionSpec] = [
    CLIOptionSpec(name: "--selection", form: .value(placeholder: "value", grammar: .opaque),
      summary: "opaque selection published by the exact action"),
    CLIOptionSpec(name: "--selection-file", form: .value(placeholder: "path|-", grammar: .opaque),
      summary: "typed JSON selection from a bounded UTF-8 document"),
  ]

  private static let agentNode = CLINodeSpec(
    token: "agent",
    summary: "high-level typed execution entry for an external agent",
    leaves: [
      CLILeafSpec(
        token: "run",
        canonicalCommand: "agent.run",
        summary: "discovery, binding, submit, run, evidence and artifact inventory",
        options: runtimeClientOptions(jobRequestOptions + [
          executionIDOption, targetProtocolOption, waitTimeoutOption,
          CLIOptionSpec(name: "--maximum-wait",
            form: .value(placeholder: "5m", grammar: .duration(maximumMilliseconds: 86_400_000)),
            summary: "durable orchestration deadline, including HAR and restart; default 5m"),
          CLIOptionSpec(
            name: "--capability",
            form: .value(placeholder: "CAP-RT-...", grammar: .opaque),
            summary: "reference to an existing Runtime capability; never a document"),
          CLIOptionSpec(name: "--reviewed-plan-digest", form: .value(placeholder: "sha256", grammar: .opaque),
            summary: "immutable reviewed-plan precondition; never authority"),
        ]),
        mutuallyExclusive: requestFileExclusions + [["--request-file", "--capability"], ["--request-file", "--reviewed-plan-digest"]],
        requiresExactlyOneOf: [["--request-file", "--operation"]],
        connectsToRuntime: true),
      CLILeafSpec(token: "status", canonicalCommand: "agent.status",
        summary: "read a Runtime execution, including its pre-Job human action",
        options: runtimeClientOptions([executionIDOption, waitTimeoutOption, targetProtocolOption]),
        requiresExactlyOneOf: [["--execution-id"]], connectsToRuntime: true),
      CLILeafSpec(token: "list", canonicalCommand: "agent.list", summary: "rediscover durable executions without disclosing inputs or selection",
        options: runtimeClientOptions(snapshotPageOptions + [waitTimeoutOption, targetProtocolOption,
          CLIOptionSpec(name: "--state", form: .value(placeholder: "state", grammar: .enumeration([
            "orchestrating", "waitingForHuman", "creatingJob", "jobOwned", "completed", "failed", "abandoned", "budgetExpired", "clockUntrusted"])),
            summary: "filter persisted execution state"),
          CLIOptionSpec(name: "--operation", form: .value(placeholder: "id@version", grammar: .opaque), summary: "filter exact operation reference"),
          CLIOptionSpec(name: "--target", form: .value(placeholder: "id", grammar: .opaque), summary: "filter resolved durable target"),
        ]), connectsToRuntime: true),
      CLILeafSpec(token: "abandon", canonicalCommand: "agent.abandon", summary: "abandon pre-Job orchestration; never cancel a Job",
        options: runtimeClientOptions([executionIDOption, generationOption, waitTimeoutOption, targetProtocolOption]),
        requiresExactlyOneOf: [["--execution-id"]], connectsToRuntime: true),
      CLILeafSpec(
        token: "resume",
        canonicalCommand: "agent.resume",
        summary: "resume an execution paused for typed physical assistance",
        options: runtimeClientOptions(physicalSelectionOptions + [targetProtocolOption, waitTimeoutOption,
          CLIOptionSpec(
            name: "--resume-token",
            form: .value(placeholder: "token", grammar: .opaque),
            summary: "legacy token; with protocol 2, an exact-value alias of resume-reference"),
          CLIOptionSpec(name: "--resume-reference", form: .value(placeholder: "ref", grammar: .opaque),
            summary: "exact Runtime-owned physical-assistance reference"),
        ]),
        mutuallyExclusive: [["--selection", "--selection-file"]],
        requiresExactlyOneOf: [["--resume-reference", "--resume-token"]],
        connectsToRuntime: true),
      CLILeafSpec(
        token: "chat",
        canonicalCommand: "agent.chat",
        summary: "retired: ArkDeck holds no model of its own",
        kind: .tombstone(.replacedBy("arkdeck agent run"))),
    ])

  private static let humanActionIDOption = CLIOptionSpec(
    name: "--human-action", form: .value(placeholder: "id", grammar: .opaque),
    summary: "exact Runtime-owned human action", isRequired: true)

  private static let humanActionNode = CLINodeSpec(
    token: "human-action", summary: "Runtime-owned typed physical assistance; never an impact approval",
    leaves: [
      CLILeafSpec(token: "list", canonicalCommand: "human-action.list", summary: "list persisted AgentExecution physical actions",
        options: runtimeClientOptions(snapshotPageOptions + [waitTimeoutOption, targetProtocolOption,
          CLIOptionSpec(name: "--owner-kind", form: .value(placeholder: "agentExecution", grammar: .enumeration(["agentExecution"])),
            summary: "published owner kind; must be paired with --owner"),
          CLIOptionSpec(name: "--owner", form: .value(placeholder: "id", grammar: .opaque), summary: "exact owner identity"),
        ]), connectsToRuntime: true),
      CLILeafSpec(token: "show", canonicalCommand: "human-action.show", summary: "read exact action, selection schema, expiry and resume reference",
        options: runtimeClientOptions([humanActionIDOption, waitTimeoutOption, targetProtocolOption]), connectsToRuntime: true),
      CLILeafSpec(token: "resume", canonicalCommand: "human-action.resume", summary: "probe the exact physical assistance and continue its original owner",
        options: runtimeClientOptions(physicalSelectionOptions + [humanActionIDOption, waitTimeoutOption, targetProtocolOption,
          CLIOptionSpec(name: "--resume-reference", form: .value(placeholder: "ref", grammar: .opaque),
            summary: "exact reference returned by this action", isRequired: true),
        ]), mutuallyExclusive: [["--selection", "--selection-file"]], connectsToRuntime: true),
    ])

  private static let capabilityNode = CLINodeSpec(
    token: "capability",
    summary: "read-only Runtime capability inspection",
    leaves: [
      CLILeafSpec(
        token: "list",
        canonicalCommand: "capability.list",
        summary: "read-only capability diagnostic projection",
        options: runtimeClientOptions([]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "inspect",
        canonicalCommand: "capability.inspect",
        summary: "read-only scope, lineage, expiry and consume state",
        options: runtimeClientOptions([
          CLIOptionSpec(
            name: "--capability",
            form: .value(placeholder: "capability-id", grammar: .opaque),
            summary: "exact capability identity",
            isRequired: true)
        ]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "draft",
        canonicalCommand: "capability.draft",
        summary: "not caller-facing: capability administration is Runtime-owned",
        kind: .refused(reason: "capability administration is Runtime-owned")),
      CLILeafSpec(
        token: "install",
        canonicalCommand: "capability.install",
        summary: "not caller-facing: capability administration is Runtime-owned",
        kind: .refused(reason: "capability administration is Runtime-owned")),
      CLILeafSpec(
        token: "revoke",
        canonicalCommand: "capability.revoke",
        summary: "not caller-facing: capability administration is Runtime-owned",
        kind: .refused(reason: "capability administration is Runtime-owned")),
    ])

  private static let cleanupDebtNode = CLINodeSpec(
    token: "cleanup-debt",
    summary: "typed cleanup residue recorded by the Runtime",
    leaves: [
      CLILeafSpec(
        token: "list",
        canonicalCommand: "cleanup-debt.list",
        summary: "list typed cleanup residue",
        options: runtimeClientOptions([]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "continue",
        canonicalCommand: "cleanup-debt.continue",
        summary: "continue a recorded cleanup inside its owner boundary",
        options: runtimeClientOptions([
          jobIDOption,
          CLIOptionSpec(
            name: "--remote-path",
            form: .value(placeholder: "recorded-path", grammar: .opaque),
            summary: "residue path exactly as the Runtime recorded it"),
          CLIOptionSpec(
            name: "--bundle",
            form: .value(placeholder: "recorded-bundle", grammar: .opaque),
            summary: "residue bundle exactly as the Runtime recorded it"),
        ]),
        requiresExactlyOneOf: [["--remote-path", "--bundle"]],
        connectsToRuntime: true),
    ])

  private static let debugNode = CLINodeSpec(
    token: "debug",
    summary: "typed application debugging, and the retired recovery aliases",
    leaves: [
      domainLeaf("hap", "debug.hap", "debug.hap@1", "install, launch and observe a HAP"),
      CLILeafSpec(
        token: "start",
        canonicalCommand: "debug.start",
        summary: "create the closed recovery decision document",
        options: runtimeClientOptions([
          CLIOptionSpec(
            name: "--request-file",
            form: .value(placeholder: "path", grammar: .opaque),
            summary: "destructive flash request document",
            isRequired: true)
        ]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "evaluate",
        canonicalCommand: "debug.evaluate",
        summary: "evaluate an effect action inside one invocation owner",
        options: runtimeClientOptions([
          CLIOptionSpec(
            name: "--invocation",
            form: .value(placeholder: "invocation-id", grammar: .opaque),
            summary: "exact invocation identity",
            isRequired: true),
          CLIOptionSpec(
            name: "--action-file",
            form: .value(placeholder: "path", grammar: .opaque),
            summary: "typed effect action document",
            isRequired: true),
          CLIOptionSpec(
            name: "--source-sha256",
            form: .value(placeholder: "sha256", grammar: .opaque),
            summary: "source digest pinned by the invocation",
            isRequired: true),
          CLIOptionSpec(
            name: "--build-sha256",
            form: .value(placeholder: "sha256", grammar: .opaque),
            summary: "build digest pinned by the invocation",
            isRequired: true),
        ]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "status",
        canonicalCommand: "debug.status",
        summary: "read one invocation owner",
        options: runtimeClientOptions([
          CLIOptionSpec(
            name: "--invocation",
            form: .value(placeholder: "invocation-id", grammar: .opaque),
            summary: "exact invocation identity",
            isRequired: true)
        ]),
        connectsToRuntime: true),
    ],
    groups: [
      CLINodeSpec(
        token: "native",
        summary: "app-owned native library deployment",
        leaves: [
          domainLeaf(
            "deploy", "debug.native.deploy", "deploy.native-library.app-owned@1",
            "deploy an app-owned native library")
        ])
    ])

  /// §6.3/§12's `legacy` namespace: the macOS historical-archive surface.
  ///
  /// These two are the whole of it, and they are here rather than under
  /// `flash` because §12 draws a line that a shared prefix blurs. `flash` is
  /// where a caller reaches a device; these only decode and settle records
  /// that already exist, create no campaign and dispatch nothing, and are
  /// explicitly not required of the portable core. Naming that separation is
  /// what stops "the flash commands" from being read as one surface with one
  /// conformance story.
  ///
  /// They stay `legacy` under the new spelling too: the rename moves where a
  /// caller types them, not what they are. §12 forbids counting either as
  /// target conformance, so promoting them to `current` on the way across
  /// would have quietly bought conformance with a rename.
  private static let legacyFlashNode = CLINodeSpec(
    token: "flash",
    summary: "historical campaign archive; decode and settle only, never dispatch",
    leaves: [
      CLILeafSpec(
        token: "status",
        canonicalCommand: "legacy.flash.status",
        summary: "decode one historical campaign record; cannot dispatch",
        options: [
          CLIOptionSpec(
            name: "--campaign-id",
            form: .value(placeholder: "ECAMP-id", grammar: .opaque),
            summary: "historical campaign identity",
            isRequired: true),
          outputOption,
        ]),
      CLILeafSpec(
        token: "reconcile",
        canonicalCommand: "legacy.flash.reconcile",
        summary: "decode interrupted flash session journals; zero device dispatch",
        options: [
          CLIOptionSpec(
            name: "--session",
            form: .value(placeholder: "session-id", grammar: .opaque),
            summary: "inspect one session instead of every unresolved one"),
          outputOption,
        ]),
    ])

  private static let legacyNode = CLINodeSpec(
    token: "legacy",
    summary: "explicit compatibility surfaces; frozen 1.x shape, never target conformance",
    groups: [legacyFlashNode])

  /// §6.3's `ui-dump` family, minus the two leaves that reach a device.
  ///
  /// `inspect` and `hit-test` are §6.2 deterministic local derivations: they
  /// read Artifact bytes the Runtime already published and compute, contacting
  /// nothing. `ui-dump capture` is a `capture.diagnostics@1` preset and
  /// `component-detail` builds an advanced-dump request against the same
  /// operation — both are device captures, so they belong with the typed
  /// presets rather than here, and filing them as offline derivations would
  /// misdescribe what they do.
  private static let uiDumpNode = CLINodeSpec(
    token: "ui-dump",
    summary: "derive a UI tree from a published capture; never reaches a device",
    leaves: [
      CLILeafSpec(
        token: "inspect",
        canonicalCommand: "ui-dump.inspect",
        summary: "parse a published capture into its node tree, with parser and source digests",
        options: runtimeClientOptions([jobIDOption]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "hit-test",
        canonicalCommand: "ui-dump.hit-test",
        summary: "resolve one screenshot coordinate to the node the device would hit",
        options: runtimeClientOptions([
          jobIDOption,
          CLIOptionSpec(
            name: "--x",
            form: .value(placeholder: "0...", grammar: .nonNegativeInteger(0...Int.max)),
            summary: "screenshot x coordinate in pixels",
            isRequired: true),
          CLIOptionSpec(
            name: "--y",
            form: .value(placeholder: "0...", grammar: .nonNegativeInteger(0...Int.max)),
            summary: "screenshot y coordinate in pixels",
            isRequired: true),
          CLIOptionSpec(
            name: "--root",
            form: .value(placeholder: "node-identity", grammar: .opaque),
            summary: "restrict the search to one subtree"),
        ]),
        connectsToRuntime: true),
    ])

  private static let flashNode = CLINodeSpec(
    token: "flash",
    summary: "durable device binding and historical campaign archive",
    leaves: [
      CLILeafSpec(
        token: "install-binding",
        canonicalCommand: "flash.install-binding",
        summary: "install or refresh the durable cross-mode device binding",
        options: [
          CLIOptionSpec(
            name: "--rebind",
            form: .flag,
            summary: "replace an existing binding instead of leaving it unchanged"),
          outputOption,
        ])
    ]
      + compatibilitySpelling(
        of: legacyFlashNode.leaves, as: "flash", replacedBy: "legacy flash")
      + [
      domainLeaf(
        "run", "flash.run", "flash.full-restore@1",
        "run the canonical full restore through the typed Agent surface"),
      CLILeafSpec(
        token: "device-access",
        canonicalCommand: "flash.device-access",
        summary: "host permission and driver access facts for Rockchip flashing",
        options: runtimeClientOptions([]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "bootloader-status",
        canonicalCommand: "flash.bootloader-status",
        summary: "observed bootloader disposition of the attached board",
        options: runtimeClientOptions([]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "prerequisites",
        canonicalCommand: "flash.prerequisites",
        summary: "everything that must hold before a restore can be admitted",
        options: runtimeClientOptions([targetIDOption, deviceProfileOption]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "lane-preview",
        canonicalCommand: "flash.lane-preview",
        summary: "read-only preview of the lane plan an archive would anchor",
        options: runtimeClientOptions([
          targetIDOption, deviceProfileOption,
          CLIOptionSpec(
            name: "--archive-sha256",
            form: .value(placeholder: "sha256", grammar: .hexDigest(length: 64)),
            summary: "digest of the imported firmware archive",
            isRequired: true),
        ]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "bind-loader",
        canonicalCommand: "flash.bind-loader",
        summary: "bind the currently attached Loader to this target, CAS on its revision",
        options: runtimeClientOptions([
          targetIDOption,
          CLIOptionSpec(
            name: "--expected-binding-revision",
            form: .value(placeholder: "n", grammar: .positiveInteger(1...Int.max)),
            summary: "revision the caller expects; a drift fails closed",
            isRequired: true),
        ]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "plan",
        canonicalCommand: "flash.plan",
        summary: "retired: the Runtime materializes flash plans",
        kind: .tombstone(.replacedBy("arkdeck job plan --operation flash.full-restore@1 ..."))),
      CLILeafSpec(
        token: "preview",
        canonicalCommand: "flash.preview",
        summary: "retired: the Runtime owns Flash admission",
        // Now that `flash lane-preview` exists, the tombstone names the exact
        // argv pattern instead of only saying what went away.
        kind: .tombstone(.replacedBy("arkdeck flash lane-preview --target <id> ..."))),
      CLILeafSpec(
        token: "execute",
        canonicalCommand: "flash.execute",
        summary: "retired: the legacy host executor no longer exists",
        kind: .tombstone(.replacedBy("arkdeck agent run --operation flash.full-restore@1 ..."))),
      CLILeafSpec(
        token: "continue",
        canonicalCommand: "flash.continue",
        summary: "retired: historical campaign continuation cannot dispatch",
        kind: .tombstone(
          .noReplacement(reason: "historical campaigns are decode-only"))),
      CLILeafSpec(
        token: "postflight",
        canonicalCommand: "flash.postflight",
        summary: "retired: use Runtime job evidence",
        // Now that `job evidence` exists, the tombstone can name the exact
        // argv pattern §12 asks for instead of describing it in prose.
        kind: .tombstone(.replacedBy("arkdeck job evidence --job <id>"))),
    ])

  private static let agentdInstallOptions: [CLIOptionSpec] = [
    CLIOptionSpec(
      name: "--hdc",
      form: .value(placeholder: "absolute-hdc-path", grammar: .opaque),
      summary: "host HDC executable the daemon is pinned to"),
    CLIOptionSpec(
      name: "--daemon",
      form: .value(placeholder: "absolute-agentd-path", grammar: .opaque),
      summary: "signed daemon bundle to install"),
    CLIOptionSpec(
      name: "--workspace-project",
      form: .value(placeholder: "absolute-path", grammar: .opaque),
      summary: "registered workspace project root"),
    CLIOptionSpec(
      name: "--deveco-sdk",
      form: .value(placeholder: "absolute-path", grammar: .opaque),
      summary: "OpenHarmony SDK root used for workspace builds"),
    CLIOptionSpec(
      name: "--arktrace-descriptor",
      form: .value(placeholder: "absolute-path|none", grammar: .opaque),
      summary: "trace analyzer descriptor, or `none` to clear it"),
    CLIOptionSpec(
      name: "--arkforge-bundle",
      form: .value(placeholder: "absolute-ArkForge.bundle|none", grammar: .opaque),
      summary: "signed ArkForge bundle, or `none` to clear it"),
    CLIOptionSpec(
      name: "--arkforge-campaign",
      form: .value(placeholder: "campaign-id", grammar: .opaque),
      summary: "campaign identity the bundle is bound to"),
    CLIOptionSpec(
      name: "--sensitive-evidence",
      form: .value(placeholder: "retired", grammar: .opaque),
      summary: "retired in-process decision plane configuration",
      stability: .refusedByName),
    CLIOptionSpec(
      name: "--harness-model-provider",
      form: .value(placeholder: "retired", grammar: .opaque),
      summary: "retired in-process decision plane configuration",
      stability: .refusedByName),
    CLIOptionSpec(
      name: "--harness-model-name",
      form: .value(placeholder: "retired", grammar: .opaque),
      summary: "retired in-process decision plane configuration",
      stability: .refusedByName),
    CLIOptionSpec(
      name: "--harness-cli",
      form: .value(placeholder: "retired", grammar: .opaque),
      summary: "retired in-process decision plane configuration",
      stability: .refusedByName),
    CLIOptionSpec(
      name: "--harness-cli-timeout-seconds",
      form: .value(placeholder: "retired", grammar: .opaque),
      summary: "retired in-process decision plane configuration",
      stability: .refusedByName),
    CLIOptionSpec(
      name: "--arkforged",
      form: .value(placeholder: "retired", grammar: .opaque),
      summary: "retired ArkForge lane configuration; answered with migration guidance",
      stability: .refusedByName),
    CLIOptionSpec(
      name: "--arkforged-sha256",
      form: .value(placeholder: "retired", grammar: .opaque),
      summary: "retired ArkForge lane configuration; answered with migration guidance",
      stability: .refusedByName),
    CLIOptionSpec(
      name: "--arkforge-profile",
      form: .value(placeholder: "retired", grammar: .opaque),
      summary: "retired ArkForge lane configuration; answered with migration guidance",
      stability: .refusedByName),
  ]

  private static let maximumWaitSecondsOption = CLIOptionSpec(
    name: "--maximum-wait-seconds",
    form: .value(placeholder: "1...300", grammar: .positiveInteger(1...300)),
    summary: "client-side wait budget in seconds")

  private static let runtimeServiceNode = CLINodeSpec(
    token: "service",
    summary: "the local Runtime service for the current user",
    leaves: [
      CLILeafSpec(
        token: "install",
        canonicalCommand: "runtime.service.install",
        summary: "install the daemon as a user-domain service",
        options: agentdInstallOptions + [outputOption, jsonOption]),
      CLILeafSpec(
        token: "update",
        canonicalCommand: "runtime.service.update",
        summary: "update the installed daemon and its pinned host tools",
        options: agentdInstallOptions + [outputOption, jsonOption]),
      CLILeafSpec(
        token: "restart",
        canonicalCommand: "runtime.service.restart",
        summary: "restart the installed daemon",
        options: [maximumWaitSecondsOption, outputOption, jsonOption]),
      CLILeafSpec(
        token: "status",
        canonicalCommand: "runtime.service.status",
        summary: "service and daemon health",
        options: [outputOption, jsonOption]),
      CLILeafSpec(
        token: "verify",
        canonicalCommand: "runtime.service.verify",
        summary: "end-to-end verification through the published typed surface",
        options: [
          CLIOptionSpec(
            name: "--target",
            form: .value(placeholder: "target-id", grammar: .opaque),
            summary: "durable target to verify against"),
          maximumWaitSecondsOption,
          CLIOptionSpec(
            name: "--execution-id",
            form: .value(placeholder: "id", grammar: .opaque),
            summary: "caller-stable execution identity"),
          CLIOptionSpec(
            name: "--job",
            form: .value(placeholder: "job-id", grammar: .opaque),
            summary: "read an existing profiled job instead of running one"),
          outputOption, jsonOption,
        ],
        mutuallyExclusive: [
          ["--job", "--target"], ["--job", "--maximum-wait-seconds"],
          ["--job", "--execution-id"],
        ]),
      CLILeafSpec(
        token: "uninstall",
        canonicalCommand: "runtime.service.uninstall",
        summary: "remove the installed daemon service",
        options: [outputOption, jsonOption]),
    ])

  /// §12: the superseded spelling of `runtime service`, derived so it cannot drift.
  private static let agentdNode = CLINodeSpec(
    token: "agentd",
    summary: "superseded spelling of `runtime service`",
    leaves: compatibilitySpelling(
      of: runtimeServiceNode.leaves, as: "agentd", replacedBy: "runtime service"))

  private static let runtimeSigningNode = CLINodeSpec(
    token: "signing",
    summary: "local OpenHarmony signing presets; secrets stay in the platform store",
    leaves: [
      CLILeafSpec(
        token: "install-sdk-release",
        canonicalCommand: "runtime.signing.install-sdk-release",
        summary: "install the SDK release signing preset",
        options: [
          CLIOptionSpec(
            name: "--sdk",
            form: .value(placeholder: "absolute-path", grammar: .opaque),
            summary: "OpenHarmony SDK root",
            isRequired: true),
          CLIOptionSpec(
            name: "--java",
            form: .value(placeholder: "absolute-path", grammar: .opaque),
            summary: "Java executable used by the signing tool",
            isRequired: true),
          CLIOptionSpec(
            name: "--bundle-name",
            form: .value(placeholder: "bundle-name", grammar: .opaque),
            summary: "application bundle name the preset signs for",
            isRequired: true),
          projectRefOption, outputOption, jsonOption,
        ]),
      CLILeafSpec(
        token: "install",
        canonicalCommand: "runtime.signing.install",
        summary: "install a signing preset from explicit credential references",
        options: [
          CLIOptionSpec(
            name: "--java",
            form: .value(placeholder: "absolute-path", grammar: .opaque),
            summary: "Java executable used by the signing tool",
            isRequired: true),
          CLIOptionSpec(
            name: "--jar",
            form: .value(placeholder: "absolute-path", grammar: .opaque),
            summary: "hapsigntool jar",
            isRequired: true),
          CLIOptionSpec(
            name: "--keystore",
            form: .value(placeholder: "absolute-path", grammar: .opaque),
            summary: "p12 or jks keystore",
            isRequired: true),
          CLIOptionSpec(
            name: "--certificate",
            form: .value(placeholder: "absolute-path", grammar: .opaque),
            summary: "pem or cer certificate",
            isRequired: true),
          CLIOptionSpec(
            name: "--profile",
            form: .value(placeholder: "absolute-path", grammar: .opaque),
            summary: "p7b provisioning profile",
            isRequired: true),
          CLIOptionSpec(
            name: "--key-alias",
            form: .value(placeholder: "alias", grammar: .opaque),
            summary: "key alias inside the keystore",
            isRequired: true),
          projectRefOption, outputOption, jsonOption,
        ]),
      CLILeafSpec(
        token: "normalize",
        canonicalCommand: "runtime.signing.normalize",
        summary: "normalize an installed preset in place",
        options: [outputOption, jsonOption]),
      CLILeafSpec(
        token: "migrate-deveco",
        canonicalCommand: "runtime.signing.migrate-deveco",
        summary: "migrate a DevEco build profile into a typed preset",
        options: [
          CLIOptionSpec(
            name: "--build-profile",
            form: .value(placeholder: "absolute-build-profile.json5", grammar: .opaque),
            summary: "DevEco build profile to read",
            isRequired: true),
          CLIOptionSpec(
            name: "--daemon",
            form: .value(placeholder: "absolute-agentd-path", grammar: .opaque),
            summary: "installed daemon bundle the preset is bound to",
            isRequired: true),
          CLIOptionSpec(
            name: "--key-alias",
            form: .value(placeholder: "alias", grammar: .opaque),
            summary: "key alias inside the keystore"),
          outputOption, jsonOption,
        ]),
      CLILeafSpec(
        token: "status",
        canonicalCommand: "runtime.signing.status",
        summary: "installed preset status",
        options: [outputOption, jsonOption]),
      CLILeafSpec(
        token: "remove",
        canonicalCommand: "runtime.signing.remove",
        summary: "remove the installed preset",
        options: [outputOption, jsonOption]),
    ])

  /// §12: the superseded spelling of `runtime signing`, derived so it cannot drift.
  private static let signingNode = CLINodeSpec(
    token: "signing",
    summary: "superseded spelling of `runtime signing`",
    leaves: compatibilitySpelling(
      of: runtimeSigningNode.leaves, as: "signing", replacedBy: "runtime signing"))

  private static let projectRefOption = CLIOptionSpec(
    name: "--project-ref",
    form: .value(placeholder: "project-ref", grammar: .opaque),
    summary: "registered workspace project the preset belongs to")

  /// §6.3's maintainer namespace: release tooling that ships in the same
  /// binary but is not part of the device-facing product surface. Keeping it
  /// under one token is what lets help, completion and coverage separate "a
  /// caller drives this" from "a maintainer publishes with this" without
  /// either list having to know the individual command names.
  private static let maintainerNode = CLINodeSpec(
    token: "maintainer",
    summary: "release maintenance tooling; never touches a private key",
    groups: [maintainerUpdateFeedNode])

  private static let maintainerUpdateFeedNode = CLINodeSpec(
    token: "update-feed",
    summary: "maintainer update-feed tooling; never touches a private key",
    leaves: [
      CLILeafSpec(
        token: "prepare",
        canonicalCommand: "maintainer.update-feed.prepare",
        summary: "emit the deterministic public payload and signature input",
        options: [
          CLIOptionSpec(
            name: "--sequence",
            form: .value(placeholder: "n", grammar: .positiveInteger(1...Int.max)),
            summary: "monotonic feed sequence",
            isRequired: true),
          CLIOptionSpec(
            name: "--version",
            form: .value(placeholder: "x.y.z", grammar: .opaque),
            summary: "released product version",
            isRequired: true),
          CLIOptionSpec(
            name: "--minimum-system",
            form: .value(placeholder: "x.y.z", grammar: .opaque),
            summary: "minimum supported host system version",
            isRequired: true),
          CLIOptionSpec(
            name: "--issued-at",
            form: .value(placeholder: "RFC3339", grammar: .opaque),
            summary: "issue timestamp",
            isRequired: true),
          CLIOptionSpec(
            name: "--expires-at",
            form: .value(placeholder: "RFC3339", grammar: .opaque),
            summary: "expiry timestamp",
            isRequired: true),
          CLIOptionSpec(
            name: "--artifact",
            form: .value(placeholder: "ArkDeck.dmg", grammar: .opaque),
            summary: "release artifact to describe",
            isRequired: true),
          CLIOptionSpec(
            name: "--artifact-url",
            form: .value(placeholder: "https-url", grammar: .opaque),
            summary: "https download location",
            isRequired: true),
          CLIOptionSpec(
            name: "--notes",
            form: .value(placeholder: "summary", grammar: .opaque),
            summary: "release summary",
            isRequired: true),
          CLIOptionSpec(
            name: "--out",
            form: .value(placeholder: "directory", grammar: .opaque),
            summary: "output directory",
            isRequired: true),
          // `--output json` only. `--json` means "the daemon reply, pretty
          // printed" (§12 legacy-json), and this family never speaks to the
          // daemon — offering it would promise a shape that has no source.
          outputOption,
        ]),
      CLILeafSpec(
        token: "assemble",
        canonicalCommand: "maintainer.update-feed.assemble",
        summary: "verify a detached signature and assemble the feed",
        options: [
          CLIOptionSpec(
            name: "--payload",
            form: .value(placeholder: "payload.json", grammar: .opaque),
            summary: "payload emitted by `prepare`",
            isRequired: true),
          CLIOptionSpec(
            name: "--signature",
            form: .value(placeholder: "signature.bin", grammar: .opaque),
            summary: "raw 64-byte detached signature",
            isRequired: true),
          CLIOptionSpec(
            name: "--out",
            form: .value(placeholder: "feed.json", grammar: .opaque),
            summary: "assembled feed output path",
            isRequired: true),
          outputOption,
        ]),
    ])

  /// §12: the superseded spelling of `maintainer update-feed`, derived so it cannot drift.
  private static let updateFeedNode = CLINodeSpec(
    token: "update-feed",
    summary: "superseded spelling of `maintainer update-feed`",
    leaves: compatibilitySpelling(
      of: maintainerUpdateFeedNode.leaves, as: "update-feed", replacedBy: "maintainer update-feed"))

  // MARK: Lookup

  /// The daemon's own ceiling for one `artifact.read` (§13.2).
  ///
  /// It silently clamps a larger request to this, which rewrites the caller's
  /// intent into a short read they cannot distinguish from the end of the
  /// artifact. §7.6's target contract refuses instead, so the parser refuses
  /// here — the wire request is unchanged, and the clamp simply becomes
  /// unreachable from this CLI.
  static let artifactReadMaximumBytes = 4 * 1024 * 1024

  /// The Golden Journey order root help leads with (§10).
  static let rootHelpHighlights: [String] = [
    "doctor", "device adopt", "operation describe", "agent run", "job status",
    "artifact export",
  ]

  static func node(_ token: String) -> CLINodeSpec? {
    nodes.first { $0.token == token }
  }

  static func rootLeaf(_ token: String) -> CLILeafSpec? {
    rootLeaves.first { $0.token == token }
  }

  /// Every executable, tombstoned and refused leaf, as `(path, leaf)`.
  static func allLeaves() -> [(path: [String], leaf: CLILeafSpec)] {
    var found: [(path: [String], leaf: CLILeafSpec)] = []
    for leaf in rootLeaves { found.append(([leaf.token], leaf)) }
    for node in nodes { found.append(contentsOf: node.reachableLeaves()) }
    return found
  }
}

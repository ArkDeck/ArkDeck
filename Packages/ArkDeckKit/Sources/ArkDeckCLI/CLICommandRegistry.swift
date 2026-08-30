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
  /// One of a closed set of tokens, compared byte for byte.
  case enumeration([String])
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
  case tombstone(replacement: CLIReplacement)
  /// Recognised and permanently refused — the capability is Runtime-owned and
  /// is not going to gain a caller-facing form.
  case refused(reason: String)
}

/// The machine half of a tombstone answer.
enum CLIReplacement: Equatable {
  /// The exact command path that does this now.
  case command(String)
  /// Nothing replaces it, and this says why.
  case none(reason: String)
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
struct CLINodeSpec {
  let token: String
  let summary: String
  var leaves: [CLILeafSpec] = []
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

  /// `--output`, scoped in this release to the registry meta-commands and
  /// `--version`. The Runtime leaves still publish `--json`; migrating them to
  /// the versioned envelope is its own vertical change, and declaring the
  /// option before it is honoured would advertise a mode that does not work.
  static let outputOption = CLIOptionSpec(
    name: "--output",
    form: .value(
      placeholder: "human|json",
      grammar: .enumeration([CLIOutputMode.human.rawValue, CLIOutputMode.json.rawValue])),
    summary: "output mode; machine modes emit one arkdeck.cli.result/1 document")

  /// The legacy machine-output flag on Runtime leaves.
  static let jsonOption = CLIOptionSpec(
    name: "--json",
    form: .flag,
    summary: "emit the reply as JSON instead of the human layout")

  /// §11.1: recognised on macOS, never advertised, never a business parameter.
  static let socketOption = CLIOptionSpec(
    name: "--socket",
    form: .value(placeholder: "absolute-path", grammar: .opaque),
    summary: "macOS-only compatibility alias for the local Runtime endpoint",
    stability: .macosCompatibilityOnly)

  private static func runtimeClientOptions(_ own: [CLIOptionSpec]) -> [CLIOptionSpec] {
    own + [jsonOption, socketOption]
  }

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
  static let rootLeaves: [CLILeafSpec] = [helpLeaf, commandsLeaf, completionLeaf]

  // MARK: Product commands

  static let nodes: [CLINodeSpec] = [
    doctorNode, operationNode, deviceNode, targetlessTraceNode, jobNode, artifactNode,
    agentNode, capabilityNode, cleanupDebtNode, debugNode, flashNode, agentdNode,
    signingNode, updateFeedNode,
  ]

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
        mutuallyExclusive: [
          ["--request-file", "--target"], ["--request-file", "--operation"],
          ["--request-file", "--inputs-file"],
          ["--request-file", "--expected-binding-revision"],
        ],
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
        mutuallyExclusive: [
          ["--request-file", "--target"], ["--request-file", "--operation"],
          ["--request-file", "--inputs-file"],
          ["--request-file", "--expected-binding-revision"],
        ],
        connectsToRuntime: true),
      CLILeafSpec(
        token: "status",
        canonicalCommand: "job.status",
        summary: "compact job state, progress and unknown-outcome flag",
        options: runtimeClientOptions([jobIDOption]),
        connectsToRuntime: true),
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
        token: "reconcile",
        canonicalCommand: "job.reconcile",
        summary: "settle an unknown outcome by readback; never replays the effect",
        options: runtimeClientOptions([jobIDOption]),
        connectsToRuntime: true),
    ])

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
        summary: "bounded read of artifact content",
        options: runtimeClientOptions([
          jobIDOption, requiredArtifactIDOption, allowSensitiveOption,
        ]),
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
    ])

  private static let requiredArtifactIDOption = CLIOptionSpec(
    name: "--artifact",
    form: .value(placeholder: "artifact-id", grammar: .opaque),
    summary: "exact artifact identity",
    isRequired: true)

  private static let agentNode = CLINodeSpec(
    token: "agent",
    summary: "high-level typed execution entry for an external agent",
    leaves: [
      CLILeafSpec(
        token: "run",
        canonicalCommand: "agent.run",
        summary: "discovery, binding, submit, run, evidence and artifact inventory",
        options: runtimeClientOptions([
          CLIOptionSpec(
            name: "--operation",
            form: .value(placeholder: "id@version", grammar: .opaque),
            summary: "exact published operation reference",
            isRequired: true),
          CLIOptionSpec(
            name: "--target",
            form: .value(placeholder: "target-id", grammar: .opaque),
            summary: "durable target; omitted lets typed discovery choose"),
          CLIOptionSpec(
            name: "--inputs-file",
            form: .value(placeholder: "path", grammar: .opaque),
            summary: "typed operation inputs"),
          CLIOptionSpec(
            name: "--capability",
            form: .value(placeholder: "CAP-RT-...", grammar: .opaque),
            summary: "reference to an existing Runtime capability; never a document"),
          CLIOptionSpec(
            name: "--execution-id",
            form: .value(placeholder: "id", grammar: .opaque),
            summary: "caller-stable execution identity for safe re-entry"),
        ]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "resume",
        canonicalCommand: "agent.resume",
        summary: "resume an execution paused for typed physical assistance",
        options: runtimeClientOptions([
          CLIOptionSpec(
            name: "--resume-token",
            form: .value(placeholder: "token", grammar: .opaque),
            summary: "token published by the paused execution",
            isRequired: true),
          CLIOptionSpec(
            name: "--selection",
            form: .value(placeholder: "value", grammar: .opaque),
            summary: "typed selection the human action asked for"),
        ]),
        connectsToRuntime: true),
      CLILeafSpec(
        token: "chat",
        canonicalCommand: "agent.chat",
        summary: "retired: ArkDeck holds no model of its own",
        kind: .tombstone(replacement: .command("agent run"))),
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
    summary: "protected destructive Flash recovery invocations",
    leaves: [
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
            summary: "replace an existing binding instead of leaving it unchanged")
        ]),
      CLILeafSpec(
        token: "status",
        canonicalCommand: "flash.status",
        summary: "decode one historical campaign record; cannot dispatch",
        options: [
          CLIOptionSpec(
            name: "--campaign-id",
            form: .value(placeholder: "ECAMP-id", grammar: .opaque),
            summary: "historical campaign identity",
            isRequired: true)
        ]),
      CLILeafSpec(
        token: "reconcile",
        canonicalCommand: "flash.reconcile",
        summary: "decode interrupted flash session journals; zero device dispatch",
        options: [
          CLIOptionSpec(
            name: "--session",
            form: .value(placeholder: "session-id", grammar: .opaque),
            summary: "inspect one session instead of every unresolved one")
        ]),
      CLILeafSpec(
        token: "plan",
        canonicalCommand: "flash.plan",
        summary: "retired: the Runtime materializes flash plans",
        kind: .tombstone(replacement: .command("job plan --operation flash.full-restore@1"))),
      CLILeafSpec(
        token: "preview",
        canonicalCommand: "flash.preview",
        summary: "retired: the Runtime owns Flash admission",
        kind: .tombstone(
          replacement: .none(reason: "Runtime admission replaced campaign preview"))),
      CLILeafSpec(
        token: "execute",
        canonicalCommand: "flash.execute",
        summary: "retired: the legacy host executor no longer exists",
        kind: .tombstone(replacement: .command("agent run --operation flash.full-restore@1"))),
      CLILeafSpec(
        token: "continue",
        canonicalCommand: "flash.continue",
        summary: "retired: historical campaign continuation cannot dispatch",
        kind: .tombstone(
          replacement: .none(reason: "historical campaigns are decode-only"))),
      CLILeafSpec(
        token: "postflight",
        canonicalCommand: "flash.postflight",
        summary: "retired: use Runtime job evidence",
        kind: .tombstone(replacement: .command("job status"))),
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

  private static let agentdNode = CLINodeSpec(
    token: "agentd",
    summary: "the local Runtime service for the current user",
    leaves: [
      CLILeafSpec(
        token: "install",
        canonicalCommand: "agentd.install",
        summary: "install the daemon as a user-domain service",
        options: agentdInstallOptions + [jsonOption]),
      CLILeafSpec(
        token: "update",
        canonicalCommand: "agentd.update",
        summary: "update the installed daemon and its pinned host tools",
        options: agentdInstallOptions + [jsonOption]),
      CLILeafSpec(
        token: "restart",
        canonicalCommand: "agentd.restart",
        summary: "restart the installed daemon",
        options: [maximumWaitSecondsOption, jsonOption]),
      CLILeafSpec(
        token: "status",
        canonicalCommand: "agentd.status",
        summary: "service and daemon health",
        options: [jsonOption]),
      CLILeafSpec(
        token: "verify",
        canonicalCommand: "agentd.verify",
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
          jsonOption,
        ],
        mutuallyExclusive: [
          ["--job", "--target"], ["--job", "--maximum-wait-seconds"],
          ["--job", "--execution-id"],
        ]),
      CLILeafSpec(
        token: "uninstall",
        canonicalCommand: "agentd.uninstall",
        summary: "remove the installed daemon service",
        options: [jsonOption]),
    ])

  private static let signingNode = CLINodeSpec(
    token: "signing",
    summary: "local OpenHarmony signing presets; secrets stay in the platform store",
    leaves: [
      CLILeafSpec(
        token: "install-sdk-release",
        canonicalCommand: "signing.install-sdk-release",
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
          projectRefOption, jsonOption,
        ]),
      CLILeafSpec(
        token: "install",
        canonicalCommand: "signing.install",
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
          projectRefOption, jsonOption,
        ]),
      CLILeafSpec(
        token: "normalize",
        canonicalCommand: "signing.normalize",
        summary: "normalize an installed preset in place",
        options: [jsonOption]),
      CLILeafSpec(
        token: "migrate-deveco",
        canonicalCommand: "signing.migrate-deveco",
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
          jsonOption,
        ]),
      CLILeafSpec(
        token: "status",
        canonicalCommand: "signing.status",
        summary: "installed preset status",
        options: [jsonOption]),
      CLILeafSpec(
        token: "remove",
        canonicalCommand: "signing.remove",
        summary: "remove the installed preset",
        options: [jsonOption]),
    ])

  private static let projectRefOption = CLIOptionSpec(
    name: "--project-ref",
    form: .value(placeholder: "project-ref", grammar: .opaque),
    summary: "registered workspace project the preset belongs to")

  private static let updateFeedNode = CLINodeSpec(
    token: "update-feed",
    summary: "maintainer update-feed tooling; never touches a private key",
    leaves: [
      CLILeafSpec(
        token: "prepare",
        canonicalCommand: "update-feed.prepare",
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
        ]),
      CLILeafSpec(
        token: "assemble",
        canonicalCommand: "update-feed.assemble",
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
        ]),
    ])

  // MARK: Lookup

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
    for node in nodes {
      for leaf in node.leaves {
        found.append((leaf.token.isEmpty ? [node.token] : [node.token, leaf.token], leaf))
      }
    }
    return found
  }
}

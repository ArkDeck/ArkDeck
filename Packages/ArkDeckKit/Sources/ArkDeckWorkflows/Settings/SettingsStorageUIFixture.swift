import ArkDeckCore
import Foundation

/// A Runtime storage owner for UI automation, standing in for the daemon's
/// `runtime.storage.*` replies and nothing else.
///
/// Like `ViewerUIFixture` this supplies a *domain* object — the protocol-2
/// reply the daemon frames — and never a presentation. The reply is composed
/// by the same `RuntimeSessionStorageStore` the daemon owns, against a
/// throwaway root under this process's temporary directory, so a launch driven
/// by it still exercises the App's real request framing, exact-shape
/// validation, generation-bound mutation and presentation mapping instead of a
/// second copy of them that could drift. Nothing here reaches XPC, and a
/// launch without the selecting argument never reaches any of it.
///
/// Why it exists: once the Settings facade moved to the Runtime-owned storage
/// owner, the Storage pane rendered nothing until `runtime.storage.status`
/// answered. Every developer machine runs the daemon, so the UI sweep passed
/// locally while the nightly runner — which has none — showed an empty pane.
/// The selecting argument is the one that already makes the Runtime a fixture
/// for History, continuation and job control: a launch that fakes the Runtime
/// fakes its storage owner too.
public enum SettingsStorageUIFixture {
  public static let selectingArgument = "--ui-test-runtime-history"

  /// The fixture keeps its owner state and its Session root under
  /// `<temporary directory>/<directoryName>/`, the root being
  /// `<directoryName>/<sessionRootName>`.
  public static let directoryName = "ArkDeck-ui-fixture-storage"
  public static let sessionRootName = "Sessions"

  /// The policy the owner publishes at creation, chosen so that no product
  /// default can be mistaken for it: an untouched daemon owner reports
  /// 20 GiB / 2 GiB / 90 days. The UI sweep asserts the pane's editable
  /// fields carry these figures, so a launch that silently reached the host's
  /// real daemon fails loudly instead of passing on a machine that happens to
  /// run one. The root path would be the natural witness, but a selectable
  /// fact row's text is not readable by UI automation on macOS.
  public static let publishedPolicy = RuntimeSessionStoragePolicy(
    totalQuotaBytes: 12 * 1_024 * 1_024 * 1_024,
    safetyMarginBytes: 3 * 1_024 * 1_024 * 1_024,
    retentionDays: 45)

  /// The artifact domain is immutable Runtime state this fixture has no owner
  /// for, so it reports one fixed measurement: the daemon's default 8 GiB
  /// quota with 2.5 GiB in use, the figures the storage domain contract tests
  /// already use.
  public static let artifactTotalBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
  public static let artifactUsedBytes: UInt64 = 2_684_354_560

  public static func isSelected(
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> Bool {
    arguments.contains(selectingArgument)
  }

  /// The owner to install, or `nil` for every ordinary launch.
  package static func owner(arguments: [String]) -> Owner? {
    guard isSelected(arguments: arguments) else { return nil }
    return Owner(
      base: FileManager.default.temporaryDirectory.appending(
        path: directoryName, directoryHint: .isDirectory))
  }

  /// The in-process stand-in for the daemon's storage resource handler: the
  /// same three methods, closed parameter sets and error codes, dispatched to
  /// a real `RuntimeSessionStorageStore`. The App-side facade validates every
  /// reply against the published shape exactly as it validates the daemon's,
  /// which is what keeps this dispatch honest. Each process starts from a
  /// fresh owner that has taken exactly one write: `publishedPolicy` at
  /// generation 2, over the default root.
  package actor Owner {
    private let base: URL
    private var store: RuntimeSessionStorageStore?

    package init(base: URL) {
      self.base = base
    }

    /// The framed reply for one request, as the bytes the transport would
    /// hand back. Never throws: a request the owner refuses is a refusal
    /// frame, exactly as it would be over XPC.
    package func reply(_ method: String, _ params: [String: JSONValue]?) -> Data {
      let fields = params ?? [:]
      let outcome: Outcome
      do {
        let store = try owner()
        switch method {
        case "runtime.storage.status":
          guard fields.isEmpty else {
            throw RuntimeSessionStorageFailure(
              "invalidInput", "Runtime storage status accepts no parameters")
          }
          outcome = .published(try store.status())

        case "runtime.storage.policy":
          guard Set(fields.keys) == [
            "expectedGeneration", "totalQuotaBytes", "safetyMarginBytes", "retentionDays",
          ] else {
            throw RuntimeSessionStorageFailure(
              "invalidInput", "Runtime storage policy requires one closed policy document")
          }
          outcome = .published(
            try store.updatePolicy(
              RuntimeSessionStoragePolicy(
                totalQuotaBytes: try positive(fields["totalQuotaBytes"], label: "totalQuotaBytes"),
                safetyMarginBytes: try positive(
                  fields["safetyMarginBytes"], label: "safetyMarginBytes"),
                retentionDays: try positive(fields["retentionDays"], label: "retentionDays")),
              expectedGeneration: try positive(
                fields["expectedGeneration"], label: "expectedGeneration")))

        case "runtime.storage.root":
          guard fields.keys.contains("expectedGeneration"),
            Set(fields.keys).isSubset(of: ["expectedGeneration", "rootPath", "resetToDefault"])
          else {
            throw RuntimeSessionStorageFailure(
              "invalidInput", "Runtime storage root requires a generation and one selection")
          }
          let path: String?
          if let value = fields["rootPath"] {
            guard case .string(let candidate) = value else {
              throw RuntimeSessionStorageFailure("invalidInput", "rootPath must be a string")
            }
            path = candidate
          } else {
            path = nil
          }
          let reset: Bool
          if let value = fields["resetToDefault"] {
            guard case .bool(let flag) = value, flag else {
              throw RuntimeSessionStorageFailure(
                "invalidInput", "resetToDefault must be true when present")
            }
            reset = flag
          } else {
            reset = false
          }
          outcome = .published(
            try store.updateRoot(
              path: path, resetToDefault: reset,
              expectedGeneration: try positive(
                fields["expectedGeneration"], label: "expectedGeneration")))

        default:
          throw RuntimeSessionStorageFailure(
            "unknownMethod", "Runtime storage method is not published")
        }
      } catch let failure as RuntimeSessionStorageFailure {
        outcome = .refused(failure.code, failure.message)
      } catch {
        outcome = .refused("recordUnreadable", "Runtime storage state is unreadable")
      }
      return Self.frame(outcome)
    }

    private enum Outcome {
      case published(RuntimeSessionStorageStatus)
      case refused(String, String)
    }

    private func owner() throws -> RuntimeSessionStorageStore {
      if let store { return store }
      // Every process starts over. A leftover owner from an earlier launch
      // would carry that launch's mutations into this one.
      try? FileManager.default.removeItem(at: base)
      let created = try RuntimeSessionStorageStore(
        ownerRoot: base.appending(path: "owner", directoryHint: .isDirectory),
        defaultSessionsRoot: base.appending(
          path: SettingsStorageUIFixture.sessionRootName, directoryHint: .isDirectory))
      // One accepted write over the untouched owner. Generation 1 is also what
      // the facade's one-time legacy migration keys on, so this closes that
      // path by construction as well as by the provider's flag.
      _ = try created.updatePolicy(
        SettingsStorageUIFixture.publishedPolicy, expectedGeneration: 1)
      store = created
      return created
    }

    private func positive(_ value: JSONValue?, label: String) throws -> UInt64 {
      guard case .string(let text)? = value,
        !text.isEmpty, text.first != "0",
        text.utf8.allSatisfy({ (48...57).contains($0) }),
        let parsed = UInt64(text), parsed <= UInt64(Int64.max)
      else {
        throw RuntimeSessionStorageFailure(
          "invalidInput", "\(label) must be a canonical positive integer")
      }
      return parsed
    }

    /// The daemon's response envelope: `result` carries both storage domains
    /// under their own names, a refusal carries the owner's error code.
    private static func frame(_ outcome: Outcome) -> Data {
      let envelope: JSONValue
      switch outcome {
      case .published(let status):
        let total = SettingsStorageUIFixture.artifactTotalBytes
        let used = SettingsStorageUIFixture.artifactUsedBytes
        envelope = .object([
          "id": .string(replyID),
          "ok": .bool(true),
          "result": .object([
            "schemaVersion": .string("arkdeck.runtime-storage/1"),
            "sessionDomain": status.projection,
            "artifactDomain": .object([
              "schemaVersion": .string("arkdeck.artifact-storage-status/1"),
              "rootReference": .string("arkdeck-runtime://artifacts"),
              "policy": .string("refuseNewWorkNeverEvict"),
              "totalBytes": .string(String(total)),
              "usedBytes": .string(String(used)),
              "remainingBytes": .string(String(total - used)),
            ]),
          ]),
        ])
      case .refused(let code, let message):
        envelope = .object([
          "id": .string(replyID),
          "ok": .bool(false),
          "error": .object([
            "code": .string(code),
            "message": .string(message),
            "details": .object([
              "phase": .string("runtimeStorageOwner"),
              "newDispatchCount": .integer(0),
            ]),
          ]),
        ])
      }
      // A `JSONValue` tree of strings, bools and one integer always encodes.
      return (try? CanonicalJSONEncoders.canonical().encode(envelope)) ?? Data("{}".utf8)
    }

    private static let replyID = "settings-storage-ui-fixture"
  }
}

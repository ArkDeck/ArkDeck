import ArkDeckCore
import Foundation

/// In-memory replies for the explicitly selected UI-automation launch. This
/// fixture owns no storage, validates no host path, measures no disk usage and
/// cannot reach transport. Runtime storage integration tests exercise the real
/// owner separately; these values exercise only request/response presentation.
public enum SettingsStoragePresentationFixture {
  public static func make(
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> (any SettingsRuntimeStorageFixture)? {
    guard arguments.contains("--ui-test-runtime-history") else { return nil }
    let stateFile: URL?
    if let index = arguments.firstIndex(of: "--ui-test-fixture-state"),
      arguments.indices.contains(index + 1)
    {
      stateFile = URL(filePath: arguments[index + 1])
    } else {
      stateFile = nil
    }
    return Replies(arguments: arguments, stateFile: stateFile)
  }

  private actor Replies: SettingsRuntimeStorageFixture {
    let arguments: [String]
    let stateFile: URL?
    let defaultRoot = FileManager.default.temporaryDirectory
      .appending(path: "ArkDeck-ui-fixture-storage/Sessions", directoryHint: .isDirectory)
      .standardizedFileURL.path
    var generation = 2
    // 12 GiB / 3 GiB / 45 days matches no Runtime default (20 GiB / 2 GiB /
    // 90 days), so a UI sweep whose launch silently reached a real daemon
    // fails on the pane's editable fields instead of passing.
    var policy: [String: JSONValue] = [
      "totalQuotaBytes": .string("12884901888"),
      "safetyMarginBytes": .string("3221225472"), "retentionDays": .string("45"),
    ]
    var selectedRoot: String?

    init(arguments: [String], stateFile: URL?) {
      self.arguments = arguments
      self.stateFile = stateFile
    }

    func runtimeStorageReply(_ method: String, _ params: [String: JSONValue]?) -> Data? {
      let unreachable = "--ui-test-runtime-history-unreachable"
      let flags = stateFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
      guard !(flags?.contains(unreachable) ?? arguments.contains(unreachable)) else { return nil }
      let fields = params ?? [:]
      // Only echo the UI's closed request shape into a display snapshot. Do
      // not emulate Runtime quota enforcement, path admission or persistence.
      switch method {
      case "runtime.storage.status":
        guard fields.isEmpty else { return failure("invalidInput") }
      case "runtime.storage.policy", "runtime.storage.root":
        guard fields["expectedGeneration"] == .string(String(generation)) else {
          return failure("resourceConflict")
        }
        if method == "runtime.storage.policy" {
          guard
            Set(fields.keys) == [
              "expectedGeneration", "totalQuotaBytes", "safetyMarginBytes", "retentionDays",
            ]
          else {
            return failure("invalidInput")
          }
          policy = fields.filter { $0.key != "expectedGeneration" }
        } else if Set(fields.keys) == ["expectedGeneration", "rootPath"],
          case .string(let path)? = fields["rootPath"]
        {
          selectedRoot = path
        } else if Set(fields.keys) == ["expectedGeneration", "resetToDefault"],
          fields["resetToDefault"] == .bool(true)
        {
          selectedRoot = nil
        } else {
          return failure("invalidInput")
        }
        generation += 1
      default: return failure("unknownMethod")
      }
      return encode([
        "ok": .bool(true),
        "result": .object([
          "schemaVersion": .string("arkdeck.runtime-storage/1"),
          "sessionDomain": .object([
            "schemaVersion": .string("arkdeck.session-storage-status/1"),
            "generation": .string(String(generation)),
            "rootPath": .string(selectedRoot ?? defaultRoot),
            "rootKind": .string(selectedRoot == nil ? "default" : "custom"),
            "policy": .object(policy), "catalogGeneration": .null,
            "usage": .object([
              "usedBytes": .string("0"), "pinnedBytes": .string("0"),
              "sessionCount": .string("0"), "pinnedSessionCount": .string("0"),
              "unaccountedSessionCount": .string("0"), "measurementIncomplete": .bool(false),
            ]),
          ]),
          "artifactDomain": .object([
            "schemaVersion": .string("arkdeck.artifact-storage-status/1"),
            "rootReference": .string("arkdeck-runtime://artifacts"),
            "policy": .string("refuseNewWorkNeverEvict"),
            "totalBytes": .string("8589934592"), "usedBytes": .string("2684354560"),
            "remainingBytes": .string("5905580032"),
          ]),
        ]),
      ])
    }

    private func failure(_ code: String) -> Data? {
      encode([
        "ok": .bool(false),
        "error": .object([
          "code": .string(code), "message": .string("UI fixture request was not expected"),
        ]),
      ])
    }

    private func encode(_ fields: [String: JSONValue]) -> Data? {
      try? CanonicalJSONEncoders.canonical().encode(fields)
    }
  }
}

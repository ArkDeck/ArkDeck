import ArkDeckAgentClient
import ArkDeckCore
import Foundation

extension RuntimeCLI {
  static func runHDCControlAction(_ arguments: [String], command: String) throws {
    var rest = arguments
    var session = runtimeSession(&rest, command: command)
    let options = try CLIOptions(rest)
    var fields: [String: JSONValue] = [:]
    switch command {
    case "runtime.hdc.impact-preview":
      for (flag, key) in [("--action", "action"), ("--server-endpoint-ref", "serverEndpointRef"),
        ("--expected-server-generation", "expectedServerGeneration"), ("--action-request-id", "actionRequestId")] {
        guard let value = options.value(flag) else { throw session.fail(.invalidInput, "an exact lifecycle intent and stable action request ID are required") }
        fields[key] = .string(value)
      }
      do { _ = try HDCControlActionIntent(fields) }
      catch { throw session.fail(.invalidInput, "HDC control-action intent failed validation") }
    case "runtime.hdc.restart":
      for (flag, key, validate) in [
        ("--control-action", "controlAction", HDCControlValue.identifier),
        ("--preview-id", "previewId", HDCControlValue.identifier),
        ("--preview-digest", "previewDigest", HDCControlValue.digest),
      ] {
        guard let value = options.value(flag), validate(value) else {
          throw session.fail(.invalidInput, "restart requires one exact control-action preview tuple")
        }
        fields[key] = .string(value)
      }
    case "control-action.show", "control-action.reconcile":
      guard let id = options.value("--control-action"), HDCControlValue.identifier(id) else {
        throw session.fail(.invalidInput, "an exact control-action identity is required")
      }
      fields["controlAction"] = .string(id)
    case "control-action.list":
      for (flag, key) in [("--kind", "kind"), ("--state", "state"), ("--cursor", "cursor")] {
        if let value = options.value(flag) { fields[key] = .string(value) }
      }
      if let text = options.value("--page-size"), let number = Int64(text) { fields["pageSize"] = .integer(number) }
    default: throw session.fail(.invalidCommand, "unsupported control-action command")
    }
    if let text = options.value("--timeout") {
      guard let duration = CLIDuration.parse(text, maximumMilliseconds: 86_400_000) else { throw session.fail(.invalidInput, "invalid bounded control timeout") }
      session.client = session.client.bounded(by: try AgentClientWaitDeadline(milliseconds: duration.milliseconds))
    }
    try session.negotiate(requiredMajor: 2, forMethod: command)
    session.emit(try session.request(command, fields))
  }
}

import ArkDeckAgentClient
import ArkDeckCore
import Foundation

/// How one invocation renders its result.
///
/// §12 makes this three modes rather than two. `--output json` is the new
/// versioned contract; `--json` keeps the shape it has always had, because
/// changing what an existing flag prints is a breaking change that belongs to
/// the next CLI major, not to the release that introduces the replacement.
enum CLIRendering: Equatable {
  /// A readable summary on stdout; progress and warnings on stderr.
  case human
  /// The daemon reply, pretty-printed, exactly one document (§12 legacy-json).
  /// Not the versioned envelope, and never carries `meta`.
  case legacyJSON
  /// One `arkdeck.cli.result/1` document (§8.2).
  case envelope
}

/// §12 lifecycle metadata for a leaf, reported in machine output so a caller
/// can see it is driving a compatibility surface rather than the target one.
/// It answers one question only: is there a newer spelling of this command?
/// Whether a leaf meets the *target contract* is separate — `device candidates`
/// is the target spelling (§6.1) and therefore `current`, while its 1.x
/// response still lacks the snapshot generation §13.2 wants. Overloading one
/// field with both would make `legacy` mean two different things to a caller.
enum CLILifecycleStatus: String, Equatable {
  /// The current, published spelling of this command.
  case current
  /// An explicit legacy-compatibility leaf. It works, but its request,
  /// response and effect are the frozen 1.x ones, so it does not count as
  /// target conformance.
  case legacy
  /// The command still runs but an exact replacement is published.
  case deprecated
}

/// One invocation's connection to the local Runtime, plus everything needed to
/// answer in the shape the caller asked for.
///
/// It exists so that the method name is in scope at the failure site. §8.4
/// resolves an ambiguous control failure from what the method can do, and the
/// old code threw that information away the moment it called
/// `client.request(method:)` and let the error propagate to a generic `catch`
/// that exited 1 — which reported an unknown outcome as a plain failure.
struct CLIRuntimeSession {
  /// Whether this invocation has already put its one document on stdout.
  ///
  /// A reference so that copies of the session share it: §8.1 allows exactly
  /// one document per machine invocation, and the rule is worth enforcing
  /// mechanically rather than by remembering. `job result` and
  /// `operation validate` both emit a result and *then* exit non-zero, which
  /// is what §8.2 asks for — and the obvious way to write that emits an error
  /// envelope after the result, giving a parser two documents where it expects
  /// one.
  final class OutputState {
    var hasEmitted = false
  }

  let client: AgentClient
  /// The canonical dotted command, e.g. `job.status`.
  let command: String
  let rendering: CLIRendering
  let controlRequestID: String
  let lifecycle: CLILifecycleStatus
  /// The argv pattern that supersedes this command, when one is published.
  var replacementArgvPattern: String?
  let outputState = OutputState()

  var isMachineOutput: Bool { rendering != .human }

  /// Sends one request and maps any failure onto the §8.4 registry.
  func request(_ method: String, _ params: [String: JSONValue]? = nil) throws -> JSONValue {
    do {
      return try client.request(method: method, params: params)
    } catch let error as AgentClientError {
      throw stamped(CLIRuntimeSession.mapped(error, method: method, command: command))
    }
  }

  /// Attaches the rendering this invocation asked for, so the failure can be
  /// answered in the caller's shape wherever it is finally caught.
  func stamped(_ error: CLIRegistryError) -> CLIRegistryError {
    var stamped = error
    stamped.rendering = rendering
    stamped.controlRequestID = controlRequestID
    stamped.lifecycle = lifecycle
    stamped.replacementArgvPattern = replacementArgvPattern
    return stamped
  }

  /// Raises a domain failure of this command in the caller's shape.
  ///
  /// After a result has been emitted the failure keeps its code and its exit
  /// status but stops being a machine document: §8.2 makes those cases
  /// `ok: true` with a full result, so the outcome travels in the exit status
  /// and a stderr diagnostic instead of a second frame on stdout.
  func fail(_ code: CLIErrorCode, _ message: String, details: [String: JSONValue] = [:])
    -> CLIRegistryError
  {
    var error = stamped(
      CLIRegistryError(code: code, message: message, details: details, command: command))
    error.suppressesMachineRendering = outputState.hasEmitted
    return error
  }

  static func mapped(_ error: AgentClientError, method: String, command: String)
    -> CLIRegistryError
  {
    switch error {
    case .daemonError(let wireCode, let message):
      // The daemon's wire error carries no structured details today, so the
      // evidence half of §8.4 is always empty and every ambiguous failure from
      // a mutation-capable method resolves to `outcomeUnknown`. That is the
      // spec's intended fail-closed default; sharpening it back to
      // `admissionDenied` needs the handler to publish `phase` and
      // `newDispatchCount`, which is a daemon-side change.
      let code = CLIControlFailureMapper.code(forWireCode: wireCode, method: method)
      return CLIRegistryError(
        code: code,
        message: message,
        details: [
          "method": .string(method),
          "wireCode": .string(wireCode),
        ],
        command: command)
    case .connectFailed(let message):
      return transportError(.connectFailed, method: method, command: command, cause: message)
    case .malformedResponse(let message):
      return transportError(.malformedResponse, method: method, command: command, cause: message)
    case .transport(let message):
      // The client cannot tell a timeout from a closed peer without reading its
      // own message text, and a code chosen by matching prose is exactly what
      // §8.4 forbids. Both prove the same thing — a request may have been sent
      // and no response completed — so both are reported as a lost response.
      return transportError(.lostResponse, method: method, command: command, cause: message)
    }
  }

  private static func transportError(
    _ failure: CLITransportFailure, method: String, command: String, cause: String
  ) -> CLIRegistryError {
    let code = CLIControlFailureMapper.code(forTransportFailure: failure, method: method)
    return CLIRegistryError(
      code: code,
      message: cause,
      details: ["method": .string(method)],
      command: command)
  }

  // MARK: Output

  /// The one result document for this invocation.
  func emit(_ value: JSONValue) {
    outputState.hasEmitted = true
    switch rendering {
    case .human:
      print(RuntimeCLI.humanRendering(of: value))
    case .legacyJSON:
      FileHandle.standardOutput.write(Data(CLIRuntimeSession.legacyDocument(value).utf8))
    case .envelope:
      var envelope = CLIResultEnvelope.success(
        command: command, result: value, controlRequestID: controlRequestID)
      envelope = CLIResultEnvelope.withLifecycle(
        envelope, lifecycle, replacement: replacementArgvPattern)
      FileHandle.standardOutput.write(Data(CLIResultEnvelope.render(envelope).utf8))
    }
  }

  /// §12: the deprecation warning for an alias goes to stderr in human mode
  /// only. In machine mode it belongs in `meta.lifecycle`, so that stdout
  /// stays exactly one parseable document.
  func warnIfLegacy() {
    guard rendering == .human, lifecycle != .current else { return }
    var text = "warning: `\(command.replacingOccurrences(of: ".", with: " "))` is "
      + "\(lifecycle.rawValue)"
    if let replacementArgvPattern { text += "; use `\(replacementArgvPattern)`" }
    FileHandle.standardError.write(Data((text + "\n").utf8))
  }

  /// Progress a person wants and a machine must not see on stdout (§8.1).
  func progress(_ text: String) {
    guard rendering == .human else { return }
    FileHandle.standardError.write(Data((text + "\n").utf8))
  }

  /// §12 requires legacy-json to stay the shape it has always had while fixing
  /// its two defects: it emitted several documents on the `--wait` compound,
  /// and it silently fell back to the human renderer when encoding failed —
  /// handing a machine caller prose where it expected JSON.
  static func legacyDocument(_ value: JSONValue) -> String {
    let encoder = CanonicalJSONEncoders.canonicalPretty()
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8)
    else {
      return """
        {"error":{"code":"internalError",\
        "message":"the daemon reply could not be encoded as JSON"}}

        """
    }
    return text + "\n"
  }
}

/// §8.1's correlation identity.
///
/// The pattern is deliberately narrow — it ends up in machine output and in
/// Runtime audit, so it must not be able to carry a delimiter, a newline or a
/// non-ASCII scalar that a downstream reader would have to normalise.
enum CLIControlRequestID {
  static func isValid(_ value: String) -> Bool {
    let scalars = Array(value.unicodeScalars)
    guard (1...128).contains(scalars.count) else { return false }
    func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
      ("0"..."9").contains(scalar) || ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar)
    }
    guard isAlphanumeric(scalars[0]) else { return false }
    return scalars.dropFirst().allSatisfy { scalar in
      isAlphanumeric(scalar) || scalar == "." || scalar == "_" || scalar == ":" || scalar == "-"
    }
  }

  static func generated() -> String {
    "ctl-" + UUID().uuidString.lowercased()
  }
}

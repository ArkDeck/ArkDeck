import ArkDeckCore
import Foundation

/// One dispatched control frame: the parsed request and the response the
/// handler produced for it. Structurally refused frames (malformed, wrong
/// version or contract identity, unknown method) never reach dispatch, so they
/// are never recorded; what is recorded is exactly what a client read back.
package struct ControlFrameRecord: Sendable {
  package let request: AgentWireProtocol.Request
  package let response: AgentWireProtocol.Response

  package init(request: AgentWireProtocol.Request, response: AgentWireProtocol.Response) {
    self.request = request
    self.response = response
  }

  /// The canonical JSON line the recorded corpus stores: the protocol version,
  /// the method, the request parameters and the response body. The request and
  /// response identifiers carry no contract and the contract identity is a
  /// constant of the build, so neither is stored; everything a per-method
  /// schema constrains is kept.
  package func encodedLine() throws -> Data {
    var fields: [String: JSONValue] = [
      "protocolVersion": .string(request.protocolVersion),
      "method": .string(request.method),
      "ok": .bool(response.ok),
    ]
    if let params = request.params { fields["params"] = .object(params) }
    if let result = response.result { fields["result"] = result }
    if let error = response.error {
      var errorFields: [String: JSONValue] = [
        "code": .string(error.code), "message": .string(error.message),
      ]
      if let details = error.details { errorFields["details"] = .object(details) }
      fields["error"] = .object(errorFields)
    }
    return try CanonicalJSONEncoders.canonical().encode(JSONValue.object(fields))
  }
}

/// A debug-build recorder driven by `ARKDECK_CONTROL_FRAME_LOG`: every frame
/// the handler dispatches is appended as one canonical JSON line to
/// `<directory>/control-frames-<pid>.jsonl`. The contract-test run that
/// derives and checks `spec/control/methods/*.json` is its only consumer. A
/// release build never reads the variable, so a production daemon cannot be
/// made to write frames to disk by its environment.
package enum ControlFrameRecorder {
  package static let environmentVariable = "ARKDECK_CONTROL_FRAME_LOG"

  static func environmentObserver() -> (@Sendable (ControlFrameRecord) -> Void)? {
    #if DEBUG
      guard let directory = ProcessInfo.processInfo.environment[environmentVariable],
        !directory.isEmpty
      else { return nil }
      let sink = ControlFrameSink.shared(directory: directory)
      return { record in sink.append(record) }
    #else
      return nil
    #endif
  }
}

#if DEBUG
  /// One append-only file per process, shared by every handler the process
  /// creates, so concurrent handlers cannot interleave partial lines.
  private final class ControlFrameSink: @unchecked Sendable {
    private static let registry = NSLock()
    nonisolated(unsafe) private static var sinks: [String: ControlFrameSink] = [:]

    static func shared(directory: String) -> ControlFrameSink {
      registry.withLock {
        if let existing = sinks[directory] { return existing }
        let sink = ControlFrameSink(directory: directory)
        sinks[directory] = sink
        return sink
      }
    }

    private let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?

    private init(directory: String) {
      let root = URL(fileURLWithPath: directory, isDirectory: true)
      url = root.appending(
        path: "control-frames-\(ProcessInfo.processInfo.processIdentifier).jsonl")
      try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func append(_ record: ControlFrameRecord) {
      guard let line = try? record.encodedLine() else { return }
      lock.withLock {
        if handle == nil {
          if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
          }
          handle = try? FileHandle(forWritingTo: url)
          _ = try? handle?.seekToEnd()
        }
        try? handle?.write(contentsOf: line + Data("\n".utf8))
      }
    }
  }
#endif

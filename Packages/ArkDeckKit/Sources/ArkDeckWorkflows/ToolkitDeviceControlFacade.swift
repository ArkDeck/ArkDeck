import ArkDeckCore
import ArkDeckRuntime
import Foundation

/// The Toolkit device-control surface: an on-demand screenshot and the three
/// published gestures, submitted as typed operations.
///
/// What this facade will not do is infer. A gesture's result is whatever the
/// runtime reported about the injection, never what the screen appears to do
/// afterwards; nothing here looks at the device again to decide whether a tap
/// "worked", because the operation cannot prove that and neither can a later
/// screenshot.

/// One frame the user is acting on, with the facts a gesture computed from it
/// has to carry.
public struct ToolkitScreenFrame: Sendable, Equatable {
  public let imageData: Data
  public let width: Int
  public let height: Int
  /// When the device produced it. The workspace shows this so the person can
  /// see how old the picture they are about to act on is; it is deliberately
  /// not turned into a freshness claim on the gesture, because an on-demand
  /// screenshot is a still the user reads at their own pace, not a live feed.
  public let capturedAtUTC: String
  public let jobID: String

  public init(imageData: Data, width: Int, height: Int, capturedAtUTC: String, jobID: String) {
    self.imageData = imageData
    self.width = width
    self.height = height
    self.capturedAtUTC = capturedAtUTC
    self.jobID = jobID
  }
}

public enum ToolkitGesture: String, Sendable, Equatable, CaseIterable {
  case tap
  case longPress
  case swipe

  public var operationID: String {
    switch self {
    case .tap: return "input.tap"
    case .longPress: return "input.long-press"
    case .swipe: return "input.swipe"
    }
  }

  public var operationReference: String { "\(operationID)@1" }
}

/// A gesture in device pixels, already mapped out of the view's coordinate
/// space and bounded by the frame it was read from.
public struct ToolkitGestureRequest: Sendable, Equatable {
  public let gesture: ToolkitGesture
  public let x: Int
  public let y: Int
  public let toX: Int?
  public let toY: Int?
  public let durationMs: Int?
  public let frameWidth: Int
  public let frameHeight: Int

  public init(
    gesture: ToolkitGesture,
    x: Int,
    y: Int,
    frameWidth: Int,
    frameHeight: Int,
    toX: Int? = nil,
    toY: Int? = nil,
    durationMs: Int? = nil
  ) {
    self.gesture = gesture
    self.x = x
    self.y = y
    self.frameWidth = frameWidth
    self.frameHeight = frameHeight
    self.toX = toX
    self.toY = toY
    self.durationMs = durationMs
  }

  public var typedInputs: [String: JSONValue] {
    var inputs: [String: JSONValue] = [
      "displayWidth": .integer(Int64(frameWidth)),
      "displayHeight": .integer(Int64(frameHeight)),
    ]
    switch gesture {
    case .tap:
      inputs["x"] = .integer(Int64(x))
      inputs["y"] = .integer(Int64(y))
    case .longPress:
      inputs["x"] = .integer(Int64(x))
      inputs["y"] = .integer(Int64(y))
      if let durationMs { inputs["durationMs"] = .integer(Int64(durationMs)) }
    case .swipe:
      inputs["fromX"] = .integer(Int64(x))
      inputs["fromY"] = .integer(Int64(y))
      inputs["toX"] = .integer(Int64(toX ?? x))
      inputs["toY"] = .integer(Int64(toY ?? y))
      inputs["durationMs"] = .integer(Int64(durationMs ?? 300))
    }
    return inputs
  }
}

/// What the runtime said about one gesture. `unknown` is a real answer and is
/// never rewritten into either of the others: an input whose outcome the
/// runtime could not establish is reported as such, and is not resent.
public enum ToolkitGestureOutcome: Sendable, Equatable {
  case confirmed(summary: [String: String])
  case failed(reason: String)
  case unknown(reason: String)
}

public struct ToolkitTargetPresentation: Sendable, Equatable {
  public let id: String
  public let bindingRevision: Int?
  public let displayName: String

  public init(id: String, bindingRevision: Int?, displayName: String) {
    self.id = id
    self.bindingRevision = bindingRevision
    self.displayName = displayName
  }
}

public enum ToolkitScreenshotResult: Sendable, Equatable {
  case captured(ToolkitScreenFrame)
  case failed(String)
}

public protocol ToolkitDeviceControlProviding: Sendable {
  func captureScreen(target: ToolkitTargetPresentation) async -> ToolkitScreenshotResult
  func send(
    _ request: ToolkitGestureRequest, to target: ToolkitTargetPresentation
  ) async -> ToolkitGestureOutcome
}

public enum ToolkitDeviceControlFacade {
  public static let screenshotOperationReference = "capture.diagnostics@1"

  /// The screenshot leg alone. A Toolkit capture wants a current picture, not
  /// a diagnostic window: HiLog is off because draining its buffer can
  /// dominate the interaction, and the component tree is off because nothing
  /// here reads it.
  public static func screenshotRequest(
    target: ToolkitTargetPresentation, nonce: String
  ) throws -> RuntimeOperationRequest {
    try RuntimeOperationRequest(
      requestID: "toolkit-screen-\(nonce)",
      idempotencyKey: "toolkit-screen-\(nonce)",
      target: DurableTargetReference(
        targetID: target.id, expectedBindingRevision: target.bindingRevision),
      operation: RuntimeOperationReference(id: "capture.diagnostics", version: 1),
      inputs: [
        "durationSeconds": .integer(1),
        "captureHilog": .bool(false),
        "hilogFilters": .array([]),
        "uiDump": .bool(false),
        "crashLogs": .bool(false),
        "uiScreenshot": .bool(true),
        "uiComponentTree": .bool(false),
        "redactionProfile": .string("standard"),
      ],
      requestedOutputs: [.rawArtifacts, .hardwareEvidence],
      clientContext: RuntimeClientContext(
        clientName: ArkDeckAgentClientName.toolkitDeviceControl))
  }

  /// Every gesture is its own request with its own idempotency key. Two taps
  /// at one coordinate are two intents, not a retry of one, and a key that
  /// collapsed them would silently drop the second.
  public static func gestureRequest(
    _ gesture: ToolkitGestureRequest,
    target: ToolkitTargetPresentation,
    nonce: String
  ) throws -> RuntimeOperationRequest {
    try RuntimeOperationRequest(
      requestID: "toolkit-input-\(nonce)",
      idempotencyKey: "toolkit-input-\(nonce)",
      target: DurableTargetReference(
        targetID: target.id, expectedBindingRevision: target.bindingRevision),
      operation: RuntimeOperationReference(id: gesture.gesture.operationID, version: 1),
      inputs: gesture.typedInputs,
      requestedOutputs: [.hardwareEvidence],
      clientContext: RuntimeClientContext(
        clientName: ArkDeckAgentClientName.toolkitDeviceControl))
  }

  public static func make() -> any ToolkitDeviceControlProviding {
    ToolkitProductionProvider()
  }
}

private actor ToolkitProductionProvider: ToolkitDeviceControlProviding {
  private static let artifactChunkBytes = 1 << 20

  func captureScreen(target: ToolkitTargetPresentation) async -> ToolkitScreenshotResult {
    do {
      let request = try ToolkitDeviceControlFacade.screenshotRequest(
        target: target, nonce: UUID().uuidString)
      let terminal = try await runToTerminal(request)
      guard let jobID = terminal.jobID else {
        return .failed("the runtime returned no job identifier for the capture")
      }
      let screenshot = try await readScreenshot(jobID: jobID)
      return .captured(
        ToolkitScreenFrame(
          imageData: screenshot.data,
          width: screenshot.width,
          height: screenshot.height,
          capturedAtUTC: terminal.finishedAtUTC ?? "",
          jobID: jobID))
    } catch let failure as ToolkitFailure {
      return .failed(failure.message)
    } catch {
      return .failed("\(error)")
    }
  }

  func send(
    _ request: ToolkitGestureRequest, to target: ToolkitTargetPresentation
  ) async -> ToolkitGestureOutcome {
    do {
      let operation = try ToolkitDeviceControlFacade.gestureRequest(
        request, target: target, nonce: UUID().uuidString)
      let terminal = try await runToTerminal(operation)
      // An unknown outcome stays unknown. The workspace shows it as such and
      // offers no resend, because the runtime cannot say whether the gesture
      // reached the device and a second one might be the second gesture.
      if terminal.outcomeUnknown {
        return .unknown(
          reason: "the runtime could not establish whether this gesture was injected")
      }
      guard terminal.state == "succeeded" else {
        return .failed(reason: terminal.failure ?? "the gesture did not succeed")
      }
      return .confirmed(summary: terminal.injectionSummary)
    } catch let failure as ToolkitFailure {
      return .failed(reason: failure.message)
    } catch {
      return .failed(reason: "\(error)")
    }
  }

  // MARK: - Runtime plumbing

  private struct ToolkitFailure: Error { let message: String }

  private struct TerminalJob {
    let jobID: String?
    let state: String
    let outcomeUnknown: Bool
    let failure: String?
    let finishedAtUTC: String?
    let injectionSummary: [String: String]
  }

  private func runToTerminal(_ request: RuntimeOperationRequest) async throws -> TerminalJob {
    let encoded = try JSONEncoder().encode(request)
    guard let requestJSON = String(data: encoded, encoding: .utf8) else {
      throw ToolkitFailure(message: "the typed request could not be encoded")
    }
    let submitted = try await requestObject(
      method: "job.submit", params: ["requestJson": .string(requestJSON)],
      label: "Toolkit submission")
    guard let jobID = submitted["jobId"] as? String, !jobID.isEmpty else {
      throw ToolkitFailure(message: "the runtime accepted no job for this request")
    }
    let terminal = try await requestObject(
      method: "job.run", params: ["jobId": .string(jobID)], label: "Toolkit run")
    let state = terminal["state"] as? String ?? "unknown"
    let residue = terminal["outstandingResidueCount"] as? Int ?? 0
    let waitingForHuman = terminal["waitingForHuman"] as? Bool ?? false
    let unknown = terminal["outcomeUnknown"] as? Bool ?? false
    let timeline = terminal["timeline"] as? [String] ?? []
    if waitingForHuman {
      throw ToolkitFailure(message: "the runtime stopped for a human decision")
    }
    if residue > 0 {
      throw ToolkitFailure(message: "the job left \(residue) unresolved device residue entries")
    }
    return TerminalJob(
      jobID: jobID,
      state: state,
      outcomeUnknown: unknown,
      failure: (terminal["failure"] as? [String: Any])?["message"] as? String,
      finishedAtUTC: terminal["finishedAtUtc"] as? String,
      injectionSummary: ToolkitProductionProviderTestHook.injectionSummary(in: timeline))
  }

  private func readScreenshot(jobID: String) async throws -> (
    data: Data, width: Int, height: Int
  ) {
    let listed = try await requestObject(
      method: "artifact.list", params: ["jobId": .string(jobID)], label: "Toolkit artifacts")
    guard let artifacts = listed["artifacts"] as? [[String: Any]] else {
      throw ToolkitFailure(message: "the capture published no artifact index")
    }
    guard
      let entry = artifacts.first(where: { $0["name"] as? String == "screenshot.png" }),
      let artifactID = entry["artifactId"] as? String,
      entry["status"] as? String == "published",
      let expectedSHA = entry["sha256"] as? String,
      let byteCount = entry["byteCount"] as? Int
    else {
      throw ToolkitFailure(message: "the capture published no verified screenshot")
    }
    var data = Data()
    var offset = 0
    while offset < byteCount {
      let chunk = try await requestObject(
        method: "artifact.read",
        params: [
          "artifactId": .string(artifactID),
          "offset": .integer(Int64(offset)),
          "maxBytes": .integer(Int64(Self.artifactChunkBytes)),
          "allowSensitive": .bool(true),
        ], label: "Toolkit screenshot read")
      guard let base64 = chunk["base64"] as? String, let part = Data(base64Encoded: base64)
      else {
        throw ToolkitFailure(message: "the screenshot chunk was not readable")
      }
      data.append(part)
      guard let next = chunk["nextOffset"] as? Int, next > offset else { break }
      offset = next
      if chunk["eof"] as? Bool == true { break }
    }
    guard data.count == byteCount else {
      throw ToolkitFailure(
        message: "the screenshot is \(data.count) bytes but the runtime published \(byteCount)")
    }
    guard ToolkitScreenshotIntegrity.sha256Hex(data) == expectedSHA.lowercased() else {
      throw ToolkitFailure(message: "the screenshot did not match its published digest")
    }
    guard let size = ToolkitScreenshotIntegrity.pngPixelSize(data) else {
      throw ToolkitFailure(message: "the screenshot is not a readable PNG")
    }
    return (data, size.width, size.height)
  }

  private func requestObject(
    method: String, params: [String: JSONValue], label: String
  ) async throws -> [String: Any] {
    switch await RuntimeXPCRequestTransport.request(method: method, params: params) {
    case .failure(let error):
      throw ToolkitFailure(message: "\(label) failed: \(error.message)")
    case .success(let data):
      guard
        let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        throw ToolkitFailure(message: "\(label) returned an unreadable response")
      }
      if let error = envelope["error"] as? [String: Any] {
        let message = error["message"] as? String ?? "\(error)"
        throw ToolkitFailure(message: "\(label) was refused: \(message)")
      }
      guard let result = envelope["result"] as? [String: Any] else {
        throw ToolkitFailure(message: "\(label) returned no result")
      }
      return result
    }
  }
}

/// Screenshot checks that do not need an image framework, so they can run in
/// tests and on the actor without pulling AppKit into the workflow layer.
public enum ToolkitScreenshotIntegrity {
  public static func sha256Hex(_ data: Data) -> String {
    RuntimeJobRecord.sha256Hex(data)
  }

  /// PNG dimensions come from the IHDR header, which is fixed-position: an
  /// 8-byte signature, then a length and the `IHDR` tag, then width and height
  /// as big-endian 32-bit values. Reading them here means the frame the
  /// workspace maps against is the picture's own, not a number supplied
  /// alongside it.
  public static func pngPixelSize(_ data: Data) -> (width: Int, height: Int)? {
    let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    guard data.count >= 24, Array(data.prefix(8)) == signature else { return nil }
    let bytes = Array(data[8..<24])
    guard Array(bytes[4..<8]) == Array("IHDR".utf8) else { return nil }
    func value(_ slice: ArraySlice<UInt8>) -> Int {
      slice.reduce(0) { ($0 << 8) | Int($1) }
    }
    let width = value(bytes[8..<12])
    let height = value(bytes[12..<16])
    guard width > 0, height > 0 else { return nil }
    return (width, height)
  }
}

/// The timeline reader, kept outside the actor so it can be exercised
/// directly rather than through a hole opened in the actor for tests.
public enum ToolkitProductionProviderTestHook {
  /// The verified keys the runtime recorded for the injection step, read from
  /// the timeline it published rather than restated from the request. What
  /// the workspace shows is therefore what the runtime attested, and an
  /// injection it never verified shows nothing at all.
  public static func injectionSummary(in timeline: [String]) -> [String: String] {
    guard
      let line = timeline.first(where: { $0.hasPrefix("verified inject-pointer-input") })
    else { return [:] }
    let keys = line
      .replacingOccurrences(of: "verified inject-pointer-input", with: "")
      .trimmingCharacters(in: CharacterSet(charactersIn: " []"))
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
      .filter { !$0.isEmpty }
    return ["verifiedFacts": keys.joined(separator: ", ")]
  }
}

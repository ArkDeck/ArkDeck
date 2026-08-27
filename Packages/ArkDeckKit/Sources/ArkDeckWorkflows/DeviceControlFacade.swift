import ArkDeckCore
import ArkDeckRuntime
import Foundation

/// The Device device-control surface: an on-demand screenshot and the three
/// published gestures, submitted as typed operations.
///
/// What this facade will not do is infer. A gesture's result is whatever the
/// runtime reported about the injection, never what the screen appears to do
/// afterwards; nothing here looks at the device again to decide whether a tap
/// "worked", because the operation cannot prove that and neither can a later
/// screenshot.

/// One frame the user is acting on, with the facts a gesture computed from it
/// has to carry.
public struct DeviceScreenFrame: Sendable, Equatable {
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

public enum DeviceGesture: String, Sendable, Equatable, CaseIterable {
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
public struct DeviceGestureRequest: Sendable, Equatable {
  public let gesture: DeviceGesture
  public let x: Int
  public let y: Int
  public let toX: Int?
  public let toY: Int?
  public let durationMs: Int?
  public let frameWidth: Int
  public let frameHeight: Int

  public init(
    gesture: DeviceGesture,
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
public enum DeviceGestureOutcome: Sendable, Equatable {
  case confirmed(summary: [String: String])
  case failed(reason: String)
  case unknown(reason: String)
}

public struct DeviceTargetPresentation: Sendable, Equatable {
  public let id: String
  public let bindingRevision: Int?
  public let displayName: String

  public init(id: String, bindingRevision: Int?, displayName: String) {
    self.id = id
    self.bindingRevision = bindingRevision
    self.displayName = displayName
  }
}

public enum DeviceScreenshotResult: Sendable, Equatable {
  case captured(DeviceScreenFrame)
  case failed(String)
}

public protocol DeviceControlProviding: Sendable {
  func captureScreen(target: DeviceTargetPresentation) async -> DeviceScreenshotResult
  /// Reads one immutable screenshot from a completed historical Job. This
  /// path cannot submit a gesture or mark the frame live for input.
  func loadHistoricalScreen(
    jobID: String,
    targetID: String
  ) async -> DeviceScreenshotResult
  func send(
    _ request: DeviceGestureRequest, to target: DeviceTargetPresentation
  ) async -> DeviceGestureOutcome
  func recordScreen(
    frameCount: Int, target: DeviceTargetPresentation
  ) async -> DeviceScreenRecordingResult
  /// How much room the artifact store has left. Read-only, and asked before a
  /// run starts rather than discovered by one that gets refused.
  func artifactHeadroomBytes() async -> Int?
}

public extension DeviceControlProviding {
  func loadHistoricalScreen(
    jobID _: String,
    targetID _: String
  ) async -> DeviceScreenshotResult {
    .failed("This Device provider cannot read historical screenshots")
  }
}

/// The frames a run brought back, with the spacing they were taken at.
public struct DeviceScreenRecording: Sendable, Equatable {
  public let frames: [DeviceFrameArchive.Frame]
  public let frameDurationsSeconds: [Double]
  /// Asked for minus captured. A frame that failed is a gap in the run, and
  /// saying so is what stops a short recording reading as a complete one.
  public let framesMissing: Int

  public init(
    frames: [DeviceFrameArchive.Frame], frameDurationsSeconds: [Double], framesMissing: Int
  ) {
    self.frames = frames
    self.frameDurationsSeconds = frameDurationsSeconds
    self.framesMissing = framesMissing
  }
}

public enum DeviceScreenRecordingResult: Sendable, Equatable {
  case captured(DeviceScreenRecording)
  case failed(String)
}

public enum DeviceControlFacade {
  // Preserve published request/idempotency prefixes across the product rename:
  // the same nonce must continue to describe the same intent after an upgrade.
  public static let screenshotOperationReference = "capture.diagnostics@1"
  public static let recordingOperationReference = "capture.screen-sequence@1"

  /// A bounded run of stills. There is no duration to ask for: the rate is
  /// the device's display readback and cannot be requested, so a caller bounds
  /// the run by frames and reads back what it achieved.
  public static func recordingRequest(
    frameCount: Int, target: DeviceTargetPresentation, nonce: String
  ) throws -> RuntimeOperationRequest {
    try RuntimeOperationRequest(
      requestID: "toolkit-record-\(nonce)",
      idempotencyKey: "toolkit-record-\(nonce)",
      target: DurableTargetReference(
        targetID: target.id, expectedBindingRevision: target.bindingRevision),
      operation: RuntimeOperationReference(id: "capture.screen-sequence", version: 1),
      inputs: [
        "frameCount": .integer(Int64(frameCount)),
        // jpeg over png: 543 ms a frame against 765, and a tenth of the bytes,
        // measured on hardware. Scaling down was measured to save nothing at
        // all, so the frames stay at the device's own size.
        "imageType": .string("jpeg"),
        // The same number the workspace preflighted. The operation's host
        // storage preflight reads exactly this field, so sending a different
        // one would mean two answers to one question.
        "totalArtifactByteBudget": .integer(
          Int64(DeviceRecordingBudget.bytes(frameCount: frameCount))),
      ],
      requestedOutputs: [.hardwareEvidence],
      clientContext: RuntimeWorkspaceThread.clientContext(
        clientName: ArkDeckAgentClientName.deviceControl, targetID: target.id))
  }

  /// The screenshot leg alone. A Device capture wants a current picture, not
  /// a diagnostic window: HiLog is off because draining its buffer can
  /// dominate the interaction, and the component tree is off because nothing
  /// here reads it.
  ///
  /// It does not yet ask for JPEG, though this is exactly what that leg is
  /// for: measured over 50 captures each, p50 638 ms against 858 and 40,947
  /// bytes against 448,352, for a viewfinder nobody keeps. Sending
  /// `screenshotImageType` makes this request unplannable on any daemon that
  /// predates the field - measured: `input screenshotImageType is not
  /// declared by capture.diagnostics@1` - and the App carries no daemon-floor
  /// gate, so every Device capture would fail with a rejection the workspace
  /// cannot explain. Raising that floor is a decision to make deliberately,
  /// not a side effect of taking the faster encoding.
  public static func screenshotRequest(
    target: DeviceTargetPresentation, nonce: String
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
      clientContext: RuntimeWorkspaceThread.clientContext(
        clientName: ArkDeckAgentClientName.deviceControl, targetID: target.id))
  }

  /// Every gesture is its own request with its own idempotency key. Two taps
  /// at one coordinate are two intents, not a retry of one, and a key that
  /// collapsed them would silently drop the second.
  public static func gestureRequest(
    _ gesture: DeviceGestureRequest,
    target: DeviceTargetPresentation,
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
      clientContext: RuntimeWorkspaceThread.clientContext(
        clientName: ArkDeckAgentClientName.deviceControl, targetID: target.id))
  }

  public static func make() -> any DeviceControlProviding {
    DeviceProductionProvider()
  }
}

private actor DeviceProductionProvider: DeviceControlProviding {
  private static let artifactChunkBytes = 1 << 20

  func captureScreen(target: DeviceTargetPresentation) async -> DeviceScreenshotResult {
    do {
      let request = try DeviceControlFacade.screenshotRequest(
        target: target, nonce: UUID().uuidString)
      let terminal = try await runToTerminal(request)
      guard let jobID = terminal.jobID else {
        return .failed("the runtime returned no job identifier for the capture")
      }
      let screenshot = try await readScreenshot(jobID: jobID)
      return .captured(
        DeviceScreenFrame(
          imageData: screenshot.data,
          width: screenshot.width,
          height: screenshot.height,
          capturedAtUTC: terminal.finishedAtUTC ?? "",
          jobID: jobID))
    } catch let failure as DeviceFailure {
      return .failed(failure.message)
    } catch let failure as DeviceArtifactIndex.IndexUnreadable {
      return .failed(failure.message)
    } catch {
      return .failed("\(error)")
    }
  }

  func loadHistoricalScreen(
    jobID: String,
    targetID: String
  ) async -> DeviceScreenshotResult {
    guard !jobID.isEmpty, !targetID.isEmpty else {
      return .failed("the historical Device context is incomplete")
    }
    do {
      let status = try await requestObject(
        method: "job.status", params: ["jobId": .string(jobID)],
        label: "Historical Device Job")
      guard status["jobId"] as? String == jobID,
        status["targetId"] as? String == targetID,
        status["operation"] as? String == "capture.diagnostics@1",
        status["state"] as? String == "succeeded",
        status["waitingForHuman"] as? Bool == false,
        status["outcomeUnknown"] as? Bool == false,
        status["outstandingResidueCount"] as? Int == 0
      else {
        return .failed("the historical Device Job is not a confirmed screenshot capture")
      }
      let screenshot = try await readScreenshot(jobID: jobID)
      return .captured(
        DeviceScreenFrame(
          imageData: screenshot.data,
          width: screenshot.width,
          height: screenshot.height,
          capturedAtUTC: status["finishedAtUtc"] as? String ?? "",
          jobID: jobID))
    } catch let failure as DeviceFailure {
      return .failed(failure.message)
    } catch let failure as DeviceArtifactIndex.IndexUnreadable {
      return .failed(failure.message)
    } catch {
      return .failed("\(error)")
    }
  }

  func send(
    _ request: DeviceGestureRequest, to target: DeviceTargetPresentation
  ) async -> DeviceGestureOutcome {
    do {
      let operation = try DeviceControlFacade.gestureRequest(
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
    } catch let failure as DeviceFailure {
      return .failed(reason: failure.message)
    } catch {
      return .failed(reason: "\(error)")
    }
  }

  // MARK: - Runtime plumbing

  private struct DeviceFailure: Error { let message: String }

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
      throw DeviceFailure(message: "the typed request could not be encoded")
    }
    let submitted = try await requestObject(
      method: "job.submit", params: ["requestJson": .string(requestJSON)],
      label: "Device submission")
    guard let jobID = submitted["jobId"] as? String, !jobID.isEmpty else {
      throw DeviceFailure(message: "the runtime accepted no job for this request")
    }
    let terminal = try await requestObject(
      method: "job.run", params: ["jobId": .string(jobID)], label: "Device run")
    let state = terminal["state"] as? String ?? "unknown"
    let residue = terminal["outstandingResidueCount"] as? Int ?? 0
    let waitingForHuman = terminal["waitingForHuman"] as? Bool ?? false
    let unknown = terminal["outcomeUnknown"] as? Bool ?? false
    let timeline = terminal["timeline"] as? [String] ?? []
    if waitingForHuman {
      throw DeviceFailure(message: "the runtime stopped for a human decision")
    }
    if residue > 0 {
      throw DeviceFailure(message: "the job left \(residue) unresolved device residue entries")
    }
    return TerminalJob(
      jobID: jobID,
      state: state,
      outcomeUnknown: unknown,
      failure: (terminal["failure"] as? [String: Any])?["message"] as? String,
      finishedAtUTC: terminal["finishedAtUtc"] as? String,
      injectionSummary: DeviceProductionProviderTestHook.injectionSummary(in: timeline))
  }

  func recordScreen(
    frameCount: Int, target: DeviceTargetPresentation
  ) async -> DeviceScreenRecordingResult {
    do {
      let request = try DeviceControlFacade.recordingRequest(
        frameCount: frameCount, target: target, nonce: UUID().uuidString)
      let terminal = try await runToTerminal(request)
      guard let jobID = terminal.jobID else {
        return .failed("the runtime returned no job identifier for the recording")
      }
      guard terminal.state == "succeeded" else {
        return .failed(terminal.failure ?? "the recording did not succeed")
      }
      let label = "Device recording artifacts"
      let entries = try DeviceArtifactIndex.entries(
        inEnvelope: try await requestEnvelope(
          method: "artifact.list", params: ["jobId": .string(jobID)], label: label),
        label: label)
      guard let archive = DeviceArtifactIndex.published(named: "frames.tar", in: entries) else {
        return .failed("the recording published no verified frame archive")
      }
      let frames = try DeviceFrameArchive.frames(
        in: try await readArtifact(jobID: jobID, entry: archive, label: "Device frames"))

      // The timings are their own published product. Reading them rather than
      // assuming a cadence is the difference between a timeline and a guess.
      guard let indexEntry = DeviceArtifactIndex.published(named: "sequence.json", in: entries)
      else { return .failed("the recording published no observed frame timings") }
      let measured = try JSONSerialization.jsonObject(
        with: try await readArtifact(
          jobID: jobID, entry: indexEntry, label: "Device recording timings"))
      guard let index = measured as? [String: Any],
        let durations = index["frameDurationsSeconds"] as? [Double],
        durations.count == frames.count
      else {
        return .failed(
          "the recording brought back \(frames.count) frames with no matching timings")
      }
      return .captured(
        DeviceScreenRecording(
          frames: frames, frameDurationsSeconds: durations,
          framesMissing: index["framesMissing"] as? Int ?? 0))
    } catch let failure as DeviceFailure {
      return .failed(failure.message)
    } catch let failure as DeviceArtifactIndex.IndexUnreadable {
      return .failed(failure.message)
    } catch {
      return .failed("\(error)")
    }
  }

  func artifactHeadroomBytes() async -> Int? {
    guard
      let quota = try? await requestObject(
        method: "artifact.quota", params: [:], label: "Device artifact quota"),
      let remaining = quota["remainingBytes"] as? Int
    else { return nil }
    return remaining
  }

  /// One published artifact's bytes, in chunks, checked against the digest the
  /// runtime published for it.
  private func readArtifact(
    jobID: String, entry: DeviceArtifactIndex.PublishedEntry, label: String
  ) async throws -> Data {
    var data = Data()
    var offset = 0
    while offset < entry.byteCount {
      let chunk = try await requestObject(
        method: "artifact.read",
        params: [
          "jobId": .string(jobID),
          "artifactId": .string(entry.artifactID),
          "offset": .integer(Int64(offset)),
          "maxBytes": .integer(Int64(Self.artifactChunkBytes)),
          "allowSensitive": .bool(true),
        ], label: label)
      guard let base64 = chunk["base64"] as? String, let part = Data(base64Encoded: base64)
      else { throw DeviceFailure(message: "\(label): a chunk was not readable") }
      data.append(part)
      guard let next = chunk["nextOffset"] as? Int, next > offset else { break }
      offset = next
      if chunk["eof"] as? Bool == true { break }
    }
    guard data.count == entry.byteCount else {
      throw DeviceFailure(
        message: "\(label) is \(data.count) bytes but the runtime published \(entry.byteCount)")
    }
    guard DeviceScreenshotIntegrity.sha256Hex(data) == entry.sha256.lowercased() else {
      throw DeviceFailure(message: "\(label) did not match its published digest")
    }
    return data
  }

  private func readScreenshot(jobID: String) async throws -> (
    data: Data, width: Int, height: Int
  ) {
    let label = "Device artifacts"
    let entries = try DeviceArtifactIndex.entries(
      inEnvelope: try await requestEnvelope(
        method: "artifact.list", params: ["jobId": .string(jobID)], label: label),
      label: label)
    guard let entry = DeviceArtifactIndex.screenshot(in: entries) else {
      throw DeviceFailure(message: "the capture published no verified screenshot")
    }
    let artifactID = entry.artifactID
    let expectedSHA = entry.sha256
    let byteCount = entry.byteCount
    var data = Data()
    var offset = 0
    while offset < byteCount {
      let chunk = try await requestObject(
        method: "artifact.read",
        params: [
          // The runtime scopes every artifact read to the job that published
          // it, so the job id travels with the artifact id on every chunk.
          "jobId": .string(jobID),
          "artifactId": .string(artifactID),
          "offset": .integer(Int64(offset)),
          "maxBytes": .integer(Int64(Self.artifactChunkBytes)),
          "allowSensitive": .bool(true),
        ], label: "Device screenshot read")
      guard let base64 = chunk["base64"] as? String, let part = Data(base64Encoded: base64)
      else {
        throw DeviceFailure(message: "the screenshot chunk was not readable")
      }
      data.append(part)
      guard let next = chunk["nextOffset"] as? Int, next > offset else { break }
      offset = next
      if chunk["eof"] as? Bool == true { break }
    }
    guard data.count == byteCount else {
      throw DeviceFailure(
        message: "the screenshot is \(data.count) bytes but the runtime published \(byteCount)")
    }
    guard DeviceScreenshotIntegrity.sha256Hex(data) == expectedSHA.lowercased() else {
      throw DeviceFailure(message: "the screenshot did not match its published digest")
    }
    guard let size = DeviceScreenshotIntegrity.pixelSize(data) else {
      throw DeviceFailure(message: "the screenshot is not a readable picture")
    }
    return (data, size.width, size.height)
  }

  /// The raw reply bytes. Parsing lives in `DeviceArtifactIndex` so a test
  /// can drive it with what the daemon actually sends.
  private func requestEnvelope(
    method: String, params: [String: JSONValue], label: String
  ) async throws -> Data {
    switch await RuntimeXPCRequestTransport.request(method: method, params: params) {
    case .failure(let error):
      throw DeviceFailure(message: "\(label) failed: \(error.message)")
    case .success(let data):
      return data
    }
  }

  private func requestObject(
    method: String, params: [String: JSONValue], label: String
  ) async throws -> [String: Any] {
    switch await RuntimeXPCRequestTransport.request(method: method, params: params) {
    case .failure(let error):
      throw DeviceFailure(message: "\(label) failed: \(error.message)")
    case .success(let data):
      guard
        let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        throw DeviceFailure(message: "\(label) returned an unreadable response")
      }
      if let error = envelope["error"] as? [String: Any] {
        let message = error["message"] as? String ?? "\(error)"
        throw DeviceFailure(message: "\(label) was refused: \(message)")
      }
      guard let result = envelope["result"] as? [String: Any] else {
        throw DeviceFailure(message: "\(label) returned no result")
      }
      return result
    }
  }
}

/// Screenshot checks that do not need an image framework, so they can run in
/// tests and on the actor without pulling AppKit into the workflow layer.
public enum DeviceScreenshotIntegrity {
  public static func sha256Hex(_ data: Data) -> String {
    RuntimeJobRecord.sha256Hex(data)
  }

  /// PNG dimensions come from the IHDR header, which is fixed-position: an
  /// 8-byte signature, then a length and the `IHDR` tag, then width and height
  /// as big-endian 32-bit values. Reading them here means the frame the
  /// workspace maps against is the picture's own, not a number supplied
  /// alongside it.
  /// The picture's own dimensions, whichever encoding it is in.
  ///
  /// Read from the bytes rather than taken from the request, because the
  /// gesture mapping is only as right as this number: a frame mapped against
  /// a size it does not have lands every press somewhere else.
  public static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
    pngPixelSize(data) ?? jpegPixelSize(data)
  }

  /// JPEG carries its size in a start-of-frame segment, which is not at a
  /// fixed offset: the markers before it vary with the encoder. So the
  /// segments are walked rather than indexed.
  ///
  /// SOF0-SOF3 are the baseline and progressive frames. C4, C8 and CC share
  /// the range and are not frames (Huffman table, JPG extension, arithmetic
  /// table), which is why they are excluded rather than the range taken whole.
  public static func jpegPixelSize(_ data: Data) -> (width: Int, height: Int)? {
    let bytes = [UInt8](data)
    guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
    var index = 2
    while index + 9 < bytes.count {
      guard bytes[index] == 0xFF else { return nil }
      let marker = bytes[index + 1]
      // Padding fill bytes between segments are legal.
      if marker == 0xFF { index += 1; continue }
      // Standalone markers carry no length.
      if marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD9) { index += 2; continue }
      let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
      guard length >= 2 else { return nil }
      if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC {
        guard index + 9 < bytes.count else { return nil }
        let height = Int(bytes[index + 5]) << 8 | Int(bytes[index + 6])
        let width = Int(bytes[index + 7]) << 8 | Int(bytes[index + 8])
        guard width > 0, height > 0 else { return nil }
        return (width, height)
      }
      // Entropy-coded data follows the scan header and holds no more sizes.
      if marker == 0xDA { return nil }
      index += 2 + length
    }
    return nil
  }

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
/// How the workspace reads the runtime's artifact index.
///
/// Split out from the transport so a test can drive it with the daemon's own
/// reply bytes. Both halves of this were wrong and neither was caught: the
/// runtime answers `artifact.list` with a bare array, and the workspace read
/// it as an object; and every chunk of `artifact.read` is scoped to the job
/// that published it, and the workspace sent only the artifact id. Each
/// mistake alone makes every capture fail, which is what the workspace showed
/// on hardware while the runtime job succeeded and the screenshot existed.
public enum DeviceArtifactIndex {
  public struct IndexUnreadable: Error, Equatable { public let message: String }

  public struct PublishedEntry: Sendable, Equatable {
    public let artifactID: String
    public let sha256: String
    public let byteCount: Int
  }

  /// The entries in a control-plane reply to `artifact.list`.
  public static func entries(inEnvelope data: Data, label: String) throws -> [[String: Any]] {
    guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw IndexUnreadable(message: "\(label) returned an unreadable response")
    }
    if let error = envelope["error"] as? [String: Any] {
      let message = error["message"] as? String ?? "\(error)"
      throw IndexUnreadable(message: "\(label) was refused: \(message)")
    }
    guard let result = envelope["result"] as? [[String: Any]] else {
      throw IndexUnreadable(message: "\(label) returned no list")
    }
    return result
  }

  /// One published product, or nothing. A truncated or missing entry is not a
  /// product: the workspace would otherwise draw a partial picture and let
  /// somebody aim at it, or compose a recording out of half an archive.
  public static func published(
    named name: String, in entries: [[String: Any]]
  ) -> PublishedEntry? {
    guard
      let entry = entries.first(where: { $0["name"] as? String == name }),
      let artifactID = entry["artifactId"] as? String,
      entry["status"] as? String == "published",
      let sha256 = entry["sha256"] as? String,
      let byteCount = entry["byteCount"] as? Int
    else { return nil }
    return PublishedEntry(artifactID: artifactID, sha256: sha256, byteCount: byteCount)
  }

  /// The published still, whichever encoding was asked for. Looking only for
  /// the PNG name would leave a JPEG capture reporting that it published
  /// nothing - which is how the workspace showed "capture failed" for every
  /// screenshot it ever took, from a different mismatch on this same path.
  public static func screenshot(in entries: [[String: Any]]) -> PublishedEntry? {
    published(named: "screenshot.jpeg", in: entries)
      ?? published(named: "screenshot.png", in: entries)
  }
}

public enum DeviceProductionProviderTestHook {
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

import Foundation
import os

/// What one Viewer capture cost, stage by stage.
///
/// Recorded from the capture that actually ran, not from a benchmark: the
/// expensive parts of this pipeline are a device round trip and a chunked XPC
/// read, and neither can be simulated honestly. The same numbers are emitted
/// as signpost intervals, so Instruments can profile a capture without the App
/// having to display anything.
public struct ViewerCaptureMetrics: Sendable, Equatable {
  /// `job.submit` — encoding the typed request and having Runtime accept it.
  public let submitMilliseconds: Double
  /// `job.run` through terminal facts. This contains the device work.
  public let runMilliseconds: Double
  /// `artifact.list` plus the metadata checks over the returned entries.
  public let listMilliseconds: Double
  /// Every bounded `artifact.read` chunk, including SHA-256 verification.
  public let readMilliseconds: Double
  public let readBytes: Int
  /// Decoding the tree and raw dump into nodes and building the lookup index.
  public let parseMilliseconds: Double
  public let nodeCount: Int

  public init(
    submitMilliseconds: Double, runMilliseconds: Double, listMilliseconds: Double,
    readMilliseconds: Double, readBytes: Int, parseMilliseconds: Double, nodeCount: Int
  ) {
    self.submitMilliseconds = submitMilliseconds
    self.runMilliseconds = runMilliseconds
    self.listMilliseconds = listMilliseconds
    self.readMilliseconds = readMilliseconds
    self.readBytes = readBytes
    self.parseMilliseconds = parseMilliseconds
    self.nodeCount = nodeCount
  }

  public var totalMilliseconds: Double {
    submitMilliseconds + runMilliseconds + listMilliseconds + readMilliseconds
      + parseMilliseconds
  }

  /// `nil` rather than a divide-by-zero or a fabricated 0: an unmeasured read
  /// and an infinitely fast one are not the same fact.
  public var readMegabytesPerSecond: Double? {
    guard readMilliseconds > 0, readBytes > 0 else { return nil }
    return Double(readBytes) / 1_048_576 / (readMilliseconds / 1000)
  }
}

/// Signpost intervals for the capture pipeline, and the stopwatch the metrics
/// are built from.
public enum ViewerSignpost {
  public static let signposter = OSSignposter(
    subsystem: "com.arkdeck.desktop", category: "Viewer")

  /// Times `body`, emits it as a signpost interval, and returns both the value
  /// and the elapsed milliseconds. A throwing body still closes its interval.
  /// Inherits the caller isolation instead of taking a sending closure: the
  /// body reads the facade own state, so moving it to another domain
  /// would be both wrong and unnecessary.
  public static func measure<T>(
    _ name: StaticString,
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> T
  ) async rethrows -> (value: T, milliseconds: Double) {
    let state = signposter.beginInterval(name)
    let start = DispatchTime.now().uptimeNanoseconds
    defer { signposter.endInterval(name, state) }
    let value = try await body()
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    return (value, elapsed)
  }

  public static func measureSync<T>(
    _ name: StaticString, _ body: () throws -> T
  ) rethrows -> (value: T, milliseconds: Double) {
    let state = signposter.beginInterval(name)
    let start = DispatchTime.now().uptimeNanoseconds
    defer { signposter.endInterval(name, state) }
    let value = try body()
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    return (value, elapsed)
  }
}

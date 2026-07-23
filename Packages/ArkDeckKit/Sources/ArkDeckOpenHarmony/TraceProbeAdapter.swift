import CryptoKit
import Foundation

/// The complete integration-profile binding adopted by TASK-TR-003. These values may change
/// only with a reviewed trace integration change and matching golden-resource closure.
public enum TraceProbeAdapterProfile {
  public static let integrationProfile = "OPENHARMONY-TOOLS@0.4.0"
  public static let registryID = "OPENHARMONY-TRACE-PROBES"
  public static let registryVersion = "1.0.0"
  public static let registrySHA256 =
    "9d2a390b84092f1d78d86c10bf182884bc3a2ef8b3cdc3d35ed8e7e2b087b613"
  public static let resourceManifestSHA256 =
    "6b77b020b50921ef419720a434a186aba48c13e7284fa66598d4efd0c4f14879"

  public static let hitraceHelpResourceSHA256 =
    "9ab0718d7da1d5beb459c74548f89cc69775a931be7931686637d6e584d70e39"
  public static let bytraceHelpResourceSHA256 =
    "690ca26bbe14d6edd8ad163cce18c1f1a494e4984e8d86f1866f32b7f8bb94fd"
  public static let rawFtraceHeaderResourceSHA256 =
    "4b6433a1845d533dd466aeb3db965e273f4d4db582c94fe67cf1cb6e1a625ae0"

  public static let hitraceHelpFamily = "hitrace.dayu200-oh7.text-v1"
  public static let bytraceHelpFamily = "bytrace.dayu200-oh7.text-v1"

  static let helpResourceByteCount = 3_382
  static let rawFtraceHeaderByteCount = 601

  // The registry permits ignoring only the leading `YYYY/MM/DD HH:MM:SS ` bytes on the
  // registered help enter line. The digest covers every remaining byte, including all markers.
  static let hitraceHelpTimestampNormalizedSuffixSHA256 =
    "b40edec78a823762d64599b21c4fd2c82be4a9071e0457120a6e6526433ed3f8"
  static let bytraceHelpTimestampNormalizedSuffixSHA256 =
    "e11541d1b671170d16c300d01dcbb5f50301e9e2533622f1e91b257a8561548e"
}

public enum TraceProbeTool: String, Equatable, Sendable {
  case hitrace
  case bytrace
}

public enum TraceProbeAdapterSelection: Equatable, Sendable {
  case captureEligible(tool: TraceProbeTool, family: String)
  case probeOnlyNotCaptureEligible(tool: TraceProbeTool, family: String)
  case unsupported
}

/// Raw help is retained for diagnostics even when its family is unknown or drifted.
public struct TraceProbeHelpEvaluation: Equatable, Sendable {
  public let selection: TraceProbeAdapterSelection
  public let rawHelp: Data
  public let rawStderr: Data
  public let rawHelpSHA256: String

  fileprivate init(
    selection: TraceProbeAdapterSelection,
    rawHelp: Data,
    rawStderr: Data
  ) {
    self.selection = selection
    self.rawHelp = rawHelp
    self.rawStderr = rawStderr
    rawHelpSHA256 = TraceProbeAdapter.sha256(rawHelp)
  }
}

public enum TraceProbeAdapter {
  /// Evaluates only a registered byte family. Tool name, firmware, process exit status, and
  /// marker fragments are intentionally insufficient to create selection authority.
  public static func evaluateHelp(
    tool: TraceProbeTool,
    stdout: Data,
    stderr: Data = Data()
  ) -> TraceProbeHelpEvaluation {
    guard stderr.isEmpty,
      stdout.count == TraceProbeAdapterProfile.helpResourceByteCount,
      let suffix = timestampNormalizedSuffix(stdout)
    else {
      return TraceProbeHelpEvaluation(
        selection: .unsupported,
        rawHelp: stdout,
        rawStderr: stderr)
    }

    let suffixSHA256 = sha256(suffix)
    let selection: TraceProbeAdapterSelection
    switch tool {
    case .hitrace:
      selection =
        suffixSHA256 == TraceProbeAdapterProfile.hitraceHelpTimestampNormalizedSuffixSHA256
        ? .captureEligible(
          tool: .hitrace,
          family: TraceProbeAdapterProfile.hitraceHelpFamily)
        : .unsupported
    case .bytrace:
      selection =
        suffixSHA256 == TraceProbeAdapterProfile.bytraceHelpTimestampNormalizedSuffixSHA256
        ? .probeOnlyNotCaptureEligible(
          tool: .bytrace,
          family: TraceProbeAdapterProfile.bytraceHelpFamily)
        : .unsupported
    }
    return TraceProbeHelpEvaluation(
      selection: selection,
      rawHelp: stdout,
      rawStderr: stderr)
  }

  fileprivate static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func timestampNormalizedSuffix(_ bytes: Data) -> Data? {
    // `YYYY/MM/DD HH:MM:SS ` is exactly 20 ASCII bytes. Calendar ranges are checked so an
    // arbitrary 19-byte prefix cannot borrow the registry's normalization permission.
    guard bytes.count >= 20 else { return nil }
    let prefix = Array(bytes.prefix(20))
    let digitPositions: Set<Int> = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]
    for (index, byte) in prefix.enumerated() where digitPositions.contains(index) {
      guard (48...57).contains(byte) else { return nil }
    }
    guard prefix[4] == 47, prefix[7] == 47, prefix[10] == 32,
      prefix[13] == 58, prefix[16] == 58, prefix[19] == 32
    else { return nil }

    func twoDigits(_ first: Int) -> Int {
      Int(prefix[first] - 48) * 10 + Int(prefix[first + 1] - 48)
    }
    guard (1...12).contains(twoDigits(5)),
      (1...31).contains(twoDigits(8)),
      (0...23).contains(twoDigits(11)),
      (0...59).contains(twoDigits(14)),
      (0...59).contains(twoDigits(17))
    else { return nil }
    return Data(bytes.dropFirst(20))
  }
}

public struct TraceRawArtifactSnapshot: Equatable, Sendable {
  public let bytes: Data
  public let sha256: String

  fileprivate init(bytes: Data) {
    self.bytes = bytes
    sha256 = TraceProbeAdapter.sha256(bytes)
  }
}

public struct TraceFtraceFilterOptions: Equatable, Sendable {
  public let removeCreateFileAssetLines: Bool

  public init(removeCreateFileAssetLines: Bool = false) {
    self.removeCreateFileAssetLines = removeCreateFileAssetLines
  }
}

public struct TraceDerivedFtraceArtifact: Equatable, Sendable {
  public let bytes: Data
  public let sha256: String
  public let removedLineCount: Int
  public let removedByteCount: Int

  fileprivate init(bytes: Data, removedLineCount: Int, removedByteCount: Int) {
    self.bytes = bytes
    sha256 = TraceProbeAdapter.sha256(bytes)
    self.removedLineCount = removedLineCount
    self.removedByteCount = removedByteCount
  }
}

public enum TraceFtraceFilterDisposition: Equatable, Sendable {
  case derived(TraceDerivedFtraceArtifact)
  case unsupportedHeader
}

public struct TraceFtraceFilterEvaluation: Equatable, Sendable {
  public let raw: TraceRawArtifactSnapshot
  public let disposition: TraceFtraceFilterDisposition

  fileprivate init(raw: TraceRawArtifactSnapshot, disposition: TraceFtraceFilterDisposition) {
    self.raw = raw
    self.disposition = disposition
  }
}

public enum TraceFtracePostprocessor {
  private static let createFileAssetToken = Data("CreateFileAsset".utf8)

  /// Creates derived bytes only for the registered ftrace header. Header bytes are copied as one
  /// immutable prefix and are never exposed to line filtering; no fixed-line deletion exists.
  public static func evaluate(
    rawBytes: Data,
    options: TraceFtraceFilterOptions = TraceFtraceFilterOptions()
  ) -> TraceFtraceFilterEvaluation {
    let raw = TraceRawArtifactSnapshot(bytes: rawBytes)
    let headerByteCount = TraceProbeAdapterProfile.rawFtraceHeaderByteCount
    guard rawBytes.count >= headerByteCount,
      TraceProbeAdapter.sha256(Data(rawBytes.prefix(headerByteCount)))
        == TraceProbeAdapterProfile.rawFtraceHeaderResourceSHA256
    else {
      return TraceFtraceFilterEvaluation(raw: raw, disposition: .unsupportedHeader)
    }

    let bodyStart = rawBytes.index(rawBytes.startIndex, offsetBy: headerByteCount)
    var derived = Data(rawBytes[..<bodyStart])
    var removedLineCount = 0
    var removedByteCount = 0
    var lineStart = bodyStart

    for index in rawBytes.indices.dropFirst(headerByteCount) where rawBytes[index] == 10 {
      let lineEnd = rawBytes.index(after: index)
      let line = Data(rawBytes[lineStart..<lineEnd])
      if options.removeCreateFileAssetLines && isConfirmedCreateFileAssetChatter(line) {
        removedLineCount += 1
        removedByteCount += line.count
      } else {
        derived.append(line)
      }
      lineStart = lineEnd
    }
    if lineStart < rawBytes.endIndex {
      let line = Data(rawBytes[lineStart..<rawBytes.endIndex])
      if options.removeCreateFileAssetLines && isConfirmedCreateFileAssetChatter(line) {
        removedLineCount += 1
        removedByteCount += line.count
      } else {
        derived.append(line)
      }
    }

    return TraceFtraceFilterEvaluation(
      raw: raw,
      disposition: .derived(
        TraceDerivedFtraceArtifact(
          bytes: derived,
          removedLineCount: removedLineCount,
          removedByteCount: removedByteCount)))
  }

  private static func isConfirmedCreateFileAssetChatter(_ line: Data) -> Bool {
    let trimmed = line.drop(while: { $0 == 32 || $0 == 9 || $0 == 13 })
    guard trimmed.first != 35, let range = line.range(of: createFileAssetToken) else {
      return false
    }

    // Treat the registered spelling as a token, never as an arbitrary substring in another
    // identifier. This is the only removable family in this adapter revision.
    let beforeIsBoundary =
      range.lowerBound == line.startIndex
      || !isIdentifierByte(line[line.index(before: range.lowerBound)])
    let afterIsBoundary =
      range.upperBound == line.endIndex || !isIdentifierByte(line[range.upperBound])
    return beforeIsBoundary && afterIsBoundary
  }

  private static func isIdentifierByte(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
      || byte == 95
  }
}

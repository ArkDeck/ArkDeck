import ArkDeckCore
import Foundation

package enum HilogSummaryDerivedAnalyzer {
  package static let analyzerRef = HilogSummaryArtifactContract.analyzerRef
  package static let analyzerVersion = HilogSummaryArtifactContract.analyzerVersion
  package static let maximumInputBytes = HilogSummaryArtifactContract.maximumInputBytes
  package static let maximumOutputBytes = HilogSummaryArtifactContract.maximumOutputBytes
  package static let incompatibleExecutableReason = "analyzer.hilogRequiresCurrentDaemon"

  /// The configured tool must contain this build's closed one-shot mode. A
  /// crash-only executable from an older installation is not a HiLog producer.
  /// The caller obtains both identities from the existing executable resolver;
  /// neither a Runtime request nor an Artifact may provide these pins.
  package static func profile(
    executable: ResolvedExecutable, currentDaemon: ResolvedExecutable
  ) -> AnalyzerProfile? {
    guard executable.sha256 == currentDaemon.sha256 else { return nil }
    return AnalyzerProfile(
      analyzerRef: analyzerRef, analyzerVersion: analyzerVersion,
      executablePath: executable.path, executableSHA256: executable.sha256,
      fixedArguments: ["--summarize-hilog"], timeoutSeconds: 120,
      outputByteBudget: maximumOutputBytes)
  }

  /// Reuses the provider's bounded, regular-file, no-symlink reader. A failed
  /// read produces no JSON, and the entry point emits only a fixed error code.
  package static func analyzeFile(at path: String) throws -> Data {
    let snapshot = try ArkTraceProfileFileReader.read(
      path: path, maximumByteCount: maximumInputBytes, allowKernelInodeAlias: true)
    return try analyze(snapshot.data)
  }

  package static func analyze(_ bytes: Data) throws -> Data {
    guard bytes.count <= maximumInputBytes else {
      throw DeviceProviderError.unsupportedAction("analyzer.hilogInputLimitExceeded")
    }
    // OpenHarmony's default time header, with either the older hex domain or
    // the current type-prefixed domain. Other formats and unprefixed wrapped
    // lines are counted explicitly as unrecognized; no severity is guessed.
    // Only a bounded header prefix is retained, even for a very long body.
    let header = try NSRegularExpression(
      pattern:
        #"^(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])[ \t]+(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]\.[0-9]{3}(?:[0-9]{3}){0,2}[ \t]+[0-9]{1,10}[ \t]+[0-9]{1,10}[ \t]+([DIWEF])[ \t]+[A-Z]?[0-9A-Fa-f]{5,8}/[^\x00-\x1F\x7F]{1,31}:(?:[ \t]|$)"#
    )
    var prefix: [UInt8] = []
    prefix.reserveCapacity(256)
    var lineHasBytes = false
    var lineIsBlank = true
    var lines = 0
    var blanks = 0
    var unknown = 0
    var levels = Dictionary(uniqueKeysWithValues: ["D", "I", "W", "E", "F"].map { ($0, 0) })

    func finishLine() {
      lines += 1
      if lineIsBlank {
        blanks += 1
      } else {
        if prefix.last == 13 { prefix.removeLast() }
        let text = String(decoding: prefix, as: UTF8.self)
        if let match = header.firstMatch(
          in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text)
        {
          levels[String(text[range]), default: 0] += 1
        } else {
          unknown += 1
        }
      }
      prefix.removeAll(keepingCapacity: true)
      lineHasBytes = false
      lineIsBlank = true
    }
    for byte in bytes {
      if byte == 10 {
        finishLine()
      } else {
        lineHasBytes = true
        if byte != 9 && byte != 13 && byte != 32 { lineIsBlank = false }
        if prefix.count < 256 { prefix.append(byte) }
      }
    }
    if lineHasBytes { finishLine() }
    let coverage = HilogSummaryArtifactContract.coverage(lines: lines, blanks: blanks, unknown: unknown)
    return try HilogSummaryAnalysis(
      schemaVersion: "1.0.0", analyzerRef: analyzerRef, analyzerVersion: analyzerVersion,
      scope: "default-hilog-header-lines", redaction: "content-and-identifiers-omitted",
      sourceSHA256: AnalyzerProvider.sha256(bytes), sourceByteCount: bytes.count,
      headerCoverage: coverage, lineCount: lines, blankLineCount: blanks,
      unrecognizedLineCount: unknown, levelCounts: levels
    ).canonicalData()
  }

  /// Accept only the producer's canonical, closed document. Re-encoding also
  /// rejects unknown/duplicate fields instead of allowing raw log text to hide
  /// in a supposedly standard-privacy Artifact. Source identity is checked
  /// again here, across the materialization -> subprocess read boundary.
  package static func validate(_ bytes: Data, invocation: AnalyzerInvocation) -> Bool {
    guard invocation.analyzerRef == analyzerRef, invocation.analyzerVersion == analyzerVersion else {
      return false
    }
    return validateReport(
      bytes, sourceSHA256: invocation.sourceSHA256, sourceByteCount: invocation.sourceByteCount)
  }

  /// The same closed artifact contract is used by the read-only client.
  package static func validateReport(
    _ bytes: Data, sourceSHA256: String, sourceByteCount: Int
  ) -> Bool {
    HilogSummaryArtifactContract.validateReport(
      bytes, sourceSHA256: sourceSHA256, sourceByteCount: sourceByteCount)
  }
}

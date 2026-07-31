// Observed state from real bytes (CHG-2026-054, TASK-HTP-002).
//
// Every measurement here comes from bytes the harness read and hashed. The
// order is deliberate: verify first, measure second. An artifact that is
// absent, empty, larger than the evaluation read bound, or whose SHA-256
// does not match what the store recorded produces a *blocker*, never a
// measurement - so "we could not read the evidence" can never look like
// "the evidence says it is fixed" (CHG-2026-049's lesson, where a failed
// capture still published a complete-looking downstream artifact).
//
// Integrity blockers (hash mismatch, unreadable) and collection blockers
// (absent, empty, oversize) are kept apart because they escalate
// differently: the first is an ERROR that needs a human, the second is
// INCONCLUSIVE that another round may fix.
//
// The crash scan is pattern-based over hilog text and is documented as
// such. It is written against the documented OpenHarmony cppcrash shape
// (`Reason:Signal:SIG...`, `Fault thread info:`, `#NN pc ... (symbol+off)`)
// and exercised by fixtures of that shape; validating it against bytes a
// real device produced belongs to the hardware task, which is why the
// run record does not claim device coverage for it.

import ArkDeckCore
import CryptoKit
import Foundation

public struct HarnessCrashSignature: Equatable, Sendable {
  public let signal: String
  public let topFrame: String?
  public let blockText: String

  public var rendered: String {
    guard let topFrame else { return signal }
    return "\(signal)+\(topFrame)"
  }
}

public struct HarnessObservationBuilder: Sendable {
  /// Read bound per artifact. Bigger evidence is not silently truncated: it
  /// becomes a blocker, because a hash over a prefix proves nothing.
  public static let defaultEvaluationReadBytes = 1 << 20

  private let artifacts: any HarnessArtifactPort
  private let maximumEvaluationBytes: Int

  public init(
    artifacts: any HarnessArtifactPort,
    maximumEvaluationBytes: Int = HarnessObservationBuilder.defaultEvaluationReadBytes
  ) {
    self.artifacts = artifacts
    self.maximumEvaluationBytes = maximumEvaluationBytes
  }

  public func observe(
    round: Int,
    jobID: String,
    declaredCrashSignature: String?,
    requiredEvidence: Set<String>
  ) async throws -> HarnessRoundObservation {
    let inventory: [HarnessArtifactDescriptor]
    do {
      inventory = try await artifacts.inventory(jobID: jobID)
    } catch {
      return HarnessRoundObservation(
        round: round, collectionBlockers: ["artifactInventoryUnavailable:\(jobID)"])
    }

    var evidence: [HarnessEvidenceRecord] = []
    var integrityBlockers: [String] = []
    var collectionBlockers: [String] = []
    var verifiedBytes: [(name: String, mediaType: String, data: Data)] = []

    for descriptor in inventory {
      if !descriptor.published {
        let blocker = "artifactMissing:\(descriptor.name):\(descriptor.missingReason ?? "unknown")"
        collectionBlockers.append(blocker)
        evidence.append(record(descriptor, verified: false, blocker: blocker))
        continue
      }
      if descriptor.sensitive {
        // Reading it would need an explicit opt-in the harness does not
        // have; report it rather than pretend the evidence was considered.
        let blocker = "artifactSensitiveNotOptedIn:\(descriptor.name)"
        collectionBlockers.append(blocker)
        evidence.append(record(descriptor, verified: false, blocker: blocker))
        continue
      }
      if descriptor.byteCount == 0 {
        let blocker = "artifactEmpty:\(descriptor.name)"
        collectionBlockers.append(blocker)
        evidence.append(record(descriptor, verified: false, blocker: blocker))
        continue
      }
      if descriptor.byteCount > maximumEvaluationBytes {
        let blocker =
          "artifactExceedsEvaluationBound:\(descriptor.name):"
          + "\(descriptor.byteCount)>\(maximumEvaluationBytes)"
        collectionBlockers.append(blocker)
        evidence.append(record(descriptor, verified: false, blocker: blocker))
        continue
      }
      let data: Data
      do {
        data = try await artifacts.read(
          jobID: jobID, artifactID: descriptor.artifactID,
          maximumBytes: maximumEvaluationBytes)
      } catch {
        let blocker = "artifactUnreadable:\(descriptor.name)"
        integrityBlockers.append(blocker)
        evidence.append(record(descriptor, verified: false, blocker: blocker))
        continue
      }
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      guard data.count == descriptor.byteCount, digest == descriptor.sha256 else {
        let blocker = "artifactHashMismatch:\(descriptor.name)"
        integrityBlockers.append(blocker)
        evidence.append(record(descriptor, verified: false, blocker: blocker))
        continue
      }
      evidence.append(record(descriptor, verified: true, blocker: nil))
      verifiedBytes.append((descriptor.name, descriptor.mediaType, data))
    }

    let inventoryNames = Set(inventory.map(\.name))
    for required in requiredEvidence.subtracting(inventoryNames).sorted() {
      collectionBlockers.append("artifactNotCollected:\(required)")
    }

    let (measurements, samples) = measure(
      verifiedBytes, declaredCrashSignature: declaredCrashSignature)
    return HarnessRoundObservation(
      round: round,
      measurements: measurements,
      sampleContribution: samples,
      evidence: evidence,
      integrityBlockers: integrityBlockers,
      collectionBlockers: collectionBlockers)
  }

  private func record(
    _ descriptor: HarnessArtifactDescriptor,
    verified: Bool,
    blocker: String?
  ) -> HarnessEvidenceRecord {
    HarnessEvidenceRecord(
      artifactID: descriptor.artifactID, name: descriptor.name,
      byteCount: descriptor.byteCount, sha256: descriptor.sha256, verified: verified,
      blocker: blocker)
  }

  // MARK: - Measurement

  private func measure(
    _ verified: [(name: String, mediaType: String, data: Data)],
    declaredCrashSignature: String?
  ) -> ([String: JSONValue], [String: Int]) {
    let logs = verified.filter { $0.name.lowercased().contains("hilog") }
    guard !logs.isEmpty else { return ([:], [:]) }

    var matching = 0
    var others = 0
    var latestSignature: String?
    var sawApplicationOutput = false

    for log in logs {
      guard let text = String(data: log.data, encoding: .utf8) else {
        // Not decodable as text: measured as nothing rather than as zero
        // crashes. Zero would be a claim; nothing is the truth.
        continue
      }
      sawApplicationOutput = sawApplicationOutput || Self.hasApplicationOutput(text)
      for signature in Self.crashSignatures(in: text) {
        latestSignature = signature.rendered
        if let declaredCrashSignature,
          Self.matches(declared: declaredCrashSignature, signature: signature)
        {
          matching += 1
        } else {
          others += 1
        }
      }
    }

    var measurements: [String: JSONValue] = [
      "matchingCrashCount": .integer(Int64(matching)),
      "newFatalSignatureCount": .integer(Int64(others)),
      "verificationRunCount": .integer(1),
    ]
    var samples: [String: Int] = [
      "matchingCrashCount": 1,
      "newFatalSignatureCount": 1,
      "verificationRunCount": 1,
    ]
    if let latestSignature {
      measurements["latestCrashSignature"] = .string(latestSignature)
      samples["latestCrashSignature"] = 1
    }
    // Liveness is only asserted when the log actually shows the application
    // running or crashing. A log with neither leaves the metric unobserved,
    // which the evaluator reads as inconclusive.
    if matching + others > 0 {
      measurements["applicationLiveness"] = .string("unhealthy")
      samples["applicationLiveness"] = 1
    } else if sawApplicationOutput {
      measurements["applicationLiveness"] = .string("healthy")
      samples["applicationLiveness"] = 1
    }
    return (measurements, samples)
  }

  /// Fault blocks in a hilog capture. A block starts at a fatal reason line
  /// and continues through the frame list, which is what makes "the declared
  /// tokens appear in this crash" a checkable statement.
  public static func crashSignatures(in text: String) -> [HarnessCrashSignature] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var signatures: [HarnessCrashSignature] = []
    var index = 0
    while index < lines.count {
      guard let signal = fatalSignal(in: lines[index]) else {
        index += 1
        continue
      }
      var block = [lines[index]]
      var cursor = index + 1
      var topFrame: String?
      while cursor < lines.count, fatalSignal(in: lines[cursor]) == nil {
        block.append(lines[cursor])
        if topFrame == nil, let frame = frameSymbol(in: lines[cursor]) {
          topFrame = frame
        }
        cursor += 1
      }
      signatures.append(
        HarnessCrashSignature(
          signal: signal, topFrame: topFrame, blockText: block.joined(separator: "\n")))
      index = cursor
    }
    return signatures
  }

  private static let fatalSignals = [
    "SIGABRT", "SIGSEGV", "SIGILL", "SIGBUS", "SIGFPE", "SIGTRAP", "SIGSYS",
  ]

  private static func fatalSignal(in line: String) -> String? {
    let upper = line.uppercased()
    guard upper.contains("REASON:") || upper.contains("SIGNAL:") || upper.contains("CPPCRASH")
    else { return nil }
    return fatalSignals.first { upper.contains($0) }
  }

  /// `#01 pc 000000000000abcd /system/lib64/libace.z.so(Symbol::Method()+72)`
  /// -> `Symbol::Method()`. System allocator/abort frames are skipped so the
  /// first *meaningful* frame is what names the crash.
  private static func frameSymbol(in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.contains("#"), trimmed.contains(" pc ") else { return nil }
    guard let open = trimmed.lastIndex(of: "("), let close = trimmed[open...].firstIndex(of: ")")
    else { return nil }
    var symbol = String(trimmed[trimmed.index(after: open)..<close])
    if let plus = symbol.lastIndex(of: "+") {
      symbol = String(symbol[..<plus])
    }
    symbol = symbol.trimmingCharacters(in: .whitespaces)
    guard !symbol.isEmpty else { return nil }
    let noise = ["abort", "raise", "pthread_kill", "__pthread_kill", "tgkill", "musl_abort"]
    if noise.contains(where: { symbol.hasPrefix($0) }) { return nil }
    return symbol
  }

  /// Token containment, not equality: a declared signature such as
  /// `SIGABRT+WaterFlowPattern::RecoverBack` matches a fault block that
  /// mentions every one of its `+`-separated tokens. Equality on a formatted
  /// signature string would break on any frame-offset or library-path
  /// difference between runs.
  public static func matches(declared: String, signature: HarnessCrashSignature) -> Bool {
    let haystack = (signature.rendered + "\n" + signature.blockText).lowercased()
    let tokens = declared.split(separator: "+").map {
      $0.trimmingCharacters(in: .whitespaces).lowercased()
    }.filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return false }
    return tokens.allSatisfy { haystack.contains($0) }
  }

  private static func hasApplicationOutput(_ text: String) -> Bool {
    // Any hilog line at all counts as "the application produced output":
    // the capture is app-scoped by the operation that collected it, so a
    // non-empty log without a fault block is a live application.
    text.split(separator: "\n").contains { line in
      !line.trimmingCharacters(in: .whitespaces).isEmpty
    }
  }
}

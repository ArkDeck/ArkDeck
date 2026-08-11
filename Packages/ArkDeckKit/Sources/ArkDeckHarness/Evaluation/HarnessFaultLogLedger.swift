// The device's crash ledger, read as bytes (CHG-2026-055, TASK-HFA-001).
//
// TASK-HTP-002 judged crashes by scanning `hilog.txt` for cppcrash fault
// blocks. TASK-HTP-006's r6 window disproved that on a real DAYU200: after
// a real crash at the same catalog digest, 887 KB of `hilog -x` carried
// zero `Reason:` / `Error message:` / `Stacktrace:` lines. The judging
// logic was fine; the source was wrong. The detail lives in Faultlogger,
// which `capture.diagnostics@1` now publishes as `crash-index.txt` (the
// ledger listing) and `crash-log.txt` (one entry's body).
//
// Two properties of that source shape everything here.
//
// It is *cumulative device state*, not a capture window. `hilog -x` returns
// the last N seconds; the ledger returns every fault the device still
// keeps, including ones that predate the task. Counting it directly would
// re-count history every round and `matchingCrashCount == 0` could never
// pass, so the builder counts only what appeared after a watermark it set
// itself (see `HarnessObservationBuilder`).
//
// And its timestamps are *device-local*: the entry measured on 2026-07-31
// reads `20260731162134` while the host clock said 08:21 UTC. Comparing
// them to a host timestamp needs the device's offset, which nothing here
// knows - so the watermark is always a device timestamp compared against
// device timestamps, never against a host clock.
//
// Formats below were measured on DAYU200 (OpenHarmony 3.2 / Build
// 7.0.0.36) and are recorded in CHG-2026-049's
// `evidence/runs/TASK-DHA-005/faultlogger-format-2026-07-31.md`.

// The wire contract types (`HarnessFaultLogEntry`, `HarnessCrashLedgerAnalysis`,
// `HarnessCrashLedgerDerivedArtifact`) live in
// `ArkDeckRuntime/CrashLedgerAnalysisContracts.swift`: the schema is shared with
// the analyzer provider and the runtime engine, which must not import the
// harness plane. This file keeps the producer — parsing and judging.
import ArkDeckCore
import ArkDeckRuntime
import Foundation

/// Pure deterministic front-end used by the pinned analyzer executable and
/// its contract tests.  Invalid input is a structured `unreadable` result,
/// never an empty ledger: downstream evaluation therefore fails closed.
public enum HarnessCrashLedgerDerivedAnalyzer {
  public static func analyze(_ bytes: Data) throws -> Data {
    let analysis: HarnessCrashLedgerAnalysis
    guard let text = String(data: bytes, encoding: .utf8) else {
      analysis = HarnessCrashLedgerAnalysis(
        status: .unreadable, unreadableReason: "invalidEncoding")
      return try canonicalData(analysis)
    }
    switch HarnessFaultLogLedger.readIndex(text) {
    case .answered(let entries):
      analysis = HarnessCrashLedgerAnalysis(status: .answered, entries: entries)
    case .unreadable(let reason):
      analysis = HarnessCrashLedgerAnalysis(
        status: .unreadable, unreadableReason: reason)
    }
    return try canonicalData(analysis)
  }

  /// The bytes whose digest the runtime records in the derived envelope.
  /// Keeping this encoder shared lets the evaluator recompute that digest
  /// instead of trusting a structured-looking result and a detached hash.
  public static func canonicalData(_ analysis: HarnessCrashLedgerAnalysis) throws -> Data {
    let encoder = CanonicalJSONEncoders.canonical()
    return try encoder.encode(analysis)
  }
}

public enum HarnessFaultLogLedger {
  /// The listing's header. Its presence is what distinguishes "the device
  /// answered and has nothing" from "we never got an answer" - a
  /// distinction the whole fail-closed story rests on, because only the
  /// first may ever support a verdict of "no crash".
  public static let listHeader = "Fault log list:"
  public static let emptyMarker = "No fault log exist."
  private static let entryFence = "******"

  public enum IndexReading: Equatable, Sendable {
    /// The device answered. An empty array means an empty ledger, which is
    /// positive evidence.
    case answered([HarnessFaultLogEntry])
    /// The bytes are not a ledger listing, or carry a name this code cannot
    /// decompose. Never silently an empty ledger: that would turn "we could
    /// not read it" into "there was no crash".
    case unreadable(String)
  }

  public static func readIndex(_ text: String) -> IndexReading {
    guard text.contains(listHeader) else {
      return .unreadable("ledgerHeaderAbsent")
    }
    let lines = text.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard let first = lines.firstIndex(of: entryFence),
      let last = lines.lastIndex(of: entryFence), last > first
    else {
      // Measured empty form prints the marker sentence; some builds print
      // the header with no fence at all. Both mean an empty ledger.
      guard text.contains(emptyMarker) else {
        return .unreadable("ledgerFenceAbsent")
      }
      return .answered([])
    }
    var entries: [HarnessFaultLogEntry] = []
    for line in lines[(first + 1)..<last] where !line.isEmpty {
      guard let entry = parse(entryName: line) else {
        return .unreadable("entryNameUnparseable")
      }
      entries.append(entry)
    }
    return .answered(entries)
  }

  /// Decomposed from the right: the last two `-` fields are the timestamp
  /// and uid, the first is the kind, and whatever is left is the bundle.
  /// Bundle names carry dots and may carry hyphens, so splitting from the
  /// left would cut them in half.
  public static func parse(entryName: String) -> HarnessFaultLogEntry? {
    let fields = entryName.split(separator: "-", omittingEmptySubsequences: false)
    guard fields.count >= 4 else { return nil }
    let timestamp = String(fields[fields.count - 1])
    let uid = String(fields[fields.count - 2])
    let kind = String(fields[0])
    let bundle = fields[1..<(fields.count - 2)].joined(separator: "-")
    guard timestamp.count == 14, timestamp.allSatisfy(\.isNumber),
      !uid.isEmpty, uid.allSatisfy(\.isNumber),
      !kind.isEmpty, kind.allSatisfy({ $0.isLetter }),
      !bundle.isEmpty
    else {
      return nil
    }
    return HarnessFaultLogEntry(
      name: entryName, kind: kind, bundle: bundle, uid: uid, timestamp: timestamp)
  }

  /// The judging fields of one entry body, dispatched on `kind`.
  ///
  /// `cppcrash` reports `Reason:Signal:SIGSEGV(...)` plus a frame list;
  /// `jscrash` reports `Reason:`/`Error name:`/`Error message:` plus an
  /// indented `Stacktrace:`. A kind this code does not know still yields
  /// its `Reason:` - what it must never do is invent a signal, because a
  /// fabricated `SIGABRT` would read downstream as a native crash that
  /// never happened.
  public static func detail(
    inEntryBody body: String,
    kind: String
  ) -> HarnessCrashSignature? {
    guard body.contains("Generated by HiviewDFX") else { return nil }
    let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let reason = value(of: "Reason:", in: lines) else { return nil }

    // The body is echoed back as the block text so a declared signature can
    // be matched against the whole entry, not only against the rendered
    // form. The trailing `HiLog:` section is dropped: it duplicates
    // `hilog.txt` and would let a hilog line satisfy a crash match.
    let block = lines.prefix { !$0.hasPrefix("HiLog:") }.joined(separator: "\n")

    if reason.hasPrefix("Signal:") || kind == "cppcrash" {
      let signal = fatalSignals.first { reason.uppercased().contains($0) } ?? reason
      return HarnessCrashSignature(
        kind: kind, signal: signal, topFrame: nativeTopFrame(lines), blockText: block)
    }
    let name = value(of: "Error name:", in: lines) ?? reason
    return HarnessCrashSignature(
      kind: kind, signal: name, topFrame: scriptTopFrame(lines), blockText: block)
  }

  static let fatalSignals = [
    "SIGABRT", "SIGSEGV", "SIGILL", "SIGBUS", "SIGFPE", "SIGTRAP", "SIGSYS",
  ]

  private static func value(of key: String, in lines: [String]) -> String? {
    for line in lines where line.hasPrefix(key) {
      let text = String(line.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
      if !text.isEmpty { return text }
    }
    return nil
  }

  /// `#01 pc 000000000000abcd /system/lib64/libace.z.so(Symbol::Method()+72)`
  /// -> `Symbol::Method()`.
  private static func nativeTopFrame(_ lines: [String]) -> String? {
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("#"), trimmed.contains(" pc ") else { continue }
      guard let open = trimmed.lastIndex(of: "("),
        let close = trimmed[open...].firstIndex(of: ")")
      else { continue }
      var symbol = String(trimmed[trimmed.index(after: open)..<close])
      if let plus = symbol.lastIndex(of: "+") { symbol = String(symbol[..<plus]) }
      symbol = symbol.trimmingCharacters(in: .whitespaces)
      guard !symbol.isEmpty, !allocatorNoise.contains(where: { symbol.hasPrefix($0) })
      else { continue }
      return symbol
    }
    return nil
  }

  /// `    at anonymous entry (entry/src/main/ets/crashprobe/CrashProbe.ets:36:16)`
  /// -> `entry/src/main/ets/crashprobe/CrashProbe.ets:36:16`. The source
  /// location, not the frame's label: `anonymous entry` names nothing, and
  /// the location is what a declared signature can be written against.
  private static func scriptTopFrame(_ lines: [String]) -> String? {
    guard let start = lines.firstIndex(where: { $0.hasPrefix("Stacktrace:") }) else { return nil }
    for line in lines[(start + 1)...] {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("at ") else { break }
      guard let open = trimmed.lastIndex(of: "("),
        let close = trimmed[open...].firstIndex(of: ")")
      else { continue }
      let location = String(trimmed[trimmed.index(after: open)..<close])
        .trimmingCharacters(in: .whitespaces)
      if !location.isEmpty { return location }
    }
    return nil
  }

  private static let allocatorNoise = [
    "abort", "raise", "pthread_kill", "__pthread_kill", "tgkill", "musl_abort",
  ]
}

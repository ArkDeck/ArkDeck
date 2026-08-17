import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// The server-fact keys the engine reads must be keys a producer writes.
///
/// `dispatchThroughArkForge` read `serverFacts["usbTopology"]`. Nothing writes
/// that key — `TargetStoreRockchipRuntimeFactsPort` publishes the port path as
/// `dayu200HDCNormalAliasUSBTopology` — and `?? ""` turned the miss into an
/// empty string. The ArkForge lane then refused to identify the board, which
/// was the correct behaviour and far too late: by then the job had already put
/// the device in Loader. A spelling mistake surfaced as a board left in the
/// wrong mode, on the first real flash attempt.
///
/// `serverFacts` is `[String: String]`, so nothing in the type system relates
/// the two ends. This does, by comparing the literals the engine subscripts
/// with against the keys the facts port declares.
///
/// Source-level for the same reason as the CLI option guard: the behavioural
/// version needs a live device in a specific mode to reach the read at all,
/// which is what let this survive to the bench.
final class ServerFactKeyAgreementContractTests: XCTestCase {

  private func source(_ relativePath: String) throws -> String {
    let root = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
  }

  /// Every `"..."` a `serverFacts[` subscript is written with.
  ///
  /// Comment lines are dropped first: a key named in prose — including the
  /// note explaining this very bug — is not a read, and counting one would
  /// make the guard unfixable.
  private func literalKeys(in source: String) -> Set<String> {
    let code = source
      .split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
      .joined(separator: "\n")
    var found: Set<String> = []
    var search = code[...]
    while let start = search.range(of: "serverFacts[\"") {
      let rest = search[start.upperBound...]
      guard let end = rest.firstIndex(of: "\"") else { break }
      found.insert(String(rest[rest.startIndex..<end]))
      search = rest[end...]
    }
    return found
  }

  func testTheEngineReadsNoServerFactKeyNobodyPublishes() throws {
    let engine = try source("Sources/ArkDeckWorkflows/RuntimeJobEngine.swift")
    let read = literalKeys(in: engine)

    // The published names, from the type that publishes them. Read as values
    // rather than as source text so a renamed constant moves both ends at once.
    let published: Set<String> = [
      TargetStoreRockchipRuntimeFactsPort.hdcAliasIdentityServerFactKey,
      TargetStoreRockchipRuntimeFactsPort.hdcAliasTopologyServerFactKey,
      TargetStoreRockchipRuntimeFactsPort.crossModeBindingServerFactKey,
      "componentPackage", "componentSigningIdentifier", "componentSigningTeam",
    ]

    let unpublished = read.subtracting(published).sorted()
    XCTAssertEqual(
      unpublished, [],
      """
      the engine reads server facts under keys no producer writes, so each \
      resolves to nil at runtime: \(unpublished.joined(separator: ", ")). \
      Subscript the producer's published constant instead of a literal.
      """)
  }

  func testTheTopologyKeyIsTheOneTheProducerPublishes() throws {
    // Named on its own because it is the one a wrong answer puts a device in
    // the wrong mode over.
    XCTAssertEqual(
      TargetStoreRockchipRuntimeFactsPort.hdcAliasTopologyServerFactKey,
      "dayu200HDCNormalAliasUSBTopology")

    let engine = try source("Sources/ArkDeckWorkflows/RuntimeJobEngine.swift")
    XCTAssertFalse(
      literalKeys(in: engine).contains("usbTopology"),
      "the engine is reading the key that never existed")
    XCTAssertTrue(
      engine.contains("TargetStoreRockchipRuntimeFactsPort.hdcAliasTopologyServerFactKey"),
      "the ArkForge lane must take the topology from the producer's constant")
  }
}

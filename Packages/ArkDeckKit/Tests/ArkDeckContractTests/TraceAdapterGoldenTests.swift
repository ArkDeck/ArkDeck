import ArkDeckOpenHarmony
import CryptoKit
import Foundation
import XCTest

/// TASK-TR-003 parser-golden coverage. Every authority-bearing positive case reads the
/// TASK-TR-001 registry/resource closure from the repository; inline mutations are negative or
/// derived contract vectors and are never represented as new golden provenance.
final class TraceAdapterGoldenTests: XCTestCase {
  private struct Registry: Decodable {
    let registryId: String
    let registryVersion: String
    let integrationProfile: String
    let unknownFamilyDisposition: String
    let capabilityMatrix: [Capability]
    let entries: [Entry]

    struct Capability: Decodable {
      let tool: String
      let family: String
      let help: String
      let tagList: String
      let minimalCapture: String
      let adapterSelection: String
    }

    struct Entry: Decodable {
      let id: String
      let tool: String
      let intent: String
      let status: String
      let judgement: Judgement
    }

    struct Judgement: Decodable {
      let requiredOrderedMarkers: [String]?
      let timestampPrefixPolicy: String?
      let goldenResource: String?
      let rawHeaderResource: String?
    }
  }

  private struct ResourceManifest: Decodable {
    let registryId: String
    let registryVersion: String
    let integrationProfile: String
    let resources: [Resource]

    struct Resource: Decodable {
      let id: String
      let role: String
      let path: String
      let sha256: String
      let sizeBytes: Int
    }
  }

  // MARK: - Registered closure

  func testAdoptedProfileMatchesTheCompleteTR001RegistryResourceClosure() throws {
    let registryData = try Data(contentsOf: registryURL)
    let manifestData = try Data(contentsOf: resourceManifestURL)
    XCTAssertEqual(sha256(registryData), TraceProbeAdapterProfile.registrySHA256)
    XCTAssertEqual(sha256(manifestData), TraceProbeAdapterProfile.resourceManifestSHA256)

    let registry = try JSONDecoder().decode(Registry.self, from: registryData)
    let manifest = try JSONDecoder().decode(ResourceManifest.self, from: manifestData)
    XCTAssertEqual(registry.registryId, TraceProbeAdapterProfile.registryID)
    XCTAssertEqual(registry.registryVersion, TraceProbeAdapterProfile.registryVersion)
    XCTAssertEqual(registry.integrationProfile, TraceProbeAdapterProfile.integrationProfile)
    XCTAssertEqual(registry.unknownFamilyDisposition, "unsupported")
    XCTAssertEqual(manifest.registryId, registry.registryId)
    XCTAssertEqual(manifest.registryVersion, registry.registryVersion)
    XCTAssertEqual(manifest.integrationProfile, registry.integrationProfile)
    XCTAssertEqual(registry.entries.count, 7)
    XCTAssertEqual(manifest.resources.count, 7)
    XCTAssertEqual(Set(manifest.resources.map(\.id)).count, manifest.resources.count)

    let hitrace = try XCTUnwrap(registry.capabilityMatrix.first { $0.tool == "hitrace" })
    XCTAssertEqual(hitrace.family, TraceProbeAdapterProfile.hitraceHelpFamily)
    XCTAssertEqual(hitrace.help, "registered")
    XCTAssertEqual(hitrace.tagList, "registered")
    XCTAssertEqual(hitrace.minimalCapture, "registered")
    XCTAssertEqual(hitrace.adapterSelection, "eligible")

    let bytrace = try XCTUnwrap(registry.capabilityMatrix.first { $0.tool == "bytrace" })
    XCTAssertEqual(bytrace.family, TraceProbeAdapterProfile.bytraceHelpFamily)
    XCTAssertEqual(bytrace.help, "registered")
    XCTAssertEqual(bytrace.tagList, "registered")
    XCTAssertEqual(bytrace.minimalCapture, "unregistered")
    XCTAssertEqual(bytrace.adapterSelection, "probeOnlyNotCaptureEligible")

    let helpEntries = registry.entries.filter { $0.intent == "helpFamilyProbe" }
    XCTAssertEqual(helpEntries.count, 4)
    for entry in helpEntries where entry.id.contains("-long-") {
      XCTAssertEqual(
        entry.judgement.timestampPrefixPolicy,
        "Ignore only the leading YYYY/MM/DD HH:MM:SS token pair on the registered enter line.")
      XCTAssertFalse(entry.judgement.requiredOrderedMarkers?.isEmpty ?? true)
    }
    let capture = try XCTUnwrap(
      registry.entries.first { $0.intent == "minimalOwnedTraceCapture" })
    XCTAssertEqual(capture.status, "registered")
    XCTAssertEqual(capture.judgement.rawHeaderResource, "tr001-raw-ftrace-header-dayu200-oh7")

    var actualFiles: Set<String> = []
    let enumerator = try XCTUnwrap(
      FileManager.default.enumerator(
        at: packRoot,
        includingPropertiesForKeys: [.isRegularFileKey]))
    for case let url as URL in enumerator {
      guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
        continue
      }
      actualFiles.insert(
        url.path.replacingOccurrences(of: packRoot.path + "/", with: ""))
    }
    XCTAssertEqual(
      actualFiles,
      Set(manifest.resources.map(\.path)).union(["registry.yaml", "resources.json"]))

    for resource in manifest.resources {
      let bytes = try Data(contentsOf: packRoot.appending(path: resource.path))
      XCTAssertEqual(bytes.count, resource.sizeBytes, resource.id)
      XCTAssertEqual(sha256(bytes), resource.sha256, resource.id)
    }

    XCTAssertEqual(
      try resource(id: "tr001-hitrace-help-dayu200-oh7", manifest: manifest).sha256,
      TraceProbeAdapterProfile.hitraceHelpResourceSHA256)
    XCTAssertEqual(
      try resource(id: "tr001-bytrace-help-dayu200-oh7", manifest: manifest).sha256,
      TraceProbeAdapterProfile.bytraceHelpResourceSHA256)
    XCTAssertEqual(
      try resource(id: "tr001-raw-ftrace-header-dayu200-oh7", manifest: manifest).sha256,
      TraceProbeAdapterProfile.rawFtraceHeaderResourceSHA256)
  }

  // MARK: - AC-TRACE-001-01

  func testTEST_AC_TRACE_001_01_ExactFamiliesSelectAndUnknownRawRemainsInspectable() throws {
    let manifest = try loadManifest()
    let hitraceHelp = try bytes(id: "tr001-hitrace-help-dayu200-oh7", manifest: manifest)
    let bytraceHelp = try bytes(id: "tr001-bytrace-help-dayu200-oh7", manifest: manifest)

    let hitrace = TraceProbeAdapter.evaluateHelp(tool: .hitrace, stdout: hitraceHelp)
    XCTAssertEqual(
      hitrace.selection,
      .captureEligible(
        tool: .hitrace,
        family: TraceProbeAdapterProfile.hitraceHelpFamily))
    XCTAssertEqual(hitrace.rawHelp, hitraceHelp)
    XCTAssertEqual(hitrace.rawHelpSHA256, TraceProbeAdapterProfile.hitraceHelpResourceSHA256)

    let bytrace = TraceProbeAdapter.evaluateHelp(tool: .bytrace, stdout: bytraceHelp)
    XCTAssertEqual(
      bytrace.selection,
      .probeOnlyNotCaptureEligible(
        tool: .bytrace,
        family: TraceProbeAdapterProfile.bytraceHelpFamily))
    XCTAssertEqual(bytrace.rawHelp, bytraceHelp)
    XCTAssertEqual(bytrace.rawHelpSHA256, TraceProbeAdapterProfile.bytraceHelpResourceSHA256)

    XCTAssertEqual(
      TraceProbeAdapter.evaluateHelp(tool: .hitrace, stdout: bytraceHelp).selection,
      .unsupported,
      "a tool name cannot borrow the other registered byte family")

    let unknown = Data("2026/07/23 01:02:03 hitrace unknown family\n".utf8)
    let unknownEvaluation = TraceProbeAdapter.evaluateHelp(tool: .hitrace, stdout: unknown)
    XCTAssertEqual(unknownEvaluation.selection, .unsupported)
    XCTAssertEqual(unknownEvaluation.rawHelp, unknown)
    XCTAssertEqual(unknownEvaluation.rawHelpSHA256, sha256(unknown))

    print(
      "TEST-AC-TRACE-001-01 PASS hitrace=eligible bytrace=probeOnlyNotCaptureEligible unknown=unsupported raw=inspectable real_device=0 hdc=0 network=0 process=0"
    )
  }

  func testHelpNormalizationAllowsOnlyAValidLeadingTimestampTokenPair() throws {
    let manifest = try loadManifest()
    let golden = try bytes(id: "tr001-hitrace-help-dayu200-oh7", manifest: manifest)
    var timestampOnlyDrift = golden
    timestampOnlyDrift.replaceSubrange(0..<19, with: Data("2030/12/31 23:59:59".utf8))
    XCTAssertEqual(
      TraceProbeAdapter.evaluateHelp(tool: .hitrace, stdout: timestampOnlyDrift).selection,
      .captureEligible(
        tool: .hitrace,
        family: TraceProbeAdapterProfile.hitraceHelpFamily))

    var invalidTimestamp = golden
    invalidTimestamp.replaceSubrange(0..<19, with: Data("2030/13/31 23:59:59".utf8))
    XCTAssertEqual(
      TraceProbeAdapter.evaluateHelp(tool: .hitrace, stdout: invalidTimestamp).selection,
      .unsupported)

    var shiftedPrefix = golden
    shiftedPrefix[19] = 9
    XCTAssertEqual(
      TraceProbeAdapter.evaluateHelp(tool: .hitrace, stdout: shiftedPrefix).selection,
      .unsupported)
  }

  func testSameNameDriftMissingMarkersAndStderrFailClosedWithoutLosingRawBytes() throws {
    let manifest = try loadManifest()
    let golden = try bytes(id: "tr001-hitrace-help-dayu200-oh7", manifest: manifest)

    var byteDrift = golden
    byteDrift[byteDrift.index(before: byteDrift.endIndex)] = 33
    let drifted = TraceProbeAdapter.evaluateHelp(tool: .hitrace, stdout: byteDrift)
    XCTAssertEqual(drifted.selection, .unsupported)
    XCTAssertEqual(drifted.rawHelp, byteDrift)

    var missingMarker = golden
    let marker = try XCTUnwrap(missingMarker.range(of: Data("-o filename".utf8)))
    missingMarker[marker.lowerBound] = 95
    let missing = TraceProbeAdapter.evaluateHelp(tool: .hitrace, stdout: missingMarker)
    XCTAssertEqual(missing.selection, .unsupported)
    XCTAssertEqual(missing.rawHelp, missingMarker)

    let stderr = Data("unregistered diagnostic".utf8)
    let withStderr = TraceProbeAdapter.evaluateHelp(
      tool: .hitrace,
      stdout: golden,
      stderr: stderr)
    XCTAssertEqual(withStderr.selection, .unsupported)
    XCTAssertEqual(withStderr.rawHelp, golden)
    XCTAssertEqual(withStderr.rawStderr, stderr)
  }

  // MARK: - AC-TRACE-007-01

  func testTEST_AC_TRACE_007_01_RegisteredHeaderAndRawRemainByteExact() throws {
    let manifest = try loadManifest()
    let header = try bytes(id: "tr001-raw-ftrace-header-dayu200-oh7", manifest: manifest)
    let beforeSHA256 = sha256(header)

    let evaluation = TraceFtracePostprocessor.evaluate(
      rawBytes: header,
      options: TraceFtraceFilterOptions(removeCreateFileAssetLines: true))
    XCTAssertEqual(evaluation.raw.bytes, header)
    XCTAssertEqual(evaluation.raw.sha256, beforeSHA256)
    XCTAssertEqual(sha256(header), beforeSHA256)
    guard case .derived(let derived) = evaluation.disposition else {
      return XCTFail("the registered header must be accepted")
    }
    XCTAssertEqual(derived.bytes, header)
    XCTAssertEqual(derived.sha256, beforeSHA256)
    XCTAssertEqual(derived.removedLineCount, 0)
    XCTAssertEqual(derived.removedByteCount, 0)
    XCTAssertTrue(derived.bytes.starts(with: Data("# tracer: nop\n#\n".utf8)))

    print(
      "TEST-AC-TRACE-007-01 PASS registered_header=preserved raw_sha256=unchanged fixed_line_deletion=0 removed_lines=0 real_device=0 hdc=0 network=0 process=0"
    )
  }

  func testFilteringStartsAfterHeaderAndRemovesOnlyTheClosedChatterToken() throws {
    let manifest = try loadManifest()
    let header = try bytes(id: "tr001-raw-ftrace-header-dayu200-oh7", manifest: manifest)
    let chatter = Data("trace-event: CreateFileAsset\n".utf8)
    let embeddedToken = Data("trace-event: CreateFileAssetHelper\n".utf8)
    let retained = Data("trace-event: sched_switch\n".utf8)
    let raw = header + chatter + embeddedToken + retained
    let rawSHA256 = sha256(raw)

    let evaluation = TraceFtracePostprocessor.evaluate(
      rawBytes: raw,
      options: TraceFtraceFilterOptions(removeCreateFileAssetLines: true))
    XCTAssertEqual(evaluation.raw.bytes, raw)
    XCTAssertEqual(evaluation.raw.sha256, rawSHA256)
    XCTAssertEqual(sha256(raw), rawSHA256)
    guard case .derived(let derived) = evaluation.disposition else {
      return XCTFail("a registered header prefix must permit derived filtering")
    }
    XCTAssertEqual(derived.bytes, header + embeddedToken + retained)
    XCTAssertTrue(derived.bytes.starts(with: header))
    XCTAssertEqual(derived.removedLineCount, 1)
    XCTAssertEqual(derived.removedByteCount, chatter.count)

    let disabled = TraceFtracePostprocessor.evaluate(rawBytes: raw)
    guard case .derived(let unfiltered) = disabled.disposition else {
      return XCTFail("a registered header prefix must permit an unfiltered derived artifact")
    }
    XCTAssertEqual(unfiltered.bytes, raw)
    XCTAssertEqual(unfiltered.removedLineCount, 0)
    XCTAssertEqual(unfiltered.removedByteCount, 0)

    // Public Data values can retain a non-zero startIndex when produced by slicing. The
    // postprocessor must use collection indices rather than assuming zero-based Int offsets.
    let padding = Data(repeating: 0x78, count: 701)
    let trailer = Data(repeating: 0x79, count: 17)
    let envelope = padding + raw + trailer
    let slicedRaw = envelope.dropFirst(padding.count).dropLast(trailer.count)
    XCTAssertEqual(slicedRaw.startIndex, padding.count)
    let slicedEvaluation = TraceFtracePostprocessor.evaluate(
      rawBytes: slicedRaw,
      options: TraceFtraceFilterOptions(removeCreateFileAssetLines: true))
    XCTAssertEqual(slicedEvaluation.raw.bytes, raw)
    XCTAssertEqual(slicedEvaluation.raw.sha256, rawSHA256)
    guard case .derived(let slicedDerived) = slicedEvaluation.disposition else {
      return XCTFail("a non-zero-index Data slice with the registered header must be accepted")
    }
    XCTAssertEqual(slicedDerived.bytes, header + embeddedToken + retained)
    XCTAssertEqual(slicedDerived.removedLineCount, 1)
    XCTAssertEqual(slicedDerived.removedByteCount, chatter.count)
  }

  func testUnregisteredHeaderFailsClosedAndStillReturnsTheRawSnapshot() throws {
    let manifest = try loadManifest()
    var drifted = try bytes(id: "tr001-raw-ftrace-header-dayu200-oh7", manifest: manifest)
    drifted[0] = 33
    let evaluation = TraceFtracePostprocessor.evaluate(
      rawBytes: drifted,
      options: TraceFtraceFilterOptions(removeCreateFileAssetLines: true))
    XCTAssertEqual(evaluation.disposition, .unsupportedHeader)
    XCTAssertEqual(evaluation.raw.bytes, drifted)
    XCTAssertEqual(evaluation.raw.sha256, sha256(drifted))
  }

  // MARK: - Repository fixture access

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // ArkDeckContractTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // ArkDeckKit
      .deletingLastPathComponent()  // Packages
      .deletingLastPathComponent()  // repository root
  }

  private var packRoot: URL {
    repositoryRoot.appending(
      path: "openspec/integrations/openharmony/trace-probes/1.0.0")
  }

  private var registryURL: URL { packRoot.appending(path: "registry.yaml") }
  private var resourceManifestURL: URL { packRoot.appending(path: "resources.json") }

  private func loadManifest() throws -> ResourceManifest {
    try JSONDecoder().decode(
      ResourceManifest.self,
      from: Data(contentsOf: resourceManifestURL))
  }

  private func resource(
    id: String,
    manifest: ResourceManifest
  ) throws -> ResourceManifest.Resource {
    try XCTUnwrap(manifest.resources.first { $0.id == id })
  }

  private func bytes(id: String, manifest: ResourceManifest) throws -> Data {
    let item = try resource(id: id, manifest: manifest)
    let result = try Data(contentsOf: packRoot.appending(path: item.path))
    XCTAssertEqual(result.count, item.sizeBytes, id)
    XCTAssertEqual(sha256(result), item.sha256, id)
    return result
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

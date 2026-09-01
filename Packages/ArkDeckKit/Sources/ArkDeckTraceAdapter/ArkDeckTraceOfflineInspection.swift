import ArkTraceAppSupport
import Foundation

public struct ArkDeckTraceOfflineInspectionContract: Sendable, Equatable {
  public let engineVersion: String
  public let engineBuild: String
  public let parserVersion: String
  public let parserUpstreamRevision: String
  public let parserSHA256: String
  public let parserAdapterVersion: String
  public let parserBuildRecipeVersion: String
  public let schemaAdapterVersion: String
  public let indexSchemaVersion: Int

  public init(
    engineVersion: String,
    engineBuild: String,
    parserVersion: String,
    parserUpstreamRevision: String,
    parserSHA256: String,
    parserAdapterVersion: String,
    parserBuildRecipeVersion: String,
    schemaAdapterVersion: String,
    indexSchemaVersion: Int
  ) {
    self.engineVersion = engineVersion
    self.engineBuild = engineBuild
    self.parserVersion = parserVersion
    self.parserUpstreamRevision = parserUpstreamRevision
    self.parserSHA256 = parserSHA256
    self.parserAdapterVersion = parserAdapterVersion
    self.parserBuildRecipeVersion = parserBuildRecipeVersion
    self.schemaAdapterVersion = schemaAdapterVersion
    self.indexSchemaVersion = indexSchemaVersion
  }
}

public struct ArkDeckTraceOfflineInspectionQualityIssue: Sendable, Equatable {
  public let category: String
  public let scope: String?
  public let count: Int64?

  public init(category: String, scope: String?, count: Int64?) {
    self.category = category
    self.scope = scope
    self.count = count
  }
}

public struct ArkDeckTraceOfflineInspectionReport: Sendable, Equatable {
  public let engineVersion: String
  public let engineBuild: String
  public let engineSourceRevision: String
  public let sourceSHA256: String
  public let sourceByteCount: Int
  public let durationNs: Int64
  public let schemaFingerprint: String
  public let parserName: String
  public let parserVersion: String
  public let parserUpstreamRevision: String
  public let parserSHA256: String
  public let parserAdapterVersion: String
  public let parserBuildRecipeVersion: String
  public let schemaAdapterVersion: String
  public let indexSchemaVersion: Int
  public let upstreamDatabaseSHA256: String
  public let upstreamDatabaseByteCount: Int64
  public let cpuScheduling: Bool
  public let threadStates: Bool
  public let namedSlices: Bool
  public let cpuCounters: Bool
  public let processCounters: Bool
  public let dataQualityStatus: String
  public let dataQualityIssues: [ArkDeckTraceOfflineInspectionQualityIssue]
}

public enum ArkDeckTraceOfflineInspectionError: Error, Equatable {
  case contractMismatch
}

/// Narrow ArkDeck adapter over ArkTrace's public offline inspection owner.
/// Distribution and working roots are fixed by daemon composition; only the
/// Runtime-held Artifact inode alias reaches `inspect`.
public actor ArkDeckTraceOfflineInspectionService {
  private let service: TraceOfflineInspectionService
  private let contract: ArkDeckTraceOfflineInspectionContract

  public init(
    distributionBundleURL: URL,
    workingDirectory: URL,
    contract: ArkDeckTraceOfflineInspectionContract
  ) throws {
    let root = workingDirectory.standardizedFileURL
    let configuration = try TraceProductConfiguration(
      bundleURL: distributionBundleURL,
      cacheDirectory: root.appending(path: "traces", directoryHint: .isDirectory),
      stagingDirectory: root.appending(path: "staging", directoryHint: .isDirectory),
      recentDocumentsKey: "ArkDeck.Runtime.TraceInspection.Recent.v1",
      signpostSubsystem: "com.arkdeck.runtime.trace-inspection",
      bundledParser: TraceBundledParserLocation(
        executableRelativePath: "Contents/Helpers/trace_streamer",
        manifestRelativePath: "Contents/Resources/TraceStreamer/manifest.json"
      ),
      bundledParserExecutionPolicy: .immutableSnapshot
    )
    service = TraceOfflineInspectionService(configuration: configuration)
    self.contract = contract
  }

  public func inspect(
    source: URL,
    expectedSourceSHA256: String,
    expectedSourceByteCount: Int
  ) async throws -> ArkDeckTraceOfflineInspectionReport {
    let report = try await service.inspect(
      source: source,
      expectedSourceSHA256: expectedSourceSHA256,
      expectedSourceByteCount: Int64(expectedSourceByteCount)
    )
    let parser = report.provenance.parser
    guard report.engineVersion == contract.engineVersion,
      report.engineBuild == contract.engineBuild,
      parser.reportedVersion == contract.parserVersion,
      parser.upstreamRevision == contract.parserUpstreamRevision,
      parser.binarySHA256 == contract.parserSHA256,
      parser.adapterVersion == contract.parserAdapterVersion,
      parser.buildRecipeVersion == contract.parserBuildRecipeVersion,
      report.provenance.schemaAdapterVersion == contract.schemaAdapterVersion,
      report.provenance.indexSchemaVersion == contract.indexSchemaVersion,
      report.sourceByteCount == Int64(expectedSourceByteCount)
    else { throw ArkDeckTraceOfflineInspectionError.contractMismatch }
    let dataQualityIssues = report.dataQualityIssues.map {
      ArkDeckTraceOfflineInspectionQualityIssue(
        category: $0.category.rawValue,
        scope: $0.scope,
        count: $0.count)
    }.sorted { lhs, rhs in
      if lhs.category != rhs.category { return lhs.category < rhs.category }
      if (lhs.scope ?? "") != (rhs.scope ?? "") {
        return (lhs.scope ?? "") < (rhs.scope ?? "")
      }
      return (lhs.count ?? Int64.min) < (rhs.count ?? Int64.min)
    }
    return ArkDeckTraceOfflineInspectionReport(
      engineVersion: report.engineVersion,
      engineBuild: report.engineBuild,
      engineSourceRevision: ArkDeckTraceConfiguration.arkTraceSourceRevision,
      sourceSHA256: report.sourceSHA256,
      sourceByteCount: expectedSourceByteCount,
      durationNs: report.durationNs,
      schemaFingerprint: report.schemaFingerprint,
      parserName: parser.name,
      parserVersion: parser.reportedVersion,
      parserUpstreamRevision: parser.upstreamRevision,
      parserSHA256: parser.binarySHA256,
      parserAdapterVersion: parser.adapterVersion,
      parserBuildRecipeVersion: parser.buildRecipeVersion,
      schemaAdapterVersion: report.provenance.schemaAdapterVersion,
      indexSchemaVersion: report.provenance.indexSchemaVersion,
      upstreamDatabaseSHA256: report.provenance.upstreamDatabaseSHA256,
      upstreamDatabaseByteCount: report.provenance.upstreamDatabaseByteCount,
      cpuScheduling: report.capabilities.cpuScheduling,
      threadStates: report.capabilities.threadStates,
      namedSlices: report.capabilities.namedSlices,
      cpuCounters: report.capabilities.cpuCounters,
      processCounters: report.capabilities.processCounters,
      dataQualityStatus: report.dataQualityStatus.rawValue,
      dataQualityIssues: dataQualityIssues)
  }
}

import ArkDeckCore
import ArkDeckProcess
import Foundation

public enum RuntimeTraceInspectionFailure: Error, Equatable, Sendable {
  case artifactIntegrity
  case invalidReport(String)
  case timedOut
}

public struct RuntimeTraceInspectionParser: Sendable, Equatable {
  public let name: String
  public let version: String
  public let upstreamRevision: String
  public let binarySHA256: String
  public let adapterVersion: String
  public let buildRecipeVersion: String

  public init(
    name: String,
    version: String,
    upstreamRevision: String,
    binarySHA256: String,
    adapterVersion: String,
    buildRecipeVersion: String
  ) throws {
    guard Self.safe(name), Self.safe(version),
      Self.lowercaseHex(upstreamRevision, count: 40),
      SHA256Hex.isLowercaseSHA256(binarySHA256),
      Self.safe(adapterVersion), Self.safe(buildRecipeVersion)
    else { throw RuntimeTraceInspectionFailure.invalidReport("parserIdentity") }
    self.name = name
    self.version = version
    self.upstreamRevision = upstreamRevision
    self.binarySHA256 = binarySHA256
    self.adapterVersion = adapterVersion
    self.buildRecipeVersion = buildRecipeVersion
  }

  fileprivate static func safe(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
      && !value.contains("/") && !value.contains("\\")
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  fileprivate static func lowercaseHex(_ value: String, count: Int) -> Bool {
    value.utf8.count == count && value.utf8.allSatisfy {
      (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
        || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
    }
  }

  package var projection: JSONValue {
    .object([
      "name": .string(name),
      "version": .string(version),
      "upstreamRevision": .string(upstreamRevision),
      "binarySha256": .string(binarySHA256),
      "adapterVersion": .string(adapterVersion),
      "buildRecipeVersion": .string(buildRecipeVersion),
    ])
  }
}

public struct RuntimeTraceInspectionSchema: Sendable, Equatable {
  public let adapterVersion: String
  public let indexVersion: Int
  public let upstreamDatabaseSHA256: String
  public let upstreamDatabaseByteCount: Int64

  public init(
    adapterVersion: String,
    indexVersion: Int,
    upstreamDatabaseSHA256: String,
    upstreamDatabaseByteCount: Int64
  ) throws {
    guard RuntimeTraceInspectionParser.safe(adapterVersion), indexVersion >= 0,
      SHA256Hex.isLowercaseSHA256(upstreamDatabaseSHA256),
      upstreamDatabaseByteCount >= 0
    else { throw RuntimeTraceInspectionFailure.invalidReport("schemaProvenance") }
    self.adapterVersion = adapterVersion
    self.indexVersion = indexVersion
    self.upstreamDatabaseSHA256 = upstreamDatabaseSHA256
    self.upstreamDatabaseByteCount = upstreamDatabaseByteCount
  }

  package var projection: JSONValue {
    .object([
      "adapterVersion": .string(adapterVersion),
      "indexVersion": .integer(Int64(indexVersion)),
      "upstreamDatabaseSha256": .string(upstreamDatabaseSHA256),
      "upstreamDatabaseByteCount": .string(String(upstreamDatabaseByteCount)),
    ])
  }
}

public struct RuntimeTraceInspectionCapabilities: Sendable, Equatable {
  public let cpuScheduling: Bool
  public let threadStates: Bool
  public let namedSlices: Bool
  public let cpuCounters: Bool
  public let processCounters: Bool

  public init(
    cpuScheduling: Bool,
    threadStates: Bool,
    namedSlices: Bool,
    cpuCounters: Bool,
    processCounters: Bool
  ) {
    self.cpuScheduling = cpuScheduling
    self.threadStates = threadStates
    self.namedSlices = namedSlices
    self.cpuCounters = cpuCounters
    self.processCounters = processCounters
  }

  package var projection: JSONValue {
    .object([
      "cpuScheduling": .bool(cpuScheduling),
      "threadStates": .bool(threadStates),
      "namedSlices": .bool(namedSlices),
      "cpuCounters": .bool(cpuCounters),
      "processCounters": .bool(processCounters),
    ])
  }
}

public struct RuntimeTraceInspectionQualityIssue: Sendable, Equatable {
  public let category: String
  public let scope: String?
  public let count: Int64?

  public init(category: String, scope: String?, count: Int64?) throws {
    let categories: Set<String> = [
      "probeTruncated", "invalidValue", "clampedValue", "droppedValue",
      "referentialIntegrity", "unavailableValue",
    ]
    guard categories.contains(category),
      scope.map(ArkTraceSummaryEnvelopeValidator.machineQualityScopes.contains) ?? true,
      count.map({ $0 >= 0 }) ?? true
    else { throw RuntimeTraceInspectionFailure.invalidReport("dataQuality") }
    self.category = category
    self.scope = scope
    self.count = count
  }

  fileprivate var key: (String, String, Int64) {
    (category, scope ?? "", count ?? Int64.min)
  }

  package var projection: JSONValue {
    .object([
      "category": .string(category),
      "scope": scope.map(JSONValue.string) ?? .null,
      "count": count.map(JSONValue.integer) ?? .null,
    ])
  }
}

/// Runtime-owned, path-free result for one exact immutable Trace Artifact.
/// This is a local derivation and never becomes Job evidence.
public struct RuntimeTraceInspectionReport: Sendable, Equatable {
  public let engineVersion: String
  public let engineBuild: String
  public let engineSourceRevision: String
  public let sourceSHA256: String
  public let sourceByteCount: Int
  public let durationNs: Int64
  public let schemaFingerprint: String
  public let parser: RuntimeTraceInspectionParser
  public let schema: RuntimeTraceInspectionSchema
  public let capabilities: RuntimeTraceInspectionCapabilities
  public let dataQualityStatus: String
  public let dataQualityIssues: [RuntimeTraceInspectionQualityIssue]

  public init(
    engineVersion: String,
    engineBuild: String,
    engineSourceRevision: String,
    sourceSHA256: String,
    sourceByteCount: Int,
    durationNs: Int64,
    schemaFingerprint: String,
    parser: RuntimeTraceInspectionParser,
    schema: RuntimeTraceInspectionSchema,
    capabilities: RuntimeTraceInspectionCapabilities,
    dataQualityStatus: String,
    dataQualityIssues: [RuntimeTraceInspectionQualityIssue]
  ) throws {
    guard RuntimeTraceInspectionParser.safe(engineVersion),
      RuntimeTraceInspectionParser.safe(engineBuild),
      RuntimeTraceInspectionParser.lowercaseHex(engineSourceRevision, count: 40),
      SHA256Hex.isLowercaseSHA256(sourceSHA256), sourceByteCount > 0,
      durationNs >= 0, SHA256Hex.isLowercaseSHA256(schemaFingerprint),
      ["ok", "warnings"].contains(dataQualityStatus),
      dataQualityIssues.count <= 4_096,
      dataQualityStatus == (dataQualityIssues.isEmpty ? "ok" : "warnings")
    else { throw RuntimeTraceInspectionFailure.invalidReport("resultIdentity") }
    var previous: (String, String, Int64)?
    var identities = Set<String>()
    for issue in dataQualityIssues {
      guard previous.map({ $0 <= issue.key }) ?? true,
        identities.insert(
          "\(issue.key.0)\u{0}\(issue.key.1)\u{0}\(issue.key.2)"
        ).inserted
      else { throw RuntimeTraceInspectionFailure.invalidReport("dataQualityOrder") }
      previous = issue.key
    }
    self.engineVersion = engineVersion
    self.engineBuild = engineBuild
    self.engineSourceRevision = engineSourceRevision
    self.sourceSHA256 = sourceSHA256
    self.sourceByteCount = sourceByteCount
    self.durationNs = durationNs
    self.schemaFingerprint = schemaFingerprint
    self.parser = parser
    self.schema = schema
    self.capabilities = capabilities
    self.dataQualityStatus = dataQualityStatus
    self.dataQualityIssues = dataQualityIssues
  }

  package func projection(
    owner: ArtifactOwnerReference,
    artifact: RuntimeArtifactMetadata
  ) -> JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.trace-inspection/1"),
      "owner": owner.value,
      "source": .object([
        "artifactId": .string(artifact.artifactID),
        "artifactDigest": .string(sourceSHA256),
        "byteCount": .string(String(sourceByteCount)),
        "sourceOperation": .string(artifact.sourceOperation),
        "name": .string(artifact.name),
        "mediaType": .string(artifact.mediaType),
        "privacy": .string(artifact.privacy.rawValue),
      ]),
      "engine": .object([
        "name": .string("ArkTrace"),
        "version": .string(engineVersion),
        "build": .string(engineBuild),
        "sourceRevision": .string(engineSourceRevision),
      ]),
      "parser": parser.projection,
      "schema": .object([
        "fingerprint": .string(schemaFingerprint),
        "provenance": schema.projection,
      ]),
      "trace": .object([
        "durationNs": .string(String(durationNs)),
        "capabilities": capabilities.projection,
      ]),
      "dataQuality": .object([
        "status": .string(dataQualityStatus),
        "issues": .array(dataQualityIssues.map(\.projection)),
      ]),
      "storageMode": .string("ephemeral"),
      "deviceEvidenceCreated": .bool(false),
    ])
  }
}

/// Closed decoder shared by CLI and daemon tests for the versioned local
/// resource. Unknown or missing fields fail instead of being dropped.
package struct RuntimeTraceInspectionProjection: Sendable {
  package let value: JSONValue
  package let owner: ArtifactOwnerReference
  package let artifactID: String
  package let report: RuntimeTraceInspectionReport

  package init(_ value: JSONValue) throws {
    func invalid(_ reason: String) -> RuntimeTraceInspectionFailure {
      .invalidReport(reason)
    }
    guard case .object(let root) = value,
      Set(root.keys) == [
        "schemaVersion", "owner", "source", "engine", "parser", "schema", "trace",
        "dataQuality", "storageMode", "deviceEvidenceCreated",
      ],
      root["schemaVersion"] == .string("arkdeck.trace-inspection/1"),
      let ownerValue = root["owner"],
      let owner = try? ArtifactOwnerReference(ownerValue), owner.kind == "job",
      root["storageMode"] == .string("ephemeral"),
      root["deviceEvidenceCreated"] == .bool(false),
      case .object(let source)? = root["source"],
      Set(source.keys) == [
        "artifactId", "artifactDigest", "byteCount", "sourceOperation", "name",
        "mediaType", "privacy",
      ],
      case .string(let artifactID)? = source["artifactId"],
      AgentExecutionIntent.validIdentifier(artifactID),
      case .string(let sourceSHA)? = source["artifactDigest"],
      SHA256Hex.isLowercaseSHA256(sourceSHA),
      case .string(let byteText)? = source["byteCount"],
      let byteCount = Int(byteText), byteCount > 0, String(byteCount) == byteText,
      source["sourceOperation"] == .string("capture.diagnostics@1"),
      source["name"] == .string("trace.htrace"),
      source["mediaType"] == .string("application/octet-stream"),
      source["privacy"] == .string("sensitive"),
      case .object(let engine)? = root["engine"],
      Set(engine.keys) == ["name", "version", "build", "sourceRevision"],
      engine["name"] == .string("ArkTrace"),
      case .string(let engineVersion)? = engine["version"],
      case .string(let engineBuild)? = engine["build"],
      case .string(let engineRevision)? = engine["sourceRevision"],
      case .object(let parserFields)? = root["parser"],
      Set(parserFields.keys) == [
        "name", "version", "upstreamRevision", "binarySha256", "adapterVersion",
        "buildRecipeVersion",
      ],
      case .string(let parserName)? = parserFields["name"],
      case .string(let parserVersion)? = parserFields["version"],
      case .string(let parserRevision)? = parserFields["upstreamRevision"],
      case .string(let parserSHA)? = parserFields["binarySha256"],
      case .string(let parserAdapter)? = parserFields["adapterVersion"],
      case .string(let parserRecipe)? = parserFields["buildRecipeVersion"],
      case .object(let schemaFields)? = root["schema"],
      Set(schemaFields.keys) == ["fingerprint", "provenance"],
      case .string(let schemaFingerprint)? = schemaFields["fingerprint"],
      case .object(let provenance)? = schemaFields["provenance"],
      Set(provenance.keys) == [
        "adapterVersion", "indexVersion", "upstreamDatabaseSha256",
        "upstreamDatabaseByteCount",
      ],
      case .string(let schemaAdapter)? = provenance["adapterVersion"],
      case .integer(let rawIndex)? = provenance["indexVersion"],
      let indexVersion = Int(exactly: rawIndex),
      case .string(let databaseSHA)? = provenance["upstreamDatabaseSha256"],
      case .string(let databaseByteText)? = provenance["upstreamDatabaseByteCount"],
      let databaseBytes = Int64(databaseByteText), databaseBytes >= 0,
      String(databaseBytes) == databaseByteText,
      case .object(let trace)? = root["trace"],
      Set(trace.keys) == ["durationNs", "capabilities"],
      case .string(let durationText)? = trace["durationNs"],
      let duration = Int64(durationText), duration >= 0, String(duration) == durationText,
      case .object(let capabilities)? = trace["capabilities"],
      Set(capabilities.keys) == [
        "cpuScheduling", "threadStates", "namedSlices", "cpuCounters",
        "processCounters",
      ],
      case .bool(let cpuScheduling)? = capabilities["cpuScheduling"],
      case .bool(let threadStates)? = capabilities["threadStates"],
      case .bool(let namedSlices)? = capabilities["namedSlices"],
      case .bool(let cpuCounters)? = capabilities["cpuCounters"],
      case .bool(let processCounters)? = capabilities["processCounters"],
      case .object(let quality)? = root["dataQuality"],
      Set(quality.keys) == ["status", "issues"],
      case .string(let qualityStatus)? = quality["status"],
      case .array(let rawIssues)? = quality["issues"], rawIssues.count <= 4_096
    else { throw invalid("shape") }
    let issues = try rawIssues.map { raw -> RuntimeTraceInspectionQualityIssue in
      guard case .object(let fields) = raw,
        Set(fields.keys) == ["category", "scope", "count"],
        case .string(let category)? = fields["category"]
      else { throw invalid("qualityShape") }
      let scope: String?
      switch fields["scope"] {
      case .null?: scope = nil
      case .string(let value)?: scope = value
      default: throw invalid("qualityScope")
      }
      let count: Int64?
      switch fields["count"] {
      case .null?: count = nil
      case .integer(let value)?: count = value
      default: throw invalid("qualityCount")
      }
      return try RuntimeTraceInspectionQualityIssue(
        category: category, scope: scope, count: count)
    }
    let parser = try RuntimeTraceInspectionParser(
      name: parserName, version: parserVersion,
      upstreamRevision: parserRevision, binarySHA256: parserSHA,
      adapterVersion: parserAdapter, buildRecipeVersion: parserRecipe)
    let schema = try RuntimeTraceInspectionSchema(
      adapterVersion: schemaAdapter, indexVersion: indexVersion,
      upstreamDatabaseSHA256: databaseSHA,
      upstreamDatabaseByteCount: databaseBytes)
    report = try RuntimeTraceInspectionReport(
      engineVersion: engineVersion, engineBuild: engineBuild,
      engineSourceRevision: engineRevision,
      sourceSHA256: sourceSHA, sourceByteCount: byteCount,
      durationNs: duration, schemaFingerprint: schemaFingerprint,
      parser: parser, schema: schema,
      capabilities: RuntimeTraceInspectionCapabilities(
        cpuScheduling: cpuScheduling, threadStates: threadStates,
        namedSlices: namedSlices, cpuCounters: cpuCounters,
        processCounters: processCounters),
      dataQualityStatus: qualityStatus, dataQualityIssues: issues)
    self.value = value
    self.owner = owner
    self.artifactID = artifactID
  }
}

/// Production composition accepts only a Runtime-resolved, identity-bound
/// source URL. No caller path, parser path or executable argument crosses this
/// boundary.
public protocol RuntimeTraceInspecting: Sendable {
  func inspect(
    source: URL,
    expectedSourceSHA256: String,
    expectedSourceByteCount: Int
  ) async throws -> RuntimeTraceInspectionReport
}

/// Workflows owns verified Artifact materialization and the Process-layer
/// descriptor. The daemon control surface receives only the typed result or a
/// closed failure and therefore keeps its architecture edge on Workflows.
package enum RuntimeTraceInspectionSource {
  private enum TimedAttempt: Sendable {
    case completed(RuntimeTraceInspectionReport)
    case timedOut
  }

  package static func inspect(
    lease: RuntimeArtifactLeaseResolution,
    inspector: any RuntimeTraceInspecting,
    timeoutMs: Int
  ) async throws -> RuntimeTraceInspectionReport {
    let source: VerifiedRegularFileDescriptor
    do {
      source = try VerifiedRegularFileDescriptor.open(
        path: lease.fileURL,
        expectedSHA256: lease.sha256,
        maximumBytes: lease.byteCount)
    } catch {
      throw RuntimeTraceInspectionFailure.artifactIntegrity
    }
    defer { source.close() }
    guard source.byteCount == lease.byteCount else {
      throw RuntimeTraceInspectionFailure.artifactIntegrity
    }
    let inodeSource = URL(filePath: source.inodePath)
    let expectedSHA256 = lease.sha256
    let expectedByteCount = lease.byteCount
    let report = try await withThrowingTaskGroup(of: TimedAttempt.self) { group in
      group.addTask {
        .completed(
          try await inspector.inspect(
            source: inodeSource,
            expectedSourceSHA256: expectedSHA256,
            expectedSourceByteCount: expectedByteCount))
      }
      group.addTask {
        try await Task.sleep(for: .milliseconds(timeoutMs))
        return .timedOut
      }
      guard let first = try await group.next() else {
        throw RuntimeTraceInspectionFailure.invalidReport("missingResult")
      }
      group.cancelAll()
      switch first {
      case .completed(let report): return report
      case .timedOut: throw RuntimeTraceInspectionFailure.timedOut
      }
    }
    do {
      try source.revalidate()
    } catch {
      throw RuntimeTraceInspectionFailure.artifactIntegrity
    }
    return report
  }
}

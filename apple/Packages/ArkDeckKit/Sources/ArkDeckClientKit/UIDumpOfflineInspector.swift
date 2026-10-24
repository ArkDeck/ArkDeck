import CryptoKit
import Foundation

/// Stable failures for the bounded UI dump derivation service.
///
/// The service never reads a path or contacts a device. Its complete input is
/// the immutable Artifact bytes and metadata supplied by a caller after a
/// Runtime read. Keeping validation here gives the App and CLI one owner for
/// the parser identity, input bounds, digest checks, and hit-test refusal.
public enum UIDumpOfflineInspectorError: Error, Equatable, Sendable {
  case invalidSource(String)
  case sourceByteCountMismatch(String)
  case sourceDigestMismatch(String)
  case captureTooLarge(maximumBytes: Int)
  case coordinatesUnverified
}

/// One immutable Artifact used by an offline derivation.
public struct UIDumpOfflineSource: Equatable, Sendable {
  public let artifactID: String
  public let name: String
  public let mediaType: String
  public let sha256: String
  public let byteCount: Int

  public init(
    artifactID: String,
    name: String,
    mediaType: String,
    sha256: String,
    byteCount: Int
  ) throws {
    guard !artifactID.isEmpty, artifactID.utf8.count <= 512,
      !artifactID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      !name.isEmpty, name.utf8.count <= 256,
      !mediaType.isEmpty, mediaType.utf8.count <= 256,
      sha256.count == 64,
      sha256.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }),
      byteCount >= 0
    else { throw UIDumpOfflineInspectorError.invalidSource(name) }
    self.artifactID = artifactID
    self.name = name
    self.mediaType = mediaType
    self.sha256 = sha256
    self.byteCount = byteCount
  }
}

/// Metadata and bytes are bound before parsing. A caller cannot publish the
/// digest of one Artifact while deriving from another byte sequence.
public struct UIDumpOfflineArtifact: Sendable {
  public let source: UIDumpOfflineSource
  public let data: Data

  public init(source: UIDumpOfflineSource, data: Data) throws {
    guard source.byteCount == data.count else {
      throw UIDumpOfflineInspectorError.sourceByteCountMismatch(source.name)
    }
    guard Self.sha256(data) == source.sha256 else {
      throw UIDumpOfflineInspectorError.sourceDigestMismatch(source.name)
    }
    self.source = source
    self.data = data
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public struct UIDumpOfflineCaptureInput: Sendable {
  public let identity: ViewerCaptureIdentity
  public let screenshot: UIDumpOfflineArtifact
  public let tree: UIDumpOfflineArtifact
  public let rawDump: UIDumpOfflineArtifact?
  public let observedFromUTC: String?
  public let observedToUTC: String?

  public init(
    identity: ViewerCaptureIdentity,
    screenshot: UIDumpOfflineArtifact,
    tree: UIDumpOfflineArtifact,
    rawDump: UIDumpOfflineArtifact? = nil,
    observedFromUTC: String? = nil,
    observedToUTC: String? = nil
  ) {
    self.identity = identity
    self.screenshot = screenshot
    self.tree = tree
    self.rawDump = rawDump
    self.observedFromUTC = observedFromUTC
    self.observedToUTC = observedToUTC
  }
}

public struct UIDumpOfflineProvenance: Equatable, Sendable {
  public let kind: String
  public let parser: String
  public let parserVersion: String
  public let observedFromUTC: String?
  public let observedToUTC: String?
  public let sources: [UIDumpOfflineSource]
}

public struct UIDumpOfflineInspection: Sendable {
  public static let schemaVersion = "arkdeck.ui-dump-inspection/1"

  public let schemaVersion: String
  public let provenance: UIDumpOfflineProvenance
  public let capture: ViewerCapture
}

public struct UIDumpOfflineHitTest: Sendable {
  public static let schemaVersion = "arkdeck.ui-dump-hit-test/1"

  public let schemaVersion: String
  public let provenance: UIDumpOfflineProvenance
  public let x: Double
  public let y: Double
  public let node: ViewerNode?
}

/// Versioned local owner for UI dump parsing and coordinate hit testing.
public struct UIDumpOfflineInspector: Sendable {
  public static let parserID = "arkdeck.viewer.ui-dump-parser"
  public static let parserVersion = "1.0.0"
  public static let maximumCaptureBytes = 64 * 1_024 * 1_024

  public static let screenshotArtifactName = "screenshot.png"
  public static let screenshotMediaType = "image/png"
  public static let treeArtifactName = "ui-tree.json"
  public static let treeMediaType = "application/json"
  public static let rawDumpArtifactName = "ui-dump.json"
  public static let rawDumpMediaType = "application/json"

  private let maximumBytes: Int

  public init() {
    maximumBytes = Self.maximumCaptureBytes
  }

  /// A lower-only package test seam. No caller can widen the production
  /// boundary or publish a second supported limit.
  package init(testMaximumCaptureBytes: Int) {
    maximumBytes = max(1, min(testMaximumCaptureBytes, Self.maximumCaptureBytes))
  }

  public func inspect(_ input: UIDumpOfflineCaptureInput) throws -> UIDumpOfflineInspection {
    try requireRole(
      input.screenshot.source,
      name: Self.screenshotArtifactName,
      mediaType: Self.screenshotMediaType)
    try requireRole(
      input.tree.source,
      name: Self.treeArtifactName,
      mediaType: Self.treeMediaType)
    if let rawDump = input.rawDump {
      try requireRole(
        rawDump.source,
        name: Self.rawDumpArtifactName,
        mediaType: Self.rawDumpMediaType)
    }

    let artifacts = [input.screenshot, input.tree] + (input.rawDump.map { [$0] } ?? [])
    guard Set(artifacts.map(\.source.artifactID)).count == artifacts.count else {
      throw UIDumpOfflineInspectorError.invalidSource("duplicateArtifactId")
    }
    var totalBytes = 0
    for artifact in artifacts {
      let sum = totalBytes.addingReportingOverflow(artifact.data.count)
      guard !sum.overflow, sum.partialValue <= maximumBytes else {
        throw UIDumpOfflineInspectorError.captureTooLarge(
          maximumBytes: maximumBytes)
      }
      totalBytes = sum.partialValue
    }

    let capture = try ViewerCaptureParser.parse(
      screenshotData: input.screenshot.data,
      treeData: input.tree.data,
      rawDumpData: input.rawDump?.data,
      identity: input.identity)
    let provenance = UIDumpOfflineProvenance(
      kind: "offlineDerived",
      parser: Self.parserID,
      parserVersion: Self.parserVersion,
      observedFromUTC: input.observedFromUTC,
      observedToUTC: input.observedToUTC,
      sources: artifacts.map(\.source).sorted { lhs, rhs in
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.artifactID < rhs.artifactID
      })
    return UIDumpOfflineInspection(
      schemaVersion: UIDumpOfflineInspection.schemaVersion,
      provenance: provenance,
      capture: capture)
  }

  public func hitTest(
    _ inspection: UIDumpOfflineInspection,
    x: Double,
    y: Double,
    rootIdentity: String? = nil
  ) throws -> UIDumpOfflineHitTest {
    guard x.isFinite, y.isFinite, x >= 0, y >= 0 else {
      throw UIDumpOfflineInspectorError.invalidSource("point")
    }
    guard inspection.capture.coordinatesAreVerified else {
      throw UIDumpOfflineInspectorError.coordinatesUnverified
    }
    return UIDumpOfflineHitTest(
      schemaVersion: UIDumpOfflineHitTest.schemaVersion,
      provenance: inspection.provenance,
      x: x,
      y: y,
      node: ViewerHitTesting.node(
        in: inspection.capture, rootIdentity: rootIdentity, x: x, y: y))
  }

  private func requireRole(
    _ source: UIDumpOfflineSource,
    name: String,
    mediaType: String
  ) throws {
    guard source.name == name, source.mediaType == mediaType else {
      throw UIDumpOfflineInspectorError.invalidSource(source.name)
    }
  }
}

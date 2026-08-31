import ArkDeckCore
import ArkDeckWorkflows
import Foundation

/// §6.2's deterministic local derivation.
///
/// `ui-dump inspect` and `ui-dump hit-test` answer from bytes the Runtime
/// already published, not from the device. §6.2 asks two things of that, and
/// both are properties of the answer rather than of the process, so both are
/// in the document:
///
/// - the parser identity and version, and the digest of every source Artifact
///   the derivation read, so a caller can tell whether two answers came from
///   the same bytes through the same code;
/// - that the result is never passed off as new device evidence. It carries
///   `kind: "offlineDerived"` and the observation window of the capture it was
///   derived from, so "what the screen looked like when this was taken" cannot
///   be read as "what the screen looks like".
///
/// The derivation runs in this process because it is deterministic and
/// touches nothing: the same bytes give the same tree, no device is contacted,
/// and no Runtime state moves. That is what makes it a local derivation rather
/// than an observation, and it is also why it may not claim to be one.
enum CLIOfflineDerivation {

  /// The Viewer parser's published identity.
  ///
  /// It moves when the parse changes what it produces from the same bytes —
  /// which is the only thing a consumer comparing two derivations cares
  /// about. It is stated here rather than derived from the product version so
  /// that a release which does not touch the parser does not look like it did.
  static let uiDumpParser = "arkdeck.viewer.ui-dump-parser"
  static let uiDumpParserVersion = "1.0.0"

  /// One source Artifact, named and pinned.
  struct Source {
    let artifactID: String
    let name: String
    let mediaType: String
    let sha256: String
    let byteCount: Int
  }

  /// The artifact names a `capture.diagnostics@1` UI dump publishes. The tree
  /// is required and the raw dump is not: some providers label an opaque text
  /// window inventory as JSON, and the structured tree stays the source of
  /// truth — an optional compatibility artifact must not be able to invalidate
  /// a capture that is otherwise complete.
  static let treeArtifactName = "ui-tree.json"
  static let rawDumpArtifactName = "ui-dump.json"
  static let screenshotMediaType = "image/png"

  /// Projects the derivation's provenance. Sorted by name so that two runs
  /// over the same job produce the same document.
  static func provenance(sources: [Source], observedFromUTC: String?, observedToUTC: String?)
    -> JSONValue
  {
    .object([
      // The word a consumer branches on. §6.2 forbids a derived result from
      // impersonating device evidence, and a machine reader needs one field
      // to check rather than a convention to remember.
      "kind": .string("offlineDerived"),
      "parser": .string(uiDumpParser),
      "parserVersion": .string(uiDumpParserVersion),
      "observedFromUtc": observedFromUTC.map(JSONValue.string) ?? .null,
      "observedToUtc": observedToUTC.map(JSONValue.string) ?? .null,
      "sources": .array(
        sources.sorted { $0.name < $1.name }.map { source in
          .object([
            "artifactId": .string(source.artifactID),
            "name": .string(source.name),
            "mediaType": .string(source.mediaType),
            "sha256": .string(source.sha256),
            "byteCount": .integer(Int64(source.byteCount)),
          ])
        }),
    ])
  }

  static func encode(node: ViewerNode) -> JSONValue {
    .object([
      "identity": .string(node.identity),
      "deviceId": node.deviceID.map(JSONValue.string) ?? .null,
      "parentIdentity": node.parentIdentity.map(JSONValue.string) ?? .null,
      "children": .array(node.children.map(JSONValue.string)),
      "type": .string(node.type),
      "text": node.text.map(JSONValue.string) ?? .null,
      "inspectorId": node.inspectorID.map(JSONValue.string) ?? .null,
      "bounds": node.bounds.map {
        .object([
          "x": .number($0.x), "y": .number($0.y),
          "width": .number($0.width), "height": .number($0.height),
        ])
      } ?? .null,
      "visible": .bool(node.visible),
      "enabled": node.enabled.map(JSONValue.bool) ?? .null,
      "clickable": node.clickable.map(JSONValue.bool) ?? .null,
      "focusable": node.focusable.map(JSONValue.bool) ?? .null,
      "focused": node.focused.map(JSONValue.bool) ?? .null,
      "clipsChildren": .bool(node.clipsChildren),
      "hitTestBehavior": node.hitTestBehavior.map(JSONValue.string) ?? .null,
      "zIndex": node.zIndex.map(JSONValue.number) ?? .null,
      "depth": .integer(Int64(node.depth)),
    ])
  }

  static func encode(capture: ViewerCapture) -> JSONValue {
    .object([
      "screenshot": .object([
        "width": .integer(Int64(capture.screenshotWidth)),
        "height": .integer(Int64(capture.screenshotHeight)),
      ]),
      // Whether a coordinate in the screenshot maps to a node at all. A
      // capture whose provider did not confirm the mapping still has a
      // readable tree, and hit-testing it would return a node chosen from
      // coordinates nobody verified — so the flag is published and the
      // hit-test refuses rather than guessing.
      "coordinatesAreVerified": .bool(capture.coordinatesAreVerified),
      "roots": .array(capture.roots.map(JSONValue.string)),
      "nodeCount": .integer(Int64(capture.nodes.count)),
      "nodes": .array(capture.nodes.map(encode(node:))),
    ])
  }
}

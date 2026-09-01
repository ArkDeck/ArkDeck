import ArkDeckCore
import ArkDeckWorkflows
import Foundation

/// Machine projection for §6.2's typed deterministic local derivation.
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
/// Parsing, bounds, source binding, and hit testing are owned by
/// `UIDumpOfflineInspector` in ArkDeckWorkflows. This type only translates its
/// typed result to the CLI's canonical JSON vocabulary.
enum CLIOfflineDerivation {
  static func encode(provenance: UIDumpOfflineProvenance) -> JSONValue {
    .object([
      // The word a consumer branches on. §6.2 forbids a derived result from
      // impersonating device evidence, and a machine reader needs one field
      // to check rather than a convention to remember.
      "kind": .string(provenance.kind),
      "parser": .string(provenance.parser),
      "parserVersion": .string(provenance.parserVersion),
      "observedFromUtc": provenance.observedFromUTC.map(JSONValue.string) ?? .null,
      "observedToUtc": provenance.observedToUTC.map(JSONValue.string) ?? .null,
      "sources": .array(
        provenance.sources.map { source in
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

import ArkDeckCore
import ArkDeckWorkflows
import Foundation

/// `arkdeck debug template list`: the closed read-only template set that
/// `debug.template@1` accepts, with what each member runs.
///
/// The set has one owner, `DebugRuntimeCommandTemplate`, which the provider
/// reads when it lowers a Job step and which this projection reads when it
/// answers. The published Catalog descriptor carries the same identities as
/// its `templateId` enum, and the two are compared here on every call: a
/// listing that named a template the Runtime would refuse, or hid one it
/// accepts, is worse than no listing. Nothing here contacts the Runtime or a
/// device; running a template is `debug template run`, a Job like any other.
extension RuntimeCLI {
  static let debugTemplateOperationReference = "debug.template@1"

  static func runDebugTemplateList(_ arguments: [String]) throws {
    var rest = arguments
    var session = runtimeSession(&rest, command: "debug.template.list")
    let options = try CLIOptions(rest)
    try options.validateAllowed([])
    guard let descriptor = RuntimeOperationCatalog.descriptor(
      reference: debugTemplateOperationReference),
      let field = descriptor.inputs.first(where: { $0.name == "templateId" }),
      let published = field.enumValues
    else {
      throw session.fail(
        .internalError, "the Debug template operation is not published in this build's Catalog")
    }
    let templates = DebugRuntimeCommandTemplate.allCases
    guard published == templates.map(\.rawValue) else {
      throw session.fail(
        .internalError,
        "the closed Debug template set drifted from the published Catalog descriptor")
    }
    session.emit(
      .object([
        "schemaVersion": .string("arkdeck.debug-template-list/1"),
        "operation": .string(debugTemplateOperationReference),
        "catalogDigest": .string(RuntimeOperationCatalog.catalogDigest),
        "effect": .string("readOnly"),
        "templates": .array(
          templates.map { template in
            .object([
              "templateId": .string(template.rawValue),
              "title": .string(template.title),
              "effect": .string("readOnly"),
              "remoteCommand": .array(template.remoteCommand.map(JSONValue.string)),
              "outputByteBudget": .integer(Int64(template.outputByteBudget)),
              "inputs": .object(["templateId": .string(template.rawValue)]),
            ])
          }),
      ]))
  }
}

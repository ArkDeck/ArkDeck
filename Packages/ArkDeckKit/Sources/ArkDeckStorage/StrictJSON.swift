import ArkDeckCore
import Foundation

/// The error type ArkDeckStorage's public decode entry points (journal codec,
/// session manifest, capability store, …) surface for strict-JSON rejection.
/// It predates the shared ArkDeckCore validator and is a public commitment of
/// this library product, so consolidation keeps the type and maps into it at
/// the module boundary instead of narrowing it away.
public enum StrictJSONError: Error, Equatable, Sendable {
  case duplicateMemberName(path: String)
  case malformed(String)
}

/// Storage-local spelling of the shared duplicate-key validator. Parsing is
/// ArkDeckCore's single implementation; only the thrown error is re-mapped so
/// existing `catch StrictJSONError` call sites inside and outside this module
/// keep working unchanged.
struct StrictJSONDuplicateValidator {
  private var core: ArkDeckCore.StrictJSONDuplicateValidator

  init(data: Data) {
    core = ArkDeckCore.StrictJSONDuplicateValidator(data: data)
  }

  mutating func validate() throws {
    do {
      try core.validate()
    } catch let error as ArkDeckCore.StrictJSONError {
      switch error {
      case .duplicateMemberName(let path):
        throw StrictJSONError.duplicateMemberName(path: path)
      case .malformed(let reason):
        throw StrictJSONError.malformed(reason)
      }
    }
  }
}

/// Reads only the shape emitted by the current durable model, including nested
/// closed records. Unknown fields and historical optional-field substitutions
/// cannot disappear through Codable's default permissive decoding.
package enum CurrentDurableJSON {
  package static func decode<Value: Codable>(_ type: Value.Type, from data: Data) throws -> Value {
    var duplicateValidator = StrictJSONDuplicateValidator(data: data)
    try duplicateValidator.validate()
    let decoder = JSONDecoder()
    let value = try decoder.decode(type, from: data)
    let supplied = try decoder.decode(JSONValue.self, from: data)
    let current = try decoder.decode(JSONValue.self, from: JSONEncoder().encode(value))
    guard supplied == current else {
      throw StrictJSONError.malformed("record does not match the current durable field shape")
    }
    return value
  }
}

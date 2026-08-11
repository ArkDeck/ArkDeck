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

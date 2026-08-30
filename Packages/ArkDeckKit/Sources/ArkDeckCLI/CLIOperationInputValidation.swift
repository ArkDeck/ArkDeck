import ArkDeckCore
import Foundation

/// A structural check of typed inputs against the descriptor the *daemon*
/// published (§6.1's `operation validate`).
///
/// Two things it deliberately is not.
///
/// It is not a second catalog. The descriptor comes from `operation.describe`
/// rather than from the copy compiled into this binary, because a CLI and a
/// daemon can be different builds — validating against the local copy would
/// tell a caller their inputs are fine while the running Runtime is about to
/// refuse them. The digest that judged the inputs is reported with the answer
/// for the same reason.
///
/// It is not admission. Passing means the document matches the published field
/// contract; the Runtime still validates plan materialization, capability,
/// binding and freshness, and any of those can still refuse. §4 forbids the
/// CLI from re-deriving those rules, so this checks the one thing the
/// descriptor fully describes and says so.
enum CLIOperationInputValidation {

  struct Finding: Equatable {
    let field: String
    let code: String
    let message: String

    var json: JSONValue {
      .object([
        "field": .string(field), "code": .string(code), "message": .string(message),
      ])
    }
  }

  /// `inputs` is the descriptor's published field list, as `operation.describe`
  /// returns it.
  static func findings(for document: JSONValue, against inputs: [JSONValue]) -> [Finding] {
    guard case .object(let supplied) = document else {
      return [
        Finding(
          field: "", code: "notAnObject",
          message: "typed inputs must be a JSON object at the root")
      ]
    }

    var findings: [Finding] = []
    var declaredNames: Set<String> = []

    for descriptor in inputs {
      guard case .object(let field) = descriptor,
        case .string(let name)? = field["name"]
      else { continue }
      declaredNames.insert(name)
      let isRequired = field["required"] == .bool(true)
      guard let value = supplied[name] else {
        if isRequired {
          findings.append(
            Finding(
              field: name, code: "missingRequired",
              message: "\(name) is required and was not supplied"))
        }
        continue
      }
      findings.append(contentsOf: check(value, named: name, against: field))
    }

    // §5.3 makes the input document exact: an unrecognised key is a caller
    // mistake, not decoration to ignore. Reporting it here is the difference
    // between a typo found before dispatch and one found after.
    for name in supplied.keys.sorted() where !declaredNames.contains(name) {
      findings.append(
        Finding(
          field: name, code: "unknownField",
          message: "\(name) is not declared by this operation"))
    }
    return findings
  }

  private static func check(
    _ value: JSONValue, named name: String, against field: [String: JSONValue]
  ) -> [Finding] {
    var findings: [Finding] = []
    guard case .string(let rawType)? = field["type"],
      let type = CatalogFieldType(rawValue: rawType)
    else {
      return []
    }
    if !matches(value, type: type) {
      findings.append(
        Finding(
          field: name, code: "typeMismatch",
          message: "\(name) must be \(rawType)"))
      // Every other check reads the value as its declared type, so once the
      // type is wrong the rest would only restate it.
      return findings
    }

    if case .array(let allowed)? = field["enum"], !allowed.contains(value) {
      let rendered = allowed.compactMap { item -> String? in
        if case .string(let text) = item { return text }
        return nil
      }
      findings.append(
        Finding(
          field: name, code: "notInEnum",
          message: "\(name) must be one of \(rendered.joined(separator: ", "))"))
    }
    if case .string(let pattern)? = field["pattern"], case .string(let text) = value,
      !matches(text, pattern: pattern)
    {
      findings.append(
        Finding(
          field: name, code: "patternMismatch",
          message: "\(name) must match \(pattern)"))
    }
    if case .integer(let number) = value {
      if case .integer(let minimum)? = field["minimum"], number < minimum {
        findings.append(
          Finding(
            field: name, code: "outOfRange", message: "\(name) must be at least \(minimum)"))
      }
      if case .integer(let maximum)? = field["maximum"], number > maximum {
        findings.append(
          Finding(
            field: name, code: "outOfRange", message: "\(name) must be at most \(maximum)"))
      }
    }
    if case .string(let text) = value, case .integer(let maxLength)? = field["maxLength"],
      text.unicodeScalars.count > maxLength
    {
      findings.append(
        Finding(
          field: name, code: "tooLong",
          message: "\(name) must be at most \(maxLength) characters"))
    }
    if case .array(let items) = value, case .integer(let maxItems)? = field["maxItems"],
      items.count > Int(maxItems)
    {
      findings.append(
        Finding(
          field: name, code: "tooManyItems",
          message: "\(name) must have at most \(maxItems) items"))
    }
    return findings
  }

  private static func matches(_ value: JSONValue, type: CatalogFieldType) -> Bool {
    switch type {
    case .string, .artifactLease, .artifactReference:
      if case .string = value { return true }
      return false
    case .integer:
      switch value {
      case .integer, .unsignedInteger: return true
      default: return false
      }
    case .boolean:
      if case .bool = value { return true }
      return false
    case .stringArray, .artifactLeaseArray:
      guard case .array(let items) = value else { return false }
      return items.allSatisfy { if case .string = $0 { return true } else { return false } }
    }
  }

  /// Whole-string match, the way the catalog means a field pattern. An
  /// unanchored search would accept a value that merely contains a match.
  private static func matches(_ text: String, pattern: String) -> Bool {
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      // A pattern this build cannot compile is not a caller error, and
      // reporting it as one would refuse a document the Runtime accepts.
      return true
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = expression.firstMatch(in: text, range: range) else { return false }
    return match.range == range
  }
}

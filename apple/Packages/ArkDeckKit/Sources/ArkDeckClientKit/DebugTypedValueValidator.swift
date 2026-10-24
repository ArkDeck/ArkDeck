import Foundation

/// Conservative App-side validation for the structured HiLog fields. Runtime
/// remains authoritative, but an obviously free-form shell fragment never
/// appears in the UI's typed request preview.
public enum DebugTypedValueValidator {
  public static func isSafeHilogComponent(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 200 else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      CharacterSet.alphanumerics.contains(scalar)
        || "._:-".unicodeScalars.contains(scalar)
    }
  }

  /// Bundle and ability names share the conservative character policy: they
  /// are Catalog-schema identifiers, and nothing that could read as a shell
  /// fragment may appear in a typed request preview.
  public static func isSafeTypedIdentifier(_ value: String) -> Bool {
    isSafeHilogComponent(value)
  }

  public static func isValidBundleName(_ value: String) -> Bool {
    value.count <= 200
      && value.range(
        of: #"^[a-zA-Z][a-zA-Z0-9_]*(?:\.[a-zA-Z][a-zA-Z0-9_]*)+$"#,
        options: .regularExpression) != nil
  }

  public static func isValidAbilityName(_ value: String) -> Bool {
    value.count <= 200
      && value.range(
        of: #"^[a-zA-Z][a-zA-Z0-9_.]*$"#,
        options: .regularExpression) != nil
  }

  public static func isValidNativeLibraryLogicalName(_ value: String) -> Bool {
    value.count <= 128
      && value.range(
        of: #"^lib[A-Za-z0-9_.-]+\.so$"#,
        options: .regularExpression) != nil
  }
}

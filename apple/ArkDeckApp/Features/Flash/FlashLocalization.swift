import Foundation

/// Resolves Flash copy from its dedicated strings catalog instead of the
/// app-wide default table.
func flashText(_ key: String) -> String {
  String(localized: String.LocalizationValue(key), table: "FlashLocalizable")
}

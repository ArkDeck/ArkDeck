import Foundation

/// Resolves Viewer copy from its dedicated strings catalog instead of the
/// app-wide default table.
///
/// The product name `Viewer`, the dump's own field names (`id`, `bounds`,
/// `inspectorId`…), and device-supplied values are deliberately not routed
/// through here: they are identifiers the device publishes, and translating
/// them would make the inspector disagree with the Raw dump beside it.
func viewerText(_ key: String) -> String {
  Bundle.main.localizedString(
    forKey: key,
    value: key,
    table: "UIDumpLocalizable")
}

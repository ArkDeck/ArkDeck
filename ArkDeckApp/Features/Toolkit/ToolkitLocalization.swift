import Foundation

/// Resolves Toolkit copy from its own strings catalog rather than the
/// app-wide default table.
///
/// Device-supplied values — the target identifier, the binding revision, the
/// frame's pixel dimensions, and the verified facts the runtime attested for
/// an injection — are deliberately not routed through here. They are facts
/// the runtime published, and translating them would make the operation log
/// disagree with the evidence it is reporting.
func toolkitText(_ key: String) -> String {
  Bundle.main.localizedString(
    forKey: key,
    value: key,
    table: "ToolkitLocalizable")
}

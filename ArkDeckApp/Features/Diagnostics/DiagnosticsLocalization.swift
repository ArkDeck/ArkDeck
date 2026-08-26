import Foundation

/// Resolves Diagnostics copy from its own strings catalog rather than the
/// app-wide default table.
///
/// Runtime facts — a job identifier, a mark's instant, the milliseconds
/// between a mark and the shutter, the name of a product that went missing —
/// are deliberately not routed through here. Translating them would make the
/// reader disagree with the evidence it is reading.
func diagnosticsText(_ key: String) -> String {
  Bundle.main.localizedString(
    forKey: key,
    value: key,
    table: "DiagnosticsLocalizable")
}

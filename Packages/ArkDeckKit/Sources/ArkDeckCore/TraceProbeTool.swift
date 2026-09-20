// The two trace capture tools a device may offer. The OpenHarmony adapter
// probes for them and the App's trace facade names one of them, so the enum
// is declared here rather than copied on either side
// (docs/ArchitectureRules.md §6 example 1).

package enum TraceProbeTool: String, Equatable, Sendable {
  case hitrace
  case bytrace
}

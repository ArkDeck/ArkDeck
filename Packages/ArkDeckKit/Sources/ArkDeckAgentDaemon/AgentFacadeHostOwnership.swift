import ArkDeckCore
import ArkDeckWorkflows
import Foundation

/// Host-only stores whose installed owner is the paired Rust transport
/// (TASK-XPA-012). The facade answers these methods itself and never forwards
/// them, so an authority composed behind a facade must not open the stores:
/// two processes would otherwise share their locks. A standalone Swift daemon
/// keeps its own owner over the same files and format.
package enum AgentFacadeHostOwnership {
  /// Keep in step with `LOCAL_METHODS` in
  /// `rust/crates/arkdeck-agentd/src/facade_owners.rs`.
  package static let methods: Set<String> = [
    "history.filter.delete", "history.filter.list", "history.filter.save",
  ]

  package static func historyFilterStore(
    stateDirectory: URL, facade: AgentFacadeConfiguration?
  ) -> RuntimeHistoryFilterStore? {
    facade == nil ? RuntimeHistoryFilterStore(rootURL: stateDirectory) : nil
  }
}

import ArkDeckCore
import Foundation

package struct RuntimeHumanActionResourceRow: Sendable, Equatable {
  package let createdAt: String
  package let actionID: String
  package let ownerKind: String
  package let ownerID: String
  package let resumeReference: String
  package let value: JSONValue
}

/// One discovery owner for both physical AgentExecution actions and host-wide
/// control-action approvals. The union gets one snapshot/cursor namespace, so
/// pagination cannot omit one owner or splice pages from different reads.
public actor RuntimeHumanActionResourceCoordinator {
  private let agents: RuntimeAgentExecutionCoordinator?
  private let controls: RuntimeControlActionResourceCoordinator?
  private let pages: RuntimeSnapshotPager

  package init(
    directory: URL, agents: RuntimeAgentExecutionCoordinator?,
    controls: RuntimeHDCControlActionCoordinator?
  ) throws {
    self.agents = agents
    self.controls = try RuntimeControlActionResourceCoordinator(
      directory: directory.appending(path: "control-actions"),
      hdc: controls, tools: nil)
    pages = try RuntimeSnapshotPager(directory: directory)
  }

  package init(
    directory: URL, agents: RuntimeAgentExecutionCoordinator?,
    controlResources: RuntimeControlActionResourceCoordinator?
  ) throws {
    self.agents = agents
    controls = controlResources
    pages = try RuntimeSnapshotPager(directory: directory)
  }

  package func show(_ actionID: String) async throws -> JSONValue {
    guard AgentExecutionIntent.validIdentifier(actionID) else {
      throw AgentExecutionControlFailure("invalidInput", "invalid human-action identity")
    }
    let rows = try await matching(actionID: actionID, resumeReference: nil)
    guard rows.count == 1, let row = rows.first else {
      if rows.isEmpty { throw AgentExecutionControlFailure("resourceNotFound", "human action does not exist") }
      throw AgentExecutionControlFailure("recordUnreadable", "human action has multiple owners")
    }
    return row.value
  }

  package func owner(
    actionID: String?, resumeReference: String
  ) async throws -> RuntimeHumanActionResourceRow? {
    guard AgentExecutionIntent.validIdentifier(resumeReference),
      actionID.map(AgentExecutionIntent.validIdentifier) ?? true
    else { throw AgentExecutionControlFailure("invalidInput", "invalid human-action reference") }
    let rows = try await matching(actionID: actionID, resumeReference: resumeReference)
    guard rows.count <= 1 else {
      throw AgentExecutionControlFailure("recordUnreadable", "human action reference has multiple owners")
    }
    return rows.first
  }

  package func list(
    filters: [String: JSONValue], pageSize: Int, cursor: String?
  ) async throws -> JSONValue {
    guard Set(filters.keys).isSubset(of: ["ownerKind", "owner"]),
      (filters["ownerKind"] == nil) == (filters["owner"] == nil),
      filters["ownerKind"].map({ value in
        value.string.map { ["agentExecution", "controlAction"].contains($0) } == true
      }) ?? true,
      filters["owner"].map({ if case .string(let id) = $0 { return AgentExecutionIntent.validIdentifier(id) }; return false }) ?? true
    else { throw AgentExecutionControlFailure("invalidInput", "invalid human-action owner filter") }
    let ownerKind = filters["ownerKind"]?.string
    let ownerID = filters["owner"]?.string
    var rows: [RuntimeHumanActionResourceRow] = []
    if ownerKind == nil || ownerKind == "agentExecution", let agents {
      rows += try await agents.humanActionResourceRows(ownerID: ownerID)
    }
    if ownerKind == nil || ownerKind == "controlAction", let controls {
      rows += try await controls.humanActionResourceRows(ownerID: ownerID)
    }
    var identities: Set<String> = []
    guard rows.allSatisfy({ identities.insert($0.actionID).inserted }) else {
      throw AgentExecutionControlFailure("recordUnreadable", "human action identity has multiple owners")
    }
    let values = rows.sorted {
      $0.createdAt == $1.createdAt
        ? $0.actionID.utf8.lexicographicallyPrecedes($1.actionID.utf8)
        : $0.createdAt > $1.createdAt
    }.map(\.value)
    return try pages.page(
      method: "human-action.list", filters: filters,
      order: "createdAtDescActionIdAsc", pageSize: pageSize, cursor: cursor
    ) { values }
  }

  private func matching(
    actionID: String?, resumeReference: String?
  ) async throws -> [RuntimeHumanActionResourceRow] {
    var rows: [RuntimeHumanActionResourceRow] = []
    if let agents { rows += try await agents.humanActionResourceRows(ownerID: nil) }
    if let controls { rows += try await controls.humanActionResourceRows(ownerID: nil) }
    return rows.filter {
      (actionID == nil || $0.actionID == actionID)
        && (resumeReference == nil || $0.resumeReference == resumeReference)
    }
  }
}

private extension JSONValue {
  var string: String? { if case .string(let value) = self { return value }; return nil }
}

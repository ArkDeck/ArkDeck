import ArkDeckCore
import Foundation

/// One discovery and routing owner for every durable Runtime control action.
/// Concrete lifecycle coordinators retain their own stores and transition
/// rules; this actor only provides collision-safe union paging and exact-owner
/// routing for generic CLI resources.
public actor RuntimeControlActionResourceCoordinator {
  private let hdc: RuntimeHDCControlActionCoordinator?
  private let tools: RuntimeToolSelectionControlActionCoordinator?
  private let pages: RuntimeSnapshotPager

  package init(
    directory: URL,
    hdc: RuntimeHDCControlActionCoordinator?,
    tools: RuntimeToolSelectionControlActionCoordinator?
  ) throws {
    self.hdc = hdc
    self.tools = tools
    pages = try RuntimeSnapshotPager(directory: directory)
  }

  package func show(_ actionID: String) async throws -> JSONValue {
    let owner = try await actionOwner(actionID)
    switch owner {
    case .hdc: return try await hdc!.show(actionID)
    case .tool: return try await tools!.show(actionID)
    }
  }

  package func reconcile(_ actionID: String) async throws -> JSONValue {
    let owner = try await actionOwner(actionID)
    switch owner {
    case .hdc: return try await hdc!.reconcile(actionID)
    case .tool: return try await tools!.reconcile(actionID)
    }
  }

  package func list(
    filters: [String: JSONValue], pageSize: Int, cursor: String?
  ) async throws -> JSONValue {
    let kinds = ["hdcLifecycle", "runtimeToolSelection"]
    guard Set(filters.keys).isSubset(of: ["kind", "state"]),
      filters["kind"].map({ value in
        if case .string(let kind) = value { return kinds.contains(kind) }
        return false
      }) ?? true,
      filters["state"].map({ value in
        if case .string(let state) = value { return Self.states.contains(state) }
        return false
      }) ?? true
    else {
      throw HDCControlValue.failure(
        "invalidInput", "unsupported control-action discovery filter")
    }
    var values: [JSONValue] = []
    if filters["kind"] == nil || filters["kind"] == .string("hdcLifecycle"), let hdc {
      values += try await hdc.listRecords().map(\.projection)
    }
    if filters["kind"] == nil || filters["kind"] == .string("runtimeToolSelection"), let tools {
      values += try await tools.listRecords().map(\.projection)
    }
    if let state = filters["state"] {
      values = values.filter { value in
        guard case .object(let fields) = value else { return false }
        return fields["state"] == state
      }
    }
    var identities: Set<String> = []
    guard
      values.allSatisfy({ value in
        guard case .object(let fields) = value,
          case .string(let id)? = fields["controlActionId"]
        else { return false }
        return identities.insert(id).inserted
      })
    else {
      throw HDCControlValue.failure(
        "recordUnreadable", "control-action identity has multiple owners")
    }
    values.sort { lhs, rhs in
      let l = Self.sortKey(lhs)
      let r = Self.sortKey(rhs)
      return l.0 == r.0
        ? l.1.utf8.lexicographicallyPrecedes(r.1.utf8)
        : l.0 < r.0
    }
    return try pages.page(
      method: "control-action.list", filters: filters,
      order: "createdAtThenControlActionId", pageSize: pageSize, cursor: cursor
    ) { values }
  }

  package func humanActionResourceRows(
    ownerID: String?
  ) async throws -> [RuntimeHumanActionResourceRow] {
    var rows: [RuntimeHumanActionResourceRow] = []
    if let hdc { rows += try await hdc.humanActionResourceRows(ownerID: ownerID) }
    if let tools { rows += try await tools.humanActionResourceRows(ownerID: ownerID) }
    return rows
  }

  package func issueInteractiveChallenge(
    actionID: String, resumeReference: String
  ) async throws -> JSONValue {
    switch try await humanOwner(actionID: actionID, resumeReference: resumeReference) {
    case .hdc:
      return try await hdc!.issueInteractiveChallenge(
        actionID: actionID, resumeReference: resumeReference)
    case .tool:
      return try await tools!.issueInteractiveChallenge(
        actionID: actionID, resumeReference: resumeReference)
    }
  }

  package func consumeInteractiveChallenge(
    actionID: String, resumeReference: String, response: String
  ) async throws -> JSONValue {
    switch try await actionOwner(actionID) {
    case .hdc:
      return try await hdc!.consumeInteractiveChallenge(
        actionID: actionID, resumeReference: resumeReference, response: response)
    case .tool:
      return try await tools!.consumeInteractiveChallenge(
        actionID: actionID, resumeReference: resumeReference, response: response)
    }
  }

  private enum Owner { case hdc, tool }

  private func actionOwner(_ actionID: String) async throws -> Owner {
    guard HDCControlValue.identifier(actionID) else {
      throw HDCControlValue.failure("invalidInput", "invalid control-action identity")
    }
    var owners: [Owner] = []
    if let hdc, try await hdc.listRecords().contains(where: { $0.actionID == actionID }) {
      owners.append(.hdc)
    }
    if let tools, try await tools.listRecords().contains(where: { $0.actionID == actionID }) {
      owners.append(.tool)
    }
    guard owners.count == 1, let owner = owners.first else {
      if owners.isEmpty {
        throw HDCControlValue.failure("resourceNotFound", "control action does not exist")
      }
      throw HDCControlValue.failure(
        "recordUnreadable", "control-action identity has multiple owners")
    }
    return owner
  }

  private func humanOwner(
    actionID: String, resumeReference: String
  ) async throws -> Owner {
    guard HDCControlValue.identifier(actionID),
      HDCControlValue.identifier(resumeReference)
    else { throw HDCControlValue.failure("invalidInput", "invalid human-action identity") }
    var owners: [Owner] = []
    if let hdc,
      try await hdc.humanActionResourceRows(ownerID: nil).contains(where: {
        $0.actionID == actionID && $0.resumeReference == resumeReference
      })
    {
      owners.append(.hdc)
    }
    if let tools,
      try await tools.humanActionResourceRows(ownerID: nil).contains(where: {
        $0.actionID == actionID && $0.resumeReference == resumeReference
      })
    {
      owners.append(.tool)
    }
    guard owners.count == 1, let owner = owners.first else {
      if owners.isEmpty {
        throw HDCControlValue.failure("resourceNotFound", "human action does not exist")
      }
      throw HDCControlValue.failure(
        "recordUnreadable", "human action has multiple control owners")
    }
    return owner
  }

  private static func sortKey(_ value: JSONValue) -> (String, String) {
    guard case .object(let fields) = value else { return ("", "") }
    return (fields["createdAt"]?.string ?? "", fields["controlActionId"]?.string ?? "")
  }

  private static let states = [
    "observing", "previewReady", "awaitingImpactApproval", "approvalRecorded",
    "dispatchPrepared", "dispatching", "succeeded", "failed",
    "outcomeUnknown", "blocked", "expired", "previewDrifted",
  ]
}

extension JSONValue {
  fileprivate var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }
}

import ArkDeckCore
import ArkDeckRuntime
import Foundation

package struct AgentExecutionBudgetGuard: Sendable {
  let executionID: String
  let lastObserved: Date
  let deadline: Date
  let continuousDeadline: ContinuousClock.Instant
  let now: @Sendable () -> Date?

  func check() throws {
    let details: [String: JSONValue] = [
      "executionId": .string(executionID), "phase": .string("preAdmission"),
      "newDispatchCount": .integer(0),
    ]
    guard let current = now(), current.timeIntervalSince1970.isFinite, current >= lastObserved else {
      throw AgentExecutionControlFailure("orchestrationClockUntrusted", "the orchestration clock moved behind its durable high-water mark", details: details)
    }
    guard current < deadline, ContinuousClock.now < continuousDeadline else {
      throw AgentExecutionControlFailure("orchestrationBudgetExpired", "the durable orchestration deadline has expired", details: details)
    }
  }
}

/// A Runtime resource owner, not an agent decision loop. It resolves one
/// declared typed request, persists physical assistance, and transfers that
/// exact request to the existing Job engine. It cannot author capabilities,
/// supply trusted facts, choose another operation or replay unknown effects.
public actor RuntimeAgentExecutionCoordinator {
  private let store: RuntimeAgentExecutionStore
  private let pages: RuntimeSnapshotPager
  private let engine: RuntimeJobEngine
  private let targets: RuntimeTargetStore
  private let observations: TargetObservationCoordinator
  private let now: @Sendable () -> Date?
  private var continuousDeadlines: [String: ContinuousClock.Instant] = [:]
  private var advancing: [String: (id: UUID, task: Task<JSONValue, Error>)] = [:]
  private var runningJobs: Set<String> = []

  package init(
    directory: URL, engine: RuntimeJobEngine, targets: RuntimeTargetStore,
    observations: TargetObservationCoordinator, now: @escaping @Sendable () -> Date? = { Date() }
  ) throws {
    store = try RuntimeAgentExecutionStore(directory: directory)
    pages = try RuntimeSnapshotPager(directory: directory.appending(path: "snapshots"))
    self.engine = engine
    self.targets = targets
    self.observations = observations
    self.now = now
  }

  private func requireRecord(_ id: String) throws -> RuntimeAgentExecutionRecord {
    guard let record = try store.load(id) else {
      throw AgentExecutionControlFailure("resourceNotFound", "execution does not exist")
    }
    return record
  }

  private func commit(_ record: inout RuntimeAgentExecutionRecord) throws {
    guard record.generation < Int64.max else {
      throw AgentExecutionControlFailure("recordUnreadable", "execution generation exhausted")
    }
    let previous = record.generation
    record.generation += 1
    try store.save(record, expectedGeneration: previous)
  }

  private func guardFor(_ record: RuntimeAgentExecutionRecord) throws -> AgentExecutionBudgetGuard {
    guard let observed = RuntimeAgentTime.parse(record.lastObservedAt),
      let deadline = RuntimeAgentTime.parse(record.deadline), let current = now(),
      current.timeIntervalSince1970.isFinite
    else { throw AgentExecutionControlFailure("orchestrationClockUntrusted", "no trusted orchestration time is available") }
    let continuous: ContinuousClock.Instant
    if let existing = continuousDeadlines[record.intent.executionID] {
      continuous = existing
    } else {
      let remaining = min(Double(record.intent.maximumWaitMilliseconds), max(0, deadline.timeIntervalSince(current) * 1000))
      continuous = ContinuousClock.now.advanced(by: .milliseconds(Int64(remaining.rounded(.down))))
      continuousDeadlines[record.intent.executionID] = continuous
    }
    return AgentExecutionBudgetGuard(
      executionID: record.intent.executionID, lastObserved: observed, deadline: deadline,
      continuousDeadline: continuous, now: now)
  }

  private func observeBudget(_ record: inout RuntimeAgentExecutionRecord) throws -> AgentExecutionBudgetGuard {
    do {
      let budget = try guardFor(record)
      try budget.check()
      guard let current = now(), current.timeIntervalSince1970.isFinite, current >= budget.lastObserved else {
        throw AgentExecutionControlFailure("orchestrationClockUntrusted", "orchestration time is unavailable or moved backwards")
      }
      guard current < budget.deadline, ContinuousClock.now < budget.continuousDeadline else {
        throw AgentExecutionControlFailure("orchestrationBudgetExpired", "the durable orchestration deadline has expired")
      }
      record.lastObservedAt = RuntimeAgentTime.format(current)
      try commit(&record)
      return try guardFor(record)
    } catch let failure as AgentExecutionControlFailure
      where ["orchestrationBudgetExpired", "orchestrationClockUntrusted"].contains(failure.code) {
      record.state = failure.code == "orchestrationBudgetExpired" ? .budgetExpired : .clockUntrusted
      record.failureCode = failure.code
      expireWaitingActions(&record)
      try commit(&record)
      throw failure
    }
  }

  private func expireWaitingActions(_ record: inout RuntimeAgentExecutionRecord) {
    for index in record.actions.indices where record.actions[index].status == "waiting" {
      record.actions[index].status = "expired"
    }
  }

  package func run(_ fields: [String: JSONValue]) async throws -> JSONValue {
    let intent = try AgentExecutionIntent(fields)
    let fingerprint = RuntimeAgentExecutionStore.fingerprint(try intent.canonicalIntent)
    var record: RuntimeAgentExecutionRecord
    if let existing = try store.load(intent.executionID) {
      guard existing.intentFingerprintSHA256 == fingerprint,
        existing.intent.reviewedPlanDigest == intent.reviewedPlanDigest
      else {
        throw AgentExecutionControlFailure("idempotencyConflict", "execution identity already belongs to a different intent or reviewed-plan precondition", details: [
          "executionId": .string(intent.executionID), "phase": .string("preAdmission"), "newDispatchCount": .integer(0),
        ])
      }
      record = existing
    } else {
      try await engine.validateAgentIntent(intent)
      // The engine validation await may have let another caller create this
      // identity. Re-read it before a first publication, preserving conflict
      // precedence and coalescing rather than racing two owner creations.
      if try store.load(intent.executionID) != nil { return try await run(fields) }
      guard let current = now(), current.timeIntervalSince1970.isFinite else {
        throw AgentExecutionControlFailure("orchestrationClockUntrusted", "cannot create execution without trusted time")
      }
      let created = RuntimeAgentTime.format(current)
      guard let createdDate = RuntimeAgentTime.parse(created) else {
        throw AgentExecutionControlFailure("orchestrationClockUntrusted", "orchestration time cannot be represented")
      }
      record = RuntimeAgentExecutionRecord(
        schemaVersion: "arkdeck.runtime-agent-execution/1", intent: intent,
        intentFingerprintSHA256: fingerprint, catalogDigest: RuntimeOperationCatalog.catalogDigest,
        createdAt: created, deadline: RuntimeAgentTime.format(createdDate.addingTimeInterval(Double(intent.maximumWaitMilliseconds) / 1000)),
        lastObservedAt: created, generation: 1, state: .orchestrating,
        target: nil, submissionRequest: nil, jobID: nil, jobState: nil, outcomeUnknown: false,
        failureCode: nil, actions: [])
      try store.save(record, expectedGeneration: nil)
    }
    if let flight = advancing[intent.executionID] { return try await flight.task.value }
    if record.state == .budgetExpired || record.state == .clockUntrusted {
      throw AgentExecutionControlFailure(record.failureCode ?? "recordUnreadable", "execution stopped at its original orchestration budget", details: [
        "executionId": .string(intent.executionID), "phase": .string("preAdmission"), "newDispatchCount": .integer(0),
      ])
    }
    if record.state.isTerminal || record.state == .jobOwned { return try await status(intent.executionID) }
    if record.state == .waitingForHuman {
      _ = try observeBudget(&record)
      return record.projection // Re-entry is not an implicit HAR resume.
    }
    return try await advance(intent.executionID)
  }

  private func advance(_ id: String) async throws -> JSONValue {
    if let flight = advancing[id] { return try await flight.task.value }
    return try await serialize(id) { try await self.drive(id) }
  }

  private func serialize(
    _ id: String, _ action: @escaping @Sendable () async throws -> JSONValue
  ) async throws -> JSONValue {
    let predecessor = advancing[id]?.task
    let flightID = UUID()
    let task = Task {
      if let predecessor { _ = try? await predecessor.value }
      defer { if advancing[id]?.id == flightID { advancing.removeValue(forKey: id) } }
      do { return try await action() }
      catch let error as AgentExecutionControlFailure {
        if ["orchestrationBudgetExpired", "orchestrationClockUntrusted"].contains(error.code) {
          var record = try requireRecord(id)
          if !record.state.isTerminal, record.jobID == nil {
            record.state = error.code == "orchestrationBudgetExpired" ? .budgetExpired : .clockUntrusted
            record.failureCode = error.code
            expireWaitingActions(&record)
            try commit(&record)
          }
        }
        throw error
      }
    }
    advancing[id] = (flightID, task)
    return try await task.value
  }

  private func drive(_ id: String) async throws -> JSONValue {
    var record = try requireRecord(id)
    // Reconcile this gap even after expiry: this read can recover a Job that
    // was already accepted, and cannot create one under an expired budget.
    if let submission = record.submissionRequest,
      let accepted = try await engine.acceptedJobForAgent(submission) {
      record.jobID = accepted.jobID
      record.state = .jobOwned
      try commit(&record)
      startJob(accepted.jobID, executionID: id)
      return record.projection
    }
    var budget = try observeBudget(&record)
    guard record.catalogDigest == RuntimeOperationCatalog.catalogDigest else {
      throw AgentExecutionControlFailure("resourceConflict", "the Catalog changed during orchestration")
    }
    if record.target == nil {
      guard let target = try await resolveTarget(&record, budget: budget) else { return record.projection }
      record.target = target
      try commit(&record)
    }
    budget = try observeBudget(&record)
    if record.submissionRequest == nil {
      record.submissionRequest = try submission(for: record)
      record.state = .creatingJob
      try commit(&record)
    }
    guard let request = record.submissionRequest else {
      throw AgentExecutionControlFailure("recordUnreadable", "execution has no exact submission request")
    }
    let finalBudget = budget
    let accepted: RuntimeJobAcceptance
    do {
      accepted = try await engine.submitForAgent(request, beforeAdmission: { try finalBudget.check() })
    } catch let error as AgentExecutionControlFailure {
      if error.code == "reviewedPlanMismatch" {
        record.state = .failed
        record.failureCode = error.code
        try commit(&record)
      } else { _ = try observeBudget(&record) }
      throw error
    } catch let error as RuntimeJobEngineError {
      // A typed pre-admission rejection is a terminal execution result, not
      // an excuse to re-enter admission with fresh state on the same ID.
      switch error {
      case .idempotencyConflict(let message):
        record.state = .failed
        record.failureCode = "idempotencyConflict"
        try commit(&record)
        throw AgentExecutionControlFailure(
          "idempotencyConflict", message,
          details: [
            "executionId": .string(record.intent.executionID),
            "phase": .string("preAdmission"), "newDispatchCount": .integer(0),
          ])
      case .rejected:
        if try await engine.acceptedJobForAgent(request) == nil {
          record.state = .failed
          record.failureCode = "admissionDenied"
          try commit(&record)
          return record.projection
        }
      default: break
      }
      throw error
    }
    record.jobID = accepted.jobID
    record.state = .jobOwned
    try commit(&record) // No dispatch before the Job identity is durable here.
    startJob(accepted.jobID, executionID: id)
    return record.projection
  }

  private func submission(for record: RuntimeAgentExecutionRecord) throws -> Data {
    guard let target = record.target,
      let operation = RuntimeOperationCatalog.descriptor(reference: record.intent.operationReference)
    else { throw AgentExecutionControlFailure("recordUnreadable", "execution target or operation is unavailable") }
    let seed = RuntimeAgentExecutionStore.fingerprint(Data(record.intent.executionID.utf8))
    let context = try record.intent.clientContext.map {
      try JSONDecoder().decode(RuntimeClientContext.self, from: CanonicalJSONEncoders.canonical().encode($0))
    }
    let request = try RuntimeOperationRequest(
      requestID: record.intent.requestID ?? "agent-request-\(seed)",
      idempotencyKey: record.intent.idempotencyKey ?? "agent-execution-\(seed)",
      target: .init(targetID: target.targetID, expectedBindingRevision: target.bindingRevision),
      operation: .init(id: operation.id, version: operation.version), inputs: record.intent.inputs,
      requestedOutputs: record.intent.requestedOutputs?.compactMap(RuntimeRequestedOutput.init(rawValue:)) ?? [.derivedArtifacts],
      authorization: record.intent.capabilityReference.map { RuntimeCapabilityReference(capabilityID: $0) },
      clientContext: context)
    let bytes = try RuntimeOperationCodec.encodeRequest(request)
    guard let digest = record.intent.reviewedPlanDigest else { return bytes }
    var object = try ControlProtocolNegotiation.decodeObject(bytes, maximumBytes: 4 * 1024 * 1024)
    object["reviewedPlanDigest"] = .string(digest)
    return try CanonicalJSONEncoders.canonical().encode(JSONValue.object(object))
  }

  private func resolveTarget(
    _ record: inout RuntimeAgentExecutionRecord, budget: AgentExecutionBudgetGuard
  ) async throws -> AgentResolvedTarget? {
    guard let descriptor = RuntimeOperationCatalog.descriptor(reference: record.intent.operationReference) else {
      throw AgentExecutionControlFailure("operationUnavailable", "the declared operation is not published")
    }
    if let targetID = record.intent.targetID {
      if descriptor.binding == .none { return AgentResolvedTarget(targetID: targetID, bindingRevision: nil) }
      guard let target = try targets.find(targetID: targetID) else {
        throw AgentExecutionControlFailure("resourceNotFound", "the explicitly requested target is not registered")
      }
      if let expected = record.intent.expectedBindingRevision, expected != target.bindingRevision {
        throw AgentExecutionControlFailure("bindingRevisionStale", "the requested binding revision is no longer current")
      }
      // The exact durable target is already selected. The Job engine must
      // materialize fresh provider facts before admission and every dispatch;
      // forcing HDC-normal discovery here would break a valid Loader target.
      return AgentResolvedTarget(targetID: targetID, bindingRevision: target.bindingRevision)
    }
    if descriptor.binding == .none, case .string(let project)? = record.intent.inputs["projectRef"],
      AgentExecutionIntent.validIdentifier(project) {
      // A registered host workspace is an existing typed scope. The provider
      // resolves/validates that registration; no synthetic host ID is made.
      return AgentResolvedTarget(targetID: project, bindingRevision: nil)
    }
    let snapshot = try await observations.snapshot()
    try budget.check()
    return try await resolveSnapshot(snapshot, record: &record, budget: budget)
  }

  private func resolveSnapshot(
    _ snapshot: TargetObservationSnapshot, record: inout RuntimeAgentExecutionRecord,
    budget: AgentExecutionBudgetGuard, selected: AgentObservedCandidate? = nil
  ) async throws -> AgentResolvedTarget? {
    let rows = snapshot.observations
    if rows.isEmpty {
      try raiseAction(.connectDevice, record: &record, snapshot: snapshot)
      return nil
    }
    let row: TargetDeviceObservation
    if let selected {
      guard let match = rows.first(where: { $0.observationID == selected.observationID && $0.candidate.connectKey == selected.candidate }),
        match.relation != nil else {
        try raiseAction(.selectDevice, record: &record, snapshot: snapshot)
        return nil
      }
      row = match
    } else if rows.count == 1 {
      row = rows[0]
    } else {
      try raiseAction(.selectDevice, record: &record, snapshot: snapshot)
      return nil
    }
    let reference = AgentObservedCandidate(row, generation: snapshot.generation)
    guard row.candidate.state == "Connected" else {
      try raiseAction(row.candidate.state == "Unauthorized" ? .trustDevice : .connectDevice,
        record: &record, snapshot: snapshot, observation: reference)
      return nil
    }
    guard row.relation != nil else {
      throw AgentExecutionControlFailure("admissionDenied", "the Runtime cannot prove the candidate's physical identity")
    }
    let target = try await observations.adopt(reference.reference, beforeCommit: { try budget.check() })
    try budget.check()
    if let fixed = record.target, target.targetID != fixed.targetID {
      throw AgentExecutionControlFailure("factsDrifted", "physical assistance cannot select a different resolved target")
    }
    let binding = RuntimeOperationCatalog.descriptor(reference: record.intent.operationReference)?.binding
    return AgentResolvedTarget(targetID: target.targetID, bindingRevision: binding == .some(.none) ? nil : target.bindingRevision)
  }

  private func raiseAction(
    _ kind: AgentPhysicalActionKind, record: inout RuntimeAgentExecutionRecord,
    snapshot: TargetObservationSnapshot, observation: AgentObservedCandidate? = nil
  ) throws {
    let choices = kind == .selectDevice ? snapshot.observations.map {
      AgentObservedCandidate($0, generation: snapshot.generation)
    } : []
    if let current = record.waitingAction, current.kind == kind,
      current.observation == observation, current.selections.map(\.observation) == choices {
      return // An unsatisfied probe does not manufacture a new action/token.
    }
    guard record.actions.count < 128 else {
      throw AgentExecutionControlFailure("operationUnavailable", "the bounded physical-assistance history is exhausted")
    }
    expireWaitingActions(&record)
    record.actions.append(RuntimeAgentHumanAction(
      actionID: "har-\(UUID().uuidString.lowercased())", executionID: record.intent.executionID,
      resumeReference: "resume-\(UUID().uuidString.lowercased())", kind: kind,
      createdAt: record.lastObservedAt, expiresAt: record.deadline, status: "waiting",
      resolvedSelection: nil, observation: observation,
      selections: choices.map { AgentCandidateSelection(reference: "candidate-\(UUID().uuidString.lowercased())", observation: $0) }))
    record.state = .waitingForHuman
    try commit(&record)
  }

  private func findAction(_ reference: String, actionID: String?) throws -> (String, String) {
    guard AgentExecutionIntent.validIdentifier(reference) else {
      throw AgentExecutionControlFailure("invalidInput", "invalid resume reference")
    }
    var found: (String, String)?
    try store.forEachRecord { record in
      for action in record.actions where action.resumeReference == reference && (actionID == nil || actionID == action.actionID) {
        guard found == nil else { throw AgentExecutionControlFailure("recordUnreadable", "resume reference has multiple owners") }
        found = (record.intent.executionID, action.actionID)
      }
    }
    guard let found else { throw AgentExecutionControlFailure("resourceNotFound", "human action does not exist") }
    return found
  }

  package func resume(reference: String, actionID: String? = nil, selection: JSONValue? = nil) async throws -> JSONValue {
    let (owner, action) = try findAction(reference, actionID: actionID)
    return try await serialize(owner) {
      try await self.resumeOwned(owner, actionID: action, reference: reference, selection: selection)
    }
  }

  private func resumeOwned(_ id: String, actionID: String, reference: String, selection: JSONValue?) async throws -> JSONValue {
    var record = try requireRecord(id)
    guard let index = record.actions.firstIndex(where: { $0.actionID == actionID && $0.resumeReference == reference }) else {
      throw AgentExecutionControlFailure("resourceNotFound", "human action is not owned by this execution")
    }
    let action = record.actions[index]
    guard action.status != "expired" else {
      throw AgentExecutionControlFailure("humanActionExpired", "the exact human action expired")
    }
    let choice: AgentCandidateSelection?
    if action.kind == .selectDevice {
      guard case .string(let value)? = selection,
        let selected = action.selections.first(where: { $0.reference == value }) else {
        throw AgentExecutionControlFailure("invalidInput", "selection must be an opaque value from this action's schema")
      }
      choice = selected
    } else {
      guard selection == nil else { throw AgentExecutionControlFailure("invalidInput", "this physical action accepts no selection") }
      choice = nil
    }
    if action.status == "resolvedByFreshProbe" {
      guard action.resolvedSelection == choice?.reference else {
        throw AgentExecutionControlFailure("idempotencyConflict", "resolved human action selection changed")
      }
      return try await status(id)
    }
    guard record.state == .waitingForHuman, record.waitingAction?.actionID == actionID else {
      throw AgentExecutionControlFailure("humanActionExpired", "this action is no longer the execution's waiting action")
    }
    guard record.catalogDigest == RuntimeOperationCatalog.catalogDigest else {
      throw AgentExecutionControlFailure("resourceConflict", "the Catalog changed during physical assistance")
    }
    let budget: AgentExecutionBudgetGuard
    do { budget = try observeBudget(&record) }
    catch let error as AgentExecutionControlFailure where error.code == "orchestrationBudgetExpired" {
      throw AgentExecutionControlFailure("humanActionExpired", "the human-action deadline expired", details: error.details)
    }
    let selected = choice?.observation ?? action.observation
    // A physical reconnect deliberately invalidates the old USB attachment
    // observation. Following that stale observation would turn a successful
    // reconnect into an identity-selection HAR even when the fresh probe has
    // exactly one independently related candidate. Start a new observation
    // chain for connectDevice; resolveSnapshot still requires the fresh USB
    // relation, direct identity readback and target-store adoption before the
    // action can be marked resolved. Trust and explicit-selection actions keep
    // following their exact observation so a replaced attachment cannot
    // inherit either authority.
    let selectedForResolution = action.kind == .connectDevice ? nil : selected
    let snapshot: TargetObservationSnapshot
    do {
      snapshot = try await observations.snapshot(following: selectedForResolution?.reference)
      if action.kind == .selectDevice, let selected, snapshot.generation != selected.generation {
        throw TargetObservationFailure("resourceConflict", "candidate selection generation changed")
      }
    } catch let failure as TargetObservationFailure where failure.code == "resourceConflict" {
      // Restart, lost relation or reused key cannot inherit old selection
      // authority. Publish fresh choices, without auto-selecting even one.
      let fresh = try await observations.snapshot()
      try budget.check()
      try raiseAction(fresh.observations.isEmpty ? .connectDevice : .selectDevice, record: &record, snapshot: fresh)
      return record.projection
    }
    try budget.check()
    guard let target = try await resolveSnapshot(
      snapshot, record: &record, budget: budget, selected: selectedForResolution
    ) else {
      return record.projection
    }
    // The original action becomes resolved only after the exact fresh probe
    // and adoption succeed; submitting a token alone proves nothing physical.
    record.actions[index].status = "resolvedByFreshProbe"
    record.actions[index].resolvedSelection = choice?.reference
    record.target = target
    record.state = .orchestrating
    try commit(&record)
    return try await drive(id)
  }

  private func startJob(_ jobID: String, executionID: String) {
    guard runningJobs.insert(jobID).inserted else { return }
    Task {
      do { _ = try await engine.run(jobID: jobID) } catch { /* Read the owner; never infer cancellation or replay. */ }
      await finishJob(jobID, executionID: executionID)
    }
  }

  private func finishJob(_ jobID: String, executionID: String) async {
    defer { runningJobs.remove(jobID) }
    do {
      let status = try await engine.status(jobID: jobID)
      var record = try requireRecord(executionID)
      guard record.jobID == jobID else { return }
      record.jobState = status.state
      record.outcomeUnknown = status.outcomeUnknown
      record.state = JobState(rawValue: status.state)?.isTerminal == true ? .completed : .jobOwned
      try commit(&record)
    } catch {
      // A lost publication is recoverable by status reading the exact Job.
      // In particular, this cannot turn an unknown effect into a failure.
    }
  }

  package func status(_ id: String) async throws -> JSONValue {
    var record = try requireRecord(id)
    if !record.state.isTerminal, record.jobID == nil,
      let submission = record.submissionRequest,
      let accepted = try await engine.acceptedJobForAgent(submission) {
      record.jobID = accepted.jobID // Read-only recovery of a lost creation receipt.
      record.state = .jobOwned
    }
    if let jobID = record.jobID {
      let status = try await engine.status(jobID: jobID)
      record.jobState = status.state
      record.outcomeUnknown = status.outcomeUnknown
      record.state = JobState(rawValue: status.state)?.isTerminal == true ? .completed : .jobOwned
    }
    return record.projection
  }

  package func list(
    filters: [String: JSONValue], pageSize: Int, cursor: String?
  ) throws -> JSONValue {
    guard Set(filters.keys).isSubset(of: ["state", "operation", "target"]),
      filters.allSatisfy({ key, value in
        guard case .string(let text) = value else { return false }
        if key == "state" { return AgentExecutionState(rawValue: text) != nil }
        if key == "target" { return AgentExecutionIntent.validIdentifier(text) }
        return (1...128).contains(text.utf8.count)
      }) else { throw AgentExecutionControlFailure("invalidInput", "invalid execution list filter") }
    return try pages.page(
      method: "agent.list", filters: filters, order: "createdAtDescExecutionIdAsc",
      pageSize: pageSize, cursor: cursor
    ) {
      var rows: [(date: String, id: String, value: JSONValue)] = []
      try store.forEachRecord { record in
        if let state = filters["state"], state != .string(record.state.rawValue) { return }
        if let operation = filters["operation"], operation != .string(record.intent.operationReference) { return }
        if let target = filters["target"], target != record.target.map({ .string($0.targetID) }) { return }
        guard case .object(var value) = record.projection else { return }
        value.removeValue(forKey: "humanAction") // Selection and inputs are never list metadata.
        rows.append((record.createdAt, record.intent.executionID, .object(value)))
      }
      return rows.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }.map(\.value)
    }
  }

  package func humanAction(_ id: String) throws -> JSONValue {
    guard AgentExecutionIntent.validIdentifier(id) else {
      throw AgentExecutionControlFailure("invalidInput", "invalid human-action identity")
    }
    var found: JSONValue?
    try store.forEachRecord { record in
      for action in record.actions where action.actionID == id {
        guard found == nil else { throw AgentExecutionControlFailure("recordUnreadable", "human action has multiple owners") }
        found = action.projection
      }
    }
    guard let found else { throw AgentExecutionControlFailure("resourceNotFound", "human action does not exist") }
    return found
  }

  package func humanActionResourceRows(
    ownerID: String?
  ) throws -> [RuntimeHumanActionResourceRow] {
    if let ownerID, !AgentExecutionIntent.validIdentifier(ownerID) {
      throw AgentExecutionControlFailure("invalidInput", "invalid human-action owner")
    }
    var rows: [RuntimeHumanActionResourceRow] = []
    try store.forEachRecord { record in
      guard ownerID == nil || ownerID == record.intent.executionID else { return }
      rows += record.actions.map { action in
        RuntimeHumanActionResourceRow(
          createdAt: action.createdAt, actionID: action.actionID,
          ownerKind: "agentExecution", ownerID: record.intent.executionID,
          resumeReference: action.resumeReference, value: action.projection)
      }
    }
    return rows
  }

  package func humanActions(
    filters: [String: JSONValue], pageSize: Int, cursor: String?
  ) throws -> JSONValue {
    guard filters.isEmpty || Set(filters.keys) == ["ownerKind", "owner"],
      filters["ownerKind"] == nil || filters["ownerKind"] == .string("agentExecution") else {
      throw AgentExecutionControlFailure("invalidInput", "this owner publishes only AgentExecution physical actions")
    }
    if let owner = filters["owner"] {
      guard case .string(let id) = owner, AgentExecutionIntent.validIdentifier(id) else {
        throw AgentExecutionControlFailure("invalidInput", "invalid human-action owner")
      }
    }
    return try pages.page(
      method: "human-action.list", filters: filters, order: "createdAtDescActionIdAsc",
      pageSize: pageSize, cursor: cursor
    ) {
      var rows: [(date: String, id: String, value: JSONValue)] = []
      try store.forEachRecord { record in
        if let owner = filters["owner"], owner != .string(record.intent.executionID) { return }
        for action in record.actions {
          guard case .object(var value) = action.projection else { continue }
          value.removeValue(forKey: "selectionSchema")
          value.removeValue(forKey: "choices")
          rows.append((action.createdAt, action.actionID, .object(value)))
        }
      }
      return rows.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }.map(\.value)
    }
  }

  package func abandon(_ id: String, expectedGeneration: Int64) async throws -> JSONValue {
    // Creation and abandonment are serialized under the same owner, including
    // the asynchronous Job admission window. This never calls job.cancel.
    try await serialize(id) { try await self.abandonOwned(id, expectedGeneration: expectedGeneration) }
  }

  private func abandonOwned(_ id: String, expectedGeneration: Int64) async throws -> JSONValue {
    var record = try requireRecord(id)
    if let submission = record.submissionRequest,
      let accepted = try await engine.acceptedJobForAgent(submission) {
      throw AgentExecutionControlFailure("resourceConflict", "execution already owns a Job; use explicit job cancel", details: ["jobId": .string(accepted.jobID)])
    }
    if let jobID = record.jobID {
      throw AgentExecutionControlFailure("resourceConflict", "execution already owns a Job", details: ["jobId": .string(jobID)])
    }
    guard expectedGeneration > 0, record.generation == expectedGeneration else {
      throw AgentExecutionControlFailure("resourceConflict", "execution generation changed")
    }
    if !record.state.isTerminal {
      record.state = .abandoned
      expireWaitingActions(&record)
      try commit(&record)
    }
    return record.projection
  }
}

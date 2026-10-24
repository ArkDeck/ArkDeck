
/// The Overview capability matrix proves its hidumper row by running the Debug
/// workspace's read-only `windowInventory` template as a `debug.template@1`
/// Job. The typed Runtime request for it (Catalog reference, expected binding
/// revision, workspace thread, idempotency key) is still built beside the Debug
/// facade, so the App composes this runner into the ClientKit Overview facade.
/// It answers only the terminal facts that row renders, read the way the Debug
/// workspace reads them.
public struct DebugWindowInventoryJobRunner: OverviewWindowInventoryJobRunning {
  private let send: DebugTemplateJobSubmission.Request

  public init() {
    self.init(send: { await DebugXPCReadTransport.request(method: $0, params: $1) })
  }

  /// Test seam: the Runtime requests this runner makes, answered in-process.
  package init(send: @escaping DebugTemplateJobSubmission.Request) {
    self.send = send
  }

  public func runWindowInventory(
    targetID: String, bindingRevision: Int
  ) async -> OverviewWindowInventoryJobResult {
    switch await DebugTemplateJobExecution.run(
      targetID: targetID,
      bindingRevision: bindingRevision,
      templateID: DebugRuntimeCommandTemplate.windowInventory.rawValue,
      send: send)
    {
    case .completed(let terminal):
      return .completed(
        jobID: terminal.jobID, state: terminal.state, outcomeUnknown: terminal.outcomeUnknown)
    case .failed(let failure):
      return .failed(failure)
    }
  }
}

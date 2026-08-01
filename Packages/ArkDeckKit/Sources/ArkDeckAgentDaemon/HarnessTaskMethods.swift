// `task.*` wire adapter (CHG-2026-054, TASK-HTP-001).
//
// Harness policy, request decoding, budgets, and result projection live in
// ArkDeckHarness. The daemon owns only wire framing and the injection of the
// platform's typed application-reference validator.

import ArkDeckHarness
import ArkDeckWorkflows

extension RuntimeControlPlaneHandler {
  func handleTaskMethod(
    _ method: String,
    _ request: AgentWireProtocol.Request
  ) async -> AgentWireProtocol.Response {
    guard let harnessCoordinator else {
      return failure(
        id: request.id, code: .rejected,
        message: "harness task plane is not configured in this composition")
    }

    let service = HarnessTaskMethodService(
      coordinator: harnessCoordinator,
      applicationReferenceValidator: { bundleName, abilityName in
        let bundle = try HDCBundleReference(bundleName: bundleName)
        if let abilityName {
          _ = try HDCAbilityReference(bundle: bundle, abilityName: abilityName)
        }
      })
    let response = await service.handle(
      method, requestID: request.id, params: request.params)

    if let errorCode = response.errorCode {
      return failure(
        id: response.id,
        code: Self.daemonErrorCode(for: errorCode),
        message: response.errorMessage ?? "harness request failed")
    }
    guard let result = response.result else {
      return failure(
        id: response.id, code: .internalError,
        message: "harness request returned neither a result nor an error")
    }
    return success(id: response.id, result: result)
  }

  private static func daemonErrorCode(
    for code: HarnessTaskMethodErrorCode
  ) -> AgentDaemonErrorCode {
    switch code {
    case .unknownMethod: .unknownMethod
    case .invalidParams: .invalidParams
    case .rejected: .rejected
    case .notFound: .notFound
    case .internalError: .internalError
    }
  }
}

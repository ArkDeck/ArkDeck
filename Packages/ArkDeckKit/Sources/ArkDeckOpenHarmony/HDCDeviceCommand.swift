import ArkDeckCore
import Foundation

package enum HDCDeviceCommandError: Error, Equatable, Sendable {
  case unsupportedStepKind(WorkflowStepKind)
  case unsupportedProviderDefinedReboot
  case invalidTypedStepArguments
  case bindingReferenceMismatch
  case connectKeyMissing
  case syntheticBindingRejected
}

/// An HDC command intent whose argv is derived only from the enclosed typed
/// WorkflowStep. No caller-provided argv surface exists.
package struct HDCDeviceCommandIntent: Equatable, Sendable {
  package let step: WorkflowStep
  package let bindingReference: DeviceBindingReference
  package let commandArguments: [String]

  package init(
    step: WorkflowStep,
    bindingReference: DeviceBindingReference
  ) throws {
    self.step = step
    self.bindingReference = bindingReference
    commandArguments = try Self.typedCommandArguments(for: step)
  }

  private static func typedCommandArguments(for step: WorkflowStep) throws -> [String] {
    switch step.kind {
    case .rebootDevice:
      guard case .string(let targetMode)? = step.arguments["targetMode"] else {
        throw HDCDeviceCommandError.invalidTypedStepArguments
      }
      switch targetMode {
      case "normal":
        return ["shell", "reboot"]
      case "recovery", "updater":
        return ["shell", "reboot", targetMode]
      case "providerDefined":
        throw HDCDeviceCommandError.unsupportedProviderDefinedReboot
      default:
        throw HDCDeviceCommandError.invalidTypedStepArguments
      }
    default:
      throw HDCDeviceCommandError.unsupportedStepKind(step.kind)
    }
  }
}

/// Minted by the journal adapter only after the exact typed step intent has
/// crossed the locked journal durability barrier.
package struct DurableHDCDeviceCommandIntent: Equatable, Sendable {
  package let journalIntentEventID: String
  package let intent: HDCDeviceCommandIntent

  package init(
    journalIntentEventID: String,
    intent: HDCDeviceCommandIntent
  ) throws {
    guard !journalIntentEventID.isEmpty else {
      throw HDCDeviceCommandError.invalidTypedStepArguments
    }
    self.journalIntentEventID = journalIntentEventID
    self.intent = intent
  }
}

package struct HDCDeviceCommand: Equatable, Sendable {
  package let journalIntentEventID: String
  package let stepID: String
  package let bindingReference: DeviceBindingReference
  package let arguments: [String]
}

package enum HDCDeviceCommandMaterializer {
  package static func materialize(
    _ durableIntent: DurableHDCDeviceCommandIntent,
    from currentBinding: DurableCurrentDeviceBinding
  ) throws -> HDCDeviceCommand {
    guard durableIntent.intent.bindingReference == currentBinding.reference else {
      throw HDCDeviceCommandError.bindingReferenceMismatch
    }
    guard currentBinding.binding.transport != .synthetic else {
      throw HDCDeviceCommandError.syntheticBindingRejected
    }
    guard let connectKey = currentBinding.binding.connectKey, !connectKey.isEmpty else {
      throw HDCDeviceCommandError.connectKeyMissing
    }
    return HDCDeviceCommand(
      journalIntentEventID: durableIntent.journalIntentEventID,
      stepID: durableIntent.intent.step.id,
      bindingReference: durableIntent.intent.bindingReference,
      arguments: ["-t", connectKey] + durableIntent.intent.commandArguments)
  }
}

package struct HDCDeviceCommandDispatchReceipt: Equatable, Sendable {
  package let journalIntentEventID: String
  package let stepID: String
  package let bindingReference: DeviceBindingReference
  package let actualArguments: [String]
}

package protocol HDCDeviceCommandDispatching: Sendable {
  func dispatch(_ command: HDCDeviceCommand) async throws -> HDCDeviceCommandDispatchReceipt
}

/// The executor is package-scoped so product callers cannot replace the
/// journal-backed authority with a caller-declared current binding or identity.
package protocol HDCDeviceCommandExecuting: Sendable {
  func dispatchAuthorized(
    _ durableIntent: DurableHDCDeviceCommandIntent,
    using dispatcher: any HDCDeviceCommandDispatching
  ) async throws -> HDCDeviceCommandDispatchReceipt
}

package enum HDCDeviceCommandExecutionGate {
  package static func dispatch(
    _ durableIntent: DurableHDCDeviceCommandIntent,
    through executor: any HDCDeviceCommandExecuting,
    using dispatcher: any HDCDeviceCommandDispatching
  ) async throws -> HDCDeviceCommandDispatchReceipt {
    try await executor.dispatchAuthorized(durableIntent, using: dispatcher)
  }
}

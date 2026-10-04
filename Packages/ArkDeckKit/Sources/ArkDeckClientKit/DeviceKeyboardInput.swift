import ArkDeckCore
import Foundation

public enum DeviceKeyboardKey: String, CaseIterable, Sendable {
  case enter, backspace, tab, escape, arrowUp, arrowDown, arrowLeft, arrowRight, home, back
}

public enum DeviceKeyboardCommand: Sendable {
  case key(DeviceKeyboardKey)
  case text(String, allowDeviceClipboard: Bool)

  public var isValid: Bool {
    switch self {
    case .key: return true
    case .text(let text, let allowed):
      return allowed && !text.isEmpty && text.utf8.count <= 512
        && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
  }

  /// Used only by the private upload channel, never by Job request encoding.
  package func privatePayload() throws -> Data {
    guard isValid else {
      throw AgentExecutionControlFailure("invalidInput", "Keyboard input requires bounded text and clipboard consent")
    }
    let value: [String: JSONValue]
    switch self {
    case .key(let key): value = ["kind": .string("key"), "key": .string(key.rawValue)]
    case .text(let text, let allowed):
      value = ["kind": .string("text"), "text": .string(text), "allowDeviceClipboard": .bool(allowed)]
    }
    return try JSONEncoder().encode(value)
  }
}

public extension DeviceControlFacade {
  static func keyboardRequest(
    lease: String, inputEpochUTC: String, target: DeviceTargetPresentation, nonce: String
  ) throws -> RuntimeOperationRequest {
    try RuntimeOperationRequest(
      requestID: "toolkit-keyboard-\(nonce)", idempotencyKey: "toolkit-keyboard-\(nonce)",
      target: DurableTargetReference(targetID: target.id, expectedBindingRevision: target.bindingRevision),
      operation: RuntimeOperationReference(id: "input.keyboard", version: 1),
      inputs: ["keyboardArtifactLease": .string(lease), "inputEpochUtc": .string(inputEpochUTC)],
      requestedOutputs: [.hardwareEvidence],
      clientContext: RuntimeWorkspaceThread.clientContext(
        clientName: ArkDeckAgentClientName.deviceControl, targetID: target.id))
  }
}

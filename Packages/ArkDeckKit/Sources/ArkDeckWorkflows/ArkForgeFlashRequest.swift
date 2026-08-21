import ArkDeckCore

/// Converts the compatibility request shape into the one ArkForge
/// implementation shape. The caller-facing request and durable record are not
/// rewritten; this projection exists only for plan materialization/execution.
package enum ArkForgeFlashRequest {
  package static func canonicalInputs(
    submittedReference: String,
    inputs: [String: JSONValue]
  ) throws -> [String: JSONValue] {
    guard ArkForgeFlashOperation.contains(submittedReference) else { return inputs }
    if submittedReference == ArkForgeFlashOperation.canonicalReference {
      return inputs
    }

    guard
      case .string(let lease)? = inputs["imageBundleLease"], !lease.isEmpty,
      case .string(let profileReference)? = inputs["deviceProfile"],
      let profile = RockchipFlashProfile.profile(reference: profileReference),
      case .array(let rawPartitions)? = inputs["partitionPlan"]
    else {
      throw DeviceProviderError.unsupportedAction(
        "legacy Flash alias inputs cannot be converted to the canonical full-restore request")
    }
    let partitions = try rawPartitions.map { value -> String in
      guard case .string(let partition) = value else {
        throw DeviceProviderError.unsupportedAction(
          "legacy partitionPlan contains a non-string value")
      }
      return partition
    }
    guard partitions == profile.mappedPartitions.map(\.partitionName) else {
      throw DeviceProviderError.unsupportedAction(
        "legacy partitionPlan must exactly match the selected published profile")
    }
    let verification = inputs["postFlashVerification"] ?? .string("full")
    return [
      "artifactLease": .string(lease),
      "deviceProfileRef": .string(profileReference),
      "intent": .string("fullRestore"),
      "verification": verification,
    ]
  }

  package static func artifactLeaseID(
    submittedReference: String,
    inputs: [String: JSONValue]
  ) -> String? {
    let name = submittedReference == ArkForgeFlashOperation.canonicalReference
      ? "artifactLease" : "imageBundleLease"
    guard case .string(let lease)? = inputs[name], !lease.isEmpty else { return nil }
    return lease
  }

  package static func profileReference(
    submittedReference: String,
    inputs: [String: JSONValue]
  ) -> String? {
    let name = submittedReference == ArkForgeFlashOperation.canonicalReference
      ? "deviceProfileRef" : "deviceProfile"
    guard case .string(let reference)? = inputs[name], !reference.isEmpty else { return nil }
    return reference
  }
}

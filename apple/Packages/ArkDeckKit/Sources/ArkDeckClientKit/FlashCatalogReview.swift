import ArkDeckCore
import Foundation

/// Reads the Rust-generated, target-independent review document. This value
/// describes the default selection only; it cannot materialize or admit a Job.
struct FlashCatalogReview: Decodable, Sendable {
  struct Step: Decodable, Sendable {
    let stepId: String
    let kind: String
    let effect: String
    let cancellation: String
    let binding: String
    let optional: Bool
    let executionOwner: String
  }

  let schemaVersion: String
  let catalogDigest: String
  let operation: String
  let providerId: String
  let selectionInputs: [String: JSONValue]
  let steps: [Step]
  let stepSetDigestSHA256: String
  let jobAdmitted: Bool
  let dispatchDisposition: String

  static func decode(_ data: Data) -> Self? {
    guard let review = try? JSONDecoder().decode(Self.self, from: data),
      review.schemaVersion == "arkdeck.catalog-review/1",
      review.catalogDigest == RuntimeOperationCatalog.catalogDigest,
      review.operation == ArkForgeFlashOperation.canonicalReference,
      review.providerId == "arkforge",
      review.selectionInputs == ["verification": .string("full")],
      !review.jobAdmitted, review.dispatchDisposition == "notDispatched",
      SHA256Hex.isLowercaseSHA256(review.stepSetDigestSHA256),
      !review.steps.isEmpty,
      Set(review.steps.map(\.stepId)).count == review.steps.count,
      let descriptor = RuntimeOperationCatalog.descriptor(reference: review.operation)
    else { return nil }
    // Validate vocabulary and descriptor identity without selecting steps or
    // recomputing Runtime's digest on the client.
    for step in review.steps {
      guard let published = descriptor.steps.first(where: { $0.stepID == step.stepId }),
        published.kind.rawValue == step.kind,
        published.effect.rawValue == step.effect,
        published.cancellation.rawValue == step.cancellation,
        published.binding.rawValue == step.binding,
        published.isOptional == step.optional,
        ["arkforgeLane", "runtimeHost"].contains(step.executionOwner)
      else { return nil }
    }
    let selectedIDs = Set(review.steps.map(\.stepId))
    guard descriptor.steps.filter({ !$0.isOptional }).allSatisfy({ selectedIDs.contains($0.stepID) }),
      descriptor.steps.filter({ selectedIDs.contains($0.stepID) }).map(\.stepID)
        == review.steps.map(\.stepId)
    else { return nil }
    return review
  }
}

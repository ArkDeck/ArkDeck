/// The one public identity policy for the ArkForge full-restore operation.
///
/// Durable records retain the submitted reference. Consumers call this type
/// only to select the canonical implementation; they do not rewrite history.
public enum ArkForgeFlashOperation {
  public static let canonicalReference = "flash.full-restore@1"
  public static let compatibilityAliases: Set<String> = ["flash.dayu200"]
  private static let legacyDurableReferences: Set<String> = ["flash.dayu200@1"]

  public static func contains(_ reference: String) -> Bool {
    reference == canonicalReference || compatibilityAliases.contains(reference)
  }

  /// Includes decode/recovery-only identities that are not valid for new
  /// admission. Callers on request or execution boundaries must use `contains`.
  public static func containsDurableRecordReference(_ reference: String) -> Bool {
    contains(reference) || legacyDurableReferences.contains(reference)
  }

  public static func canonicalReference(for reference: String) -> String? {
    contains(reference) ? canonicalReference : nil
  }

  public static func canonicalDescriptor(
    for reference: String
  ) -> CatalogOperationDescriptor? {
    guard canonicalReference(for: reference) != nil else { return nil }
    return RuntimeOperationCatalog.descriptor(reference: canonicalReference)
  }
}

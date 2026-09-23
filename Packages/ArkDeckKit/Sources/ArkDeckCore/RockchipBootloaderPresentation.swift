/// Redacted, read-only relationship between the DAYU200 personality currently
/// present on USB and Runtime's durable target/binding facts. The raw serial,
/// topology and their digest never cross this boundary.
public enum RockchipBootloaderBindingDisposition: String, Sendable, Equatable {
  case absent
  case ambiguous
  case exactBoundTarget
  case targetBindingUnprepared
  case unbound
}

public struct RockchipBootloaderStatus: Sendable, Equatable {
  public let disposition: RockchipBootloaderBindingDisposition
  public let observationCount: Int
  public let mode: String?
  public let targetID: String?
  public let bindingRevision: Int?

  public init(
    disposition: RockchipBootloaderBindingDisposition,
    observationCount: Int,
    mode: String?,
    targetID: String?,
    bindingRevision: Int?
  ) {
    self.disposition = disposition
    self.observationCount = observationCount
    self.mode = mode
    self.targetID = targetID
    self.bindingRevision = bindingRevision
  }
}

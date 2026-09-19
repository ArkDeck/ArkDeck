import ArkDeckClientKit

/// The daemon-side owner boundary for ArkTrace's lease-aware cache service.
/// Paths are fixed when the production implementation is composed and can
/// never arrive in a control request. The values it answers with, and their
/// wire projections, are the App-facing models in ArkDeckClientKit.
public protocol RuntimeTraceCacheMaintaining: Sendable {
  func inventory() async throws -> RuntimeTraceCacheInventory
  func purgeUnused() async throws -> RuntimeTraceCachePurgeReport
}

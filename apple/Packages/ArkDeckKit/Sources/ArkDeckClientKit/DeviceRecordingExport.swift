import Foundation

/// Saves a host-composed recording without moving or modifying its source.
public enum DeviceRecordingExport {
  /// The panel and UI state belong to the main actor; potentially slow disk
  /// operations do not. Explicit concurrent execution also holds for callers
  /// built with main-actor default isolation.
  @concurrent
  public static func copy(from source: URL, to destination: URL) async throws {
    try Task.checkCancellation()
    let files = FileManager()
    let temporary = destination.deletingLastPathComponent().appending(
      path: ".arkdeck-\(UUID().uuidString)-\(destination.lastPathComponent)")
    defer { try? files.removeItem(at: temporary) }

    // Stage beside the destination so replacement stays on the same volume.
    // A failed copy must never remove an existing user file.
    try files.copyItem(at: source, to: temporary)
    try Task.checkCancellation()
    if files.fileExists(atPath: destination.path) {
      _ = try files.replaceItemAt(destination, withItemAt: temporary)
    } else {
      try files.moveItem(at: temporary, to: destination)
    }
  }
}

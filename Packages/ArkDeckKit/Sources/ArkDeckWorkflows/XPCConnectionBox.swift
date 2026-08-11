import Foundation

/// Sendable-safe holder for an `NSXPCConnection` captured by facade reply
/// closures. One definition for all App-facing facades; the connection class
/// itself is thread-safe, the box only carries the reference across the
/// `@Sendable` boundary.
final class XPCConnectionBox: @unchecked Sendable {
  let connection: NSXPCConnection
  init(_ connection: NSXPCConnection) { self.connection = connection }
}

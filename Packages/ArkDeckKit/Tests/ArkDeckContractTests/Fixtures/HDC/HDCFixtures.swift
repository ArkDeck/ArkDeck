import Foundation

/// Declared HDC output families used by the M0A semantic parser contract.
/// The large fixture is materialized in bounded chunks so the repository does
/// not contain a large opaque blob and the test exercises streaming behavior.
enum HDCFixtures {
    static let exitZeroFailure = Data("[Fail] ErrorCode: E000003 Unauthorized device\n".utf8)
    static let largeOutputChunk = Data("progress: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n".utf8)
    static let largeOutputRepeatCount = 16_384
    static let largeOutputFailureTail = Data("[Fail] Offline after transfer\n".utf8)
}

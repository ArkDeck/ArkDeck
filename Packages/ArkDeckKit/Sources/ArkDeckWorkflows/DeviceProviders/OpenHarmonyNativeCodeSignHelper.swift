import Foundation

package struct HDCNativeCodeSignHelperArtifact: Sendable {
  package let fileURL: URL
  package let facts: HDCNativeCodeSignHelperFacts

  package static func bundled() throws -> HDCNativeCodeSignHelperArtifact {
    guard
      let fileURL = Bundle.module.url(
        forResource: "arkdeck-code-sign-enable",
        withExtension: nil,
        subdirectory: "OpenHarmonyNativeCodeSign")
    else {
      throw DeviceProviderError.unsupportedAction(
        "bundled OpenHarmony code-sign helper is missing")
    }
    let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    let artifact = try NativeLibraryArtifactValidator.validate(
      data, expectedABI: .arm64)
    guard artifact.codeSign == nil else {
      throw DeviceProviderError.unsupportedAction(
        "bundled code-sign helper unexpectedly carries a mutable input signature")
    }
    guard isStaticExecutable(data) else {
      throw DeviceProviderError.unsupportedAction(
        "bundled code-sign helper is not a static arm64 executable")
    }
    return HDCNativeCodeSignHelperArtifact(
      fileURL: fileURL,
      facts: HDCNativeCodeSignHelperFacts(
        abi: artifact.abi,
        buildID: artifact.buildID,
        sha256: artifact.sha256,
        byteCount: artifact.byteCount))
  }

  private static func isStaticExecutable(_ data: Data) -> Bool {
    let elfExecutable: UInt16 = 2
    let programLoad: UInt32 = 1
    let programInterpreter: UInt32 = 3
    guard readUInt16(data, at: 16) == elfExecutable,
      let programHeaderOffsetValue = readUInt64(data, at: 32),
      programHeaderOffsetValue <= UInt64(Int.max),
      let programHeaderEntrySizeValue = readUInt16(data, at: 54),
      let programHeaderCountValue = readUInt16(data, at: 56)
    else {
      return false
    }
    let programHeaderOffset = Int(programHeaderOffsetValue)
    let programHeaderEntrySize = Int(programHeaderEntrySizeValue)
    let programHeaderCount = Int(programHeaderCountValue)
    guard programHeaderEntrySize >= 56, programHeaderCount > 0,
      programHeaderOffset <= data.count,
      programHeaderCount <= (data.count - programHeaderOffset) / programHeaderEntrySize
    else {
      return false
    }
    var hasLoadSegment = false
    for index in 0..<programHeaderCount {
      guard let type = readUInt32(
        data, at: programHeaderOffset + index * programHeaderEntrySize)
      else {
        return false
      }
      if type == programInterpreter {
        return false
      }
      hasLoadSegment = hasLoadSegment || type == programLoad
    }
    return hasLoadSegment
  }

  private static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= data.count else { return nil }
    return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
  }

  private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
    guard let low = readUInt16(data, at: offset),
      let high = readUInt16(data, at: offset + 2)
    else {
      return nil
    }
    return UInt32(low) | (UInt32(high) << 16)
  }

  private static func readUInt64(_ data: Data, at offset: Int) -> UInt64? {
    guard let low = readUInt32(data, at: offset),
      let high = readUInt32(data, at: offset + 4)
    else {
      return nil
    }
    return UInt64(low) | (UInt64(high) << 32)
  }
}

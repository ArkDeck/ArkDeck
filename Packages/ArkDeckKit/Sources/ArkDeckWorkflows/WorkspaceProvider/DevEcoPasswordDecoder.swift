import CryptoKit
import Darwin
import Foundation

/// Decodes the encrypted password strings emitted by DevEco Studio next to
/// its generated PKCS#12 material. This is used only by the interactive
/// `arkdeck signing install` boundary: the decoded value is placed in the
/// login Keychain, and Runtime Jobs never depend on mutable DevEco material.
package enum OpenHarmonyDevEcoPasswordDecoder {
  private static let component = Data([
    49, 243, 9, 115, 214, 175, 91, 184,
    211, 190, 177, 88, 101, 131, 192, 119,
  ])

  package static func decodeIfNeeded(
    _ candidate: Data, keystore: URL,
    fileManager: FileManager = .default
  ) throws -> Data {
    guard let text = String(data: candidate, encoding: .utf8),
      text.utf8.count >= 32, text.utf8.count.isMultiple(of: 2),
      text.utf8.allSatisfy({ Self.hexNibble($0) != nil })
    else { return candidate }
    guard text.utf8.count <= 2_048,
      let encryptedPassword = Self.decodeHex(text)
    else {
      throw OpenHarmonySigningError.invalidConfiguration(
        "DevEco password ciphertext is malformed")
    }
    // A long hexadecimal plaintext password is valid. Treat it as DevEco
    // material only when it also has the authenticated-envelope shape used
    // by DevEco's decipher utility. The 4-byte big-endian prefix is the
    // ciphertext-plus-tag length (not the nonce length), followed by a
    // 12-byte nonce, ciphertext, and a 16-byte GCM tag.
    guard looksLikeEnvelope(encryptedPassword) else { return candidate }

    let material = keystore.deletingLastPathComponent()
      .appending(path: "material", directoryHint: .isDirectory)
    var fdParts = try readFDParts(
      in: material.appending(path: "fd", directoryHint: .isDirectory),
      fileManager: fileManager)
    defer {
      for index in fdParts.indices {
        fdParts[index].resetBytes(in: 0..<fdParts[index].count)
      }
    }
    var salt = try onlyFile(
      in: material.appending(path: "ac", directoryHint: .isDirectory),
      expectedByteCount: 16, fileManager: fileManager)
    defer { salt.resetBytes(in: 0..<salt.count) }
    var encryptedWorkKey = try onlyFile(
      in: material.appending(path: "ce", directoryHint: .isDirectory),
      expectedByteCount: nil, fileManager: fileManager)
    defer { encryptedWorkKey.resetBytes(in: 0..<encryptedWorkKey.count) }

    var combined = fdParts[0]
    for part in fdParts.dropFirst() { xor(part, into: &combined) }
    xor(component, into: &combined)
    defer { combined.resetBytes(in: 0..<combined.count) }
    // DevEco converts the XOR result through Node Buffer.toString(), whose
    // default encoding is UTF-8 with replacement for malformed sequences,
    // before pbkdf2Sync converts that String back to UTF-8 bytes. It does not
    // use Int8's comma-separated decimal representation.
    var passwordMaterial = Data(String(decoding: combined, as: UTF8.self).utf8)
    defer { passwordMaterial.resetBytes(in: 0..<passwordMaterial.count) }
    var rootKey = try pbkdf2SHA256(
      password: passwordMaterial, salt: salt, iterations: 10_000,
      outputByteCount: 16)
    defer { rootKey.resetBytes(in: 0..<rootKey.count) }
    var workKey = try decrypt(encryptedWorkKey, key: rootKey)
    defer { workKey.resetBytes(in: 0..<workKey.count) }
    guard workKey.count == 16 else {
      throw OpenHarmonySigningError.invalidConfiguration(
        "DevEco signing material produced an invalid work key")
    }
    let decoded = try decrypt(encryptedPassword, key: workKey)
    guard !decoded.isEmpty, decoded.count <= 1_024,
      String(data: decoded, encoding: .utf8) != nil,
      !decoded.contains(0), !decoded.contains(10), !decoded.contains(13)
    else {
      throw OpenHarmonySigningError.invalidConfiguration(
        "DevEco signing password plaintext is invalid")
    }
    return decoded
  }

  private static func onlyFile(
    in directory: URL, expectedByteCount: Int?, fileManager: FileManager
  ) throws -> Data {
    try readFiles(
      in: directory, expectedCount: 1, expectedByteCount: expectedByteCount,
      fileManager: fileManager)[0]
  }

  /// DevEco stores each of the three XOR components in its own directory
  /// (`material/fd/<slot>/<opaque-file>`), rather than directly below `fd`.
  /// Mirror that bounded layout exactly so unrelated files can never become
  /// key-derivation input.
  private static func readFDParts(
    in directory: URL, fileManager: FileManager
  ) throws -> [Data] {
    try validateDirectory(directory)
    let slots = try fileManager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.lastPathComponent != ".DS_Store" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard slots.count == 3 else {
      throw OpenHarmonySigningError.invalidConfiguration(
        "DevEco signing material layout is incomplete")
    }
    return try slots.map {
      try onlyFile(
        in: $0, expectedByteCount: 16, fileManager: fileManager)
    }
  }

  private static func readFiles(
    in directory: URL, expectedCount: Int, expectedByteCount: Int?,
    fileManager: FileManager
  ) throws -> [Data] {
    try validateDirectory(directory)
    let entries = try fileManager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.lastPathComponent != ".DS_Store" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard entries.count == expectedCount else {
      throw OpenHarmonySigningError.invalidConfiguration(
        "DevEco signing material layout is incomplete")
    }
    return try entries.map { url in
      var info = stat()
      guard url.path.withCString({ lstat($0, &info) }) == 0,
        info.st_mode & S_IFMT == S_IFREG, info.st_size > 0,
        info.st_size <= 4_096,
        expectedByteCount.map({ Int(info.st_size) == $0 }) ?? true
      else {
        throw OpenHarmonySigningError.invalidConfiguration(
          "DevEco signing material file is absent or unsafe")
      }
      let bytes = try Data(contentsOf: url, options: [.uncached])
      guard bytes.count == Int(info.st_size) else {
        throw OpenHarmonySigningError.identityDrift("DevEco signing material")
      }
      return bytes
    }
  }

  private static func validateDirectory(_ directory: URL) throws {
    var directoryInfo = stat()
    guard directory.path.withCString({ lstat($0, &directoryInfo) }) == 0,
      directoryInfo.st_mode & S_IFMT == S_IFDIR,
      directoryInfo.st_mode & 0o022 == 0
    else {
      throw OpenHarmonySigningError.invalidConfiguration(
        "DevEco signing material directory is absent or unsafe")
    }
  }

  private static func decrypt(_ envelope: Data, key: Data) throws -> Data {
    guard envelope.count >= 4 + 12 + 16 else {
      throw OpenHarmonySigningError.invalidConfiguration(
        "DevEco encrypted material is truncated")
    }
    let sealedCount = envelope.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
    let nonceCount = envelope.count - 4 - sealedCount
    let ciphertextCount = sealedCount - 16
    guard nonceCount == 12, ciphertextCount > 0 else {
      throw OpenHarmonySigningError.invalidConfiguration(
        "DevEco encrypted material envelope is malformed")
    }
    do {
      let nonceRange = 4..<(4 + nonceCount)
      let ciphertextRange = nonceRange.upperBound..<(nonceRange.upperBound + ciphertextCount)
      let tagRange = ciphertextRange.upperBound..<envelope.endIndex
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: envelope[nonceRange]),
        ciphertext: envelope[ciphertextRange], tag: envelope[tagRange])
      return try AES.GCM.open(box, using: SymmetricKey(data: key))
    } catch {
      throw OpenHarmonySigningError.invalidConfiguration(
        "DevEco encrypted password could not be authenticated")
    }
  }

  private static func looksLikeEnvelope(_ envelope: Data) -> Bool {
    guard envelope.count >= 4 + 12 + 1 + 16 else { return false }
    let sealedCount = envelope.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
    return sealedCount > 16 && envelope.count - 4 - sealedCount == 12
  }

  private static func pbkdf2SHA256(
    password: Data, salt: Data, iterations: Int, outputByteCount: Int
  ) throws -> Data {
    guard iterations > 0, outputByteCount > 0 else {
      throw OpenHarmonySigningError.invalidConfiguration(
        "DevEco password derivation parameters are invalid")
    }
    let key = SymmetricKey(data: password)
    var derived = Data()
    var block: UInt32 = 1
    while derived.count < outputByteCount {
      var bigEndian = block.bigEndian
      var input = salt
      withUnsafeBytes(of: &bigEndian) { input.append(contentsOf: $0) }
      var u = Data(HMAC<SHA256>.authenticationCode(for: input, using: key))
      var accumulated = u
      if iterations > 1 {
        for _ in 1..<iterations {
          u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
          xor(u, into: &accumulated)
        }
      }
      derived.append(accumulated)
      u.resetBytes(in: 0..<u.count)
      accumulated.resetBytes(in: 0..<accumulated.count)
      block += 1
    }
    return Data(derived.prefix(outputByteCount))
  }

  private static func xor(_ source: Data, into destination: inout Data) {
    precondition(source.count == destination.count)
    destination.withUnsafeMutableBytes { destinationBytes in
      source.withUnsafeBytes { sourceBytes in
        guard let destinationBase = destinationBytes.baseAddress,
          let sourceBase = sourceBytes.baseAddress
        else { return }
        for index in 0..<source.count {
          destinationBase.storeBytes(
            of: destinationBase.load(fromByteOffset: index, as: UInt8.self)
              ^ sourceBase.load(fromByteOffset: index, as: UInt8.self),
            toByteOffset: index, as: UInt8.self)
        }
      }
    }
  }

  private static func decodeHex(_ value: String) -> Data? {
    let bytes = Array(value.utf8)
    var decoded = Data(capacity: bytes.count / 2)
    for index in stride(from: 0, to: bytes.count, by: 2) {
      guard let high = hexNibble(bytes[index]), let low = hexNibble(bytes[index + 1]) else {
        return nil
      }
      decoded.append((high << 4) | low)
    }
    return decoded
  }

  private static func hexNibble(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48...57: byte - 48
    case 65...70: byte - 55
    case 97...102: byte - 87
    default: nil
    }
  }
}

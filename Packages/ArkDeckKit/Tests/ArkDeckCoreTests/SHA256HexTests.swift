import CryptoKit
import Foundation
import Testing

@testable import ArkDeckCore

struct SHA256HexTests {
  // Known-answer vectors (FIPS 180-2 / independently verifiable).
  @Test func knownDigestVectorsRenderAsLowercaseHex() {
    #expect(
      SHA256Hex.string(of: Data())
        == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(
      SHA256Hex.string(of: Data("abc".utf8))
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  @Test func hexStringMatchesStringOfForTheSameBytes() {
    let payload = Data((0...255).map { UInt8($0) })
    #expect(
      SHA256Hex.hexString(SHA256.hash(data: payload))
        == SHA256Hex.string(of: payload))
  }

  @Test func arbitraryBytesRenderWithoutCFormatting() {
    #expect(SHA256Hex.lowercaseHex([0x00, 0x0f, 0x10, 0xff]) == "000f10ff")
  }

  @Test func predicateAcceptsExactlyLowercase64Hex() {
    let digest = SHA256Hex.string(of: Data("abc".utf8))
    #expect(SHA256Hex.isLowercaseSHA256(digest))
    #expect(SHA256Hex.isLowercaseSHA256(String(repeating: "0", count: 64)))
    #expect(SHA256Hex.isLowercaseSHA256(String(repeating: "f", count: 64)))
  }

  @Test func predicateRejectsCaseLengthAndAlphabetDrift() {
    let digest = SHA256Hex.string(of: Data("abc".utf8))
    #expect(!SHA256Hex.isLowercaseSHA256(digest.uppercased()))
    #expect(!SHA256Hex.isLowercaseSHA256(String(digest.dropLast())))
    #expect(!SHA256Hex.isLowercaseSHA256(digest + "0"))
    #expect(!SHA256Hex.isLowercaseSHA256(""))
    #expect(!SHA256Hex.isLowercaseSHA256(String(repeating: "g", count: 64)))
    #expect(!SHA256Hex.isLowercaseSHA256(String(repeating: "0", count: 63) + "G"))
  }

  @Test func predicateRejectsNonASCIIEvenAtMatchingCharacterCount() {
    // 64 characters, but multi-byte UTF-8 — must not satisfy the closed shape.
    #expect(!SHA256Hex.isLowercaseSHA256(String(repeating: "０", count: 64)))
    #expect(
      !SHA256Hex.isLowercaseSHA256(String(repeating: "0", count: 63) + "０"))
    // 64 bytes reached via multi-byte characters must also fail.
    #expect(!SHA256Hex.isLowercaseSHA256(String(repeating: "é", count: 32)))
  }
}

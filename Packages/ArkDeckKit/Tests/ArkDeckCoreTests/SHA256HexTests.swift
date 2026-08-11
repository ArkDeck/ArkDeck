import CryptoKit
import XCTest

@testable import ArkDeckCore

final class SHA256HexTests: XCTestCase {
  // Known-answer vectors (FIPS 180-2 / independently verifiable).
  func testKnownDigestVectorsRenderAsLowercaseHex() {
    XCTAssertEqual(
      SHA256Hex.string(of: Data()),
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    XCTAssertEqual(
      SHA256Hex.string(of: Data("abc".utf8)),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  func testHexStringMatchesStringOfForTheSameBytes() {
    let payload = Data((0...255).map { UInt8($0) })
    XCTAssertEqual(
      SHA256Hex.hexString(SHA256.hash(data: payload)),
      SHA256Hex.string(of: payload))
  }

  func testPredicateAcceptsExactlyLowercase64Hex() {
    let digest = SHA256Hex.string(of: Data("abc".utf8))
    XCTAssertTrue(SHA256Hex.isLowercaseSHA256(digest))
    XCTAssertTrue(SHA256Hex.isLowercaseSHA256(String(repeating: "0", count: 64)))
    XCTAssertTrue(SHA256Hex.isLowercaseSHA256(String(repeating: "f", count: 64)))
  }

  func testPredicateRejectsCaseLengthAndAlphabetDrift() {
    let digest = SHA256Hex.string(of: Data("abc".utf8))
    XCTAssertFalse(SHA256Hex.isLowercaseSHA256(digest.uppercased()))
    XCTAssertFalse(SHA256Hex.isLowercaseSHA256(String(digest.dropLast())))
    XCTAssertFalse(SHA256Hex.isLowercaseSHA256(digest + "0"))
    XCTAssertFalse(SHA256Hex.isLowercaseSHA256(""))
    XCTAssertFalse(SHA256Hex.isLowercaseSHA256(String(repeating: "g", count: 64)))
    XCTAssertFalse(SHA256Hex.isLowercaseSHA256(String(repeating: "0", count: 63) + "G"))
  }

  func testPredicateRejectsNonASCIIEvenAtMatchingCharacterCount() {
    // 64 characters, but multi-byte UTF-8 — must not satisfy the closed shape.
    XCTAssertFalse(SHA256Hex.isLowercaseSHA256(String(repeating: "０", count: 64)))
    XCTAssertFalse(
      SHA256Hex.isLowercaseSHA256(String(repeating: "0", count: 63) + "０"))
    // 64 bytes reached via multi-byte characters must also fail.
    XCTAssertFalse(SHA256Hex.isLowercaseSHA256(String(repeating: "é", count: 32)))
  }
}

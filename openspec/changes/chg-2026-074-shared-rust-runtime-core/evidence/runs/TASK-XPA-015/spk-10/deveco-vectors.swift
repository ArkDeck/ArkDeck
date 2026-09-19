import CryptoKit
import Foundation
// Mirrors OpenHarmonyLocalSigningContractTests.makeDevEcoPasswordFixture and
// its testDevEcoEnvelope / testPBKDF2SHA256 helpers; prints hex vectors.
let component = Data([49, 243, 9, 115, 214, 175, 91, 184, 211, 190, 177, 88, 101, 131, 192, 119])
func xor(_ s: Data, _ d: inout Data) { for i in d.indices { d[i] ^= s[i] } }
func pbkdf2(_ password: Data, _ salt: Data, _ iterations: Int, _ count: Int) -> Data {
  let key = SymmetricKey(data: password); var derived = Data(); var block: UInt32 = 1
  while derived.count < count {
    var be = block.bigEndian; var input = salt; withUnsafeBytes(of: &be) { input.append(contentsOf: $0) }
    var u = Data(HMAC<SHA256>.authenticationCode(for: input, using: key)); var acc = u
    for _ in 1..<iterations { u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key)); xor(u, &acc) }
    derived.append(acc); block += 1 }
  return Data(derived.prefix(count))
}
func envelope(_ plaintext: Data, key: Data, nonceByte: UInt8) throws -> Data {
  let nonce = try AES.GCM.Nonce(data: Data(repeating: nonceByte, count: 12))
  let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce)
  var count = UInt32(sealed.ciphertext.count + sealed.tag.count).bigEndian
  var r = Data(); withUnsafeBytes(of: &count) { r.append(contentsOf: $0) }
  r.append(contentsOf: nonce); r.append(sealed.ciphertext); r.append(sealed.tag); return r
}
func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func vector(_ name: String, parts: [Data], plaintext: String, workKeyBase: UInt8) throws {
  let salt = Data((0..<16).map(UInt8.init))
  var combined = parts[0]; for p in parts.dropFirst() { xor(p, &combined) }; xor(component, &combined)
  let material = Data(String(decoding: combined, as: UTF8.self).utf8)
  let rootKey = pbkdf2(material, salt, 10_000, 16)
  let workKey = Data((0..<16).map { UInt8(workKeyBase &+ $0) })
  print("\(name).parts=" + parts.map(hex).joined(separator: ","))
  print("\(name).salt=" + hex(salt))
  print("\(name).lossy=" + hex(material))
  print("\(name).workKeyEnvelope=" + hex(try envelope(workKey, key: rootKey, nonceByte: 0x21)))
  print("\(name).encrypted=" + hex(try envelope(Data(plaintext.utf8), key: workKey, nonceByte: 0x37)))
  print("\(name).plaintext=" + plaintext)
}
try vector("swiftTest", parts: [Data(repeating: 0x11, count: 16), Data(repeating: 0x42, count: 16), Data(repeating: 0xA5, count: 16)], plaintext: "deveco-plaintext-password", workKeyBase: 0xD0)
// combined = overlong, surrogate, out-of-range, truncated and valid 4-byte sequences.
var tricky = Data([0xC0, 0x80, 0xE0, 0x80, 0x41, 0xED, 0xA0, 0x80, 0xF4, 0x90, 0x80, 0x80, 0xF0, 0x9F, 0x98, 0x80])
xor(component, &tricky)
try vector("illFormed", parts: [tricky, Data(count: 16), Data(count: 16)], plaintext: "Ill-formed UTF-8 key material 7", workKeyBase: 0x10)
var ascii = Data("0123456789abcdef".utf8); xor(component, &ascii)
try vector("ascii", parts: [Data(count: 16), ascii, Data(count: 16)], plaintext: "ascii-material-password", workKeyBase: 0x60)
// RFC 7914 §11 PBKDF2-HMAC-SHA256 vector through the same helper.
print("rfc7914=" + hex(pbkdf2(Data("passwd".utf8), Data("salt".utf8), 1, 64)))
// Lossy decoding of assorted ill-formed inputs.
for input in [Data([0xE2, 0x82]), Data([0xF0, 0x80, 0x80, 0x41]), Data([0xFF, 0xFE, 0x41]), Data([0xE1, 0x80, 0xE2, 0xF0, 0x91, 0x92, 0xF1, 0xBF, 0x41])] {
  print("lossy " + hex(input) + " -> " + hex(Data(String(decoding: input, as: UTF8.self).utf8)))
}

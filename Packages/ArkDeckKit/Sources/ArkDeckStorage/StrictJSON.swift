import Foundation

public enum StrictJSONError: Error, Equatable, Sendable {
  case duplicateMemberName(path: String)
  case malformed(String)
}

struct StrictJSONDuplicateValidator {
  private let bytes: [UInt8]
  private var index = 0

  init(data: Data) {
    self.bytes = Array(data)
  }

  mutating func validate() throws {
    skipWhitespace()
    try parseValue(path: "$", depth: 0)
    skipWhitespace()
    guard index == bytes.count else {
      throw StrictJSONError.malformed("unexpected trailing data at byte offset \(index)")
    }
  }

  private mutating func parseValue(path: String, depth: Int) throws {
    guard depth <= 256, let byte = currentByte else {
      throw StrictJSONError.malformed(
        depth > 256 ? "JSON nesting exceeds 256 levels" : "missing JSON value")
    }
    switch byte {
    case Self.objectStart:
      try parseObject(path: path, depth: depth)
    case Self.arrayStart:
      try parseArray(path: path, depth: depth)
    case Self.quote:
      _ = try parseString()
    case Self.minus, Self.zero...Self.nine:
      try parseNumber()
    case Self.lowercaseT:
      try parseLiteral(Array("true".utf8))
    case Self.lowercaseF:
      try parseLiteral(Array("false".utf8))
    case Self.lowercaseN:
      try parseLiteral(Array("null".utf8))
    default:
      throw StrictJSONError.malformed("unexpected byte at byte offset \(index)")
    }
  }

  private mutating func parseObject(path: String, depth: Int) throws {
    try consume(Self.objectStart, expectation: "object start")
    skipWhitespace()
    if consumeIfPresent(Self.objectEnd) { return }

    var names: Set<String> = []
    while true {
      guard currentByte == Self.quote else {
        throw StrictJSONError.malformed("object member name must be a string")
      }
      let name = try parseString()
      let memberPath = "\(path).\(name)"
      guard names.insert(name).inserted else {
        throw StrictJSONError.duplicateMemberName(path: memberPath)
      }
      skipWhitespace()
      try consume(Self.nameSeparator, expectation: "colon after member name")
      skipWhitespace()
      try parseValue(path: memberPath, depth: depth + 1)
      skipWhitespace()
      if consumeIfPresent(Self.objectEnd) { return }
      try consume(Self.valueSeparator, expectation: "comma between object members")
      skipWhitespace()
    }
  }

  private mutating func parseArray(path: String, depth: Int) throws {
    try consume(Self.arrayStart, expectation: "array start")
    skipWhitespace()
    if consumeIfPresent(Self.arrayEnd) { return }
    var elementIndex = 0
    while true {
      try parseValue(path: "\(path)[\(elementIndex)]", depth: depth + 1)
      elementIndex += 1
      skipWhitespace()
      if consumeIfPresent(Self.arrayEnd) { return }
      try consume(Self.valueSeparator, expectation: "comma between array elements")
      skipWhitespace()
    }
  }

  private mutating func parseString() throws -> String {
    let start = index
    try consume(Self.quote, expectation: "string opening quote")
    while let byte = currentByte {
      switch byte {
      case Self.quote:
        index += 1
        do {
          return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
        } catch {
          throw StrictJSONError.malformed("invalid JSON string")
        }
      case Self.escape:
        index += 1
        guard let escaped = currentByte else {
          throw StrictJSONError.malformed("unterminated JSON escape")
        }
        if escaped == Self.lowercaseU {
          index += 1
          for _ in 0..<4 {
            guard let hex = currentByte, Self.isHexDigit(hex) else {
              throw StrictJSONError.malformed("invalid Unicode escape")
            }
            index += 1
          }
        } else {
          guard Self.simpleEscapes.contains(escaped) else {
            throw StrictJSONError.malformed("invalid JSON escape")
          }
          index += 1
        }
      case 0x00...0x1F:
        throw StrictJSONError.malformed("unescaped control character in JSON string")
      default:
        index += 1
      }
    }
    throw StrictJSONError.malformed("unterminated JSON string")
  }

  private mutating func parseLiteral(_ literal: [UInt8]) throws {
    let end = index + literal.count
    guard end <= bytes.count, bytes[index..<end].elementsEqual(literal) else {
      throw StrictJSONError.malformed("invalid JSON literal")
    }
    index = end
  }

  private mutating func parseNumber() throws {
    if consumeIfPresent(Self.minus), currentByte == nil {
      throw StrictJSONError.malformed("minus must be followed by a number")
    }
    if consumeIfPresent(Self.zero) {
      if let byte = currentByte, Self.isDigit(byte) {
        throw StrictJSONError.malformed("leading zero in JSON number")
      }
    } else {
      guard let byte = currentByte, Self.one...Self.nine ~= byte else {
        throw StrictJSONError.malformed("invalid JSON integer")
      }
      repeat { index += 1 } while currentByte.map(Self.isDigit) == true
    }
    if consumeIfPresent(Self.decimalPoint) {
      guard currentByte.map(Self.isDigit) == true else {
        throw StrictJSONError.malformed("fraction requires a digit")
      }
      repeat { index += 1 } while currentByte.map(Self.isDigit) == true
    }
    if currentByte == Self.lowercaseE || currentByte == Self.uppercaseE {
      index += 1
      if currentByte == Self.plus || currentByte == Self.minus { index += 1 }
      guard currentByte.map(Self.isDigit) == true else {
        throw StrictJSONError.malformed("exponent requires a digit")
      }
      repeat { index += 1 } while currentByte.map(Self.isDigit) == true
    }
  }

  private mutating func consume(_ expected: UInt8, expectation: String) throws {
    guard consumeIfPresent(expected) else {
      throw StrictJSONError.malformed("expected \(expectation) at byte offset \(index)")
    }
  }

  private mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
    guard currentByte == expected else { return false }
    index += 1
    return true
  }

  private mutating func skipWhitespace() {
    while let byte = currentByte, Self.whitespace.contains(byte) { index += 1 }
  }

  private var currentByte: UInt8? { index < bytes.count ? bytes[index] : nil }

  private static func isDigit(_ byte: UInt8) -> Bool { zero...nine ~= byte }
  private static func isHexDigit(_ byte: UInt8) -> Bool {
    isDigit(byte) || lowercaseA...lowercaseF ~= byte || uppercaseA...uppercaseF ~= byte
  }

  private static let objectStart = UInt8(ascii: "{")
  private static let objectEnd = UInt8(ascii: "}")
  private static let arrayStart = UInt8(ascii: "[")
  private static let arrayEnd = UInt8(ascii: "]")
  private static let quote = UInt8(ascii: "\"")
  private static let escape = UInt8(ascii: "\\")
  private static let nameSeparator = UInt8(ascii: ":")
  private static let valueSeparator = UInt8(ascii: ",")
  private static let decimalPoint = UInt8(ascii: ".")
  private static let plus = UInt8(ascii: "+")
  private static let minus = UInt8(ascii: "-")
  private static let zero = UInt8(ascii: "0")
  private static let one = UInt8(ascii: "1")
  private static let nine = UInt8(ascii: "9")
  private static let lowercaseA = UInt8(ascii: "a")
  private static let lowercaseE = UInt8(ascii: "e")
  private static let lowercaseF = UInt8(ascii: "f")
  private static let lowercaseT = UInt8(ascii: "t")
  private static let lowercaseN = UInt8(ascii: "n")
  private static let lowercaseU = UInt8(ascii: "u")
  private static let uppercaseA = UInt8(ascii: "A")
  private static let uppercaseE = UInt8(ascii: "E")
  private static let uppercaseF = UInt8(ascii: "F")
  private static let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
  private static let simpleEscapes: Set<UInt8> = [
    UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"),
    UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"),
  ]
}

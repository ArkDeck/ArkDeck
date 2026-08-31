import ArkDeckCore
import Foundation

// CLI output and Runtime execution intent fingerprints use the same published JCS bytes.
typealias CLICanonicalJSON = PortableCanonicalJSON

/// Strict decoding of a caller-supplied JSON document (§5.3, §8.2).
///
/// `JSONDecoder` keeps the last of a repeated key and says nothing, so a
/// document with `{"target":"a","target":"b"}` silently loses one of them —
/// and which one is lost depends on the decoder, not on the document. I-JSON
/// forbids it, so this refuses it.
enum CLIStrictJSON {
  enum Failure: Error, Equatable {
    case byteOrderMark
    case notUTF8
    case malformed
    case duplicateKey(String)
  }

  static func decode(_ data: Data) throws -> JSONValue {
    guard !data.starts(with: [0xEF, 0xBB, 0xBF]) else { throw Failure.byteOrderMark }
    guard let text = String(data: data, encoding: .utf8) else { throw Failure.notUTF8 }
    if let duplicate = firstDuplicateKey(in: text) { throw Failure.duplicateKey(duplicate) }
    guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
      throw Failure.malformed
    }
    return decoded
  }

  /// Scans for a key repeated within one object.
  ///
  /// Done on the text because the decoded value cannot show it: by the time a
  /// dictionary exists, the duplicate is already gone. The scan tracks string
  /// and escape state so a brace or a quote inside a string cannot be mistaken
  /// for structure.
  static func firstDuplicateKey(in text: String) -> String? {
    var stack: [Set<String>] = []
    var pendingKey: String?
    var current = ""
    var inString = false
    var escaped = false
    var expectingKey = false

    for character in text {
      if inString {
        if escaped {
          current.append(character)
          escaped = false
        } else if character == "\\" {
          current.append(character)
          escaped = true
        } else if character == "\"" {
          inString = false
          if expectingKey { pendingKey = unescaped(current) }
        } else {
          current.append(character)
        }
        continue
      }
      switch character {
      case "\"":
        inString = true
        current = ""
      case "{":
        stack.append([])
        expectingKey = true
      case "}":
        if !stack.isEmpty { stack.removeLast() }
        expectingKey = !stack.isEmpty
      case "[":
        expectingKey = false
      case "]":
        expectingKey = !stack.isEmpty
      case ":":
        if let key = pendingKey, !stack.isEmpty {
          if stack[stack.count - 1].contains(key) { return key }
          stack[stack.count - 1].insert(key)
          pendingKey = nil
        }
        expectingKey = false
      case ",":
        expectingKey = !stack.isEmpty
      default:
        break
      }
    }
    return nil
  }

  /// Only the escapes that can appear inside a key matter here: two keys are
  /// the same key whether or not one spelled a character with `\u`.
  private static func unescaped(_ raw: String) -> String {
    guard raw.contains("\\"),
      let data = "\"\(raw)\"".data(using: .utf8),
      let decoded = try? JSONDecoder().decode(String.self, from: data)
    else { return raw }
    return decoded
  }
}

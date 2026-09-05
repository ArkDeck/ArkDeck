import Foundation

/// Shared strict JSON framing for control traffic and bounded durable records.
/// This parser chooses no protocol and carries no execution authority.
package enum ControlFrameJSON {
  package enum Failure: Error { case malformed }

  package static func decodeObject(_ data: Data, maximumBytes: Int) throws -> [String: JSONValue] {
    guard data.count + 1 <= maximumBytes,
      String(data: data, encoding: .utf8) != nil,
      !data.contains(0x0A), !data.contains(0x0D)
    else { throw Failure.malformed }
    var validator = StrictJSONDuplicateValidator(data: data)
    try validator.validate()
    return try JSONDecoder().decode([String: JSONValue].self, from: data)
  }

}

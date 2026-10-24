import Testing
@testable import ArkDeckClientKit
@testable import ArkDeckCore

struct HistoryFilterWireTests {
  @Test func requestDistinguishesOmittedNullAndStringIdentities() throws {
    let variants: [[String: JSONValue]] = [[:], ["sessionId": .null], ["sessionId": .string("S-1")]]
    for fields in variants {
      let request = try HistoryFilterSaveRequest.decode(.object(fields))
      #expect(request.wire == .object(fields))
    }
    #expect(throws: (any Error).self) {
      try HistoryFilterSaveRequest.decode(.object(["extra": .null]))
    }
    #expect(throws: (any Error).self) {
      try HistoryFilterSaveRequest.decode(.object(["sessionId": .integer(1)]))
    }
  }

  @Test func requiredNullableFieldCannotBeOmitted() throws {
    let list: [String: JSONValue] = [
      "schemaVersion": .string("arkdeck.history-filter-list/1"),
      "generation": .string("1"), "filters": .array([]), "updatedAtUtc": .null,
    ]
    #expect(try HistoryFilterListResult.decode(.object(list)).wire == .object(list))
    var missing = list
    missing.removeValue(forKey: "updatedAtUtc")
    #expect(throws: (any Error).self) { try HistoryFilterListResult.decode(.object(missing)) }
  }

  @Test func methodResultStructuresStayDistinct() throws {
    let deleted: JSONValue = .object([
      "schemaVersion": .string("arkdeck.history-filter/1"), "generation": .string("3"),
      "query": .null, "updatedAtUtc": .string("2026-09-01T08:30:00.000Z"),
    ])
    #expect(try HistoryFilterDeleteResult.decode(deleted).wire == deleted)
    #expect(throws: (any Error).self) { try HistoryFilterSaveResult.decode(deleted) }
  }
}

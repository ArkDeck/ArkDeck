import XCTest
@testable import ArkDeckClientKit
@testable import ArkDeckCore

final class HistoryFilterWireTests: XCTestCase {
  func testRequestDistinguishesOmittedNullAndStringIdentities() throws {
    let variants: [[String: JSONValue]] = [[:], ["sessionId": .null], ["sessionId": .string("S-1")]]
    for fields in variants {
      let request = try HistoryFilterSaveRequest.decode(.object(fields))
      XCTAssertEqual(request.wire, .object(fields))
    }
    XCTAssertThrowsError(try HistoryFilterSaveRequest.decode(.object(["extra": .null])))
    XCTAssertThrowsError(try HistoryFilterSaveRequest.decode(.object(["sessionId": .integer(1)])))
  }

  func testRequiredNullableFieldCannotBeOmitted() throws {
    let list: [String: JSONValue] = [
      "schemaVersion": .string("arkdeck.history-filter-list/1"),
      "generation": .string("1"), "filters": .array([]), "updatedAtUtc": .null,
    ]
    XCTAssertEqual(try HistoryFilterListResult.decode(.object(list)).wire, .object(list))
    var missing = list
    missing.removeValue(forKey: "updatedAtUtc")
    XCTAssertThrowsError(try HistoryFilterListResult.decode(.object(missing)))
  }

  func testMethodResultStructuresStayDistinct() throws {
    let deleted: JSONValue = .object([
      "schemaVersion": .string("arkdeck.history-filter/1"), "generation": .string("3"),
      "query": .null, "updatedAtUtc": .string("2026-09-01T08:30:00.000Z"),
    ])
    XCTAssertEqual(try HistoryFilterDeleteResult.decode(deleted).wire, deleted)
    XCTAssertThrowsError(try HistoryFilterSaveResult.decode(deleted))
  }
}

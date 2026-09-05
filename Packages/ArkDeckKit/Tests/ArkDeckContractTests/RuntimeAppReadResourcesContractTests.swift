import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

final class RuntimeAppReadResourcesContractTests: XCTestCase {
  private let jobID = "job-app-read"
  private let revision = "11111111-1111-4111-8111-111111111111"

  private actor Replies {
    var values: [JSONValue]
    var calls: [(String, [String: JSONValue])] = []

    init(_ values: [JSONValue]) { self.values = values }

    func send(_ method: String, _ params: [String: JSONValue]) throws -> Data {
      calls.append((method, params))
      guard !values.isEmpty else {
        throw AgentExecutionControlFailure("recordUnreadable", "unexpected extra fixture read")
      }
      return try CanonicalJSONEncoders.canonical().encode(JSONValue.object([
        "id": .string("fixture"), "ok": .bool(true), "result": values.removeFirst(),
      ]))
    }
  }

  private func detail(_ timeline: JSONValue, schema: String = "arkdeck.job-status/1") -> JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.job/1"),
      "job": .object(["schemaVersion": .string(schema), "jobId": .string(jobID)]),
      "timeline": timeline,
    ])
  }

  private var pagedDetail: JSONValue {
    detail(.object([
      "kind": .string("snapshotPages"), "method": .string("job.timeline"), "jobId": .string(jobID),
    ]))
  }

  private func fragment(_ entry: Int, _ part: Int, _ text: String, last: Bool) -> JSONValue {
    .object([
      "entryIndex": .string(String(entry)), "partIndex": .string(String(part)),
      "text": .string(text), "lastPart": .bool(last),
    ])
  }

  private func page(_ rows: [JSONValue], cursor: String? = nil, revision: String? = nil) -> JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.cli.page/1"), "pageKind": .string("snapshot"),
      "order": .string("entryIndexAscPartIndexAsc"), "items": .array(rows),
      "snapshotRevision": .string(revision ?? self.revision),
      "hasMore": .bool(cursor != nil), "nextCursor": cursor.map(JSONValue.string) ?? .null,
    ])
  }

  func testTimelineFragmentsAcrossPagesKeepExactTextAndReadSelectors() async throws {
    let cursor = revision + ".next"
    let replies = Replies([
      pagedDetail,
      page([fragment(0, 0, "中🙂e", last: false)], cursor: cursor),
      page([fragment(0, 1, "\u{301}", last: true), fragment(1, 0, "", last: true)]),
    ])
    let result = try await RuntimeAppReadResources.jobDetail(jobID: jobID) {
      try await replies.send($0, $1)
    }
    XCTAssertEqual(result, detail(.object([
      "kind": .string("inline"), "entries": .array([.string("中🙂e\u{301}"), .string("")]),
    ])))
    let calls = await replies.calls
    XCTAssertEqual(calls.map(\.0), ["job.show", "job.timeline", "job.timeline"])
    XCTAssertEqual(calls[0].1, ["jobId": .string(jobID)])
    XCTAssertEqual(calls[1].1, ["jobId": .string(jobID), "pageSize": .integer(1000)])
    XCTAssertEqual(calls[2].1, ["jobId": .string(jobID), "pageSize": .integer(1000), "cursor": .string(cursor)])
  }

  func testMalformedInlineTimelineAndWrongNestedResourceFailBeforeAnotherRead() async throws {
    let validTimeline = JSONValue.object(["kind": .string("inline"), "entries": .array([])])
    for invalid in [
      detail(validTimeline, schema: "arkdeck.job-summary/1"),
      detail(validTimeline, schema: "arkdeck.job-status/2"),
      detail(.object(["kind": .string("inline"), "entries": .array([.integer(1)])])),
      detail(.object(["kind": .string("inline"), "entries": .array([]), "extra": .null])),
      detail(.object(["kind": .string("snapshotPages"), "method": .string("job.timeline"), "jobId": .string("job-foreign")])),
    ] {
      let replies = Replies([invalid])
      do {
        _ = try await RuntimeAppReadResources.jobDetail(jobID: jobID) { try await replies.send($0, $1) }
        XCTFail("malformed detail must fail")
      } catch let error as AgentExecutionControlFailure {
        XCTAssertEqual(error.code, "recordUnreadable")
      }
      let calls = await replies.calls
      XCTAssertEqual(calls.map(\.0), ["job.show"])
    }
  }

  func testIncompleteOutOfOrderAndMixedSnapshotPagesNeverReturnPartialTimeline() async throws {
    let cursor = revision + ".next"
    let first = page([fragment(0, 0, "first", last: false)], cursor: cursor)
    for pages in [
      [page([fragment(0, 0, "unfinished", last: false)])],
      [page([fragment(1, 0, "missing first entry", last: true)])],
      [first, page([fragment(0, 2, "missing part", last: true)])],
      [first, page([fragment(0, 1, "last", last: true)], revision: "22222222-2222-4222-8222-222222222222")],
      [first, page([fragment(0, 1, "last", last: true)], cursor: cursor)],
    ] {
      let replies = Replies([pagedDetail] + pages)
      do {
        _ = try await RuntimeAppReadResources.jobDetail(jobID: jobID) { try await replies.send($0, $1) }
        XCTFail("invalid pages must not produce a partial timeline")
      } catch let error as AgentExecutionControlFailure {
        XCTAssertEqual(error.code, "recordUnreadable")
      }
      let calls = await replies.calls
      XCTAssertEqual(calls.count, pages.count + 1)
      XCTAssertTrue(calls.allSatisfy { ["job.show", "job.timeline"].contains($0.0) })
    }
  }
}

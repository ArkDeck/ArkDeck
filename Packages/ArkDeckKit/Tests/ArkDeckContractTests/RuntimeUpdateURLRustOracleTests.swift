import Foundation
import XCTest

@testable import ArkDeckClientKit
@testable import ArkDeckCore

final class RuntimeUpdateURLRustOracleTests: XCTestCase {
  func testActualSwiftRequestAndRedirectURLsForRust() throws {
    let inputs = [
      "https://github.com/ArkDeck/a.dmg",
      "http://github.com/ArkDeck/a.dmg",
      "HTTPS://github.com/ArkDeck/a.dmg",
      "https://user@github.com/a.dmg",
      "https://github.com:443/a.dmg",
      "https://github.com/a.dmg#fragment",
      "https://github.com/a.dmg#",
      "https://evil.example/a.dmg",
      "https://127.0.0.1/a.dmg",
      "https://%67ithub.com/a.dmg",
      "https://GITHUB.COM/a.dmg",
      "https://github.com/a b.dmg",
      "https://github.com/a%20b.dmg",
      "https://github.com/%FF.dmg",
      "https://github.com/%ZZ.dmg",
      "https://github.com/a.dmg?x=[1]",
    ]
    var artifacts: [JSONValue] = []
    for input in inputs {
      var url: JSONValue = .null
      var error: JSONValue = .null
      do {
        let request = try UpdateRequestFactory.artifactRequest(signedURL: input)
        url = .string(try XCTUnwrap(request.url).absoluteString)
      }
      catch let failure { error = .string(String(describing: failure)) }
      artifacts.append(.object(["input": .string(input), "url": url, "error": error]))
    }
    var redirects: [JSONValue] = []
    for (input, count) in [
      ("https://release-assets.githubusercontent.com/a.dmg?appVersion=1&osVersion=14&arch=arm64&token=x%2By&empty&AppVersion=keep", 1),
      ("https://objects.githubusercontent.com/a.dmg?%61ppVersion=1&token=a%2Fb%3Fc%26d", 5),
      ("https://github.com/a.dmg?appVersion=1", 1),
      ("https://github.com/a.dmg?", 1),
      ("https://github.com/a.dmg", 6),
      ("http://github.com/a.dmg", 1),
      ("https://user@github.com/a.dmg", 1),
      ("https://github.com/a.dmg#", 1),
    ] {
      let proposed = try XCTUnwrap(URL(string: input))
      var url: JSONValue = .null
      var error: JSONValue = .null
      do {
        let request = try UpdateRedirectPolicy.redirectedRequest(
          proposed: URLRequest(url: proposed), redirectCount: count)
        url = .string(try XCTUnwrap(request.url).absoluteString)
      } catch let failure { error = .string(String(describing: failure)) }
      redirects.append(.object([
        "proposed": .string(proposed.absoluteString), "count": .integer(Int64(count)),
        "url": url, "error": error,
      ]))
    }
    var feeds: [JSONValue] = []
    for (app, os, arch) in [("1.2.3", "14.0.0", "arm64"), ("1.2.3+query?", "14 0", "arm&64")] {
      let request = try UpdateRequestFactory.feedRequest(identity: UpdateProductIdentity(
        appVersion: app, osVersion: os, architecture: arch))
      feeds.append(.object([
        "appVersion": .string(app), "osVersion": .string(os), "architecture": .string(arch),
        "url": .string(try XCTUnwrap(request.url).absoluteString),
        "method": .string(try XCTUnwrap(request.httpMethod)),
        "accept": .string(try XCTUnwrap(request.value(forHTTPHeaderField: "Accept"))),
        "userAgent": .string(try XCTUnwrap(request.value(forHTTPHeaderField: "User-Agent"))),
        "cookies": .bool(request.httpShouldHandleCookies),
      ]))
    }
    let output = try CanonicalJSONEncoders.canonicalPretty().encode(JSONValue.object([
      "producer": .string("RuntimeUpdateURLRustOracleTests"), "artifacts": .array(artifacts),
      "redirects": .array(redirects), "feeds": .array(feeds),
    ])) + Data("\n".utf8)
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    if ProcessInfo.processInfo.environment["ARKDECK_RUST_UPDATE_URL_RECORD"] != nil {
      try HDCOracleHarness.recordOrCompare(["urls.json": output], variable: "ARKDECK_RUST_UPDATE_URL_RECORD",
        oracle: repository.appending(path: "rust/tests/fixtures/runtime-update"))
    } else {
      XCTAssertEqual(output, try Data(contentsOf: repository.appending(path: "rust/tests/fixtures/runtime-update/urls.json")))
    }
  }
}

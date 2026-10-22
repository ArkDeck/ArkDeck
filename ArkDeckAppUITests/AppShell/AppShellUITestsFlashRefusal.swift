import XCTest

extension AppShellUITests {
  /// The typed ArkForge handshake refusal stays distinct from a generic probe
  /// failure: the device-access reason carries the wire code and daemon text.
  func testFlashArkForgeHandshakeRefusalShowsTypedReasonInBothLanguages() throws {
    let reason =
      "unsupportedProtocolVersion: ArkForge PROTOCOL_REFUSED: protocol major 2 is not compatible with 1"
    for language in ["(en)", "(zh-Hans)"] {
      try "--ui-test-runtime-history-empty".write(
        to: fixtureStateFileURL, atomically: true, encoding: .utf8)
      let app = launch(arguments: [
        "--ui-test-flash", "--ui-test-runtime-history", "--ui-test-devices",
        "--ui-test-flash-arkforge-handshake-refused",
        "--ui-test-fixture-state", fixtureStateFileURL.path, "-AppleLanguages", language,
      ])
      select("app.navigation.flash", in: app)
      toggleFlashDetails(in: app)
      let shown = element("flash.deviceAccess.reason", in: app)
      XCTAssertTrue(shown.waitForExistenceFast(timeout: 10))
      scrollIntoView(shown, in: app)
      assertDisplayed(shown, equals: reason, timeout: 10)
      let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
      attachment.name = "flash-handshake-refused-\(language)"
      attachment.lifetime = .keepAlways
      add(attachment)
      app.terminate()
    }
  }

  /// Exit 7 (content mismatch) and exit 9 (typed skip) are the verification
  /// document's own outcomes. The fixture never contacts a device.
  func testFlashVerifyExitCodesArePresentedInBothLanguages() throws {
    let cases: [(String, String, String)] = [
      ("--ui-test-flash-verify-exit-7", "Result: failed (exit 7)", "结果：failed（退出码 7）"),
      ("--ui-test-flash-verify-exit-9", "Result: partial (exit 9)", "结果：partial（退出码 9）"),
    ]
    for (flag, english, chinese) in cases {
      for (language, expected) in [("(en)", english), ("(zh-Hans)", chinese)] {
        try "--ui-test-runtime-flash-succeeded\n--ui-test-runtime-flash-canonical\n\(flag)".write(
          to: fixtureStateFileURL, atomically: true, encoding: .utf8)
        let app = launch(arguments: [
          "--ui-test-flash", "--ui-test-runtime-history", "--ui-test-devices",
          "--ui-test-fixture-state", fixtureStateFileURL.path, "-AppleLanguages", language,
        ])
        select("app.navigation.flash", in: app)
        let verify = element("flash.maintenance.verify", in: app)
        XCTAssertTrue(verify.waitForExistenceFast(timeout: 15))
        scrollIntoView(verify, in: app)
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: verify)
        waitForExpectations(timeout: 10)
        verify.click()
        let result = element("flash.maintenance.result", in: app)
        XCTAssertTrue(result.waitForExistenceFast(timeout: 10))
        scrollIntoView(result, in: app)
        assertDisplayed(result, equals: expected, timeout: 10)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "flash-verify-\(flag)-\(language)"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
      }
    }
  }
}

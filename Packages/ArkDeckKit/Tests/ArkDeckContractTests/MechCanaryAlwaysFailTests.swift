import XCTest

// CHG-2026-028 TASK-MECH-001 canary(丢弃分支专用,永不合入):
// 注入必败测试证明 swift-ci 会红(readiness r2 #333 形态)。
final class MechCanaryAlwaysFailTests: XCTestCase {
    func testCanaryMustFail() {
        XCTFail("MECH-001 canary: this test exists only to prove swift-ci turns red")
    }
}

import XCTest
@testable import Last9RUM

final class Last9RUMTests: XCTestCase {

    // MARK: - SessionStore

    func testSessionStoreCreatesSession() {
        let store = SessionStore()
        store.setCurrentSession(id: "test-session-1", previousId: nil, startedAt: Date())

        XCTAssertEqual(store.currentSessionId, "test-session-1")
        XCTAssertNil(store.previousSessionId)
    }

    func testSessionStoreRotatesSession() {
        let store = SessionStore()
        store.setCurrentSession(id: "session-1", previousId: nil, startedAt: Date())
        store.clearSession()
        store.setCurrentSession(id: "session-2", previousId: "session-1", startedAt: Date())

        XCTAssertEqual(store.currentSessionId, "session-2")
        XCTAssertEqual(store.previousSessionId, "session-1")
    }

    func testSessionStoreViewTracking() {
        let store = SessionStore()
        store.beginView(id: "view-1", name: "HomeView")

        XCTAssertEqual(store.currentViewId, "view-1")
        XCTAssertEqual(store.currentViewName, "HomeView")

        let timeSpent = store.endView()
        XCTAssertNotNil(timeSpent)
        XCTAssertNil(store.currentViewId)
        XCTAssertNil(store.currentViewName)
    }

    func testSessionStoreUserIdentity() {
        let store = SessionStore()
        let user = UserInfo(id: "u_123", name: "Alice", email: "alice@example.com")
        store.setUser(user)

        XCTAssertEqual(store.currentUser?.id, "u_123")
        XCTAssertEqual(store.currentUser?.name, "Alice")
        XCTAssertEqual(store.currentUser?.email, "alice@example.com")

        store.setUser(nil)
        XCTAssertNil(store.currentUser)
    }

    func testSessionStoreThreadSafety() {
        let store = SessionStore()
        let expectation = XCTestExpectation(description: "Concurrent access")
        expectation.expectedFulfillmentCount = 100

        for i in 0..<100 {
            DispatchQueue.global().async {
                store.setCurrentSession(id: "session-\(i)", previousId: nil, startedAt: Date())
                _ = store.currentSessionId
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - UserInfo

    func testUserInfoDefaults() {
        let user = UserInfo()
        XCTAssertNil(user.id)
        XCTAssertNil(user.name)
        XCTAssertNil(user.fullName)
        XCTAssertNil(user.email)
        XCTAssertTrue(user.extraInfo.isEmpty)
    }

    func testUserInfoExtraInfo() {
        let user = UserInfo(
            id: "u_1",
            extraInfo: ["plan": "pro", "region": "us-west-2"]
        )
        XCTAssertEqual(user.extraInfo["plan"], "pro")
        XCTAssertEqual(user.extraInfo["region"], "us-west-2")
    }

    // MARK: - PerformanceMonitor

    func testPerformanceMonitorReturnsSnapshot() {
        let snapshot = PerformanceMonitor.currentSnapshot()
        // CPU usage should be between 0 and some reasonable upper bound
        XCTAssertGreaterThanOrEqual(snapshot.cpuUsage, 0.0)
        // Memory should be > 0 (any running process uses memory)
        XCTAssertGreaterThan(snapshot.memoryBytes, 0)
    }
}

import XCTest
@testable import XiaoYuWorkspace

final class ProjectChangeMonitorTests: XCTestCase {
    @MainActor
    func testNestedExternalFileCreationNotifiesProject() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let nested = root.appending(path: "raw/deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let changed = expectation(description: "FSEvents reports a change below the project root")
        var didNotify = false
        let monitor = ProjectChangeMonitor(root: root) {
            if !didNotify {
                didNotify = true
                changed.fulfill()
            }
        }
        // Let FSEvents finish installing the stream before the external write.
        try await Task.sleep(for: .milliseconds(500))
        try Data("result".utf8).write(to: nested.appending(path: "sample.csv"))
        await fulfillment(of: [changed], timeout: 5)
        monitor.stop()
    }
}

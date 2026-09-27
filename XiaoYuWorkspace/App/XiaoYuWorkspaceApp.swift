import SwiftData
import SwiftUI

@main
struct XiaoYuWorkspaceApp: App {
    var body: some Scene {
        WindowGroup("小鱼工作台") {
            WorkspaceRootView()
        }
        .modelContainer(for: [ProjectRecord.self, FileAnnotationRecord.self,
                              JournalSubmissionRecord.self, JournalFileLinkRecord.self])
        .commands {
            WorkspaceCommands()
        }
        Settings {
            WorkspaceSettingsView()
        }
    }
}

import AppKit
import SwiftData
import SwiftUI

@main
struct XiaoYuWorkspaceApp: App {
    @AppStorage("appLanguage") private var appLanguage = "zh-Hans"

    init() {
        // Keep AppKit's menu bar in English; SwiftUI content uses appLanguage below
        UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
    }

    var body: some Scene {
        WindowGroup(appLanguage == "en" ? "XiaoYu Workspace" : "小鱼工作台") {
            WorkspaceRootView()
                .environment(\.locale, Locale(identifier: appLanguage))
                .onAppear { AppLanguage.scheduleEnglishMenuBar() }
                .onChange(of: appLanguage) { _, _ in AppLanguage.scheduleEnglishMenuBar() }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification)) { _ in
                    AppLanguage.scheduleEnglishMenuBar()
                }
        }
        .modelContainer(for: [ProjectRecord.self, FileAnnotationRecord.self,
                              JournalSubmissionRecord.self, JournalFileLinkRecord.self])
        .commands {
            WorkspaceCommands()
        }
        Settings {
            WorkspaceSettingsView()
                .environment(\.locale, Locale(identifier: appLanguage))
        }
    }
}

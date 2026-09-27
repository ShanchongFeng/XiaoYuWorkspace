import AppKit
import Foundation

enum AppLanguage {
    static func isEnglish(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier == "en"
    }

    static func text(_ key: String, locale: Locale) -> String {
        guard isEnglish(locale),
              let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func fileKind(_ kind: String, locale: Locale) -> String {
        guard isEnglish(locale) else { return kind }
        if kind.hasSuffix(" 文件") {
            return "\(kind.dropLast(3)) File"
        }
        return text(kind, locale: locale)
    }

    static func classificationExplanation(_ classification: FileClassification,
                                          locale: Locale) -> String {
        guard isEnglish(locale) else { return classification.explanation }
        switch classification.source {
        case .manual: return "Set manually"
        case .model: return "Jev classified this file from its extracted content"
        case .projectRule: return "Project rule: \(classification.explanation.dropFirst("项目规则：".count))"
        case .folderRule: return "Folder rule: \(classification.explanation.dropFirst("文件夹规则：".count))"
        case .filenameRule: return "File name rule: \(classification.explanation.dropFirst("文件名规则：".count))"
        case .compoundExtension, .extensionRegistry:
            return "File format: \(text(classification.format, locale: locale))"
        case .fallback: return "No matching rule"
        }
    }

    static func operationStatus(_ value: String, locale: Locale) -> String {
        guard isEnglish(locale) else { return value }
        let direct = text(value, locale: locale)
        if direct != value { return direct }
        var result = value
        let replacements: [(String, String)] = [
            ("正在扫描项目 ", "Scanning project "),
            ("正在逐个判断：", "Classifying files: "),
            ("没有需要自动分类的文件。已手动分类和已完成模型分类的文件会跳过。",
             "No files need classification; manual and previously classified files were skipped"),
            ("完成：处理 ", "Completed: processed "),
            (" 个文件，更新 ", " files; updated "),
            (" 个分类", " categories"),
            (" 个没有可用内容而跳过", " skipped for missing content"),
            (" 个失败，可重试。", " failed and can be retried"),
            ("已中断：", "Interrupted: "),
            ("已停止", "Stopped"),
            ("已完成 ", "Completed "),
            ("；已保存的结果可保留，下次运行会跳过。", "; saved results will be kept and skipped next time"),
            (" 个文件", " files"),
            (" 项", " items"),
            ("无法完成操作", "Could not complete operation"),
            ("无法打开此文件。", "Could not open this file"),
            ("文件操作已完成，但", "File operation completed, but "),
            ("注释同步失败：", "annotation sync failed: "),
            ("投稿文件关联同步失败：", "submission link sync failed: "),
            ("无法保存废纸篓记录：", "Could not save Trash record: "),
            ("投稿文件导出失败：", "Could not export submission files: "),
            ("封面无法保存：", "Could not save cover: "),
            ("封面无法导入：", "Could not import cover: "),
            ("无法选择封面：", "Could not select cover: "),
            ("更改已完成，但日志保存失败：", "Change completed, but activity log could not be saved: ")
        ]
        for (chinese, english) in replacements {
            result = result.replacingOccurrences(of: chinese, with: english)
        }
        return result
    }

    static func activityDetail(_ value: String, locale: Locale) -> String {
        operationStatus(value, locale: locale)
    }

    @MainActor
    static func keepMenuBarInEnglish() {
        guard let items = NSApplication.shared.mainMenu?.items, items.count >= 8 else { return }
        items[0].title = "XiaoYu Workspace"
        let titles = ["File", "Edit", "View", "File Operations", "Project", "Window", "Help"]
        for (index, title) in titles.enumerated() {
            items[index + 1].title = title
        }
    }

    @MainActor
    static func scheduleEnglishMenuBar() {
        Task { @MainActor in
            keepMenuBarInEnglish()
            try? await Task.sleep(for: .milliseconds(300))
            keepMenuBarInEnglish()
        }
    }
}

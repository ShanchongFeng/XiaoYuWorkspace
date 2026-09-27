import Foundation
import XCTest
@testable import XiaoYuWorkspace

final class AppLanguageTests: XCTestCase {
    func testEnglishLabelsAndChineseFallback() {
        let english = Locale(identifier: "en")
        let chinese = Locale(identifier: "zh-Hans")

        XCTAssertEqual(AppLanguage.text("概览", locale: english), "Overview")
        XCTAssertEqual(AppLanguage.text("投稿期刊", locale: english), "Submission Journals")
        XCTAssertEqual(AppLanguage.text("已发表", locale: english), "Published")
        XCTAssertEqual(AppLanguage.text("概览", locale: chinese), "概览")
        XCTAssertEqual(AppLanguage.text("User Project", locale: english), "User Project")
    }

    func testFileKindAndClassificationExplanation() {
        let english = Locale(identifier: "en")
        XCTAssertEqual(AppLanguage.fileKind("DOCX 文件", locale: english), "DOCX File")
        XCTAssertEqual(AppLanguage.fileKind("文件夹", locale: english), "Folder")

        let classification = FileClassification(
            workflow: .manuscript, domain: "通用", format: "Word 文稿",
            role: "稿件草稿", source: .manual, explanation: "手动指定")
        XCTAssertEqual(AppLanguage.classificationExplanation(classification, locale: english),
                       "Set manually")
    }
}

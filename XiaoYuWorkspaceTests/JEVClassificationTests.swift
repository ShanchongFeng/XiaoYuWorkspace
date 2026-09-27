import Foundation
import AppKit
import SwiftData
import XCTest
@testable import XiaoYuWorkspace

private actor ContentJEVStub: JEVModelClient {
    private(set) var requests: [JEVModelRequest] = []
    private var active = 0
    private(set) var peakActive = 0

    func generate(_ request: JEVModelRequest) async throws -> JEVModelResponse {
        requests.append(request)
        active += 1
        peakActive = max(peakActive, active)
        try? await Task.sleep(for: .milliseconds(60))
        active -= 1
        var answers: [String: JEVDecisionAnswer] = [:]
        let category = request.state["content"]?.contains("Figure panel") == true ? "figures" : "other"
        answers["category"] = JEVDecisionAnswer(type: .choice, choice: category,
                                                  noul: nil, confidence: 0.9, probabilities: nil)
        return JEVModelResponse(model: "test-jev", answers: answers, usage: nil)
    }
}

private actor ContextRetryJEVStub: JEVModelClient {
    private(set) var sizes: [Int] = []

    func generate(_ request: JEVModelRequest) async throws -> JEVModelResponse {
        sizes.append(JEVContextBudget.estimatedTokens(request.state["content"] ?? ""))
        if sizes.count == 1 { throw JEVModelError.contextTooLong }
        return JEVModelResponse(
            model: "test-jev",
            answers: ["category": JEVDecisionAnswer(type: .choice, choice: "analysis",
                                                       noul: nil, confidence: nil, probabilities: nil)],
            usage: nil)
    }
}

final class JEVClassificationTests: XCTestCase {
    func testContentBudgetUsesMostOfWindowAndKeepsDistantSections() {
        let content = "BEGIN" + String(repeating: "a", count: 115_000) +
            "MIDDLE" + String(repeating: "b", count: 85_000) + "END"
        let fitted = JEVContextBudget.fit(content)
        let estimate = JEVContextBudget.estimatedTokens(fitted)
        XCTAssertGreaterThan(estimate, 27_000)
        XCTAssertLessThanOrEqual(estimate, JEVContextBudget.maxEvidenceTokens)
        XCTAssertTrue(fitted.contains("BEGIN"))
        XCTAssertTrue(fitted.contains("MIDDLE"))
        XCTAssertTrue(fitted.contains("END"))
    }

    @MainActor
    func testJEVReadsEachLinkedFolderFileIndependently() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let primary = temporary.appending(path: "primary")
        let linked = temporary.appending(path: "linked")
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data("Plain protocol notes".utf8).write(to: primary.appending(path: "same.md"))
        try Data("Figure panel shows the result".utf8).write(to: linked.appending(path: "same.md"))
        let container = try ModelContainer(for: ProjectRecord.self, FileAnnotationRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let access = ProjectAccessService()
        let project = ProjectRecord(displayName: "Both", bookmarkData: try access.makeBookmark(for: primary),
                                    lastKnownPath: primary.path)
        let link = ProjectLinkedFolder(displayName: "linked",
                                       bookmarkData: try access.makeBookmark(for: linked),
                                       lastKnownPath: linked.path)
        project.linkedFolders = [link]
        context.insert(project)
        try context.save()
        let stub = ContentJEVStub()
        let model = WorkspaceModel()
        model.configureJEVClient(stub)
        model.configure(context: context)
        while model.isScanning { try await Task.sleep(for: .milliseconds(20)) }
        model.startAutoClassification(allProjects: false)
        for _ in 0..<250 where model.isAutoClassifying {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.isAutoClassifying, model.autoClassificationStatus)
        let main = try XCTUnwrap(model.file(at: "same.md"))
        let other = try XCTUnwrap(model.file(at: link.virtualRootPath + "/same.md"))
        XCTAssertEqual(model.classification(for: main).workflow, .other)
        XCTAssertEqual(model.classification(for: other).workflow, .figures)
        XCTAssertEqual(model.autoClassificationTotal, 2)
        let requests = await stub.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testContextLimitRetriesSameFileWithSmallerEvidence() async throws {
        let client = ContextRetryJEVStub()
        let content = String(repeating: "x", count: 100_000)
        let result = try await JEVFileClassifier.classify(excerpt: content, using: client)
        XCTAssertEqual(result, .analysis)
        let sizes = await client.sizes
        XCTAssertEqual(sizes.count, 2)
        XCTAssertLessThan(sizes[1], sizes[0])
    }

    @MainActor
    func testClassifiesExtractedContentAndPreservesManualChoice() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("Figure panel shows microscopy results.".utf8)
            .write(to: root.appending(path: "private_concept.txt"))
        try Data("Analysis notes from cohort A.".utf8)
            .write(to: root.appending(path: "second.md"))
        try Data("group,value\ntreated,42".utf8)
            .write(to: root.appending(path: "third.csv"))
        try Data("Protocol for experimental samples.".utf8)
            .write(to: root.appending(path: "fourth.md"))
        try Data("Submission letter".utf8).write(to: root.appending(path: "manual.txt"))
        try Data().write(to: root.appending(path: "blank.md"))
        try Data([0, 1, 2]).write(to: root.appending(path: "unsupported.bin"))
        try Data([0, 1, 2]).write(to: root.appending(path: "ignored.png"))

        let container = try ModelContainer(for: ProjectRecord.self, FileAnnotationRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let access = ProjectAccessService()
        let project = ProjectRecord(displayName: "Test", bookmarkData: try access.makeBookmark(for: root),
                                    lastKnownPath: root.path)
        context.insert(project)
        try context.save()

        let stub = ContentJEVStub()
        let model = WorkspaceModel()
        model.configureJEVClient(stub)
        model.configure(context: context)
        while model.isScanning { try await Task.sleep(for: .milliseconds(20)) }
        let manual = try XCTUnwrap(model.files.first { $0.name == "manual.txt" })
        model.setManualWorkflow(.submission, for: manual)

        model.startAutoClassification(allProjects: false)
        for _ in 0..<250 where model.isAutoClassifying {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.isAutoClassifying, model.autoClassificationStatus)
        let classified = try XCTUnwrap(model.files.first { $0.name == "private_concept.txt" })
        XCTAssertEqual(model.classification(for: classified).workflow, .figures)
        XCTAssertEqual(model.classification(for: classified).source, .model)
        XCTAssertEqual(model.classification(for: manual).workflow, .submission)
        XCTAssertEqual(model.annotation(for: manual)?.modelWorkflowRaw, nil)
        XCTAssertEqual(model.autoClassificationManualSkipped, 1)
        XCTAssertEqual(model.autoClassificationTotal, 5)
        XCTAssertEqual(model.autoClassificationNoContent, 1)
        XCTAssertEqual(model.autoClassificationChanged, 4)
        let requests = await stub.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.allSatisfy { $0.state.count == 1 && $0.questions.count == 1 })
        XCTAssertTrue(requests.contains { $0.state["content"]?.contains("Figure panel") == true })
        XCTAssertFalse(requests.contains { $0.state.values.joined().contains("private_concept") })
        let peakActive = await stub.peakActive
        XCTAssertGreaterThanOrEqual(peakActive, 2, "可处理文件应并发请求")
        XCTAssertLessThanOrEqual(peakActive, 3, "最多同时 3 个请求")

        model.setManualWorkflow(.analysis, for: classified)
        XCTAssertEqual(model.classification(for: classified).workflow, .analysis)
        model.setManualWorkflow(nil, for: classified)
        XCTAssertEqual(model.classification(for: classified).workflow, .figures)

        model.startAutoClassification(allProjects: false)
        for _ in 0..<250 where model.isAutoClassifying {
            try await Task.sleep(for: .milliseconds(20))
        }
        let requestsAfterRetry = await stub.requests
        XCTAssertEqual(requestsAfterRetry.count, 4, "已完成的模型分类应跳过")
    }

    func testXLSXUsesCellValuesAsEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let sheet = root.appending(path: "xl/worksheets")
        try FileManager.default.createDirectory(at: sheet, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let strings = #"<sst><si><t>experimental group</t></si><si><t>treated sample</t></si></sst>"#
        let cells = #"<worksheet><sheetData><row><c t="s"><v>0</v></c><c t="s"><v>1</v></c><c><v>42</v></c></row></sheetData></worksheet>"#
        let secondSheet = #"<worksheet><sheetData><row><c t="inlineStr"><is><t>follow-up results</t></is></c></row></sheetData></worksheet>"#
        try Data(strings.utf8).write(to: root.appending(path: "xl/sharedStrings.xml"))
        try Data(cells.utf8).write(to: sheet.appending(path: "sheet1.xml"))
        try Data(secondSheet.utf8).write(to: sheet.appending(path: "sheet2.xml"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        process.arguments = ["-q", "-r", "table.xlsx", "xl"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let scanned = try await ProjectScanService().scan(root: root)
        let file = try XCTUnwrap(scanned.first { $0.name == "table.xlsx" })
        let evidence = try await JEVContentExtractor().extract(
            from: root.appending(path: "table.xlsx"), file: file)
        XCTAssertTrue(evidence?.contains("experimental group") == true)
        XCTAssertTrue(evidence?.contains("treated sample") == true)
        XCTAssertTrue(evidence?.contains("42") == true)
        XCTAssertTrue(evidence?.contains("follow-up results") == true)
    }

    func testDOCXUsesDocumentBodyAsEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = NSAttributedString(string: "Manuscript body about reproductive toxicology.")
        let data = try text.data(from: NSRange(location: 0, length: text.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        let url = root.appending(path: "draft.docx")
        try data.write(to: url)
        let scanned = try await ProjectScanService().scan(root: root)
        let file = try XCTUnwrap(scanned.first { $0.name == "draft.docx" })
        let evidence = try await JEVContentExtractor().extract(from: url, file: file)
        XCTAssertTrue(evidence?.contains("reproductive toxicology") == true)
    }
}

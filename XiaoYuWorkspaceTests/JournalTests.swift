import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import XiaoYuWorkspace

final class JournalTests: XCTestCase {
    func testJournalZIPCombinesFilesFromDistinctRootsWithSameNames() throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let primary = temporary.appending(path: "primary")
        let linked = temporary.appending(path: "linked")
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data("one".utf8).write(to: primary.appending(path: "same.txt"))
        try Data("two".utf8).write(to: linked.appending(path: "same.txt"))
        let archive = temporary.appending(path: "combined.zip")
        let sources = [
            JournalArchiveService.Source(root: primary, relativePath: "same.txt",
                                         archivePath: "主文件夹/same.txt"),
            JournalArchiveService.Source(root: linked, relativePath: "same.txt",
                                         archivePath: "关联文件夹/linked/same.txt")
        ]
        try JournalArchiveService.createZIP(sources: sources, destination: archive)
        let extracted = temporary.appending(path: "extracted")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, extracted.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: extracted.appending(path: "主文件夹/same.txt"),
                                  encoding: .utf8), "one")
        XCTAssertEqual(try String(contentsOf: extracted.appending(path: "关联文件夹/linked/same.txt"),
                                  encoding: .utf8), "two")
        let originalArchive = try Data(contentsOf: archive)
        let duplicate = JournalArchiveService.Source(root: linked, relativePath: "same.txt",
                                                      archivePath: "主文件夹/same.txt")
        XCTAssertThrowsError(try JournalArchiveService.createZIP(
            sources: [sources[0], duplicate], destination: archive)) { error in
                XCTAssertTrue(error is JournalArchiveError)
            }
        XCTAssertEqual(try Data(contentsOf: archive), originalArchive)
    }

    func testJournalZIPExportsOnlyLinkedFilesWithTheirRelativePaths() throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let root = temporary.appending(path: "project")
        let extracted = temporary.appending(path: "extracted")
        try FileManager.default.createDirectory(at: root.appending(path: "draft"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "final"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data("first".utf8).write(to: root.appending(path: "draft/Manuscript.docx"))
        try Data("second".utf8).write(to: root.appending(path: "final/Manuscript.docx"))
        try Data("not linked".utf8).write(to: root.appending(path: "final/Notes.txt"))
        let archive = temporary.appending(path: "submission.zip")

        try JournalArchiveService.createZIP(root: root,
                                            relativePaths: ["draft/Manuscript.docx", "final/Manuscript.docx"],
                                            destination: archive)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, extracted.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: extracted.appending(path: "draft/Manuscript.docx"),
                                  encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: extracted.appending(path: "final/Manuscript.docx"),
                                  encoding: .utf8), "second")
        XCTAssertFalse(FileManager.default.fileExists(atPath: extracted.appending(path: "final/Notes.txt").path))
        XCTAssertEqual(try String(contentsOf: root.appending(path: "draft/Manuscript.docx"),
                                  encoding: .utf8), "first")

        let originalArchive = try Data(contentsOf: archive)
        XCTAssertThrowsError(try JournalArchiveService.createZIP(root: root,
                                                                  relativePaths: ["missing.pdf"],
                                                                  destination: archive))
        XCTAssertEqual(try Data(contentsOf: archive), originalArchive)
        XCTAssertThrowsError(try JournalArchiveService.createZIP(root: root,
                                                                  relativePaths: ["../outside.pdf"],
                                                                  destination: archive))
        try JournalArchiveService.createZIP(root: root,
                                            relativePaths: ["final/Manuscript.docx"],
                                            destination: archive)
        let replacement = temporary.appending(path: "replacement")
        let replacementProcess = Process()
        replacementProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        replacementProcess.arguments = ["-x", "-k", archive.path, replacement.path]
        try replacementProcess.run()
        replacementProcess.waitUntilExit()
        XCTAssertEqual(replacementProcess.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: replacement.appending(path: "draft/Manuscript.docx").path))
        XCTAssertEqual(try String(contentsOf: replacement.appending(path: "final/Manuscript.docx"),
                                  encoding: .utf8), "second")
        XCTAssertEqual(JournalArchiveService.suggestedFilename(for: "Nature/子刊"), "Nature-子刊.zip")
    }

    @MainActor
    func testManualCoverImportDownsamplesAndPersists() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appending(path: "chosen-cover.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 800,
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            imageURL as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let coverData = try JournalCoverService.importedCover(from: imageURL)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(coverData as CFData, nil))
        let thumbnail = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 360)
        XCTAssertTrue(coverData.count > 0)

        let configuration = ModelConfiguration(url: root.appending(path: "cover.store"))
        let projectID = UUID()
        do {
            let container = try ModelContainer(for: JournalSubmissionRecord.self,
                                               configurations: configuration)
            let service = JournalSubmissionService(context: ModelContext(container))
            let journal = try service.add(projectID: projectID, name: "Journal",
                                          website: "https://example.org")
            try service.saveCover(coverData, for: journal)
        }
        let reopened = try ModelContainer(for: JournalSubmissionRecord.self,
                                          configurations: configuration)
        let service = JournalSubmissionService(context: ModelContext(reopened))
        let journal = try XCTUnwrap(service.load(projectID: projectID).0.first)
        XCTAssertEqual(journal.coverImageData, coverData)
        XCTAssertNotNil(journal.coverFetchAttemptedAt)

        let invalidURL = root.appending(path: "not-an-image.png")
        try Data("invalid".utf8).write(to: invalidURL)
        XCTAssertThrowsError(try JournalCoverService.importedCover(from: invalidURL))
    }

    @MainActor
    func testAddingJournalModelsPreservesExistingProjects() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = ModelConfiguration(url: root.appending(path: "existing.store"))
        let projectID = UUID()
        do {
            let oldContainer = try ModelContainer(for: ProjectRecord.self, FileAnnotationRecord.self,
                                                  configurations: configuration)
            let oldContext = ModelContext(oldContainer)
            oldContext.insert(ProjectRecord(id: projectID, displayName: "Existing",
                                            bookmarkData: Data([1]), lastKnownPath: "/existing"))
            try oldContext.save()
        }
        let newContainer = try ModelContainer(for: ProjectRecord.self, FileAnnotationRecord.self,
                                              JournalSubmissionRecord.self, JournalFileLinkRecord.self,
                                              configurations: configuration)
        let newContext = ModelContext(newContainer)
        XCTAssertEqual(try newContext.fetch(FetchDescriptor<ProjectRecord>()).map(\.id), [projectID])
        XCTAssertTrue(try newContext.fetch(FetchDescriptor<JournalSubmissionRecord>()).isEmpty)
    }

    @MainActor
    func testJournalRecordsAreScopedAndDoNotTouchProjectFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "cover-letter.docx")
        try Data("original".utf8).write(to: fileURL)
        let databaseURL = root.appending(path: "journals.store")
        let configuration = ModelConfiguration(url: databaseURL)
        let firstProject = UUID()
        let secondProject = UUID()
        let journalID: UUID
        do {
            let container = try ModelContainer(for: JournalSubmissionRecord.self, JournalFileLinkRecord.self,
                                               configurations: configuration)
            let context = ModelContext(container)
            let service = JournalSubmissionService(context: context)
            let journal = try service.add(projectID: firstProject, name: "Nature",
                                          website: "https://www.nature.com")
            journalID = journal.id
            let files = try await ProjectScanService().scan(root: root)
            let file = try XCTUnwrap(files.first { $0.relativePath == "cover-letter.docx" })
            let links = try service.link([file], to: journal, existing: [])
            XCTAssertEqual(links.count, 1)
            XCTAssertEqual(try service.link([file], to: journal, existing: links).count, 0)
            XCTAssertEqual(try service.load(projectID: secondProject).0.count, 0)
            XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "original")
        }
        let reopened = try ModelContainer(for: JournalSubmissionRecord.self, JournalFileLinkRecord.self,
                                          configurations: configuration)
        let service = JournalSubmissionService(context: ModelContext(reopened))
        let (journals, links) = try service.load(projectID: firstProject)
        XCTAssertEqual(journals.map(\.id), [journalID])
        XCTAssertEqual(links.map(\.relativePath), ["cover-letter.docx"])
        try service.delete(journals[0], links: links)
        XCTAssertTrue(try service.load(projectID: firstProject).0.isEmpty)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "original")
    }

    @MainActor
    func testFailedCoverAttemptPersistsUntilWebsiteChanges() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = ModelConfiguration(url: root.appending(path: "cover-cache.store"))
        let projectID = UUID()
        do {
            let container = try ModelContainer(for: JournalSubmissionRecord.self,
                                               configurations: configuration)
            let service = JournalSubmissionService(context: ModelContext(container))
            let journal = try service.add(projectID: projectID, name: "Journal",
                                          website: "https://example.org/old")
            XCTAssertNil(journal.coverFetchAttemptedAt)
            try service.saveCover(nil, for: journal)
            XCTAssertNotNil(journal.coverFetchAttemptedAt)
        }
        let reopened = try ModelContainer(for: JournalSubmissionRecord.self,
                                          configurations: configuration)
        let service = JournalSubmissionService(context: ModelContext(reopened))
        let journal = try XCTUnwrap(service.load(projectID: projectID).0.first)
        XCTAssertNil(journal.coverImageData)
        let attemptedAt = try XCTUnwrap(journal.coverFetchAttemptedAt)
        try service.update(journal, name: "Renamed", website: "https://example.org/old")
        XCTAssertEqual(journal.coverFetchAttemptedAt, attemptedAt)
        try service.update(journal, name: "Renamed", website: "https://example.org/new")
        XCTAssertNil(journal.coverFetchAttemptedAt)
        XCTAssertNil(journal.coverImageData)
    }

    @MainActor
    func testJournalLinkFollowsExternalAndInAppRename() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "draft.pdf")
        try Data("draft".utf8).write(to: original)
        let container = try ModelContainer(for: JournalSubmissionRecord.self, JournalFileLinkRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let service = JournalSubmissionService(context: ModelContext(container))
        let journal = try service.add(projectID: UUID(), name: "Science", website: "https://science.org")
        let scanner = ProjectScanService()
        let before = try await scanner.scan(root: root)
        let link = try XCTUnwrap(service.link(before, to: journal, existing: []).first)
        try FileManager.default.moveItem(at: original, to: root.appending(path: "revised.pdf"))
        let after = try await scanner.scan(root: root)
        try service.reconcile([link], with: after)
        XCTAssertEqual(link.relativePath, "revised.pdf")
        XCTAssertTrue(JournalSubmissionService.matches(link, file: try XCTUnwrap(after.first)))
        try service.applyMoveReceipts([FileOperationReceipt(oldRelativePath: "revised.pdf",
                                                           newRelativePath: "final.pdf",
                                                           identityPreserved: true)], to: [link])
        XCTAssertEqual(link.relativePath, "final.pdf")
    }

    func testCoverMetadataPrefersOpenGraphAndResolvesRelativeURLs() {
        let html = """
        <link rel="icon" href="/icon.png">
        <meta name="twitter:image" content="/twitter.png">
        <meta content="/cover.jpg?x=1&amp;y=2" property="og:image">
        """
        let urls = JournalCoverService.imageCandidates(html: html,
                                                        base: URL(string: "https://example.org/journal/home")!)
        XCTAssertEqual(urls.first?.absoluteString, "https://example.org/cover.jpg?x=1&y=2")
        XCTAssertEqual(urls.last?.absoluteString, "https://example.org/icon.png")
        XCTAssertNil(JournalCoverService.validWebURL("file:///etc/passwd"))
    }

    func testFolderSelectionIncludesEveryDescendantWithoutMatchingSiblingPrefix() {
        let paths = ["draft", "draft/数据", "draft/数据/原始", "draft/a.docx",
                     "draft/数据/b.xlsx", "draft/数据/原始/c.pdf", "draft2/d.pdf"]
        let folders: Set<String> = ["draft", "draft/数据", "draft/数据/原始"]
        let files = paths.map { path in
            let name = (path as NSString).lastPathComponent
            let parent = (path as NSString).deletingLastPathComponent
            let directory = folders.contains(path)
            return ScannedFile(relativePath: path, name: name,
                               parentPath: parent == "." ? "" : parent,
                               isDirectory: directory, isPackage: false, isSymbolicLink: false,
                               size: nil, createdAt: nil, modifiedAt: nil,
                               contentTypeIdentifier: nil, resourceIdentifier: nil,
                               volumeIdentifier: nil,
                               classification: ClassificationEngine().classify(
                                name: name, relativePath: path, isDirectory: directory))
        }
        let selected = JournalFileSelection.expandedFiles(for: ["draft"], in: files)
        XCTAssertEqual(Set(selected.map(\.relativePath)),
                       ["draft/a.docx", "draft/数据/b.xlsx", "draft/数据/原始/c.pdf"])
        let available = JournalFileSelection.availableItems(
            in: files, linked: ["draft/a.docx"], query: "")
        XCTAssertEqual(available.folderFileCounts["draft"], 2)
        XCTAssertEqual(available.folderFileCounts["draft/数据"], 2)
        XCTAssertEqual(available.fileCount, 3)
        XCTAssertFalse(available.rows.contains { $0.relativePath == "draft/a.docx" })
    }

    @MainActor
    func testJournalWebsiteNormalization() {
        XCTAssertEqual(WorkspaceModel.normalizedJournalWebsite("example.org/path"), "https://example.org/path")
        XCTAssertNil(WorkspaceModel.normalizedJournalWebsite(""))
        XCTAssertNil(WorkspaceModel.normalizedJournalWebsite("file:///tmp/a"))
    }
}

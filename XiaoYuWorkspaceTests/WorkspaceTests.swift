import XCTest
import SwiftData
@testable import XiaoYuWorkspace

final class WorkspaceTests: XCTestCase {
    func testActivityLogPersistsTimestampedChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActivityLogStore(directory: directory)
        let first = ActivityEvent(action: "添加项目", detail: "Project A", projectName: "Project A",
                                  occurredAt: Date(timeIntervalSince1970: 100))
        let second = ActivityEvent(action: "置顶文件", detail: "draft/a.pdf", projectName: "Project A",
                                   occurredAt: Date(timeIntervalSince1970: 200))
        try await store.append(first)
        try await store.append(second)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.map(\.action), ["置顶文件", "添加项目"])
        XCTAssertEqual(loaded.map(\.occurredAt), [second.occurredAt, first.occurredAt])
        XCTAssertEqual(loaded.first?.detail, "draft/a.pdf")
    }

    @MainActor
    func testFolderNavigationKeepsSelectedFolder() {
        let model = WorkspaceModel()
        let projectID = UUID()
        model.selectedProjectID = projectID
        model.folderPath = "Raw Data/2026"
        model.navigate(to: .project(projectID))
        XCTAssertEqual(model.folderPath, "Raw Data/2026")
        model.navigate(to: .overview)
        XCTAssertEqual(model.folderPath, "")
    }

    func testIgnoreRulesPreserveMeaningfulHiddenFiles() {
        XCTAssertTrue(IgnoreRule.shouldIgnore(name: ".DS_Store"))
        XCTAssertTrue(IgnoreRule.shouldIgnore(name: ".git"))
        XCTAssertFalse(IgnoreRule.shouldIgnore(name: ".RData"))
        XCTAssertFalse(IgnoreRule.shouldIgnore(name: ".gitignore"))
    }

    func testScannerKeepsOriginalPathsAndDoesNotEnterPackagesOrSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appending(path: "Raw Data")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        try Data().write(to: raw.appending(path: "sample.fastq.gz"))
        let package = root.appending(path: "Draft.pages")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data().write(to: package.appending(path: "internal.xml"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "loop"), withDestinationURL: root)

        let files = try await ProjectScanService().scan(root: root)
        XCTAssertTrue(files.contains { $0.relativePath == "Raw Data/sample.fastq.gz" })
        XCTAssertTrue(files.contains { $0.relativePath == "Draft.pages" })
        XCTAssertFalse(files.contains { $0.relativePath == "Draft.pages/internal.xml" })
        XCTAssertTrue(files.contains { $0.relativePath == "loop" })
        XCTAssertLessThan(files.count, 10)
    }

    func testScannerDoesNotSkipSiblingsAfterIgnoredFileAtMultipleDepths() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let grandchild = root.appending(path: "draft/figures/raw")
        try FileManager.default.createDirectory(at: grandchild, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appending(path: ".DS_Store"))
        try Data().write(to: root.appending(path: "manuscript.docx"))
        try Data().write(to: root.appending(path: "draft/.DS_Store"))
        try Data().write(to: root.appending(path: "draft/notes.txt"))
        try Data().write(to: root.appending(path: "draft/figures/.DS_Store"))
        try Data().write(to: grandchild.appending(path: "figure.tiff"))

        let paths = Set(try await ProjectScanService().scan(root: root).map(\.relativePath))
        XCTAssertEqual(paths, ["manuscript.docx", "draft", "draft/notes.txt",
                               "draft/figures", "draft/figures/raw", "draft/figures/raw/figure.tiff"])
    }

    func testScannerResourceIdentitySurvivesFinderStyleRename() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "Figure_1.ai")
        try Data("figure".utf8).write(to: original)
        let scanner = ProjectScanService()
        let beforeFiles = try await scanner.scan(root: root)
        let before = try XCTUnwrap(beforeFiles.first)
        try FileManager.default.moveItem(at: original, to: root.appending(path: "Figure_final.ai"))
        let afterFiles = try await scanner.scan(root: root)
        let after = try XCTUnwrap(afterFiles.first)
        XCTAssertNotNil(before.resourceIdentifier)
        XCTAssertEqual(before.resourceIdentifier, after.resourceIdentifier)
        XCTAssertEqual(before.volumeIdentifier, after.volumeIdentifier)
        XCTAssertNotEqual(before.relativePath, after.relativePath)
    }

    @MainActor
    func testMultipleProjectsPersistWithoutOwningTheirFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "projects.store")
        let configuration = ModelConfiguration(url: databaseURL)
        do {
            let container = try ModelContainer(for: ProjectRecord.self, configurations: configuration)
            let context = ModelContext(container)
            for index in 1...3 {
                context.insert(ProjectRecord(displayName: "Project \(index)",
                                             bookmarkData: Data([UInt8(index)]),
                                             lastKnownPath: "/external/project-\(index)"))
            }
            try context.save()
        }
        let reopened = try ModelContainer(for: ProjectRecord.self, configurations: configuration)
        let projects = try ModelContext(reopened).fetch(FetchDescriptor<ProjectRecord>())
        XCTAssertEqual(projects.count, 3)
        XCTAssertEqual(Set(projects.map(\.lastKnownPath)), Set((1...3).map { "/external/project-\($0)" }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Library/Projects").path))
    }

    @MainActor
    func testProjectBookmarkResolvesRealFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let access = ProjectAccessService()
        let bookmark = try access.makeBookmark(for: folder)
        let project = ProjectRecord(displayName: "Fixture", bookmarkData: bookmark,
                                    lastKnownPath: folder.path)
        let resolved = try access.activate(project)
        XCTAssertEqual(resolved.lastPathComponent, folder.lastPathComponent)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: resolved.path))
        access.deactivate()
    }

    @MainActor
    func testLinkedFoldersMergeSameNamedFilesWithoutMixingAnnotations() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let primary = temporary.appending(path: "primary")
        let linked = temporary.appending(path: "linked")
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let primaryFile = primary.appending(path: "same.md")
        let linkedFile = linked.appending(path: "same.md")
        try Data("primary content".utf8).write(to: primaryFile)
        try Data("linked content".utf8).write(to: linkedFile)

        let container = try ModelContainer(for: ProjectRecord.self, FileAnnotationRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let access = ProjectAccessService()
        let project = ProjectRecord(displayName: "Multiple",
                                    bookmarkData: try access.makeBookmark(for: primary),
                                    lastKnownPath: primary.path)
        let link = ProjectLinkedFolder(displayName: "linked",
                                       bookmarkData: try access.makeBookmark(for: linked),
                                       lastKnownPath: linked.path)
        project.linkedFolders = [link]
        context.insert(project)
        try context.save()

        let model = WorkspaceModel()
        model.configure(context: context)
        while model.isScanning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(Set(model.files.map(\.relativePath)),
                       ["same.md", link.virtualRootPath, link.virtualRootPath + "/same.md"])
        let main = try XCTUnwrap(model.file(at: "same.md"))
        let other = try XCTUnwrap(model.file(at: link.virtualRootPath + "/same.md"))
        XCTAssertEqual(model.url(for: main)?.resolvingSymlinksInPath().path,
                       primaryFile.resolvingSymlinksInPath().path)
        XCTAssertEqual(model.url(for: other)?.resolvingSymlinksInPath().path,
                       linkedFile.resolvingSymlinksInPath().path)
        XCTAssertEqual(model.displayPath(other.relativePath), "关联文件夹/linked/same.md")
        XCTAssertTrue(model.classifyDroppedURLs([linkedFile], as: .figures))
        XCTAssertEqual(model.annotation(for: other)?.manualWorkflowRaw, WorkflowCategory.figures.rawValue)
        XCTAssertNil(model.annotation(for: main)?.manualWorkflowRaw)
        model.navigate(to: .allFiles)
        XCTAssertEqual(model.visibleFiles.count, 3)
    }

    @MainActor
    func testLinkedFoldersPersistWithPrimaryProjectRecord() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = ModelConfiguration(url: root.appending(path: "projects.store"))
        let link = ProjectLinkedFolder(displayName: "Second", bookmarkData: Data([2]),
                                       lastKnownPath: "/second")
        do {
            let container = try ModelContainer(for: ProjectRecord.self, configurations: config)
            let context = ModelContext(container)
            let project = ProjectRecord(displayName: "First", bookmarkData: Data([1]),
                                        lastKnownPath: "/first")
            XCTAssertTrue(project.linkedFolders.isEmpty)
            project.linkedFolders = [link]
            context.insert(project)
            try context.save()
        }
        let reopened = try ModelContainer(for: ProjectRecord.self, configurations: config)
        let project = try XCTUnwrap(ModelContext(reopened).fetch(FetchDescriptor<ProjectRecord>()).first)
        XCTAssertEqual(project.lastKnownPath, "/first")
        XCTAssertEqual(project.linkedFolders, [link])
    }

    @MainActor
    func testTemporaryAccessKeepsCurrentProjectActive() async throws {
        let first = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let second = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let access = ProjectAccessService()
        let active = ProjectRecord(displayName: "First", bookmarkData: try access.makeBookmark(for: first),
                                   lastKnownPath: first.path)
        let source = ProjectRecord(displayName: "Second", bookmarkData: try access.makeBookmark(for: second),
                                   lastKnownPath: second.path)
        _ = try access.activate(active)
        let resolved = try await access.withTemporaryAccess(to: source) { $0 }
        XCTAssertEqual(resolved.resolvingSymlinksInPath().path, second.resolvingSymlinksInPath().path)
        XCTAssertEqual(access.currentURL?.resolvingSymlinksInPath().path,
                       first.resolvingSymlinksInPath().path)
        access.deactivate()
    }

    @MainActor
    func testBatchFailureReportsCompletedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("saved".utf8).write(to: root.appending(path: "A.txt"))

        let container = try ModelContainer(for: ProjectRecord.self, FileAnnotationRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let access = ProjectAccessService()
        context.insert(ProjectRecord(displayName: "Batch", bookmarkData: try access.makeBookmark(for: root),
                                     lastKnownPath: root.path))
        try context.save()

        let model = WorkspaceModel()
        model.configure(context: context)
        model.selectedFilePaths = ["A.txt", "Missing.txt"]
        model.duplicateSelected()
        while model.isOperating { try await Task.sleep(for: .milliseconds(20)) }

        XCTAssertEqual(try String(contentsOf: root.appending(path: "A 2.txt"), encoding: .utf8), "saved")
        XCTAssertEqual(model.selectedFilePaths, ["A 2.txt"])
        XCTAssertTrue(model.errorMessage?.contains("已完成 1 项") == true)
    }

    @MainActor
    func testFavoriteUndoAndRedoPersist() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appending(path: "paper.pdf"))
        let container = try ModelContainer(for: ProjectRecord.self, FileAnnotationRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let access = ProjectAccessService()
        context.insert(ProjectRecord(displayName: "Undo", bookmarkData: try access.makeBookmark(for: root),
                                     lastKnownPath: root.path))
        try context.save()

        let model = WorkspaceModel()
        let undo = UndoManager()
        model.undoManager = undo
        model.configure(context: context)
        while model.isScanning { try await Task.sleep(for: .milliseconds(20)) }
        let file = try XCTUnwrap(model.files.first { $0.relativePath == "paper.pdf" })
        model.toggleFavorite(file)
        XCTAssertEqual(model.annotation(for: file)?.isFavorite, true)
        undo.undo()
        XCTAssertEqual(model.annotation(for: file)?.isFavorite, false)
        undo.redo()
        XCTAssertEqual(model.annotation(for: file)?.isFavorite, true)
    }

    @MainActor
    func testSidebarDropChangesOnlyClassificationAndPersists() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "sample.txt")
        try Data("research".utf8).write(to: source)
        let container = try ModelContainer(for: ProjectRecord.self, FileAnnotationRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let access = ProjectAccessService()
        let project = ProjectRecord(displayName: "Classify",
                                    bookmarkData: try access.makeBookmark(for: root),
                                    lastKnownPath: root.path)
        context.insert(project)
        try context.save()
        let model = WorkspaceModel()
        let undo = UndoManager()
        model.undoManager = undo
        model.configure(context: context)
        while model.isScanning { try await Task.sleep(for: .milliseconds(20)) }
        let file = try XCTUnwrap(model.files.first { $0.relativePath == "sample.txt" })
        let drag = WorkspaceDraggedFile(projectID: project.id,
                                        relativePath: file.relativePath, fileURL: source)
        XCTAssertFalse(model.classifyDroppedFiles([
            WorkspaceDraggedFile(projectID: UUID(), relativePath: file.relativePath, fileURL: source)
        ], as: .figures))
        XCTAssertTrue(model.classifyDroppedFiles([drag], as: .figures))
        XCTAssertEqual(model.classification(for: file).workflow, .figures)
        XCTAssertEqual(model.count(in: .figures), 1)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "research")
        let persisted = try FileAnnotationService(context: context).load(projectID: project.id)
        XCTAssertEqual(persisted.first?.manualWorkflowRaw, WorkflowCategory.figures.rawValue)
        undo.undo()
        XCTAssertEqual(model.classification(for: file).workflow, file.classification.workflow)
        undo.redo()
        XCTAssertEqual(model.classification(for: file).workflow, .figures)
        XCTAssertTrue(model.classifyDroppedURLs([source], as: .rawData))
        XCTAssertEqual(model.classification(for: file).workflow, .rawData)
        XCTAssertFalse(model.classifyDroppedURLs([root.appending(path: "outside.txt")], as: .figures))
    }

    @MainActor
    func testTrashRecordRestoresItemToOriginalProjectPath() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "restore-me.txt")
        try Data("kept".utf8).write(to: source)
        let container = try ModelContainer(for: ProjectRecord.self, FileAnnotationRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let access = ProjectAccessService()
        let project = ProjectRecord(displayName: "Trash",
                                    bookmarkData: try access.makeBookmark(for: root),
                                    lastKnownPath: root.path)
        context.insert(project)
        try context.save()
        let model = WorkspaceModel()
        model.configure(context: context)
        defer {
            for record in model.currentTrashRecords {
                try? FileManager.default.removeItem(at: record.resolvedURL)
                model.forgetTrashed(record)
            }
        }
        while model.isScanning { try await Task.sleep(for: .milliseconds(20)) }
        model.selectedFilePaths = ["restore-me.txt"]
        model.moveSelectedToTrash()
        while model.isOperating { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let record = try XCTUnwrap(model.currentTrashRecords.first)
        XCTAssertTrue(record.isAvailable)
        XCTAssertEqual(record.originalRelativePath, "restore-me.txt")
        XCTAssertTrue(TrashHistoryStore().load().contains { $0.id == record.id })
        model.restore(record)
        while model.isOperating { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "kept")
        XCTAssertTrue(model.currentTrashRecords.isEmpty)
    }

    @MainActor
    func testRepeatedLargeListReadsStayResponsive() {
        let model = WorkspaceModel()
        let classification = ClassificationEngine().classify(name: "sample.txt",
                                                             relativePath: "sample.txt")
        model.files = (0..<8_000).map { number in
            let name = "sample-\(number).txt"
            return ScannedFile(relativePath: name, name: name, parentPath: "",
                               isDirectory: false, isPackage: false, isSymbolicLink: false,
                               size: 10, createdAt: nil, modifiedAt: nil,
                               contentTypeIdentifier: nil, resourceIdentifier: nil,
                               volumeIdentifier: nil, classification: classification)
        }
        model.location = .allFiles
        XCTAssertEqual(model.visibleFiles.count, 8_000)
        let start = ContinuousClock.now
        var total = 0
        for _ in 0..<100 { total += model.visibleFiles.count }
        let elapsed = start.duration(to: ContinuousClock.now)
        XCTAssertEqual(total, 800_000)
        XCTAssertLessThan(elapsed, .seconds(3))
        XCTAssertEqual(model.count(in: classification.workflow), 8_000)
    }

    @MainActor
    func testInternalDropMovesByDefaultAndOptionCopies() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appending(path: "Figures"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("figure".utf8).write(to: root.appending(path: "plot.ai"))
        let container = try ModelContainer(for: ProjectRecord.self, FileAnnotationRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let access = ProjectAccessService()
        let project = ProjectRecord(displayName: "Drag", bookmarkData: try access.makeBookmark(for: root),
                                    lastKnownPath: root.path)
        context.insert(project)
        try context.save()
        let model = WorkspaceModel()
        model.configure(context: context)
        while model.isScanning { try await Task.sleep(for: .milliseconds(20)) }
        let folder = try XCTUnwrap(model.files.first { $0.relativePath == "Figures" })

        let first = WorkspaceDraggedFile(projectID: project.id, relativePath: "plot.ai",
                                         fileURL: root.appending(path: "plot.ai"))
        XCTAssertTrue(model.moveDroppedFiles([first], into: folder, copying: false))
        while model.isOperating { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "plot.ai").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "Figures/plot.ai").path))

        let second = WorkspaceDraggedFile(projectID: project.id, relativePath: "Figures/plot.ai",
                                          fileURL: root.appending(path: "Figures/plot.ai"))
        XCTAssertTrue(model.moveDroppedFiles([second], copying: true))
        while model.isOperating { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "Figures/plot.ai").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "plot.ai").path))
    }
}

import XCTest
@testable import XiaoYuWorkspace

final class FileOperationTests: XCTestCase {
    private let manager = FileManager.default

    func testCreateRenameCopyMoveDuplicateWithoutOverwrite() async throws {
        let root = try makeRoot()
        defer { try? manager.removeItem(at: root) }
        let service = FileOperationService()
        _ = try await service.createFolder(root: root, parentPath: "", name: "Figures")
        _ = try await service.createFolder(root: root, parentPath: "", name: "Submission")
        let original = root.appending(path: "Figures/Figure_1.ai")
        try Data("source".utf8).write(to: original)

        let renamed = try await service.rename(root: root, relativePath: "Figures/Figure_1.ai", newName: "Figure_final.ai")
        XCTAssertEqual(renamed.newRelativePath, "Figures/Figure_final.ai")
        XCTAssertTrue(manager.fileExists(atPath: root.appending(path: "Figures/Figure_final.ai").path))

        let copied = try await service.copy(root: root, relativePath: "Figures/Figure_final.ai", toFolder: "Submission")
        XCTAssertEqual(copied.newRelativePath, "Submission/Figure_final.ai")
        let copiedAgain = try await service.copy(root: root, relativePath: "Figures/Figure_final.ai", toFolder: "Submission")
        XCTAssertEqual(copiedAgain.newRelativePath, "Submission/Figure_final 2.ai")
        XCTAssertEqual(try Data(contentsOf: original.deletingLastPathComponent().appending(path: "Figure_final.ai")), Data("source".utf8))

        let duplicated = try await service.duplicate(root: root, relativePath: "Figures/Figure_final.ai")
        XCTAssertEqual(duplicated.newRelativePath, "Figures/Figure_final 2.ai")

        let moved = try await service.move(root: root, relativePath: "Figures/Figure_final.ai", toFolder: "Submission")
        XCTAssertEqual(moved.newRelativePath, "Submission/Figure_final 3.ai")
        XCTAssertFalse(manager.fileExists(atPath: root.appending(path: "Figures/Figure_final.ai").path))
        XCTAssertTrue(manager.fileExists(atPath: root.appending(path: "Submission/Figure_final 3.ai").path))
    }

    func testInvalidAndRecursiveMovesDoNotMutateFiles() async throws {
        let root = try makeRoot()
        defer { try? manager.removeItem(at: root) }
        let service = FileOperationService()
        _ = try await service.createFolder(root: root, parentPath: "", name: "A")
        _ = try await service.createFolder(root: root, parentPath: "A", name: "B")
        do {
            _ = try await service.move(root: root, relativePath: "A", toFolder: "A/B")
            XCTFail("Recursive move must fail")
        } catch FileOperationError.invalidDestination {}
        do {
            _ = try await service.copy(root: root, relativePath: "A", toFolder: "A/B")
            XCTFail("Recursive copy must fail")
        } catch FileOperationError.invalidDestination {}
        XCTAssertTrue(manager.fileExists(atPath: root.appending(path: "A/B").path))

        do {
            _ = try await service.createFolder(root: root, parentPath: "", name: "../escape")
            XCTFail("Invalid name must fail")
        } catch FileOperationError.invalidName {}
        XCTAssertFalse(manager.fileExists(atPath: root.deletingLastPathComponent().appending(path: "escape").path))
    }

    func testRenameCollisionPreservesBothFiles() async throws {
        let root = try makeRoot()
        defer { try? manager.removeItem(at: root) }
        try Data("one".utf8).write(to: root.appending(path: "one.txt"))
        try Data("two".utf8).write(to: root.appending(path: "two.txt"))
        do {
            _ = try await FileOperationService().rename(root: root, relativePath: "one.txt", newName: "two.txt")
            XCTFail("Collision must fail")
        } catch FileOperationError.collision {}
        XCTAssertEqual(try String(contentsOf: root.appending(path: "one.txt"), encoding: .utf8), "one")
        XCTAssertEqual(try String(contentsOf: root.appending(path: "two.txt"), encoding: .utf8), "two")
    }

    func testImportAndExportLeaveSourcesUntouched() async throws {
        let project = try makeRoot()
        let external = try makeRoot()
        defer {
            try? manager.removeItem(at: project)
            try? manager.removeItem(at: external)
        }
        let source = external.appending(path: "cells.fcs")
        try Data("original".utf8).write(to: source)
        let service = FileOperationService()

        let imported = try await service.importItem(root: project, sourceURL: source, toFolder: "")
        XCTAssertEqual(imported.newRelativePath, "cells.fcs")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: project.appending(path: "cells.fcs"), encoding: .utf8), "original")

        let exportURL = external.appending(path: "exported.fcs")
        try await service.exportItem(root: project, relativePath: "cells.fcs", destinationURL: exportURL)
        XCTAssertEqual(try String(contentsOf: exportURL, encoding: .utf8), "original")
        XCTAssertTrue(manager.fileExists(atPath: project.appending(path: "cells.fcs").path))

        do {
            try await service.exportItem(root: project, relativePath: "cells.fcs", destinationURL: exportURL)
            XCTFail("Export must not overwrite")
        } catch FileOperationError.collision {}
    }

    func testImportRejectsCopyingProjectIntoItself() async throws {
        let root = try makeRoot()
        defer { try? manager.removeItem(at: root) }
        do {
            _ = try await FileOperationService().importItem(root: root, sourceURL: root, toFolder: "")
            XCTFail("Project root cannot be imported into itself")
        } catch FileOperationError.invalidDestination {}
    }

    func testBrokenSymlinkCanBeRenamedWithoutFollowingIt() async throws {
        let root = try makeRoot()
        defer { try? manager.removeItem(at: root) }
        try manager.createSymbolicLink(at: root.appending(path: "broken-link"),
                                       withDestinationURL: root.appending(path: "missing"))
        let receipt = try await FileOperationService().rename(root: root,
                                                               relativePath: "broken-link",
                                                               newName: "renamed-link")
        XCTAssertEqual(receipt.newRelativePath, "renamed-link")
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: root.appending(path: "renamed-link").path),
                       root.appending(path: "missing").path)
    }

    func testCopyKeepsCompoundExtensionTogether() async throws {
        let root = try makeRoot()
        defer { try? manager.removeItem(at: root) }
        try Data().write(to: root.appending(path: "sample.fastq.gz"))
        let receipt = try await FileOperationService().copy(root: root,
                                                             relativePath: "sample.fastq.gz",
                                                             toFolder: "")
        XCTAssertEqual(receipt.newRelativePath, "sample 2.fastq.gz")
    }

    func testCopyBetweenProjectsKeepsSourceAndBothDestinationVersions() async throws {
        let sourceRoot = try makeRoot()
        let destinationRoot = try makeRoot()
        defer {
            try? manager.removeItem(at: sourceRoot)
            try? manager.removeItem(at: destinationRoot)
        }
        let source = sourceRoot.appending(path: "sample.fastq.gz")
        try Data("original".utf8).write(to: source)
        try Data("existing".utf8).write(to: destinationRoot.appending(path: "sample.fastq.gz"))

        let receipt = try await FileOperationService().copyBetweenProjects(
            sourceRoot: sourceRoot, relativePath: "sample.fastq.gz",
            destinationRoot: destinationRoot, toFolder: "")
        XCTAssertEqual(receipt.newRelativePath, "sample 2.fastq.gz")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: destinationRoot.appending(path: "sample.fastq.gz"), encoding: .utf8), "existing")
        XCTAssertEqual(try String(contentsOf: destinationRoot.appending(path: "sample 2.fastq.gz"), encoding: .utf8), "original")
    }

    func testCrossProjectCopyRejectsDestinationInsideSourceFolder() async throws {
        let root = try makeRoot()
        defer { try? manager.removeItem(at: root) }
        let source = root.appending(path: "Study")
        let nested = source.appending(path: "Output")
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        do {
            _ = try await FileOperationService().copyBetweenProjects(
                sourceRoot: root, relativePath: "Study", destinationRoot: nested, toFolder: "")
            XCTFail("Copying a folder into its own descendant must fail")
        } catch FileOperationError.invalidDestination {}
        XCTAssertFalse(manager.fileExists(atPath: nested.appending(path: "Study").path))
    }

    func testConflictStopAndReplacePreserveExpectedContents() async throws {
        let root = try makeRoot()
        defer { try? manager.removeItem(at: root) }
        let destination = root.appending(path: "Destination")
        try manager.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("new".utf8).write(to: root.appending(path: "sample.txt"))
        try Data("old".utf8).write(to: destination.appending(path: "sample.txt"))
        let service = FileOperationService()

        let hasConflict = try await service.hasConflict(root: root, toFolder: "Destination", name: "sample.txt")
        XCTAssertTrue(hasConflict)
        do {
            _ = try await service.copy(root: root, relativePath: "sample.txt",
                                       toFolder: "Destination", resolution: .stop)
            XCTFail("Stop must leave both files untouched")
        } catch FileOperationError.stopped {}
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "sample.txt"), encoding: .utf8), "old")

        let receipt = try await service.copy(root: root, relativePath: "sample.txt",
                                             toFolder: "Destination", resolution: .replace)
        XCTAssertEqual(receipt.replacedRelativePath, "Destination/sample.txt")
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "sample.txt"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: root.appending(path: "sample.txt"), encoding: .utf8), "new")
        XCTAssertFalse(try manager.contentsOfDirectory(atPath: destination.path)
            .contains { $0.hasPrefix(".xiaoyu-") })
    }

    func testReplacingFolderMovesSourceAndRemovesOldDestination() async throws {
        let root = try makeRoot()
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root.appending(path: "Source/Study"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appending(path: "Destination/Study"), withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: "Source/Study/new.txt"))
        try Data().write(to: root.appending(path: "Destination/Study/old.txt"))

        let receipt = try await FileOperationService().move(root: root, relativePath: "Source/Study",
                                                            toFolder: "Destination", resolution: .replace)
        XCTAssertEqual(receipt.replacedRelativePath, "Destination/Study")
        XCTAssertTrue(manager.fileExists(atPath: root.appending(path: "Destination/Study/new.txt").path))
        XCTAssertFalse(manager.fileExists(atPath: root.appending(path: "Destination/Study/old.txt").path))
        XCTAssertFalse(manager.fileExists(atPath: root.appending(path: "Source/Study").path))
    }

    func testCrossProjectCutCopiesThenMovesSourceToTrash() async throws {
        let sourceRoot = try makeRoot()
        let destinationRoot = try makeRoot()
        defer {
            try? manager.removeItem(at: sourceRoot)
            try? manager.removeItem(at: destinationRoot)
        }
        try Data("content".utf8).write(to: sourceRoot.appending(path: "data.txt"))

        let receipt = try await FileOperationService().moveBetweenProjects(
            sourceRoot: sourceRoot, relativePath: "data.txt",
            destinationRoot: destinationRoot, toFolder: "")
        defer {
            if let trashURL = receipt.trashedURL { try? manager.removeItem(at: trashURL) }
        }
        XCTAssertEqual(receipt.oldRelativePath, "data.txt")
        XCTAssertEqual(receipt.newRelativePath, "data.txt")
        XCTAssertFalse(manager.fileExists(atPath: sourceRoot.appending(path: "data.txt").path))
        XCTAssertEqual(try String(contentsOf: destinationRoot.appending(path: "data.txt"), encoding: .utf8),
                       "content")
        XCTAssertNotNil(receipt.trashedURL)
    }

    private func makeRoot() throws -> URL {
        let root = manager.temporaryDirectory.appending(path: UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

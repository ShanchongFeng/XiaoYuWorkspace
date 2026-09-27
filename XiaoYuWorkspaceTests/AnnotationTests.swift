import SwiftData
import XCTest
@testable import XiaoYuWorkspace

final class AnnotationTests: XCTestCase {
    @MainActor
    func testPinPersistsAndSortsFilesFirst() throws {
        let container = try ModelContainer(
            for: FileAnnotationRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let model = WorkspaceModel()
        model.configure(context: context)
        model.selectedProjectID = UUID()
        let first = file("a.txt", resource: "a")
        let last = file("z.txt", resource: "z")
        model.files = [first, last]
        model.location = .allFiles

        XCTAssertEqual(model.visibleFiles.map(\.name), ["a.txt", "z.txt"])
        model.togglePin(last)
        XCTAssertEqual(model.visibleFiles.map(\.name), ["z.txt", "a.txt"])
        XCTAssertNotNil(model.annotation(for: last)?.pinnedAt)
        XCTAssertNotNil(try context.fetch(FetchDescriptor<FileAnnotationRecord>()).first?.pinnedAt)
        model.togglePin(last)
        XCTAssertEqual(model.visibleFiles.map(\.name), ["a.txt", "z.txt"])
    }

    @MainActor
    func testAnnotationSurvivesInternalAndExternalRename() throws {
        let container = try ModelContainer(
            for: ProjectRecord.self, FileAnnotationRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = FileAnnotationService(context: ModelContext(container))
        let projectID = UUID()
        let original = file("Figures/Figure_1.ai", resource: "file-123")
        var records: [FileAnnotationRecord] = []
        let record = try service.record(for: original, projectID: projectID, in: &records)
        record.isFavorite = true
        record.note = "Keep source figure"
        record.tags = ["HMGCS2"]
        try service.save()

        try service.applyMoveReceipts([
            FileOperationReceipt(oldRelativePath: "Figures/Figure_1.ai",
                                 newRelativePath: "Submission/Figure_1.ai", identityPreserved: true)
        ], to: records)
        XCTAssertEqual(record.relativePath, "Submission/Figure_1.ai")
        XCTAssertTrue(record.isFavorite)
        XCTAssertEqual(record.note, "Keep source figure")

        try service.reconcile(records, with: [file("Submission/Figure_1_final.ai", resource: "file-123")])
        XCTAssertEqual(record.relativePath, "Submission/Figure_1_final.ai")
        XCTAssertEqual(record.tags, ["HMGCS2"])
    }

    @MainActor
    func testCopyDoesNotMoveOriginalAnnotation() throws {
        let container = try ModelContainer(
            for: FileAnnotationRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = FileAnnotationService(context: ModelContext(container))
        var records: [FileAnnotationRecord] = []
        let original = file("Figures/A.ai", resource: "a")
        let record = try service.record(for: original, projectID: UUID(), in: &records)
        try service.applyMoveReceipts([
            FileOperationReceipt(oldRelativePath: "Figures/A.ai", newRelativePath: "Figures/A 2.ai")
        ], to: records)
        XCTAssertEqual(record.relativePath, "Figures/A.ai")
    }

    @MainActor
    func testCrossProjectMoveTransfersAnnotationAfterReplacement() throws {
        let container = try ModelContainer(
            for: FileAnnotationRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = FileAnnotationService(context: ModelContext(container))
        let sourceID = UUID()
        let destinationID = UUID()
        var sourceRecords: [FileAnnotationRecord] = []
        var destinationRecords: [FileAnnotationRecord] = []
        let original = try service.record(for: file("Figures/A.ai", resource: "source"),
                                          projectID: sourceID, in: &sourceRecords)
        original.isFavorite = true
        original.note = "source note"
        _ = try service.record(for: file("A.ai", resource: "old-target"),
                               projectID: destinationID, in: &destinationRecords)
        try service.save()

        let receipt = FileOperationReceipt(oldRelativePath: "Figures/A.ai",
                                           newRelativePath: "A.ai", replacedRelativePath: "A.ai")
        try service.applyMoveReceipts([receipt], to: destinationRecords)
        try service.transferAnnotations(from: sourceID, to: destinationID, receipts: [receipt])

        XCTAssertTrue(try service.load(projectID: sourceID).isEmpty)
        let transferred = try XCTUnwrap(service.load(projectID: destinationID).first)
        XCTAssertEqual(try service.load(projectID: destinationID).count, 1)
        XCTAssertEqual(transferred.relativePath, "A.ai")
        XCTAssertTrue(transferred.isFavorite)
        XCTAssertEqual(transferred.note, "source note")
        XCTAssertNil(transferred.resourceIdentifier)
    }

    private func file(_ path: String, resource: String) -> ScannedFile {
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        return ScannedFile(
            relativePath: path, name: name, parentPath: parent,
            isDirectory: false, isPackage: false, isSymbolicLink: false,
            size: nil, createdAt: nil, modifiedAt: nil,
            contentTypeIdentifier: nil, resourceIdentifier: resource,
            volumeIdentifier: "volume-1",
            classification: ClassificationEngine().classify(name: name, relativePath: path)
        )
    }
}

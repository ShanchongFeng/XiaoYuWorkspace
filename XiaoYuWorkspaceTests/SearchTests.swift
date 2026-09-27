import XCTest
@testable import XiaoYuWorkspace

final class SearchTests: XCTestCase {
    func testSearchesPathClassificationTagsAndNotes() {
        let file = makeFile("Figures/HMGCS2_24M.tif")
        let annotation = FileAnnotationRecord(projectID: UUID(), file: file)
        annotation.tags = ["IHC"]
        annotation.note = "Reviewer 2 requested a larger label"
        let classification = file.classification

        XCTAssertTrue(SearchQuery("HMGCS2").matches(file: file, classification: classification, annotation: annotation))
        XCTAssertTrue(SearchQuery("type:tif category:figures").matches(file: file, classification: classification, annotation: annotation))
        XCTAssertTrue(SearchQuery("tag:IHC reviewer").matches(file: file, classification: classification, annotation: annotation))
        XCTAssertFalse(SearchQuery("tag:WB").matches(file: file, classification: classification, annotation: annotation))
    }

    func testSearchDomainAliasAndModifiedToday() {
        let file = makeFile("Raw Data/slide.svs", modifiedAt: .now)
        XCTAssertTrue(SearchQuery("domain:pathology modified:today")
            .matches(file: file, classification: file.classification, annotation: nil))
    }

    private func makeFile(_ path: String, modifiedAt: Date? = nil) -> ScannedFile {
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        return ScannedFile(relativePath: path, name: name, parentPath: parent,
                           isDirectory: false, isPackage: false, isSymbolicLink: false,
                           size: nil, createdAt: nil, modifiedAt: modifiedAt,
                           contentTypeIdentifier: nil, resourceIdentifier: nil,
                           volumeIdentifier: nil,
                           classification: ClassificationEngine().classify(name: name, relativePath: path))
    }
}

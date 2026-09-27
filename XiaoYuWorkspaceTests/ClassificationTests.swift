import XCTest
@testable import XiaoYuWorkspace

final class ClassificationTests: XCTestCase {
    private let engine = ClassificationEngine()

    func testCompoundExtensionsUseLongestSuffix() {
        XCTAssertEqual(CompoundExtensionParser.fileExtension(of: "sample.fastq.gz"), "fastq.gz")
        XCTAssertEqual(CompoundExtensionParser.fileExtension(of: "image.OME.TIFF"), "ome.tiff")
        XCTAssertEqual(CompoundExtensionParser.fileExtension(of: "scan.nii.gz"), "nii.gz")
        XCTAssertEqual(CompoundExtensionParser.fileExtension(of: "archive.tar.gz"), "tar.gz")
    }

    func testClassificationRegressionMatrix() {
        let cases: [(String, String, WorkflowCategory, String)] = [
            ("paper.pdf", "Literature/paper.pdf", .literature, "PDF"),
            ("Figure_4.pdf", "Figures/Figure_4.pdf", .figures, "PDF"),
            ("result.pzfx", "Statistics/result.pzfx", .statistics, "GraphPad Prism"),
            ("Figure_5.ai", "Figures/Figure_5.ai", .figures, "矢量图"),
            ("raw.czi", "Raw Data/Microscopy/raw.czi", .rawData, "显微成像"),
            ("slide.svs", "Raw Data/Pathology/slide.svs", .rawData, "数字病理切片"),
            ("project.qpproj", "Analysis/QuPath/project.qpproj", .analysis, "QuPath 项目"),
            ("cells.fcs", "Raw Data/Flow/cells.fcs", .rawData, "流式细胞术"),
            ("sample.fastq.gz", "Raw Data/sample.fastq.gz", .rawData, "FASTQ"),
            ("matrix.h5ad", "Processed Data/matrix.h5ad", .processedData, "AnnData H5AD"),
            ("object.rds", "Analysis/object.rds", .analysis, "R 数据"),
            ("manuscript_v12.docx", "Manuscript/manuscript_v12.docx", .manuscript, "Word 文稿"),
            ("response_to_reviewers.docx", "Revision/response_to_reviewers.docx", .submission, "Word 文稿"),
            ("protocol_WB.pdf", "Protocols/protocol_WB.pdf", .protocols, "PDF")
        ]
        for (name, path, workflow, format) in cases {
            let result = engine.classify(name: name, relativePath: path)
            XCTAssertEqual(result.workflow, workflow, path)
            XCTAssertEqual(result.format, format, path)
        }
    }

    func testAmbiguousFormatsRemainConservative() {
        for name in ["unknown.pdf", "data.h5", "capture.raw", "model.m", "metadata.xml"] {
            let result = engine.classify(name: name, relativePath: name)
            XCTAssertEqual(result.workflow, .other, name)
            XCTAssertEqual(result.domain, "通用", name)
        }
    }

    func testManualAndProjectRulePrecedence() {
        let rule = ProjectClassificationRule(pathComponent: "My Results", workflow: .processedData)
        let project = engine.classify(name: "figure_1.pdf", relativePath: "My Results/figure_1.pdf",
                                      projectRules: [rule])
        XCTAssertEqual(project.workflow, .processedData)
        XCTAssertEqual(project.source, .projectRule)

        let manual = engine.classify(name: "figure_1.pdf", relativePath: "My Results/figure_1.pdf",
                                     manualOverride: .literature, projectRules: [rule])
        XCTAssertEqual(manual.workflow, .literature)
        XCTAssertEqual(manual.source, .manual)
    }

    func testPathComponentsDoNotMatchPartialNames() {
        let result = engine.classify(name: "paper.pdf", relativePath: "NotLiterature/paper.pdf")
        XCTAssertEqual(result.workflow, .other)
    }
}

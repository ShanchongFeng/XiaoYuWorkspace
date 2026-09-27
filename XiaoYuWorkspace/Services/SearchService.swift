import Foundation

struct SearchQuery: Sendable {
    let terms: [Term]

    enum Term: Sendable {
        case text(String)
        case fileType(String)
        case category(String)
        case domain(String)
        case tag(String)
        case modifiedToday
    }

    init(_ input: String) {
        terms = input.split(whereSeparator: \.isWhitespace).map { part in
            let token = String(part)
            let lower = token.lowercased()
            if lower.hasPrefix("type:") { return .fileType(String(token.dropFirst(5))) }
            if lower.hasPrefix("category:") { return .category(String(token.dropFirst(9))) }
            if lower.hasPrefix("domain:") { return .domain(String(token.dropFirst(7))) }
            if lower.hasPrefix("tag:") { return .tag(String(token.dropFirst(4))) }
            if lower == "modified:today" { return .modifiedToday }
            return .text(token)
        }
    }

    func matches(file: ScannedFile, classification: FileClassification,
                 annotation: FileAnnotationRecord?) -> Bool {
        terms.allSatisfy { term in
            switch term {
            case .text(let value):
                return [file.name, file.relativePath, classification.workflow.rawValue,
                        classification.domain, classification.format, classification.role,
                        annotation?.note ?? ""].contains { contains($0, value) }
                    || (annotation?.tags.contains { contains($0, value) } ?? false)
            case .fileType(let value):
                return contains(classification.format, value)
                    || contains(CompoundExtensionParser.fileExtension(of: file.name), value)
            case .category(let value):
                return contains(classification.workflow.rawValue, value)
                    || Self.categoryAliases[classification.workflow]?.contains(where: { contains($0, value) }) == true
            case .domain(let value):
                return contains(classification.domain, value)
                    || Self.domainAliases[classification.domain]?.contains(where: { contains($0, value) }) == true
            case .tag(let value):
                return annotation?.tags.contains { contains($0, value) } ?? false
            case .modifiedToday:
                return file.modifiedAt.map(Calendar.current.isDateInToday) ?? false
            }
        }
    }

    private func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.localizedStandardContains(needle)
    }

    private static let categoryAliases: [WorkflowCategory: [String]] = [
        .literature: ["literature", "references"], .manuscript: ["manuscript"],
        .rawData: ["raw data"], .processedData: ["processed data"],
        .statistics: ["statistics"], .figures: ["figures"],
        .analysis: ["analysis"], .protocols: ["protocols"],
        .submission: ["submission"], .other: ["other"]
    ]

    private static let domainAliases: [String: [String]] = [
        "数字病理": ["pathology", "digital pathology"],
        "显微成像": ["microscopy"],
        "流式细胞术": ["flow", "flow cytometry"],
        "基因组学": ["genomics"],
        "单细胞": ["single-cell", "single cell"],
        "生物信息学": ["bioinformatics"],
        "统计学": ["statistics"]
    ]
}

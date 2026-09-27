import Foundation

enum WorkflowCategory: String, CaseIterable, Codable, Sendable {
    case literature = "文献"
    case manuscript = "稿件"
    case rawData = "原始数据"
    case processedData = "处理数据"
    case statistics = "统计"
    case figures = "图表"
    case analysis = "分析"
    case protocols = "实验方案"
    case submission = "投稿"
    case other = "其他"

    var symbol: String {
        switch self {
        case .literature: "books.vertical"
        case .manuscript: "doc.text"
        case .rawData: "externaldrive"
        case .processedData: "tablecells"
        case .statistics: "chart.bar.xaxis"
        case .figures: "photo"
        case .analysis: "curlybraces"
        case .protocols: "checklist"
        case .submission: "paperplane"
        case .other: "tray"
        }
    }
}

enum ClassificationSource: String, Codable, Sendable {
    case manual, model, projectRule, folderRule, filenameRule, compoundExtension, extensionRegistry, fallback
}

struct FileClassification: Codable, Hashable, Sendable {
    var workflow: WorkflowCategory
    var domain: String
    var format: String
    var role: String
    var source: ClassificationSource
    var explanation: String
}

struct ProjectClassificationRule: Sendable {
    let pathComponent: String
    let workflow: WorkflowCategory
}

struct FileTypeDescriptor: Sendable {
    let format: String
    let domain: String
    let workflow: WorkflowCategory
    let role: String
}

enum CompoundExtensionParser {
    private static let known = [
        "ome.tiff", "fastq.gz", "vcf.gz", "tar.gz", "fq.gz", "bam.bai",
        "ome.tif", "nii.gz", "bed.gz", "csv.gz", "tsv.gz", "fasta.gz", "fa.gz"
    ].sorted { $0.count > $1.count }

    static func fileExtension(of name: String) -> String {
        let lower = name.lowercased()
        if let match = known.first(where: { lower.hasSuffix(".\($0)") }) { return match }
        return URL(fileURLWithPath: lower).pathExtension
    }

    static func isCompound(_ ext: String) -> Bool { ext.contains(".") }
}

enum FileTypeRegistry {
    static let types: [String: FileTypeDescriptor] = {
        var result: [String: FileTypeDescriptor] = [:]
        func register(_ extensions: [String], _ format: String, _ domain: String = "通用",
                      _ workflow: WorkflowCategory = .other, _ role: String = "文件") {
            for ext in extensions {
                result[ext] = FileTypeDescriptor(format: format, domain: domain,
                                                 workflow: workflow, role: role)
            }
        }
        register(["pdf"], "PDF")
        register(["doc", "docx", "rtf"], "Word 文稿", "通用", .manuscript, "稿件草稿")
        register(["xlsx", "xls", "numbers", "csv", "tsv", "csv.gz", "tsv.gz"], "表格")
        register(["ppt", "pptx", "key"], "演示文稿")
        register(["pzfx", "pzf", "prism"], "GraphPad Prism", "统计学", .statistics, "统计分析")
        register(["ai", "eps", "svg"], "矢量图", "通用", .figures, "源图")
        register(["tif", "tiff", "png", "jpg", "jpeg", "psd"], "图像")
        register(["ome.tif", "ome.tiff"], "OME-TIFF", "显微成像", .rawData, "原始图像")
        register(["czi", "lif", "nd2", "vsi", "ims"], "显微成像", "显微成像", .rawData, "原始图像")
        register(["svs", "ndpi", "mrxs", "scn"], "数字病理切片", "数字病理", .rawData, "原始切片")
        register(["dcm", "dicom", "nii.gz"], "医学影像", "医学影像", .rawData, "原始影像")
        register(["fcs", "wsp"], "流式细胞术", "流式细胞术", .rawData, "原始数据")
        register(["fastq", "fq", "fastq.gz", "fq.gz"], "FASTQ", "基因组学", .rawData, "测序读段")
        register(["fasta", "fa", "fasta.gz", "fa.gz"], "FASTA", "基因组学", .analysis, "参考序列")
        register(["bam", "cram", "sam", "bam.bai"], "序列比对", "基因组学", .processedData, "比对数据")
        register(["vcf", "vcf.gz"], "变异数据", "基因组学", .processedData, "变异结果")
        register(["h5ad"], "AnnData H5AD", "单细胞", .processedData, "分析数据集")
        register(["rds", "rdata", "rda"], "R 数据", "生物信息学", .analysis, "分析数据集")
        register(["r", "rmd", "qmd", "rproj"], "R 脚本", "生物信息学", .analysis, "脚本")
        register(["py", "ipynb"], "Python / Notebook", "生物信息学", .analysis, "脚本")
        register(["qpproj"], "QuPath 项目", "数字病理", .analysis, "分析项目")
        register(["sh", "bash", "zsh"], "Shell 脚本", "通用", .analysis, "脚本")
        register(["zip", "tar", "tar.gz", "7z", "gz"], "压缩归档", "通用", .other, "归档")
        register(["h5", "hdf5"], "HDF5")
        register(["raw"], "RAW 文件")
        register(["m"], "M 源文件")
        register(["xml"], "XML")
        return result
    }()
}

struct ClassificationEngine: Sendable {
    func classify(name: String, relativePath: String, isDirectory: Bool = false,
                  manualOverride: WorkflowCategory? = nil,
                  projectRules: [ProjectClassificationRule] = []) -> FileClassification {
        let ext = CompoundExtensionParser.fileExtension(of: name)
        let descriptor = FileTypeRegistry.types[ext]
        let folderComponents = relativePath.split(separator: "/").dropLast().map(String.init)
        let workflow: WorkflowCategory
        let source: ClassificationSource
        let explanation: String

        if let manualOverride {
            workflow = manualOverride
            source = .manual
            explanation = "手动指定"
        } else if let rule = projectRules.first(where: { rule in
            folderComponents.contains { normalize($0) == normalize(rule.pathComponent) }
        }) {
            workflow = rule.workflow
            source = .projectRule
            explanation = "项目规则：\(rule.pathComponent)"
        } else if let match = FolderRuleEngine.match(components: isDirectory ? folderComponents + [name] : folderComponents) {
            workflow = match.category
            source = .folderRule
            explanation = "文件夹规则：\(match.component)"
        } else if let match = FilenameRuleEngine.match(name: name) {
            workflow = match
            source = .filenameRule
            explanation = "文件名规则：\(name)"
        } else if let descriptor {
            workflow = descriptor.workflow
            source = CompoundExtensionParser.isCompound(ext) ? .compoundExtension : .extensionRegistry
            explanation = "文件格式：\(descriptor.format)"
        } else {
            workflow = .other
            source = .fallback
            explanation = "暂无匹配规则"
        }

        let role: String
        if workflow == .literature { role = "参考文献" }
        else if workflow == .protocols { role = "实验方案" }
        else if workflow == .submission { role = "投稿文件" }
        else if workflow == .figures && ["ai", "eps", "svg", "psd"].contains(ext) { role = "源图" }
        else if workflow == .figures { role = "图表" }
        else { role = descriptor?.role ?? (isDirectory ? "文件夹" : "文件") }

        return FileClassification(workflow: workflow,
                                  domain: descriptor?.domain ?? "通用",
                                  format: isDirectory ? "文件夹" : descriptor?.format ?? "未知格式",
                                  role: role, source: source, explanation: explanation)
    }

    private func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum FolderRuleEngine {
    private static let rules: [(WorkflowCategory, Set<String>)] = [
        (.rawData, ["raw", "raw data", "original", "original data", "source data", "原始数据", "原始文件"]),
        (.processedData, ["processed", "processed data", "results", "output", "outputs", "derived", "结果", "处理数据"]),
        (.figures, ["fig", "figs", "figure", "figures", "plots", "graphics", "images", "图片", "图", "作图"]),
        (.literature, ["literature", "references", "refs", "papers", "articles", "文献", "参考文献"]),
        (.statistics, ["statistics", "stats", "统计"]),
        (.analysis, ["analysis", "scripts", "code", "src", "notebooks", "分析", "代码"]),
        (.submission, ["submission", "revision", "reviewer", "proof", "resubmission", "投稿", "返修", "审稿"]),
        (.protocols, ["protocol", "protocols", "method", "methods", "sop", "实验方案", "实验流程"]),
        (.manuscript, ["manuscript", "manuscripts", "稿件"])
    ]

    static func match(components: [String]) -> (category: WorkflowCategory, component: String)? {
        for component in components.reversed() {
            let normalized = component.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
                .replacingOccurrences(of: "_", with: " ")
            if let category = rules.first(where: { $0.1.contains(normalized) })?.0 {
                return (category, component)
            }
        }
        return nil
    }
}

enum FilenameRuleEngine {
    static func match(name: String) -> WorkflowCategory? {
        let lower = name.lowercased()
        if ["response_to_reviewers", "rebuttal", "cover_letter", "title_page", "highlights"].contains(where: lower.hasPrefix) {
            return .submission
        }
        if ["manuscript", "draft"].contains(where: lower.hasPrefix) { return .manuscript }
        if ["figure_", "fig_", "graphical_abstract"].contains(where: lower.hasPrefix) { return .figures }
        if ["protocol_", "sop_"].contains(where: lower.hasPrefix) { return .protocols }
        return nil
    }
}

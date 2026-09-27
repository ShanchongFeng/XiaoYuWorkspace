import Foundation

enum ProjectStage: String, CaseIterable, Identifiable {
    case planning = "筹备"
    case experiments = "实验中"
    case analysis = "数据分析"
    case writing = "论文撰写"
    case submissionPreparation = "投稿准备"
    case submitting = "投稿中"
    case submitted = "已投稿"
    case revision = "返修"
    case published = "已发表"

    var id: String { rawValue }
}

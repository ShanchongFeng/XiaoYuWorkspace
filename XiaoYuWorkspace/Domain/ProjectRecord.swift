import Foundation
import SwiftData

@Model
final class ProjectRecord {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var bookmarkData: Data
    var lastKnownPath: String
    var linkedFoldersData: Data?
    var status: String
    var targetJournal: String
    var projectDescription: String
    var isArchived: Bool
    var createdAt: Date
    var lastOpenedAt: Date?

    init(id: UUID = UUID(), displayName: String, bookmarkData: Data, lastKnownPath: String) {
        self.id = id
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.lastKnownPath = lastKnownPath
        self.linkedFoldersData = nil
        self.status = ProjectStage.planning.rawValue
        self.targetJournal = ""
        self.projectDescription = ""
        self.isArchived = false
        self.createdAt = .now
        self.lastOpenedAt = nil
    }

    var linkedFolders: [ProjectLinkedFolder] {
        get { (linkedFoldersData.flatMap { try? JSONDecoder().decode([ProjectLinkedFolder].self, from: $0) }) ?? [] }
        set { linkedFoldersData = try? JSONEncoder().encode(newValue) }
    }
}

struct ProjectLinkedFolder: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var displayName: String
    var bookmarkData: Data
    var lastKnownPath: String

    init(id: UUID = UUID(), displayName: String, bookmarkData: Data, lastKnownPath: String) {
        self.id = id
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.lastKnownPath = lastKnownPath
    }

    var virtualRootPath: String { "关联文件夹-\(id.uuidString)" }
}

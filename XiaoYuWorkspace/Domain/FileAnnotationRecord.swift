import Foundation
import SwiftData

@Model
final class FileAnnotationRecord {
    @Attribute(.unique) var id: UUID
    var projectID: UUID
    var relativePath: String
    var resourceIdentifier: String?
    var volumeIdentifier: String?
    var isFavorite: Bool
    var pinnedAt: Date?
    var tags: [String]
    var note: String
    var manualWorkflowRaw: String?
    var modelWorkflowRaw: String?
    var lastSeenAt: Date

    init(projectID: UUID, file: ScannedFile) {
        self.id = UUID()
        self.projectID = projectID
        self.relativePath = file.relativePath
        self.resourceIdentifier = file.resourceIdentifier
        self.volumeIdentifier = file.volumeIdentifier
        self.isFavorite = false
        self.pinnedAt = nil
        self.tags = []
        self.note = ""
        self.manualWorkflowRaw = nil
        self.modelWorkflowRaw = nil
        self.lastSeenAt = .now
    }

    init(projectID: UUID, relativePath: String, copying source: FileAnnotationRecord) {
        id = UUID()
        self.projectID = projectID
        self.relativePath = relativePath
        resourceIdentifier = nil
        volumeIdentifier = nil
        isFavorite = source.isFavorite
        pinnedAt = source.pinnedAt
        tags = source.tags
        note = source.note
        manualWorkflowRaw = source.manualWorkflowRaw
        modelWorkflowRaw = source.modelWorkflowRaw
        lastSeenAt = .now
    }
}

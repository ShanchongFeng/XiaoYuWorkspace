import Foundation
import SwiftData

@Model
final class JournalSubmissionRecord {
    @Attribute(.unique) var id: UUID
    var projectID: UUID
    var name: String
    var website: String
    @Attribute(.externalStorage) var coverImageData: Data?
    var coverFetchAttemptedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(projectID: UUID, name: String, website: String) {
        id = UUID()
        self.projectID = projectID
        self.name = name
        self.website = website
        coverImageData = nil
        coverFetchAttemptedAt = nil
        createdAt = .now
        updatedAt = .now
    }
}

@Model
final class JournalFileLinkRecord {
    @Attribute(.unique) var id: UUID
    var projectID: UUID
    var journalID: UUID
    var relativePath: String
    var resourceIdentifier: String?
    var volumeIdentifier: String?
    var createdAt: Date

    init(projectID: UUID, journalID: UUID, file: ScannedFile) {
        id = UUID()
        self.projectID = projectID
        self.journalID = journalID
        relativePath = file.relativePath
        resourceIdentifier = file.resourceIdentifier
        volumeIdentifier = file.volumeIdentifier
        createdAt = .now
    }
}

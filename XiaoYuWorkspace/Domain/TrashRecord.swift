import Foundation

struct TrashRecord: Codable, Hashable, Identifiable {
    let id: UUID
    let projectID: UUID
    let originalRelativePath: String
    let trashedURL: URL
    let trashBookmark: Data?
    let trashedAt: Date

    init(projectID: UUID, originalRelativePath: String, trashedURL: URL,
         trashBookmark: Data? = nil, trashedAt: Date = .now) {
        id = UUID()
        self.projectID = projectID
        self.originalRelativePath = originalRelativePath
        self.trashedURL = trashedURL
        self.trashBookmark = trashBookmark
        self.trashedAt = trashedAt
    }

    var name: String { (originalRelativePath as NSString).lastPathComponent }

    var resolvedURL: URL {
        guard let trashBookmark else { return trashedURL }
        var stale = false
        return (try? URL(resolvingBookmarkData: trashBookmark,
                         options: [.withSecurityScope], relativeTo: nil,
                         bookmarkDataIsStale: &stale)) ?? trashedURL
    }

    var isAvailable: Bool {
        let url = resolvedURL
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

struct TrashHistoryStore {
    private let defaults: UserDefaults
    private let key = "xiaoyu.trash.records.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [TrashRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([TrashRecord].self, from: data)) ?? []
    }

    func save(_ records: [TrashRecord]) throws {
        defaults.set(try JSONEncoder().encode(records), forKey: key)
    }
}

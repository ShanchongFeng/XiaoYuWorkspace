import Foundation

struct ActivityEvent: Codable, Identifiable, Sendable {
    let id: UUID
    let occurredAt: Date
    let action: String
    let detail: String
    let projectName: String?

    init(action: String, detail: String, projectName: String?, occurredAt: Date = .now) {
        id = UUID()
        self.occurredAt = occurredAt
        self.action = action
        self.detail = detail
        self.projectName = projectName
    }
}

actor ActivityLogStore {
    static let shared = ActivityLogStore()

    private let customDirectory: URL?

    init(directory: URL? = nil) {
        customDirectory = directory
    }

    func append(_ event: ActivityEvent) throws {
        let url = try logURL()
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        var data = try JSONEncoder().encode(event)
        data.append(0x0A)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func load() throws -> [ActivityEvent] {
        let url = try logURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap {
            try? decoder.decode(ActivityEvent.self, from: Data($0))
        }.sorted { $0.occurredAt > $1.occurredAt }
    }

    private func logURL() throws -> URL {
        let directory: URL
        if let customDirectory {
            directory = customDirectory
        } else {
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask, appropriateFor: nil, create: true)
            directory = support.appending(path: "小鱼工作台", directoryHint: .isDirectory)
        }
        return directory.appending(path: "ActivityLog.jsonl")
    }
}

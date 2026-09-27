import Foundation

actor IndexCacheService {
    private let directory: URL

    init() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        directory = support.appending(path: "小鱼工作台/Cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func load(projectID: UUID) -> [ScannedFile]? {
        let url = directory.appending(path: "\(projectID.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([ScannedFile].self, from: data)
    }

    func save(_ files: [ScannedFile], projectID: UUID) throws {
        let data = try JSONEncoder().encode(files)
        try data.write(to: directory.appending(path: "\(projectID.uuidString).json"), options: .atomic)
    }

    func remove(projectID: UUID) throws {
        let url = directory.appending(path: "\(projectID.uuidString).json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

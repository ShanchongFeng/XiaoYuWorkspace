import Foundation

@MainActor
final class ProjectAccessService {
    private var activeURL: URL?
    private var hasStartedAccess = false
    private var linkedURLs: [UUID: URL] = [:]
    private var linkedAccessStarted: Set<UUID> = []

    func makeBookmark(for folder: URL) throws -> Data {
        try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func activate(_ project: ProjectRecord) throws -> URL {
        if activeURL != nil { deactivate() }
        var stale = false
        let url = try URL(resolvingBookmarkData: project.bookmarkData,
                          options: .withSecurityScope, relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectAccessError.folderMissing
        }
        let started = url.startAccessingSecurityScopedResource()
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            if started { url.stopAccessingSecurityScopedResource() }
            throw ProjectAccessError.accessDenied
        }
        if stale {
            do {
                project.bookmarkData = try makeBookmark(for: url)
            } catch {
                if started { url.stopAccessingSecurityScopedResource() }
                throw error
            }
        }
        project.lastKnownPath = url.path
        activeURL = url
        hasStartedAccess = started
        var links = project.linkedFolders
        for index in links.indices {
            var staleLink = false
            guard let linkedURL = try? URL(resolvingBookmarkData: links[index].bookmarkData,
                                           options: .withSecurityScope, relativeTo: nil,
                                           bookmarkDataIsStale: &staleLink),
                  FileManager.default.fileExists(atPath: linkedURL.path) else { continue }
            let linkedStarted = linkedURL.startAccessingSecurityScopedResource()
            guard FileManager.default.isReadableFile(atPath: linkedURL.path) else {
                if linkedStarted { linkedURL.stopAccessingSecurityScopedResource() }
                continue
            }
            linkedURLs[links[index].id] = linkedURL
            if linkedStarted { linkedAccessStarted.insert(links[index].id) }
            if staleLink, let refreshed = try? makeBookmark(for: linkedURL) {
                links[index].bookmarkData = refreshed
            }
            links[index].lastKnownPath = linkedURL.path
        }
        if links != project.linkedFolders { project.linkedFolders = links }
        return url
    }

    func deactivate() {
        if hasStartedAccess { activeURL?.stopAccessingSecurityScopedResource() }
        for id in linkedAccessStarted { linkedURLs[id]?.stopAccessingSecurityScopedResource() }
        activeURL = nil
        hasStartedAccess = false
        linkedURLs = [:]
        linkedAccessStarted = []
    }

    var currentURL: URL? { activeURL }
    func linkedURL(for id: UUID) -> URL? { linkedURLs[id] }

    func activeMounts(for project: ProjectRecord) -> [(prefix: String, url: URL, name: String)] {
        var mounts: [(prefix: String, url: URL, name: String)] = []
        if let activeURL { mounts.append(("", activeURL, project.displayName)) }
        mounts += project.linkedFolders.compactMap { link in
            linkedURLs[link.id].map { (link.virtualRootPath, $0, link.displayName) }
        }
        return mounts
    }

    func resolveActivePath(_ virtualPath: String, in project: ProjectRecord)
        -> (root: URL, localPath: String, prefix: String)? {
        if let link = project.linkedFolders.first(where: {
            virtualPath == $0.virtualRootPath || virtualPath.hasPrefix($0.virtualRootPath + "/")
        }) {
            guard let root = linkedURLs[link.id] else { return nil }
            let local = virtualPath == link.virtualRootPath ? "" :
                String(virtualPath.dropFirst(link.virtualRootPath.count + 1))
            return (root, local, link.virtualRootPath)
        }
        guard let activeURL else { return nil }
        return (activeURL, virtualPath, "")
    }

    func withTemporaryAccess<T: Sendable>(to project: ProjectRecord,
                                          operation: @MainActor (URL) async throws -> T) async throws -> T {
        var stale = false
        let url = try URL(resolvingBookmarkData: project.bookmarkData,
                          options: .withSecurityScope, relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectAccessError.folderMissing
        }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ProjectAccessError.accessDenied
        }
        if stale { project.bookmarkData = try makeBookmark(for: url) }
        return try await operation(url)
    }

    func withTemporaryMounts<T: Sendable>(to project: ProjectRecord,
                                          operation: @MainActor ([(prefix: String, url: URL, name: String)]) async throws -> T)
        async throws -> T {
        var scoped: [URL] = []
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        var bookmarks: [(String, Data, String)] = [("", project.bookmarkData, project.displayName)]
        bookmarks += project.linkedFolders.map { ($0.virtualRootPath, $0.bookmarkData, $0.displayName) }
        var mounts: [(prefix: String, url: URL, name: String)] = []
        for (prefix, data, name) in bookmarks {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            guard FileManager.default.fileExists(atPath: url.path) else {
                if prefix.isEmpty { throw ProjectAccessError.folderMissing }
                continue
            }
            let started = url.startAccessingSecurityScopedResource()
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                if started { url.stopAccessingSecurityScopedResource() }
                if prefix.isEmpty { throw ProjectAccessError.accessDenied }
                continue
            }
            if started { scoped.append(url) }
            mounts.append((prefix, url, name))
        }
        return try await operation(mounts)
    }
}

enum ProjectAccessError: LocalizedError {
    case folderMissing
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .folderMissing: "项目文件夹已移动或不可用，请重新关联。"
        case .accessDenied: "无法读取项目文件夹，请重新授权访问。"
        }
    }
}

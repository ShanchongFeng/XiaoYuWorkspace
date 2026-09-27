import Foundation
import SwiftData

struct JournalPickerItems: Sendable {
    let rows: [ScannedFile]
    let fileCount: Int
    let folderFileCounts: [String: Int]
}

enum JournalFileSelection {
    static func expandedFiles(for paths: Set<String>, in files: [ScannedFile]) -> [ScannedFile] {
        let folders = files.filter { paths.contains($0.relativePath) && $0.isBrowsableFolder }
            .map { $0.relativePath + "/" }
        return files.filter { file in
            !file.isBrowsableFolder &&
                (paths.contains(file.relativePath) || folders.contains { file.relativePath.hasPrefix($0) })
        }
    }

    static func availableItems(in files: [ScannedFile], linked: Set<String>, query: String) -> JournalPickerItems {
        var folderFileCounts: [String: Int] = [:]
        let unlinkedFiles = files.filter { !$0.isBrowsableFolder && !linked.contains($0.relativePath) }
        for file in unlinkedFiles {
            var parent = file.parentPath
            while !parent.isEmpty && parent != "." {
                folderFileCounts[parent, default: 0] += 1
                let next = (parent as NSString).deletingLastPathComponent
                parent = next == "." ? "" : next
            }
        }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = files.filter { file in
            let available = file.isBrowsableFolder
                ? folderFileCounts[file.relativePath, default: 0] > 0
                : !linked.contains(file.relativePath)
            return available && (search.isEmpty || file.relativePath.localizedCaseInsensitiveContains(search))
        }.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return JournalPickerItems(rows: rows, fileCount: unlinkedFiles.count,
                                  folderFileCounts: folderFileCounts)
    }
}

@MainActor
final class JournalSubmissionService {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func load(projectID: UUID) throws -> ([JournalSubmissionRecord], [JournalFileLinkRecord]) {
        let journals = try context.fetch(FetchDescriptor<JournalSubmissionRecord>())
            .filter { $0.projectID == projectID }
            .sorted { $0.createdAt > $1.createdAt }
        let links = try context.fetch(FetchDescriptor<JournalFileLinkRecord>())
            .filter { $0.projectID == projectID }
        return (journals, links)
    }

    func add(projectID: UUID, name: String, website: String) throws -> JournalSubmissionRecord {
        let record = JournalSubmissionRecord(projectID: projectID, name: name, website: website)
        context.insert(record)
        try context.save()
        return record
    }

    func update(_ journal: JournalSubmissionRecord, name: String, website: String) throws {
        journal.name = name
        if journal.website != website {
            journal.website = website
            journal.coverImageData = nil
            journal.coverFetchAttemptedAt = nil
        }
        journal.updatedAt = .now
        try context.save()
    }

    func saveCover(_ data: Data?, for journal: JournalSubmissionRecord) throws {
        journal.coverImageData = data
        journal.coverFetchAttemptedAt = .now
        journal.updatedAt = .now
        try context.save()
    }

    func link(_ files: [ScannedFile], to journal: JournalSubmissionRecord,
              existing: [JournalFileLinkRecord]) throws -> [JournalFileLinkRecord] {
        let paths = Set(existing.filter { $0.journalID == journal.id }.map(\.relativePath))
        let additions = files.filter { !paths.contains($0.relativePath) }.map {
            JournalFileLinkRecord(projectID: journal.projectID, journalID: journal.id, file: $0)
        }
        for link in additions { context.insert(link) }
        try context.save()
        return additions
    }

    func unlink(_ link: JournalFileLinkRecord) throws {
        context.delete(link)
        try context.save()
    }

    func delete(_ journal: JournalSubmissionRecord, links: [JournalFileLinkRecord]) throws {
        for link in links where link.journalID == journal.id { context.delete(link) }
        context.delete(journal)
        try context.save()
    }

    func deleteProject(_ id: UUID) throws {
        let (journals, links) = try load(projectID: id)
        for link in links { context.delete(link) }
        for journal in journals { context.delete(journal) }
        try context.save()
    }

    func applyMoveReceipts(_ receipts: [FileOperationReceipt], to links: [JournalFileLinkRecord]) throws {
        for receipt in receipts where receipt.identityPreserved {
            guard let old = receipt.oldRelativePath, let new = receipt.newRelativePath else { continue }
            for link in links where link.relativePath == old || link.relativePath.hasPrefix(old + "/") {
                link.relativePath = new + String(link.relativePath.dropFirst(old.count))
            }
        }
        try context.save()
    }

    func reconcile(_ links: [JournalFileLinkRecord], with files: [ScannedFile]) throws {
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath, $0) })
        var byIdentity: [String: ScannedFile] = [:]
        var ambiguous: Set<String> = []
        for file in files {
            guard let key = Self.identity(file.resourceIdentifier, file.volumeIdentifier) else { continue }
            if byIdentity[key] != nil { ambiguous.insert(key) }
            else { byIdentity[key] = file }
        }
        for link in links {
            let key = Self.identity(link.resourceIdentifier, link.volumeIdentifier)
            if let exact = byPath[link.relativePath],
               key == Self.identity(exact.resourceIdentifier, exact.volumeIdentifier) { continue }
            if let key, !ambiguous.contains(key), let renamed = byIdentity[key] {
                link.relativePath = renamed.relativePath
            } else if key == nil, let exact = byPath[link.relativePath] {
                link.resourceIdentifier = exact.resourceIdentifier
                link.volumeIdentifier = exact.volumeIdentifier
            }
        }
        try context.save()
    }

    static func matches(_ link: JournalFileLinkRecord, file: ScannedFile) -> Bool {
        guard link.relativePath == file.relativePath else { return false }
        let expected = identity(link.resourceIdentifier, link.volumeIdentifier)
        let actual = identity(file.resourceIdentifier, file.volumeIdentifier)
        return expected == nil || actual == nil || expected == actual
    }

    private static func identity(_ resource: String?, _ volume: String?) -> String? {
        guard let resource, !resource.isEmpty else { return nil }
        return (volume ?? "") + "\0" + resource
    }
}

enum JournalArchiveError: LocalizedError {
    case noFiles
    case invalidPath(String)
    case missingFile(String)
    case archiveFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .noFiles: "这条期刊记录还没有关联投稿文件。"
        case .invalidPath(let path): "无法安全导出文件：\(path)"
        case .missingFile(let path): "关联文件已移动或无法读取：\(path)"
        case .archiveFailed(let status): "ZIP 打包失败（错误码 \(status)）。"
        }
    }
}

enum JournalArchiveService {
    struct Source: Sendable {
        let root: URL
        let relativePath: String
        let archivePath: String
    }

    static func suggestedFilename(for journalName: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\\n\r")
        let cleaned = journalName.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "投稿文件" : cleaned).prefix(80)) + ".zip"
    }

    static func createZIP(root: URL, relativePaths: [String], destination: URL) throws {
        try createZIP(sources: relativePaths.map {
            Source(root: root, relativePath: $0, archivePath: $0)
        }, destination: destination)
    }

    static func createZIP(sources: [Source], destination: URL) throws {
        guard !sources.isEmpty else { throw JournalArchiveError.noFiles }
        var archivePaths: Set<String> = []
        for source in sources {
            guard archivePaths.insert(source.archivePath).inserted else {
                throw JournalArchiveError.invalidPath(source.archivePath)
            }
        }
        let manager = FileManager.default
        var scopedRoots: [URL] = []
        for root in Set(sources.map(\.root)) {
            if root.startAccessingSecurityScopedResource() { scopedRoots.append(root) }
        }
        defer { scopedRoots.forEach { $0.stopAccessingSecurityScopedResource() } }
        let destinationAccess = destination.startAccessingSecurityScopedResource()
        defer { if destinationAccess { destination.stopAccessingSecurityScopedResource() } }

        let temporary = manager.temporaryDirectory.appendingPathComponent(
            "xiaoyu-journal-export-\(UUID().uuidString)", isDirectory: true)
        let stagedFiles = temporary.appendingPathComponent("files", isDirectory: true)
        try manager.createDirectory(at: stagedFiles, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        for item in sources.sorted(by: { $0.archivePath < $1.archivePath }) {
            try Task.checkCancellation()
            let sourceComponents = item.relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let archiveComponents = item.archivePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !item.relativePath.hasPrefix("/"), !item.archivePath.hasPrefix("/"),
                  sourceComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  archiveComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw JournalArchiveError.invalidPath(item.archivePath)
            }
            let resolvedRoot = item.root.resolvingSymlinksInPath().standardizedFileURL.path
            let rootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
            let source = sourceComponents.reduce(item.root) { $0.appendingPathComponent($1) }
                .resolvingSymlinksInPath().standardizedFileURL
            guard source.path.hasPrefix(rootPrefix) else {
                throw JournalArchiveError.invalidPath(item.archivePath)
            }
            guard manager.fileExists(atPath: source.path), manager.isReadableFile(atPath: source.path) else {
                throw JournalArchiveError.missingFile(item.archivePath)
            }
            let target = archiveComponents.reduce(stagedFiles) { $0.appendingPathComponent($1) }
            try manager.createDirectory(at: target.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            try manager.copyItem(at: source, to: target)
        }

        let archive = temporary.appendingPathComponent("submission.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl",
                             stagedFiles.path, archive.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              manager.fileExists(atPath: archive.path) else {
            throw JournalArchiveError.archiveFailed(process.terminationStatus)
        }
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: archive)
        } else {
            try manager.copyItem(at: archive, to: destination)
        }
    }
}

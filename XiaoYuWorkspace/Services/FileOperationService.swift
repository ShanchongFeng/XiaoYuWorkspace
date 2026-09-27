import Foundation
import Darwin

enum FileOperationError: LocalizedError {
    case invalidName
    case invalidPath
    case missingSource
    case invalidDestination
    case collision
    case stopped

    var errorDescription: String? {
        switch self {
        case .invalidName: "名称不能为空，也不能包含路径分隔符。"
        case .invalidPath: "路径不属于当前项目。"
        case .missingSource: "原文件已不存在，请刷新项目。"
        case .invalidDestination: "目标文件夹不可用，或位于待移动的文件夹内。"
        case .collision: "目标位置已有同名文件，请使用其他名称。"
        case .stopped: "已停止文件操作。"
        }
    }
}

enum ConflictResolution: Sendable {
    case keepBoth
    case replace
    case stop
}

struct PartialFileOperationError: LocalizedError {
    let receipt: FileOperationReceipt
    var errorDescription: String? { "目标副本已建立，但来源未能移到废纸篓；请检查两处文件。" }
}

struct FileOperationReceipt: Sendable {
    let oldRelativePath: String?
    let newRelativePath: String?
    let identityPreserved: Bool
    let replacedRelativePath: String?
    let trashedURL: URL?

    init(oldRelativePath: String?, newRelativePath: String?, identityPreserved: Bool = false,
         replacedRelativePath: String? = nil, trashedURL: URL? = nil) {
        self.oldRelativePath = oldRelativePath
        self.newRelativePath = newRelativePath
        self.identityPreserved = identityPreserved
        self.replacedRelativePath = replacedRelativePath
        self.trashedURL = trashedURL
    }
}

actor FileOperationService {
    private let manager = FileManager.default

    func createFolder(root: URL, parentPath: String, name: String) throws -> FileOperationReceipt {
        let parent = try directory(root: root, relativePath: parentPath)
        let name = try validName(name)
        let target = parent.appendingPathComponent(name, isDirectory: true)
        guard !pathExists(target) else { throw FileOperationError.collision }
        try manager.createDirectory(at: target, withIntermediateDirectories: false)
        return FileOperationReceipt(oldRelativePath: nil,
                                    newRelativePath: relativePath(parentPath, name))
    }

    func rename(root: URL, relativePath: String, newName: String) throws -> FileOperationReceipt {
        let source = try existingItem(root: root, relativePath: relativePath)
        let name = try validName(newName)
        let parent = source.deletingLastPathComponent()
        try ensureInside(root: root, directory: parent)
        let target = parent.appendingPathComponent(name)
        if source == target {
            return FileOperationReceipt(oldRelativePath: relativePath, newRelativePath: relativePath,
                                        identityPreserved: true)
        }
        guard !pathExists(target) else { throw FileOperationError.collision }
        try manager.moveItem(at: source, to: target)
        return FileOperationReceipt(oldRelativePath: relativePath,
                                    newRelativePath: self.relativePath((relativePath as NSString).deletingLastPathComponent == "." ? "" : (relativePath as NSString).deletingLastPathComponent, name),
                                    identityPreserved: true)
    }

    func duplicate(root: URL, relativePath: String) throws -> FileOperationReceipt {
        let source = try existingItem(root: root, relativePath: relativePath)
        let parent = source.deletingLastPathComponent()
        try ensureInside(root: root, directory: parent)
        let name = availableName(source.lastPathComponent, in: parent)
        let target = parent.appendingPathComponent(name)
        try copyItemSafely(from: source, to: target)
        let parentPath = (relativePath as NSString).deletingLastPathComponent
        return FileOperationReceipt(oldRelativePath: relativePath,
                                    newRelativePath: self.relativePath(parentPath == "." ? "" : parentPath, name))
    }

    func hasConflict(root: URL, toFolder destinationPath: String, name: String) throws -> Bool {
        let destination = try directory(root: root, relativePath: destinationPath)
        return pathExists(destination.appendingPathComponent(name))
    }

    func copy(root: URL, relativePath: String, toFolder destinationPath: String,
              resolution: ConflictResolution = .keepBoth) throws -> FileOperationReceipt {
        let source = try existingItem(root: root, relativePath: relativePath)
        let destination = try directory(root: root, relativePath: destinationPath)
        if destinationPath == relativePath || destinationPath.hasPrefix(relativePath + "/") {
            throw FileOperationError.invalidDestination
        }
        let effectiveResolution: ConflictResolution = source.deletingLastPathComponent() == destination
            ? .keepBoth : resolution
        let name = try resolvedName(source.lastPathComponent, in: destination, resolution: effectiveResolution)
        let target = destination.appendingPathComponent(name)
        let replacing = effectiveResolution == .replace && pathExists(target)
        try copyItemSafely(from: source, to: target, replacing: replacing)
        return FileOperationReceipt(oldRelativePath: relativePath,
                                    newRelativePath: self.relativePath(destinationPath, name),
                                    replacedRelativePath: replacing ? self.relativePath(destinationPath, name) : nil)
    }

    func copyBetweenProjects(sourceRoot: URL, relativePath: String,
                             destinationRoot: URL, toFolder destinationPath: String,
                             resolution: ConflictResolution = .keepBoth) throws -> FileOperationReceipt {
        let source = try existingItem(root: sourceRoot, relativePath: relativePath)
        let destination = try directory(root: destinationRoot, relativePath: destinationPath)
        if let sourcePath = canonical(source), let destinationPath = canonical(destination),
           (sourcePath == destinationPath || destinationPath.hasPrefix(sourcePath + "/")) {
            throw FileOperationError.invalidDestination
        }
        let requestedTarget = destination.appendingPathComponent(source.lastPathComponent)
        let effectiveResolution: ConflictResolution = canonical(source) == canonical(requestedTarget)
            ? .keepBoth : resolution
        let name = try resolvedName(source.lastPathComponent, in: destination, resolution: effectiveResolution)
        let target = destination.appendingPathComponent(name)
        let replacing = effectiveResolution == .replace && pathExists(target)
        try copyItemSafely(from: source, to: target, replacing: replacing)
        return FileOperationReceipt(oldRelativePath: nil,
                                    newRelativePath: self.relativePath(destinationPath, name),
                                    replacedRelativePath: replacing ? self.relativePath(destinationPath, name) : nil)
    }

    func moveBetweenProjects(sourceRoot: URL, relativePath: String,
                             destinationRoot: URL, toFolder destinationPath: String,
                             resolution: ConflictResolution = .keepBoth) throws -> FileOperationReceipt {
        let copied = try copyBetweenProjects(sourceRoot: sourceRoot, relativePath: relativePath,
                                             destinationRoot: destinationRoot, toFolder: destinationPath,
                                             resolution: resolution)
        let trashed: FileOperationReceipt
        do {
            trashed = try moveToTrash(root: sourceRoot, relativePath: relativePath)
        } catch {
            throw PartialFileOperationError(receipt: copied)
        }
        return FileOperationReceipt(oldRelativePath: relativePath,
                                    newRelativePath: copied.newRelativePath,
                                    replacedRelativePath: copied.replacedRelativePath,
                                    trashedURL: trashed.trashedURL)
    }

    func move(root: URL, relativePath: String, toFolder destinationPath: String,
              resolution: ConflictResolution = .keepBoth) throws -> FileOperationReceipt {
        let source = try existingItem(root: root, relativePath: relativePath)
        let destination = try directory(root: root, relativePath: destinationPath)
        if destinationPath == relativePath || destinationPath.hasPrefix(relativePath + "/") {
            throw FileOperationError.invalidDestination
        }
        if source.deletingLastPathComponent() == destination {
            return FileOperationReceipt(oldRelativePath: relativePath, newRelativePath: relativePath,
                                        identityPreserved: true)
        }
        let name = try resolvedName(source.lastPathComponent, in: destination, resolution: resolution)
        let target = destination.appendingPathComponent(name)
        let replacing = resolution == .replace && pathExists(target)
        try moveItemSafely(from: source, to: target, replacing: replacing)
        return FileOperationReceipt(oldRelativePath: relativePath,
                                    newRelativePath: self.relativePath(destinationPath, name),
                                    identityPreserved: true,
                                    replacedRelativePath: replacing ? self.relativePath(destinationPath, name) : nil)
    }

    func moveToTrash(root: URL, relativePath: String) throws -> FileOperationReceipt {
        let source = try existingItem(root: root, relativePath: relativePath)
        var trashURL: NSURL?
        try manager.trashItem(at: source, resultingItemURL: &trashURL)
        return FileOperationReceipt(oldRelativePath: relativePath, newRelativePath: nil,
                                    trashedURL: trashURL as URL?)
    }

    func restoreFromTrash(root: URL, originalRelativePath: String,
                          trashedURL: URL) throws -> FileOperationReceipt {
        guard trashedURL.isFileURL else { throw FileOperationError.invalidPath }
        let parentPath = (originalRelativePath as NSString).deletingLastPathComponent
        let parent = try directory(root: root, relativePath: parentPath == "." ? "" : parentPath)
        let name = try validName((originalRelativePath as NSString).lastPathComponent)
        let destination = parent.appendingPathComponent(name)
        guard !pathExists(destination) else { throw FileOperationError.collision }
        let accessStarted = trashedURL.startAccessingSecurityScopedResource()
        defer { if accessStarted { trashedURL.stopAccessingSecurityScopedResource() } }
        guard pathExists(trashedURL) else { throw FileOperationError.missingSource }
        try manager.moveItem(at: trashedURL, to: destination)
        return FileOperationReceipt(oldRelativePath: nil, newRelativePath: originalRelativePath)
    }

    func importItem(root: URL, sourceURL: URL, toFolder destinationPath: String,
                    resolution: ConflictResolution = .keepBoth) throws -> FileOperationReceipt {
        let destination = try directory(root: root, relativePath: destinationPath)
        let accessStarted = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessStarted { sourceURL.stopAccessingSecurityScopedResource() } }
        guard pathExists(sourceURL) else { throw FileOperationError.missingSource }
        if let source = canonical(sourceURL), let targetFolder = canonical(destination),
           (targetFolder == source || targetFolder.hasPrefix(source + "/")) {
            throw FileOperationError.invalidDestination
        }
        let requestedTarget = destination.appendingPathComponent(sourceURL.lastPathComponent)
        let effectiveResolution: ConflictResolution = canonical(sourceURL) == canonical(requestedTarget)
            ? .keepBoth : resolution
        let name = try resolvedName(sourceURL.lastPathComponent, in: destination, resolution: effectiveResolution)
        let finalURL = destination.appendingPathComponent(name)
        let replacing = effectiveResolution == .replace && pathExists(finalURL)
        try copyItemSafely(from: sourceURL, to: finalURL, replacing: replacing)
        return FileOperationReceipt(oldRelativePath: nil,
                                    newRelativePath: relativePath(destinationPath, name),
                                    replacedRelativePath: replacing ? relativePath(destinationPath, name) : nil)
    }

    func exportItem(root: URL, relativePath: String, destinationURL: URL) throws {
        let source = try existingItem(root: root, relativePath: relativePath)
        let accessStarted = destinationURL.startAccessingSecurityScopedResource()
        defer { if accessStarted { destinationURL.stopAccessingSecurityScopedResource() } }
        guard !pathExists(destinationURL) else {
            throw FileOperationError.collision
        }
        try manager.copyItem(at: source, to: destinationURL)
    }

    private func existingItem(root: URL, relativePath: String) throws -> URL {
        let url = try itemURL(root: root, relativePath: relativePath)
        guard pathExists(url) else { throw FileOperationError.missingSource }
        try ensureInside(root: root, directory: url.deletingLastPathComponent())
        return url
    }

    private func copyItemSafely(from source: URL, to target: URL, replacing: Bool = false) throws {
        if !replacing && pathExists(target) { throw FileOperationError.collision }
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".xiaoyu-copy-\(UUID().uuidString)")
        do {
            try manager.copyItem(at: source, to: staging)
            try moveItemSafely(from: staging, to: target, replacing: replacing)
        } catch {
            if pathExists(staging) { try? manager.removeItem(at: staging) }
            throw error
        }
    }

    private func moveItemSafely(from source: URL, to target: URL, replacing: Bool) throws {
        guard replacing && pathExists(target) else {
            guard !pathExists(target) else { throw FileOperationError.collision }
            try manager.moveItem(at: source, to: target)
            return
        }
        let backup = target.deletingLastPathComponent()
            .appendingPathComponent(".xiaoyu-backup-\(UUID().uuidString)")
        try manager.moveItem(at: target, to: backup)
        do {
            try manager.moveItem(at: source, to: target)
        } catch {
            try? manager.moveItem(at: backup, to: target)
            throw error
        }
        // Keep the old destination if cleanup fails; it can be recovered manually.
        try? manager.removeItem(at: backup)
    }

    private func resolvedName(_ name: String, in destination: URL,
                              resolution: ConflictResolution) throws -> String {
        guard pathExists(destination.appendingPathComponent(name)) else { return name }
        switch resolution {
        case .keepBoth: return availableName(name, in: destination)
        case .replace: return name
        case .stop: throw FileOperationError.stopped
        }
    }

    private func directory(root: URL, relativePath: String) throws -> URL {
        let url = relativePath.isEmpty ? root : try itemURL(root: root, relativePath: relativePath)
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileOperationError.invalidDestination
        }
        if !relativePath.isEmpty,
           (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw FileOperationError.invalidDestination
        }
        try ensureInside(root: root, directory: url)
        return url
    }

    private func itemURL(root: URL, relativePath: String) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw FileOperationError.invalidPath
        }
        return components.reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    private func ensureInside(root: URL, directory: URL) throws {
        guard let rootPath = canonical(root), let path = canonical(directory),
              (path == rootPath || path.hasPrefix(rootPath + "/")) else {
            throw FileOperationError.invalidPath
        }
    }

    private func canonical(_ url: URL) -> String? {
        guard let resolved = url.withUnsafeFileSystemRepresentation({ realpath($0, nil) }) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.contains("\0") else {
            throw FileOperationError.invalidName
        }
        return trimmed
    }

    private func relativePath(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }

    private func availableName(_ name: String, in directory: URL) -> String {
        if !pathExists(directory.appendingPathComponent(name)) { return name }
        let ext = CompoundExtensionParser.fileExtension(of: name)
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        for index in 2...10_000 {
            let candidate = "\(stem) \(index)\(ext.isEmpty ? "" : ".\(ext)")"
            if !pathExists(directory.appendingPathComponent(candidate)) {
                return candidate
            }
        }
        return "\(stem) \(UUID().uuidString)\(ext.isEmpty ? "" : ".\(ext)")"
    }

    private func pathExists(_ url: URL) -> Bool {
        var information = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return lstat(path, &information) == 0
        }
    }
}

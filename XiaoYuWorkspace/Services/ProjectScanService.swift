import Foundation
import Darwin
import UniformTypeIdentifiers

actor ProjectScanService {
    func scan(root: URL) throws -> [ScannedFile] {
        guard let resolved = root.withUnsafeFileSystemRepresentation({ realpath($0, nil) }) else {
            throw ProjectAccessError.folderMissing
        }
        defer { free(resolved) }
        let scanRoot = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let rootPrefix = scanRoot.path.hasSuffix("/") ? scanRoot.path : scanRoot.path + "/"
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
            .fileSizeKey, .creationDateKey, .contentModificationDateKey,
            .contentTypeKey, .fileResourceIdentifierKey, .volumeIdentifierKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: scanRoot, includingPropertiesForKeys: Array(keys),
            options: [], errorHandler: { _, _ in true }
        ) else { throw ProjectAccessError.accessDenied }

        var entries: [ScannedFile] = []
        let classifier = ClassificationEngine()
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let name = url.lastPathComponent
            let values: URLResourceValues
            do { values = try url.resourceValues(forKeys: keys) }
            catch { continue }
            let directory = values.isDirectory == true
            if IgnoreRule.shouldIgnore(name: name) {
                if directory { enumerator.skipDescendants() }
                continue
            }
            let package = values.isPackage == true || Self.packageExtensions.contains(url.pathExtension.lowercased())
            let symlink = values.isSymbolicLink == true
            if directory && (package || symlink) { enumerator.skipDescendants() }
            guard url.path.hasPrefix(rootPrefix) else { continue }
            let relative = String(url.path.dropFirst(rootPrefix.count))
            guard !relative.isEmpty else { continue }
            let parent = (relative as NSString).deletingLastPathComponent
            entries.append(ScannedFile(
                relativePath: relative, name: name,
                parentPath: parent == "." ? "" : parent,
                isDirectory: directory, isPackage: package, isSymbolicLink: symlink,
                size: directory ? nil : values.fileSize.map(Int64.init),
                createdAt: values.creationDate,
                modifiedAt: values.contentModificationDate,
                contentTypeIdentifier: values.contentType?.identifier,
                resourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
                volumeIdentifier: values.volumeIdentifier.map { String(describing: $0) },
                classification: classifier.classify(name: name, relativePath: relative,
                                                    isDirectory: directory && !package)
            ))
        }
        return entries
    }

    private static let packageExtensions: Set<String> = [
        "pages", "numbers", "key", "xcodeproj", "xcworkspace", "app", "bundle"
    ]
}

enum IgnoreRule {
    static let directoryNames: Set<String> = [
        ".Trashes", ".Spotlight-V100", ".fseventsd", ".git", "node_modules",
        "__pycache__", ".pytest_cache", ".ipynb_checkpoints", ".venv", "venv", "DerivedData"
    ]

    static func shouldIgnore(name: String) -> Bool {
        if name.hasPrefix(".xiaoyu-copy-") || name.hasPrefix(".xiaoyu-import-")
            || name.hasPrefix(".xiaoyu-backup-") { return true }
        if directoryNames.contains(name) { return true }
        if name == ".DS_Store" || name.hasPrefix("._") { return true }
        if name.hasPrefix("~$") || ["tmp", "swp", "lock"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) {
            return true
        }
        return false
    }
}

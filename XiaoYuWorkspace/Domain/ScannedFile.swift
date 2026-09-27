import Foundation

struct ScannedFile: Identifiable, Hashable, Codable, Sendable {
    let relativePath: String
    let name: String
    let parentPath: String
    let isDirectory: Bool
    let isPackage: Bool
    let isSymbolicLink: Bool
    let size: Int64?
    let createdAt: Date?
    let modifiedAt: Date?
    let contentTypeIdentifier: String?
    let resourceIdentifier: String?
    let volumeIdentifier: String?
    let classification: FileClassification

    var id: String { relativePath }
    var categoryName: String { classification.workflow.rawValue }
    var isBrowsableFolder: Bool { isDirectory && !isPackage && !isSymbolicLink }
    var kind: String {
        if isSymbolicLink { return "替身链接" }
        if isPackage { return "软件包" }
        if isDirectory { return "文件夹" }
        let ext = URL(fileURLWithPath: name).pathExtension.uppercased()
        return ext.isEmpty ? "文件" : "\(ext) 文件"
    }

    func mounted(at prefix: String) -> ScannedFile {
        guard !prefix.isEmpty else { return self }
        return ScannedFile(relativePath: prefix + "/" + relativePath,
                           name: name,
                           parentPath: parentPath.isEmpty ? prefix : prefix + "/" + parentPath,
                           isDirectory: isDirectory, isPackage: isPackage,
                           isSymbolicLink: isSymbolicLink, size: size,
                           createdAt: createdAt, modifiedAt: modifiedAt,
                           contentTypeIdentifier: contentTypeIdentifier,
                           resourceIdentifier: resourceIdentifier,
                           volumeIdentifier: volumeIdentifier,
                           classification: classification)
    }

    static func linkedFolderRow(_ link: ProjectLinkedFolder) -> ScannedFile {
        ScannedFile(relativePath: link.virtualRootPath, name: link.displayName, parentPath: "",
                    isDirectory: true, isPackage: false, isSymbolicLink: false,
                    size: nil, createdAt: nil, modifiedAt: nil, contentTypeIdentifier: nil,
                    resourceIdentifier: nil, volumeIdentifier: nil,
                    classification: ClassificationEngine().classify(name: link.displayName,
                                                                     relativePath: link.virtualRootPath,
                                                                     isDirectory: true))
    }
}

enum WorkspaceLocation: Hashable {
    case allProjects
    case project(UUID)
    case overview
    case journals
    case allFiles
    case recent
    case favorites
    case trash
    case category(String)
}

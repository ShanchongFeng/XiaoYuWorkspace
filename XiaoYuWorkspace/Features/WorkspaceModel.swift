import AppKit
import Foundation
import Observation
import SwiftData
import UniformTypeIdentifiers

@MainActor @Observable
final class WorkspaceModel {
    private enum AutoClassificationOutcome: Sendable {
        case decision(WorkflowCategory)
        case noContent
        case extractionFailed
        case invalidAnswer
        case requestFailed(String)
        case cancelled
    }

    private struct AutoClassificationRunError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    private struct VisibleFilesKey: Equatable {
        let fileRevision: Int
        let annotationRevision: Int
        let location: WorkspaceLocation?
        let folderPath: String
        let searchQuery: String
        let sortRevision: Int
    }
    private struct AnnotationSnapshot: Equatable {
        let isFavorite: Bool
        let pinnedAt: Date?
        let tags: [String]
        let note: String
        let manualWorkflowRaw: String?
        let modelWorkflowRaw: String?

        init(_ record: FileAnnotationRecord) {
            isFavorite = record.isFavorite
            pinnedAt = record.pinnedAt
            tags = record.tags
            note = record.note
            manualWorkflowRaw = record.manualWorkflowRaw
            modelWorkflowRaw = record.modelWorkflowRaw
        }

        func apply(to record: FileAnnotationRecord) {
            record.isFavorite = isFavorite
            record.pinnedAt = pinnedAt
            record.tags = tags
            record.note = note
            record.manualWorkflowRaw = manualWorkflowRaw
            record.modelWorkflowRaw = modelWorkflowRaw
        }
    }
    struct ConflictPrompt: Identifiable {
        let id = UUID()
        let name: String
        let destination: String
    }
    var projects: [ProjectRecord] = []
    var journals: [JournalSubmissionRecord] = []
    var journalFileLinks: [JournalFileLinkRecord] = []
    var loadingJournalCovers: Set<UUID> = []
    var exportingJournalIDs: Set<UUID> = []
    var location: WorkspaceLocation?
    var selectedProjectID: UUID?
    var selectedFilePaths: Set<String> = []
    var folderPath = ""
    var files: [ScannedFile] = [] {
        didSet {
            filesByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath, $0) })
            fileRevision += 1
            rebuildCategoryCounts()
        }
    }
    private var fileRevision = 0
    @ObservationIgnored private var filesByPath: [String: ScannedFile] = [:]
    var sortOrder: [KeyPathComparator<ScannedFile>] = [.init(\.name)] {
        didSet { sortRevision += 1 }
    }
    private var sortRevision = 0
    @ObservationIgnored private var visibleFilesCache: (key: VisibleFilesKey, rows: [ScannedFile])?
    var annotations: [FileAnnotationRecord] = []
    @ObservationIgnored private var annotationIndex: [String: FileAnnotationRecord] = [:]
    private var annotationRevision = 0
    private var categoryCounts: [WorkflowCategory: Int] = [:]
    var trashRecords: [TrashRecord] = []
    var isScanning = false
    var inspectorPresented = false
    var errorMessage: String?
    var searchQuery = ""
    var previewURL: URL?
    var newFolderPresented = false
    var renameRequest: ScannedFile?
    var isOperating = false
    var operationCompleted = 0
    var operationTotal = 0
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    var conflictPrompt: ConflictPrompt?
    @ObservationIgnored private var conflictContinuation: CheckedContinuation<ConflictResolution, Never>?
    @ObservationIgnored private var applyToAllResolution: ConflictResolution?

    private struct ClipboardState {
        let projectID: UUID
        let paths: [String]
        let isCut: Bool
    }
    private struct BatchFailure: Error {
        let receipts: [FileOperationReceipt]
        let itemName: String
        let reason: String
    }
    private var clipboard: ClipboardState?

    private var context: ModelContext?
    var undoManager: UndoManager?
    private var annotationService: FileAnnotationService?
    private var journalService: JournalSubmissionService?
    @ObservationIgnored private var pendingTextLogs: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var isBatchClassifying = false
    @ObservationIgnored private var jevClient: any JEVModelClient = OpenRouterJEVModelClient()
    var isAutoClassifying = false
    var autoClassificationPreparing = false
    var autoClassificationStatus = ""
    var autoClassificationCompleted = 0
    var autoClassificationTotal = 0
    var autoClassificationChanged = 0
    var autoClassificationManualSkipped = 0
    var autoClassificationNoContent = 0
    var autoClassificationFailed = 0
    @ObservationIgnored private var autoClassificationTask: Task<Void, Never>?
    private let coverService = JournalCoverService()
    @ObservationIgnored private var coverTasks: [UUID: Task<Void, Never>] = [:]
    private let access = ProjectAccessService()
    private let scanner = ProjectScanService()
    private let fileOpen = FileOpenService()
    private let operations = FileOperationService()
    private let trashHistory = TrashHistoryStore()
    private let cache = try? IndexCacheService()
    private var scanTask: Task<Void, Never>?
    private var changeMonitors: [ProjectChangeMonitor] = []
    private var changeRefreshTask: Task<Void, Never>?

    var currentProject: ProjectRecord? {
        projects.first { $0.id == selectedProjectID }
    }

    var currentRoot: URL? { access.currentURL }
    var currentLinkedFolders: [ProjectLinkedFolder] { currentProject?.linkedFolders ?? [] }

    private func resolvedPath(_ virtualPath: String) -> (root: URL, localPath: String, prefix: String)? {
        guard let currentProject else { return nil }
        return access.resolveActivePath(virtualPath, in: currentProject)
    }

    private func virtualPath(for url: URL) -> String? {
        guard let currentProject else { return nil }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let mounts = access.activeMounts(for: currentProject)
            .sorted { $0.url.path.count > $1.url.path.count }
        for mount in mounts {
            let root = mount.url.resolvingSymlinksInPath().standardizedFileURL.path
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(prefix) {
                let local = String(path.dropFirst(prefix.count))
                return mount.prefix.isEmpty ? local : mount.prefix + "/" + local
            }
        }
        return nil
    }

    private func isLinkedFolderRoot(_ path: String) -> Bool {
        currentLinkedFolders.contains { $0.virtualRootPath == path }
    }

    func isLinkedFolderEntry(_ file: ScannedFile) -> Bool {
        isLinkedFolderRoot(file.relativePath)
    }

    func displayPath(_ path: String) -> String {
        guard let link = currentLinkedFolders.first(where: {
            path == $0.virtualRootPath || path.hasPrefix($0.virtualRootPath + "/")
        }) else { return path }
        let sameName = currentLinkedFolders.filter { $0.displayName == link.displayName }
        let number = sameName.firstIndex(where: { $0.id == link.id }).map { $0 + 1 } ?? 1
        let name = sameName.count > 1 ? "\(link.displayName) (\(number))" : link.displayName
        let suffix = String(path.dropFirst(link.virtualRootPath.count))
        return "关联文件夹/\(name)\(suffix)"
    }

    private func overlapsExistingFolder(_ candidate: String, paths: [String]) -> Bool {
        paths.contains { existing in
            candidate == existing || candidate.hasPrefix(existing + "/") ||
                existing.hasPrefix(candidate + "/")
        }
    }

    private func mappedReceipt(_ receipt: FileOperationReceipt, oldPrefix: String,
                               newPrefix: String? = nil) -> FileOperationReceipt {
        let destinationPrefix = newPrefix ?? oldPrefix
        func path(_ value: String?, prefix: String) -> String? {
            guard let value else { return nil }
            return prefix.isEmpty ? value : prefix + "/" + value
        }
        return FileOperationReceipt(oldRelativePath: path(receipt.oldRelativePath, prefix: oldPrefix),
                                    newRelativePath: path(receipt.newRelativePath, prefix: destinationPrefix),
                                    identityPreserved: receipt.identityPreserved,
                                    replacedRelativePath: path(receipt.replacedRelativePath, prefix: destinationPrefix),
                                    trashedURL: receipt.trashedURL)
    }

    private func mountedLocation(_ virtualPath: String,
                                 in mounts: [(prefix: String, url: URL, name: String)])
        -> (root: URL, localPath: String, prefix: String)? {
        if let mount = mounts.first(where: {
            !$0.prefix.isEmpty &&
            (virtualPath == $0.prefix || virtualPath.hasPrefix($0.prefix + "/"))
        }) {
            let local = virtualPath == mount.prefix ? "" :
                String(virtualPath.dropFirst(mount.prefix.count + 1))
            return (mount.url, local, mount.prefix)
        }
        return mounts.first(where: { $0.prefix.isEmpty }).map { ($0.url, virtualPath, "") }
    }

    private func copyOrMove(_ virtualPath: String, into virtualFolder: String,
                            copying: Bool, resolution: ConflictResolution) async throws
        -> FileOperationReceipt {
        guard let source = resolvedPath(virtualPath), let destination = resolvedPath(virtualFolder),
              !source.localPath.isEmpty else { throw FileOperationError.invalidPath }
        do {
            let receipt: FileOperationReceipt
            if source.root == destination.root {
                receipt = try await copying
                    ? operations.copy(root: source.root, relativePath: source.localPath,
                                      toFolder: destination.localPath, resolution: resolution)
                    : operations.move(root: source.root, relativePath: source.localPath,
                                      toFolder: destination.localPath, resolution: resolution)
            } else {
                receipt = try await copying
                    ? operations.copyBetweenProjects(sourceRoot: source.root,
                                                     relativePath: source.localPath,
                                                     destinationRoot: destination.root,
                                                     toFolder: destination.localPath,
                                                     resolution: resolution)
                    : operations.moveBetweenProjects(sourceRoot: source.root,
                                                     relativePath: source.localPath,
                                                     destinationRoot: destination.root,
                                                     toFolder: destination.localPath,
                                                     resolution: resolution)
            }
            return mappedReceipt(receipt, oldPrefix: source.prefix, newPrefix: destination.prefix)
        } catch let partial as PartialFileOperationError {
            throw PartialFileOperationError(receipt: mappedReceipt(
                partial.receipt, oldPrefix: source.prefix, newPrefix: destination.prefix))
        }
    }
    var hasClipboard: Bool {
        guard !isOperating else { return false }
        return clipboard != nil
    }

    var visibleFiles: [ScannedFile] {
        let key = VisibleFilesKey(fileRevision: fileRevision,
                                  annotationRevision: annotationRevision,
                                  location: location, folderPath: folderPath,
                                  searchQuery: searchQuery, sortRevision: sortRevision)
        if let cached = visibleFilesCache, cached.key == key { return cached.rows }
        let base: [ScannedFile]
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let query = SearchQuery(searchQuery)
            base = files.filter {
                query.matches(file: $0, classification: classification(for: $0),
                              annotation: annotation(for: $0))
            }
        } else {
            switch location {
            case .recent:
                base = files.filter { !$0.isBrowsableFolder }
            case .allFiles:
                base = files
            case .favorites:
                base = files.filter { annotation(for: $0)?.isFavorite == true }
            case .trash, .allProjects, .journals:
                base = []
            case .category(let category):
                base = files.filter { !$0.isBrowsableFolder && effectiveWorkflow(for: $0).rawValue == category }
            case .project, .overview, .none:
                base = files.filter { $0.parentPath == folderPath }
            }
        }
        let sorted = base.sorted { left, right in
            let leftPin = annotationIndex[left.relativePath]?.pinnedAt
            let rightPin = annotationIndex[right.relativePath]?.pinnedAt
            if let leftPin, let rightPin, leftPin != rightPin { return leftPin > rightPin }
            if (leftPin == nil) != (rightPin == nil) { return leftPin != nil }
            if location == .recent && searchQuery.isEmpty && sortRevision == 0 {
                let leftDate = left.modifiedAt ?? .distantPast
                let rightDate = right.modifiedAt ?? .distantPast
                if leftDate != rightDate { return leftDate > rightDate }
            }
            if sortRevision == 0 {
                if left.isBrowsableFolder != right.isBrowsableFolder { return left.isBrowsableFolder }
                let nameOrder = left.name.localizedStandardCompare(right.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            } else {
                for comparator in sortOrder {
                    let order = comparator.compare(left, right)
                    if order != .orderedSame { return order == .orderedAscending }
                }
            }
            return left.relativePath.localizedStandardCompare(right.relativePath) == .orderedAscending
        }
        let rows = location == .recent && searchQuery.isEmpty ? Array(sorted.prefix(100)) : sorted
        visibleFilesCache = (key, rows)
        return rows
    }

    var selectedFile: ScannedFile? {
        guard let path = selectedFilePaths.first else { return nil }
        return filesByPath[path]
    }

    func file(at relativePath: String) -> ScannedFile? {
        filesByPath[relativePath]
    }

    func count(in category: WorkflowCategory) -> Int {
        categoryCounts[category, default: 0]
    }

    private func effectiveWorkflow(for file: ScannedFile) -> WorkflowCategory {
        if let raw = annotationIndex[file.relativePath]?.manualWorkflowRaw,
           let workflow = WorkflowCategory(rawValue: raw) { return workflow }
        if let raw = annotationIndex[file.relativePath]?.modelWorkflowRaw,
           let workflow = WorkflowCategory(rawValue: raw) { return workflow }
        return file.classification.workflow
    }

    private func rebuildCategoryCounts() {
        var counts: [WorkflowCategory: Int] = [:]
        for file in files where !file.isBrowsableFolder {
            counts[effectiveWorkflow(for: file), default: 0] += 1
        }
        categoryCounts = counts
    }

    func annotation(for file: ScannedFile) -> FileAnnotationRecord? {
        _ = annotationRevision
        return annotationIndex[file.relativePath]
    }

    func classification(for file: ScannedFile) -> FileClassification {
        let record = annotation(for: file)
        if let raw = record?.manualWorkflowRaw,
           let override = WorkflowCategory(rawValue: raw) {
            return ClassificationEngine().classify(name: file.name, relativePath: file.relativePath,
                                                   isDirectory: file.isBrowsableFolder,
                                                   manualOverride: override)
        }
        if let raw = record?.modelWorkflowRaw,
           let workflow = WorkflowCategory(rawValue: raw) {
            var result = ClassificationEngine().classify(name: file.name, relativePath: file.relativePath,
                                                         isDirectory: file.isBrowsableFolder,
                                                         manualOverride: workflow)
            result.source = .model
            result.explanation = "Jev 根据提取的文件内容判断"
            return result
        }
        return file.classification
    }

    func toggleFavorite(_ file: ScannedFile) {
        editAnnotation(for: file) { $0.isFavorite.toggle() }
    }

    func togglePin(_ file: ScannedFile) {
        editAnnotation(for: file) { $0.pinnedAt = $0.pinnedAt == nil ? .now : nil }
    }

    func updateNote(_ note: String, for file: ScannedFile) {
        editAnnotation(for: file) { $0.note = note }
    }

    func updateTags(_ tags: String, for file: ScannedFile) {
        let parsed = Array(Set(tags.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        editAnnotation(for: file) { $0.tags = parsed }
    }

    func setManualWorkflow(_ category: WorkflowCategory?, for file: ScannedFile) {
        editAnnotation(for: file) { $0.manualWorkflowRaw = category?.rawValue }
    }

    @discardableResult
    func classifyDroppedFiles(_ items: [WorkspaceDraggedFile], as category: WorkflowCategory) -> Bool {
        guard let selectedProjectID, !isOperating, !items.isEmpty,
              items.allSatisfy({ $0.projectID == selectedProjectID }) else { return false }
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath, $0) })
        let uniquePaths = Set(items.map(\.relativePath))
        let matches = uniquePaths.compactMap { byPath[$0] }.filter { !$0.isBrowsableFolder }
        guard matches.count == uniquePaths.count else { return false }
        undoManager?.beginUndoGrouping()
        isBatchClassifying = true
        var changedCount = 0
        for file in matches {
            if editAnnotation(for: file, { $0.manualWorkflowRaw = category.rawValue }) {
                changedCount += 1
            }
        }
        isBatchClassifying = false
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("手动分类")
        if changedCount > 0 {
            recordActivity("批量手动分类", detail: "\(changedCount) 个文件 → \(category.rawValue)")
        }
        return true
    }

    @discardableResult
    func classifyDroppedURLs(_ urls: [URL], as category: WorkflowCategory) -> Bool {
        guard let projectID = selectedProjectID,
              !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
        let paths = urls.compactMap { virtualPath(for: $0) }
        guard paths.count == urls.count else { return false }
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath, $0) })
        let matched = paths.compactMap { byPath[$0] }
        guard matched.count == urls.count else { return false }
        return classifyDroppedFiles(matched.map { file in
            WorkspaceDraggedFile(projectID: projectID, relativePath: file.relativePath,
                                 fileURL: url(for: file) ?? URL(fileURLWithPath: "/"))
        }, as: category)
    }

    @discardableResult
    private func editAnnotation(for file: ScannedFile,
                                _ edit: (FileAnnotationRecord) -> Void) -> Bool {
        guard let selectedProjectID, let annotationService else { return false }
        do {
            let record = try annotationService.record(for: file, projectID: selectedProjectID,
                                                      in: &annotations)
            annotationIndex[file.relativePath] = record
            let previous = AnnotationSnapshot(record)
            edit(record)
            try annotationService.save()
            let changed = previous != AnnotationSnapshot(record)
            if changed {
                annotationRevision += 1
                if previous.manualWorkflowRaw != record.manualWorkflowRaw ||
                    previous.modelWorkflowRaw != record.modelWorkflowRaw {
                    rebuildCategoryCounts()
                }
                if !isBatchClassifying {
                    if previous.isFavorite != record.isFavorite {
                        recordActivity(record.isFavorite ? "收藏文件" : "取消收藏",
                                       detail: file.relativePath)
                    }
                    if previous.pinnedAt != record.pinnedAt {
                        recordActivity(record.pinnedAt == nil ? "取消置顶" : "置顶文件",
                                       detail: file.relativePath)
                    }
                    if previous.manualWorkflowRaw != record.manualWorkflowRaw {
                        recordActivity("手动分类", detail: "\(file.relativePath) → \(record.manualWorkflowRaw ?? "自动")")
                    }
                    if previous.tags != record.tags {
                        recordActivity("更新标签", detail: file.relativePath)
                    }
                    if previous.note != record.note {
                        scheduleTextLog(key: "note:\(record.id)", action: "更新笔记",
                                        detail: file.relativePath)
                    }
                }
                registerAnnotationUndo(recordID: record.id, projectID: selectedProjectID,
                                       snapshot: previous)
            }
            return changed
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func registerAnnotationUndo(recordID: UUID, projectID: UUID,
                                        snapshot: AnnotationSnapshot) {
        undoManager?.registerUndo(withTarget: self) { model in
            model.restoreAnnotation(recordID: recordID, projectID: projectID, snapshot: snapshot)
        }
        undoManager?.setActionName("修改文件注释")
    }

    private func restoreAnnotation(recordID: UUID, projectID: UUID,
                                   snapshot: AnnotationSnapshot) {
        guard let context else { return }
        do {
            guard let record = try context.fetch(FetchDescriptor<FileAnnotationRecord>())
                .first(where: { $0.id == recordID && $0.projectID == projectID }) else { return }
            let previous = AnnotationSnapshot(record)
            snapshot.apply(to: record)
            try context.save()
            if selectedProjectID == projectID { rebuildAnnotationIndex() }
            recordActivity("撤销或重做文件标注", detail: record.relativePath)
            registerAnnotationUndo(recordID: recordID, projectID: projectID, snapshot: previous)
        } catch { errorMessage = error.localizedDescription }
    }

    func configure(context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        self.annotationService = FileAnnotationService(context: context)
        self.journalService = JournalSubmissionService(context: context)
        reloadTrashRecords()
        reloadProjects()
        if let first = projects.first { selectProject(first.id) }
        else { location = .allProjects }
    }

    func reloadProjects() {
        guard let context else { return }
        do {
            projects = try context.fetch(FetchDescriptor<ProjectRecord>())
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加项目"
        guard panel.runModal() == .OK, let url = panel.url, let context else { return }
        do {
            guard FileManager.default.isReadableFile(atPath: url.path),
                  FileManager.default.isWritableFile(atPath: url.path) else {
                throw ProjectAccessError.accessDenied
            }
            if let existing = projects.first(where: { $0.lastKnownPath == url.path }) {
                selectProject(existing.id)
                return
            }
            let bookmark = try access.makeBookmark(for: url)
            let project = ProjectRecord(displayName: url.lastPathComponent,
                                        bookmarkData: bookmark, lastKnownPath: url.path)
            context.insert(project)
            try context.save()
            recordActivity("添加项目", detail: url.path, projectName: project.displayName)
            reloadProjects()
            selectProject(project.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addLinkedFolders(to project: ProjectRecord) {
        guard !isOperating, !isAutoClassifying, let context else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "关联文件夹"
        guard panel.runModal() == .OK else { return }
        do {
            var links = project.linkedFolders
            var existingPaths = ([project.lastKnownPath] + links.map(\.lastKnownPath)).map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
            }
            var added: [ProjectLinkedFolder] = []
            for url in panel.urls {
                let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard !overlapsExistingFolder(path, paths: existingPaths) else { continue }
                guard FileManager.default.isReadableFile(atPath: path) else {
                    throw ProjectAccessError.accessDenied
                }
                let link = ProjectLinkedFolder(displayName: url.lastPathComponent,
                                               bookmarkData: try access.makeBookmark(for: url),
                                               lastKnownPath: url.path)
                links.append(link)
                added.append(link)
                existingPaths.append(path)
            }
            guard !added.isEmpty else {
                errorMessage = "所选文件夹已关联，或与现有关联文件夹相互包含。"
                return
            }
            project.linkedFolders = links
            try context.save()
            recordActivity("关联项目文件夹", detail: added.map(\.lastKnownPath).joined(separator: "；"),
                           projectName: project.displayName)
            if selectedProjectID == project.id { selectProject(project.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    func removeLinkedFolder(_ link: ProjectLinkedFolder, from project: ProjectRecord) {
        guard !isOperating, !isAutoClassifying, let context else { return }
        do {
            project.linkedFolders = project.linkedFolders.filter { $0.id != link.id }
            let prefix = link.virtualRootPath
            for record in try context.fetch(FetchDescriptor<FileAnnotationRecord>()) where
                record.projectID == project.id &&
                (record.relativePath == prefix || record.relativePath.hasPrefix(prefix + "/")) {
                context.delete(record)
            }
            for record in try context.fetch(FetchDescriptor<JournalFileLinkRecord>()) where
                record.projectID == project.id && record.relativePath.hasPrefix(prefix + "/") {
                context.delete(record)
            }
            try context.save()
            recordActivity("解除项目文件夹关联", detail: link.lastKnownPath,
                           projectName: project.displayName)
            if selectedProjectID == project.id { selectProject(project.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    func relink(_ link: ProjectLinkedFolder, in project: ProjectRecord) {
        guard !isOperating, !isAutoClassifying, let context else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "重新关联"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var links = project.linkedFolders
            guard let index = links.firstIndex(where: { $0.id == link.id }) else { return }
            let previous = links[index].lastKnownPath
            let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path
            let others = ([project.lastKnownPath] + links.enumerated().compactMap {
                $0.offset == index ? nil : $0.element.lastKnownPath
            }).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
            guard !overlapsExistingFolder(candidate, paths: others) else {
                errorMessage = "此文件夹与项目中另一个文件夹相互包含，不能重复关联。"
                return
            }
            links[index].bookmarkData = try access.makeBookmark(for: url)
            links[index].lastKnownPath = url.path
            links[index].displayName = url.lastPathComponent
            project.linkedFolders = links
            try context.save()
            recordActivity("重新关联项目文件夹", detail: "\(previous) → \(url.path)",
                           projectName: project.displayName)
            if selectedProjectID == project.id { selectProject(project.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    func selectProject(_ id: UUID) {
        guard !isOperating else {
            errorMessage = "请等待当前文件操作完成后再切换项目。"
            return
        }
        guard let project = projects.first(where: { $0.id == id }), let context else { return }
        scanTask?.cancel()
        isScanning = false
        stopMonitoring()
        access.deactivate()
        for task in coverTasks.values { task.cancel() }
        coverTasks = [:]
        loadingJournalCovers = []
        files = []
        annotations = []
        journals = []
        journalFileLinks = []
        annotationIndex = [:]
        selectedFilePaths = []
        folderPath = ""
        selectedProjectID = id
        location = .overview
        do {
            let root = try access.activate(project)
            annotations = try annotationService?.load(projectID: id) ?? []
            (journals, journalFileLinks) = try journalService?.load(projectID: id) ?? ([], [])
            rebuildAnnotationIndex()
            project.lastOpenedAt = .now
            try context.save()
            startMonitoring(roots: access.activeMounts(for: project).map(\.url), projectID: id)
            refresh(root: root)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func navigate(to destination: WorkspaceLocation?) {
        guard let destination else { return }
        if case .project(let id) = destination, id != selectedProjectID {
            selectProject(id)
            return
        }
        location = destination
        selectedFilePaths = []
        if case .overview = destination { folderPath = "" }
        if case .journals = destination { refreshMissingJournalCovers() }
    }

    func refresh() {
        guard let root = currentRoot else { return }
        refresh(root: root)
    }

    private func refresh(root: URL) {
        guard let id = selectedProjectID, let project = currentProject else { return }
        let mounts = access.activeMounts(for: project)
        scanTask?.cancel()
        isScanning = true
        scanTask = Task {
            if let cached = await cache?.load(projectID: id), !Task.isCancelled,
               selectedProjectID == id, files.isEmpty {
                files = cached
            }
            do {
                var result: [ScannedFile] = []
                for mount in mounts {
                    try Task.checkCancellation()
                    if !mount.prefix.isEmpty,
                       let link = project.linkedFolders.first(where: { $0.virtualRootPath == mount.prefix }) {
                        result.append(.linkedFolderRow(link))
                    }
                    result += try await scanner.scan(root: mount.url).map { $0.mounted(at: mount.prefix) }
                }
                guard !Task.isCancelled, selectedProjectID == id else { return }
                try annotationService?.reconcile(annotations, with: result)
                try journalService?.reconcile(journalFileLinks, with: result)
                rebuildAnnotationIndex()
                files = result
                isScanning = false
                try? await cache?.save(result, projectID: id)
            } catch is CancellationError {
                // A newer project scan owns the visible state.
            } catch {
                if selectedProjectID == id {
                    isScanning = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func startMonitoring(roots: [URL], projectID: UUID) {
        changeMonitors = roots.map { root in ProjectChangeMonitor(root: root) { [weak self] in
            guard let self, self.selectedProjectID == projectID else { return }
            self.changeRefreshTask?.cancel()
            self.changeRefreshTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.8))
                guard !Task.isCancelled, let self,
                      self.selectedProjectID == projectID, !self.isOperating else { return }
                self.refresh()
            }
        } }
    }

    private func stopMonitoring() {
        changeRefreshTask?.cancel()
        changeRefreshTask = nil
        changeMonitors.forEach { $0.stop() }
        changeMonitors = []
    }

    func enter(_ file: ScannedFile) {
        if file.isBrowsableFolder {
            folderPath = file.relativePath
            selectedFilePaths = []
            location = selectedProjectID.map(WorkspaceLocation.project)
        } else {
            open(file)
        }
    }

    func goUp() {
        guard !folderPath.isEmpty else { return }
        let parent = (folderPath as NSString).deletingLastPathComponent
        folderPath = parent == "." ? "" : parent
        selectedFilePaths = []
    }

    func url(for file: ScannedFile) -> URL? {
        guard let location = resolvedPath(file.relativePath) else { return nil }
        return location.localPath.isEmpty ? location.root : location.root.appending(path: location.localPath)
    }

    func open(_ file: ScannedFile) {
        guard let url = url(for: file) else { return }
        if !fileOpen.open(url) { errorMessage = "无法打开此文件。" }
    }

    func openSelected() {
        guard let selectedFile else { return }
        enter(selectedFile)
    }

    func previewSelected() {
        guard selectedFilePaths.count == 1, let file = selectedFile,
              let url = url(for: file), FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        previewURL = url
    }

    func applications(for file: ScannedFile) -> [URL] {
        guard let url = url(for: file) else { return [] }
        return fileOpen.applications(for: url)
    }

    func open(_ file: ScannedFile, with application: URL) {
        guard let url = url(for: file) else { return }
        fileOpen.open(url, with: application)
    }

    func copyPath(_ file: ScannedFile) {
        guard let url = url(for: file) else { return }
        fileOpen.copyPath(url)
    }

    func copyRelativePath(_ file: ScannedFile) {
        fileOpen.copyText(displayPath(file.relativePath))
    }

    func requestRenameSelected() {
        guard !isOperating, selectedFilePaths.count == 1,
              let selectedFile, !isLinkedFolderRoot(selectedFile.relativePath) else { return }
        renameRequest = selectedFile
    }

    func createFolder(named name: String) {
        let destination = destinationPath
        guard let target = resolvedPath(destination) else { return }
        perform("新建文件夹") { _ in
            let receipt = try await self.operations.createFolder(root: target.root,
                                                                  parentPath: target.localPath, name: name)
            return [self.mappedReceipt(receipt, oldPrefix: target.prefix)]
        }
    }

    func rename(_ file: ScannedFile, to name: String) {
        guard !isLinkedFolderRoot(file.relativePath), let source = resolvedPath(file.relativePath) else { return }
        perform("重命名文件") { _ in
            let receipt = try await self.operations.rename(root: source.root,
                                                            relativePath: source.localPath, newName: name)
            return [self.mappedReceipt(receipt, oldPrefix: source.prefix)]
        }
    }

    func duplicateSelected() {
        let paths = topLevelSelectedPaths.filter { !isLinkedFolderRoot($0) }
        guard !paths.isEmpty else { return }
        perform("制作副本") { _ in
            try await self.processBatch(paths, name: { $0 }) { path in
                guard let source = self.resolvedPath(path) else { throw FileOperationError.invalidPath }
                let receipt = try await self.operations.duplicate(root: source.root,
                                                                   relativePath: source.localPath)
                return self.mappedReceipt(receipt, oldPrefix: source.prefix)
            }
        }
    }

    func copySelected() {
        guard !isOperating else { return }
        guard let selectedProjectID else { return }
        let paths = topLevelSelectedPaths.filter { !isLinkedFolderRoot($0) }
        guard !paths.isEmpty else { return }
        clipboard = ClipboardState(projectID: selectedProjectID, paths: paths, isCut: false)
    }

    func cutSelected() {
        guard !isOperating else { return }
        guard let selectedProjectID else { return }
        let paths = topLevelSelectedPaths.filter { !isLinkedFolderRoot($0) }
        guard !paths.isEmpty else { return }
        clipboard = ClipboardState(projectID: selectedProjectID, paths: paths, isCut: true)
    }

    func paste(into folder: ScannedFile? = nil) {
        guard !isOperating else { return }
        guard let clipboard, let selectedProjectID else { return }
        let destination = folder?.isBrowsableFolder == true ? folder!.relativePath : destinationPath
        guard let target = resolvedPath(destination) else { return }
        if clipboard.projectID != selectedProjectID {
            guard let sourceProject = projects.first(where: { $0.id == clipboard.projectID }) else {
                errorMessage = "来源项目已从工作台移除。"
                return
            }
            perform(clipboard.isCut ? "跨项目移动" : "跨项目复制") { _ in
                defer { try? self.context?.save() }
                return try await self.access.withTemporaryMounts(to: sourceProject) { sourceMounts in
                    try await self.processBatch(clipboard.paths, name: { $0 }) { path in
                        guard let source = self.mountedLocation(path, in: sourceMounts),
                              !source.localPath.isEmpty else { throw FileOperationError.invalidPath }
                        let resolution = try await self.resolution(for: (path as NSString).lastPathComponent,
                                                                   root: target.root, folder: target.localPath)
                        do {
                            let receipt = try await clipboard.isCut
                                ? self.operations.moveBetweenProjects(
                                    sourceRoot: source.root, relativePath: source.localPath,
                                    destinationRoot: target.root, toFolder: target.localPath,
                                    resolution: resolution)
                                : self.operations.copyBetweenProjects(
                                    sourceRoot: source.root, relativePath: source.localPath,
                                    destinationRoot: target.root, toFolder: target.localPath,
                                    resolution: resolution)
                            return self.mappedReceipt(receipt, oldPrefix: source.prefix,
                                                      newPrefix: target.prefix)
                        } catch let partial as PartialFileOperationError {
                            throw PartialFileOperationError(receipt: self.mappedReceipt(
                                partial.receipt, oldPrefix: source.prefix, newPrefix: target.prefix))
                        }
                    }
                }
            } completion: { receipts, success in
                guard clipboard.isCut else { return }
                if success || !receipts.isEmpty { self.clipboard = nil }
                do {
                    try self.annotationService?.transferAnnotations(from: clipboard.projectID,
                                                                    to: selectedProjectID, receipts: receipts)
                    self.annotations = try self.annotationService?.load(projectID: selectedProjectID) ?? []
                    self.rebuildAnnotationIndex()
                    self.refresh()
                } catch {
                    self.errorMessage = "文件已移动，但注释转移失败：\(error.localizedDescription)"
                }
            }
            return
        }
        perform(clipboard.isCut ? "移动文件" : "复制文件") { _ in
            try await self.processBatch(clipboard.paths, name: { $0 }) { path in
                let parent = (path as NSString).deletingLastPathComponent
                let isSameFolderMove = clipboard.isCut && (parent == "." ? "" : parent) == destination
                let resolution = isSameFolderMove ? .keepBoth :
                    try await self.resolution(for: (path as NSString).lastPathComponent,
                                              root: target.root, folder: target.localPath)
                return try await self.copyOrMove(path, into: destination,
                                                 copying: !clipboard.isCut, resolution: resolution)
            }
        } completion: { receipts, success in
            if clipboard.isCut && (success || !receipts.isEmpty) { self.clipboard = nil }
        }
    }

    func moveSelectedToTrash() {
        let paths = topLevelSelectedPaths.filter { !isLinkedFolderRoot($0) }
        guard !paths.isEmpty, let projectID = selectedProjectID else { return }
        perform("移到废纸篓") { _ in
            try await self.processBatch(paths, name: { $0 }) { path in
                guard let source = self.resolvedPath(path), !source.localPath.isEmpty else {
                    throw FileOperationError.invalidPath
                }
                let receipt = try await self.operations.moveToTrash(root: source.root,
                                                                    relativePath: source.localPath)
                return self.mappedReceipt(receipt, oldPrefix: source.prefix)
            }
        } completion: { receipts, _ in
            let added = receipts.compactMap { receipt -> TrashRecord? in
                guard let path = receipt.oldRelativePath,
                      let url = receipt.trashedURL else { return nil }
                let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                                     includingResourceValuesForKeys: nil,
                                                     relativeTo: nil)
                return TrashRecord(projectID: projectID, originalRelativePath: path,
                                   trashedURL: url, trashBookmark: bookmark)
            }
            guard !added.isEmpty else { return }
            self.trashRecords.insert(contentsOf: added, at: 0)
            self.saveTrashRecords()
        }
    }

    var currentTrashRecords: [TrashRecord] {
        trashRecords.filter { $0.projectID == selectedProjectID }
            .sorted { $0.trashedAt > $1.trashedAt }
    }

    func reloadTrashRecords() {
        let loaded = trashHistory.load()
        if loaded != trashRecords { trashRecords = loaded }
    }

    func restore(_ record: TrashRecord) {
        guard record.projectID == selectedProjectID, record.isAvailable else {
            errorMessage = "废纸篓中的原文件已不可用，可能已被清空。"
            return
        }
        guard let target = resolvedPath(record.originalRelativePath), !target.localPath.isEmpty else {
            errorMessage = "原关联文件夹不可用，无法恢复。"
            return
        }
        perform("恢复废纸篓文件") { _ in
            let receipt = try await self.operations.restoreFromTrash(root: target.root,
                originalRelativePath: target.localPath, trashedURL: record.resolvedURL)
            return [self.mappedReceipt(receipt, oldPrefix: target.prefix)]
        } completion: { receipts, _ in
            if !receipts.isEmpty {
                self.trashRecords.removeAll { $0.id == record.id }
                self.saveTrashRecords()
            }
        }
    }

    func revealTrashed(_ record: TrashRecord) {
        guard record.isAvailable else {
            errorMessage = "废纸篓中的原文件已不可用，可能已被清空。"
            return
        }
        fileOpen.reveal(record.resolvedURL)
    }

    func forgetTrashed(_ record: TrashRecord) {
        trashRecords.removeAll { $0.id == record.id }
        saveTrashRecords()
        recordActivity("移除废纸篓记录", detail: record.originalRelativePath)
    }

    private func saveTrashRecords() {
        do { try trashHistory.save(trashRecords) }
        catch { errorMessage = "无法保存废纸篓记录：\(error.localizedDescription)" }
    }

    func importItems() {
        guard currentRoot != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "导入副本"
        guard panel.runModal() == .OK else { return }
        let sources = panel.urls
        let destination = destinationPath
        guard let target = resolvedPath(destination) else { return }
        perform("导入文件副本") { _ in
            try await self.processBatch(sources, name: { $0.lastPathComponent }) { source in
                let resolution = try await self.resolution(for: source.lastPathComponent,
                                                           root: target.root, folder: target.localPath)
                let receipt = try await self.operations.importItem(root: target.root,
                    sourceURL: source, toFolder: target.localPath, resolution: resolution)
                return self.mappedReceipt(receipt, oldPrefix: target.prefix)
            }
        }
    }

    func importDroppedURLs(_ urls: [URL], into folder: ScannedFile? = nil) {
        let sources = urls.filter(\.isFileURL)
        guard !sources.isEmpty, currentRoot != nil, !isOperating else { return }
        let destination = folder?.isBrowsableFolder == true ? folder!.relativePath : destinationPath
        guard let target = resolvedPath(destination) else { return }
        perform("拖入文件副本") { _ in
            try await self.processBatch(sources, name: { $0.lastPathComponent }) { source in
                let resolution = try await self.resolution(for: source.lastPathComponent,
                                                           root: target.root, folder: target.localPath)
                let receipt = try await self.operations.importItem(root: target.root,
                    sourceURL: source, toFolder: target.localPath, resolution: resolution)
                return self.mappedReceipt(receipt, oldPrefix: target.prefix)
            }
        }
    }

    @discardableResult
    func moveDroppedFiles(_ items: [WorkspaceDraggedFile], into folder: ScannedFile? = nil,
                          copying: Bool) -> Bool {
        guard let selectedProjectID, currentRoot != nil, !isOperating,
              !items.isEmpty, items.allSatisfy({ $0.projectID == selectedProjectID }) else {
            return false
        }
        let destination = folder?.isBrowsableFolder == true ? folder!.relativePath : destinationPath
        guard let target = resolvedPath(destination) else { return false }
        let sorted = Array(Set(items.map(\.relativePath))).sorted { $0.count < $1.count }
        var paths: [String] = []
        for path in sorted where !isLinkedFolderRoot(path) &&
            !paths.contains(where: { path.hasPrefix($0 + "/") }) {
            paths.append(path)
        }
        guard !paths.isEmpty else { return false }
        perform(copying ? "拖动复制" : "拖动移动") { _ in
            try await self.processBatch(paths, name: { $0 }) { path in
                let parent = (path as NSString).deletingLastPathComponent
                let sameFolderMove = !copying && (parent == "." ? "" : parent) == destination
                let resolution = sameFolderMove ? .keepBoth :
                    try await self.resolution(for: (path as NSString).lastPathComponent,
                                              root: target.root, folder: target.localPath)
                return try await self.copyOrMove(path, into: destination,
                                                 copying: copying, resolution: resolution)
            }
        }
        return true
    }

    func exportSelected() {
        guard selectedFilePaths.count == 1, let file = selectedFile,
              let source = resolvedPath(file.relativePath), !source.localPath.isEmpty,
              !isOperating else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.prompt = "导出副本"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isOperating = true
        Task {
            defer { isOperating = false }
            do {
                try await operations.exportItem(root: source.root, relativePath: source.localPath,
                                                destinationURL: destination)
                recordActivity("导出文件副本", detail: "\(file.relativePath) → \(destination.path)")
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private var destinationPath: String {
        if case .project = location { return folderPath }
        return ""
    }

    private var topLevelSelectedPaths: [String] {
        let sorted = selectedFilePaths.sorted { $0.count < $1.count }
        var result: [String] = []
        for path in sorted where !result.contains(where: { path.hasPrefix($0 + "/") }) {
            result.append(path)
        }
        return result
    }

    private func resolution(for name: String, root: URL, folder: String) async throws -> ConflictResolution {
        guard try await operations.hasConflict(root: root, toFolder: folder, name: name) else {
            return .keepBoth
        }
        if let applyToAllResolution { return applyToAllResolution }
        let choice = await withCheckedContinuation { continuation in
            conflictContinuation = continuation
            conflictPrompt = ConflictPrompt(name: name, destination: folder.isEmpty ? "项目根目录" : folder)
        }
        if choice == .stop { throw FileOperationError.stopped }
        return choice
    }

    func resolveConflict(_ resolution: ConflictResolution, applyToAll: Bool) {
        if applyToAll && resolution != .stop { applyToAllResolution = resolution }
        conflictPrompt = nil
        conflictContinuation?.resume(returning: resolution)
        conflictContinuation = nil
    }

    private func processBatch<Item: Sendable>(_ items: [Item], name: @MainActor (Item) -> String,
                                    action: @MainActor (Item) async throws -> FileOperationReceipt) async throws -> [FileOperationReceipt] {
        var receipts: [FileOperationReceipt] = []
        operationTotal = items.count
        operationCompleted = 0
        for item in items {
            do {
                try Task.checkCancellation()
                receipts.append(try await action(item))
                operationCompleted = receipts.count
            } catch let partial as PartialFileOperationError {
                receipts.append(partial.receipt)
                operationCompleted = receipts.count
                throw BatchFailure(receipts: receipts, itemName: name(item),
                                   reason: partial.localizedDescription)
            } catch {
                throw BatchFailure(receipts: receipts, itemName: name(item),
                                   reason: error is CancellationError ? "已停止后续项目。" : error.localizedDescription)
            }
        }
        return receipts
    }

    func cancelOperation() {
        operationTask?.cancel()
        if conflictPrompt != nil { resolveConflict(.stop, applyToAll: false) }
    }

    private func perform(_ operationName: String,
                         _ action: @escaping (URL) async throws -> [FileOperationReceipt],
                         completion: (([FileOperationReceipt], Bool) -> Void)? = nil) {
        guard let root = currentRoot, !isOperating else { return }
        applyToAllResolution = nil
        operationCompleted = 0
        operationTotal = 0
        isOperating = true
        operationTask = Task {
            defer {
                applyToAllResolution = nil
                isOperating = false
                operationTask = nil
            }
            do {
                let receipts = try await action(root)
                finishOperation(receipts, operationName: operationName)
                completion?(receipts, true)
            } catch let failure as BatchFailure {
                finishOperation(failure.receipts, operationName: operationName)
                completion?(failure.receipts, false)
                let detail = "\(failure.itemName)：\(failure.reason)"
                let message = failure.receipts.isEmpty ? "未完成操作。\(detail)"
                    : "已完成 \(failure.receipts.count) 项，随后停止。\(detail)"
                errorMessage = [errorMessage, message].compactMap { $0 }.joined(separator: "\n")
            } catch {
                errorMessage = error.localizedDescription
                refresh()
            }
        }
    }

    private func finishOperation(_ receipts: [FileOperationReceipt], operationName: String) {
        let changed = receipts.filter {
            $0.oldRelativePath != $0.newRelativePath || $0.trashedURL != nil
        }
        if !changed.isEmpty {
            let paths = changed.prefix(8).map { receipt in
                "\(receipt.oldRelativePath ?? "外部文件") → \(receipt.newRelativePath ?? "系统废纸篓")"
            }.joined(separator: "；")
            let remainder = changed.count > 8 ? "；另有 \(changed.count - 8) 项" : ""
            recordActivity(operationName, detail: "\(changed.count) 项：\(paths)\(remainder)")
        }
        selectedFilePaths = Set(receipts.compactMap(\.newRelativePath))
        do {
            try annotationService?.applyMoveReceipts(receipts, to: annotations)
            if let selectedProjectID {
                annotations = try annotationService?.load(projectID: selectedProjectID) ?? []
            }
            rebuildAnnotationIndex()
        } catch {
            errorMessage = "文件操作已完成，但注释同步失败：\(error.localizedDescription)"
        }
        do { try journalService?.applyMoveReceipts(receipts, to: journalFileLinks) }
        catch { errorMessage = "文件操作已完成，但投稿文件关联同步失败：\(error.localizedDescription)" }
        refresh()
    }

    func reveal(_ file: ScannedFile? = nil) {
        let url = file.flatMap { self.url(for: $0) } ?? currentRoot
        guard let url else { return }
        fileOpen.reveal(url)
    }

    func renameProject(_ project: ProjectRecord, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let context else { return }
        let previous = project.displayName
        guard previous != trimmed else { return }
        project.displayName = trimmed
        do {
            try context.save()
            recordActivity("重命名项目", detail: "\(previous) → \(trimmed)", projectName: trimmed)
            reloadProjects()
        }
        catch { errorMessage = error.localizedDescription }
    }

    func updateProject(_ project: ProjectRecord, status: String? = nil,
                       targetJournal: String? = nil, description: String? = nil,
                       isArchived: Bool? = nil) {
        guard let context else { return }
        let oldStatus = project.status
        let oldTarget = project.targetJournal
        let oldDescription = project.projectDescription
        let oldArchived = project.isArchived
        if let status { project.status = status }
        if let targetJournal { project.targetJournal = targetJournal }
        if let description { project.projectDescription = description }
        if let isArchived { project.isArchived = isArchived }
        do {
            try context.save()
            if oldStatus != project.status {
                recordActivity("更改项目阶段", detail: "\(oldStatus) → \(project.status)",
                               projectName: project.displayName)
            }
            if oldTarget != project.targetJournal {
                scheduleTextLog(key: "target:\(project.id)", action: "更新目标期刊",
                                detail: project.displayName, projectName: project.displayName)
            }
            if oldDescription != project.projectDescription {
                scheduleTextLog(key: "description:\(project.id)", action: "更新项目说明",
                                detail: project.displayName, projectName: project.displayName)
            }
            if oldArchived != project.isArchived {
                recordActivity(project.isArchived ? "归档项目" : "取消项目归档",
                               detail: project.displayName, projectName: project.displayName)
            }
        }
        catch { errorMessage = error.localizedDescription }
    }

    func removeProject(_ project: ProjectRecord) {
        guard !isOperating else {
            errorMessage = "请等待当前文件操作完成。"
            return
        }
        guard let context else { return }
        if selectedProjectID == project.id {
            scanTask?.cancel()
            isScanning = false
            stopMonitoring()
            access.deactivate()
            for task in coverTasks.values { task.cancel() }
            coverTasks = [:]
            loadingJournalCovers = []
            selectedProjectID = nil
            location = .allProjects
            files = []
            annotations = []
            annotationIndex = [:]
            journals = []
            journalFileLinks = []
        }
        if clipboard?.projectID == project.id { clipboard = nil }
        do {
            try journalService?.deleteProject(project.id)
            context.delete(project)
            try context.save()
            trashRecords.removeAll { $0.projectID == project.id }
            saveTrashRecords()
            Task { try? await cache?.remove(projectID: project.id) }
            recordActivity("从工作台移除项目", detail: "\(project.displayName)（原文件未删除）",
                           projectName: project.displayName)
            reloadProjects()
            if selectedProjectID == nil { location = .allProjects }
        } catch { errorMessage = error.localizedDescription }
    }

    func relink(_ project: ProjectRecord) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "重新关联"
        guard panel.runModal() == .OK, let url = panel.url, let context else { return }
        do {
            let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path
            let linkedPaths = project.linkedFolders.map {
                URL(fileURLWithPath: $0.lastKnownPath).resolvingSymlinksInPath().standardizedFileURL.path
            }
            guard !overlapsExistingFolder(candidate, paths: linkedPaths) else {
                errorMessage = "此文件夹与项目中另一个文件夹相互包含，不能重复关联。"
                return
            }
            let previousPath = project.lastKnownPath
            project.bookmarkData = try access.makeBookmark(for: url)
            project.lastKnownPath = url.path
            try context.save()
            if previousPath != url.path {
                recordActivity("重新关联项目文件夹", detail: "\(previousPath) → \(url.path)",
                               projectName: project.displayName)
            }
            selectProject(project.id)
        } catch { errorMessage = error.localizedDescription }
    }

    static func normalizedJournalWebsite(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        return JournalCoverService.validWebURL(candidate)?.absoluteString
    }

    func createJournal(name: String, website: String) {
        guard let id = selectedProjectID, let journalService else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let website = Self.normalizedJournalWebsite(website) else {
            errorMessage = "请输入期刊名称和有效的 http 或 https 链接。"
            return
        }
        do {
            let journal = try journalService.add(projectID: id, name: name, website: website)
            journals.insert(journal, at: 0)
            recordActivity("新建投稿期刊", detail: "\(name) · \(website)")
            refreshJournalCover(journal)
        } catch { errorMessage = error.localizedDescription }
    }

    func updateJournal(_ journal: JournalSubmissionRecord, name: String, website: String) {
        guard journal.projectID == selectedProjectID, let journalService else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let website = Self.normalizedJournalWebsite(website) else {
            errorMessage = "请输入期刊名称和有效的 http 或 https 链接。"
            return
        }
        let changedWebsite = journal.website != website
        let oldName = journal.name
        let oldWebsite = journal.website
        do {
            try journalService.update(journal, name: name, website: website)
            if oldName != name || oldWebsite != website {
                recordActivity("编辑投稿期刊", detail: "\(oldName) → \(name)；网址：\(website)")
            }
            if changedWebsite { refreshJournalCover(journal) }
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteJournal(_ journal: JournalSubmissionRecord) {
        guard journal.projectID == selectedProjectID, let journalService else { return }
        coverTasks[journal.id]?.cancel()
        coverTasks[journal.id] = nil
        do {
            try journalService.delete(journal, links: journalFileLinks)
            journalFileLinks.removeAll { $0.journalID == journal.id }
            journals.removeAll { $0.id == journal.id }
            loadingJournalCovers.remove(journal.id)
            recordActivity("删除投稿期刊记录", detail: journal.name)
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshMissingJournalCovers() {
        for journal in journals where journal.coverImageData == nil &&
            journal.coverFetchAttemptedAt == nil && coverTasks[journal.id] == nil {
            refreshJournalCover(journal)
        }
    }

    func configureJEVClient(_ client: any JEVModelClient) {
        jevClient = client
    }

    func requestJEV(_ request: JEVModelRequest) async throws -> JEVModelResponse {
        return try await jevClient.generate(request)
    }

    func startAutoClassification(allProjects: Bool) {
        guard !isAutoClassifying, !isOperating, let annotationService else { return }
        let targets = allProjects ? projects : currentProject.map { [$0] } ?? []
        guard !targets.isEmpty else { return }
        isAutoClassifying = true
        autoClassificationPreparing = true
        autoClassificationCompleted = 0
        autoClassificationTotal = 0
        autoClassificationChanged = 0
        autoClassificationManualSkipped = 0
        autoClassificationNoContent = 0
        autoClassificationFailed = 0
        autoClassificationStatus = "正在扫描项目文件…"
        autoClassificationTask = Task {
            var changedByProject: [UUID: Int] = [:]
            do {
                var plans: [(ProjectRecord, [ScannedFile])] = []
                for (index, project) in targets.enumerated() {
                    try Task.checkCancellation()
                    autoClassificationStatus = "正在扫描项目 \(index + 1)/\(targets.count)：\(project.displayName)"
                    let scanned = try await access.withTemporaryMounts(to: project) { mounts in
                        var combined: [ScannedFile] = []
                        for mount in mounts {
                            try Task.checkCancellation()
                            combined += try await scanner.scan(root: mount.url)
                                .map { $0.mounted(at: mount.prefix) }
                        }
                        return combined
                    }
                    let existing = try annotationService.load(projectID: project.id)
                    let byPath = Dictionary(existing.map { ($0.relativePath, $0) },
                                            uniquingKeysWith: { first, _ in first })
                    let ordinaryFiles = scanned.filter(JEVContentExtractor.supports)
                    autoClassificationManualSkipped += ordinaryFiles.filter {
                        byPath[$0.relativePath]?.manualWorkflowRaw != nil
                    }.count
                    let candidates = ordinaryFiles.filter { file in
                        let record = byPath[file.relativePath]
                        return record?.manualWorkflowRaw == nil && record?.modelWorkflowRaw == nil
                    }
                    plans.append((project, candidates))
                    autoClassificationTotal += candidates.count
                }
                autoClassificationPreparing = false

                for (project, filesToClassify) in plans {
                    try Task.checkCancellation()
                    var records = try annotationService.load(projectID: project.id)
                    let client = jevClient
                    for start in stride(from: 0, to: filesToClassify.count,
                                        by: JEVFileClassifier.maxConcurrentRequests) {
                        try Task.checkCancellation()
                        let batch = Array(filesToClassify[start..<min(start + JEVFileClassifier.maxConcurrentRequests,
                                                                       filesToClassify.count)])
                        autoClassificationStatus = "正在逐个判断：\(project.displayName)（\(autoClassificationCompleted)/\(autoClassificationTotal)）"
                        let results = try await access.withTemporaryMounts(to: project) { mounts in
                            await withTaskGroup(of: (ScannedFile, AutoClassificationOutcome).self) { group in
                                for file in batch {
                                    group.addTask {
                                        do {
                                            guard let mount = mounts.first(where: {
                                                !$0.prefix.isEmpty &&
                                                file.relativePath.hasPrefix($0.prefix + "/")
                                            }) ?? mounts.first(where: { $0.prefix.isEmpty }) else {
                                                return (file, .extractionFailed)
                                            }
                                            let localPath = mount.prefix.isEmpty ? file.relativePath :
                                                String(file.relativePath.dropFirst(mount.prefix.count + 1))
                                            let excerpt = try await JEVContentExtractor().extract(
                                                from: mount.url.appending(path: localPath), file: file)
                                            guard let excerpt else { return (file, .noContent) }
                                            do {
                                                let category = try await JEVFileClassifier.classify(
                                                    excerpt: excerpt, using: client)
                                                guard let category else { return (file, .invalidAnswer) }
                                                return (file, .decision(category))
                                            } catch {
                                                if Task.isCancelled { return (file, .cancelled) }
                                                return (file, .requestFailed(error.localizedDescription))
                                            }
                                        } catch {
                                            return (file, Task.isCancelled ? .cancelled : .extractionFailed)
                                        }
                                    }
                                }
                                var results: [(ScannedFile, AutoClassificationOutcome)] = []
                                for await result in group { results.append(result) }
                                return results
                            }
                        }
                        var accepted: [(ScannedFile, WorkflowCategory)] = []
                        var requestFailure: String?
                        var processedCount = 0
                        for (file, outcome) in results {
                            switch outcome {
                            case .decision(let category): accepted.append((file, category))
                            case .noContent: autoClassificationNoContent += 1
                            case .extractionFailed, .invalidAnswer: autoClassificationFailed += 1
                            case .requestFailed(let reason):
                                autoClassificationFailed += 1
                                requestFailure = reason
                            case .cancelled: continue
                            }
                            processedCount += 1
                        }
                        let changed = try annotationService.applyModelWorkflows(
                            accepted, projectID: project.id, records: &records)
                        autoClassificationChanged += changed
                        changedByProject[project.id, default: 0] += changed
                        autoClassificationCompleted += processedCount
                        if selectedProjectID == project.id {
                            annotations = records
                            rebuildAnnotationIndex()
                        }
                        try Task.checkCancellation()
                        if let requestFailure { throw AutoClassificationRunError(reason: requestFailure) }
                    }
                }
                autoClassificationStatus = autoClassificationTotal == 0
                    ? "没有需要自动分类的文件。已手动分类和已完成模型分类的文件会跳过。"
                    : "完成：处理 \(autoClassificationCompleted) 个文件，更新 \(autoClassificationChanged) 个分类" +
                      "，\(autoClassificationNoContent) 个没有可用内容而跳过" +
                      (autoClassificationFailed > 0 ? "，\(autoClassificationFailed) 个失败，可重试。" : "。")
            } catch {
                let reason = Task.isCancelled ? "已停止" : "已中断：\(error.localizedDescription)"
                autoClassificationStatus = "\(reason)。已完成 \(autoClassificationCompleted)/\(autoClassificationTotal)；已保存的结果可保留，下次运行会跳过。"
            }
            for project in targets {
                let count = changedByProject[project.id, default: 0]
                if count > 0 {
                    recordActivity("Jev 自动分类", detail: "更新 \(count) 个文件分类",
                                   projectName: project.displayName)
                }
            }
            autoClassificationPreparing = false
            isAutoClassifying = false
            autoClassificationTask = nil
        }
    }

    func cancelAutoClassification() {
        autoClassificationTask?.cancel()
    }

    func refreshJournalCover(_ journal: JournalSubmissionRecord) {
        guard journal.projectID == selectedProjectID, journalService != nil else { return }
        coverTasks[journal.id]?.cancel()
        let website = journal.website
        let journalID = journal.id
        let projectID = journal.projectID
        loadingJournalCovers.insert(journalID)
        coverTasks[journalID] = Task {
            let image = await coverService.fetchCover(website: website)
            guard !Task.isCancelled, selectedProjectID == projectID,
                  let current = journals.first(where: { $0.id == journalID && $0.website == website }) else { return }
            let changed = current.coverImageData != image
            do {
                try journalService?.saveCover(image, for: current)
                if changed {
                    recordActivity("更新期刊封面", detail: current.name)
                }
            }
            catch { errorMessage = "封面无法保存：\(error.localizedDescription)" }
            loadingJournalCovers.remove(journalID)
            coverTasks[journalID] = nil
        }
    }

    func importJournalCover(_ url: URL, for journal: JournalSubmissionRecord) {
        guard journal.projectID == selectedProjectID, journalService != nil else { return }
        let journalID = journal.id
        let projectID = journal.projectID
        coverTasks[journalID]?.cancel()
        loadingJournalCovers.insert(journalID)
        coverTasks[journalID] = Task {
            do {
                let image = try await Task.detached(priority: .userInitiated) {
                    try JournalCoverService.importedCover(from: url)
                }.value
                guard !Task.isCancelled, selectedProjectID == projectID,
                      let current = journals.first(where: { $0.id == journalID }) else { return }
                try journalService?.saveCover(image, for: current)
                recordActivity("手动设置期刊封面", detail: current.name)
            } catch {
                if !Task.isCancelled { errorMessage = "封面无法导入：\(error.localizedDescription)" }
            }
            if !Task.isCancelled {
                loadingJournalCovers.remove(journalID)
                coverTasks[journalID] = nil
            }
        }
    }

    func links(for journal: JournalSubmissionRecord) -> [JournalFileLinkRecord] {
        journalFileLinks.filter { $0.journalID == journal.id }
            .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    func linkedFile(for link: JournalFileLinkRecord) -> ScannedFile? {
        guard link.projectID == selectedProjectID,
              let file = filesByPath[link.relativePath],
              JournalSubmissionService.matches(link, file: file) else { return nil }
        return file
    }

    func exportJournalFiles(_ journal: JournalSubmissionRecord) {
        guard journal.projectID == selectedProjectID, currentRoot != nil,
              !exportingJournalIDs.contains(journal.id) else { return }
        let linkedFiles = links(for: journal)
        guard !linkedFiles.isEmpty else {
            errorMessage = JournalArchiveError.noFiles.localizedDescription
            return
        }
        if let missing = linkedFiles.first(where: { linkedFile(for: $0) == nil }) {
            errorMessage = JournalArchiveError.missingFile(missing.relativePath).localizedDescription
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出投稿文件"
        panel.message = "选择保存投稿文件 ZIP 的文件夹。"
        panel.nameFieldStringValue = JournalArchiveService.suggestedFilename(for: journal.name)
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let paths = linkedFiles.map(\.relativePath)
        let hasLinkedSources = paths.contains { path in
            currentLinkedFolders.contains { path.hasPrefix($0.virtualRootPath + "/") }
        }
        let sources: [JournalArchiveService.Source] = paths.compactMap { path in
            guard let location = resolvedPath(path), !location.localPath.isEmpty else { return nil }
            let archivePath: String
            if location.prefix.isEmpty {
                archivePath = hasLinkedSources ? "主文件夹/" + location.localPath : location.localPath
            } else {
                let displayName = currentLinkedFolders.first(where: { $0.virtualRootPath == location.prefix })?
                    .displayName ?? "文件夹"
                let safeName = displayName.replacingOccurrences(of: "/", with: "-")
                let suffix = String(location.prefix.suffix(8))
                archivePath = "关联文件夹/\(safeName)-\(suffix)/\(location.localPath)"
            }
            return .init(root: location.root, relativePath: location.localPath,
                         archivePath: archivePath)
        }
        guard sources.count == paths.count else {
            errorMessage = "部分投稿文件所在的关联文件夹不可用。"
            return
        }
        let journalID = journal.id
        let journalName = journal.name
        let projectName = currentProject?.displayName
        exportingJournalIDs.insert(journalID)
        Task {
            defer { exportingJournalIDs.remove(journalID) }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try JournalArchiveService.createZIP(sources: sources, destination: destination)
                }.value
                recordActivity("导出投稿文件", detail: "\(journalName) · \(paths.count) 个文件 → \(destination.path)",
                               projectName: projectName)
            } catch {
                errorMessage = "投稿文件导出失败：\(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    func linkFiles(_ paths: Set<String>, to journal: JournalSubmissionRecord) -> Bool {
        guard journal.projectID == selectedProjectID, let journalService else { return false }
        let matches = JournalFileSelection.expandedFiles(for: paths, in: files)
        guard !matches.isEmpty else { return false }
        do {
            let additions = try journalService.link(matches, to: journal,
                                                    existing: journalFileLinks)
            journalFileLinks.append(contentsOf: additions)
            if !additions.isEmpty {
                let paths = additions.prefix(5).map(\.relativePath).joined(separator: "；")
                let remainder = additions.count > 5 ? "；另有 \(additions.count - 5) 个" : ""
                recordActivity("关联投稿文件", detail: "\(journal.name)：\(additions.count) 个文件：\(paths)\(remainder)")
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func linkDroppedFiles(_ items: [WorkspaceDraggedFile], to journal: JournalSubmissionRecord) -> Bool {
        guard let id = selectedProjectID, !items.isEmpty,
              items.allSatisfy({ $0.projectID == id }) else { return false }
        return linkFiles(Set(items.map(\.relativePath)), to: journal)
    }

    @discardableResult
    func linkDroppedURLs(_ urls: [URL], to journal: JournalSubmissionRecord) -> Bool {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
        let paths = urls.compactMap { virtualPath(for: $0) }
        guard paths.count == urls.count else { return false }
        return linkFiles(Set(paths), to: journal)
    }

    func unlink(_ link: JournalFileLinkRecord) {
        guard link.projectID == selectedProjectID else { return }
        do {
            try journalService?.unlink(link)
            journalFileLinks.removeAll { $0.id == link.id }
            recordActivity("解除投稿文件关联", detail: link.relativePath)
        } catch { errorMessage = error.localizedDescription }
    }

    private func recordActivity(_ action: String, detail: String, projectName: String? = nil) {
        let event = ActivityEvent(action: action, detail: detail,
                                  projectName: projectName ?? currentProject?.displayName)
        appendActivity(event)
    }

    private func scheduleTextLog(key: String, action: String, detail: String,
                                 projectName: String? = nil) {
        pendingTextLogs[key]?.cancel()
        let event = ActivityEvent(action: action, detail: detail,
                                  projectName: projectName ?? currentProject?.displayName)
        pendingTextLogs[key] = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            pendingTextLogs[key] = nil
            appendActivity(event)
        }
    }

    private func appendActivity(_ event: ActivityEvent) {
        Task {
            do { try await ActivityLogStore.shared.append(event) }
            catch { errorMessage = "更改已完成，但日志保存失败：\(error.localizedDescription)" }
        }
    }

    private func rebuildAnnotationIndex() {
        annotationIndex = Dictionary(annotations.map { ($0.relativePath, $0) },
                                     uniquingKeysWith: { first, _ in first })
        annotationRevision += 1
        rebuildCategoryCounts()
    }
}

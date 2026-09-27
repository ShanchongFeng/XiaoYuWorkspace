import Foundation
import SwiftData

@MainActor
final class FileAnnotationService {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func load(projectID: UUID) throws -> [FileAnnotationRecord] {
        try context.fetch(FetchDescriptor<FileAnnotationRecord>())
            .filter { $0.projectID == projectID }
    }

    func record(for file: ScannedFile, projectID: UUID,
                in records: inout [FileAnnotationRecord]) throws -> FileAnnotationRecord {
        if let existing = records.first(where: { $0.relativePath == file.relativePath }) {
            return existing
        }
        let record = FileAnnotationRecord(projectID: projectID, file: file)
        context.insert(record)
        records.append(record)
        try context.save()
        return record
    }

    func save() throws { try context.save() }

    /// Save a small response batch in one transaction. A manual decision always wins, including
    /// one made while the network request was in flight.
    func applyModelWorkflows(_ decisions: [(ScannedFile, WorkflowCategory)], projectID: UUID,
                             records: inout [FileAnnotationRecord]) throws -> Int {
        var byPath = Dictionary(records.map { ($0.relativePath, $0) },
                                uniquingKeysWith: { first, _ in first })
        var changed = 0
        for (file, category) in decisions {
            let record: FileAnnotationRecord
            if let existing = byPath[file.relativePath] {
                record = existing
            } else {
                record = FileAnnotationRecord(projectID: projectID, file: file)
                context.insert(record)
                records.append(record)
                byPath[file.relativePath] = record
            }
            guard record.manualWorkflowRaw == nil else { continue }
            if record.modelWorkflowRaw != category.rawValue {
                record.modelWorkflowRaw = category.rawValue
                changed += 1
            }
        }
        if changed > 0 { try context.save() }
        return changed
    }

    func transferAnnotations(from sourceProjectID: UUID, to destinationProjectID: UUID,
                             receipts: [FileOperationReceipt]) throws {
        let sourceRecords = try context.fetch(FetchDescriptor<FileAnnotationRecord>())
            .filter { $0.projectID == sourceProjectID }
        for receipt in receipts {
            guard let old = receipt.oldRelativePath, let new = receipt.newRelativePath else { continue }
            for record in sourceRecords where record.relativePath == old
                || record.relativePath.hasPrefix(old + "/") {
                let path = new + String(record.relativePath.dropFirst(old.count))
                context.insert(FileAnnotationRecord(projectID: destinationProjectID,
                                                    relativePath: path, copying: record))
                context.delete(record)
            }
        }
        try context.save()
    }

    func applyMoveReceipts(_ receipts: [FileOperationReceipt],
                           to records: [FileAnnotationRecord]) throws {
        for receipt in receipts {
            guard let replaced = receipt.replacedRelativePath else { continue }
            for record in records where record.relativePath == replaced
                || record.relativePath.hasPrefix(replaced + "/") {
                context.delete(record)
            }
        }
        for receipt in receipts where receipt.identityPreserved {
            guard let old = receipt.oldRelativePath, let new = receipt.newRelativePath else { continue }
            for record in records where record.relativePath == old || record.relativePath.hasPrefix(old + "/") {
                record.relativePath = new + String(record.relativePath.dropFirst(old.count))
            }
        }
        try context.save()
    }

    func reconcile(_ records: [FileAnnotationRecord], with files: [ScannedFile]) throws {
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath, $0) })
        var byIdentity: [String: ScannedFile] = [:]
        var ambiguousIdentities: Set<String> = []
        for file in files {
            if let key = identityKey(file.resourceIdentifier, file.volumeIdentifier) {
                if byIdentity[key] != nil { ambiguousIdentities.insert(key) }
                else { byIdentity[key] = file }
            }
        }
        for record in records {
            if let exact = byPath[record.relativePath],
               identityKey(exact.resourceIdentifier, exact.volumeIdentifier)
                 == identityKey(record.resourceIdentifier, record.volumeIdentifier) {
                record.lastSeenAt = .now
                continue
            }
            if let key = identityKey(record.resourceIdentifier, record.volumeIdentifier),
               !ambiguousIdentities.contains(key), let match = byIdentity[key] {
                record.relativePath = match.relativePath
                record.lastSeenAt = .now
            } else if let match = byPath[record.relativePath],
                      (record.resourceIdentifier == nil || match.resourceIdentifier == nil) {
                record.resourceIdentifier = match.resourceIdentifier
                record.volumeIdentifier = match.volumeIdentifier
                record.lastSeenAt = .now
            }
        }
        try context.save()
    }

    private func identityKey(_ resource: String?, _ volume: String?) -> String? {
        guard let resource, !resource.isEmpty else { return nil }
        return (volume ?? "") + "\0" + resource
    }
}

import AppKit
import Foundation

/// Extracts bounded textual evidence locally. Jev never receives raw files or their paths.
actor JEVContentExtractor {
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "ndjson", "xml",
        "yaml", "yml", "log", "py", "r", "rmd", "qmd", "mjs", "js", "sql",
        "sh", "bash", "zsh", "swift", "tex", "bib", "fasta", "fa"
    ]
    private static let documentExtensions: Set<String> = [
        "docx", "doc", "rtf", "html", "htm", "odt"
    ]
    private let hardCharacterLimit = 500_000

    static func supports(_ file: ScannedFile) -> Bool {
        guard !file.isDirectory, !file.isSymbolicLink else { return false }
        let ext = URL(fileURLWithPath: file.name).pathExtension.lowercased()
        return textExtensions.contains(ext) || documentExtensions.contains(ext) || ext == "xlsx"
    }

    func extract(from url: URL, file: ScannedFile) throws -> String? {
        try Task.checkCancellation()
        let ext = url.pathExtension.lowercased()
        let evidence: String?
        if Self.textExtensions.contains(ext) {
            evidence = try textEvidence(at: url)
        } else if Self.documentExtensions.contains(ext) {
            evidence = documentEvidence(at: url)
        } else if ext == "xlsx" {
            evidence = try spreadsheetEvidence(at: url)
        } else {
            evidence = nil
        }
        try Task.checkCancellation()
        guard let evidence else { return nil }
        let trimmed = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let bounded = trimmed.count > hardCharacterLimit
            ? String(trimmed.prefix(hardCharacterLimit / 2)) + "\n[省略超大文件中间内容]\n" +
              String(trimmed.suffix(hardCharacterLimit / 2))
            : trimmed
        return JEVContextBudget.fit(bounded)
    }

    private func textEvidence(at url: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 512 * 1024) ?? Data()
        guard !data.isEmpty else { return nil }
        let hasUTF16BOM = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        let decoded = hasUTF16BOM ? String(data: data, encoding: .utf16)
                                  : String(decoding: data, as: UTF8.self)
        guard let decoded, !decoded.contains("\0") else { return nil }
        return "文件正文摘录：\n" + decoded
    }

    private func documentEvidence(at url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = ext == "docx"
            ? [.documentType: NSAttributedString.DocumentType.officeOpenXML] : [:]
        guard let content = try? NSAttributedString(url: url, options: options,
                                                    documentAttributes: nil).string,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "文档正文摘录：\n" + content
    }

    private func spreadsheetEvidence(at url: URL) throws -> String? {
        // XLSX is a ZIP package. Read shared strings and the first sheet through the system
        // unzip utility, bounding each stream to avoid loading a large workbook into memory.
        let stringsData = try unzipEntry("xl/sharedStrings.xml", from: url)
        let shared = stringsData.map { SpreadsheetXMLCollector.strings(in: $0) } ?? []
        var sections: [String] = []
        for sheetIndex in 1...8 {
            try Task.checkCancellation()
            guard let sheetData = try unzipEntry("xl/worksheets/sheet\(sheetIndex).xml", from: url) else {
                if sheetIndex > 1 { break }
                continue
            }
            let cells = SpreadsheetXMLCollector.cells(in: sheetData, sharedStrings: shared)
            if !cells.isEmpty {
                sections.append("工作表 \(sheetIndex)：" + cells.joined(separator: " | "))
            }
            if JEVContextBudget.estimatedTokens(sections.joined()) >= JEVContextBudget.maxEvidenceTokens {
                break
            }
        }
        if sections.isEmpty {
            return shared.isEmpty ? nil : "表格文字：\n" + shared.prefix(1_000).joined(separator: " | ")
        }
        return "表格单元格内容：\n" + sections.joined(separator: "\n")
    }

    private func unzipEntry(_ entry: String, from url: URL) throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, entry]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        var data = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            data.append(chunk)
            if data.count >= 4 * 1024 * 1024 {
                process.terminate()
                break
            }
        }
        return data.isEmpty ? nil : data
    }
}

private final class SpreadsheetXMLCollector: NSObject, XMLParserDelegate {
    private enum Mode { case strings, cells }
    private let mode: Mode
    private let sharedStrings: [String]
    private var inString = false
    private var inValue = false
    private var cellType = ""
    private var current = ""
    private(set) var values: [String] = []

    private init(mode: Mode, sharedStrings: [String] = []) {
        self.mode = mode
        self.sharedStrings = sharedStrings
    }

    static func strings(in data: Data) -> [String] {
        parse(data, mode: .strings).values
    }

    static func cells(in data: Data, sharedStrings: [String]) -> [String] {
        parse(data, mode: .cells, sharedStrings: sharedStrings).values
    }

    private static func parse(_ data: Data, mode: Mode,
                              sharedStrings: [String] = []) -> SpreadsheetXMLCollector {
        let collector = SpreadsheetXMLCollector(mode: mode, sharedStrings: sharedStrings)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        _ = parser.parse()
        return collector
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        switch mode {
        case .strings:
            if elementName == "si" { current = ""; inString = true }
            if elementName == "t" && inString { inValue = true }
        case .cells:
            if elementName == "c" { cellType = attributeDict["t"] ?? "" }
            if elementName == "v" || elementName == "t" { current = ""; inValue = true }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        switch mode {
        case .strings:
            if elementName == "t" { inValue = false }
            if elementName == "si" {
                values.append(current)
                inString = false
            }
        case .cells:
            if elementName == "v" || elementName == "t" {
                let value = cellType == "s" && elementName == "v"
                    ? Int(current).flatMap { sharedStrings.indices.contains($0) ? sharedStrings[$0] : nil }
                    : current
                if let value, !value.isEmpty { values.append(value) }
                inValue = false
            }
        }
        switch mode {
        case .strings where values.count >= 20_000: parser.abortParsing()
        case .cells where values.count >= 10_000: parser.abortParsing()
        default: break
        }
    }
}

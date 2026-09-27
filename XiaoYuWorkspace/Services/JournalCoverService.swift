import Foundation
import ImageIO
import UniformTypeIdentifiers

actor JournalCoverService {
    enum ImportError: LocalizedError {
        case unreadableFile
        case invalidImage

        var errorDescription: String? {
            switch self {
            case .unreadableFile: "无法读取所选图片。"
            case .invalidImage: "所选文件不是可用的图片。"
            }
        }
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        session = URLSession(configuration: configuration)
    }

    func fetchCover(website: String) async -> Data? {
        guard let pageURL = Self.validWebURL(website) else { return nil }
        var candidates: [URL] = []
        if let (data, _) = try? await session.data(from: pageURL), data.count <= 1_500_000 {
            candidates = Self.imageCandidates(html: String(decoding: data, as: UTF8.self), base: pageURL)
        }
        if var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) {
            components.path = "/favicon.ico"
            components.query = nil
            components.fragment = nil
            if let iconURL = components.url { candidates.append(iconURL) }
        }
        for url in candidates.prefix(5) {
            guard !Task.isCancelled,
                  let (data, response) = try? await session.data(from: url),
                  data.count <= 3_000_000, !data.isEmpty,
                  let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  response.mimeType?.lowercased().hasPrefix("image/") == true else { continue }
            if let thumbnail = Self.thumbnailPNG(from: data) { return thumbnail }
        }
        return nil
    }

    private static func thumbnailPNG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = thumbnail(from: source) else { return nil }
        return pngData(for: image)
    }

    static func importedCover(from url: URL) throws -> Data {
        guard url.isFileURL else { throw ImportError.unreadableFile }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isReadableFile(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL,
                                                       [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ImportError.unreadableFile
        }
        guard let image = thumbnail(from: source), let data = pngData(for: image) else {
            throw ImportError.invalidImage
        }
        return data
    }

    private static func thumbnail(from source: CGImageSource) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 360,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    private static func pngData(for image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString,
                                                                 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func validWebURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    static func imageCandidates(html: String, base: URL) -> [URL] {
        let tagPattern = #"<(meta|link)\b[^>]*>"#
        let attributePattern = #"([\w:-]+)\s*=\s*(["'])(.*?)\2"#
        guard let tags = try? NSRegularExpression(pattern: tagPattern, options: [.caseInsensitive]),
              let attributes = try? NSRegularExpression(pattern: attributePattern, options: [.caseInsensitive])
        else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var preferred: [(Int, URL)] = []
        for tag in tags.matches(in: html, range: range).prefix(250) {
            guard let tagRange = Range(tag.range, in: html) else { continue }
            let source = String(html[tagRange])
            let nsSource = source as NSString
            var values: [String: String] = [:]
            for match in attributes.matches(in: source, range: NSRange(location: 0, length: nsSource.length)) {
                values[nsSource.substring(with: match.range(at: 1)).lowercased()] =
                    nsSource.substring(with: match.range(at: 3))
            }
            let property = (values["property"] ?? values["name"] ?? "").lowercased()
            let relation = (values["rel"] ?? "").lowercased()
            let value: String?
            let priority: Int
            if property == "og:image" || property == "og:image:url" {
                value = values["content"]; priority = 0
            } else if property == "twitter:image" {
                value = values["content"]; priority = 1
            } else if relation.contains("icon") {
                value = values["href"]; priority = 2
            } else { continue }
            guard let value else { continue }
            let decoded = value.replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: decoded, relativeTo: base)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) else { continue }
            preferred.append((priority, url))
        }
        return preferred.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

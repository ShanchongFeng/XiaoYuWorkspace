import AppKit
import Foundation

@MainActor
final class FileOpenService {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    func applications(for url: URL) -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: url)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func open(_ url: URL, with application: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: application,
                                configuration: NSWorkspace.OpenConfiguration(),
                                completionHandler: nil)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyPath(_ url: URL) {
        copyText(url.path)
    }

    func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

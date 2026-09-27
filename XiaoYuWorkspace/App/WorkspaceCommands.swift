import SwiftUI

private struct WorkspaceModelFocusedKey: FocusedValueKey {
    typealias Value = WorkspaceModel
}

extension FocusedValues {
    var workspaceModel: WorkspaceModel? {
        get { self[WorkspaceModelFocusedKey.self] }
        set { self[WorkspaceModelFocusedKey.self] = newValue }
    }
}

struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceModel) private var model

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Project…") { model?.addProject() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
            Button("Open") { model?.openSelected() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model?.selectedFile == nil)
            Button("Quick Look") { model?.previewSelected() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model?.selectedFile == nil)
            Button("Show in Finder") { model?.reveal(model?.selectedFile) }
                .disabled(model?.currentRoot == nil)
        }
        CommandMenu("File Operations") {
            Button("New Folder…") { model?.newFolderPresented = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model?.currentRoot == nil || model?.isOperating == true)
            Button("Import Files or Folders…") { model?.importItems() }
                .disabled(model?.currentRoot == nil || model?.isOperating == true)
            Button("Export Selected Copies…") { model?.exportSelected() }
                .disabled(model?.selectedFile == nil || model?.isOperating == true)
            Button("Rename…") { model?.requestRenameSelected() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(model?.selectedFile == nil || model?.isOperating == true)
            Button("Duplicate") { model?.duplicateSelected() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model?.selectedFile == nil || model?.isOperating == true)
            Divider()
            Button("Copy") { model?.copySelected() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(model?.selectedFile == nil || model?.isOperating == true)
            Button("Cut") { model?.cutSelected() }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(model?.selectedFile == nil || model?.isOperating == true)
            Button("Paste") { model?.paste() }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(model?.hasClipboard != true)
            Divider()
            Button("Move to Trash", role: .destructive) { model?.moveSelectedToTrash() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model?.selectedFile == nil || model?.isOperating == true)
        }
        CommandMenu("Project") {
            Button("Refresh") { model?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model?.currentRoot == nil)
            Button("Show in Finder") { model?.reveal() }
                .disabled(model?.currentRoot == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Show or Hide Inspector") { model?.inspectorPresented.toggle() }
                .keyboardShortcut("i", modifiers: .command)
        }
    }
}

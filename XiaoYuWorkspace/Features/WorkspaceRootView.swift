import AppKit
import SwiftData
import SwiftUI
import QuickLook
import UniformTypeIdentifiers

struct WorkspaceDraggedFile: Codable, Transferable {
    let projectID: UUID
    let relativePath: String
    let fileURL: URL

    private static let contentType = UTType(exportedAs: "com.xiaoyu.workspace.dragged-file")

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
        ProxyRepresentation(exporting: \.fileURL)
    }
}

struct WorkspaceRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.undoManager) private var undoManager
    @State private var model = WorkspaceModel()
    @State private var projectToRename: ProjectRecord?
    @State private var renameText = ""
    @State private var newFolderName = ""
    @State private var fileRenameText = ""
    @State private var tagDraft = ""
    @State private var conflictApplyToAll = false
    @State private var projectVisibleCount = 20
    @State private var projectsExpanded = UserDefaults.standard.object(forKey: "sidebarProjectsExpanded") as? Bool ?? true
    @State private var projectCollapseTask: Task<Void, Never>?
    @AppStorage("sidebarUsesCustomTransparency") private var customSidebarTransparency = false
    @AppStorage("sidebarTransparency") private var sidebarTransparency = 0.5
    @AppStorage("themeColorHex") private var themeColorHex = ThemePalette.defaultHex
    @State private var autoClassifyPresented = false
    @State private var autoClassifyScope: AutoClassificationScope = .currentProject
    @State private var journalFormPresented = false
    @State private var editingJournalID: UUID?
    @State private var journalName = ""
    @State private var journalWebsite = ""
    @State private var filePickerJournal: JournalSubmissionRecord?
    @State private var linkedFolderToRemove: ProjectLinkedFolder?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 225)
        } detail: {
            content
        }
        .inspector(isPresented: $model.inspectorPresented) {
            inspector
                .inspectorColumnWidth(min: 235, ideal: 275)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("添加项目", systemImage: "plus") { model.addProject() }
                    .help("添加现有项目文件夹")
                Button("自动分类", systemImage: "tag") {
                    autoClassifyScope = model.location == .allProjects ? .allProjects : .currentProject
                    autoClassifyPresented = true
                }
                .disabled(model.projects.isEmpty)
                .help("Jev 1.13 按文件内容自动分类")
                Button("刷新", systemImage: "arrow.clockwise") { model.refresh() }
                    .disabled(model.currentRoot == nil)
                    .help("重新扫描当前项目")
                Button("新建文件夹", systemImage: "folder.badge.plus") {
                    newFolderName = ""
                    model.newFolderPresented = true
                }
                .disabled(model.currentRoot == nil || model.isOperating)
                Button("导入", systemImage: "square.and.arrow.down") { model.importItems() }
                    .disabled(model.currentRoot == nil || model.isOperating)
                Button("检查器", systemImage: "sidebar.right") {
                    model.inspectorPresented.toggle()
                }
                .help("显示或隐藏检查器")
            }
            if model.isOperating {
                ToolbarItem(placement: .status) {
                    HStack(spacing: 8) {
                        if model.operationTotal > 0 {
                            ProgressView(value: Double(model.operationCompleted),
                                         total: Double(model.operationTotal))
                                .frame(width: 70)
                            Text("\(model.operationCompleted)/\(model.operationTotal)")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("停止后续项目") { model.cancelOperation() }
                                .font(.caption)
                        } else {
                            ProgressView("正在处理文件…").controlSize(.small)
                        }
                    }
                }
            }
        }
        .focusedSceneValue(\.workspaceModel, model)
        .searchable(text: $model.searchQuery, prompt: "搜索文件、路径、分类、标签和笔记")
        .quickLookPreview($model.previewURL)
        .onAppear {
            model.undoManager = undoManager
            model.configure(context: modelContext)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.reloadTrashRecords() }
        }
        .onChange(of: model.location) { _, newValue in
            model.navigate(to: newValue)
        }
        .onChange(of: model.selectedFile?.relativePath) { _, _ in
            tagDraft = model.selectedFile.flatMap { model.annotation(for: $0)?.tags.joined(separator: ", ") } ?? ""
        }
        .alert("无法完成操作", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
        .confirmationDialog("解除文件夹关联？", isPresented: Binding(
            get: { linkedFolderToRemove != nil },
            set: { if !$0 { linkedFolderToRemove = nil } }
        )) {
            Button("解除关联", role: .destructive) {
                if let link = linkedFolderToRemove, let project = model.currentProject {
                    model.removeLinkedFolder(link, from: project)
                }
                linkedFolderToRemove = nil
            }
            Button("取消", role: .cancel) { linkedFolderToRemove = nil }
        } message: {
            Text("磁盘上的文件会保留。此文件夹的工作台标注和投稿文件关联将删除。")
        }
        .sheet(item: $projectToRename) { project in
            VStack(alignment: .leading, spacing: 14) {
                Text("重命名项目").font(.headline)
                TextField("项目名称", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(project) }
                HStack {
                    Spacer()
                    Button("取消") { projectToRename = nil }
                    Button("保存") { commitRename(project) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 360)
        }
        .sheet(isPresented: $model.newFolderPresented) {
            VStack(alignment: .leading, spacing: 14) {
                Text("新建文件夹").font(.headline)
                TextField("文件夹名称", text: $newFolderName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitNewFolder() }
                HStack {
                    Spacer()
                    Button("取消") { model.newFolderPresented = false }
                    Button("创建") { commitNewFolder() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20).frame(width: 360)
        }
        .sheet(item: $model.renameRequest) { file in
            VStack(alignment: .leading, spacing: 14) {
                Text("重命名文件").font(.headline)
                TextField("名称", text: $fileRenameText)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { fileRenameText = file.name }
                    .onSubmit { commitFileRename(file) }
                HStack {
                    Spacer()
                    Button("取消") { model.renameRequest = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("重命名") { commitFileRename(file) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(fileRenameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20).frame(width: 360)
        }
        .sheet(item: $model.conflictPrompt) { prompt in
            VStack(alignment: .leading, spacing: 14) {
                Text("目标位置已有同名项目").font(.headline)
                Text("“\(prompt.name)”已存在于“\(prompt.destination)”。请选择如何处理。")
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("对后续同名项目使用此选择", isOn: $conflictApplyToAll)
                HStack {
                    Button("停止") { model.resolveConflict(.stop, applyToAll: false) }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("保留两份") {
                        model.resolveConflict(.keepBoth, applyToAll: conflictApplyToAll)
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("替换", role: .destructive) {
                        model.resolveConflict(.replace, applyToAll: conflictApplyToAll)
                    }
                }
            }
            .padding(20)
            .frame(width: 430)
            .onAppear { conflictApplyToAll = false }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $journalFormPresented) {
            VStack(alignment: .leading, spacing: 16) {
                Text(editingJournalID == nil ? "新建投稿期刊" : "编辑投稿期刊")
                    .font(.headline)
                TextField("期刊名称", text: $journalName)
                    .textFieldStyle(.roundedBorder)
                TextField("期刊网站链接", text: $journalWebsite)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.URL)
                Text("保存后会从期刊网页尝试识别封面图片，找不到时使用网站图标。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("取消") { journalFormPresented = false }
                        .keyboardShortcut(.cancelAction)
                    Button("保存") { commitJournalForm() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(journalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || WorkspaceModel.normalizedJournalWebsite(journalWebsite) == nil)
                }
            }
            .padding(22).frame(width: 440)
        }
        .sheet(item: $filePickerJournal) { journal in
            JournalFilePicker(model: model, journal: journal) {
                filePickerJournal = nil
            }
        }
        .sheet(isPresented: $autoClassifyPresented) {
            AutoClassificationPreview(model: model, scope: $autoClassifyScope) {
                autoClassifyPresented = false
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .tint(ThemePalette.color(for: themeColorHex))
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    cancelProjectListCollapse()
                    withAnimation(.linear(duration: 0.23)) {
                        projectsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("项目")
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(projectsExpanded ? 0 : -90))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(projectsExpanded ? "收起项目列表" : "展开项目列表")
                .padding(.leading, 14)
                .padding(.top, 10)
                .padding(.bottom, 5)

                VStack(spacing: 0) {
                    let showAllProjects = projectsExpanded || model.currentProject == nil
                    sidebarProjectButton("全部项目", systemImage: "square.stack.3d.up",
                                         location: .allProjects)
                        .opacity(showAllProjects ? 1 : 0)
                        .frame(height: showAllProjects ? 30 : 0, alignment: .top)
                        .clipped()
                        .allowsHitTesting(showAllProjects)

                    ForEach(model.projects) { project in
                        let isVisible = projectsExpanded || project.id == model.selectedProjectID
                        projectSidebarRow(project)
                            .opacity(isVisible ? 1 : 0)
                            .frame(height: isVisible ? 30 : 0, alignment: .top)
                            .clipped()
                            .allowsHitTesting(isVisible)
                    }
                }
                .padding(.horizontal, 10)

                if model.selectedProjectID != nil {
                    sidebarSectionTitle("当前项目")
                    VStack(spacing: 0) {
                        sidebarProjectButton("概览", systemImage: "square.grid.2x2", location: .overview)
                        sidebarProjectButton("投稿期刊", systemImage: "book.closed", location: .journals)
                        sidebarProjectButton("全部文件", systemImage: "list.bullet", location: .allFiles)
                        sidebarProjectButton("最近修改", systemImage: "clock", location: .recent)
                        sidebarProjectButton("收藏", systemImage: "star", location: .favorites)
                        sidebarProjectButton("废纸篓", systemImage: "trash", location: .trash)
                    }
                    .padding(.horizontal, 10)

                    sidebarSectionTitle("研究分类")
                    VStack(spacing: 0) {
                        ForEach(WorkflowCategory.allCases, id: \.self) { category in
                            CategorySidebarRow(category: category, model: model)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 18)
            .animation(.linear(duration: 0.23), value: projectsExpanded)
        }
        .onChange(of: projectsExpanded) { _, expanded in
            UserDefaults.standard.set(expanded, forKey: "sidebarProjectsExpanded")
        }
        .background {
            if customSidebarTransparency {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color(nsColor: .windowBackgroundColor)
                        .opacity(1 - sidebarTransparency))
            }
        }
    }

    private func cancelProjectListCollapse() {
        projectCollapseTask?.cancel()
        projectCollapseTask = nil
    }

    private func scheduleProjectListCollapse() {
        cancelProjectListCollapse()
        guard projectsExpanded else { return }
        projectCollapseTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            guard projectsExpanded else { return }
            withAnimation(.linear(duration: 0.23)) {
                projectsExpanded = false
            }
            projectCollapseTask = nil
        }
    }

    private func sidebarSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 14)
            .padding(.top, 18)
            .padding(.bottom, 5)
    }

    private func projectSidebarRow(_ project: ProjectRecord) -> some View {
        sidebarProjectButton(project.displayName, systemImage: "folder",
                             location: .project(project.id))
            .contextMenu {
                Button("在访达中显示") {
                    model.selectProject(project.id)
                    scheduleProjectListCollapse()
                    model.reveal()
                }
                Button("重命名显示名称…") {
                    renameText = project.displayName
                    projectToRename = project
                }
                Button("关联更多文件夹…") { model.addLinkedFolders(to: project) }
                Button("重新关联文件夹…") { model.relink(project) }
                Divider()
                Button("从工作台移除", role: .destructive) {
                    model.removeProject(project)
                }
            }
    }

    private func sidebarProjectButton(_ title: String, systemImage: String,
                                      location: WorkspaceLocation) -> some View {
        Button {
            model.location = location
            switch location {
            case .project: scheduleProjectListCollapse()
            case .allProjects: cancelProjectListCollapse()
            default: break
            }
        } label: {
            SidebarNavigationLabel(title, systemImage: systemImage,
                                   isSelected: model.location == location)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background {
                    if model.location == location {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .selectedContentBackgroundColor))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        if model.location == .allProjects {
            allProjectsView
        } else if model.currentProject == nil {
            ContentUnavailableView {
                Label("开始使用小鱼工作台", systemImage: "folder.badge.plus")
            } description: {
                Text("添加一个现有研究文件夹，原文件不会被复制或移动。")
            } actions: {
                Button("添加项目") { model.addProject() }
            }
        } else if model.currentRoot == nil {
            ContentUnavailableView("项目文件夹不可用", systemImage: "externaldrive.badge.questionmark",
                                   description: Text("请检查磁盘连接，或重新关联此项目。"))
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("重新关联") {
                            if let project = model.currentProject { model.relink(project) }
                        }
                    }
                }
        } else if model.location == .journals {
            journalView
        } else if model.location == .trash {
            trashView
        } else if model.location == .overview && model.searchQuery.isEmpty {
            overview
        } else if case .project = model.location, model.folderPath.isEmpty, model.searchQuery.isEmpty {
            overview
        } else {
            browser
        }
    }

    private var allProjectsView: some View {
        let query = model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let projects = model.projects
            .filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.lastKnownPath.localizedCaseInsensitiveContains(query) }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        return Group {
        if projects.isEmpty {
            VStack(spacing: 0) {
                allProjectsHeader(count: 0)
                    .padding(.horizontal, 28)
                    .padding(.top, 28)
                if query.isEmpty {
                    Button { model.addProject() } label: {
                        ContentUnavailableView("还没有项目", systemImage: "folder.badge.plus",
                                               description: Text("点击空白处，选择要添加的研究文件夹。"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("添加项目文件夹")
                } else {
                    ContentUnavailableView("没有匹配的项目", systemImage: "magnifyingglass",
                                           description: Text("换个关键词试试。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                allProjectsHeader(count: projects.count)
                .padding(.bottom, 8)
                ForEach(Array(projects.prefix(projectVisibleCount))) { project in
                    HStack(spacing: 18) {
                        Button {
                            model.selectProject(project.id)
                            scheduleProjectListCollapse()
                        } label: {
                            HStack(spacing: 18) {
                            Image("SidebarFolder")
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 34, height: 34)
                                .foregroundStyle(.tint)
                                .frame(width: 48)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(project.displayName).font(.headline).lineLimit(1)
                                Text("上次打开：\(project.lastOpenedAt?.formatted(date: .abbreviated, time: .shortened) ?? "尚未打开")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if project.isArchived {
                            Text("已归档").font(.caption).foregroundStyle(.secondary)
                        }
                        ProjectStatusMenu(project: project, model: model)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.regularMaterial)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
                            }
                    }
                }
                if projects.count > projectVisibleCount {
                    Button("加载更多项目") {
                        projectVisibleCount += 20
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .onAppear { projectVisibleCount += 20 }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        }
        }
        .navigationTitle("全部项目")
    }

    private func allProjectsHeader(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("全部项目").font(.largeTitle).bold()
            Spacer()
            Text("\(count) 个项目").foregroundStyle(.secondary)
        }
    }

    private var journalView: some View {
        GeometryReader { geometry in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("投稿期刊").font(.largeTitle).bold()
                            Spacer()
                            Button("新建期刊", systemImage: "plus") { beginNewJournal() }
                        }
                        .padding(.bottom, 8)
                        if model.journals.isEmpty {
                            ContentUnavailableView("还没有投稿期刊", systemImage: "book.closed",
                                                   description: Text("新建期刊记录，再关联当前项目中的投稿文件。"))
                                .frame(maxWidth: .infinity, minHeight: 320)
                        }
                        ForEach(model.journals) { journal in
                            JournalRow(journal: journal, model: model,
                                       edit: { beginEditJournal(journal) },
                                       addFiles: { filePickerJournal = journal },
                                       onExpand: { scrollProxy.scrollTo(journal.id, anchor: .top) })
                                .id(journal.id)
                        }
                        Color.clear
                            .frame(height: max(0, geometry.size.height - 120))
                            .accessibilityHidden(true)
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle("投稿期刊")
            }
        }
    }

    private var overview: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let project = model.currentProject {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(project.displayName).font(.largeTitle).bold()
                            Text("\(model.files.count) 个文件与文件夹")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        ProjectStatusMenu(project: project, model: model)
                            .padding(.top, 7)
                    }
                    Divider()
                    HStack {
                        Text("关联的文件夹").font(.headline)
                        Spacer()
                        Button("添加文件夹", systemImage: "folder.badge.plus") {
                            model.addLinkedFolders(to: project)
                        }
                    }
                    Button {
                        model.reveal()
                    } label: {
                        Label(URL(fileURLWithPath: project.lastKnownPath).lastPathComponent,
                              systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                    ForEach(project.linkedFolders) { link in
                        HStack {
                            Button {
                                model.folderPath = link.virtualRootPath
                                model.location = .project(project.id)
                            } label: {
                                Label(link.displayName, systemImage: "folder")
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Menu {
                                Button("在访达中显示") {
                                    if let file = model.file(at: link.virtualRootPath) {
                                        model.reveal(file)
                                    }
                                }
                                Button("重新关联…") { model.relink(link, in: project) }
                                Divider()
                                Button("解除关联", role: .destructive) {
                                    linkedFolderToRemove = link
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                    Divider()
                    Text("分类").font(.headline)
                    ForEach(WorkflowCategory.allCases.filter { model.count(in: $0) > 0 }, id: \.self) { category in
                        Button {
                            model.location = .category(category.rawValue)
                        } label: {
                            HStack {
                                Text(category.rawValue)
                                Spacer()
                                Text(model.count(in: category).formatted())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Divider()
                    HStack {
                        Text("最近修改").font(.headline)
                        Spacer()
                        Button("查看全部文件") { model.location = .allFiles }
                    }
                    ForEach(Array(model.files.filter { !$0.isDirectory }
                        .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
                        .prefix(8))) { file in
                        Button {
                            model.open(file)
                        } label: {
                            HStack {
                                FileIconView(fileName: file.name,
                                             isFolder: file.isBrowsableFolder)
                                Text(file.name)
                                Spacer()
                                Text(file.modifiedAt?.formatted(date: .abbreviated, time: .omitted) ?? "")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if model.files.isEmpty && !model.isScanning {
                        Text("此项目中没有可显示的文件。")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minWidth: max(0, geometry.size.width - 56),
                   minHeight: max(0, geometry.size.height - 56),
                   alignment: .topLeading)
            .padding(28)
        }
        }
        .navigationTitle(model.currentProject?.displayName ?? "小鱼工作台")
        .toolbar {
            if model.isScanning {
                ToolbarItem(placement: .status) { ProgressView().controlSize(.small) }
            }
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            if !model.folderPath.isEmpty {
                HStack(spacing: 8) {
                    Button("上一级", systemImage: "chevron.left") { model.goUp() }
                        .labelStyle(.iconOnly)
                    Text(model.folderPath).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                Divider()
            }
            Table(model.visibleFiles,
                  selection: $model.selectedFilePaths, sortOrder: $model.sortOrder) {
                TableColumn("名称", value: \.name) { file in
                    FileNameCell(file: file, model: model)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.enter(file) })
                }
                .width(min: 260, ideal: 400)
                TableColumn("种类", value: \.kind)
                TableColumn("分类") { file in
                    Text(model.classification(for: file).workflow.rawValue)
                }
                TableColumn("大小") { file in
                    Text(file.size.map {
                        ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                    } ?? "—")
                }
                TableColumn("修改时间") { file in
                    Text(file.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                }
                TableColumn("位置") { file in
                    Text(model.displayPath(file.parentPath))
                }
                    .width(min: 120, ideal: 180)
            }
            .contextMenu(forSelectionType: String.self) { paths in
                if let path = paths.first, let file = model.file(at: path) {
                    fileContextMenu(for: file)
                }
            }
            .overlay {
                if model.visibleFiles.isEmpty && !model.isScanning {
                    ContentUnavailableView("没有文件", systemImage: "doc.text.magnifyingglass")
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty, !model.isOperating else { return false }
                model.importDroppedURLs(files)
                return true
            }
            .dropDestination(for: WorkspaceDraggedFile.self) { items, _ in
                model.moveDroppedFiles(items,
                                       copying: NSEvent.modifierFlags.contains(.option))
            }
        }
        .navigationTitle(browserTitle)
        .toolbar {
            if model.isScanning {
                ToolbarItem(placement: .status) { ProgressView().controlSize(.small) }
            }
        }
    }

    @ViewBuilder
    private func fileContextMenu(for file: ScannedFile) -> some View {
        if model.isLinkedFolderEntry(file) {
            Button("打开") { model.enter(file) }
            Button("在访达中显示") { model.reveal(file) }
            Button("复制路径") { model.copyPath(file) }
        } else {
        Button("打开") { model.enter(file) }
        Menu("打开方式") {
            ForEach(model.applications(for: file), id: \.self) { application in
                Button(application.deletingPathExtension().lastPathComponent) {
                    model.open(file, with: application)
                }
            }
        }
        Button("快速预览") {
            model.selectedFilePaths = [file.relativePath]
            model.previewSelected()
        }
        Divider()
        if file.isBrowsableFolder {
            Button("粘贴到此文件夹") { model.paste(into: file) }
                .disabled(!model.hasClipboard)
        }
        Button("重命名…") { model.renameRequest = file }
        Button("制作副本") {
            model.selectedFilePaths = [file.relativePath]
            model.duplicateSelected()
        }
        Button("复制") {
            model.selectedFilePaths = [file.relativePath]
            model.copySelected()
        }
        Button("剪切") {
            model.selectedFilePaths = [file.relativePath]
            model.cutSelected()
        }
        Button(model.annotation(for: file)?.isFavorite == true ? "取消收藏" : "收藏") {
            model.toggleFavorite(file)
        }
        Button(model.annotation(for: file)?.pinnedAt == nil ? "置顶" : "取消置顶") {
            model.togglePin(file)
        }
        if !file.isBrowsableFolder {
            Menu("分类到") {
                ForEach(WorkflowCategory.allCases, id: \.self) { category in
                    Button {
                        model.setManualWorkflow(category, for: file)
                    } label: {
                        if model.classification(for: file).workflow == category {
                            Label(category.rawValue, systemImage: "checkmark")
                        } else {
                            Text(category.rawValue)
                        }
                    }
                }
                if model.annotation(for: file)?.manualWorkflowRaw != nil {
                    Divider()
                    Button("恢复自动分类") {
                        model.setManualWorkflow(nil, for: file)
                    }
                }
            }
        }
        if !model.journals.isEmpty {
            Menu("关联到投稿期刊") {
                ForEach(model.journals) { journal in
                    Button(journal.name) {
                        _ = model.linkFiles([file.relativePath], to: journal)
                    }
                }
            }
        }
        Button("移到废纸篓", role: .destructive) {
            model.selectedFilePaths = [file.relativePath]
            model.moveSelectedToTrash()
        }
        Divider()
        Button("导出副本…") {
            model.selectedFilePaths = [file.relativePath]
            model.exportSelected()
        }
        Button("在访达中显示") { model.reveal(file) }
        Button("复制路径") { model.copyPath(file) }
        Button("复制相对路径") { model.copyRelativePath(file) }
        }
    }

    private var trashView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("这里记录从当前项目通过小鱼工作台移入系统废纸篓的文件。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            if model.currentTrashRecords.isEmpty {
                ContentUnavailableView("废纸篓没有记录", systemImage: "trash",
                                       description: Text("从当前项目移到废纸篓的文件会显示在这里。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.currentTrashRecords) { record in
                    HStack(spacing: 10) {
                        FileIconView(fileName: record.name)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.name).lineLimit(1)
                            Text(record.originalRelativePath)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(record.isAvailable
                             ? record.trashedAt.formatted(date: .abbreviated, time: .shortened)
                             : "原文件已不可用")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("恢复") { model.restore(record) }
                            .disabled(!record.isAvailable || model.isOperating)
                        Button("在访达中显示") { model.revealTrashed(record) }
                            .disabled(!record.isAvailable)
                        if !record.isAvailable {
                            Button("移除记录") { model.forgetTrashed(record) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("废纸篓")
    }

    private var browserTitle: String {
        if !model.folderPath.isEmpty { return (model.folderPath as NSString).lastPathComponent }
        return switch model.location {
        case .allProjects: "全部项目"
        case .journals: "投稿期刊"
        case .allFiles: "全部文件"
        case .recent: "最近修改"
        case .favorites: "收藏"
        case .trash: "废纸篓"
        case .category(let category): category
        default: model.currentProject?.displayName ?? "文件"
        }
    }

    private var inspector: some View {
        Form {
            if let file = model.selectedFile {
                Section("常规") {
                    LabeledContent("名称", value: file.name)
                    LabeledContent("种类", value: file.kind)
                    if let size = file.size {
                        LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                }
                Section("科研分类") {
                    LabeledContent("工作流", value: model.classification(for: file).workflow.rawValue)
                    LabeledContent("科学领域", value: model.classification(for: file).domain)
                    LabeledContent("格式", value: model.classification(for: file).format)
                    LabeledContent("用途", value: model.classification(for: file).role)
                    Picker("手动分类", selection: Binding<WorkflowCategory?>(
                        get: { model.annotation(for: file)?.manualWorkflowRaw.flatMap(WorkflowCategory.init(rawValue:)) },
                        set: { model.setManualWorkflow($0, for: file) }
                    )) {
                        Text("自动").tag(nil as WorkflowCategory?)
                        ForEach(WorkflowCategory.allCases, id: \.self) { category in
                            Text(category.rawValue).tag(Optional(category))
                        }
                    }
                    Text(model.classification(for: file).explanation)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("研究元数据") {
                    Toggle("收藏", isOn: Binding(
                        get: { model.annotation(for: file)?.isFavorite == true },
                        set: { value in
                            if (model.annotation(for: file)?.isFavorite == true) != value {
                                model.toggleFavorite(file)
                            }
                        }
                    ))
                    TextField("标签（逗号分隔）", text: $tagDraft)
                        .onSubmit { model.updateTags(tagDraft, for: file) }
                    Button("保存标签") { model.updateTags(tagDraft, for: file) }
                    TextField("笔记", text: Binding(
                        get: { model.annotation(for: file)?.note ?? "" },
                        set: { model.updateNote($0, for: file) }
                    ), axis: .vertical)
                    .lineLimit(3...8)
                }
                Section("位置") {
                    Text(model.displayPath(file.relativePath)).textSelection(.enabled)
                    Button("在访达中显示") { model.reveal(file) }
                }
                Section("日期") {
                    if let date = file.createdAt {
                        LabeledContent("创建", value: date.formatted())
                    }
                    if let date = file.modifiedAt {
                        LabeledContent("修改", value: date.formatted())
                    }
                }
            } else if let project = model.currentProject {
                Section("项目") {
                    LabeledContent("名称", value: project.displayName)
                    LabeledContent("状态") {
                        ProjectStatusMenu(project: project, model: model)
                    }
                    TextField("目标期刊", text: Binding(
                        get: { project.targetJournal },
                        set: { model.updateProject(project, targetJournal: $0) }
                    ))
                    TextField("说明", text: Binding(
                        get: { project.projectDescription },
                        set: { model.updateProject(project, description: $0) }
                    ), axis: .vertical)
                    Toggle("已归档", isOn: Binding(
                        get: { project.isArchived },
                        set: { model.updateProject(project, isArchived: $0) }
                    ))
                    Button("在访达中显示") { model.reveal() }
                }
            } else {
                Text("选择项目或文件查看详情。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func commitRename(_ project: ProjectRecord) {
        model.renameProject(project, to: renameText)
        projectToRename = nil
    }

    private func commitNewFolder() {
        model.createFolder(named: newFolderName)
        model.newFolderPresented = false
    }

    private func commitFileRename(_ file: ScannedFile) {
        model.rename(file, to: fileRenameText)
        model.renameRequest = nil
    }

    private func beginNewJournal() {
        editingJournalID = nil
        journalName = ""
        journalWebsite = ""
        journalFormPresented = true
    }

    private func beginEditJournal(_ journal: JournalSubmissionRecord) {
        editingJournalID = journal.id
        journalName = journal.name
        journalWebsite = journal.website
        journalFormPresented = true
    }

    private func commitJournalForm() {
        if let id = editingJournalID,
           let journal = model.journals.first(where: { $0.id == id }) {
            model.updateJournal(journal, name: journalName, website: journalWebsite)
        } else {
            model.createJournal(name: journalName, website: journalWebsite)
        }
        journalFormPresented = false
    }
}

private struct ProjectStatusMenu: View {
    let project: ProjectRecord
    let model: WorkspaceModel
    @State private var showingStages = false

    var body: some View {
        Button { showingStages = true } label: {
            HStack(spacing: 6) {
                Text(project.status)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(foregroundColor)
            .shadow(color: usesLightGrayStatusText ? .black.opacity(0.25) : .black.opacity(0.38), radius: 1, x: 0, y: 1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(backgroundColor, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $showingStages, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("项目阶段")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.bottom, 5)
                ForEach(ProjectStage.allCases) { stage in
                    Button {
                        model.updateProject(project, status: stage.rawValue)
                        showingStages = false
                    } label: {
                        HStack(spacing: 9) {
                            Circle()
                                .fill(color(for: stage))
                                .frame(width: 12, height: 12)
                            Text(stage.rawValue)
                            Spacer(minLength: 8)
                            if project.status == stage.rawValue {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .frame(width: 170)
            .presentationBackground(.ultraThinMaterial)
        }
        .help("选择项目阶段")
        .accessibilityLabel("项目状态：\(project.status)，点击选择阶段")
    }

    private var backgroundColor: Color {
        guard let stage = ProjectStage(rawValue: project.status) else {
            return Color(rgb: 0xB8D9F0)
        }
        return color(for: stage)
    }

    private func color(for stage: ProjectStage) -> Color {
        ThemePalette.color(for: hex(for: stage))
    }

    private var foregroundColor: Color {
        usesLightGrayStatusText ? Color(rgb: 0xE3E3E3) : .white
    }

    private var usesLightGrayStatusText: Bool {
        switch ProjectStage(rawValue: project.status) {
        case .planning, .experiments, .published: true
        default: false
        }
    }

    private func hex(for stage: ProjectStage) -> String {
        switch stage {
        case .planning: "#FCE54C"
        case .experiments: "#4CD8ED"
        case .analysis: "#5377E6"
        case .writing: "#8346EB"
        case .submissionPreparation: "#F79C40"
        case .submitting: "#F2453F"
        case .submitted: "#2961D9"
        case .revision: "#ED4CA2"
        case .published: "#4FE88C"
        }
    }
}

private extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}

private struct SidebarNavigationLabel: View {
    @AppStorage("themeColorHex") private var themeColorHex = ThemePalette.defaultHex
    let title: String
    let systemImage: String
    let isSelected: Bool

    init(_ title: String, systemImage: String, isSelected: Bool) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
    }

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(isSelected ? ThemePalette.contrastingColor(for: themeColorHex) : .primary)
        } icon: {
            Image(SidebarIcon.assetName(for: systemImage))
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(isSelected ? ThemePalette.contrastingColor(for: themeColorHex)
                                            : ThemePalette.color(for: themeColorHex))
        }
    }
}

private enum SidebarIcon {
    static func assetName(for symbol: String) -> String {
        switch symbol {
        case "square.stack.3d.up": "SidebarHome"
        case "folder": "SidebarFolder"
        case "square.grid.2x2": "SidebarOverview"
        case "book.closed", "books.vertical": "SidebarNotebook"
        case "list.bullet": "SidebarList"
        case "clock": "SidebarTime"
        case "star": "SidebarStar"
        case "trash": "SidebarTrash"
        case "doc.text": "SidebarWrite"
        case "externaldrive": "SidebarDrive"
        case "tablecells": "SidebarTable"
        case "chart.bar.xaxis": "SidebarChart"
        case "photo": "SidebarPhoto"
        case "curlybraces": "SidebarCode"
        case "checklist": "SidebarChecklist"
        case "paperplane": "SidebarNavigation"
        case "tray": "SidebarTray"
        default: "SidebarFolder"
        }
    }
}

private struct CategorySidebarRow: View {
    @AppStorage("themeColorHex") private var themeColorHex = ThemePalette.defaultHex
    let category: WorkflowCategory
    let model: WorkspaceModel
    @State private var isTargeted = false

    var body: some View {
        Button {
            model.location = .category(category.rawValue)
        } label: {
            HStack {
                SidebarNavigationLabel(category.rawValue, systemImage: category.symbol,
                                       isSelected: model.location == .category(category.rawValue))
                Spacer()
                Text(model.count(in: category).formatted())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(ThemePalette.color(for: themeColorHex).opacity(0.18))
                } else if model.location == .category(category.rawValue) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .selectedContentBackgroundColor))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: WorkspaceDraggedFile.self) { items, _ in
            model.classifyDroppedFiles(items, as: category)
        } isTargeted: { isTargeted = $0 }
        .dropDestination(for: URL.self) { urls, _ in
            model.classifyDroppedURLs(urls, as: category)
        }
    }
}

private struct JournalRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("themeColorHex") private var themeColorHex = ThemePalette.defaultHex
    let journal: JournalSubmissionRecord
    let model: WorkspaceModel
    let edit: () -> Void
    let addFiles: () -> Void
    let onExpand: () -> Void
    @State private var isExpanded = false
    @State private var isTargeted = false
    @State private var confirmDelete = false
    @State private var importingCover = false

    var body: some View {
        let linkedFileCount = model.links(for: journal).count
        let isExporting = model.exportingJournalIDs.contains(journal.id)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 18) {
                Button {
                    if let url = JournalCoverService.validWebURL(journal.website) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    JournalCoverView(journal: journal)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .help("打开期刊网站")
                    .accessibilityLabel("打开\(journal.name)的期刊网站")
                    .contextMenu {
                        Button("编辑封面…") { importingCover = true }
                        Button("刷新封面") { model.refreshJournalCover(journal) }
                    }
                    .fileImporter(isPresented: $importingCover, allowedContentTypes: [.image]) { result in
                        switch result {
                        case .success(let url): model.importJournalCover(url, for: journal)
                        case .failure(let error):
                            let nsError = error as NSError
                            if nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError {
                                model.errorMessage = "无法选择封面：\(error.localizedDescription)"
                            }
                        }
                    }
                VStack(alignment: .leading, spacing: 9) {
                    Text(journal.name).font(.title3).bold().lineLimit(2)
                    Text("\(linkedFileCount) 个关联文件")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        if let url = JournalCoverService.validWebURL(journal.website) {
                            Link("打开期刊网站", destination: url)
                        }
                        Button("添加文件") { addFiles() }
                        Button {
                            model.exportJournalFiles(journal)
                        } label: {
                            if isExporting {
                                HStack(spacing: 5) {
                                    ProgressView().controlSize(.small)
                                    Text("正在打包…")
                                }
                            } else {
                                Text("导出投稿文件")
                            }
                        }
                        .disabled(linkedFileCount == 0 || isExporting)
                        Button("编辑") { edit() }
                        Button("刷新封面") { model.refreshJournalCover(journal) }
                            .disabled(model.loadingJournalCovers.contains(journal.id))
                        if model.loadingJournalCovers.contains(journal.id) {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
                .frame(minHeight: 96, alignment: .center)
                Spacer(minLength: 8)
                Button {
                    let expanded = !isExpanded
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                        isExpanded = expanded
                        if expanded { onExpand() }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isExpanded ? "收起投稿文件" : "展开投稿文件")
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    let links = model.links(for: journal)
                    if links.isEmpty {
                        Text("尚未关联文件。可以点击“添加文件”，或把当前项目的文件拖到这条期刊记录。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(links) { link in
                        let file = model.linkedFile(for: link)
                        HStack(spacing: 10) {
                            FileIconView(fileName: (link.relativePath as NSString).lastPathComponent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text((link.relativePath as NSString).lastPathComponent).lineLimit(1)
                                Text(file == nil ? "文件已移动或不可用 · \(model.displayPath(link.relativePath))" : model.displayPath(link.relativePath))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("打开") { if let file { model.open(file) } }
                                .disabled(file == nil)
                            Button("在访达中显示") { if let file { model.reveal(file) } }
                                .disabled(file == nil)
                            Button("解除关联") { model.unlink(link) }
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .padding(.vertical, 3)
                    }
                }
                .clipped()
                .transition(reduceMotion ? .opacity : .offset(y: -12).combined(with: .opacity))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isTargeted ? ThemePalette.color(for: themeColorHex).opacity(0.18)
                               : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12))
        .dropDestination(for: WorkspaceDraggedFile.self) { items, _ in
            model.linkDroppedFiles(items, to: journal)
        } isTargeted: { isTargeted = $0 }
        .dropDestination(for: URL.self) { urls, _ in
            model.linkDroppedURLs(urls, to: journal)
        }
        .contextMenu {
            Button("编辑期刊…") { edit() }
            Button("编辑封面…") { importingCover = true }
            Button("添加投稿文件…") { addFiles() }
            Button("导出投稿文件…") { model.exportJournalFiles(journal) }
                .disabled(linkedFileCount == 0 || isExporting)
            Button("刷新封面") { model.refreshJournalCover(journal) }
            Divider()
            Button("删除期刊记录", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("删除“\(journal.name)”的期刊记录？", isPresented: $confirmDelete) {
            Button("删除记录和文件关联", role: .destructive) { model.deleteJournal(journal) }
        } message: {
            Text("项目文件不会被删除或移动。")
        }
    }
}

@MainActor
private enum JournalCoverCache {
    static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 100
        return cache
    }()

    static func image(for journal: JournalSubmissionRecord) -> NSImage? {
        let key = "\(journal.id)-\(journal.updatedAt.timeIntervalSince1970)" as NSString
        if let image = images.object(forKey: key) { return image }
        guard let data = journal.coverImageData, let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }
}

private struct JournalCoverView: View {
    let journal: JournalSubmissionRecord

    var body: some View {
        Group {
            if let image = JournalCoverCache.image(for: journal) {
                Image(nsImage: image)
                    .resizable().scaledToFit()
            } else {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 76, height: 96)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityLabel("\(journal.name)封面")
    }
}

private struct JournalFilePicker: View {
    let model: WorkspaceModel
    let journal: JournalSubmissionRecord
    let close: () -> Void
    @State private var query = ""
    @State private var selectedPaths: Set<String> = []
    @State private var availableFiles: [ScannedFile] = []
    @State private var folderFileCounts: [String: Int] = [:]
    @State private var availableFileCount = 0
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("为“\(journal.name)”关联投稿文件").font(.headline)
            Text("可选文件夹，自动关联其中所有层级的文件；原文件不会移动或复制。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("搜索项目文件", text: $query)
                .textFieldStyle(.roundedBorder)
            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("正在加载项目文件…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if availableFiles.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "没有可关联的文件" : "没有匹配的文件",
                                           systemImage: "doc.text.magnifyingglass")
                } else {
                    List(availableFiles, selection: $selectedPaths) { file in
                        HStack(spacing: 9) {
                            FileIconView(fileName: file.name, isFolder: file.isBrowsableFolder)
                            Text(model.displayPath(file.relativePath)).lineLimit(1)
                            if file.isBrowsableFolder {
                                Spacer()
                                Text("\(folderFileCounts[file.relativePath, default: 0]) 个文件")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(file.relativePath)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 340, maxHeight: .infinity)
            HStack {
                Text("可关联 \(availableFileCount) 个文件 · 已选 \(selectedPaths.count) 项")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { close() }
                Button("关联文件") {
                    if model.linkFiles(selectedPaths, to: journal) { close() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isLoading || selectedPaths.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 650, height: 510)
        .task(id: query) {
            isLoading = true
            let source = model.files
            let linked = Set(model.links(for: journal).map(\.relativePath))
            let search = query
            let filterTask = Task.detached(priority: .userInitiated) {
                JournalFileSelection.availableItems(in: source, linked: linked, query: search)
            }
            let results = await withTaskCancellationHandler {
                await filterTask.value
            } onCancel: {
                filterTask.cancel()
            }
            guard !Task.isCancelled else { return }
            availableFiles = results.rows
            folderFileCounts = results.folderFileCounts
            availableFileCount = results.fileCount
            isLoading = false
        }
    }
}

private enum AutoClassificationScope: String, CaseIterable, Identifiable {
    case currentProject = "当前项目"
    case allProjects = "全部项目"

    var id: Self { self }
}

private struct AutoClassificationPreview: View {
    let model: WorkspaceModel
    @Binding var scope: AutoClassificationScope
    let close: () -> Void
    @State private var showingProgress = false
    @State private var stopping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if showingProgress || model.isAutoClassifying {
                progressPage
            } else {
                setupPage
            }
        }
        .padding(24)
        .frame(width: 520)
        .frame(minHeight: 330)
        .onAppear {
            showingProgress = model.isAutoClassifying || model.autoClassificationTotal > 0
        }
    }

    private var setupPage: some View {
        Group {
            Label("Jev 1.13 自动分类", systemImage: "tag")
                .font(.title2.bold())
            Text("提取项目中的Markdown、CSV、XLSX、Docx等文本内容，由Jev模型进行判断分类，不会影响你已手动分类的文件")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("处理范围", selection: $scope) {
                Text("当前项目").tag(AutoClassificationScope.currentProject)
                    .disabled(model.currentProject == nil)
                Text("全部项目").tag(AutoClassificationScope.allProjects)
            }
            .pickerStyle(.segmented)
            Text(scope == .allProjects
                 ? "范围：已导入的 \(model.projects.count) 个项目。"
                 : "范围：\(model.currentProject?.displayName ?? "尚未选择项目")。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("提取的文本片段会发送至OpenRouter的Jev模型进行分析，无法正常读取的文件会跳过，保密文件请勿使用")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("关闭") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("开始自动分类") {
                    stopping = false
                    model.startAutoClassification(allProjects: scope == .allProjects)
                    showingProgress = model.isAutoClassifying
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var progressPage: some View {
        Group {
            Label(model.isAutoClassifying ? "正在自动分类" : "自动分类结果",
                  systemImage: model.isAutoClassifying ? "tag" : "checkmark.circle")
                .font(.title2.bold())
            Text(model.autoClassificationPreparing ? "正在扫描项目文件…" :
                 "已处理 \(model.autoClassificationCompleted) / \(model.autoClassificationTotal) 个文件")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            if model.autoClassificationPreparing {
                ProgressView().progressViewStyle(.linear)
            } else {
                ProgressView(value: Double(model.autoClassificationCompleted),
                             total: Double(max(model.autoClassificationTotal, 1)))
                    .progressViewStyle(.linear)
            }
            Text(model.autoClassificationStatus)
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                progressMetric("已分类", value: model.autoClassificationChanged)
                progressMetric("手动跳过", value: model.autoClassificationManualSkipped)
                progressMetric("无内容", value: model.autoClassificationNoContent)
                progressMetric("失败", value: model.autoClassificationFailed)
            }
            Spacer(minLength: 0)
            HStack {
                if model.isAutoClassifying {
                    Spacer()
                    Button(stopping ? "正在停止…" : "停止") {
                        stopping = true
                        model.cancelAutoClassification()
                    }
                    .disabled(stopping)
                } else {
                    Button("返回设置") { showingProgress = false }
                    Spacer()
                    Button("关闭") { close() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func progressMetric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)").font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private enum FileIconCache {
    static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    static func icon(for fileName: String) -> NSImage {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        let key = (fileExtension.isEmpty ? "file" : fileExtension) as NSString
        if let cached = images.object(forKey: key) { return cached }
        let type = UTType(filenameExtension: fileExtension) ?? UTType.data
        let icon = NSWorkspace.shared.icon(for: type)
        images.setObject(icon, forKey: key)
        return icon
    }
}

private struct FileIconView: View {
    let fileName: String
    var isFolder = false

    var body: some View {
        Group {
            if isFolder {
                Image("SidebarFolder")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tint)
            } else {
                Image(nsImage: FileIconCache.icon(for: fileName))
                    .resizable()
                    .interpolation(.high)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

private struct FileNameCell: View {
    @AppStorage("themeColorHex") private var themeColorHex = ThemePalette.defaultHex
    let file: ScannedFile
    let model: WorkspaceModel
    @State private var isDropTargeted = false

    @ViewBuilder
    var body: some View {
        if let fileURL = model.url(for: file), let projectID = model.selectedProjectID {
            contentRow.draggable(WorkspaceDraggedFile(projectID: projectID,
                                                      relativePath: file.relativePath,
                                                      fileURL: fileURL))
        } else {
            contentRow
        }
    }

    @ViewBuilder
    private var contentRow: some View {
        if file.isBrowsableFolder {
            folderDropRow
        } else {
            plainRow
        }
    }

    private var plainRow: some View {
        HStack(spacing: 7) {
            FileIconView(fileName: file.name, isFolder: file.isBrowsableFolder)
            Text(file.name).lineLimit(1)
            if model.annotation(for: file)?.pinnedAt != nil {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(ThemePalette.color(for: themeColorHex))
                    .accessibilityLabel("已置顶")
            }
        }
        .contentShape(Rectangle())
    }

    private var folderDropRow: some View {
        plainRow
        .background(isDropTargeted ? ThemePalette.color(for: themeColorHex).opacity(0.18) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty, !model.isOperating else { return false }
            model.importDroppedURLs(files, into: file)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .dropDestination(for: WorkspaceDraggedFile.self) { items, _ in
            return model.moveDroppedFiles(items, into: file,
                                          copying: NSEvent.modifierFlags.contains(.option))
        }
    }
}

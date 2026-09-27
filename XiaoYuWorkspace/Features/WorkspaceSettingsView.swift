import AppKit
import SwiftUI

struct WorkspaceSettingsView: View {
    @AppStorage("themeColorHex") private var themeColorHex = ThemePalette.defaultHex

    var body: some View {
        TabView {
            about
                .tabItem { Label("关于", systemImage: "info.circle") }
            AppearanceSettingsView()
                .tabItem { Label("外观", systemImage: "sidebar.left") }
            OpenRouterSettingsView()
                .tabItem { Label("OpenRouter", systemImage: "key") }
            ActivityLogView()
                .tabItem { Label("日志", systemImage: "list.bullet.rectangle") }
        }
        .frame(minWidth: 650, minHeight: 440)
        .tint(ThemePalette.color(for: themeColorHex))
    }

    private var about: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 104, height: 104)
            Text("小鱼工作台")
                .font(.title.bold())
            Text("版本 \(version)（\(build)）")
                .foregroundStyle(.secondary)
            Divider().frame(width: 400)
            Text("免费使用，未经授权的商业使用可能构成侵权")
            HStack(spacing: 4) {
                Text("有任何建议请联系")
                Link("yuluoxiangsiqi@icloud.com",
                     destination: URL(string: "mailto:yuluoxiangsiqi@icloud.com")!)
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
}

private struct AppearanceSettingsView: View {
    @AppStorage("themeColorHex") private var themeColorHex = ThemePalette.defaultHex
    @AppStorage("sidebarUsesCustomTransparency") private var customTransparency = false
    @AppStorage("sidebarTransparency") private var transparency = 0.5

    var body: some View {
        Form {
            Section("主题色") {
                ForEach(ThemePalette.groups) { group in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(group.name)
                            .font(.subheadline.weight(.semibold))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5),
                                  spacing: 10) {
                            ForEach(group.hexes, id: \.self) { hex in
                                ThemeSwatchButton(hex: hex, isSelected: themeColorHex == hex) {
                                    themeColorHex = hex
                                }
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
            Section("侧栏") {
                Toggle("自定义侧栏透明度", isOn: $customTransparency)
                HStack {
                    Slider(value: $transparency, in: 0...1, step: 0.05,
                           onEditingChanged: { editing in
                        if !editing {
                            recordAppearanceChange("侧栏透明度", detail: "\(Int((transparency * 100).rounded()))%")
                        }
                    }) {
                        Text("透明度")
                    }
                    Text("\(Int((transparency * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
                .disabled(!customTransparency)
                Text("0% 更实，100% 更通透。关闭自定义时使用 macOS 默认外观。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .onChange(of: customTransparency) { _, enabled in
            recordAppearanceChange("侧栏外观", detail: enabled ? "启用自定义透明度" : "使用系统默认")
        }
        .onChange(of: themeColorHex) { oldValue, newValue in
            if oldValue != newValue {
                recordAppearanceChange("主题色", detail: newValue)
            }
        }
    }

    private func recordAppearanceChange(_ action: String, detail: String) {
        Task {
            try? await ActivityLogStore.shared.append(
                ActivityEvent(action: action, detail: detail, projectName: nil))
        }
    }
}

private struct ThemeSwatchButton: View {
    let hex: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(ThemePalette.color(for: hex))
                    .frame(height: 38)
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(ThemePalette.contrastingColor(for: hex))
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? Color.primary : Color.primary.opacity(0.08),
                                          lineWidth: isSelected ? 2 : 1)
                    }
                Text(hex)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("主题色 \(hex)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct OpenRouterSettingsView: View {
    @State private var input = ""
    @State private var hasSavedKey = false
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section("OpenRouter API Key") {
                Text("当前模型：TypeSafe Jev 1.13")
                    .foregroundStyle(.secondary)
                SecureField("输入 API Key", text: $input)
                    .textFieldStyle(.roundedBorder)
                Text(hasSavedKey ? "已保存到本机钥匙串" : "尚未设置 API Key")
                    .foregroundStyle(hasSavedKey ? .green : .secondary)
                HStack {
                    Button("保存到钥匙串") { save() }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("删除已保存的密钥", role: .destructive) { delete() }
                        .disabled(!hasSavedKey)
                }
                Link("获取 OpenRouter API Key",
                     destination: URL(string: "https://openrouter.ai/settings/keys")!)
                if let statusMessage {
                    Text(statusMessage).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .onAppear { reload() }
    }

    private func reload() {
        do {
            hasSavedKey = try OpenRouterAPIKeyStore.load() != nil
            statusMessage = nil
        } catch { statusMessage = error.localizedDescription }
    }

    private func save() {
        do {
            try OpenRouterAPIKeyStore.save(input)
            input = ""
            hasSavedKey = true
            statusMessage = nil
            recordKeyChange("保存 OpenRouter API Key")
        } catch { statusMessage = error.localizedDescription }
    }

    private func delete() {
        do {
            try OpenRouterAPIKeyStore.delete()
            input = ""
            hasSavedKey = false
            statusMessage = nil
            recordKeyChange("删除 OpenRouter API Key")
        } catch { statusMessage = error.localizedDescription }
    }

    private func recordKeyChange(_ action: String) {
        Task {
            try? await ActivityLogStore.shared.append(
                ActivityEvent(action: action, detail: "仅记录密钥状态，不记录密钥内容。", projectName: nil))
        }
    }
}

private struct ActivityLogView: View {
    @State private var events: [ActivityEvent] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("操作日志").font(.title2.bold())
                Spacer()
                Button("刷新", systemImage: "arrow.clockwise") {
                    Task { await reload() }
                }
            }
            if isLoading {
                ProgressView("正在读取日志…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("日志读取失败", systemImage: "exclamationmark.triangle",
                                       description: Text(errorMessage))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if events.isEmpty {
                ContentUnavailableView("还没有变更记录", systemImage: "list.bullet.rectangle",
                                       description: Text("保存或修改项目后，记录会出现在这里。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(events) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(event.action).fontWeight(.semibold)
                            Spacer()
                            Text(event.occurredAt.formatted(
                                .dateTime.year().month().day().hour().minute().second()))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(event.detail)
                            .font(.caption)
                            .textSelection(.enabled)
                        if let projectName = event.projectName {
                            Text("项目：\(projectName)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(20)
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            events = try await ActivityLogStore.shared.load()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

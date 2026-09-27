# 小鱼工作台

小鱼工作台是一款原生 macOS 科研项目文件工作台。它整理项目、文件分类和投稿记录，**原文件始终保留在访达中的原位置**。

| 项目 | 信息 |
| --- | --- |
| 当前版本 | 0.2.23（25） |
| 系统要求 | macOS 27 及以上、Apple silicon |
| 技术栈 | SwiftUI、SwiftData、App Sandbox |
| 使用许可 | [PolyForm Noncommercial 1.0.0](LICENSE.md)，禁止未经授权的商业用途 |

[下载最新版 DMG](https://github.com/ShanchongFeng/XiaoYuWorkspace/releases/latest) · [查看开发规格](docs/Research_Workspace_macOS27_ARCHITECTURE_UI.md)

## 功能

### 项目与文件夹

- 一个项目可以关联多个现有文件夹；“全部文件”、搜索和自动分类合并显示这些文件夹的内容，同名文件按来源区分。
- 项目可记录阶段、目标期刊、说明和归档状态；“全部项目”提供概览、搜索和分批加载。
- 使用安全书签记住访问权限。解除文件夹关联不会移动磁盘上的文件，但会删除该文件夹在工作台中的标注和投稿关联。

### 文件浏览与操作

- 递归浏览项目目录，查看最近修改、收藏、置顶、标签和笔记；支持 Quick Look、系统“打开方式”和访达定位。
- 支持新建、重命名、复制、移动、导入副本、导出副本和移到系统废纸篓；同名冲突可选择保留两份、替换或停止。
- 支持从访达拖入文件，以及在工作台内拖动文件。外部文件变化由 FSEvents 监听并刷新索引。

### 分类与搜索

- 根据文件名和目录规则提供基础分类，也可以手动分类；把文件拖到侧栏分类即可保存。
- 可选用 OpenRouter 的 TypeSafe Jev 1.13 按**每个文件的实际文本内容**自动分类。支持 Markdown、CSV、XLSX、DOCX 等文本类文件；图片和 PDF 不参与。手动分类结果始终优先。
- 自动分类显示进度并可停止。提取的文本片段会发送至 OpenRouter；请勿对保密文件使用此功能。API Key 保存在本机钥匙串。

### 投稿与外观

- 为项目记录投稿期刊、网址和封面，并关联多个投稿文件；关联操作不会移动原文件。
- 可将关联文件从多个项目文件夹打包为 ZIP，按来源分目录保存。
- 提供 30 种主题色、侧栏透明度设置，以及只记录实际变更的本地操作日志。

## 安装

1. 从 [Releases](https://github.com/ShanchongFeng/XiaoYuWorkspace/releases/latest) 下载 DMG。
2. 打开 DMG，将“小鱼工作台.app”拖入“应用程序”。
3. 首次打开后，在工作台中选择现有项目文件夹。

当前公开包采用本地代码签名，**尚未使用 Developer ID 签名或经过 Apple 公证**。其他 Mac 首次打开时可能受到 Gatekeeper 限制；请仅在确认下载来源可信后，按 macOS“隐私与安全性”的提示操作。

## 从源码构建

需要 Xcode 27、XcodeGen 和 Apple silicon Mac：

```sh
xcodegen generate
xcodebuild -project XiaoYuWorkspace.xcodeproj -scheme XiaoYuWorkspace \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

默认方案运行单元测试。`XiaoYuWorkspaceUITests` 已保留，但完整的 UI 自动化和正式分发签名仍需配置。应用 Bundle ID 为 `com.xiaoyu.workspace.native27`。

## 已知限制

- 当前仍是开发版本。文件重命名及移动的撤销、单个大文件复制中的即时取消、跨窗口或跨项目拖动，尚未完整实现或验证。
- 侧栏与期刊行拖放仍需真实鼠标端到端验证；期刊封面依赖网站公开图片元数据和网络状态。
- 在处理重要项目文件前，建议先用测试文件夹验证文件操作。

## 许可与第三方资源

本仓库的原创代码和原创资源采用 [PolyForm Noncommercial License 1.0.0](LICENSE.md)。符合条款的非商业使用、修改与再分发可以进行；商业用途需要另行取得授权。**这是一份限制商业用途的源码可用许可，不属于 OSI 定义的开源许可。** 商业授权或建议可联系 [yuluoxiangsiqi@icloud.com](mailto:yuluoxiangsiqi@icloud.com)。

侧边栏使用 Alex Martynov 的 [Unoline 图标](https://iconstore.co/)。这些第三方图标遵循其原许可，允许作为个人或商业项目中的界面组件使用和修改，但不得未经作者许可将其作为独立图标包重新分发；它们不受本仓库 PolyForm 许可约束。

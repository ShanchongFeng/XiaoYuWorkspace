# 小鱼工作台

小鱼工作台是一款原生 macOS 科研项目文件工作台。它整理项目、文件分类和投稿记录，**原文件始终保留在访达中的原位置**

| 项目 | 信息 |
| --- | --- |
| 当前版本 | 0.2.24（26） |
| 最低系统版本 | macOS 15、Apple silicon；界面仅在 macOS 27 上验证 |
| 技术栈 | SwiftUI、SwiftData、App Sandbox |
| 使用许可 | [PolyForm Noncommercial 1.0.0](LICENSE.md)，禁止未经授权的商业用途 |

[下载最新版 DMG](https://github.com/ShanchongFeng/XiaoYuWorkspace/releases/latest) · [查看开发规格](docs/Research_Workspace_macOS27_ARCHITECTURE_UI.md)

> **本地运行与 API Key：** 软件在本机运行；Jev 准确分类需自备 OpenRouter API Key，密钥保存在 macOS 钥匙串，请勿分享或提交到仓库；分类时文本片段会发送至 OpenRouter，请留意用量和费用

## 功能

### 项目与文件夹

- 一个项目可以关联多个现有文件夹；“全部文件”、搜索和自动分类合并显示这些文件夹的内容，同名文件按来源区分
- 项目可记录阶段、目标期刊、说明和归档状态；“全部项目”提供概览、搜索和分批加载
- 使用安全书签记住访问权限。解除文件夹关联不会移动磁盘上的文件，但会删除该文件夹在工作台中的标注和投稿关联

### 文件浏览与操作

- 递归浏览项目目录，查看最近修改、收藏、置顶、标签和笔记；支持 Quick Look、系统“打开方式”和访达定位
- 支持新建、重命名、复制、移动、导入副本、导出副本和移到系统废纸篓；同名冲突可选择保留两份、替换或停止
- 支持从访达拖入文件，以及在工作台内拖动文件。外部文件变化由 FSEvents 监听并刷新索引

### 分类与搜索

- 根据文件名和目录规则提供基础分类，也可以手动分类；把文件拖到侧栏分类即可保存
- 可选用 OpenRouter 的 TypeSafe Jev 1.13 按**每个文件的实际文本内容**自动分类。支持 Markdown、CSV、XLSX、DOCX 等文本类文件；图片和 PDF 不参与。手动分类结果始终优先
- 自动分类显示进度并可停止。调用方式、费用和保密提醒见下文

### 投稿与外观

- 为项目记录投稿期刊、网址和封面，并关联多个投稿文件；关联操作不会移动原文件
- 可将关联文件从多个项目文件夹打包为 ZIP，按来源分目录保存
- 提供 30 种主题色、侧栏透明度设置，以及只记录实际变更的本地操作日志

## 准确分类：Jev 与本地方案

### 当前接入与费用

- 内置的准确分类使用 **TypeSafe Jev 1.13**，经 **OpenRouter** 调用；Jev 是面向结构化决策的模型，不是通用对话 LLM。使用前需自行[申请 OpenRouter API Key](https://openrouter.ai/settings/keys)，并在应用设置中保存到本机钥匙串
- [OpenRouter 当前页面](https://openrouter.ai/typesafe/jev-1.13)标出的参考价为：每百万输入 token **0.042 美元**、每百万输出 token **0 美元**。价格可能调整，以实际账单为准。作者申请 TypeSafe 官方 API 时仍在排队，因此先接入 OpenRouter；作者当时查询的两边标价相同，后续请以各平台最新定价核对

### 每份文件如何判断

1. 应用在本机提取当前文件的文本内容；图片、PDF 和无法读取正文的文件跳过，已经手动分类的文件不覆盖
2. 请求以 JSON 预定义全部候选类别及说明；Jev 在结构化响应中为**每份文件选择一个类别**。每份文件独立请求，最多同时处理 3 份，其余排队等待
3. Jev 的上下文窗口为 32k。应用为分类结构与输出预留空间，将单文件证据控制在约 29k 估算 token 内；超出时取开头、中间和结尾的片段。如服务端仍报超限，会缩短片段重试。省略的段落可能包含关键证据，因此超长文件的分类准确性可能下降

### 保密文件与替代方案

> **保密提醒：** 准确分类会将文件中的文本片段发送至 OpenRouter，保密文件请勿使用；手动分类和基础分类无需调用 Jev

如需数据留在本机，可考虑部署开源的 [Kev 决策模型](https://github.com/jaredpalmer/kev)；也可针对自己的科研方向，基于 [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B)、[Qwen3.5-9B](https://huggingface.co/Qwen/Qwen3.5-9B) 或 [Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B) 等稠密模型准备标注数据并训练。**当前应用尚未接入这些本地模型**；部署、标注和训练需要额外硬件与时间，个人使用规模下的前期成本可能高于直接调用 API

## 安装

1. 从 [Releases](https://github.com/ShanchongFeng/XiaoYuWorkspace/releases/latest) 下载 DMG
2. 打开 DMG，将“小鱼工作台.app”拖入“应用程序”
3. 首次打开后，在工作台中选择现有项目文件夹

当前公开包采用本地代码签名，**尚未使用 Developer ID 签名或经过 Apple 公证**。其他 Mac 首次打开时可能受到 Gatekeeper 限制；请仅在确认下载来源可信后，按 macOS“隐私与安全性”的提示操作

## 从源码构建

需要 Xcode 27、XcodeGen 和 Apple silicon Mac：

```sh
xcodegen generate
xcodebuild -project XiaoYuWorkspace.xcodeproj -scheme XiaoYuWorkspace \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

默认方案运行单元测试。`XiaoYuWorkspaceUITests` 已保留，但完整的 UI 自动化和正式分发签名仍需配置。应用 Bundle ID 为 `com.xiaoyu.workspace.native27`

## 已知限制

- 应用目前以 macOS 15 为最低构建目标，但界面只在 macOS 27 上优化和测试；macOS 15、26 的外观与交互表现尚未实机验证
- 当前仍是开发版本。文件重命名及移动的撤销、单个大文件复制中的即时取消、跨窗口或跨项目拖动，尚未完整实现或验证
- 侧栏与期刊行拖放仍需真实鼠标端到端验证；期刊封面依赖网站公开图片元数据和网络状态
- 在处理重要项目文件前，建议先用测试文件夹验证文件操作

## 其他平台与二次开发

目前没有 Windows 构建。若要迁移到 Windows，可使用 Harness、Claude Code、Codex 等代理工具克隆本仓库，移植文件管理和分类逻辑，并在目标 x86 设备上做压力测试；界面可考虑 Tauri 或 WebUI。也欢迎在遵守本仓库[非商业许可](LICENSE.md)及第三方资源许可的前提下，用代理工具继续修改应用

## 许可与第三方资源

本仓库的原创代码和原创资源采用 [PolyForm Noncommercial License 1.0.0](LICENSE.md)。符合条款的非商业使用、修改与再分发可以进行；商业用途需要另行取得授权。**这是一份限制商业用途的源码可用许可，不属于 OSI 定义的开源许可。** 商业授权或建议可联系 [yuluoxiangsiqi@icloud.com](mailto:yuluoxiangsiqi@icloud.com)

侧边栏使用 Alex Martynov 的 [Unoline 图标](https://iconstore.co/)。这些第三方图标遵循其原许可，允许作为个人或商业项目中的界面组件使用和修改，但不得未经作者许可将其作为独立图标包重新分发；它们不受本仓库 PolyForm 许可约束

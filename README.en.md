# XiaoYu Workspace

[简体中文](README.md) · **English**

XiaoYu Workspace is a native macOS app for organizing research projects, files, and journal submissions; original files stay in their existing Finder locations

| Item | Details |
| --- | --- |
| Current version | 0.2.25 (build 27) |
| Minimum system | macOS 15 on Apple silicon; the UI has only been verified on macOS 27 |
| Technology | SwiftUI, SwiftData, App Sandbox |
| License | [PolyForm Noncommercial 1.0.0](LICENSE.md); commercial use requires separate authorization |

[Download the latest DMG](https://github.com/ShanchongFeng/XiaoYuWorkspace/releases/latest) · [Read the development specification (Chinese)](docs/Research_Workspace_macOS27_ARCHITECTURE_UI.md)

> **Local operation and API key:** The app runs on your Mac; Jev classification requires your own OpenRouter API key, stored in the macOS Keychain. Never share the key or commit it to a repository; classification sends text excerpts to OpenRouter, so monitor usage and charges

## Features

### Projects and folders

- Link multiple existing folders to one project; All Files, search, and automatic classification combine their contents and distinguish files with the same name by source
- Track a project's stage, target journal, notes, and archive status; All Projects offers an overview, search, and incremental loading
- Security-scoped bookmarks retain folder access; unlinking a folder does not move its files, but removes its workspace labels and journal submission associations

### File browsing and operations

- Browse project folders recursively and inspect recent changes, favorites, pinned items, labels, and notes; use Quick Look, Open With, or Reveal in Finder
- Create, rename, copy, move, import copies, export copies, and move items to the system Trash; on name conflicts, keep both, replace, or stop
- Drag files in from Finder or move them within the workspace; FSEvents watches for external changes and refreshes the index

### Classification and search

- Use basic classification based on file names and folder rules, or classify files manually by dragging them onto sidebar categories
- Optionally classify each file by its actual text content through TypeSafe Jev 1.13 on OpenRouter; Markdown, CSV, XLSX, DOCX, and similar text files are supported, while images and PDFs are excluded; manual categories take priority
- Automatic classification shows progress and can be stopped; see the API, pricing, and confidentiality notes below

### Submissions and appearance

- Record journals, URLs, and covers for each project, and associate multiple submission files without moving the originals
- Export associated files from multiple project folders as a ZIP, grouped by source
- Switch the interface between Chinese and English, choose from 30 theme colors, adjust sidebar transparency, and view a local activity log that records actual changes

## Detailed classification: Jev and local options

### Current integration and pricing

- Detailed classification uses **TypeSafe Jev 1.13** through **OpenRouter**; Jev is designed for structured decisions, rather than general conversation. [Create your own OpenRouter API key](https://openrouter.ai/settings/keys) and save it in the app's settings, which use the macOS Keychain
- The [OpenRouter model page](https://openrouter.ai/typesafe/jev-1.13) lists reference prices of **US$0.042 per million input tokens** and **US$0 per million output tokens**; prices may change, so check your actual bill. The author's TypeSafe direct API request was still pending when this integration was built; the listed prices matched at the time, but should be checked again on each provider's site

### How each file is classified

1. The app extracts text locally from each file; images, PDFs, unreadable files, and files already classified manually are skipped
2. Each request supplies all candidate categories and descriptions in a predefined JSON format; Jev selects one category per file in a structured response. Files are requested independently, with up to three processed concurrently and the rest queued
3. Jev has a 32k context window. The app reserves room for the category definitions and output, limiting each file's evidence to roughly 29k estimated tokens; for longer files it samples the beginning, middle, and end, then retries with a shorter excerpt if the service reports a context overflow. Omitted passages may contain important evidence, reducing accuracy for long files

### Confidential files and alternatives

> **Confidentiality reminder:** Detailed classification sends extracted text excerpts to OpenRouter; do not use it for confidential files. Manual and basic rule-based classification do not call Jev

To keep data on your Mac, you could deploy the open-source [Kev decision model](https://github.com/jaredpalmer/kev), or prepare labeled examples and train a dense model such as [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B), [Qwen3.5-9B](https://huggingface.co/Qwen/Qwen3.5-9B), or [Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B) for your research field. **The app does not currently integrate these local models**; deployment, labeling, and training require additional hardware and time, and their initial cost may exceed API use at a personal scale

## Installation

1. Download the DMG from [Releases](https://github.com/ShanchongFeng/XiaoYuWorkspace/releases/latest)
2. Open the DMG and drag “小鱼工作台.app” into Applications
3. Open the app and select an existing project folder

The public build is locally code-signed, but **has no Developer ID signature or Apple notarization**; Gatekeeper may block its first launch on another Mac. Proceed through macOS Privacy & Security only after verifying that you trust the download source

## Build from source

Requires Xcode 27, XcodeGen, and an Apple silicon Mac:

```sh
xcodegen generate
xcodebuild -project XiaoYuWorkspace.xcodeproj -scheme XiaoYuWorkspace \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

The default scheme runs unit tests; `XiaoYuWorkspaceUITests` remains in the project, but full UI automation and distribution signing still need configuration. The app's bundle ID is `com.xiaoyu.workspace.native27`

## Known limitations

- The minimum deployment target is macOS 15, but the UI has only been optimized and tested on macOS 27; appearance and interaction on macOS 15 and 26 remain unverified on real devices
- This is still a development release; undo for rename and move, immediate cancellation while copying a single large file, and cross-window or cross-project dragging are incomplete or unverified
- Sidebar and journal-row drag and drop still need end-to-end testing with a real mouse; journal covers depend on public website image metadata and network availability
- Try file operations in a test folder before using the app on important project files

## Other platforms and further development

There is no Windows build. For a Windows port, you can clone this repository with an agent tool such as Harness, Claude Code, or Codex, port the file-management and classification logic, and stress-test it on the target x86 hardware; Tauri or a web UI may suit the interface. You may also modify the app further with agent tools, subject to this repository's [noncommercial license](LICENSE.md) and third-party asset licenses

## License and third-party assets

Original code and assets in this repository are licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE.md); qualifying noncommercial use, modification, and redistribution are permitted, while commercial use requires separate authorization. **This is a source-available license that restricts commercial use, not an OSI-approved open-source license**. For commercial licensing or suggestions, contact [yuluoxiangsiqi@icloud.com](mailto:yuluoxiangsiqi@icloud.com)

The sidebar uses [Unoline icons](https://iconstore.co/) by Alex Martynov. Their own license allows their use and modification as UI components in personal or commercial projects, but does not allow redistribution as a standalone icon pack without the author's permission; the icons are not covered by this repository's PolyForm license

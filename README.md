<div align="center">

# MacPaste & WinPaste

### 轻量跨端桌面剪贴板 · 截图原地翻译 · 滚动长截图 · Snipaste 级无顶栏活贴图

**macOS 纯 Swift/SwiftUI（0 依赖 ~540 KB） · Windows .NET 8/WPF + SkiaSharp + 离线 PP-OCRv5（100% 功能/交互对齐）**

[![macOS](https://img.shields.io/badge/macOS-13.0%2B%20(arm64)-181c24?style=flat-square&logo=apple&logoColor=white)](https://github.com/HunterLzap/Mac-paste/releases/latest)
[![Windows](https://img.shields.io/badge/Windows-10%2F11%20(win--x64)-0078d4?style=flat-square&logo=windows&logoColor=white)](https://github.com/HunterLzap/Mac-paste/releases/latest)
[![Windows CI](https://github.com/HunterLzap/Mac-paste/actions/workflows/windows-build.yml/badge.svg)](https://github.com/HunterLzap/Mac-paste/actions/workflows/windows-build.yml)
[![Release](https://img.shields.io/github/v/release/HunterLzap/Mac-paste?style=flat-square&color=007aff)](https://github.com/HunterLzap/Mac-paste/releases)
[![License](https://img.shields.io/badge/License-MIT-64748b?style=flat-square)](LICENSE)

<br />

[产品亮点](#-核心亮点) · [快速下载安装](#-快速下载与安装) · [功能与交互](#-核心功能速览) · [双端快捷键速查](#-双端高频快捷键速查) · [源码构建与架构](#-源码构建与隐私说明)

<br />

<img src="docs/assets/macpaste-hero-light.svg" alt="MacPaste & WinPaste 浅色界面与核心功能总览" width="1180" />

</div>

---

## ✨ 核心亮点

| 亮点模块 | 解决什么痛点 | MacPaste / WinPaste 的做法 |
| :--- | :--- | :--- |
| **🍃 原生轻量 & 统一浅色 UI** | Electron/重框架剪贴板占内存、双端体验割裂 | macOS 纯 Swift 原生（**~540 KB**）；Windows 基于 **.NET 8 + WPF + SkiaSharp + PerMonitorV2 DPI**，共享同一套通透浅色卡片体系与按压微动效 |
| **📌 Snipaste 级无顶栏活贴图 (`F3`)** | 传统贴图顶栏臃肿遮挡画面、长文本无法缩放 | **常态零顶栏** 100% 还原画面；悬停时在**贴图外侧上/下方**智能展开中文标签工具栏；**任意位置拖拽移动**（`⌥/Alt+拖拽` 划词），**`⌥/Alt+滚轮` 大段文本同步缩放字号** |
| **🌐 截图原地替换翻译 (`F1`)** | 截图后再切翻译软件、译文错位或盖坏渐变底 | 严格对齐的 OCR 行组/段落合并、居中同轴传染、拼写断词还原与**外侧 3 点中值渐变双遍擦除重绘**，默认译为**简体中文**（24 种语言） |
| **📜 镂空直通滚动长截图 (`L`)** | 长图拼合经常文字重影、断层或滚不动 | 选区内部 **100% 鼠标透传**底层应用 + 双向位移配准防重影，支持空格键自动匀速滚屏、上滚回退与 `F3` 直接贴图 |
| **📋 无焦点回贴 & 表格交互网格** | 多条账号/SQL/命令反复切换窗口粘贴 | `NSWorkspace`/`WS_EX_NOACTIVATE` 无焦点悬停弹窗，选中自动送出 `⌘V`/`Ctrl+V`；支持「按序粘贴」自动递进及 Excel/飞书表格双击单元格导出 |

---

## 📥 快速下载与安装

👉 **[前往 GitHub Releases 下载最新版本 (`v1.2.0`)](https://github.com/HunterLzap/Mac-paste/releases/latest)**

### 🍎 macOS（Apple Silicon `arm64`，macOS 13.0+）
- 安装包：`MacPaste-v1.2.0-macOS-arm64.zip`（或固定链接 `MacPaste.zip`）
1. 双击解压出 `MacPaste.app`，拖入「访达 → 应用程序」（`/Applications`）。
2. **首次打开授权（无 Apple 年费公证证书）**：在「应用程序」中**按住 `Control` 键单击（或右键）`MacPaste.app` → 选择「打开」**，或终端执行 `xattr -cr /Applications/MacPaste.app`。

### 🪟 Windows（Windows 10 / 11 64 位便携自包含包，无需额外装 .NET）
- 安装包：`WinPaste-v1.2.0-win-x64.zip`（或固定链接 `WinPaste.zip`）
1. 下载后**完整解压**到任意目录（保留同级 `WinPaste.exe` 与 `models/` OCR 模型文件夹），双击 `WinPaste.exe` 即驻留系统托盘。
2. 如遇 SmartScreen 未知发布者拦截：点击「**更多信息 → 仍要运行**」即可。
3. *可选中英混排离线 OCR 增强*：便携包默认内置 PP-OCRv5 拉丁模型；若需离线识别中英混排截图文字，将 PP-OCRv5 中文模型放入同级 `models/custom-v5/` 目录即自动优先加载。

---

## 🖥️ 核心功能速览

### 1. 主剪贴板窗口 (`⌥V` / `Alt+V` · 状态栏/托盘常驻)
- **不抢焦点非激活面板**：呼出检索并点击粘贴时平滑写回原目标应用，支持**文本 / 长文本 / 图片 / 表格 / 文件路径**自动分类与实时搜索。
- **按序粘贴模式**：多段文本点击「按序粘贴」后预载第 1 段并归还焦点，在外部应用中每按一次 `⌘V` / `Ctrl+V`，卡片自动高亮反馈并装入下一段。
- **悬停独立预览窗**：条目上悬停 `0.4s` 自动滑出侧边预览，多段文本支持逐段独立「复制」或「粘贴」；表格支持单元格双击与 `Shift` 框选区域复制。

### 2. F1 交互式截图、原地翻译 & 滚动长截图
- **物理像素精准选区与取色**：多屏混合 DPI 下全物理像素坐标抓取（Windows 采用 `PerMonitorV2` + `BitBlt` 虚拟桌面），8 方向手柄、方向键 `1px` 微调、局部像素放大镜；按 <kbd>C</kbd> 复制 HEX 色值。
- **全矢量二次编辑标注**：矩形、椭圆、箭头、画笔、荧光笔、马赛克、文字（支持 `⌘Z` / `Ctrl+Z` 撤销，Windows 同步支持 `Ctrl+Y` 重做，选中后可拖动角点与整体移动）。
- **原地替换翻译**：默认自动译为**简体中文**（中文默认译为英文），支持 24 国语言切换、单次批量换行合并 + 并发降级兜底，保留标题/正文真实行高字重与深色按钮居中识别。

### 3. F3 桌面置顶活贴图 & 双语对照
- **外置智能工具栏**：常态零顶栏遮挡，悬停自动浮现于贴图**外侧上方**（靠屏幕顶部边缘自动翻转到下方），配备清晰中文按钮标签：
  - **图片贴图**：`原图` · `识字`（离线 OCR）· `翻译`（1-to-1 编号双语对照弹窗）· `复制` · `收起` · `关闭`
  - **文本贴图**：`原文` · `分段`（逐条复制/粘贴）· `翻译` · `编辑`/`完成` · `复制` · `收起` · `关闭`
- **零门槛贴图手势**：任意内容区拖拽移动（按住 `⌥`/`Alt` 可临时划词）；`⌥`/`Alt` + 滚轮缩放窗口与长文排版字号；`⌘`/`Ctrl` + 滚轮无级调节透明度。

---

## ⌨️ 双端高频快捷键速查

| 功能场景 | macOS (`MacPaste`) | Windows (`WinPaste`) | 功能说明 |
| :--- | :--- | :--- | :--- |
| 呼出 / 置顶主面板 | <kbd>⌥ Option</kbd> + <kbd>V</kbd> | <kbd>Alt</kbd> + <kbd>V</kbd> | 全局无焦点呼出或隐藏主窗口 |
| 交互式截图 / 原地翻译 | <kbd>F1</kbd> | <kbd>F1</kbd> | 启动全屏截图选区、标注与原地翻译 |
| 贴图到桌面 (`Pin`) | <kbd>F3</kbd> | <kbd>F3</kbd> | 将剪贴板或当前选区直接贴到屏幕最前 |
| 显隐全部活贴图 | <kbd>⇧ Shift</kbd> + <kbd>F3</kbd> | <kbd>Shift</kbd> + <kbd>F3</kbd> | 一键隐藏 / 恢复全部桌面贴图 |
| 按序粘贴下一段 | 监听全局 <kbd>⌘V</kbd> | <kbd>Alt</kbd> + <kbd>Shift</kbd> + <kbd>V</kbd> / 监听 <kbd>Ctrl</kbd>+<kbd>V</kbd> | 按序自动装入下一条待粘贴分段 |
| 贴图缩放 / 透明度 | <kbd>⌥</kbd> + 滚轮 / <kbd>⌘</kbd> + 滚轮 | <kbd>Alt</kbd> + 滚轮 / <kbd>Ctrl</kbd> + 滚轮 | 同步缩放图片与长文字号 / 调整透明度（`+`/`-`/`0` 微调重置） |
| 截图取色 / 微调 / 长截图 | <kbd>C</kbd> / 方向键 / <kbd>L</kbd> | <kbd>C</kbd> / 方向键 / <kbd>L</kbd> | 复制光标处 HEX / 1px 微调选区 / 开启滚动长截图 |
| 滚动长截图控制 | <kbd>空格键</kbd> / <kbd>Enter</kbd> | <kbd>空格键</kbd> / <kbd>Enter</kbd> | 暂停/恢复自动滚屏 · 完成拼接并写入剪贴板 |
| 撤销 / 重做 / 保存 | <kbd>⌘Z</kbd> / — / <kbd>⌘S</kbd> | <kbd>Ctrl</kbd>+<kbd>Z</kbd> / <kbd>Ctrl</kbd>+<kbd>Y</kbd> / <kbd>Ctrl</kbd>+<kbd>S</kbd> | 撤销/重做标注，或保存截图为 PNG |

---

## 🔨 源码构建与隐私说明

### macOS 构建（需要 Xcode Command Line Tools）
```bash
git clone https://github.com/HunterLzap/Mac-paste.git && cd Mac-paste
bash Scripts/build.sh
# 输出产物：build/MacPaste.app
```

### Windows 构建与测试（需要 .NET 8 SDK）
```powershell
git clone https://github.com/HunterLzap/Mac-paste.git
cd Mac-paste
dotnet restore windows/WinPaste.sln
dotnet build windows/WinPaste.sln -c Release --no-restore
dotnet test windows/WinPaste.Tests/WinPaste.Tests.csproj -c Release --no-build --verbosity normal
# 生成单文件便携可执行包：
dotnet publish windows/WinPaste.App/WinPaste.App.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -o publish/win-x64
```
> 仓库已配置 [windows-build.yml](.github/workflows/windows-build.yml)，每次推送至 `windows/**` 或打 `v*` 标签都会在 `windows-latest` Runner 上自动执行全量编译、`WinPaste.Tests` 回归测试并打包 `WinPaste-win-x64.zip`。

<details>
<summary><strong>🔐 数据安全、目录结构与系统权限 (点击展开)</strong></summary>

- **100% 本地存储与像素去重**：
  - **macOS**：`~/Library/Application Support/MacPaste/history.db`（SQLite3 WAL + Apple Vision OCR / Live Text 本地执行）。
  - **Windows**：`%LOCALAPPDATA%\WinPaste\history.db`（SQLite3 WAL + RapidOCR PP-OCRv5 ONNX 本地推理 + `ISpellChecker` 英文断词还原）。
  - 仅在主动点击「翻译」时向翻译接口发起文本请求。
- **工程目录**：
  - `Sources/MacPaste/`：macOS 原生 Swift / SwiftUI 源码
  - `windows/WinPaste.Core/`：跨平台核心引擎（剪贴板解析、表格解析、SQLite 存储、OCR 分块与断词、原位样式检测与双遍擦除重绘、长图拼接）
  - `windows/WinPaste.App/`：Windows WPF + SkiaSharp 桌面端应用与 Win32 P/Invoke 互操作层
  - `windows/WinPaste.Tests/`：xUnit 核心算法与端到端 OCR 集成测试套件（35 项测试全通过）
- **macOS 所需权限**：屏幕录制（F1 截图/取色/长截图）、辅助功能（仅点击自动回贴/按序粘贴模拟 `⌘V` 时需要）。

</details>

---

<div align="center">

基于 [MIT License](LICENSE) 开源 · 如果觉得顺手好用的话，欢迎点一个 ⭐ Star

</div>

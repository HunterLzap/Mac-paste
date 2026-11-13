<div align="center">

# MacPaste

### 轻量纯原生 macOS 剪贴板 · 截图原地翻译 · 滚动长截图 · Snipaste 级无顶栏活贴图

**0 第三方依赖 · 纯 Swift / SwiftUI 原生实现 · 安装包仅 ~500 KB · 数据 100% 本地离线**

[![Platform](https://img.shields.io/badge/Platform-macOS%2013.0%2B-181c24?style=flat-square&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![Architecture](https://img.shields.io/badge/Arch-Apple%20Silicon%20%2F%20arm64-007aff?style=flat-square)](https://support.apple.com/en-us/HT211814)
[![Dependencies](https://img.shields.io/badge/Dependencies-0%20(Zero)-16a34a?style=flat-square)](Package.swift)
[![Release](https://img.shields.io/github/v/release/HunterLzap/Mac-paste?style=flat-square&color=007aff)](https://github.com/HunterLzap/Mac-paste/releases)
[![License](https://img.shields.io/badge/License-MIT-64748b?style=flat-square)](LICENSE)

<br />

[产品亮点](#-核心亮点) · [快速下载安装](#-快速下载与安装) · [功能与交互](#-核心功能速览) · [快捷键速查](#-高频快捷键速查) · [源码构建](#-源码构建与隐私说明)

<br />

<img src="docs/assets/macpaste-hero.svg" alt="MacPaste v1.1 全新浅色界面与核心功能总览" width="1180" />

</div>

---

## ✨ 核心亮点

| 亮点模块 | 解决什么痛点 | MacPaste 的做法 |
| :--- | :--- | :--- |
| **🍃 极致轻量 & 统一浅色 UI** | Electron/重框架剪贴板占内存、界面割裂 | 纯 Swift + AppKit/SwiftUI，单包仅 **~533 KB**；红绿灯融合标题栏 + 全局 `TactileButtonStyle` 弹性触控反馈，全界面统一通透浅色风 |
| **📌 Snipaste 级无顶栏活贴图 (`F3`)** | 传统贴图顶栏臃肿遮挡画面、长文本无法缩放 | **常态零顶栏** 100% 还原画面；悬停时在**贴图外侧上/下方**智能展开中文标签工具栏；**任意位置拖拽移动**（`⌥+拖拽` 划词），**`⌥+滚轮` 大段文本同步缩放字号** |
| **🌐 截图原地替换翻译 (`F1`)** | 截图后再切翻译软件/遮挡弹窗看译文 | 选区内自动采样底色并在**原文位置直接排版替换译文**，默认智能译为**简体中文**（支持 24 种语言实时切换记忆 + 取色器 + 矢量化二次拖动标注） |
| **📜 镂空直通滚动长截图** | 长图拼合经常文字重影、断层或滚不动 | 选区内部 **100% 鼠标透传**底层应用 + Apple Vision 位移配准 & 双向 MAD 残差防重影，支持空格键自动匀速滚屏 |
| **📋 按序粘贴 & 表格交互网格** | 多条账号/SQL/命令反复 `⌘Tab` 切换复制 | 多行清单一键开启「按序粘贴」，目标应用里**连续敲 `⌘V` 自动递进下一段**；Excel/飞书表格支持双击单元格或 `Shift` 框选区域导出 |

---

## 📥 快速下载与安装

👉 **[前往 GitHub Releases 下载最新版 `MacPaste-v1.1.0-macOS-arm64.zip`（或固定链接 `MacPaste.zip`）](https://github.com/HunterLzap/Mac-paste/releases/latest)**

1. 双击解压下载好的 `.zip`，将 `MacPaste.app` 拖入「访达 → 应用程序」（`/Applications`）。
2. **首次打开授权说明（个人开源应用无 Apple 年费公证证书）**：
   - **纯鼠标方式（推荐）**：在「应用程序」中**按住 `Control` 键单击（或右键）`MacPaste.app` → 选择「打开」**，确认后即可永久正常运行。
   - **终端方式**：执行 `xattr -cr /Applications/MacPaste.app`。

---

## 🖥️ 核心功能速览

### 1. 主剪贴板窗口 (`⌥V` · 菜单栏常驻)
- **不抢焦点非激活面板**：呼出检索并点击粘贴时平滑写回原目标应用，支持**短文本 / 长文本 / 图片 / 表格**自动分类与 `120ms` 防抖实时搜索。
- **按序粘贴模式**：多段文本点击「按序粘贴」后预载第 1 段并归还焦点，在外部应用中每按一次 `⌘V`，卡片自动绿色闪烁并装入下一段。
- **悬停独立预览窗**：条目上悬停 `0.4s` 自动滑出侧边大字预览，多段文本支持逐段独立「复制」或「粘贴」。

### 2. F1 交互式截图、原地翻译 & 滚动长截图
- **精准选区与取色**：8 方向手柄、方向键 `1px` 微调、局部像素放大镜；按 <kbd>C</kbd> 直接复制光标处 HEX 色值。
- **全矢量可二次编辑标注**：矩形、椭圆、箭头、画笔、荧光笔、马赛克、文字（支持 `⌘Z` 撤销与选中后再拖动缩放）。
- **24 国语言原地翻译**：默认外文自动译为**简体中文**（中文默认译为英文），点击工具栏 `▾` 可切换 24 种语言，支持 `4.5s` 超时防死锁保护与翻译后直接 `F3` 贴图或 `⌘S` 保存。

### 3. F3 桌面置顶活贴图 & 离线 OCR
- **外置智能工具栏**：悬停自动浮现于贴图**外侧上方**，若贴图靠近屏幕顶部菜单栏则自动翻转到**外侧下方**，所有按钮配备清晰中文标签：
  - **图片贴图**：`原图` · `识字`（离线 Vision OCR 按行提取复制）· `翻译`（双语对照）· `复制` · `收起` · `关闭`
  - **文本贴图**：`原文` · `分段`（带序号打勾与逐条复制粘贴）· `翻译` · `编辑`/`完成`（便携便签）· `复制` · `收起` · `关闭`
- **零门槛贴图手势**：左键点击任意内容区即可拖动；`⌥+滚轮` 或双指捏合同步缩放图片与大段文字字号；拖动右侧/底边/右下角边缘自由拉伸尺寸；`⌘+滚轮` 可无级调整透明度。

---

## ⌨️ 高频快捷键速查

| 快捷键 / 手势 | 触发场景 | 功能说明 |
| :--- | :--- | :--- |
| <kbd>⌥ Option</kbd> + <kbd>V</kbd> | 全局 | 呼出 / 置顶主剪贴板面板 |
| <kbd>F1</kbd> | 全局 | 启动交互式全屏截图 / 原地翻译 / 长截图 |
| <kbd>F3</kbd> | 全局 | 将当前剪贴板（截图、长文或表格）直接贴到屏幕 |
| <kbd>⇧ Shift</kbd> + <kbd>F3</kbd> | 全局 | 一键隐藏 / 重新显示全部桌面活贴图 |
| 任意位置左键拖拽 | 桌面活贴图上 | 直接移动贴图（按住 <kbd>⌥ Option</kbd> 拖拽可临时划词） |
| <kbd>⌥ Option</kbd> + 滚轮 / 双指捏合 | 桌面活贴图（含大段文字） | 同步缩放贴图窗口与文字排版字号（<kbd>⌘0</kbd> 重置，<kbd>⌘+</kbd>/<kbd>⌘-</kbd> 微调） |
| <kbd>C</kbd> / 方向键 | F1 截图选区中 | 复制光标处 HEX 色值 / 1px 微调选区位置与宽高 |
| <kbd>空格键</kbd> / <kbd>Enter</kbd> | 滚动长截图 / 截图中 | 开始或暂停自动匀速滚屏 / 完成截取并写入剪贴板 |
| <kbd>Esc</kbd> | 任意浮窗或搜索 | 关闭当前截图或贴图 / 优先收起主窗口搜索框 |

---

## 🔨 源码构建与隐私说明

```bash
git clone https://github.com/HunterLzap/Mac-paste.git && cd Mac-paste
bash Scripts/build.sh
# 输出产物：build/MacPaste.app（内置自动使用本地 "MacPaste Developer" 证书签名以保持辅助功能授权持久化）
```

<details>
<summary><strong>🔐 数据安全、系统权限与常见问题 (点击展开)</strong></summary>

- **100% 本地存储与去重**：历史记录存放在 `~/Library/Application Support/MacPaste/history.db`（SQLite3 WAL），图片基于 `32×32 sRGB` 像素指纹去重，Apple Live Text 与 Vision OCR 全部本地离线执行；仅在你主动点击截图/贴图「翻译」时才会发出文本翻译请求。
- **所需系统权限（按需申请）**：
  - **屏幕录制**：用于 F1 截图、像素取色与滚动长截屏。
  - **辅助功能**：仅在使用「点击条目自动粘贴」或「按序粘贴」合成 `⌘V` 按键时需要（仅复制/贴图无需开启）。
- **大段文本贴图怎么既能滚轮阅读又能缩放大小？**：长文本超出贴图高度时，直接滑动滚轮用于上下阅读；按住 <kbd>⌥ Option</kbd> 再滑动滚轮（或触控板捏合）即可流畅放大/缩小字体与窗口。

</details>

---

<div align="center">

基于 [MIT License](LICENSE) 开源 · 如果觉得顺手好用的话，欢迎点一个 ⭐ Star

</div>

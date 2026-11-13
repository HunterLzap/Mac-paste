import AppKit
import SwiftUI

/// 活贴图内容视图：Snipaste 级无顶栏纯享画布（常态与悬停 100% 不遮挡内容，支持任意位置拖拽移动，外置工具栏自动在上方或下方展开）
/// 支持置顶、调整大小、滚轮/⌥+滚轮缩放文字与图片、⌘+滚轮调透明度、选项键(⌥)+拖拽划词
struct PinContentView: View {
    @ObservedObject var state: PinItemState
    var onToggleCollapse: () -> Void
    var onScaleAdjust: (CGFloat) -> Void = { _ in }
    var onTriggerTranslate: () -> Void = {}
    var onChangeTargetLanguage: (TranslationService.TargetLanguage) -> Void = { _ in }
    var onResizeStart: () -> CGSize
    var onResize: (CGSize, CGSize) -> Void
    var onClose: () -> Void

    @State private var copiedLineIdx: Int?
    @State private var pastedLineIdx: Int?
    @State private var copiedTranslation = false
    @State private var copiedSource = false

    private var cornerRadius: CGFloat {
        (state.kind == .image && !state.showOCRList && !state.showTranslation && !state.isCollapsed) ? 8 : AppTheme.panelCornerRadius
    }

    var body: some View {
        Group {
            if state.isCollapsed {
                collapsedBar
            } else {
                contentBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(AppTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    state.isHovered ? AppTheme.accent.opacity(0.45) : AppTheme.strongBorder,
                    lineWidth: 1.0
                )
        )
        .overlay(alignment: .bottom) {
            if !state.isCollapsed {
                ResizeHandleView(edge: .bottom, onResizeStart: onResizeStart, onResize: onResize)
            }
        }
        .overlay(alignment: .trailing) {
            if !state.isCollapsed {
                ResizeHandleView(edge: .right, onResizeStart: onResizeStart, onResize: onResize)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !state.isCollapsed {
                ResizeHandleView(edge: .corner, onResizeStart: onResizeStart, onResize: onResize)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .contextMenu {
            Button("复制全部内容") { state.copyAllToPasteboard() }
            Divider()
            Button("放大 (⌥+滚轮上 / ⌘+)") { onScaleAdjust(0.12) }
            Button("缩小 (⌥+滚轮下 / ⌘-)") { onScaleAdjust(-0.12) }
            if abs(state.contentScale - 1.0) > 0.02 {
                Button("重置缩放 (⌘0)") { onScaleAdjust(0) }
            }
            Divider()
            Button(state.isCollapsed ? "展开贴图" : "折叠为胶囊") { onToggleCollapse() }
            Button("关闭贴图 (Esc)") { onClose() }
        }
        .environment(\.colorScheme, .light)
    }

    // MARK: - 折叠态极简胶囊

    private var collapsedBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "pin.fill")
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.pinOrange)

            Text(collapsedTitle)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                onToggleCollapse()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.tactile(cornerRadius: 5))
            .help("展开贴图")

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.tactile(cornerRadius: 5))
            .help("关闭贴图 (Esc)")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(AppTheme.panelBackground)
        .contentShape(Rectangle())
    }

    private var collapsedTitle: String {
        switch state.kind {
        case .image: return "图片贴图 · \(state.imageSizeText)"
        case .table: return "表格贴图 · \(state.tableRows.count)×\(state.tableRows.first?.count ?? 0)"
        default:
            let first = state.textContent.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "文本贴图"
            return displayTruncate(first, 24)
        }
    }

    // MARK: - 内容主体

    @ViewBuilder
    private var contentBody: some View {
        switch state.kind {
        case .shortText, .longText:
            if state.showTranslation {
                translationBilingualView
            } else if state.isEditingText {
                TextEditor(text: $state.textContent)
                    .font(.system(size: 12.5 * state.contentScale))
                    .padding(8)
            } else if state.showSegments && state.paragraphs.count >= 2 {
                segmentsListView(lines: state.paragraphs)
            } else {
                SelectableTextView(text: state.textContent, fontScale: state.contentScale)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
            }

        case .image:
            if state.showTranslation {
                translationBilingualView
            } else if state.showOCRList {
                segmentsListView(lines: state.ocrLines)
            } else if let img = state.image {
                LiveTextImageView(image: img)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case .table:
            ScrollView([.horizontal, .vertical]) {
                pinTableGrid
                    .padding(8)
            }
        }
    }

    /// 分段交互列表（每段可打勾标记已用、可划词选中、可独立点「复制」或「粘贴」）
    private func segmentsListView(lines: [String]) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                    let isCopied = copiedLineIdx == idx
                    let isPasted = pastedLineIdx == idx
                    let isChecked = state.checkedIndices.contains(idx)

                    HStack(alignment: .top, spacing: 8) {
                        Button {
                            if isChecked {
                                state.checkedIndices.remove(idx)
                            } else {
                                state.checkedIndices.insert(idx)
                            }
                        } label: {
                            if isChecked {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.green)
                            } else {
                                Text("\(idx + 1)")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18, height: 18)
                                    .background(Circle().fill(Color.primary.opacity(0.08)))
                            }
                        }
                        .buttonStyle(.plain)
                        .help(isChecked ? "取消已用标记" : "标记为已处理")
                        .padding(.top, 1)

                        Text(line)
                            .font(.system(size: 12 * state.contentScale))
                            .strikethrough(isChecked, color: .secondary)
                            .foregroundStyle(isChecked ? AppTheme.textTertiary : AppTheme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 4) {
                            Button {
                                copySegment(line)
                                copiedLineIdx = idx
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                                    if copiedLineIdx == idx { copiedLineIdx = nil }
                                }
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 9))
                                    Text(isCopied ? "已复制" : "复制")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(isCopied ? Color.green.opacity(0.18) : Color.primary.opacity(0.08))
                                )
                                .foregroundStyle(isCopied ? Color.green : Color.primary)
                            }
                            .buttonStyle(.tactile(cornerRadius: 5, hoverFill: Color.black.opacity(0.06), pressedScale: 0.93))

                            Button {
                                PinWindowManager.shared.onPasteText?(line)
                                state.checkedIndices.insert(idx)
                                pastedLineIdx = idx
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                                    if pastedLineIdx == idx { pastedLineIdx = nil }
                                }
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: isPasted ? "checkmark" : "arrow.turn.down.left")
                                        .font(.system(size: 9))
                                    Text(isPasted ? "已粘贴" : "粘贴")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(isPasted ? Color.green.opacity(0.18) : Color.accentColor.opacity(0.14))
                                )
                                .foregroundStyle(isPasted ? Color.green : Color.accentColor)
                            }
                            .buttonStyle(.tactile(cornerRadius: 5, hoverFill: AppTheme.accentSoft, pressedScale: 0.93))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isCopied || isPasted
                                  ? AppTheme.successGreen.opacity(0.08)
                                  : AppTheme.cardSubtleBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(AppTheme.hairlineBorder, lineWidth: 0.8)
                    )
                }
            }
            .padding(10)
        }
    }

    /// 贴图内可交互表格网格（双击任意单元格复制）
    private var pinTableGrid: some View {
        let rows = state.tableRows
        let s = state.contentScale
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<min(rows.count, TableParser.maxRenderRows), id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<min(rows[r].count, TableParser.maxRenderCols), id: \.self) { c in
                        let val = rows[r][c]
                        Text(val.isEmpty ? " " : val)
                            .font(.system(size: 11 * s))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .frame(width: 84 * s, height: 22 * s, alignment: .leading)
                            .background(r % 2 == 0 ? AppTheme.cardSubtleBackground : AppTheme.cardBackground)
                            .overlay(Rectangle().stroke(AppTheme.hairlineBorder, lineWidth: 0.5))
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                copySegment(val)
                            }
                            .contextMenu {
                                Button("复制单元格") { copySegment(val) }
                                Button("粘贴单元格") { PinWindowManager.shared.onPasteText?(val) }
                                Button("复制整行") { copySegment(rows[r].joined(separator: "\t")) }
                            }
                    }
                }
            }
        }
    }

    // MARK: - 截图 / 文本双语翻译卡片视图

    @ViewBuilder
    private var translationBilingualView: some View {
        VStack(spacing: 0) {
            // 1. 语言控制栏（源语言检测 -> 目标语言下拉菜单 + 朗读 + 复制）
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("源:")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(state.detectedSourceName)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }

                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)

                Menu {
                    ForEach(TranslationService.commonTargetLanguages) { lang in
                        Button {
                            onChangeTargetLanguage(lang)
                        } label: {
                            HStack {
                                Text(lang.name)
                                if lang.code == state.selectedTargetLanguage.code {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(state.selectedTargetLanguage.name)
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    .foregroundStyle(Color.accentColor)
                }
                .menuStyle(.borderlessButton)
                .help("切换翻译目标语言")

                Spacer()

                if !state.translatedText.isEmpty {
                    Button {
                        speak(text: state.translatedText)
                    } label: {
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("朗读译文")

                    Button {
                        copyTranslation()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: copiedTranslation ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                            Text(copiedTranslation ? "已复制" : "复制译文")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(copiedTranslation ? Color.green.opacity(0.18) : Color.primary.opacity(0.08)))
                        .foregroundStyle(copiedTranslation ? Color.green : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .help("复制完整译文到剪贴板")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(AppTheme.panelBackground)

            Divider().overlay(AppTheme.hairlineBorder)

            // 2. 双语对照主体内容
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    // 原文卡片
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("原文")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                speak(text: state.sourceTextForTranslation)
                            } label: {
                                Image(systemName: "speaker.wave.1")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("朗读原文")

                            Button {
                                copySource()
                            } label: {
                                Image(systemName: copiedSource ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 9))
                                    .foregroundStyle(copiedSource ? Color.green : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("复制原文")
                        }
                        Text(state.sourceTextForTranslation.isEmpty ? "（等待识别...）" : state.sourceTextForTranslation)
                            .font(.system(size: 12 * state.contentScale))
                            .foregroundStyle(AppTheme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(AppTheme.cardSubtleBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(AppTheme.hairlineBorder, lineWidth: 0.8)
                    )

                    // 译文卡片
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("译文 (\(state.selectedTargetLanguage.name))")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                            Spacer()
                        }

                        if state.isTranslating {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在翻译中...")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 14)
                        } else if let errorMsg = state.translationErrorMessage {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(Color.orange)
                                    Text("翻译失败: \(errorMsg)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Button("重试") {
                                    onTriggerTranslate()
                                }
                                .font(.system(size: 11, weight: .medium))
                                .buttonStyle(.borderedProminent)
                                .controlSize(.mini)
                            }
                            .padding(.vertical, 6)
                        } else {
                            Text(state.translatedText.isEmpty ? "（无翻译内容）" : state.translatedText)
                                .font(.system(size: 13 * state.contentScale, weight: .regular))
                                .foregroundStyle(AppTheme.textPrimary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(AppTheme.selectedCardBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(AppTheme.accent.opacity(0.24), lineWidth: 0.9)
                    )
                }
                .padding(8)
            }
        }
    }

    private static let speechSynthesizer = NSSpeechSynthesizer()

    private func speak(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if Self.speechSynthesizer.isSpeaking {
            Self.speechSynthesizer.stopSpeaking()
        } else {
            Self.speechSynthesizer.startSpeaking(trimmed)
        }
    }

    private func copyTranslation() {
        let text = state.translatedText
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if pb.setString(text, forType: .string) {
            ClipboardMonitor.markInternalWrite(text)
            copiedTranslation = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                copiedTranslation = false
            }
        }
    }

    private func copySource() {
        let text = state.sourceTextForTranslation
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if pb.setString(text, forType: .string) {
            ClipboardMonitor.markInternalWrite(text)
            copiedSource = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                copiedSource = false
            }
        }
    }

    private func copySegment(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if pb.setString(text, forType: .string) {
            ClipboardMonitor.markInternalWrite(text)
        }
    }
}

// MARK: - 外置悬停浮动工具栏视图（自动展开于贴图之外上方或下方）

struct PinToolbarView: View {
    @ObservedObject var state: PinItemState
    var onToggleCollapse: () -> Void
    var onTriggerOCR: () -> Void
    var onTriggerTranslate: () -> Void
    var onClose: () -> Void

    @State private var copiedAll = false

    var body: some View {
        HStack(spacing: 4) {
            modeSegmentedGroup

            if state.kind != .table {
                Rectangle()
                    .fill(AppTheme.hairlineBorder)
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 2)
            }

            // 复制全部
            toolbarActionButton(
                symbol: copiedAll ? "checkmark" : "doc.on.doc",
                title: copiedAll ? "已复制" : "复制",
                tint: copiedAll ? AppTheme.successGreen : AppTheme.textSecondary,
                help: copiedAll ? "已复制" : "复制全部内容"
            ) {
                state.copyAllToPasteboard()
                copiedAll = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { copiedAll = false }
            }

            // 收起折叠
            toolbarActionButton(
                symbol: "chevron.up",
                title: "收起",
                tint: AppTheme.textSecondary,
                help: "收起为小胶囊"
            ) {
                onToggleCollapse()
            }

            // 关闭贴图
            toolbarActionButton(
                symbol: "xmark",
                title: "关闭",
                tint: AppTheme.textSecondary,
                help: "关闭贴图 (Esc)"
            ) {
                onClose()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3.5)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(AppTheme.hairlineBorder, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 5, y: 2)
        // 周围透明留白既能完整呈现阴影，也与贴图窗口无缝相接避免鼠标跨越断层
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .fixedSize()
        .environment(\.colorScheme, .light)
    }

    private func toolbarActionButton(
        symbol: String,
        title: String,
        tint: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.tactile(cornerRadius: 6, hoverFill: Color.black.opacity(0.065), pressedScale: 0.93))
        .help(help)
    }

    @ViewBuilder
    private var modeSegmentedGroup: some View {
        switch state.kind {
        case .image:
            let isRaw = !state.showOCRList && !state.showTranslation
            HStack(spacing: 2) {
                segIconButton(symbol: "photo", title: "原图", active: isRaw, loading: false, help: "原图视图（任意位置拖拽移动，⌥+拖拽划词）") {
                    state.showOCRList = false
                    state.showTranslation = false
                }
                segIconButton(symbol: "text.viewfinder", title: "识字", active: state.showOCRList, loading: state.isPerformingOCR, help: "OCR 识别并提取图片中的文字") {
                    if state.showOCRList {
                        state.showOCRList = false
                    } else {
                        state.showTranslation = false
                        onTriggerOCR()
                    }
                }
                segIconButton(symbol: "translate", title: "翻译", active: state.showTranslation, loading: state.isTranslating, help: "双语对照翻译") {
                    if state.showTranslation {
                        state.showTranslation = false
                    } else {
                        onTriggerTranslate()
                    }
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.06)))

        case .shortText, .longText:
            let isRaw = !state.showSegments && !state.showTranslation && !state.isEditingText
            HStack(spacing: 2) {
                segIconButton(symbol: "text.alignleft", title: "原文", active: isRaw, loading: false, help: "原文视图（任意位置拖拽移动，⌥+拖拽划词）") {
                    state.showSegments = false
                    state.showTranslation = false
                    state.isEditingText = false
                }
                if state.paragraphs.count >= 2 {
                    segIconButton(symbol: "list.number", title: "分段", active: state.showSegments && !state.showTranslation && !state.isEditingText, loading: false, help: "按段落拆分并逐条复制或粘贴") {
                        state.showTranslation = false
                        state.isEditingText = false
                        state.showSegments = true
                    }
                }
                segIconButton(symbol: "translate", title: "翻译", active: state.showTranslation, loading: state.isTranslating, help: "多语言智能翻译") {
                    if state.showTranslation {
                        state.showTranslation = false
                    } else {
                        state.isEditingText = false
                        onTriggerTranslate()
                    }
                }
                segIconButton(symbol: state.isEditingText ? "checkmark" : "pencil", title: state.isEditingText ? "完成" : "编辑", active: state.isEditingText, loading: false, help: state.isEditingText ? "完成编辑" : "直接编辑文本（便签模式）") {
                    state.showTranslation = false
                    state.isEditingText.toggle()
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.06)))

        case .table:
            EmptyView()
        }
    }

    private func segIconButton(symbol: String, title: String, active: Bool, loading: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if loading {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.55)
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: active ? .semibold : .medium))
                }
                Text(title)
                    .font(.system(size: 10.5, weight: active ? .semibold : .medium))
            }
            .foregroundStyle(active ? AppTheme.accent : AppTheme.textSecondary)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(active ? Color.white : Color.clear)
                    .shadow(color: active ? Color.black.opacity(0.08) : .clear, radius: 1, y: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.tactile(cornerRadius: 6, hoverFill: Color.black.opacity(0.065), pressedScale: 0.93))
        .help(help)
    }
}


// MARK: - 原生可划词文本视图（保持原始段落排版、空格与换行，支持直接拖选划词复制）

@MainActor
final class NativeSelectableTextView: NSView {
    let scrollView = NSScrollView()
    let textView = NSTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.font = NSFont.systemFont(ofSize: 13.0, weight: .regular)
        textView.textColor = AppTheme.nsTextPrimary
        textView.textContainer?.lineFragmentPadding = 6
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func setContent(_ text: String, fontScale: CGFloat) {
        if textView.string != text {
            textView.string = text
        }
        let targetFontSize = max(8.5, min(32.5, 13.0 * fontScale))
        if abs((textView.font?.pointSize ?? 13.0) - targetFontSize) > 0.2 {
            textView.font = NSFont.systemFont(ofSize: targetFontSize, weight: .regular)
        }
    }
}

struct SelectableTextView: NSViewRepresentable {
    let text: String
    var fontScale: CGFloat = 1.0

    func makeNSView(context: Context) -> NativeSelectableTextView {
        let v = NativeSelectableTextView(frame: .zero)
        v.setContent(text, fontScale: fontScale)
        return v
    }

    func updateNSView(_ nsView: NativeSelectableTextView, context: Context) {
        nsView.setContent(text, fontScale: fontScale)
    }
}

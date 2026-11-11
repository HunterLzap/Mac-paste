import AppKit
import SwiftUI

/// 活贴图内容视图：支持置顶、调整大小、调整透明度、双击折叠，且贴出的文字/图片/表格均可继续交互操作
struct PinContentView: View {
    @ObservedObject var state: PinItemState
    var onToggleCollapse: () -> Void
    var onOpacityChange: (Double) -> Void
    var onTriggerOCR: () -> Void
    var onTriggerTranslate: () -> Void = {}
    var onChangeTargetLanguage: (TranslationService.TargetLanguage) -> Void = { _ in }
    var onResizeStart: () -> CGSize
    var onResize: (CGSize, CGSize) -> Void
    var onClose: () -> Void

    @State private var copiedAll = false
    @State private var copiedLineIdx: Int?
    @State private var pastedLineIdx: Int?
    @State private var copiedTranslation = false
    @State private var copiedSource = false
    @State private var showOpacityPopover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            if !state.isCollapsed {
                Divider()
                contentBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(0.38), lineWidth: 1.2)
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
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 顶部控制栏

    private var headerBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "pin.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)

            Text(headerTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if !state.isCollapsed {
                modeButtons
            }

            // 透明度按钮 + 弹出滑块
            Button {
                showOpacityPopover.toggle()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 10))
                    Text("\(Int(round(state.opacity * 100)))%")
                        .font(.system(size: 9, design: .monospaced))
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("调整贴图透明度（也可直接在贴图上按 ⌘+滚轮 调节）")
            .popover(isPresented: $showOpacityPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("透明度")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text("\(Int(round(state.opacity * 100)))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { state.opacity },
                        set: { onOpacityChange($0) }
                    ), in: 0.15...1.0)
                    HStack(spacing: 6) {
                        ForEach([0.4, 0.7, 1.0], id: \.self) { preset in
                            Button("\(Int(preset * 100))%") {
                                onOpacityChange(preset)
                            }
                            .font(.caption2)
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                        Spacer()
                    }
                    Text("提示：⌘ + 滚轮 可快速调节透明度")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(10)
                .frame(width: 200)
            }

            // 一键复制全部
            Button {
                copyAll()
                copiedAll = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { copiedAll = false }
            } label: {
                Image(systemName: copiedAll ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(copiedAll ? Color.green : Color.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(copiedAll ? "已复制" : "复制全部内容")

            // 折叠/展开
            Button {
                onToggleCollapse()
            } label: {
                Image(systemName: state.isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 20)
            }
            .buttonStyle(.plain)
            .help(state.isCollapsed ? "展开贴图（或双击顶部栏）" : "折叠贴图为小胶囊（或双击顶部栏）")

            // 关闭贴图
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("关闭贴图 (Esc)")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var modeButtons: some View {
        switch state.kind {
        case .image:
            Button {
                onTriggerOCR()
            } label: {
                HStack(spacing: 3) {
                    if state.isPerformingOCR {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: state.showOCRList ? "photo" : "text.viewfinder")
                            .font(.system(size: 10))
                    }
                    Text(state.showOCRList ? "看原图" : "提取文字")
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(state.showOCRList ? "切换回原图视图（原图上可直接划词复制）" : "OCR 识别图片中的全部文字并拆分为可复制段落")

            Button {
                onTriggerTranslate()
            } label: {
                HStack(spacing: 3) {
                    if state.isTranslating {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: state.showTranslation ? "photo" : "character.bubble")
                            .font(.system(size: 10))
                    }
                    Text(state.showTranslation ? "看原图" : "翻译")
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.teal.opacity(0.18)))
                .foregroundStyle(Color.teal)
            }
            .buttonStyle(.plain)
            .help(state.showTranslation ? "切换回原图视图" : "自动识别图片中文字并进行多国语言翻译")

        case .shortText, .longText:
            if state.paragraphs.count >= 2 && !state.isEditingText {
                Button {
                    state.showSegments.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: state.showSegments ? "text.alignleft" : "list.number")
                            .font(.system(size: 10))
                        Text(state.showSegments ? "原文" : "分段")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(state.showSegments ? "切换为原始完整格式视图（直接划词复制）" : "切换为分段列表视图（带序号与按序粘贴）")
            }

            Button {
                onTriggerTranslate()
            } label: {
                HStack(spacing: 2) {
                    if state.isTranslating {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: state.showTranslation ? "text.alignleft" : "character.bubble")
                            .font(.system(size: 10))
                    }
                    Text(state.showTranslation ? "原文" : "翻译")
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.teal.opacity(0.18)))
                .foregroundStyle(Color.teal)
            }
            .buttonStyle(.plain)
            .help(state.showTranslation ? "切换回原文" : "多国语言智能翻译")

            Button {
                state.isEditingText.toggle()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: state.isEditingText ? "checkmark.circle.fill" : "pencil")
                        .font(.system(size: 10))
                    Text(state.isEditingText ? "完成" : "编辑")
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(state.isEditingText ? Color.green.opacity(0.18) : Color.primary.opacity(0.08)))
                .foregroundStyle(state.isEditingText ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(state.isEditingText ? "完成编辑" : "直接编辑贴图中的文字（当便签使用）")

        case .table:
            EmptyView()
        }
    }

    private var headerTitle: String {
        if state.isCollapsed {
            switch state.kind {
            case .image: return "图片贴图 · \(state.imageSizeText)"
            case .table: return "表格贴图 · \(state.tableRows.count)×\(state.tableRows.first?.count ?? 0)"
            default:
                let first = state.textContent.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "文本贴图"
                return displayTruncate(first, 24)
            }
        }
        switch state.kind {
        case .image:
            if state.showTranslation {
                return "截图翻译 · \(state.detectedSourceName) → \(state.selectedTargetLanguage.name)"
            }
            return state.showOCRList ? "图片文字 (\(state.ocrLines.count) 行)" : "图片贴图 · 可直接划词复制"
        case .table:
            return "表格贴图 · \(state.tableRows.count)×\(state.tableRows.first?.count ?? 0)（双击单元格复制）"
        case .shortText, .longText:
            if state.showTranslation {
                return "文本翻译 · \(state.detectedSourceName) → \(state.selectedTargetLanguage.name)"
            }
            if state.showSegments && state.paragraphs.count >= 2 {
                return "分段清单 · 共 \(state.paragraphs.count) 段"
            }
            let first = state.textContent.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "文本贴图"
            return displayTruncate(first, 22)
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
                    .font(.system(size: 12.5))
                    .padding(6)
            } else if state.showSegments && state.paragraphs.count >= 2 {
                segmentsListView(lines: state.paragraphs)
            } else {
                SelectableTextView(text: state.textContent)
                    .padding(4)
            }

        case .image:
            if state.showTranslation {
                translationBilingualView
            } else if state.showOCRList {
                segmentsListView(lines: state.ocrLines)
            } else if let img = state.image {
                LiveTextImageView(image: img)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(4)
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
                            .font(.system(size: 12))
                            .strikethrough(isChecked, color: .secondary)
                            .foregroundStyle(isChecked ? .secondary : .primary)
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
                            .buttonStyle(.plain)

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
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(isCopied || isPasted
                                  ? Color.green.opacity(0.08)
                                  : Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                    )
                }
            }
            .padding(10)
        }
    }

    /// 贴图内可交互表格网格（双击任意单元格复制）
    private var pinTableGrid: some View {
        let rows = state.tableRows
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<min(rows.count, TableParser.maxRenderRows), id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<min(rows[r].count, TableParser.maxRenderCols), id: \.self) { c in
                        let val = rows[r][c]
                        Text(val.isEmpty ? " " : val)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .frame(width: 84, height: 22, alignment: .leading)
                            .background(Color.primary.opacity(r % 2 == 0 ? 0.04 : 0.015))
                            .overlay(Rectangle().stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
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
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.03))

            Divider()

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
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.04))
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
                                .font(.system(size: 13, weight: .regular))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.08))
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

    private func copyAll() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if state.showTranslation && !state.translatedText.isEmpty {
            if pb.setString(state.translatedText, forType: .string) {
                ClipboardMonitor.markInternalWrite(state.translatedText)
            }
            return
        }
        switch state.kind {
        case .image:
            if state.showOCRList, !state.ocrLines.isEmpty {
                let joined = state.ocrLines.joined(separator: "\n")
                if pb.setString(joined, forType: .string) {
                    ClipboardMonitor.markInternalWrite(joined)
                }
            } else if let img = state.image,
                      let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) {
                if pb.setData(png, forType: .png) {
                    ClipboardMonitor.markInternalWrite()
                }
            }
        case .table:
            let tsv = TableParser.canonicalTSV(state.tableRows)
            if pb.setString(tsv, forType: .string) {
                if let html = TableParser.htmlTable(state.tableRows).data(using: .utf8) {
                    pb.setData(html, forType: .html)
                }
                ClipboardMonitor.markInternalWrite(tsv)
            }
        default:
            if pb.setString(state.textContent, forType: .string) {
                ClipboardMonitor.markInternalWrite(state.textContent)
            }
        }
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
        textView.textColor = NSColor.labelColor
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

    func setContent(_ text: String) {
        if textView.string != text {
            textView.string = text
        }
    }
}

struct SelectableTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NativeSelectableTextView {
        let v = NativeSelectableTextView(frame: .zero)
        v.setContent(text)
        return v
    }

    func updateNSView(_ nsView: NativeSelectableTextView, context: Context) {
        nsView.setContent(text)
    }
}

import SwiftUI

/// 文本条目卡片：支持常规展示与多段「按序粘贴」模式；悬停出现 置顶/删除 按钮；点击按设置分发
struct ItemRowView: View {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel
    let onCopy: () -> Void
    let onActivate: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var clickedFlash = false

    private var hasMultiParagraphs: Bool { item.paragraphs.count >= 2 }
    private var isSequential: Bool { viewModel.isSequential(item) }
    private var seqIndex: Int { viewModel.sequentialIndex(for: item) }
    private var isFlashing: Bool { clickedFlash || viewModel.sequentialFlashItemId == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if isSequential && hasMultiParagraphs {
                sequentialHeader
                sequentialBody
            } else {
                Text(displayTruncate(item.content))
                    .font(.system(size: 13))
                    .lineLimit(item.kind == .longText ? 3 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                Text(relativeTimeShort(item.createdAt))
                if hasMultiParagraphs {
                    Text("· 共 \(item.paragraphs.count) 段")
                        .foregroundStyle(.secondary)
                    if !isSequential {
                        Button {
                            viewModel.toggleSequential(item)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "list.number")
                                    .font(.system(size: 9))
                                Text("按序粘贴")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                            .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("开启按顺序逐段粘贴（开启后直接按 ⌘V 或点卡片依次粘贴下一段）")
                    }
                }
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isFlashing
                      ? Color.green.opacity(0.22)
                      : (isSequential
                         ? Color.accentColor.opacity(hovering ? 0.16 : 0.10)
                         : (hovering ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSequential ? Color.accentColor.opacity(0.65) : Color.clear, lineWidth: 1.5)
        )
        .overlay(alignment: .topTrailing) {
            if item.pinned && !isSequential {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .padding(6)
            }
        }
        .overlay(alignment: .trailing) {
            if hovering && !isSequential {
                HStack(spacing: 4) {
                    if hasMultiParagraphs {
                        actionButton(icon: "list.number", help: "开启按顺序粘贴", action: {
                            viewModel.toggleSequential(item)
                        })
                    }
                    actionButton(icon: "pip.enter", help: "贴到屏幕 (F3)", action: {
                        viewModel.pin(item)
                    })
                    actionButton(icon: "pin", help: item.pinned ? "取消置顶（此条消息）" : "置顶（此条消息）", action: onPin)
                    actionButton(icon: "trash", help: "删除", action: onDelete)
                }
                .padding(.trailing, 8)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { h in
            hovering = h
            if h {
                PreviewController.shared.schedulePreview(for: item)
            } else {
                PreviewController.shared.itemMouseExited()
            }
        }
        .onTapGesture {
            triggerFlash()
            onActivate()
        }
        .contextMenu {
            Button("复制全文") { onCopy() }
            Button("贴到屏幕 (F3)") { viewModel.pin(item) }
            if hasMultiParagraphs {
                Button(isSequential ? "退出按序粘贴模式" : "开启按序粘贴（共 \(item.paragraphs.count) 段）") {
                    viewModel.toggleSequential(item)
                }
                if isSequential {
                    Button("重置进度到第 1 段") {
                        viewModel.resetSequential(item)
                    }
                }
            }
            Button(item.pinned ? "取消置顶" : "置顶") { onPin() }
            Divider()
            Button("删除", role: .destructive) { onDelete() }
        }
    }

    // MARK: - 按序粘贴卡片子视图

    private var sequentialHeader: some View {
        let total = item.paragraphs.count
        return HStack(spacing: 6) {
            HStack(spacing: 3) {
                Image(systemName: "list.number")
                    .font(.system(size: 10))
                Text("按序 \(seqIndex + 1)/\(total)")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor))
            .foregroundStyle(.white)

            Text("直接按 ⌘V 或点卡片依次粘贴")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            HStack(spacing: 3) {
                seqMiniButton(icon: "chevron.left", help: "上一段") {
                    viewModel.stepSequential(item, delta: -1)
                }
                seqMiniButton(icon: "chevron.right", help: "下一段") {
                    viewModel.stepSequential(item, delta: 1)
                }
                seqMiniButton(icon: "arrow.counterclockwise", help: "重置到第 1 段") {
                    viewModel.resetSequential(item)
                }
                seqMiniButton(icon: "xmark", help: "退出按序模式") {
                    viewModel.toggleSequential(item)
                }
            }
        }
    }

    private var sequentialBody: some View {
        let segments = item.paragraphs
        let cur = segments[seqIndex]
        let nextIdx = (seqIndex + 1) % segments.count
        let next = segments[nextIdx]
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("当前：")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text(displayTruncate(cur, 200))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if segments.count >= 2 {
                Text("下一段（\(nextIdx + 1)/\(segments.count)）：\(displayTruncate(next, 100))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func seqMiniButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.85)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func triggerFlash() {
        clickedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            clickedFlash = false
        }
    }
}

/// 图片网格单元：缩略图 + 尺寸/时间；点击按设置分发（复制或粘贴原图）
struct ImageCell: View {
    let item: ClipboardItem
    let onCopy: () -> Void
    let onPreview: () -> Void
    let onSticker: () -> Void
    let onActivate: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var clickedFlash = false

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let path = item.thumbPath, let img = ImageStore.cachedThumb(at: path) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 100)
            Text(item.content)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(clickedFlash
                  ? Color.green.opacity(0.22)
                  : (hovering ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))))
        .overlay(alignment: .topLeading) {
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .padding(5)
            }
        }
        .overlay(alignment: .topTrailing) {
            if hovering {
                actionButton(icon: "pip.enter", help: "贴到屏幕 (F3)", action: onSticker)
                    .padding(5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { h in
            hovering = h
            if h {
                PreviewController.shared.schedulePreview(for: item)
            } else {
                PreviewController.shared.itemMouseExited()
            }
        }
        .onTapGesture {
            clickedFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                clickedFlash = false
            }
            onActivate()
        }
        .contextMenu {
            Button("复制") { onCopy() }
            Button("贴到屏幕 (F3)") { onSticker() }
            Button("预览") { onPreview() }
            Button(item.pinned ? "取消置顶" : "置顶") { onPin() }
            Divider()
            Button("删除", role: .destructive) { onDelete() }
        }
    }
}

/// 条目上的小圆钮（多文件共用）
@ViewBuilder
func actionButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: icon)
            .font(.system(size: 10))
            .frame(width: 20, height: 20)
    }
    .buttonStyle(.plain)
    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
    .help(help)
}

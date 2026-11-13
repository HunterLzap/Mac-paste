import SwiftUI

/// 表格条目卡片：折叠显示尺寸与预览，点击展开交互网格
struct TableCardView: View {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel
    @State private var expanded = false
    @State private var hovering = false
    @State private var rows: [[String]] = []
    @State private var colWidths: [CGFloat] = []
    @State private var selAnchor: (r: Int, c: Int)?
    @State private var selRows: ClosedRange<Int>?
    @State private var selCols: ClosedRange<Int>?
    @State private var flash: String?

    private let headerH: CGFloat = 22
    private let cellH: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded {
                toolbar
                grid
                if rows.count > TableParser.maxRenderRows || displayCols > TableParser.maxRenderCols {
                    Text("表格过大，仅预览前 \(min(rows.count, TableParser.maxRenderRows)) 行 × \(min(displayCols, TableParser.maxRenderCols)) 列")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                preview
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius)
                .fill(hovering && !expanded ? AppTheme.cardHoverBackground : AppTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius)
                .strokeBorder(hovering && !expanded ? AppTheme.accent.opacity(0.30) : AppTheme.hairlineBorder, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(hovering ? 0.06 : 0.03), radius: hovering ? 4 : 2, y: 1)
        .overlay(alignment: .topTrailing) {
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(AppTheme.pinOrange)
                    .padding(7)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius))
        .onHover { h in
            withAnimation(.easeOut(duration: 0.14)) {
                hovering = h
            }
            if h && !expanded {
                PreviewController.shared.schedulePreview(for: item)
            } else if !h {
                PreviewController.shared.itemMouseExited()
            }
        }
        .onTapGesture { withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) { expanded.toggle() } }
        .contextMenu {
            Button("复制整表") { viewModel.copy(item) }
            Button("粘贴整表") { viewModel.paste(item) }
            Button("贴到屏幕 (F3)") { viewModel.pin(item) }
            Button(item.pinned ? "取消置顶" : "置顶") { viewModel.togglePin(item) }
            Divider()
            Button("删除", role: .destructive) { onDeleteItem() }
        }
        .onAppear {
            rows = viewModel.grid(for: item)
            colWidths = Self.computeColWidths(rows)
        }
    }

    private func onDeleteItem() {
        viewModel.delete(item)
    }

    private var rowCount: Int { rows.count }
    private var displayCols: Int { rows.first?.count ?? 0 }
    private var renderRows: Int { min(rows.count, TableParser.maxRenderRows) }
    private var renderCols: Int { min(displayCols, TableParser.maxRenderCols) }

    // MARK: - 头部与预览

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "tablecells")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("\(rowCount) 行 × \(displayCols) 列")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Text(relativeTimeShort(item.createdAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<min(2, rows.count), id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<min(6, displayCols), id: \.self) { c in
                        Text(cell(r, c))
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                            .frame(width: 74, height: 21, alignment: .leading)
                            .padding(.horizontal, 4)
                            .background(r == 0 ? AppTheme.cardSubtleBackground : AppTheme.cardBackground)
                    }
                }
                .overlay(Rectangle().stroke(AppTheme.hairlineBorder, lineWidth: 0.5))
            }
            if displayCols > 6 || rowCount > 2 {
                Text(displayCols > 6 ? "… 共 \(displayCols) 列" : "… 共 \(rowCount) 行")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            if let sr = selRows, let sc = selCols {
                let rCount = sr.upperBound - sr.lowerBound + 1
                let cCount = sc.upperBound - sc.lowerBound + 1
                Text("已选 \(rCount)×\(cCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("复制所选区域") {
                    viewModel.copyRegion(item, rows: sr, cols: sc)
                    flash = "region"
                    Task { try? await Task.sleep(nanoseconds: 500_000_000); if flash == "region" { flash = nil } }
                }
                .font(.caption2)
                .foregroundStyle(AppTheme.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .buttonStyle(.tactile(cornerRadius: 4, hoverFill: AppTheme.accentSoft))
                Button("清除选择") {
                    selRows = nil; selCols = nil; selAnchor = nil
                }
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .buttonStyle(.tactile(cornerRadius: 4))
            } else {
                Text("双击单元格复制 · 单击选中 · Shift+点击选区域 · 点行号/列标复制整行/列")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    // MARK: - 交互网格

    private var grid: some View {
        VStack(spacing: 0) {
            // 列标行
            HStack(spacing: 0) {
                Color.clear.frame(width: 26, height: headerH)
                ForEach(0..<renderCols, id: \.self) { c in
                    headerButton(text: TableParser.columnLetter(c)) {
                        viewModel.copyColumn(item, col: c)
                        flash = "col:\(c)"
                        Task { try? await Task.sleep(nanoseconds: 500_000_000); if flash == "col:\(c)" { flash = nil } }
                    }
                }
            }
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<renderRows, id: \.self) { r in
                        HStack(spacing: 0) {
                            headerButton(text: "\(r + 1)") {
                                viewModel.copyRow(item, row: r)
                                flash = "row:\(r)"
                                Task { try? await Task.sleep(nanoseconds: 500_000_000); if flash == "row:\(r)" { flash = nil } }
                            }
                            ForEach(0..<renderCols, id: \.self) { c in
                                cellView(r, c)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
            .overlay(Rectangle().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func headerButton(text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: headerH)
                .background(Color.primary.opacity(0.06))
                .contentShape(Rectangle())
        }
        .buttonStyle(.tactile(cornerRadius: 3, hoverFill: AppTheme.accentSoft, pressedScale: 0.92))
    }

    private func cellView(_ r: Int, _ c: Int) -> some View {
        let selected = selRows?.contains(r) == true && selCols?.contains(c) == true
        let isFlash = flash == "\(r):\(c)"
        return Text(cell(r, c).isEmpty ? " " : cell(r, c))
            .font(.system(size: 11))
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(width: colWidth(c), height: cellH, alignment: .leading)
            .background(
                isFlash ? Color.green.opacity(0.35)
                : selected ? Color.accentColor.opacity(0.28)
                : (r % 2 == 0 ? Color.primary.opacity(0.03) : Color.clear)
            )
            .overlay(Rectangle().stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                // 双击快速复制
                selAnchor = (r, c)
                selRows = r...r
                selCols = c...c
                viewModel.copyCell(item, row: r, col: c)
                flash = "\(r):\(c)"
                Task { try? await Task.sleep(nanoseconds: 400_000_000); if flash == "\(r):\(c)" { flash = nil } }
            }
            .onTapGesture {
                // 单击只选中；Shift+单击扩展区域
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if shift {
                    let anchor = selAnchor ?? (selRows.map { (r: $0.lowerBound, c: selCols?.lowerBound ?? c) } ?? (r, c))
                    selRows = min(anchor.r, r)...max(anchor.r, r)
                    selCols = min(anchor.c, c)...max(anchor.c, c)
                } else {
                    selAnchor = (r, c)
                    selRows = r...r
                    selCols = c...c
                }
            }
            .contextMenu {
                Button("复制该单元格内容") { viewModel.copyCell(item, row: r, col: c) }
                Button("复制该行") { viewModel.copyRow(item, row: r) }
                Button("复制该列") { viewModel.copyColumn(item, col: c) }
            }
    }

    private func cell(_ r: Int, _ c: Int) -> String {
        guard r < rows.count, c < rows[r].count else { return "" }
        return rows[r][c]
    }

    private func colWidth(_ c: Int) -> CGFloat {
        guard c < colWidths.count else { return 72 }
        return colWidths[c]
    }

    /// 按内容长度估算列宽（仅统计预览范围内的行）
    private static func computeColWidths(_ rows: [[String]]) -> [CGFloat] {
        let cols = rows.first?.count ?? 0
        guard cols > 0 else { return [] }
        var widths = [CGFloat](repeating: 0, count: cols)
        for row in rows.prefix(TableParser.maxRenderRows) {
            for (c, cell) in row.enumerated() where c < cols {
                widths[c] = max(widths[c], CGFloat(min(cell.count, 40)))
            }
        }
        return widths.map { min(max($0 * 6 + 20, 56), 180) }
    }
}

import SwiftUI

/// 历史列表：文本页为列表，图片页为 3 列网格
struct HistoryListView: View {
    @ObservedObject var viewModel: ClipboardViewModel

    var body: some View {
        if viewModel.items.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: viewModel.searchText.isEmpty ? "tray" : "magnifyingglass")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(AppTheme.textTertiary)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.white.opacity(0.85)))
                    .overlay(Circle().strokeBorder(AppTheme.hairlineBorder, lineWidth: 1))
                Text(viewModel.searchText.isEmpty
                     ? "暂无历史记录\n复制的内容会自动出现在这里"
                     : "没有匹配的结果")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.tab == .table {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.items) { item in
                        TableCardView(item: item, viewModel: viewModel)
                    }
                }
                .padding(12)
            }
        } else if viewModel.tab == .image {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)],
                          spacing: 8) {
                    ForEach(viewModel.items) { item in
                        ImageCell(item: item,
                                  onCopy: { viewModel.copy(item) },
                                  onPreview: {
                                      if let p = item.dataPath {
                                          QuickLookController.shared.show(url: URL(fileURLWithPath: p))
                                      }
                                  },
                                  onSticker: { viewModel.pin(item) },
                                  onActivate: { viewModel.activate(item) },
                                  onPin: { viewModel.togglePin(item) },
                                  onDelete: { viewModel.delete(item) })
                    }
                }
                .padding(12)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(viewModel.items) { item in
                        ItemRowView(item: item,
                                    viewModel: viewModel,
                                    onCopy: { viewModel.copy(item) },
                                    onActivate: { viewModel.activate(item) },
                                    onPin: { viewModel.togglePin(item) },
                                    onDelete: { viewModel.delete(item) })
                    }
                }
                .padding(12)
            }
        }
    }
}

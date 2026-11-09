import AppKit
import SwiftUI

/// 独立主窗口内容：一体化头部 + 分类标签 + 列表 + 底部栏
struct ContentView: View {
    @ObservedObject var viewModel: ClipboardViewModel
    var onHide: () -> Void
    @State private var searchExpanded = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.accessibilityDenied {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text("粘贴需要辅助功能权限")
                        .font(.caption)
                    Spacer()
                    Button("重新检测") {
                        viewModel.accessibilityDenied = !AccessibilityPermission.isTrusted
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    Button("打开设置") {
                        NSWorkspace.shared.open(AccessibilityPermission.settingsURL)
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.12))
                .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                    // 授权完成后提示条自动消失
                    if viewModel.accessibilityDenied && AccessibilityPermission.isTrusted {
                        viewModel.accessibilityDenied = false
                    }
                }
            }

            header

            Picker("分类", selection: $viewModel.tab) {
                ForEach(ClipboardKind.allCases, id: \.self) { kind in
                    Text(kind.tabTitle).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()

            HistoryListView(viewModel: viewModel)

            Divider()

            HStack {
                Text("共 \(viewModel.totalCount) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清空历史") {
                    viewModel.showClearConfirm = true
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.85))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(minWidth: PanelController.minSize.width,
               maxWidth: .infinity,
               minHeight: PanelController.minSize.height,
               maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            searchFocused = true
            viewModel.reload()
        }
        .onExitCommand {
            if searchExpanded {
                toggleSearch()
            } else {
                onHide()
            }
        }
        .confirmationDialog("确定清空所有历史记录？",
                            isPresented: $viewModel.showClearConfirm,
                            titleVisibility: .visible) {
            Button("清空", role: .destructive) { viewModel.clearAll() }
        } message: {
            Text("此操作不可撤销")
        }
    }

    // MARK: - 一体化头部

    /// 单行头部：右对齐 [搜索按钮] [置顶] [设置]；点搜索按钮后搜索框向左滑出。
    /// 左侧为悬浮红绿灯留出空间（标题栏已一体化）。
    private var header: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 62, height: 1)
            Spacer(minLength: 0)
            if searchExpanded {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("搜索历史…", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($searchFocused)
                    if !viewModel.searchText.isEmpty {
                        Button {
                            viewModel.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .frame(maxWidth: searchExpanded ? 170 : 0)
                .clipped()
                .transition(.opacity)
            }
            headerButton(icon: "magnifyingglass", active: searchExpanded, help: "搜索") {
                toggleSearch()
            }
            headerButton(icon: "camera.viewfinder", active: false, help: "区域截图 (F1)") {
                viewModel.onStartSnip?()
            }
            headerButton(icon: "pip.enter", active: false, help: "将当前剪贴板贴到屏幕 (F3)") {
                viewModel.pinCurrentOrLatest()
            }
            headerButton(icon: viewModel.alwaysOnTop ? "pin.fill" : "pin",
                         active: viewModel.alwaysOnTop,
                         activeTint: .orange,
                         help: viewModel.alwaysOnTop ? "取消窗口置顶" : "窗口置顶（窗口保持最前）") {
                viewModel.alwaysOnTop.toggle()
            }
            headerButton(icon: "gearshape", active: false, help: "设置") {
                viewModel.settingsOpenRequest = true
            }
            .popover(isPresented: Binding(
                get: { viewModel.settingsOpenRequest },
                set: { viewModel.settingsOpenRequest = $0 }
            ), arrowEdge: .bottom) {
                SettingsView(viewModel: viewModel)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: searchExpanded)
    }

    private func toggleSearch() {
        if searchExpanded {
            searchExpanded = false
            searchFocused = false
            viewModel.searchText = ""
        } else {
            searchExpanded = true
            viewModel.onFocusWindowForKeyboard?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
        }
    }

    private func headerButton(icon: String, active: Bool, activeTint: Color = .accentColor, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(active ? activeTint : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 窗口边缘拖拽缩放手柄（预览窗的自定义缩放实现）
struct ResizeHandleView: View {
    enum Edge { case bottom, right, corner }
    let edge: Edge
    let onResizeStart: () -> CGSize
    let onResize: (CGSize, CGSize) -> Void
    @State private var startSize: CGSize?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: edge == .bottom ? nil : (edge == .corner ? 14 : 6),
                   height: edge == .right ? nil : (edge == .corner ? 14 : 6))
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    if startSize == nil { startSize = onResizeStart() }
                    if let s = startSize { onResize(s, v.translation) }
                }
                .onEnded { _ in startSize = nil })
            .onHover { h in
                guard h else { NSCursor.pop(); return }
                switch edge {
                case .bottom: NSCursor.resizeUpDown.push()
                case .right: NSCursor.resizeLeftRight.push()
                case .corner: NSCursor.crosshair.push()
                }
            }
    }
}

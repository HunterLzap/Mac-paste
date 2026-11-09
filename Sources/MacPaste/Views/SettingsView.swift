import AppKit
import SwiftUI
import ServiceManagement

/// 设置弹层：开机自启、历史上限、退出
struct SettingsView: View {
    @ObservedObject var viewModel: ClipboardViewModel
    @State private var launchEnabled: Bool = LaunchAtLogin.isEnabled
    @State private var launchFailed = false
    @State private var limit: Int = UserDefaults.standard.object(forKey: "historyLimit") as? Int ?? 500

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置")
                .font(.headline)

            Toggle("开机自动启动", isOn: Binding(
                get: { launchEnabled },
                set: { newValue in
                    do {
                        try LaunchAtLogin.setEnabled(newValue)
                        launchEnabled = newValue
                        launchFailed = false
                    } catch {
                        launchFailed = true
                        launchEnabled = false
                    }
                }
            ))

            VStack(alignment: .leading, spacing: 6) {
                Text("点击条目时")
                    .font(.subheadline)
                Picker("", selection: Binding(
                    get: { viewModel.clickAction },
                    set: { viewModel.clickAction = $0 }
                )) {
                    Text("复制").tag(ClickAction.copy)
                    Text("粘贴").tag(ClickAction.paste)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if viewModel.clickAction == .paste && !AccessibilityPermission.isTrusted {
                Text("粘贴需要辅助功能权限：请在系统设置中允许 MacPaste")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Button("去授权") {
                    NSWorkspace.shared.open(AccessibilityPermission.settingsURL)
                }
                .font(.caption2)
            }

            Toggle("清空历史时同时清除置顶内容", isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: "clearIncludesPinned") },
                set: { UserDefaults.standard.set($0, forKey: "clearIncludesPinned") }
            ))
            .toggleStyle(.switch)

            Stepper(value: Binding(
                get: { limit },
                set: { newValue in
                    limit = newValue
                    viewModel.historyLimit = newValue
                }
            ), in: 100...5000, step: 100) {
                Text("历史条数上限：\(limit)")
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("快捷键说明（与 Snipaste 一致）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("• F1：区域截图到剪贴板（空格可截窗口）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("• F3：将当前剪贴板的文字/图片/表格贴到屏幕")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("• Shift+F3：隐藏 / 显示全部屏幕贴图")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("• 贴图操作：⌘+滚轮调透明度 · 滚轮/拖拽缩放 · 双击顶栏折叠 · Esc关闭")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("• ⌥V：打开 / 前置主窗口")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("• 开启卡片「按序粘贴」后：直接按 ⌘V 即可逐段按顺序粘贴")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if launchFailed {
                Text("设置失败：请先把 MacPaste.app 安装到「应用程序」文件夹后再开启")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if !LaunchAtLogin.isAppBundled {
                Text("提示：当前为开发模式运行（非 .app），自启与热键体验以打包后的 app 为准")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("打开独立窗口") {
                viewModel.onOpenMainWindow?()
            }
            Button("退出 MacPaste") {
                NSApp.terminate(nil)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 300)
    }
}

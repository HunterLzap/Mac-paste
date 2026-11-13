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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("偏好设置")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text("MacPaste")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textTertiary)
            }

            // 分组卡片 1：常规与粘贴行为
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("开机自动启动")
                        .font(.system(size: 12.5))
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Toggle("", isOn: Binding(
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
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                .padding(.vertical, 8)

                Divider().overlay(AppTheme.hairlineBorder)

                HStack {
                    Text("点击条目时")
                        .font(.system(size: 12.5))
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { viewModel.clickAction },
                        set: { viewModel.clickAction = $0 }
                    )) {
                        Text("复制").tag(ClickAction.copy)
                        Text("粘贴").tag(ClickAction.paste)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 110)
                }
                .padding(.vertical, 8)

                if viewModel.clickAction == .paste && !AccessibilityPermission.isTrusted {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        Text("自动粘贴需要辅助功能权限")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("去授权") {
                            NSWorkspace.shared.open(AccessibilityPermission.settingsURL)
                        }
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(AppTheme.accent)
                    }
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.10)))
                    .padding(.bottom, 6)
                }

                Divider().overlay(AppTheme.hairlineBorder)

                HStack {
                    Text("清空历史时清除置顶")
                        .font(.system(size: 12.5))
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "clearIncludesPinned") },
                        set: { UserDefaults.standard.set($0, forKey: "clearIncludesPinned") }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                .padding(.vertical, 8)

                Divider().overlay(AppTheme.hairlineBorder)

                HStack {
                    Text("历史条数上限")
                        .font(.system(size: 12.5))
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer()
                    Stepper(value: Binding(
                        get: { limit },
                        set: { newValue in
                            limit = newValue
                            viewModel.historyLimit = newValue
                        }
                    ), in: 100...5000, step: 100) {
                        Text("\(limit)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius).fill(AppTheme.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius).strokeBorder(AppTheme.hairlineBorder, lineWidth: 1))

            // 分组卡片 2：全局快捷键（Keycap 徽章）
            VStack(alignment: .leading, spacing: 6) {
                Text("全局快捷键（与 Snipaste 一致）")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)

                shortcutRow("区域截图（空格切窗口）", keys: ["F1"])
                shortcutRow("贴到屏幕（文字 / 图 / 表）", keys: ["F3"])
                shortcutRow("隐藏 / 显示全部贴图", keys: ["⇧", "F3"])
                shortcutRow("打开 / 前置主窗口", keys: ["⌥", "V"])
                shortcutRow("贴图缩放 / 调透明度", keys: ["⌥ 滚轮", "⌘ 滚轮"])
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius).fill(AppTheme.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius).strokeBorder(AppTheme.hairlineBorder, lineWidth: 1))

            if launchFailed {
                Text("设置失败：请先把 MacPaste.app 安装到「应用程序」文件夹后再开启")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if !LaunchAtLogin.isAppBundled {
                Text("提示：当前为开发模式运行（非 .app），自启与热键体验以打包后的 app 为准")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            HStack(spacing: 8) {
                Button {
                    viewModel.onOpenMainWindow?()
                } label: {
                    Text("打开独立窗口")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.cardBackground))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppTheme.strongBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text("退出 MacPaste")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.dangerRed)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.dangerRed.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppTheme.dangerRed.opacity(0.22), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 316)
        .background(AppTheme.panelBackground)
        .environment(\.colorScheme, .light)
    }

    private func shortcutRow(_ label: String, keys: [String]) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer(minLength: 6)
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { k in
                    Text(k)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppTheme.textPrimary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(AppTheme.cardSubtleBackground))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(AppTheme.strongBorder, lineWidth: 0.8))
                }
            }
        }
    }
}

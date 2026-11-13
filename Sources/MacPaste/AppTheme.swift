import AppKit
import SwiftUI

/// MacPaste 全局浅色设计系统（Frosted Paper & Crisp Ink）
/// 供 SwiftUI 窗口（主剪贴板、设置、预览、活贴图）与 AppKit 浮层共享同一套浅色视觉语义 Token
enum AppTheme {
    // MARK: - SwiftUI Colors

    /// 面板/窗口浅灰底色 (#F7F8FB)
    static let panelBackground = Color(red: 0.969, green: 0.973, blue: 0.984)
    /// 纯净白浮层/卡片底色 (#FFFFFF)
    static let cardBackground = Color.white
    /// 卡片悬停微蓝白底 (#FAFCFF)
    static let cardHoverBackground = Color(red: 0.980, green: 0.988, blue: 1.000)
    /// 次级浅灰容器底色 (#F3F5F9)
    static let cardSubtleBackground = Color(red: 0.953, green: 0.961, blue: 0.976)
    /// 选中/按序高亮卡片底色 (#F5F9FF)
    static let selectedCardBackground = Color(red: 0.961, green: 0.976, blue: 1.000)

    /// 极细分割线与卡片描边
    static let hairlineBorder = Color.black.opacity(0.085)
    static let strongBorder = Color.black.opacity(0.14)

    /// 品牌强调色（与系统蓝对齐 #007AFF）
    static let accent = Color(red: 0.00, green: 0.48, blue: 1.00)
    static let accentSoft = Color(red: 0.00, green: 0.48, blue: 1.00).opacity(0.12)
    static let pinOrange = Color(red: 1.00, green: 0.58, blue: 0.00)
    static let successGreen = Color(red: 0.16, green: 0.80, blue: 0.25)
    static let dangerRed = Color(red: 1.00, green: 0.23, blue: 0.19)

    /// 文本层级
    static let textPrimary = Color(red: 0.094, green: 0.110, blue: 0.141)
    static let textSecondary = Color(red: 0.369, green: 0.400, blue: 0.471)
    static let textTertiary = Color(red: 0.553, green: 0.584, blue: 0.647)

    // MARK: - AppKit NSColors

    static let nsPanelBackground = NSColor(calibratedRed: 0.969, green: 0.973, blue: 0.984, alpha: 1.0)
    static let nsCardBackground = NSColor.white
    static let nsTextPrimary = NSColor(calibratedRed: 0.094, green: 0.110, blue: 0.141, alpha: 1.0)
    static let nsTextSecondary = NSColor(calibratedRed: 0.369, green: 0.400, blue: 0.471, alpha: 1.0)
    static let nsAccent = NSColor(calibratedRed: 0.00, green: 0.48, blue: 1.00, alpha: 1.0)

    // MARK: - Metrics

    static let cardCornerRadius: CGFloat = 10
    static let panelCornerRadius: CGFloat = 12
}

// MARK: - 统一微交互按钮样式（悬停高亮底色 + 按压弹性微缩）

struct TactileButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6
    var hoverFill: Color = Color.black.opacity(0.065)
    var pressedScale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        TactileButtonBody(
            configuration: configuration,
            cornerRadius: cornerRadius,
            hoverFill: hoverFill,
            pressedScale: pressedScale
        )
    }

    private struct TactileButtonBody: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        let hoverFill: Color
        let pressedScale: CGFloat
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(backgroundColor)
                )
                .scaleEffect(configuration.isPressed ? pressedScale : 1.0)
                .opacity(configuration.isPressed ? 0.84 : 1.0)
                .animation(.spring(response: 0.16, dampingFraction: 0.78), value: isHovered)
                .animation(.spring(response: 0.12, dampingFraction: 0.75), value: configuration.isPressed)
                .onHover { hovering in
                    isHovered = hovering
                }
        }

        private var backgroundColor: Color {
            if configuration.isPressed {
                return hoverFill.opacity(1.45)
            }
            return isHovered ? hoverFill : .clear
        }
    }
}

extension ButtonStyle where Self == TactileButtonStyle {
    static func tactile(
        cornerRadius: CGFloat = 6,
        hoverFill: Color = Color.black.opacity(0.065),
        pressedScale: CGFloat = 0.94
    ) -> TactileButtonStyle {
        TactileButtonStyle(cornerRadius: cornerRadius, hoverFill: hoverFill, pressedScale: pressedScale)
    }
}

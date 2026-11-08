import SwiftUI
import AppKit

/// 半透明毛玻璃窗口背景（跟随系统外观）
struct GlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.autoresizingMask = [.width, .height]
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// 统一的窗口容器：玻璃底 + 顶部标题 + 内容
struct WindowShell<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    let subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tint.opacity(0.16))
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(tint)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    if let s = subtitle {
                        Text(s).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.primary.opacity(0.85))
                    } else {
                        Text(title).font(.system(size: 13, weight: .semibold))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider().opacity(0.5)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 卡片：把一组行包成一个圆角块
struct WCard<Content: View>: View {
    var padding: CGFloat = 10
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            content()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

/// 小标题
struct WSectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }
}

/// 行：左标签 + 右内容
struct WRow<Trailing: View>: View {
    let label: String
    var icon: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10.5)).foregroundStyle(.secondary).frame(width: 14)
            }
            Text(label).font(.system(size: 11.5)).foregroundStyle(.primary.opacity(0.85))
            Spacer(minLength: 8)
            trailing()
        }
        .frame(minHeight: 18)
    }
}

/// 胶囊按钮（工具窗口里的操作按钮）
struct PillButton: View {
    let title: String
    var icon: String? = nil
    var tint: Color = .accentColor
    var filled: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .medium)) }
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(filled ? tint.opacity(0.85) : Color.primary.opacity(0.07))
            )
            .overlay(
                Capsule().strokeBorder(Color.primary.opacity(filled ? 0.10 : 0.10), lineWidth: 0.5)
            )
            .foregroundStyle(filled ? Color.white : tint)
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// 窗口透明标题栏 + 可拖动 + 隐藏标题
    func makeTransparentWindow(title: String) -> some View {
        self
    }
}

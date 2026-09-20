import Localization
import SwiftUI

// MARK: - 液态玻璃

/// macOS 26 起，侧边栏、顶栏控件、按钮与切换控件用系统的液态玻璃；更早的系统退回原来的实色样式。
/// 玻璃只给浮在内容之上的导航与控件用，卡片、设置分组这类内容本身保持实色（与系统设置一致）。
extension EnvironmentValues {
    /// 已经在一块玻璃里面（比如侧边栏面板）：里面的控件不再叠一层玻璃，改用普通的悬停底色
    @Entry var isInsideGlass = false
}

extension DS {
    enum Glass {
        /// 当前系统是否支持液态玻璃
        static var isAvailable: Bool {
            if #available(macOS 26.0, *) { true } else { false }
        }
    }
}

extension View {
    /// 给控件加一层液态玻璃。`tint` 为品牌色时是蓝色玻璃（主按钮、选中项）；
    /// `interactive` 为真时按下会有玻璃的形变反馈。不支持玻璃的系统上、以及离屏截图时（拍不出玻璃）画 `fallback` 实色
    func dsGlass<S: InsettableShape>(in shape: S, tint: Color? = nil, interactive: Bool = false,
                                     fallback: Color = DS.Palette.elevated) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive, fallback: fallback))
    }
}

private struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    let fallback: Color
    @Environment(\.isSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !isSnapshot {
            content.glassEffect(DS.Glass.style(tint: tint, interactive: interactive), in: shape)
        } else {
            content.background(tint ?? fallback, in: shape)
        }
    }
}

@available(macOS 26.0, *)
extension DS.Glass {
    static func style(tint: Color?, interactive: Bool) -> SwiftUI.Glass {
        var glass = SwiftUI.Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

// MARK: - 全局加载

/// 需要等待、期间不宜继续操作的任务（清理、卸载、导出诊断、修改 DNS）：
/// 整个窗口压暗，中间浮一块玻璃加载框，写明正在做什么；任务结束自动消失
struct LoadingHUD: View {
    let message: String

    var body: some View {
        ZStack {
            // 压暗并拦住点击，避免任务进行中又触发别的操作
            Rectangle()
                .fill(DS.Palette.scrim)
                .contentShape(Rectangle())
                .onTapGesture {}

            HStack(spacing: DS.Space.s3) {
                ProgressView().controlSize(.regular)
                Text(verbatim: message)
                    .dsFont(.base, weight: .medium)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DS.Space.s8)
            .padding(.vertical, DS.Space.s6)
            .frame(minWidth: DS.Size.sidebarWidth + DS.Space.s16)
            .modifier(HUDBackground())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        }
        .transition(.opacity)
    }
}

private struct HUDBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
        } else {
            content
                .background(DS.Palette.elevated, in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
                .dsShadow(DS.Shadow.level2)
        }
    }
}

extension View {
    /// 有文字时在上方盖一层全局加载框
    func loadingHUD(_ message: String?) -> some View {
        overlay {
            if let message { LoadingHUD(message: message) }
        }
        .animation(DS.Motion.quick, value: message)
    }
}

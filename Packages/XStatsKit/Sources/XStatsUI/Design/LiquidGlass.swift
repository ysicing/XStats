import Cleaner
import Localization
import Metrics
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

enum CleanerHUDStage {
    case cleaning, stopping, verifying, skippingVerification

    var message: String {
        switch self {
        case .cleaning: tr("正在清理…")
        case .stopping: tr("正在停止清理…")
        case .verifying: tr("正在核对剩余项目…")
        case .skippingVerification: tr("正在跳过核对…")
        }
    }

    var isVerifying: Bool { self == .verifying || self == .skippingVerification }
    var isStopping: Bool { self == .stopping || self == .skippingVerification }
}

/// 需要等待、期间不宜继续操作的任务（清理、卸载、导出诊断、修改 DNS）：
/// 整个窗口压暗，中间浮一块玻璃加载框，写明正在做什么；任务结束自动消失
struct LoadingHUD: View {
    let message: String
    let progress: CleanProgress?
    let cleanerStage: CleanerHUDStage?
    let onCancel: (() -> Void)?

    var body: some View {
        ZStack {
            // 压暗并拦住背景点击；可取消任务在加载框内提供操作。
            Rectangle()
                .fill(DS.Palette.scrim)
                .contentShape(Rectangle())
                .onTapGesture {}

            VStack(alignment: .leading, spacing: DS.Space.s3) {
                HStack(spacing: DS.Space.s3) {
                    ProgressView().controlSize(.regular)
                    Text(verbatim: message)
                        .dsFont(.base, weight: .medium)
                        .foregroundStyle(DS.Palette.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let cleanerStage {
                    cleanerDetails(cleanerStage)
                    HStack {
                        Spacer(minLength: 0)
                        Button(cleanerStage.isVerifying ? tr("跳过核对") : tr("停止清理")) { onCancel?() }
                            .buttonStyle(DSButtonStyle(kind: .secondary))
                            .disabled(cleanerStage.isStopping || onCancel == nil)
                    }
                } else if let onCancel {
                    HStack {
                        Spacer(minLength: 0)
                        Button(tr("取消"), action: onCancel)
                            .buttonStyle(DSButtonStyle(kind: .secondary))
                    }
                }
            }
            .padding(.horizontal, DS.Space.s8)
            .padding(.vertical, DS.Space.s6)
            .frame(minWidth: DS.Size.sidebarWidth + DS.Space.s16, maxWidth: 420)
            .modifier(HUDBackground())
            .accessibilityElement(children: cleanerStage == nil && onCancel == nil ? .combine : .contain)
            .accessibilityAddTraits(.updatesFrequently)
        }
        .transition(.opacity)
    }

    private func cleanerDetails(_ stage: CleanerHUDStage) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            if stage.isVerifying {
                Text(tr("清理已结束，正在更新可清理空间"))
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.textSecondary)
            } else if let progress {
                HStack(spacing: DS.Space.s2) {
                    Text(verbatim: progress.currentRule)
                        .dsFont(.sm, weight: .medium)
                        .foregroundStyle(DS.Palette.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if progress.ruleCount > 1 {
                        Text(tr("第 \(progress.ruleNumber)/\(progress.ruleCount) 项"))
                            .dsFont(.xs)
                            .foregroundStyle(DS.Palette.textSecondary)
                            .monospacedDigit()
                    }
                }
                if progress.toolScannedBytes == nil, progress.currentRuleTotal > 1 {
                    ProgressView(value: Double(progress.currentRuleCompleted),
                                 total: Double(progress.currentRuleTotal))
                        .accessibilityLabel(progress.currentRule)
                        .accessibilityValue(tr("已处理 \(progress.currentRuleCompleted)/\(progress.currentRuleTotal) 项"))
                }
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                    Text(verbatim: detail(for: progress))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Text(tr("已运行"))
                    Text(progress.currentRuleStartedAt, style: .timer)
                        .monospacedDigit()
                }
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textSecondary)
            } else {
                Text(tr("正在准备清理…"))
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: DS.Space.s16, alignment: .topLeading)
    }

    private func detail(for progress: CleanProgress) -> String {
        if let bytes = progress.toolScannedBytes {
            return tr("扫描大小约 \(Format.bytes(bytes, base: .decimal))")
        }
        if progress.currentRuleTotal > 1 {
            return tr("已处理 \(progress.currentRuleCompleted)/\(progress.currentRuleTotal) 项")
        }
        return tr("正在处理当前项目")
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
    func loadingHUD(_ message: String?, progress: CleanProgress? = nil, cleanerStage: CleanerHUDStage? = nil,
                    onCancel: (() -> Void)? = nil) -> some View {
        overlay {
            if let message { LoadingHUD(message: message, progress: progress, cleanerStage: cleanerStage, onCancel: onCancel) }
        }
        .animation(DS.Motion.quick, value: message)
    }
}

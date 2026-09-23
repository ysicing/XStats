import Foundation
import Localization
import Metrics
import SwiftUI

/// 用独立身份包装不可比较的闭包，避免 SwiftUI 把无关环境刷新都视为回调变化。
struct PopoverOverflowReporter: Equatable, Sendable {
    private let id = UUID()
    private let action: @MainActor @Sendable (CGFloat) -> Void

    init(_ action: @escaping @MainActor @Sendable (CGFloat) -> Void) {
        self.action = action
    }

    @MainActor
    func callAsFunction(_ overflow: CGFloat) {
        action(overflow)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

/// ImageRenderer 无法渲染 ScrollView 等 AppKit 承载的控件，截图模式下改用平铺布局。
extension EnvironmentValues {
    @Entry var isSnapshot = false
    /// 在主窗口里显示指标详情：显示全部区块，图表更高
    @Entry var isDetailPage = false
    /// 菜单栏弹窗：区块去掉卡片底色，用细分隔线隔开，排得更紧凑
    @Entry var isPopover = false
    /// 菜单栏弹窗：滚动内容的实际高度比可视区域高出（负数为矮出）多少，交给面板调整窗口高度
    @Entry var reportPopoverOverflow: PopoverOverflowReporter?
}

// MARK: - 卡片

struct Card<Content: View>: View {
    var padding: CGFloat = DS.Space.s4
    var spacing: CGFloat = DS.Space.s3
    @ViewBuilder var content: Content
    @Environment(\.isPopover) private var isPopover

    var body: some View {
        if isPopover {
            // 菜单栏弹窗：不画卡片，区块顶上一条细分隔线，上下各留一点空，行距收紧
            VStack(alignment: .leading, spacing: min(spacing, DS.Space.s1 + DS.Space.s1 / 2)) {
                content
            }
            .padding(.vertical, DS.Space.s2)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .overlay(alignment: .top) { HairlineDivider() }
        } else {
            cardBody
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(padding)
        // 在等高行里撑满高度，背景随之延伸
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
    }
}

struct CardHeader<Trailing: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            Image(systemName: icon)
                .font(.system(size: DS.TextSize.sm.rawValue, weight: .medium))
                .foregroundStyle(DS.Palette.textSecondary)
                .frame(width: DS.Size.iconInline, height: DS.Size.iconInline)
            Text(title)
                .dsFont(.sm, weight: .semibold)
                .foregroundStyle(DS.Palette.textPrimary)
            Spacer(minLength: DS.Space.s2)
            trailing
        }
    }
}

extension CardHeader where Trailing == Text {
    init(icon: String, title: String, detail: String) {
        self.icon = icon
        self.title = title
        self.trailing = Text(detail).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
    }
}

struct HairlineDivider: View {
    var body: some View {
        Rectangle().fill(DS.Palette.border).frame(height: DS.Size.stroke)
    }
}

// MARK: - 图例

struct LegendItem: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: DS.Space.s1) {
            Circle().fill(color).frame(width: DS.Size.barHeight, height: DS.Size.barHeight)
            Text(label).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            Text(value).dsFont(.xs, weight: .semibold).monospacedDigit().foregroundStyle(DS.Palette.textPrimary)
        }
        .lineLimit(1)
    }
}

// MARK: - 进度条

struct ProgressTrack: View {
    let fraction: Double
    var color: Color = DS.Palette.primary
    var height: CGFloat = DS.Size.barHeight
    /// 占比类（容量、电量）画灰色底槽；排行类（按应用汇总）只画彩色条，底槽拉满一整行反而显得杂乱
    var showsTrack = true

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                if showsTrack {
                    RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.Palette.track)
                }
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .fill(color)
                    .frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: height)
    }
}

/// 分段条：把一个整体按比例切成几段，每段填自己的颜色，段内写“名称 百分比”，
/// 第一段靠左、最后一段靠右、中间居中；段太窄放不下文字就只画色块，数值由旁边的图例补充
struct SegmentedBar: View {
    struct Segment: Identifiable {
        let id: String
        let label: String
        let fraction: Double
        let color: Color
        var labelColor: Color = DS.Palette.onPrimary
    }

    let segments: [Segment]
    var height: CGFloat = DS.Size.controlHeight

    var body: some View {
        GeometryReader { proxy in
            let total = max(segments.reduce(0) { $0 + max(0, $1.fraction) }, 0.000_001)
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    let width = proxy.size.width * max(0, segment.fraction) / total
                    let percent = Format.percent(segment.fraction / total)
                    ZStack(alignment: index == 0 ? .leading : index == segments.count - 1 ? .trailing : .center) {
                        Rectangle().fill(segment.color)
                        // 放得下就写“名称 百分比”，只放得下数字就只写百分比，再窄就只画色块
                        ViewThatFits(in: .horizontal) {
                            Text(verbatim: "\(segment.label) \(percent)")
                            Text(verbatim: percent)
                            Color.clear.frame(width: 0, height: 0)
                        }
                        .dsFont(.xs, weight: .semibold)
                        .foregroundStyle(segment.labelColor)
                        .monospacedDigit()
                        .lineLimit(1)
                        .padding(.horizontal, DS.Space.s2)
                    }
                    .frame(width: width)
                    .clipped()
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
    }
}

/// 带图标的徽章（cleanip.io 样式）：浅色底、细边框、同色系文字，用于“原生 IP”“住宅 IP”“ISP”这类结论性标签
struct TagBadge: View {
    enum Tone { case success, warning, neutral, primary }

    var icon: String?
    let text: String
    var tone: Tone = .success
    /// 放在区块标题行里的小号：更窄的内边距
    var compact = false

    var body: some View {
        HStack(spacing: DS.Space.s1) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: DS.TextSize.sm.rawValue, weight: .semibold))
                    .frame(width: DS.Size.iconInline, height: DS.Size.iconInline)
            }
            Text(text).dsFont(.xs, weight: .semibold)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, compact ? DS.Space.s1 : DS.Space.s3)
        .padding(.vertical, compact ? DS.Space.s1 / 2 : DS.Space.s1)
        .background(fill, in: RoundedRectangle(cornerRadius: compact ? DS.Radius.sm : DS.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: compact ? DS.Radius.sm : DS.Radius.md).strokeBorder(border, lineWidth: DS.Size.stroke))
        .lineLimit(1)
        .fixedSize()
    }

    private var foreground: Color {
        switch tone {
        case .success: DS.Badge.successText
        case .warning: DS.Badge.warningText
        case .neutral: DS.Badge.neutralText
        case .primary: DS.Palette.primary
        }
    }

    private var fill: Color {
        switch tone {
        case .success: DS.Badge.successFill
        case .warning: DS.Badge.warningFill
        case .neutral: DS.Badge.neutralFill
        case .primary: DS.Palette.primary.opacity(0.10)
        }
    }

    private var border: Color {
        switch tone {
        case .success: DS.Badge.successBorder
        case .warning: DS.Badge.warningBorder
        case .neutral: DS.Badge.neutralBorder
        case .primary: DS.Palette.primary.opacity(0.30)
        }
    }
}

/// cleanip.io 的字标：黑色部分按文字色着色（随深浅色变化），圆环与 “.io” 保持品牌绿。
/// 画布已裁到字形边缘，指定的高度就是字形实际高度，不留上下空白
struct CleanIPLogo: View {
    var height: CGFloat = DS.Size.iconInline

    var body: some View {
        // 字标画布已裁到字形边缘：600 × 98
        let width = height * 600 / 98
        ZStack {
            if let ink = LogoCache.shared.image(named: "cleanip-ink", template: true) {
                Image(nsImage: ink).resizable().foregroundStyle(DS.Palette.textPrimary)
            }
            if let green = LogoCache.shared.image(named: "cleanip-green", template: false) {
                Image(nsImage: green).resizable()
            }
        }
        .frame(width: width, height: height)
        // 字母落在画布 y = 78 处（下面是 p 的下伸部分）：与文字按基线对齐时对齐这条线，字标才和文字在同一水平线上
        .alignmentGuide(.firstTextBaseline) { $0.height * 78 / 98 }
        .alignmentGuide(.lastTextBaseline) { $0.height * 78 / 98 }
        .accessibilityLabel("cleanip.io")
    }
}

/// 可点击的 cleanip.io 字标：点了打开链接，悬停时略微变淡
struct CleanIPLink: View {
    static let site = URL(string: "https://cleanip.io")!
    var height: CGFloat = DS.Size.iconInline
    var url = CleanIPLink.site
    var help = "cleanip.io"
    @State private var hovering = false

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            CleanIPLogo(height: height)
                .opacity(hovering ? 0.7 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.Motion.quick, value: hovering)
        .help(help)
    }
}

/// 胶囊切换：底槽是一条灰色胶囊，选中项是一颗蓝色胶囊滑过去，文字随之变白
struct PillSwitch<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .dsFont(.xs, weight: .semibold)
                        .foregroundStyle(selected ? DS.Palette.onPrimary : DS.Palette.textSecondary)
                        .padding(.horizontal, DS.Space.s2)
                        .frame(height: DS.Size.segmentHeight - DS.Space.s1)
                        .background {
                            if selected {
                                Capsule().fill(DS.Palette.primary)
                                    .matchedGeometryEffect(id: "pill", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DS.Space.s1 / 2)
        .background(DS.Palette.track, in: Capsule())
        .animation(DS.Motion.quick, value: selection)
        .fixedSize()
    }
}

// MARK: - 徽标

enum Tone {
    case neutral, primary, success, warning, error

    var color: Color {
        switch self {
        case .neutral: DS.Palette.textSecondary
        case .primary: DS.Palette.primary
        case .success: DS.Palette.success
        case .warning: DS.Palette.warning
        case .error: DS.Palette.error
        }
    }

    static func forTemperature(_ celsius: Double) -> Tone {
        celsius >= DS.Thermal.hot ? .error : celsius >= DS.Thermal.warm ? .warning : .primary
    }
}

struct StatusBadge: View {
    let text: String
    var tone: Tone = .neutral

    var body: some View {
        HStack(spacing: DS.Space.s1) {
            Circle().fill(tone.color).frame(width: DS.Space.s2 - DS.Space.s1 / 2, height: DS.Space.s2 - DS.Space.s1 / 2)
            Text(text).dsFont(.xs, weight: .medium).foregroundStyle(tone.color)
        }
        .padding(.horizontal, DS.Space.s2)
        .padding(.vertical, DS.Space.s1 / 2)
        .background(tone.color.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.sm))
        .lineLimit(1)
    }
}

// MARK: - 按钮

struct DSButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost }
    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        DSButtonBody(configuration: configuration, kind: kind)
    }
}

private struct DSButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: DSButtonStyle.Kind
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isInsideGlass) private var isInsideGlass

    var body: some View {
        if DS.Glass.isAvailable {
            glassBody
        } else {
            solidBody
        }
    }

    /// macOS 26：胶囊形玻璃按钮。主按钮是蓝色玻璃，次要按钮是透明玻璃，文字按钮不加玻璃
    private var glassBody: some View {
        configuration.label
            .dsFont(.sm, weight: .medium)
            .foregroundStyle(foreground)
            .padding(.horizontal, DS.Space.s4)
            .frame(height: DS.Size.controlHeight)
            .contentShape(Capsule())
            .modifier(GlassButtonSurface(kind: kind, active: active, isInsideGlass: isInsideGlass))
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { hovering = $0 }
            .animation(DS.Motion.quick, value: hovering)
    }

    private var solidBody: some View {
        configuration.label
            .dsFont(.sm, weight: .medium)
            .foregroundStyle(foreground)
            .padding(.horizontal, DS.Space.s3)
            .frame(height: DS.Size.controlHeight)
            .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.md))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(DS.Palette.border, lineWidth: DS.Size.stroke)
                }
            }
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(DS.Motion.quick, value: hovering)
    }

    private var active: Bool { hovering || configuration.isPressed }

    private var foreground: Color {
        switch kind {
        case .primary: DS.Palette.onPrimary
        case .secondary: DS.Palette.textPrimary
        case .ghost: DS.Palette.primary
        }
    }

    private var background: Color {
        switch kind {
        case .primary: active ? DS.Palette.primaryHover : DS.Palette.primary
        case .secondary: active ? DS.Palette.surfaceHover : DS.Palette.elevated
        case .ghost: active ? DS.Palette.surfaceHover : .clear
        }
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isInsideGlass) private var isInsideGlass

    var body: some View {
        // macOS 26 上是圆形玻璃按钮（与系统设置的前进后退一致）；已经在玻璃面板里时只有悬停底色
        let glass = DS.Glass.isAvailable && !isInsideGlass
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: DS.TextSize.sm.rawValue, weight: .medium))
                .foregroundStyle(hovering ? DS.Palette.primary : glass ? DS.Palette.textPrimary : DS.Palette.textSecondary)
                .frame(width: DS.Size.controlHeight, height: DS.Size.controlHeight)
                .modifier(IconButtonSurface(hovering: hovering, glass: glass))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 玻璃按钮的底：主按钮蓝色玻璃，次要按钮透明玻璃；文字按钮、或已在玻璃面板里的次要按钮只有悬停底色
private struct GlassButtonSurface: ViewModifier {
    let kind: DSButtonStyle.Kind
    let active: Bool
    let isInsideGlass: Bool

    func body(content: Content) -> some View {
        switch kind {
        case .primary:
            content.dsGlass(in: Capsule(), tint: DS.Palette.primary, interactive: true)
        case .secondary where !isInsideGlass:
            content.dsGlass(in: Capsule(), interactive: true)
        default:
            content.background(active ? DS.Palette.surfaceHover : .clear, in: Capsule())
        }
    }
}

private struct IconButtonSurface: ViewModifier {
    let hovering: Bool
    let glass: Bool

    func body(content: Content) -> some View {
        if glass {
            content.dsGlass(in: Circle(), interactive: true)
        } else if DS.Glass.isAvailable {
            content.background(hovering ? DS.Palette.surfaceHover : .clear, in: Circle())
        } else {
            content.background(hovering ? DS.Palette.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        }
    }
}

// MARK: - 侧边栏

/// 侧边栏的一项。选中态不填色：由容器上的 `sidebarGlider()` 画左侧滑动的蓝色光条与淡淡的高亮
struct SidebarButton: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    /// 需要注意时在右侧显示一个圆点（有新版本、辅助工具需要重新安装）
    var badge: Tone?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: symbol)
                    .font(.system(size: DS.TextSize.sm.rawValue, weight: .medium))
                    .frame(width: DS.Size.iconStandalone)
                Text(title).dsFont(.sm, weight: isSelected ? .semibold : .regular)
                Spacer()
                if let badge {
                    Circle().fill(badge.color).frame(width: DS.Space.s2, height: DS.Space.s2)
                        .accessibilityLabel(tr("需要注意"))
                }
            }
            .foregroundStyle(isSelected ? DS.Palette.primary : hovering ? DS.Palette.textPrimary : DS.Palette.textSecondary)
            .padding(.leading, DS.Space.s3)
            .padding(.trailing, DS.Space.s2)
            .frame(height: DS.Size.controlHeight)
            .contentShape(Rectangle())
            .animation(DS.Motion.quick, value: isSelected)
            .animation(DS.Motion.quick, value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .anchorPreference(key: SidebarRowsKey.self, value: .bounds) { [SidebarRow(isSelected: isSelected, bounds: $0)] }
    }
}

struct SidebarRow {
    let isSelected: Bool
    let bounds: Anchor<CGRect>
}

struct SidebarRowsKey: PreferenceKey {
    static let defaultValue: [SidebarRow] = []
    static func reduce(value: inout [SidebarRow], nextValue: () -> [SidebarRow]) { value += nextValue() }
}

extension View {
    /// 放在包含 SidebarButton 的容器上，画出选中态。
    /// macOS 26：选中项垫一块淡蓝色圆角底，切换时滑过去（侧边栏本身是玻璃面板，里面不再叠玻璃）；
    /// 更早的系统：左侧一条两端渐隐的细线，选中项位置有一段发光的蓝色光条，带回弹地滑过去
    @ViewBuilder
    func sidebarGlider() -> some View {
        if DS.Glass.isAvailable {
            backgroundPreferenceValue(SidebarRowsKey.self) { rows in
                GeometryReader { proxy in
                    if let selected = rows.first(where: \.isSelected).map({ proxy[$0.bounds] }) {
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .fill(DS.Palette.sidebarSelected)
                            .frame(width: selected.width, height: selected.height)
                            .offset(x: selected.minX, y: selected.minY)
                            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selected)
                    }
                }
                .allowsHitTesting(false)
            }
        } else {
            overlayPreferenceValue(SidebarRowsKey.self) { rows in
                GeometryReader { proxy in
                    SidebarGlider(frames: rows.map { proxy[$0.bounds] },
                                  selected: rows.first(where: \.isSelected).map { proxy[$0.bounds] })
                }
                .allowsHitTesting(false)
            }
        }
    }
}

private struct SidebarGlider: View {
    let frames: [CGRect]
    let selected: CGRect?

    private static let barWidth: CGFloat = 2
    private static let glowWidth = DS.Space.s1 + DS.Space.s1 / 2

    var body: some View {
        if let first = frames.min(by: { $0.minY < $1.minY }), let last = frames.max(by: { $0.maxY < $1.maxY }) {
            ZStack(alignment: .topLeading) {
                // 底轨：整列的细线，上下两端渐隐
                Rectangle()
                    .fill(LinearGradient(colors: [.clear, DS.Palette.border, DS.Palette.border, .clear], startPoint: .top, endPoint: .bottom))
                    .frame(width: DS.Size.stroke, height: last.maxY - first.minY)
                    .offset(x: first.minX, y: first.minY)

                if let selected {
                    Rectangle()
                        .fill(LinearGradient(colors: [DS.Palette.primary.opacity(0.14), DS.Palette.primary.opacity(0)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: selected.width, height: selected.height)
                        .offset(x: selected.minX, y: selected.minY)
                    Capsule()
                        .fill(DS.Palette.primary)
                        .frame(width: Self.glowWidth, height: selected.height * 0.6)
                        .blur(radius: DS.Space.s2)
                        .offset(x: selected.minX - Self.glowWidth / 2, y: selected.midY - selected.height * 0.3)
                    Rectangle()
                        .fill(LinearGradient(colors: [DS.Palette.primary.opacity(0), DS.Palette.primary, DS.Palette.primary.opacity(0)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: Self.barWidth, height: selected.height)
                        .offset(x: selected.minX - Self.barWidth / 2, y: selected.minY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(.spring(response: 0.45, dampingFraction: 0.6), value: selected)
        }
    }
}

// MARK: - 分段控件

/// 分段切换（苹果标准样式，与系统设置一致）：一条灰色圆角底槽，各段等宽铺满，
/// 选中的一段是实心品牌蓝、白字，切换时蓝块滑过去
struct SegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @Namespace private var namespace

    private static var radius: CGFloat { DS.Radius.md - DS.Space.s1 / 2 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .dsFont(.sm)
                        .foregroundStyle(selected ? DS.Palette.onPrimary : DS.Palette.textPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, DS.Space.s2)
                        .frame(maxWidth: .infinity)
                        .frame(height: DS.Size.segmentHeight + DS.Space.s1)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                                    .fill(DS.Palette.primary)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .background(DS.Palette.track, in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selection)
    }
}

// MARK: - 开关

struct DSToggle: View {
    @Binding var isOn: Bool
    var label: String = ""
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        // 离屏截图时窗口不在前台，系统开关会画成灰色，截图里用自绘的蓝色开关
        if DS.Glass.isAvailable, !isSnapshot {
            // macOS 26 的系统开关自带液态玻璃（拖动时滑块变成玻璃），颜色沿用品牌蓝
            Toggle(isOn: $isOn) { Text(label) }
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(DS.Palette.primary)
        } else {
            solidBody
        }
    }

    private var solidBody: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? DS.Palette.primary : DS.Palette.neutral300)
                Circle()
                    .fill(DS.Palette.onPrimary)
                    .frame(width: DS.Size.switchKnob, height: DS.Size.switchKnob)
                    .dsShadow(DS.Shadow.level1)
                    .padding(DS.Space.s1)
            }
            .frame(width: DS.Size.switchWidth, height: DS.Size.switchHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(DS.Motion.quick, value: isOn)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? tr("开") : tr("关"))
    }
}

// MARK: - 复选框

struct DSCheckbox: View {
    let isOn: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: DS.Radius.sm)
                .fill(isOn ? DS.Palette.primary : Color.clear)
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: DS.TextSize.xs.rawValue - DS.Space.s1 / 2, weight: .bold))
                            .foregroundStyle(DS.Palette.onPrimary)
                    } else {
                        RoundedRectangle(cornerRadius: DS.Radius.sm)
                            .strokeBorder(DS.Palette.neutral300, lineWidth: DS.Size.chartLine)
                    }
                }
                .frame(width: DS.Size.iconInline, height: DS.Size.iconInline)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - 单选行

struct RadioRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: DS.Space.s3) {
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? DS.Palette.primary : DS.Palette.neutral300, lineWidth: DS.Size.chartLine)
                    if isSelected {
                        Circle().fill(DS.Palette.primary).frame(width: DS.Space.s2, height: DS.Space.s2)
                    }
                }
                .frame(width: DS.Size.iconInline, height: DS.Size.iconInline)
                .padding(.top, DS.Space.s1 / 2)

                VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                    Text(title).dsFont(.sm, weight: .medium).foregroundStyle(DS.Palette.textPrimary)
                    Text(subtitle).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - 设置行

struct SettingRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var icon: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: DS.Space.s3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: DS.TextSize.base.rawValue))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(width: DS.Size.iconStandalone, height: DS.Size.iconStandalone)
            }
            VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                Text(title).dsFont(.sm, weight: .medium).foregroundStyle(DS.Palette.textPrimary)
                if let subtitle {
                    Text(subtitle).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.s4)
            control
        }
    }
}

// MARK: - 提示条

struct InfoBanner<Action: View>: View {
    let icon: String
    let text: String
    var tone: Tone = .primary
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.s3) {
            Image(systemName: icon)
                .font(.system(size: DS.TextSize.sm.rawValue, weight: .semibold))
                .foregroundStyle(tone.color)
                .frame(width: DS.Size.iconInline)
            Text(text)
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            action
        }
        .padding(DS.Space.s3)
        .background(tone.color.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.md))
    }
}

extension InfoBanner where Action == EmptyView {
    init(icon: String, text: String, tone: Tone = .primary) {
        self.init(icon: icon, text: text, tone: tone) { EmptyView() }
    }
}

// MARK: - 滑块（自绘，保证截图与界面风格一致）

struct DSSlider: View {
    @Binding var value: Double           // 0...1
    var onEditingEnded: () -> Void = {}

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let knob = DS.Size.switchKnob
            let x = (width - knob) * min(1, max(0, value))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.Palette.track)
                    .frame(height: DS.Space.s1 + DS.Space.s1 / 2)
                RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.Palette.primary)
                    .frame(width: x + knob / 2, height: DS.Space.s1 + DS.Space.s1 / 2)
                Circle()
                    .fill(DS.Palette.elevated)
                    .overlay(Circle().strokeBorder(DS.Palette.primary, lineWidth: DS.Size.chartLine))
                    .frame(width: knob, height: knob)
                    .dsShadow(DS.Shadow.level1)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        value = min(1, max(0, (gesture.location.x - knob / 2) / max(1, width - knob)))
                    }
                    .onEnded { _ in onEditingEnded() }
            )
        }
        .frame(height: DS.Size.segmentHeight)
        .accessibilityElement()
        .accessibilityValue(Format.percent(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(1, value + 0.1)
            case .decrement: value = max(0, value - 0.1)
            @unknown default: break
            }
            onEditingEnded()
        }
    }
}

// MARK: - 滚动容器

struct PageScroll<Content: View>: View {
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.isPopover) private var isPopover
    @Environment(\.reportPopoverOverflow) private var reportOverflow
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        // 弹窗里区块之间靠分隔线隔开，不再额外留间距
        let stack = VStack(alignment: .leading, spacing: isPopover ? 0 : DS.Space.s3) { content }
            .padding(.horizontal, DS.Space.s3)
            .padding(.bottom, isPopover ? DS.Space.s1 : DS.Space.s3)
        if isSnapshot {
            stack
        } else {
            // 内容放得下时不回弹，避免点击时整页轻微抖动
            ScrollView {
                stack
                    .overlayScrollers()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        contentHeight = height
                        report()
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                viewportHeight = height
                report()
            }
        }
    }

    /// 弹窗里内容高度一变（数据刷新、展开收起），就让面板把窗口调到正好放下；屏幕放不下时才出现滚动
    private func report() {
        guard let reportOverflow, contentHeight > 0, viewportHeight > 0 else { return }
        reportOverflow(contentHeight - viewportHeight)
    }
}

// MARK: - 徽章 / 标签

struct Chip: View {
    let text: String
    var icon: String?
    var tone: Tone = .neutral

    var body: some View {
        HStack(spacing: DS.Space.s1) {
            if let icon {
                Image(systemName: icon).font(.system(size: DS.TextSize.xs.rawValue, weight: .semibold))
            }
            Text(verbatim: text).dsFont(.xs, weight: .medium).monospacedDigit()
        }
        .foregroundStyle(tone == .neutral ? DS.Palette.textSecondary : tone.color)
        .padding(.horizontal, DS.Space.s2)
        .padding(.vertical, DS.Space.s1 / 2)
        .background(tone == .neutral ? DS.Palette.track : tone.color.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: DS.Radius.sm))
        .lineLimit(1)
        .fixedSize()
    }
}

/// 可点击的小标签，用于风扇模式等快捷切换
struct ChipButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        if DS.Glass.isAvailable {
            // macOS 26：每个选项是一颗玻璃胶囊，选中的是蓝色玻璃
            Button(action: action) {
                Text(title)
                    .dsFont(.xs, weight: isSelected ? .semibold : .medium)
                    .foregroundStyle(isSelected ? DS.Palette.onPrimary : DS.Palette.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: DS.Size.segmentHeight)
                    .contentShape(Capsule())
                    .dsGlass(in: Capsule(), tint: isSelected ? DS.Palette.primary : nil, interactive: true)
            }
            .buttonStyle(.plain)
            .animation(DS.Motion.quick, value: isSelected)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            solidBody
        }
    }

    private var solidBody: some View {
        Button(action: action) {
            Text(title)
                .dsFont(.xs, weight: isSelected ? .semibold : .medium)
                .foregroundStyle(isSelected ? DS.Palette.primary : DS.Palette.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: DS.Size.segmentHeight)
                .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .strokeBorder(isSelected ? DS.Palette.primary.opacity(0.4) : DS.Palette.border, lineWidth: DS.Size.stroke))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected { return DS.Palette.primary.opacity(0.12) }
        return hovering ? DS.Palette.surfaceHover : .clear
    }
}

/// 自动换行排列（徽章行）
struct FlowLayout: Layout {
    var spacing: CGFloat = DS.Space.s2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, maxWidth: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let proposedWidth = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if proposedWidth > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - 指标小卡片

struct MetricTile<Chart: View, Footer: View>: View {
    let icon: String
    let title: String
    var chip: String?
    var chipTone: Tone = .neutral
    let value: String
    var unit: String?
    @ViewBuilder var chart: Chart
    @ViewBuilder var footer: Footer

    var body: some View {
        Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s1) {
                Image(systemName: icon)
                    .font(.system(size: DS.TextSize.xs.rawValue, weight: .semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
                Text(title)
                    .dsFont(.xs, weight: .semibold)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: DS.Space.s1)
                if let chip { Chip(text: chip, tone: chipTone) }
            }
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s1 / 2) {
                Text(verbatim: value)
                    .dsFont(.xl, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(DS.Palette.textPrimary)
                if let unit {
                    Text(verbatim: unit).dsFont(.xs, weight: .medium).foregroundStyle(DS.Palette.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            chart
                .frame(height: DS.Size.tileChart)
            footer
                .font(.system(size: DS.TextSize.xs.rawValue))
                .foregroundStyle(DS.Palette.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

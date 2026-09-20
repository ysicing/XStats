import AppKit
import SwiftUI

/// 设计 token。界面里的颜色、字号、间距、圆角一律从这里取值。
public enum DS {}

// MARK: - 颜色

extension DS {
    enum Palette {
        // 品牌色（单个视图内不超过 3 种）
        static let primary = Color.dynamic(light: 0x2563EB, dark: 0x3B82F6)
        static let primaryHover = Color.dynamic(light: 0x1D4ED8, dark: 0x2563EB)   // 加深约 10%
        static let secondary = Color.dynamic(light: 0x0D9488, dark: 0x2DD4BF)

        // 语义色
        static let success = Color.dynamic(light: 0x16A34A, dark: 0x22C55E)
        static let warning = Color.dynamic(light: 0xD97706, dark: 0xF59E0B)
        static let error = Color.dynamic(light: 0xDC2626, dark: 0xF87171)

        // 文字
        static let textPrimary = Color.dynamic(light: 0x111827, dark: 0xF3F4F6)
        static let textSecondary = Color.dynamic(light: 0x6B7280, dark: 0x9CA3AF)
        static let textTertiary = Color.dynamic(light: 0x9CA3AF, dark: 0x6B7280)
        static let onPrimary = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF)

        // XStats 的统一配色：浅色为白底蓝色，深色为黑底蓝色。
        // 窗口、侧边栏、标题栏与弹窗共用同一底色，卡片用浅灰 / 深灰实色区分层级，不加边框
        static let background = Color(nsColor: NSColor.dsBackground)
        static let surface = Color.dynamic(light: 0xF3F4F6, dark: 0x17181B)
        /// 卡片上的控件底色（分段选中块、次要按钮、输入框）
        static let elevated = Color.dynamic(light: 0xFFFFFF, dark: 0x26282D)
        static let surfaceHover = Color.dynamic(light: 0x000000, lightAlpha: 0.05, dark: 0xFFFFFF, darkAlpha: 0.07)
        static let border = Color.dynamic(light: 0x000000, lightAlpha: 0.07, dark: 0xFFFFFF, darkAlpha: 0.09)
        static let track = Color.dynamic(light: 0x000000, lightAlpha: 0.06, dark: 0xFFFFFF, darkAlpha: 0.10)
        static let neutral300 = Color.dynamic(light: 0xD1D5DB, dark: 0x3F434A)
        /// 分段条里表示“剩余 / 空闲”的中性段，深到能衬白字
        static let neutral500 = Color.dynamic(light: 0x6B7280, dark: 0x4B5563)
        /// 浅一档的品牌蓝，用来区分同一图表里的第二类数据（如性能核）
        static let primarySoft = Color.dynamic(light: 0x93C5FD, dark: 0x60A5FA)
        /// 侧边栏选中项的淡蓝底
        static let sidebarSelected = Color.dynamic(light: 0x2563EB, lightAlpha: 0.12, dark: 0x3B82F6, darkAlpha: 0.22)
        /// 全局加载时压暗整个窗口
        /// 网站图标的垫底：深色模式下也保持浅色，黑色字标才看得清
        static let logoTile = Color.dynamic(light: 0xFFFFFF, dark: 0xF3F4F6)
        static let scrim = Color.dynamic(light: 0x000000, lightAlpha: 0.12, dark: 0x000000, darkAlpha: 0.40)

        /// 核心类型配色：最高性能档为品牌蓝，其次浅蓝，能效核灰色
        static func cluster(_ id: Int) -> Color {
            switch id {
            case 0: primary
            case 1: primarySoft
            default: neutral300
            }
        }
    }
}

extension DS {
    /// 网速配色：上传绿、下载蓝，面板与菜单栏保持一致
    enum NetworkPalette {
        static let upload = NSColor.dynamic(light: 0x16A34A, dark: 0x22C55E)
        static let download = NSColor.dynamic(light: 0x2563EB, dark: 0x3B82F6)
    }
}

extension Color {
    static func dynamic(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: .dynamic(light: light, lightAlpha: lightAlpha, dark: dark, darkAlpha: darkAlpha))
    }
}

extension NSColor {
    /// 窗口底色，AppKit 窗口背景与 SwiftUI 页面共用
    static let dsBackground = NSColor.dynamic(light: 0xFFFFFF, dark: 0x0B0B0D)

    static func dynamic(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

// MARK: - 字号 / 间距 / 圆角 / 尺寸

extension DS {
    enum TextSize: CGFloat {
        case xs = 12, sm = 14, base = 16, lg = 20, xl = 24, xxl = 32
    }

    /// 徽章配色：浅底、细边、深字，与 cleanip.io 的徽章一致
    enum Badge {
        static let successText = Color.dynamic(light: 0x15803D, dark: 0x75D99B)
        static let successFill = Color.dynamic(light: 0xF0FDF4, dark: 0x142F24)
        static let successBorder = Color.dynamic(light: 0xBBF7D0, dark: 0x29543C)
        static let warningText = Color.dynamic(light: 0xB45309, dark: 0xF3C66C)
        static let warningFill = Color.dynamic(light: 0xFFFBEB, dark: 0x342B1B)
        static let warningBorder = Color.dynamic(light: 0xFDE68A, dark: 0x625030)
        static let neutralText = Palette.textSecondary
        static let neutralFill = Palette.elevated
        static let neutralBorder = Palette.border
    }

    /// 0–100 分的六档色阶（F / D / C / B / A / A+），只用于评分类图表，不是界面配色
    enum Grade {
        static let f = Palette.error
        static let d = Palette.warning
        static let c = Color.dynamic(light: 0xEAB308, dark: 0xFACC15)
        static let b = Color.dynamic(light: 0x84CC16, dark: 0xA3E635)
        static let a = Palette.success
        static let aPlus = Color.dynamic(light: 0x15803D, dark: 0x16A34A)

        /// 分段上限与颜色，从低到高
        static let bands: [(grade: String, upper: Int, color: Color)] = [
            ("F", 25, f), ("D", 50, d), ("C", 70, c), ("B", 85, b), ("A", 95, a), ("A+", 100, aPlus),
        ]

        static func color(for score: Int) -> Color {
            bands.first { score < $0.upper }?.color ?? aPlus
        }
    }

    enum Space {
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s6: CGFloat = 24
        static let s8: CGFloat = 32
        static let s12: CGFloat = 48
        static let s16: CGFloat = 64
    }

    /// 层级：控件 < 卡片 < 面板/窗口
    enum Radius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16   // 弹窗
    }

    enum Size {
        static let iconInline: CGFloat = 16
        static let iconStandalone: CGFloat = 20
        static let controlHeight: CGFloat = 32
        static let segmentHeight: CGFloat = 24
        static let switchWidth: CGFloat = 40
        static let switchHeight: CGFloat = 24
        static let switchKnob: CGFloat = 16
        static let barHeight: CGFloat = 8
        static let coreBarHeight: CGFloat = 32
        static let chartHeight: CGFloat = 48
        static let tileChart: CGFloat = 40
        static let stroke: CGFloat = 1
        static let chartLine: CGFloat = 1.5
        static let panelWidth: CGFloat = 640
        /// 菜单栏单项详情弹窗的宽度
        static let popoverWidth: CGFloat = 320
        static let panelMinHeight: CGFloat = 320
        static let panelGap: CGFloat = 4
        /// 窗口顶栏高度：标准工具栏的标题栏（52pt），红绿灯、页面标题与右上角 32pt 的按钮在同一条水平线上，按钮上下各留 10pt
        static let windowHeader: CGFloat = DS.Space.s12 + DS.Space.s1
        /// 没有侧边栏的窗口里，顶栏标题要让出红绿灯按钮的宽度
        static let trafficLightsWidth: CGFloat = 80
        /// 网络测速窗口
        static let speedTestWindowWidth: CGFloat = 720
        static let speedTestWindowHeight: CGFloat = 840
        /// 出口与分流窗口
        static let egressWindowWidth: CGFloat = 720
        static let egressWindowHeight: CGFloat = 800
        /// 主窗口首次打开的最小高度（屏幕放得下时）
        static let windowDefaultHeight: CGFloat = 720
        /// 主窗口默认内容区宽度（侧边栏另计）
        static let windowDefaultContentWidth: CGFloat = 880
        static let sidebarWidth: CGFloat = 192
        /// 升级提示窗口
        static let updateWindowWidth: CGFloat = 480
        static let updateNotesHeight: CGFloat = 192
        static let valueColumn: CGFloat = 64
        static let labelColumn: CGFloat = 48
    }

    enum Shadow {
        struct Level {
            let color: Color
            let radius: CGFloat
            let y: CGFloat
        }

        static let level1 = Level(color: .black.opacity(0.08), radius: 3, y: 1)
        static let level2 = Level(color: .black.opacity(0.10), radius: 12, y: 4)
    }

    enum Motion {
        static let quick = Animation.easeOut(duration: 0.15)
    }

    /// 温度阈值（°C），用于着色
    enum Thermal {
        static let warm: Double = 80
        static let hot: Double = 95
        static let scaleMax: Double = 110
    }
}

// MARK: - 修饰器

extension View {
    func dsFont(_ size: DS.TextSize, weight: Font.Weight = .regular) -> some View {
        font(.system(size: size.rawValue, weight: weight))
    }

}

extension Text {
    func dsFont(_ size: DS.TextSize, weight: Font.Weight = .regular) -> Text {
        font(.system(size: size.rawValue, weight: weight))
    }
}

extension View {
    func dsShadow(_ level: DS.Shadow.Level) -> some View {
        shadow(color: level.color, radius: level.radius, x: 0, y: level.y)
    }
}

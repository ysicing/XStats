import Foundation

/// 界面语言。源代码里的文案是简体中文；选择英文时，`tr` 在显示前把中文换成英文。
///
/// 翻译表以中文原文为键：没有插值的文案精确匹配；带插值的文案用 `{}` 表示插入的内容，
/// 例如 “{} 个进程” → “{} processes”，英文里可以写 `{1}`、`{2}` 调整顺序。
public enum AppLanguage: String, CaseIterable, Sendable {
    case system, chinese, english

    /// 跟随系统时，系统首选语言是中文就用中文，否则用英文。
    /// 读全局偏好而不是 Locale.preferredLanguages：后者会被应用自己写入的 AppleLanguages 覆盖
    public var resolved: AppLanguage {
        guard self == .system else { return self }
        let global = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
        let preferred = (global?.first ?? Locale.preferredLanguages.first ?? "zh").lowercased()
        return preferred.hasPrefix("zh") ? .chinese : .english
    }

    /// 让系统提供的文字（日期、显示器名称、应用名称）与界面语言一致：写入应用自己的 AppleLanguages，下次启动生效
    public func applyToProcessLocale(defaults: UserDefaults = .standard) {
        // 地区保持用户设置（影响日期顺序、单位等），只换语言
        let region = (CFPreferencesCopyValue("AppleLocale" as CFString, kCFPreferencesAnyApplication,
                                             kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String)
            .map { Locale(identifier: $0).region?.identifier ?? "US" } ?? "US"
        switch self {
        case .system:
            defaults.removeObject(forKey: "AppleLanguages")
            defaults.removeObject(forKey: "AppleLocale")
        case .chinese:
            defaults.set(["zh-Hans"], forKey: "AppleLanguages")
            defaults.set("zh_Hans_\(region)", forKey: "AppleLocale")
        case .english:
            defaults.set(["en"], forKey: "AppleLanguages")
            defaults.set("en_\(region)", forKey: "AppleLocale")
        }
    }
}

public enum L10n {
    /// 默认中文；应用启动时按设置调用 configure。单元测试与辅助工具不调用，始终保持中文原文
    nonisolated(unsafe) public private(set) static var language: AppLanguage = .chinese
    /// 截图与调试时记录没有翻译的中文，便于补全
    nonisolated(unsafe) public static var missLog: URL?

    public static var isEnglish: Bool { language == .english }

    /// 格式化日期用的地区：英文界面用英文月份名，地区沿用系统设置
    public static var locale: Locale {
        guard isEnglish else { return .current }
        return Locale(identifier: "en_" + (Locale.current.region?.identifier ?? "US"))
    }

    public static func configure(_ language: AppLanguage) {
        lock.lock()
        self.language = language.resolved
        cache = [:]
        lock.unlock()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    nonisolated(unsafe) private static var misses = Set<String>()

    static func translate(_ text: String) -> String {
        guard language == .english, containsChinese(text) else { return text }
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[text] { return cached }
        let result = Translations.shared.translate(text) ?? {
            recordMiss(text)
            return text
        }()
        // 带数字的文案不断变化，缓存设上限
        if cache.count > 4000 { cache.removeAll(keepingCapacity: true) }
        cache[text] = result
        return result
    }

    static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3000...0x303F).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }

    private static func recordMiss(_ text: String) {
        guard let missLog, misses.insert(text).inserted else { return }
        if let handle = try? FileHandle(forWritingTo: missLog) {
            handle.seekToEndOfFile()
            handle.write(Data((text.replacingOccurrences(of: "\n", with: "\\n") + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((text + "\n").utf8).write(to: missLog)
        }
    }
}

/// 界面文案：英文界面下返回译文，否则原样返回
@inline(__always)
public func tr(_ text: String) -> String {
    L10n.translate(text)
}

/// 翻译表：精确匹配表与带 `{}` 的模板
final class Translations: @unchecked Sendable {
    static let shared = Translations()

    private var exact: [String: String] = [:]
    private var templates: [Template] = []

    struct Template {
        let fragments: [String]
        let regex: NSRegularExpression
        let english: String
    }

    private init() {
        for table in Translations.tables {
            for line in table.split(separator: "\n", omittingEmptySubsequences: true) {
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let source = String(parts[0]).replacingOccurrences(of: "\\n", with: "\n")
                let english = String(parts[1]).replacingOccurrences(of: "\\n", with: "\n")
                if source.contains("{}") {
                    let fragments = source.components(separatedBy: "{}")
                    let pattern = "^" + fragments.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "(.*?)") + "$"
                    if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                        templates.append(Template(fragments: fragments.filter { !$0.isEmpty }, regex: regex, english: english))
                    }
                } else {
                    exact[source] = english
                }
            }
        }
        // 片段越长越具体，优先匹配
        templates.sort { $0.fragments.joined().count > $1.fragments.joined().count }
    }

    func translate(_ text: String, depth: Int = 0) -> String? {
        if let english = exact[text] { return english }
        let range = NSRange(text.startIndex..., in: text)
        for template in templates where template.fragments.allSatisfy(text.contains) {
            guard let match = template.regex.firstMatch(in: text, range: range) else { continue }
            var values: [String] = []
            for index in 1..<match.numberOfRanges {
                guard let r = Range(match.range(at: index), in: text) else { continue }
                let value = String(text[r])
                // 插进来的内容本身也可能是中文（例如来自其他模块的名称），能翻就翻
                values.append(depth < 2 && L10n.containsChinese(value) ? (translate(value, depth: depth + 1) ?? value) : value)
            }
            return fill(template.english, values)
        }
        return nil
    }

    private func fill(_ english: String, _ values: [String]) -> String {
        var result = english
        // 先替换带序号的 {1}{2}，再按顺序替换 {}
        for (index, value) in values.enumerated() {
            result = result.replacingOccurrences(of: "{\(index + 1)}", with: value)
        }
        var iterator = values.makeIterator()
        while let range = result.range(of: "{}") {
            result.replaceSubrange(range, with: iterator.next() ?? "")
        }
        return result
    }
}

// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import Foundation

public enum L10n {
    // 所有可变全局状态都由同一把锁保护；tr 同时用于 UI 和后台采样任务。
    private static let lock = NSLock()
    nonisolated(unsafe) private static var selectedLanguage: AppLanguage = .chinese
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    nonisolated(unsafe) private static var misses = Set<String>()
    nonisolated(unsafe) private static var missingLogURL: URL?

    public static var language: AppLanguage { lock.withLock { selectedLanguage } }
    public static var missLog: URL? {
        get { lock.withLock { missingLogURL } }
        set { lock.withLock { missingLogURL = newValue } }
    }
    public static var isEnglish: Bool { language == .english }
    /// 在线地名只有中英文两套数据时，其他语言使用英文，国家名称仍由当前 Locale 本地化。
    public static var usesEnglishNames: Bool { !language.isChinese }
    public static var locale: Locale { locale(for: language) }

    public static func locale(for language: AppLanguage) -> Locale {
        let region = Locale.current.region?.identifier ?? "US"
        return Locale(identifier: language.resolved.languageCode.replacingOccurrences(of: "-", with: "_") + "_" + region)
    }

    public static func configure(_ language: AppLanguage) {
        let resolved = language.resolved
        lock.withLock {
            selectedLanguage = resolved
            cache.removeAll(keepingCapacity: true)
        }
    }

    static func translate(_ text: String) -> String {
        lock.withLock {
            guard selectedLanguage != .chinese, containsChinese(text) else { return text }
            if let cached = cache[text] { return cached }
            let catalog = Translations.catalog(for: selectedLanguage)
            let translated = catalog?.translate(text, fallback: Translations.shared)
            if translated == nil { recordMiss(text) }
            let result = translated ?? Translations.shared.translate(text) ?? text
            if cache.count > 4000 { cache.removeAll(keepingCapacity: true) }
            cache[text] = result
            return result
        }
    }

    static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value) || (0x3000...0x303F).contains($0.value) || (0xFF00...0xFFEF).contains($0.value)
        }
    }

    /// 仅在持锁状态调用。按语言记录缺失条目，缺失新文案回退英文而非空白。
    private static func recordMiss(_ text: String) {
        let key = "\(selectedLanguage.languageCode)\t\(text)"
        guard let missingLogURL, misses.insert(key).inserted else { return }
        let line = key.replacingOccurrences(of: "\n", with: "\\n") + "\n"
        if let handle = try? FileHandle(forWritingTo: missingLogURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: missingLogURL)
        }
    }
}

/// 中文原文作为稳定键，界面显示前按所选语言翻译。
@inline(__always)
public func tr(_ text: String) -> String { L10n.translate(text) }

/// 不可变翻译表，可在采样和界面线程共享。占位符支持 {} 以及重排后的 {1}、{2}。
final class Translations: Sendable {
    static let shared = Translations(tables: tables)
    private static let catalogs: [AppLanguage: Translations] = {
        var result: [AppLanguage: Translations] = [.english: shared]
        for language in AppLanguage.allCases where language != .system && language != .chinese && language != .english {
            guard let url = Bundle.module.url(forResource: language.languageCode, withExtension: "tsv"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            result[language] = Translations(tables: [text], rightToLeft: language.isRightToLeft)
        }
        return result
    }()

    static func catalog(for language: AppLanguage) -> Translations? { catalogs[language.resolved] }

    private let exact: [String: String]
    private let templates: [Template]
    private let rightToLeft: Bool
    let sourceKeys: Set<String>

    struct Template: Sendable {
        let fragments: [String]
        let regex: NSRegularExpression
        let translation: String
    }

    init(tables: [String], rightToLeft: Bool = false) {
        var values: [String: String] = [:]
        for table in tables {
            for line in table.split(separator: "\n", omittingEmptySubsequences: true) {
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let source = String(parts[0]).replacingOccurrences(of: "\\n", with: "\n")
                let translation = String(parts[1]).replacingOccurrences(of: "\\n", with: "\n")
                // 错误占位符会丢失路径/数值，拒绝该条目并交由英文回退处理。
                guard !translation.isEmpty, Self.validPlaceholders(source: source, translation: translation) else { continue }
                values[source] = translation
            }
        }
        sourceKeys = Set(values.keys)
        var exact: [String: String] = [:]
        var templates: [Template] = []
        for (source, translation) in values {
            if source.contains("{}") {
                let fragments = source.components(separatedBy: "{}")
                let pattern = "^" + fragments.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "(.*?)") + "$"
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                    templates.append(Template(fragments: fragments.filter { !$0.isEmpty }, regex: regex, translation: translation))
                }
            } else {
                exact[source] = translation
            }
        }
        self.exact = exact
        // 长模板优先；长度相同时稳定排序，避免相近模板因字典顺序出现随机匹配。
        self.templates = templates.sorted {
            let left = $0.fragments.joined(), right = $1.fragments.joined()
            return left.count == right.count ? left < right : left.count > right.count
        }
        self.rightToLeft = rightToLeft
    }

    func translate(_ text: String, depth: Int = 0, fallback: Translations? = nil) -> String? {
        if let translation = exact[text] { return translation }
        let range = NSRange(text.startIndex..., in: text)
        for template in templates where template.fragments.allSatisfy(text.contains) {
            guard let match = template.regex.firstMatch(in: text, range: range) else { continue }
            var values: [String] = []
            for index in 1..<match.numberOfRanges {
                guard let range = Range(match.range(at: index), in: text) else { continue }
                let value = String(text[range])
                values.append(depth < 2 && L10n.containsChinese(value)
                    ? (translate(value, depth: depth + 1, fallback: fallback)
                       ?? fallback?.translate(value, depth: depth + 1) ?? value) : value)
            }
            return fill(template.translation, values)
        }
        return nil
    }

    private func fill(_ translation: String, _ values: [String]) -> String {
        // RTL 模板中的路径、IP 和数值独立定向，不让标点与相邻阿拉伯文互相重排。
        let values = rightToLeft ? values.map { "\u{2068}\($0)\u{2069}" } : values
        // 只扫描模板，绝不再次扫描插入值，保留文件名或命令里本来就有的 {}。
        var result = ""
        var cursor = translation.startIndex
        var sequential = 0
        for match in Self.placeholder.matches(in: translation, range: NSRange(translation.startIndex..., in: translation)) {
            guard let range = Range(match.range, in: translation),
                  let numberRange = Range(match.range(at: 1), in: translation) else { continue }
            result += translation[cursor..<range.lowerBound]
            let number = translation[numberRange]
            let index: Int
            if number.isEmpty {
                index = sequential
                sequential += 1
            } else {
                index = (Int(number) ?? 0) - 1
            }
            result += values.indices.contains(index) ? values[index] : String(translation[range])
            cursor = range.upperBound
        }
        return result + translation[cursor...]
    }

    private static let placeholder = try! NSRegularExpression(pattern: #"\{(\d*)\}"#)

    private static func validPlaceholders(source: String, translation: String) -> Bool {
        let count = source.components(separatedBy: "{}").count - 1
        var sequential = 0
        var used = Set<Int>()
        for match in placeholder.matches(in: translation, range: NSRange(translation.startIndex..., in: translation)) {
            guard let range = Range(match.range(at: 1), in: translation) else { return false }
            let number = translation[range]
            if number.isEmpty {
                sequential += 1
                used.insert(sequential)
            } else {
                guard let index = Int(number), index > 0 else { return false }
                used.insert(index)
            }
        }
        return used == Set(1..<(count + 1))
    }
}

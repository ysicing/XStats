// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI
import WidgetKit

private struct RestEntry: TimelineEntry {
    let date: Date
    let enabled: Bool
    let isResting: Bool
    let running: Bool
    let remaining: TimeInterval
    let deadline: Date
    let duration: TimeInterval
}

private struct RestProvider: TimelineProvider {
    func placeholder(in context: Context) -> RestEntry {
        RestEntry(date: .now, enabled: true, isResting: false, running: true, remaining: 20 * 60,
                  deadline: .now.addingTimeInterval(20 * 60), duration: 20 * 60)
    }

    func getSnapshot(in context: Context, completion: @escaping (RestEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : read())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RestEntry>) -> Void) {
        let entry = read()
        guard entry.enabled, entry.running, entry.deadline > entry.date else {
            completion(Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(3600))))
            return
        }

        // 倒计时文字可由系统更新；圆环需要在阶段内提供新的 TimelineEntry。
        var entries = [entry]
        var date = entry.date
        while date < entry.deadline {
            date = min(date.addingTimeInterval(60), entry.deadline)
            entries.append(RestEntry(date: date, enabled: entry.enabled, isResting: entry.isResting,
                                     running: entry.running, remaining: entry.remaining,
                                     deadline: entry.deadline, duration: entry.duration))
        }
        completion(Timeline(entries: entries, policy: .after(entry.deadline)))
    }

    private func read() -> RestEntry {
        let defaults = UserDefaults(suiteName: "group.work.12306.xstats")
        if let language = defaults?.string(forKey: "rest.language").flatMap(AppLanguage.init(rawValue:)) {
            L10n.configure(language)
        }
        let now = Date()
        return RestEntry(date: now, enabled: defaults?.bool(forKey: "rest.enabled") ?? false,
                         isResting: ["rest", "longRest"].contains(defaults?.string(forKey: "rest.phase") ?? ""),
                         running: defaults?.bool(forKey: "rest.running") ?? false,
                         remaining: defaults?.double(forKey: "rest.remaining") ?? 0,
                         deadline: Date(timeIntervalSince1970: defaults?.double(forKey: "rest.deadline") ?? 0),
                         duration: TimeInterval(defaults?.double(forKey: "rest.duration") ?? 0))
    }
}

private struct RestWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RestEntry

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.cyan.opacity(0.17), lineWidth: 8)
                Circle().trim(from: 0, to: progress)
                    .stroke(.cyan, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: entry.isResting ? "eye" : "timer")
                    .font(.system(size: family == .systemSmall ? 28 : 36, weight: .ultraLight))
            }
            .frame(width: family == .systemSmall ? 76 : 96, height: family == .systemSmall ? 76 : 96)
            VStack(alignment: .leading, spacing: 6) {
                Text(tr(entry.enabled ? (entry.running ? (entry.isResting ? "休息中" : "专注中") : "已暂停")
                     : "护眼休息未开启"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                if entry.enabled {
                    if entry.running {
                        Text(entry.deadline, style: .timer)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    } else {
                        Text(String(format: "%02d:%02d", max(0, Int(entry.remaining)) / 60,
                                    max(0, Int(entry.remaining)) % 60))
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.background, for: .widget)
        .environment(\.locale, L10n.locale(for: L10n.language))
        .environment(\.layoutDirection, L10n.language.isRightToLeft ? .rightToLeft : .leftToRight)
    }

    private var progress: Double {
        guard entry.enabled, entry.duration > 0 else { return 0 }
        let remaining = entry.running ? max(0, entry.deadline.timeIntervalSince(entry.date)) : entry.remaining
        return min(1, max(0, 1 - remaining / entry.duration))
    }
}

struct RestWidget: Widget {
    init() {
        let defaults = UserDefaults(suiteName: "group.work.12306.xstats")
        let language = defaults?.string(forKey: "rest.language").flatMap(AppLanguage.init(rawValue:)) ?? .system
        L10n.configure(language)
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "rest", provider: RestProvider()) { entry in
            RestWidgetView(entry: entry)
        }
        .configurationDisplayName(tr("番茄钟"))
        .description(tr("查看下一次休息或当前休息倒计时。"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

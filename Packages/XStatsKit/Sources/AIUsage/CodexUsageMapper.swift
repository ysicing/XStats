// Copyright (c) 2026 Burak Gon
// Copyright (c) 2026 Robin Ebers
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// Adapted from AI Usage quota mapping; see LICENSES/AI-Usage-and-OpenUsage-MIT.txt.

import Foundation
import CoreFoundation

enum CodexUsageMapper {
    private enum WindowSlot { case session, weekly }

    private struct Candidate {
        let object: [String: Any]
        let usedPercent: Double?
        let fallback: WindowSlot
    }

    static func map(data: Data, headers: [String: String], now: Date) throws -> AIUsageSnapshot {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIUsageFailure.invalidResponse
        }
        var windows = classify(
            rateLimit: object(body["rate_limit"]),
            kinds: (.session, .weekly),
            headerPercents: (
                header("x-codex-primary-used-percent", in: headers).flatMap(number),
                header("x-codex-secondary-used-percent", in: headers).flatMap(number)
            ),
            now: now
        )
        if let entries = body["additional_rate_limits"] as? [Any] {
            for raw in entries {
                guard let entry = object(raw), isSpark(entry), let rateLimit = object(entry["rate_limit"]) else { continue }
                windows += classify(rateLimit: rateLimit, kinds: (.sparkSession, .sparkWeekly),
                                    headerPercents: (nil, nil), now: now)
                break
            }
        }
        guard !windows.isEmpty || credits(in: body, headers: headers) != nil else {
            throw AIUsageFailure.invalidResponse
        }
        return AIUsageSnapshot(provider: .codex, planName: planName(body["plan_type"]), windows: windows,
                               remainingCredits: credits(in: body, headers: headers), fetchedAt: now)
    }

    private static func classify(rateLimit: [String: Any]?,
                                 kinds: (session: AIQuotaKind, weekly: AIQuotaKind),
                                 headerPercents: (primary: Double?, secondary: Double?),
                                 now: Date) -> [AIQuotaWindow] {
        let candidates = [
            candidate(rateLimit?["primary_window"], headerPercent: headerPercents.primary, fallback: .session),
            candidate(rateLimit?["secondary_window"], headerPercent: headerPercents.secondary, fallback: .weekly),
        ].compactMap { $0 }
        return [
            window(slot: .session, kind: kinds.session, candidates: candidates, now: now),
            window(slot: .weekly, kind: kinds.weekly, candidates: candidates, now: now),
        ].compactMap { $0 }
    }

    private static func candidate(_ value: Any?, headerPercent: Double?, fallback: WindowSlot) -> Candidate? {
        let object: [String: Any]
        if let parsed = self.object(value) { object = parsed }
        else if headerPercent != nil { object = [:] }
        else { return nil }
        return Candidate(object: object, usedPercent: number(object["used_percent"]) ?? headerPercent, fallback: fallback)
    }

    private static func window(slot: WindowSlot, kind: AIQuotaKind, candidates: [Candidate], now: Date) -> AIQuotaWindow? {
        let exact = candidates.first { exactSlot($0.object) == slot }
        let fallback = candidates.first { exactSlot($0.object) == nil && $0.fallback == slot }
        guard let candidate = exact ?? fallback, let used = candidate.usedPercent, used.isFinite else { return nil }
        return AIQuotaWindow(kind: kind, usedPercent: used, resetsAt: resetDate(candidate.object, now: now))
    }

    private static func exactSlot(_ object: [String: Any]) -> WindowSlot? {
        guard let seconds = number(object["limit_window_seconds"]) else { return nil }
        return switch seconds {
        case 18_000: .session
        case 604_800: .weekly
        default: nil
        }
    }

    private static func resetDate(_ object: [String: Any], now: Date) -> Date? {
        if let value = number(object["reset_at"]) { return Date(timeIntervalSince1970: value) }
        if let value = number(object["reset_after_seconds"]) { return now.addingTimeInterval(value) }
        return nil
    }

    private static func isSpark(_ entry: [String: Any]) -> Bool {
        [entry["limit_name"], entry["metered_feature"]]
            .compactMap { $0 as? String }
            .contains { $0.localizedCaseInsensitiveContains("spark") }
    }

    private static func credits(in body: [String: Any], headers: [String: String]) -> Double? {
        if let values = object(body["credits"]) {
            if let balance = number(values["balance"]) { return max(0, balance) }
            if values["has_credits"] as? Bool == false { return 0 }
        }
        return header("x-codex-credits-balance", in: headers).flatMap(number).map { max(0, $0) }
    }

    private static func planName(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "prolite", "pro_lite": return "Pro 5x"
        case "pro": return "Pro 20x"
        default:
            return raw.replacingOccurrences(of: "_", with: " ").split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
        }
    }

    private static func object(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            return number.doubleValue
        }
        if let string = value as? String, let number = Double(string), number.isFinite { return number }
        return nil
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

@preconcurrency import EventKit
import Foundation
import Localization
import Observation

struct CalendarAgendaSource: Identifiable, Sendable {
    let id: String
    let title: String
}

struct CalendarAgendaItem: Identifiable, Sendable {
    let id: String
    let title: String
    let source: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let isReminder: Bool

    /// 全天及跨天事件的结束时间是开区间，不能在次日多画一个日程标记。
    func occurs(on date: Date, calendar: Calendar) -> Bool {
        guard let day = calendar.dateInterval(of: .day, for: date) else { return false }
        if isReminder || end <= start { return start >= day.start && start < day.end }
        return start < day.end && end > day.start
    }
}

struct CalendarAgendaQuery: Equatable, Sendable {
    let start: Date
    let end: Date
    let events: Bool
    let reminders: Bool
    let eventIDs: Set<String>?
    let reminderIDs: Set<String>?
    let revision: Int
}

/// EventKit 对象留在工作 actor 内；界面只接收值类型，不在主线程同步查询日程。
private actor CalendarAgendaReader {
    private lazy var store = EKEventStore()
    private var pending: [UUID: (Any, CheckedContinuation<[CalendarAgendaItem]?, Never>)] = [:]

    func sources(reminders: Bool) -> [CalendarAgendaSource] {
        let type: EKEntityType = reminders ? .reminder : .event
        guard EKEventStore.authorizationStatus(for: type) == .fullAccess else { return [] }
        return store.calendars(for: type).map { .init(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func load(_ query: CalendarAgendaQuery) async -> [CalendarAgendaItem]? {
        guard !Task.isCancelled else { return nil }
        var result: [CalendarAgendaItem] = []
        if query.events && EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            let calendars = store.calendars(for: .event).filter { query.eventIDs?.contains($0.calendarIdentifier) ?? true }
            // EventKit 会把空列表视为“所有日历”；用户明确取消全部时必须跳过查询。
            if !calendars.isEmpty {
                let predicate = store.predicateForEvents(withStart: query.start, end: query.end, calendars: calendars)
                result = store.events(matching: predicate).map {
                    .init(id: $0.calendarItemIdentifier + ":" + String($0.startDate.timeIntervalSince1970),
                          title: $0.title ?? "", source: $0.calendar.title, start: $0.startDate, end: $0.endDate,
                          isAllDay: $0.isAllDay, isReminder: false)
                }
            }
        }
        if query.reminders && EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            let calendars = store.calendars(for: .reminder).filter { query.reminderIDs?.contains($0.calendarIdentifier) ?? true }
            if !calendars.isEmpty {
                guard let reminders = await reminders(query, calendars: calendars) else { return nil }
                result += reminders
            }
        }
        return result.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
    }

    private func reminders(_ query: CalendarAgendaQuery, calendars: [EKCalendar]) async -> [CalendarAgendaItem]? {
        let id = UUID()
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: query.start, ending: query.end, calendars: calendars)
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                let token = store.fetchReminders(matching: predicate) { [weak self] reminders in
                    let items = reminders.map { reminders in
                        reminders.compactMap { reminder -> CalendarAgendaItem? in
                            guard let components = reminder.dueDateComponents else { return nil }
                            var calendar = components.calendar ?? Calendar(identifier: .gregorian)
                            calendar.timeZone = components.timeZone ?? .autoupdatingCurrent
                            guard let date = calendar.date(from: components), date >= query.start, date < query.end else { return nil }
                            return .init(id: reminder.calendarItemIdentifier, title: reminder.title ?? "",
                                         source: reminder.calendar.title, start: date, end: date,
                                         isAllDay: components.hour == nil, isReminder: true)
                        }
                    }
                    // 先固定 weak 引用，避免发送给 Task 的闭包捕获可变的 self。
                    let reader = self
                    Task { await reader?.finish(id, items: items) }
                }
                pending[id] = (token, continuation)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func finish(_ id: UUID, items: [CalendarAgendaItem]?) {
        pending.removeValue(forKey: id)?.1.resume(returning: items)
    }

    private func cancel(_ id: UUID) {
        guard let (token, continuation) = pending.removeValue(forKey: id) else { return }
        store.cancelFetchRequest(token)
        continuation.resume(returning: nil)
    }
}

@MainActor
@Observable
final class CalendarAgendaController {
    private(set) var items: [CalendarAgendaItem] = []
    private(set) var eventSources: [CalendarAgendaSource] = []
    private(set) var reminderSources: [CalendarAgendaSource] = []
    private(set) var eventsAccess = EKEventStore.authorizationStatus(for: .event)
    private(set) var remindersAccess = EKEventStore.authorizationStatus(for: .reminder)
    private(set) var isLoading = false
    private(set) var isRequesting = false
    private(set) var failed = false
    var revision = 0
    @ObservationIgnored private let reader = CalendarAgendaReader()
    @ObservationIgnored private var generation = UUID()

    func refreshAuthorization() {
        eventsAccess = EKEventStore.authorizationStatus(for: .event)
        remindersAccess = EKEventStore.authorizationStatus(for: .reminder)
        revision += 1
    }

    /// 只能由明确的授权按钮调用；启用功能、导入偏好和打开日历均不自动弹出系统授权。
    func requestAccess(reminders: Bool) async {
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        do {
            let store = EKEventStore()
            if reminders { _ = try await store.requestFullAccessToReminders() }
            else { _ = try await store.requestFullAccessToEvents() }
            failed = false
        } catch { failed = true }
        refreshAuthorization()
        if reminders { reminderSources = await reader.sources(reminders: true) }
        else { eventSources = await reader.sources(reminders: false) }
    }

    func refreshSources(events: Bool, reminders: Bool) async {
        refreshAuthorization()
        eventSources = events ? await reader.sources(reminders: false) : []
        reminderSources = reminders ? await reader.sources(reminders: true) : []
    }

    func load(_ query: CalendarAgendaQuery) async {
        let current = UUID()
        generation = current
        items = []
        failed = false
        guard query.events || query.reminders else { isLoading = false; return }
        isLoading = true
        let result = await reader.load(query)
        guard generation == current, !Task.isCancelled else { return }
        items = result ?? []
        failed = result == nil
        isLoading = false
    }

    func clear() {
        generation = UUID()
        items = []
        isLoading = false
        failed = false
    }
}

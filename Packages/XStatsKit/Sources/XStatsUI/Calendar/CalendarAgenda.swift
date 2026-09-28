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

    /// 在这一天显示的时间：跨天日程从前一天延续过来时显示“续”，而不是前一天的开始时间
    func timeLabel(on date: Date, calendar: Calendar) -> String {
        if isAllDay { return tr("全天") }
        if let day = calendar.dateInterval(of: .day, for: date), start < day.start { return tr("续") }
        return start.formatted(.dateTime.hour().minute().locale(L10n.locale))
    }

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
    private var cachedStore: EKEventStore?
    private var storeAccess: (EKAuthorizationStatus, EKAuthorizationStatus)?
    private var pending: [UUID: (EKEventStore, Any, CheckedContinuation<[CalendarAgendaItem]?, Never>)] = [:]

    /// 授权变化后换用新的 store：授权前创建的实例看不到之后才获准访问的日历或提醒事项。
    /// 每次使用前按当前授权判断，不依赖调用方的通知顺序。
    private var store: EKEventStore {
        let access = (EKEventStore.authorizationStatus(for: .event), EKEventStore.authorizationStatus(for: .reminder))
        if let cachedStore, let storeAccess, storeAccess == access { return cachedStore }
        let fresh = EKEventStore()
        cachedStore = fresh
        storeAccess = access
        return fresh
    }

    func sources(reminders: Bool) -> [CalendarAgendaSource] {
        let type: EKEntityType = reminders ? .reminder : .event
        guard EKEventStore.authorizationStatus(for: type) == .fullAccess else { return [] }
        let store = self.store
        return store.calendars(for: type).map { .init(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func load(_ query: CalendarAgendaQuery) async -> [CalendarAgendaItem]? {
        guard !Task.isCancelled else { return nil }
        let store = self.store
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
                guard let reminders = await reminders(query, calendars: calendars, store: store) else { return nil }
                result += reminders
            }
        }
        return result.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
    }

    private func reminders(_ query: CalendarAgendaQuery, calendars: [EKCalendar], store: EKEventStore) async -> [CalendarAgendaItem]? {
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
                pending[id] = (store, token, continuation)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func finish(_ id: UUID, items: [CalendarAgendaItem]?) {
        pending.removeValue(forKey: id)?.2.resume(returning: items)
    }

    private func cancel(_ id: UUID) {
        guard let (store, token, continuation) = pending.removeValue(forKey: id) else { return }
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

    /// 打开面板、应用激活时调用；授权确实变化才重新查询，避免每次打开都取消刚开始的查询再重来
    func refreshAuthorization() {
        let events = EKEventStore.authorizationStatus(for: .event)
        let reminders = EKEventStore.authorizationStatus(for: .reminder)
        guard events != eventsAccess || reminders != remindersAccess else { return }
        eventsAccess = events
        remindersAccess = reminders
        revision += 1
    }

    /// 日历或提醒事项内容变化（EKEventStoreChanged）时重新查询
    func storeChanged() {
        refreshAuthorization()
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
        failed = false
        // 新结果返回前保留旧列表，刷新时日程和日期圆点不会先消失再出现；按日期过滤，跨月也不会显示错位
        guard query.events || query.reminders else { items = []; isLoading = false; return }
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

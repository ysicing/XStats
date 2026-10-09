// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import Observation

/// 协调独立护眼提醒、番茄阶段和手动护眼休息；提醒不改番茄计时，主动休息才暂停专注。
@MainActor @Observable final class WellnessController {
    private(set) var pending: Set<HealthReminderKind> = []
    private(set) var isEyeRestActive = false
    private(set) var eyeRestSecondsRemaining: TimeInterval = 0
    /// 开始护眼休息时的实际时长；番茄休息中可能缩短，不随偏好或历史清空改变。
    private(set) var eyeRestDuration: TimeInterval = 0
    private(set) var canContinueFocus = false
    private(set) var summary = WellnessSummary.make(activities: [], at: Date())
    private(set) var storageError: String?
    private(set) var nextRestAt: Date?
    private(set) var nextWake: TimeInterval?
    var onReminder: ((Set<HealthReminderKind>) -> Void)?
    var onDismissReminder: (() -> Void)?
    var onPresentationChange: ((Bool) -> Void)?
    var onStateChange: (() -> Void)?

    let settings: AppSettings
    private let rest: RestController
    private let store: WellnessActivityStore
    private let clock: () -> TimeInterval
    private let date: () -> Date
    private let schedulesTimers: Bool
    @ObservationIgnored private var schedule = HealthReminderSchedule()
    @ObservationIgnored private var deadlineTimer: Timer?
    @ObservationIgnored private var displayTimer: Timer?
    @ObservationIgnored private var scheduledWake: TimeInterval?
    @ObservationIgnored private var storageTask: Task<Void, Never>?
    @ObservationIgnored private var pendingStorage = 0
    @ObservationIgnored private var pageVisible = false
    @ObservationIgnored private var summaryDay = Calendar.current.startOfDay(for: Date())
    @ObservationIgnored private var systemPaused = false
    @ObservationIgnored private var isReconciling = false
    @ObservationIgnored private var wasPomodoroRest = false
    @ObservationIgnored private var lastPresentation = false
    @ObservationIgnored private var restDeadline: TimeInterval?
    @ObservationIgnored private var eyeRestSegmentStart: TimeInterval?
    @ObservationIgnored private var eyeRestSegmentDate: Date?
    @ObservationIgnored private var embeddedInRest = false
    @ObservationIgnored private var preview = false

    init(rest: RestController, settings: AppSettings, store: WellnessActivityStore,
         clock: @escaping () -> TimeInterval = { Double(RestClock.now()) / 1e9 },
         date: @escaping () -> Date = Date.init, schedulesTimers: Bool = true) {
        self.rest = rest; self.settings = settings; self.store = store
        self.clock = clock; self.date = date; self.schedulesTimers = schedulesTimers
        rest.onActivity = { [weak self] activity in self?.recordPomodoro(activity) }
        rest.onSessionChange = { [weak self] in self?.pomodoroChanged() }
        rest.onFocusCompletionUndo = { [weak self] in
            guard let self else { return }
            let today = Calendar.current.startOfDay(for: self.date())
            self.mutateStore { try await $0.revokeLatestFocusCompletion(since: today) }
        }
    }

    var requiresTerminationPreparation: Bool { isEyeRestActive || rest.isRunning || pendingStorage > 0 }
    var hasDisplayTimer: Bool { displayTimer != nil }
    var hasDeadlineTimer: Bool { deadlineTimer != nil }
    var isSystemPaused: Bool { systemPaused }

    private var focusBreakAt: TimeInterval? {
        rest.isRunning && rest.phase == .work ? rest.deadline.map { Double($0) / 1e9 } : nil
    }
    private var pomodoroRestRemaining: TimeInterval {
        rest.deadline.map { max(0, Double($0) / 1e9 - clock()) } ?? 0
    }

    func sync() {
        guard !preview else { return }
        schedule.configure(preferences: settings.wellnessPreferences, enabled: settings.restEnabled, at: clock())
        if !settings.restEnabled {
            onDismissReminder?()
            finishEyeRest(completed: false)
            canContinueFocus = false
        }
        refresh()
    }

    func setPageVisible(_ visible: Bool) {
        pageVisible = visible
        if visible { reloadSummary() }
        refresh()
    }

    func refresh() {
        guard !preview, !isReconciling else { return }
        guard settings.restEnabled && !systemPaused else {
            publishSchedule()
            return
        }
        // 健康和番茄截止点可能同一轮到达，先让原计时器结算，避免发出重复通知。
        if let deadline = rest.deadline, Double(deadline) / 1e9 <= clock() { rest.sync() }
        let now = clock()
        if let restDeadline, now >= restDeadline { finishEyeRest(completed: true) }
        let due = schedule.due(at: now, focusBreakAt: focusBreakAt)
        if !due.isEmpty && !(rest.phase.isResting && rest.isRunning) && !isEyeRestActive {
            onReminder?(schedule.pending)
        }
        eyeRestSecondsRemaining = restDeadline.map { max(0, $0 - now) } ?? 0
        publishSchedule()
    }

    func postpone(_ kind: HealthReminderKind) {
        schedule.postpone(kind, at: clock())
        onDismissReminder?()
        refresh()
    }

    func startShortRest() {
        guard settings.restEnabled, !isEyeRestActive, !systemPaused, !preview else { return }
        onDismissReminder?()
        pauseFocusForExercise()
        embeddedInRest = rest.phase.isResting && rest.isRunning
        let duration = Double(settings.wellnessPreferences.normalized.breakSeconds)
        eyeRestDuration = embeddedInRest ? min(duration, pomodoroRestRemaining) : duration
        restDeadline = clock() + eyeRestDuration
        eyeRestSegmentStart = clock(); eyeRestSegmentDate = date()
        isEyeRestActive = true
        refresh()
    }

    func finishEyeRest(completed: Bool) {
        guard isEyeRestActive else { return }
        recordEyeRestSegment(completed: completed)
        if completed { schedule.acknowledge(.rest, at: clock()) }
        restDeadline = nil
        isEyeRestActive = false; eyeRestSecondsRemaining = 0; eyeRestDuration = 0
        embeddedInRest = false
        publishSchedule()
    }

    func continueFocus() {
        guard canContinueFocus, !isEyeRestActive, settings.restEnabled else { return }
        canContinueFocus = false
        rest.setRunning(true)
    }

    func suspend() {
        guard !systemPaused else { return }
        systemPaused = true
        onDismissReminder?()
        finishEyeRest(completed: false)
        schedule.suspend(at: clock())
        publishSchedule()
    }

    func resume() {
        guard systemPaused else { return }
        systemPaused = false
        schedule.resume(at: clock())
        sync()
    }

    func clearHistory() {
        rest.restartActivityTracking()
        if eyeRestSegmentStart != nil {
            eyeRestSegmentStart = clock(); eyeRestSegmentDate = date()
        }
        mutateStore { try await $0.clear() }
    }

    func reloadSummary() {
        summaryDay = Calendar.current.startOfDay(for: date())
        mutateStore { _ in }
    }
    func flush() async { await storageTask?.value }

    func prepareForTermination() async {
        suspend()
        await flush()
    }

    private func pauseFocusForExercise() {
        if rest.isRunning && rest.phase == .work {
            isReconciling = true
            rest.setRunning(false)
            isReconciling = false
            canContinueFocus = true
        }
    }

    private func pomodoroChanged() {
        guard !preview, !isReconciling, !systemPaused else { return }
        isReconciling = true
        let resting = rest.phase.isResting && rest.isRunning
        if resting && !wasPomodoroRest {
            _ = schedule.mergeForBreak(at: clock())
            onDismissReminder?()
        }
        if isEyeRestActive && ((embeddedInRest && !resting) || (!embeddedInRest && rest.isRunning && rest.phase == .work)) {
            let completed = restDeadline.map { clock() >= $0 } ?? false
            finishEyeRest(completed: completed)
        }
        if wasPomodoroRest && !resting && schedule.pending.contains(.rest) { schedule.postpone(.rest, at: clock()) }
        wasPomodoroRest = resting
        if rest.isRunning || rest.phase != .work || !rest.canEndSession || (settings.restMode == .workday && !rest.isWorkdayActive) { canContinueFocus = false }
        isReconciling = false
        refresh()
    }

    private func recordPomodoro(_ activity: WellnessActivity) {
        record(activity)
        if activity.kind == .rest && activity.duration >= Double(settings.wellnessPreferences.normalized.breakSeconds) {
            schedule.acknowledge(.rest, at: clock())
        }
    }

    private func recordEyeRestSegment(completed: Bool) {
        guard let started = eyeRestSegmentStart, let date = eyeRestSegmentDate, isEyeRestActive else { return }
        let duration = max(0, min(clock(), restDeadline ?? clock()) - started)
        eyeRestSegmentStart = nil; eyeRestSegmentDate = nil
        // 同一段番茄休息已经由原计时器记录，护眼子视图不能再次计入。
        guard duration > 0, !embeddedInRest else { return }
        record(WellnessActivity(kind: .rest, startedAt: date,
                                endedAt: date.addingTimeInterval(duration), completed: completed))
    }

    private func record(_ activity: WellnessActivity) {
        let now = date()
        mutateStore { try await $0.record(activity, now: now) }
    }

    private func mutateStore(_ mutation: @escaping @Sendable (WellnessActivityStore) async throws -> Void) {
        guard !preview else { return }
        let previous = storageTask
        let store = store
        pendingStorage += 1
        // 同一控制器的记录、撤销、清空按用户动作排序，查询仅在事件或页面进入时执行。
        storageTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { self.pendingStorage -= 1 }
            do {
                try await mutation(store)
                let now = self.date()
                let since = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: now)) ?? now
                let activities = try await store.activities(since: since, now: now)
                self.summary = WellnessSummary.make(activities: activities, at: now)
                self.summaryDay = Calendar.current.startOfDay(for: now)
                self.storageError = nil
            } catch {
                self.storageError = tr("无法保存活动记录，请稍后重试。")
            }
        }
    }

    private func publishSchedule() {
        let now = clock()
        pending = schedule.pending
        nextRestAt = schedule.deadline(for: .rest, focusBreakAt: focusBreakAt).map { date().addingTimeInterval(max(0, $0 - now)) }
        let eyeRestDeadline = restDeadline
        // 只在页面可见时维护跨日统计；隐藏时不为日期切换唤醒应用。
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date()))
        let midnight = pageVisible ? tomorrow.map { now + $0.timeIntervalSince(date()) } : nil
        if pageVisible && !Calendar.current.isDate(summaryDay, inSameDayAs: date()) { reloadSummary() }
        nextWake = settings.restEnabled && !systemPaused
            ? [schedule.nextWake(focusBreakAt: focusBreakAt), eyeRestDeadline, midnight].compactMap { $0 }.min() : nil
        if schedulesTimers {
            if let nextWake {
                if scheduledWake.map({ abs($0 - nextWake) > 0.01 }) ?? true {
                    deadlineTimer?.invalidate()
                    scheduledWake = nextWake
                    deadlineTimer = Timer.scheduledTimer(withTimeInterval: max(0.01, nextWake - now), repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated { self?.scheduledWake = nil; self?.refresh() }
                    }
                    deadlineTimer?.tolerance = !isEyeRestActive ? 1 : 0.01
                }
            } else {
                deadlineTimer?.invalidate(); deadlineTimer = nil; scheduledWake = nil
            }
            // 番茄休息已有显示刷新，通过 onSessionChange 共用，不再叠加一个秒级定时器。
            let visibleCountdown = !systemPaused && isEyeRestActive && !embeddedInRest
            if visibleCountdown && displayTimer == nil {
                displayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
                displayTimer?.tolerance = 0.1
            } else if !visibleCountdown { displayTimer?.invalidate(); displayTimer = nil }
        }
        let present = isEyeRestActive && !systemPaused
        if present != lastPresentation {
            lastPresentation = present
            onPresentationChange?(present)
        }
        onStateChange?()
    }

    /// 只注入演示值，不启用提醒、计时器或写入本机活动库。
    func showPreview(activities: [WellnessActivity], at now: Date, eyeRest: Bool = false) {
        preview = true
        isEyeRestActive = eyeRest
        eyeRestDuration = eyeRest ? 60 : 0
        eyeRestSecondsRemaining = eyeRest ? 42 : 0
        summary = WellnessSummary.make(activities: activities, at: now)
        nextRestAt = now.addingTimeInterval(5 * 60)
    }
}

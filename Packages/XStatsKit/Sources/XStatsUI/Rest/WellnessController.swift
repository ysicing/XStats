// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import Observation

enum WellnessExerciseKind: Sendable { case rest, breathing }

/// 协调独立健康提醒、番茄阶段和手动练习；提醒不改番茄计时，主动休息才暂停专注。
@MainActor @Observable final class WellnessController {
    private(set) var pending: Set<HealthReminderKind> = []
    private(set) var activeExercise: WellnessExerciseKind?
    private(set) var exerciseSecondsRemaining: TimeInterval = 0
    private(set) var isExerciseRunning = false
    private(set) var canContinueFocus = false
    private(set) var summary = WellnessSummary.make(activities: [], at: Date())
    private(set) var storageError: String?
    private(set) var nextRestAt: Date?
    private(set) var nextWaterAt: Date?
    private(set) var nextWake: TimeInterval?
    private(set) var lastWaterID: UUID?
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
    @ObservationIgnored private var breathing: BreathingSession?
    @ObservationIgnored private var restDeadline: TimeInterval?
    @ObservationIgnored private var exerciseSegmentStart: TimeInterval?
    @ObservationIgnored private var exerciseSegmentDate: Date?
    @ObservationIgnored private var exerciseSegmentLimit: TimeInterval = 0
    @ObservationIgnored private var embeddedInRest = false
    @ObservationIgnored private var preview = false
    @ObservationIgnored private var previewReading: BreathingReading?

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

    var requiresTerminationPreparation: Bool { activeExercise != nil || rest.isRunning || pendingStorage > 0 }
    var hasDisplayTimer: Bool { displayTimer != nil }
    var hasDeadlineTimer: Bool { deadlineTimer != nil }
    var isSystemPaused: Bool { systemPaused }
    var breathingReading: BreathingReading? { previewReading ?? breathing?.reading(at: clock()) }

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
            finishExercise(completed: false)
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
        if let breathing, breathing.reading(at: now).isFinished { finishExercise(completed: true) }
        if let restDeadline, now >= restDeadline { finishExercise(completed: true) }
        let due = schedule.due(at: now, focusBreakAt: focusBreakAt)
        if !due.isEmpty && !(rest.phase.isResting && rest.isRunning) && activeExercise == nil {
            onReminder?(schedule.pending)
        }
        exerciseSecondsRemaining = breathing?.reading(at: now).secondsRemaining
            ?? restDeadline.map { max(0, $0 - now) } ?? 0
        isExerciseRunning = breathing?.isRunning ?? (restDeadline != nil)
        publishSchedule()
    }

    func recordWater() {
        guard settings.restEnabled && !preview else { return }
        let now = date()
        let activity = WellnessActivity(kind: .water, startedAt: now, endedAt: now, completed: true)
        lastWaterID = activity.id
        record(activity)
        schedule.acknowledge(.water, at: clock())
        onDismissReminder?()
        refresh()
    }

    func undoWater() {
        guard let id = lastWaterID else { return }
        lastWaterID = nil
        mutateStore { try await $0.remove(id) }
    }

    func postpone(_ kind: HealthReminderKind) {
        schedule.postpone(kind, at: clock())
        onDismissReminder?()
        refresh()
    }

    func startShortRest() {
        guard settings.restEnabled, activeExercise == nil, !systemPaused, !preview else { return }
        onDismissReminder?()
        pauseFocusForExercise()
        embeddedInRest = rest.phase.isResting && rest.isRunning
        let duration = Double(settings.wellnessPreferences.normalized.breakSeconds)
        restDeadline = clock() + (embeddedInRest ? min(duration, pomodoroRestRemaining) : duration)
        exerciseSegmentStart = clock(); exerciseSegmentDate = date()
        activeExercise = .rest
        refresh()
    }

    func startBreathing() {
        guard settings.restEnabled, activeExercise == nil, !systemPaused, !preview else { return }
        onDismissReminder?()
        pauseFocusForExercise()
        embeddedInRest = rest.phase.isResting && rest.isRunning
        let preferences = settings.wellnessPreferences.normalized
        let duration = Double(preferences.breathingMinutes) * 60
        let actualDuration = embeddedInRest ? min(duration, pomodoroRestRemaining) : duration
        breathing = BreathingSession(now: clock(), duration: actualDuration,
                                     pattern: preferences.breathingPattern)
        exerciseSegmentLimit = actualDuration
        exerciseSegmentStart = clock(); exerciseSegmentDate = date()
        activeExercise = .breathing
        refresh()
    }

    func toggleBreathingPause() {
        guard var breathing else { return }
        if breathing.isRunning {
            recordExerciseSegment(completed: false)
            breathing.pause(at: clock())
        } else {
            breathing.resume(at: clock())
            exerciseSegmentStart = clock(); exerciseSegmentDate = date()
            exerciseSegmentLimit = breathing.reading(at: clock()).secondsRemaining
        }
        self.breathing = breathing
        refresh()
    }

    func finishExercise(completed: Bool) {
        guard activeExercise != nil else { return }
        recordExerciseSegment(completed: completed)
        if completed { schedule.acknowledge(.rest, at: clock()) }
        breathing = nil; restDeadline = nil
        activeExercise = nil; exerciseSecondsRemaining = 0; isExerciseRunning = false
        embeddedInRest = false
        publishSchedule()
    }

    func continueFocus() {
        guard canContinueFocus, activeExercise == nil, settings.restEnabled else { return }
        canContinueFocus = false
        rest.setRunning(true)
    }

    func suspend() {
        guard !systemPaused else { return }
        systemPaused = true
        onDismissReminder?()
        finishExercise(completed: false)
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
        if exerciseSegmentStart != nil {
            exerciseSegmentStart = clock(); exerciseSegmentDate = date()
            exerciseSegmentLimit = breathingReading?.secondsRemaining ?? 0
        }
        lastWaterID = nil
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
        if activeExercise != nil && ((embeddedInRest && !resting) || (!embeddedInRest && rest.isRunning && rest.phase == .work)) {
            let completed = breathing?.reading(at: clock()).isFinished ?? restDeadline.map { clock() >= $0 } ?? false
            finishExercise(completed: completed)
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

    private func recordExerciseSegment(completed: Bool) {
        guard let started = exerciseSegmentStart, let date = exerciseSegmentDate, let kind = activeExercise else { return }
        let end = kind == .rest ? min(clock(), restDeadline ?? clock()) : clock()
        let duration = max(0, kind == .breathing ? min(end - started, exerciseSegmentLimit) : end - started)
        exerciseSegmentStart = nil; exerciseSegmentDate = nil
        guard duration > 0 else { return }
        var activity = WellnessActivity(kind: kind == .rest ? .rest : .breathing, startedAt: date,
                                        endedAt: date.addingTimeInterval(duration), completed: completed)
        if embeddedInRest { activity.isPartOfRest = true }
        // 番茄幕布已记录同一段休息，短休子视图不能再写一条重复休息。
        if kind != .rest || !embeddedInRest { record(activity) }
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
                self.storageError = tr("无法保存健康记录，请稍后重试。")
            }
        }
    }

    private func publishSchedule() {
        let now = clock()
        pending = schedule.pending
        nextRestAt = schedule.deadline(for: .rest, focusBreakAt: focusBreakAt).map { date().addingTimeInterval(max(0, $0 - now)) }
        nextWaterAt = schedule.deadline(for: .water, focusBreakAt: focusBreakAt).map { date().addingTimeInterval(max(0, $0 - now)) }
        let exerciseDeadline = breathing?.nextPhaseDeadline(at: now) ?? restDeadline
        // 只在页面可见时维护跨日统计；隐藏时不为日期切换唤醒应用。
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date()))
        let midnight = pageVisible ? tomorrow.map { now + $0.timeIntervalSince(date()) } : nil
        if pageVisible && !Calendar.current.isDate(summaryDay, inSameDayAs: date()) { reloadSummary() }
        nextWake = settings.restEnabled && !systemPaused
            ? [schedule.nextWake(focusBreakAt: focusBreakAt), exerciseDeadline, midnight].compactMap { $0 }.min() : nil
        if schedulesTimers {
            if let nextWake {
                if scheduledWake.map({ abs($0 - nextWake) > 0.01 }) ?? true {
                    deadlineTimer?.invalidate()
                    scheduledWake = nextWake
                    deadlineTimer = Timer.scheduledTimer(withTimeInterval: max(0.01, nextWake - now), repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated { self?.scheduledWake = nil; self?.refresh() }
                    }
                    deadlineTimer?.tolerance = activeExercise == nil ? 1 : 0.01
                }
            } else {
                deadlineTimer?.invalidate(); deadlineTimer = nil; scheduledWake = nil
            }
            // 番茄休息已有显示刷新，通过 onSessionChange 共用，不再叠加一个秒级定时器。
            let visibleCountdown = !systemPaused && activeExercise != nil && isExerciseRunning && !embeddedInRest
            if visibleCountdown && displayTimer == nil {
                displayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
                displayTimer?.tolerance = 0.1
            } else if !visibleCountdown { displayTimer?.invalidate(); displayTimer = nil }
        }
        let present = activeExercise != nil && !systemPaused
        if present != lastPresentation {
            lastPresentation = present
            onPresentationChange?(present)
        }
        onStateChange?()
    }

    /// 只注入演示值，不启用提醒、计时器或写入本机活动库。
    func showPreview(activities: [WellnessActivity], at now: Date, exercise: WellnessExerciseKind? = nil) {
        preview = true
        lastWaterID = activities.last(where: { $0.kind == .water })?.id
        activeExercise = exercise
        isExerciseRunning = exercise != nil
        exerciseSecondsRemaining = 178
        previewReading = exercise == .breathing ? BreathingSession(now: 0, duration: 180, pattern: .gentle).reading(at: 1.8) : nil
        summary = WellnessSummary.make(activities: activities, at: now)
        nextRestAt = now.addingTimeInterval(5 * 60)
        nextWaterAt = now.addingTimeInterval(35 * 60)
    }
}

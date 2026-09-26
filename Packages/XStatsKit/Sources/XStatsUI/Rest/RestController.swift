// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Darwin
import Foundation
import Localization
import Observation
import WidgetKit

/// mach_continuous_time 包含系统睡眠，和界面刷新次数无关。
enum RestClock {
    static func now() -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = mach_continuous_time()
        return UInt64(info.denom).dividingFullWidth(
            ticks.multipliedFullWidth(by: UInt64(info.numer))).quotient
    }
}

enum RestPhase: String, CaseIterable, Identifiable {
    case work, rest, longRest
    var id: String { rawValue }
    var isResting: Bool { self != .work }
}

/// 运行阶段按硬件绝对截止点计时；暂停时分别保存各阶段剩余时间。
struct RestSession {
    var phase: RestPhase = .work
    var deadline: UInt64
    private(set) var phaseDuration: UInt64
    private(set) var isRunning = false
    private(set) var completedFocus = 0
    private var pausedRemaining: UInt64
    private var remainingByPhase: [RestPhase: UInt64]
    private var activeDurationByPhase: [RestPhase: UInt64]
    private var canUndoFocus = false
    let workNanoseconds: UInt64
    let restNanoseconds: UInt64
    let longRestNanoseconds: UInt64

    init(now: UInt64, workMinutes: Int, restMinutes: Int, longBreakMinutes: Int = 15,
         completedFocus: Int = 0) {
        workNanoseconds = UInt64(max(1, workMinutes)) * 60_000_000_000
        restNanoseconds = UInt64(max(1, restMinutes)) * 60_000_000_000
        longRestNanoseconds = UInt64(max(1, longBreakMinutes)) * 60_000_000_000
        phaseDuration = workNanoseconds
        pausedRemaining = workNanoseconds
        remainingByPhase = [.work: workNanoseconds, .rest: restNanoseconds, .longRest: longRestNanoseconds]
        activeDurationByPhase = remainingByPhase
        deadline = now + workNanoseconds
        self.completedFocus = completedFocus
    }

    func remaining(at now: UInt64) -> TimeInterval {
        let value = isRunning ? (deadline > now ? deadline - now : 0) : pausedRemaining
        return TimeInterval(value) / 1_000_000_000
    }

    var canContinue: Bool { !isRunning && pausedRemaining > 0 && pausedRemaining < phaseDuration }

    /// “开始”从完整时长起步；已有进度显示为“继续”，从暂停处恢复。
    mutating func startOrContinue(at now: UInt64) {
        if !canContinue { resetCurrentPhase(at: now) }
        resume(at: now)
    }

    mutating func resume(at now: UInt64) {
        guard !isRunning else { return }
        deadline = now + pausedRemaining
        isRunning = true
    }

    mutating func pause(at now: UInt64) {
        guard isRunning else { return }
        pausedRemaining = deadline > now ? deadline - now : 0
        remainingByPhase[phase] = pausedRemaining
        isRunning = false
    }

    /// 手动切换保存运行中或已暂停阶段的进度；同一阶段再次点击不等于重置。
    mutating func select(_ selected: RestPhase, at now: UInt64) {
        guard selected != phase else { return }
        if isRunning { pausedRemaining = deadline > now ? deadline - now : 0 }
        remainingByPhase[phase] = pausedRemaining
        phase = selected
        phaseDuration = activeDurationByPhase[selected] ?? duration(for: selected)
        pausedRemaining = remainingByPhase[selected] ?? phaseDuration
        deadline = now + pausedRemaining
        isRunning = false
        canUndoFocus = false
    }

    mutating func resetCurrentPhase(at now: UInt64) {
        phaseDuration = duration(for: phase)
        pausedRemaining = phaseDuration
        remainingByPhase[phase] = phaseDuration
        activeDurationByPhase[phase] = phaseDuration
        deadline = now + phaseDuration
        isRunning = false
        canUndoFocus = false
    }

    /// 睡眠后可跨越多个阶段；单次模式在一次休息结束后停在下一轮专注起点。
    @discardableResult mutating func advance(to now: UInt64, cycle: Bool = false) -> [UInt64] {
        guard isRunning else { return [] }
        var completedAt: [UInt64] = []
        while now >= deadline {
            let reached = deadline
            remainingByPhase[phase] = duration(for: phase)
            activeDurationByPhase[phase] = duration(for: phase)
            if phase == .work {
                completedFocus += 1
                completedAt.append(reached)
                canUndoFocus = true
                phase = completedFocus.isMultiple(of: 4) ? .longRest : .rest
            } else {
                phase = .work
                canUndoFocus = false
            }
            phaseDuration = duration(for: phase)
            pausedRemaining = phaseDuration
            remainingByPhase[phase] = phaseDuration
            activeDurationByPhase[phase] = phaseDuration
            deadline = reached + phaseDuration
            if phase == .work && !cycle {
                isRunning = false
                deadline = now + phaseDuration
                break
            }
        }
        return completedAt
    }

    mutating func skip(at now: UInt64) {
        remainingByPhase[phase] = duration(for: phase)
        activeDurationByPhase[phase] = duration(for: phase)
        phase = phase.isResting ? .work : .rest
        phaseDuration = duration(for: phase)
        pausedRemaining = phaseDuration
        remainingByPhase[phase] = phaseDuration
        activeDurationByPhase[phase] = phaseDuration
        deadline = now + phaseDuration
        isRunning = true
        canUndoFocus = false
    }

    mutating func postponeFocus(at now: UInt64) {
        guard phase.isResting else { return }
        remainingByPhase[phase] = duration(for: phase)
        activeDurationByPhase[phase] = duration(for: phase)
        if canUndoFocus { completedFocus = max(0, completedFocus - 1) }
        canUndoFocus = false
        phase = .work
        phaseDuration = 5 * 60_000_000_000
        pausedRemaining = phaseDuration
        remainingByPhase[phase] = phaseDuration
        activeDurationByPhase[phase] = phaseDuration
        deadline = now + phaseDuration
        isRunning = true
    }

    private func duration(for phase: RestPhase) -> UInt64 {
        switch phase {
        case .work: workNanoseconds
        case .rest: restNanoseconds
        case .longRest: longRestNanoseconds
        }
    }
}

@MainActor @Observable
final class RestController {
    private(set) var phase: RestPhase = .work
    private(set) var isRunning = false
    private(set) var isWorkdayActive = false
    private(set) var canContinue = false
    private(set) var secondsRemaining: TimeInterval = 0
    private(set) var phaseDuration: TimeInterval = 0
    private(set) var completedToday: Int

    private var session: RestSession?
    private var displayTimer: Timer?
    private var deadlineTimer: Timer?
    private var scheduledDeadline: UInt64?
    private var hudVisible = false
    private var pageVisible = false
    private var menuBarVisible = false
    private var restVisible = false
    private var suspendedAt: UInt64?
    private var lastFocusCredited = false
    private var lastSharedDeadline: UInt64?
    private var lastSharedRunning: Bool?
    private var lastSharedPhase: RestPhase?
    private var lastSharedLanguage: AppLanguage?
    private let audio = RestSoundPlayer()
    private let localDefaults: UserDefaults
    private let defaults: UserDefaults?
    private let clock: () -> UInt64
    /// 墙上时间只用于按自然日统计；计时仍以 clock 的单调时钟为准。
    private let date: () -> Date
    var onRestChange: ((Bool) -> Void)?
    var onStateChange: (() -> Void)?
    let settings: AppSettings

    init(settings: AppSettings, localDefaults: UserDefaults = .standard,
         sharedDefaults: UserDefaults? = UserDefaults(suiteName: "group.work.12306.xstats"),
         clock: @escaping () -> UInt64 = { RestClock.now() },
         date: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.localDefaults = localDefaults
        defaults = sharedDefaults
        self.clock = clock
        self.date = date
        let today = Self.todayKey(for: date())
        completedToday = localDefaults.string(forKey: "rest.day") == today
            ? localDefaults.integer(forKey: "rest.completedToday") : 0
    }

    func sync() {
        guard settings.restEnabled else { stop(); return }
        refreshDay()
        if session == nil {
            session = RestSession(now: clock(), workMinutes: settings.restWorkMinutes,
                                  restMinutes: settings.restBreakMinutes,
                                  longBreakMinutes: settings.restLongBreakMinutes)
        }
        refresh()
    }

    func setHUDVisible(_ visible: Bool) {
        hudVisible = visible
        updateDisplayTimer()
        if visible { refresh() }
    }

    func setPageVisible(_ visible: Bool) {
        pageVisible = visible
        updateDisplayTimer()
        if visible { refresh() }
    }

    func setMenuBarVisible(_ visible: Bool) {
        menuBarVisible = visible
        updateDisplayTimer()
    }

    func startPause() {
        guard settings.restEnabled else { return }
        if settings.restMode == .workday && !isWorkdayActive {
            startWorkday()
            return
        }
        settleExpiredSession()
        guard var session else { return }
        let now = clock()
        if session.isRunning {
            session.pause(at: now)
        } else {
            session.startOrContinue(at: now)
        }
        self.session = session
        refresh()
    }

    /// 工作时段必须由用户开始；开始时从完整的第一轮专注计时。
    private func startWorkday() {
        let now = clock()
        var session = RestSession(now: now, workMinutes: settings.restWorkMinutes,
                                  restMinutes: settings.restBreakMinutes,
                                  longBreakMinutes: settings.restLongBreakMinutes)
        session.startOrContinue(at: now)
        self.session = session
        isWorkdayActive = true
        suspendedAt = nil
        lastFocusCredited = false
        refresh()
    }

    func endWorkday() {
        guard settings.restMode == .workday, isWorkdayActive else { return }
        settleExpiredSession()
        isWorkdayActive = false
        suspendedAt = nil
        lastFocusCredited = false
        session = RestSession(now: clock(), workMinutes: settings.restWorkMinutes,
                              restMinutes: settings.restBreakMinutes,
                              longBreakMinutes: settings.restLongBreakMinutes)
        refresh()
    }

    /// 改运行方式只暂停当前阶段并保留剩余时间；工作时段只能显式结束。
    func modeDidChange() {
        settleExpiredSession()
        if var session {
            session.pause(at: clock())
            self.session = session
        }
        refresh()
    }

    func selectPhase(_ selected: RestPhase) {
        settleExpiredSession()
        guard var session else { return }
        session.select(selected, at: clock())
        self.session = session
        refresh()
    }

    func resetCurrentPhase() {
        settleExpiredSession()
        guard var session else { return }
        session.resetCurrentPhase(at: clock())
        self.session = session
        refresh()
    }

    func restart() {
        settleExpiredSession()
        let completedFocus = isWorkdayActive ? session?.completedFocus ?? 0 : 0
        suspendedAt = nil
        lastFocusCredited = false
        session = RestSession(now: clock(), workMinutes: settings.restWorkMinutes,
                              restMinutes: settings.restBreakMinutes,
                              longBreakMinutes: settings.restLongBreakMinutes,
                              completedFocus: completedFocus)
        sync()
    }

    func skip() {
        guard settings.restMode != .workday || isWorkdayActive else { return }
        settleExpiredSession()
        guard var session else { return }
        session.skip(at: clock())
        self.session = session
        refresh()
    }

    func postponeFiveMinutes() {
        settleExpiredSession()
        guard var session else { return }
        let previousCount = session.completedFocus
        session.postponeFocus(at: clock())
        if session.completedFocus < previousCount && lastFocusCredited { updateCompletedToday(by: -1) }
        lastFocusCredited = false
        self.session = session
        refresh()
    }

    /// 手动操作可能抢在延迟的 Timer 回调前到达；先结算已过截止点，避免吞掉完成事件。
    private func settleExpiredSession() {
        guard let session, session.isRunning, clock() >= session.deadline else { return }
        refresh()
    }

    private func refresh() {
        guard var session else { return }
        refreshDay()
        let now = clock()
        let continuesAutomatically = settings.restMode == .cycle
            || (settings.restMode == .workday && isWorkdayActive)
        let completedAt = session.advance(to: now, cycle: continuesAutomatically)
        let nowDate = date()
        let today = Calendar.current.startOfDay(for: nowDate)
        let credited = completedAt.filter { completion in
            let date = nowDate.addingTimeInterval(-TimeInterval(now - completion) / 1_000_000_000)
            let awake = suspendedAt.map { completion <= $0 } ?? true
            return awake && date >= today
        }
        if let last = completedAt.last { lastFocusCredited = credited.contains(last) }
        updateCompletedToday(by: credited.count)
        suspendedAt = nil
        self.session = session
        phase = session.phase
        isRunning = session.isRunning
        canContinue = session.canContinue
        secondsRemaining = session.remaining(at: now)
        phaseDuration = TimeInterval(session.phaseDuration) / 1_000_000_000

        if session.isRunning && scheduledDeadline != session.deadline {
            deadlineTimer?.invalidate()
            scheduledDeadline = session.deadline
            deadlineTimer = Timer.scheduledTimer(withTimeInterval: max(0.001, secondsRemaining), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // 系统若在截止点前触发 Timer，重新按硬件截止点调度。
                    self.scheduledDeadline = nil
                    self.deadlineTimer = nil
                    self.refresh()
                }
            }
            deadlineTimer?.tolerance = 0.001
        } else if !session.isRunning {
            deadlineTimer?.invalidate()
            deadlineTimer = nil
            scheduledDeadline = nil
        }

        let shouldShowRest = session.phase.isResting && session.isRunning
        if restVisible != shouldShowRest {
            restVisible = shouldShowRest
            onRestChange?(shouldShowRest)
        }
        updateDisplayTimer()
        syncSound()
        onStateChange?()

        // 截止点或状态变化时才更新 Widget 共享值，避免每秒磁盘写入。
        if lastSharedDeadline != session.deadline || lastSharedRunning != session.isRunning
            || lastSharedPhase != session.phase || lastSharedLanguage != settings.language {
            defaults?.set(settings.restEnabled, forKey: "rest.enabled")
            defaults?.set(session.phase.rawValue, forKey: "rest.phase")
            defaults?.set(session.isRunning, forKey: "rest.running")
            defaults?.set(secondsRemaining, forKey: "rest.remaining")
            defaults?.set(date().addingTimeInterval(secondsRemaining).timeIntervalSince1970, forKey: "rest.deadline")
            defaults?.set(phaseDuration, forKey: "rest.duration")
            defaults?.set(settings.language.rawValue, forKey: "rest.language")
            lastSharedDeadline = session.deadline
            lastSharedRunning = session.isRunning
            lastSharedPhase = session.phase
            lastSharedLanguage = settings.language
            WidgetCenter.shared.reloadTimelines(ofKind: "rest")
        }
    }

    private func updateDisplayTimer() {
        let needsUpdates = settings.restEnabled && isRunning && (restVisible || hudVisible || pageVisible || menuBarVisible)
        if needsUpdates && displayTimer == nil {
            displayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            displayTimer?.tolerance = 0.1
        } else if !needsUpdates {
            displayTimer?.invalidate()
            displayTimer = nil
        }
    }

    func stop() {
        suspend()
        session = nil
        isWorkdayActive = false
        suspendedAt = nil
        lastFocusCredited = false
        lastSharedDeadline = nil
        secondsRemaining = 0
        isRunning = false
        canContinue = false
        if restVisible { onRestChange?(false) }
        restVisible = false
        phase = .work
        onStateChange?()
        defaults?.set(false, forKey: "rest.enabled")
        WidgetCenter.shared.reloadTimelines(ofKind: "rest")
    }

    func suspend() {
        // 屏幕休眠与系统睡眠会先后到达，保留最早的暂停时刻，之后完成的专注都不计入。
        if session?.isRunning == true { suspendedAt = suspendedAt ?? clock() }
        displayTimer?.invalidate()
        displayTimer = nil
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        scheduledDeadline = nil
        audio.stop()
    }

    func prepareForTermination() {
        let remaining = session?.remaining(at: clock()) ?? secondsRemaining
        suspend()
        defaults?.set(false, forKey: "rest.running")
        defaults?.set(remaining, forKey: "rest.remaining")
        WidgetCenter.shared.reloadTimelines(ofKind: "rest")
    }

    func syncSound() {
        if settings.restEnabled && isRunning && phase.isResting {
            audio.play(settings.restSound)
        } else {
            audio.stop()
        }
    }

    private func refreshDay() {
        let today = Self.todayKey(for: date())
        guard localDefaults.string(forKey: "rest.day") != today else { return }
        completedToday = 0
        localDefaults.set(today, forKey: "rest.day")
        localDefaults.set(0, forKey: "rest.completedToday")
    }

    private func updateCompletedToday(by count: Int) {
        guard count != 0 else { return }
        completedToday = max(0, completedToday + count)
        localDefaults.set(completedToday, forKey: "rest.completedToday")
    }

    private static func todayKey(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}

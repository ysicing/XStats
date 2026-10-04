// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import AudioControl
import Foundation
import Observation

/// 设备事件驱动刷新；关闭界面后仅保留已修改音量所需的应用检测与实时处理。
@MainActor @Observable
final class AudioController {
    private(set) var snapshot = AudioHardwareSnapshot.empty
    private(set) var hasPermission: Bool
    private(set) var isWorking = false
    private var operationError: AudioControlError?
    private var mixingError: AudioControlError?
    var error: AudioControlError? { operationError ?? mixingError }
    private(set) var volumes: [String: AudioAppVolume]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let hardware = AudioHardwareClient()
    @ObservationIgnored private let mixer = AudioMixerClient()
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var menuVisible = false
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var mixTask: Task<Void, Never>?
    @ObservationIgnored private var deviceVolumeTask: Task<Void, Never>?
    @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []

    var output: AudioDeviceInfo? { snapshot.devices.first { $0.id == snapshot.outputID } }
    var input: AudioDeviceInfo? { snapshot.devices.first { $0.id == snapshot.inputID } }
    var supportsMixing: Bool { AudioMixerClient.isSupported }
    private var hasSavedAdjustments: Bool { volumes.values.contains(where: \.needsProcessing) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasPermission = defaults.bool(forKey: "audio.captureAuthorized")
        let decoded = defaults.data(forKey: "audio.applicationVolumes")
            .flatMap { data -> [String: AudioAppVolume]? in
                guard data.count <= 262_144 else { return nil }
                return try? JSONDecoder().decode([String: AudioAppVolume].self, from: data)
            } ?? [:]
        volumes = Dictionary(uniqueKeysWithValues: decoded.sorted { $0.key < $1.key }.prefix(256).compactMap { key, value in
            guard !key.hasPrefix("pid:"), key.count <= 512, let checked = AudioAppVolume(level: value.level, isMuted: value.isMuted), checked.needsProcessing else { return nil }
            return (key, checked)
        })
    }

    func volume(for app: AudioApplication) -> AudioAppVolume { volumes[app.id] ?? AudioAppVolume(level: 1)! }

    func setDemand(enabled: Bool, visible: Bool, menuVisible: Bool) {
        guard self.enabled != enabled || self.visible != visible || self.menuVisible != menuVisible else { return }
        self.enabled = enabled
        self.visible = visible
        self.menuVisible = menuVisible
        revision &+= 1
        deviceVolumeTask?.cancel()
        updateWatchers()
    }

    private func updateWatchers() {
        refreshTask?.cancel()
        let epoch = revision
        if !enabled || sleeping {
            hardware.stopWatching()
            mixTask?.cancel()
            Task { [weak self] in
                guard let self, revision == epoch else { return }
                await mixer.stop()
            }
            if !enabled { snapshot = .empty; removeSleepObservers() }
            return
        }
        installSleepObservers()
        let watchesApps = visible || (hasPermission && hasSavedAdjustments)
        if visible || menuVisible || watchesApps {
            hardware.watch(applications: watchesApps) { [weak self] in
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            }
            scheduleRefresh(immediate: true)
        } else {
            hardware.stopWatching()
            Task { [weak self] in
                guard let self, revision == epoch else { return }
                await mixer.stop()
            }
        }
    }

    private func scheduleRefresh(immediate: Bool = false) {
        guard enabled, !sleeping else { return }
        refreshTask?.cancel()
        let epoch = revision
        refreshTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(80), tolerance: .milliseconds(20)) }
            guard let self, !Task.isCancelled, revision == epoch, enabled, !sleeping else { return }
            let updated = await hardware.snapshot(includeApplications: visible || (hasPermission && hasSavedAdjustments))
            guard !Task.isCancelled, revision == epoch, enabled, !sleeping else { return }
            snapshot = updated
            let currentIDs = Set(updated.applications.map(\.id))
            volumes = volumes.filter { !$0.key.hasPrefix("pid:") || currentIDs.contains($0.key) }
            if !isWorking { reconcile() }
        }
    }

    func authorizeMixing() {
        guard enabled, supportsMixing, !isWorking else { return }
        isWorking = true
        operationError = nil
        let epoch = revision
        Task { [weak self] in
            guard let self else { return }
            do {
                try await mixer.requestAccess()
                guard revision == epoch, enabled else { isWorking = false; return }
                mixingError = nil
                hasPermission = true
                defaults.set(true, forKey: "audio.captureAuthorized")
                isWorking = false
                updateWatchers()
            } catch {
                guard revision == epoch else { isWorking = false; return }
                isWorking = false
                self.operationError = error as? AudioControlError ?? .unavailable
            }
        }
    }

    func setAppLevel(_ level: Double, app: AudioApplication) {
        guard enabled, !sleeping, !isWorking, hasPermission, supportsMixing, let volume = AudioAppVolume(level: level) else { return }
        operationError = nil
        save(volume, for: app.id)
        reconcile()
    }

    func toggleAppMute(_ app: AudioApplication) {
        guard enabled, !sleeping, !isWorking, hasPermission, supportsMixing else { return }
        var volume = volume(for: app)
        volume.isMuted.toggle()
        operationError = nil
        save(volume, for: app.id)
        reconcile()
    }

    func resetApp(_ app: AudioApplication) {
        guard enabled, !sleeping, !isWorking else { return }
        operationError = nil
        volumes.removeValue(forKey: app.id)
        persist()
        reconcile()
        updateWatchers()
    }

    private func save(_ volume: AudioAppVolume, for id: String) {
        guard id.count <= 512, volumes[id] != nil || volumes.count < 256 else { return }
        if volume.needsProcessing { volumes[id] = volume } else { volumes.removeValue(forKey: id) }
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(volumes.filter { !$0.key.hasPrefix("pid:") }), forKey: "audio.applicationVolumes")
    }

    private func reconcile() {
        mixTask?.cancel()
        let epoch = revision
        let targets = enabled && !sleeping && hasPermission ? snapshot.applications.compactMap { app -> AudioMixTarget? in
            let volume = volume(for: app)
            return volume.needsProcessing ? AudioMixTarget(id: app.id, processObjectIDs: app.processObjectIDs, volume: volume) : nil
        } : []
        let uid = output?.uid
        mixTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                if supportsMixing { try await mixer.apply(targets, outputUID: uid) }
                guard !Task.isCancelled, revision == epoch else { return }
                mixingError = nil
            } catch {
                guard !Task.isCancelled, revision == epoch else { return }
                self.mixingError = error as? AudioControlError ?? .unavailable
                if self.mixingError == .permissionRequired {
                    hasPermission = false
                    defaults.set(false, forKey: "audio.captureAuthorized")
                }
            }
        }
    }

    func setDeviceLevel(_ level: Double, direction: AudioDirection) {
        guard enabled, !sleeping, !isWorking, let device = direction == .output ? output : input else { return }
        deviceVolumeTask?.cancel()
        let epoch = revision
        deviceVolumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(25))
            guard let self, !Task.isCancelled, revision == epoch else { return }
            do {
                try await hardware.setVolume(level, device: device, direction: direction)
                if level > 0, (direction == .output ? device.outputMuted : device.inputMuted) == true {
                    try await hardware.setMuted(false, device: device, direction: direction)
                }
                guard !Task.isCancelled, revision == epoch else { return }
                operationError = nil
            } catch {
                guard !Task.isCancelled, revision == epoch else { return }
                self.operationError = error as? AudioControlError ?? .unavailable
            }
            scheduleRefresh(immediate: true)
        }
    }

    func toggleDeviceMute(_ direction: AudioDirection) {
        guard !isWorking, let device = direction == .output ? output : input else { return }
        let muted = direction == .output ? device.outputMuted : device.inputMuted
        guard let muted else { return }
        perform { [hardware] in try await hardware.setMuted(!muted, device: device, direction: direction) }
    }

    func selectDevice(_ id: UInt32, direction: AudioDirection) {
        guard !isWorking, let device = snapshot.devices.first(where: { $0.id == id }) else { return }
        guard device.id != (direction == .output ? snapshot.outputID : snapshot.inputID) else { return }
        perform { [weak self] in
            guard let self else { return }
            let guardTap = direction == .output ? try await mixer.prepareOutputSwitch() : nil
            guard enabled, !sleeping else { await mixer.finishOutputSwitch(guardTap); return }
            do {
                try await hardware.select(device, direction: direction)
                snapshot = await hardware.snapshot(includeApplications: hasPermission && hasSavedAdjustments || visible)
                let targets = hasPermission ? snapshot.applications.compactMap { app -> AudioMixTarget? in
                    let volume = volume(for: app)
                    return volume.needsProcessing ? AudioMixTarget(id: app.id, processObjectIDs: app.processObjectIDs, volume: volume) : nil
                } : []
                if direction == .output, supportsMixing, enabled, !sleeping { try await mixer.apply(targets, outputUID: output?.uid) }
                guard enabled, !sleeping else { await mixer.stop(); await mixer.finishOutputSwitch(guardTap); return }
                await mixer.finishOutputSwitch(guardTap)
            } catch {
                // 写设备失败时，先尝试恢复当前输出上的音量，之后才释放过渡静音。
                if enabled, !sleeping, supportsMixing {
                    snapshot = await hardware.snapshot(includeApplications: hasPermission)
                    let targets = snapshot.applications.compactMap { app -> AudioMixTarget? in
                        let volume = volume(for: app)
                        return volume.needsProcessing ? AudioMixTarget(id: app.id, processObjectIDs: app.processObjectIDs, volume: volume) : nil
                    }
                    try? await mixer.apply(targets, outputUID: output?.uid)
                }
                await mixer.finishOutputSwitch(guardTap)
                throw error
            }
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard enabled, !sleeping else { return }
        isWorking = true
        operationError = nil
        let epoch = revision
        deviceVolumeTask?.cancel()
        mixTask?.cancel()
        Task { [weak self] in
            guard let self, revision == epoch, enabled, !sleeping else { self?.isWorking = false; return }
            do { try await operation() }
            catch { if revision == epoch { self.operationError = error as? AudioControlError ?? .unavailable } }
            isWorking = false
            scheduleRefresh(immediate: true)
        }
    }

    private func installSleepObservers() {
        guard sleepObservers.isEmpty else { return }
        for (name, sleep) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sleeping = sleep
                    self.revision &+= 1
                    self.updateWatchers()
                }
            }
            sleepObservers.append(observer)
        }
    }

    private func removeSleepObservers() {
        for observer in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        sleepObservers.removeAll()
    }

    func stop() {
        enabled = false
        revision &+= 1
        refreshTask?.cancel()
        mixTask?.cancel()
        deviceVolumeTask?.cancel()
        removeSleepObservers()
        hardware.stopWatching()
        Task { await mixer.stop() }
    }
}

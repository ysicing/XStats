// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import CoreAudio
import Foundation
import Localization

public enum RestSound: String, CaseIterable, Identifiable, Sendable {
    case off, rain, stream, wind, pink, white, custom
    public var id: String { rawValue }
    var title: String {
        switch self {
        case .off: tr("关闭")
        case .white: tr("白噪音")
        case .pink: tr("粉红噪音")
        case .rain: tr("轻雨")
        case .stream: tr("溪流")
        case .wind: tr("风声")
        case .custom: tr("自定义音频")
        }
    }
}

/// 实时生成采样，无文件、下载或麦克风访问。render block 内不分配内存，也不访问 UI 状态。
@MainActor
final class RestSoundPlayer {
    private var engine: AVAudioEngine?
    private var customPlayer: AVAudioPlayer?
    private var customURL: URL?
    private(set) var playing: RestSound = .off
    /// 启动失败后短暂冷却；调用方每秒同步一次，不能每秒重建引擎。
    private var failed: RestSound?
    private var retryAfter: UInt64?
    private var configurationObserver: NSObjectProtocol?
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?
    private let outputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private let startEngine: (AVAudioEngine) throws -> Void
    private let clock: () -> UInt64
    private let startCustomPlayer: (AVAudioPlayer) -> Bool

    init(startEngine: @escaping (AVAudioEngine) throws -> Void = { try $0.start() },
         clock: @escaping () -> UInt64 = { RestClock.now() },
         startCustomPlayer: @escaping (AVAudioPlayer) -> Bool = { $0.play() }) {
        self.startEngine = startEngine
        self.clock = clock
        self.startCustomPlayer = startCustomPlayer
    }

    func play(_ sound: RestSound, customURL: URL? = nil) {
        guard sound != playing || (sound == .custom && self.customURL != customURL) else { return }
        if sound == failed, let retryAfter, clock() < retryAfter { return }
        stop()
        guard sound != .off else { return }
        if sound == .custom {
            do {
                guard let customURL else { throw RestCustomAudioStore.Failure.unreadable }
                let player = try AVAudioPlayer(contentsOf: customURL)
                player.numberOfLoops = -1
                player.volume = 0.16
                guard startCustomPlayer(player) else { throw RestCustomAudioStore.Failure.unreadable }
                customPlayer = player
                self.customURL = customURL
                playing = .custom
                // AVAudioPlayer 没有引擎配置通知；默认输出设备变化后按原文件重新播放。
                startWatchingOutputDevice()
            } catch {
                failed = sound
                retryAfter = clock() + 10_000_000_000
            }
            return
        }
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let node = makeNoiseSourceNode(format: format, mode: sound)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.16
        do {
            try startEngine(engine)
            self.engine = engine
            playing = sound
            // 切换耳机等输出设备时系统会停止引擎；按新配置重建，否则本次休息剩余时间都没有声音。
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleConfigurationChange() }
            }
        } catch {
            engine.stop()
            failed = sound
            retryAfter = clock() + 10_000_000_000
        }
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        stopWatchingOutputDevice()
        engine?.stop()
        engine = nil
        customPlayer?.stop()
        customPlayer = nil
        customURL = nil
        playing = .off
        failed = nil
        retryAfter = nil
    }

    /// 输出设备变化会停掉当前播放。保留声音和自定义文件，按新设备重新开始。
    func handleConfigurationChange() {
        let current = playing
        let url = customURL
        guard current != .off else { return }
        stop()
        play(current, customURL: url)
    }

    private func startWatchingOutputDevice() {
        guard outputDeviceListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
        var address = outputDeviceAddress
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr else { return }
        outputDeviceListener = listener
    }

    private func stopWatchingOutputDevice() {
        guard let listener = outputDeviceListener else { return }
        var address = outputDeviceAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        outputDeviceListener = nil
    }
}

/// AVAudioSourceNode 在音频线程调用此闭包；在非隔离函数中创建，避免继承播放器的 MainActor。
nonisolated func makeNoiseSourceNode(format: AVAudioFormat, mode: RestSound) -> AVAudioSourceNode {
    let generator = RestSoundGenerator(mode: mode, sampleRate: format.sampleRate)
    return AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for frame in 0..<Int(frameCount) {
            let sample = generator.next()
            for buffer in buffers {
                buffer.mData!.assumingMemoryBound(to: Float.self)[frame] = sample
            }
        }
        return noErr
    }
}

/// 单个 source node 的渲染回调独占采样状态，不向其他线程暴露。
nonisolated final class RestSoundGenerator {
    let mode: RestSound
    private var seed: UInt64 = 0x9E3779B97F4A7C15
    private var lowA: Float = 0
    private var pink0: Float = 0
    private var pink1: Float = 0
    private var pink2: Float = 0
    private var pink3: Float = 0
    private var pink4: Float = 0
    private var pink5: Float = 0
    private var pink6: Float = 0
    private var ambientBody: Float = 0
    private var ambientGain: Float = 1
    private var targetGain: Float = 1
    private var framesUntilVariation = 0
    private var fade: Float = 0
    private var bubbleA = StreamBubbleVoice()
    private var bubbleB = StreamBubbleVoice()
    private var bubbleFramesRemaining = 0
    private let sampleRate: Double
    private let broadCoefficient: Float
    private let bodyCoefficient: Float
    private let gainCoefficient: Float
    private let variationFrames: Int
    private let fadeStep: Float

    init(mode: RestSound, sampleRate: Double = 44_100) {
        precondition(sampleRate.isFinite && sampleRate > 0)
        self.mode = mode
        self.sampleRate = sampleRate
        // 底层水流/雨幕/风声使用低通噪声；溪流另外叠加有界水泡共振，避免仅靠换频带区分。
        let frequencies: (Double, Double)
        let variation: (interval: Double, smoothing: Double)
        switch mode {
        case .rain: frequencies = (1400, 150); variation = (3, 0.7)
        case .stream: frequencies = (1200, 240); variation = (0.45, 0.28)
        case .wind: frequencies = (500, 70); variation = (4, 1.5)
        default: frequencies = (1400, 150); variation = (3, 0.7)
        }
        broadCoefficient = Float(1 - exp(-2 * Double.pi * frequencies.0 / sampleRate))
        bodyCoefficient = Float(1 - exp(-2 * Double.pi * frequencies.1 / sampleRate))
        gainCoefficient = Float(1 - exp(-1 / (sampleRate * variation.smoothing)))
        variationFrames = max(1, Int(sampleRate * variation.interval))
        fadeStep = Float(1 / (sampleRate * 0.2))
    }

    func next() -> Float {
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        let white = Float(seed & 0xFFFF) / 32767.5 - 1
        let sample: Float
        switch mode {
        case .off, .custom: return 0
        case .white: sample = white * 0.35
        case .pink:
            // Paul Kellett 的 pink-noise 滤波系数；多极点近似 1/f 频谱。
            // https://www.musicdsp.org/en/latest/Filters/76-pink-noise-filter.html
            pink0 = 0.99886 * pink0 + white * 0.0555179
            pink1 = 0.99332 * pink1 + white * 0.0750759
            pink2 = 0.96900 * pink2 + white * 0.1538520
            pink3 = 0.86650 * pink3 + white * 0.3104856
            pink4 = 0.55000 * pink4 + white * 0.5329522
            pink5 = -0.7616 * pink5 - white * 0.0168980
            sample = (pink0 + pink1 + pink2 + pink3 + pink4 + pink5 + pink6 + white * 0.5362) * 0.11
            pink6 = white * 0.115926
        case .rain, .stream, .wind:
            lowA += broadCoefficient * (white - lowA)
            ambientBody += bodyCoefficient * (white - ambientBody)
            if framesUntilVariation == 0 {
                let variation = Float((seed >> 32) & 0xFFFF) / 65535
                switch mode {
                case .rain: targetGain = 0.85 + variation * 0.2
                case .stream: targetGain = 0.75 + variation * 0.4
                case .wind: targetGain = 0.65 + variation * 0.35
                default: break
                }
                framesUntilVariation = variationFrames
            }
            framesUntilVariation -= 1
            ambientGain += gainCoefficient * (targetGain - ambientGain)
            switch mode {
            case .rain: sample = (lowA * 0.5 + ambientBody * 0.28) * ambientGain
            case .stream:
                if bubbleFramesRemaining == 0 {
                    let pitch = Double((seed >> 16) & 0xFFFF) / 65535
                    let size = Double((seed >> 32) & 0xFFFF) / 65535
                    let frequency = 240 + pitch * 550
                    let duration = 0.10 + size * 0.08
                    let amplitude = Float(0.13 + size * 0.10)
                    // 只使用空闲声部，不能覆盖尚未淡出的水泡而产生突兀截断。
                    if !bubbleA.isActive {
                        bubbleA.start(frequency: frequency, duration: duration, amplitude: amplitude, sampleRate: sampleRate)
                        bubbleFramesRemaining = max(1, Int(sampleRate * (0.065 + pitch * 0.085)))
                    } else if !bubbleB.isActive {
                        bubbleB.start(frequency: frequency, duration: duration, amplitude: amplitude, sampleRate: sampleRate)
                        bubbleFramesRemaining = max(1, Int(sampleRate * (0.065 + pitch * 0.085)))
                    } else {
                        bubbleFramesRemaining = max(1, Int(sampleRate * 0.01))
                    }
                }
                bubbleFramesRemaining -= 1
                sample = ((lowA * 0.12 + ambientBody * 0.16) + bubbleA.next() + bubbleB.next()) * ambientGain
            case .wind: sample = (lowA * 0.38 + ambientBody * 0.58) * ambientGain
            default: sample = 0
            }
        }
        // 前 200ms 平滑渐入，切换与试听的第一帧不突然跳到完整音量。
        fade = min(1, fade + fadeStep)
        return sample * fade * fade * (3 - 2 * fade)
    }
}

/// 两个短暂水泡交替发声；缓慢升高共振频率并衰减，形成流动水声中的细小咕噜质感。
/// 振荡状态属于同一个音频回调，无线程共享；三角系数只在每次水泡开始时计算。
nonisolated private struct StreamBubbleVoice {
    private var current = 0.0
    private var previous = 0.0
    private var coefficient = 0.0
    private var coefficientStep = 0.0
    private var age = 0
    private var length = 0
    private var amplitude: Float = 0

    var isActive: Bool { age < length }

    mutating func start(frequency: Double, duration: Double, amplitude: Float, sampleRate: Double) {
        length = max(1, Int(duration * sampleRate))
        age = 0
        current = 0
        let omega = 2 * Double.pi * frequency / sampleRate
        previous = -sin(omega)
        coefficient = 2 * cos(omega)
        coefficientStep = (2 * cos(omega * 1.45) - coefficient) / Double(length)
        self.amplitude = amplitude
    }

    mutating func next() -> Float {
        guard age < length else { return 0 }
        let progress = Double(age) / Double(length)
        let attack = min(1, progress / 0.12)
        let envelope = attack * attack * (3 - 2 * attack) * (1 - progress) * (1 - progress)
        let sample = Float(current * envelope) * amplitude
        let following = coefficient * current - previous
        previous = current
        current = following
        coefficient += coefficientStep
        age += 1
        return sample
    }
}

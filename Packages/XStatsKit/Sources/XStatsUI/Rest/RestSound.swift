// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import Localization

public enum RestSound: String, CaseIterable, Identifiable, Sendable {
    case off, white, pink, rain
    public var id: String { rawValue }
    var title: String {
        switch self {
        case .off: tr("关闭")
        case .white: tr("白噪音")
        case .pink: tr("粉红噪音")
        case .rain: tr("雨声")
        }
    }
}

/// 实时生成采样，无文件、下载或麦克风访问。render block 内不分配内存，也不访问 UI 状态。
@MainActor
final class RestSoundPlayer {
    private var engine: AVAudioEngine?
    private(set) var playing: RestSound = .off

    func play(_ sound: RestSound) {
        guard sound != playing else { return }
        stop()
        guard sound != .off else { return }
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let node = makeNoiseSourceNode(format: format, mode: sound)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.16
        do {
            try engine.start()
            self.engine = engine
            playing = sound
        } catch {
            engine.stop()
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
        playing = .off
    }
}

/// AVAudioSourceNode 在音频线程调用此闭包；在非隔离函数中创建，避免继承播放器的 MainActor。
nonisolated private func makeNoiseSourceNode(format: AVAudioFormat, mode: RestSound) -> AVAudioSourceNode {
    let generator = NoiseGenerator(mode: mode)
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
nonisolated private final class NoiseGenerator {
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
    private var drops: Float = 0

    init(mode: RestSound) { self.mode = mode }

    func next() -> Float {
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        let white = Float(seed & 0xFFFF) / 32767.5 - 1
        switch mode {
        case .off: return 0
        case .white: return white * 0.35
        case .pink:
            // Paul Kellett 的 pink-noise 滤波系数；多极点近似 1/f 频谱。
            // https://www.musicdsp.org/en/latest/Filters/76-pink-noise-filter.html
            pink0 = 0.99886 * pink0 + white * 0.0555179
            pink1 = 0.99332 * pink1 + white * 0.0750759
            pink2 = 0.96900 * pink2 + white * 0.1538520
            pink3 = 0.86650 * pink3 + white * 0.3104856
            pink4 = 0.55000 * pink4 + white * 0.5329522
            pink5 = -0.7616 * pink5 - white * 0.0168980
            let sample = pink0 + pink1 + pink2 + pink3 + pink4 + pink5 + pink6 + white * 0.5362
            pink6 = white * 0.115926
            return sample * 0.11
        case .rain:
            lowA += 0.035 * (white - lowA)
            if seed & 0x1FFF == 0 { drops = 0.75 }
            drops *= 0.998
            return lowA * 0.7 + white * drops * 0.25
        }
    }
}

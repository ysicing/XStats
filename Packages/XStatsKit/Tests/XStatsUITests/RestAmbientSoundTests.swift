// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import Foundation
import Testing
@testable import XStatsUI

struct RestAmbientSoundTests {
    @Test func newChoicesRoundTripAndRainKeepsItsSavedIdentifier() throws {
        #expect(RestSound(rawValue: "rain") == .rain)
        #expect(RestSound(rawValue: "stream") == .stream)
        #expect(RestSound(rawValue: "wind") == .wind)
        #expect(Set(RestSound.allCases.map(\.rawValue)).count == RestSound.allCases.count)
    }

    @Test(arguments: [RestSound.rain, .stream, .wind], [44_100.0, 48_000.0])
    func ambientSamplesRemainQuietFiniteAndBounded(sound: RestSound, sampleRate: Double) {
        let generator = RestSoundGenerator(mode: sound, sampleRate: sampleRate)
        var energy = 0.0, sum = 0.0, peak = 0.0, firstPeak = 0.0
        var finite = true
        let count = Int(sampleRate * 12)
        for index in 0..<count {
            let sample = Double(generator.next())
            finite = finite && sample.isFinite
            peak = max(peak, abs(sample))
            if index < 16 { firstPeak = max(firstPeak, abs(sample)) }
            energy += sample * sample; sum += sample
        }
        let rms = sqrt(energy / Double(count))
        #expect(finite)
        #expect(rms > 0.02 && rms < 0.18)
        #expect(peak < 0.9 && abs(sum / Double(count)) < 0.006)
        #expect(firstPeak < 0.002) // 开始时渐入，避免第一帧突然跳到完整幅度。
    }

    @Test func threeSoundscapesHaveDistinctSamplesAndSilenceRemainsSilent() {
        let silence = RestSoundGenerator(mode: .off)
        #expect((0..<100).allSatisfy { _ in silence.next() == 0 })
        let rain = RestSoundGenerator(mode: .rain)
        let stream = RestSoundGenerator(mode: .stream)
        let wind = RestSoundGenerator(mode: .wind)
        var rainStreamDifference = 0.0, rainWindDifference = 0.0
        for _ in 0..<44_100 {
            let r = Double(rain.next())
            rainStreamDifference += abs(r - Double(stream.next()))
            rainWindDifference += abs(r - Double(wind.next()))
        }
        #expect(rainStreamDifference / 44_100 > 0.01)
        #expect(rainWindDifference / 44_100 > 0.01)
    }

    @Test func streamDoesNotReuseTheRainNoiseTexture() {
        let rain = RestSoundGenerator(mode: .rain)
        let stream = RestSoundGenerator(mode: .stream)
        var cross = 0.0, rainEnergy = 0.0, streamEnergy = 0.0
        for _ in 0..<44_100 * 4 {
            let r = Double(rain.next()), s = Double(stream.next())
            cross += r * s; rainEnergy += r * r; streamEnergy += s * s
        }
        let correlation = abs(cross) / sqrt(rainEnergy * streamEnergy)
        #expect(correlation < 0.55) // 防止再次退化为同一段噪声仅改变频带；听感仍由试听确认。
    }

    @MainActor @Test(arguments: [RestSound.stream, .wind])
    func newChoicesPersistInSettingsAndBackup(sound: RestSound) throws {
        let suite = "RestAmbientSoundTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.restSound = sound
        #expect(AppSettings(defaults: defaults).restSound == sound)
        let backup = try JSONDecoder().decode(SettingsDocument.self, from: JSONEncoder().encode(settings.exportDocument()))
        settings.restSound = .off
        settings.apply(backup)
        #expect(settings.restSound == sound)
    }
    @MainActor @Test func rapidSoundChangesAndStopReleaseThePreviousEngine() async throws {
        weak var previousEngine: AVAudioEngine?
        let player = RestSoundPlayer(startEngine: { engine in
            // 不启动硬件：上一引擎及其 source node 必须在新引擎取得所有权前释放。
            #expect(previousEngine == nil)
            previousEngine = engine
        })
        defer { player.stop() }
        for _ in 0..<10 {
            for sound in [RestSound.rain, .stream, .wind] {
                player.play(sound)
                #expect(player.playing == sound && previousEngine != nil)
                await Task.yield()
            }
        }
        player.stop()
        #expect(player.playing == .off && previousEngine == nil)
    }

    @Test(arguments: [RestSound.rain, .stream, .wind])
    func sourceNodeRendersStereoOfflineWithoutSpeakerAccess(sound: RestSound) async throws {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let node = makeNoiseSourceNode(format: format, mode: sound)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.16
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        defer { engine.stop() }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        let totalFrames = 8 * 44_100
        var rendered = 0, squareSum = 0.0, peak = 0.0, finite = true, matched = true
        var file: AVAudioFile?
        if let destination = ProcessInfo.processInfo.environment["XSTATS_SOUND_ARTIFACTS"] {
            let directory = URL(fileURLWithPath: destination, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            file = try AVAudioFile(forWriting: directory.appendingPathComponent("\(sound.rawValue).wav"), settings: format.settings)
        }
        while rendered < totalFrames {
            let frames = AVAudioFrameCount(min(4096, totalFrames - rendered))
            let status = try engine.renderOffline(frames, to: buffer)
            try #require(status == .success)
            let channels = try #require(buffer.floatChannelData)
            for index in 0..<Int(buffer.frameLength) {
                let sample = Double(channels[0][index])
                finite = finite && sample.isFinite
                matched = matched && channels[0][index] == channels[1][index]
                peak = max(peak, abs(sample)); squareSum += sample * sample
                // 只为离线试听文件补一个结尾淡出；实时播放器的停止行为不受此处影响。
                let remaining = totalFrames - rendered - index
                if remaining < 8820 {
                    let gain = Float(remaining) / 8820
                    channels[0][index] *= gain; channels[1][index] *= gain
                }
            }
            try file?.write(from: buffer)
            rendered += Int(buffer.frameLength)
            await Task.yield()
        }
        #expect(finite && matched && peak < 0.16)
        #expect(sqrt(squareSum / Double(totalFrames)) > 0.002)
    }

}

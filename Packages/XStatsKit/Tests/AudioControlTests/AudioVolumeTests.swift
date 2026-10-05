// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import AudioControl

struct AudioVolumeTests {
    @Test func mutePreservesTheSelectedAudibleLevel() throws {
        var volume = try #require(AudioAppVolume(level: 0.65, isMuted: true))
        #expect(volume.gain == 0)
        #expect(volume.level == 0.65)
        volume.isMuted = false
        #expect(abs(volume.gain - 0.65) < 0.0001)
    }

    @Test func unityDoesNotRequireAudioProcessing() throws {
        #expect(try #require(AudioAppVolume(level: 1)).needsProcessing == false)
        #expect(try #require(AudioAppVolume(level: 0.5)).needsProcessing)
        #expect(try #require(AudioAppVolume(level: 1, isMuted: true)).needsProcessing)
    }

    @Test(arguments: [Double.nan, Double.infinity, -0.1, 2.01, 3])
    func rejectsInvalidLevelsAndExcessiveBoost(_ level: Double) {
        #expect(AudioAppVolume(level: level) == nil)
    }
    @Test func decodingCannotBypassTheVolumeRange() throws {
        let invalid = Data(#"{"level":2.01,"isMuted":false}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(AudioAppVolume.self, from: invalid) }
        let volume = try #require(AudioAppVolume(level: 0.35, isMuted: true))
        #expect(try JSONDecoder().decode(AudioAppVolume.self, from: JSONEncoder().encode(volume)) == volume)
    }
}

// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreAudio

/// 设备全局声道编号与 IOProc 输出缓冲区偏移由同一流描述提供。
struct AudioOutputStream: Sendable {
    let startingChannel: UInt32
    let bufferIndex: UInt32
    let format: AudioStreamBasicDescription
}

struct AudioOutputLayout: Sendable {
    let bufferIndex: UInt32
    let format: AudioStreamBasicDescription
    let leftChannel: UInt32
    let rightChannel: UInt32

    static func resolve(streams: [AudioOutputStream], preferred: [UInt32]?) throws -> Self {
        guard !streams.isEmpty, streams.allSatisfy({ $0.startingChannel > 0 && (1...32).contains($0.format.mChannelsPerFrame) }) else { throw AudioControlError.unsupportedFormat }
        if streams.count == 1, let mono = streams.first, mono.format.mChannelsPerFrame == 1 {
            return Self(bufferIndex: mono.bufferIndex, format: mono.format, leftChannel: 0, rightChannel: 0)
        }
        let pair: [UInt32]
        if let preferred {
            guard preferred.count == 2, preferred[0] != preferred[1], preferred.allSatisfy({ $0 > 0 }) else { throw AudioControlError.unsupportedFormat }
            pair = preferred
        } else {
            guard streams.count == 1, let stereo = streams.first, stereo.format.mChannelsPerFrame == 2,
                  stereo.startingChannel > 0, stereo.startingChannel < UInt32.max else { throw AudioControlError.unsupportedFormat }
            pair = [stereo.startingChannel, stereo.startingChannel + 1]
        }
        // 当前管线只有一个输出 PCM 描述；跨流或格式不一致的声道不能猜测映射。
        let matches = streams.filter { stream in
            guard stream.startingChannel > 0, (1...32).contains(stream.format.mChannelsPerFrame) else { return false }
            let end = UInt64(stream.startingChannel) + UInt64(stream.format.mChannelsPerFrame)
            return pair.allSatisfy { UInt64($0) >= UInt64(stream.startingChannel) && UInt64($0) < end }
        }
        guard matches.count == 1, let stream = matches.first else { throw AudioControlError.unsupportedFormat }
        return Self(bufferIndex: stream.bufferIndex, format: stream.format,
                    leftChannel: pair[0] - stream.startingChannel + 1, rightChannel: pair[1] - stream.startingChannel + 1)
    }
}

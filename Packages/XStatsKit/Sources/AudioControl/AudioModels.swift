// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public struct AudioAppVolume: Codable, Equatable, Sendable {
    public let level: Double
    public var isMuted: Bool
    public var gain: Float { isMuted ? 0 : Float(level) }
    public var needsProcessing: Bool { gain != 1 }

    private enum CodingKeys: String, CodingKey { case level, isMuted }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let level = try container.decode(Double.self, forKey: .level)
        let muted = try container.decode(Bool.self, forKey: .isMuted)
        guard let checked = Self(level: level, isMuted: muted) else {
            throw DecodingError.dataCorruptedError(forKey: .level, in: container, debugDescription: "Volume must be finite and in 0...2")
        }
        self = checked
    }

    public init?(level: Double, isMuted: Bool = false) {
        guard level.isFinite, (0...2).contains(level) else { return nil }
        self.level = level
        self.isMuted = isMuted
    }
}

public enum AudioDirection: Sendable, Equatable { case input, output }

public struct AudioDeviceInfo: Sendable, Equatable, Identifiable {
    public let id: UInt32
    public let uid: String
    public let name: String
    public let hasInput: Bool
    public let hasOutput: Bool
    public let inputVolume: Double?
    public let outputVolume: Double?
    public let inputMuted: Bool?
    public let outputMuted: Bool?
    public let canSetInputVolume: Bool
    public let canSetOutputVolume: Bool
    public let canSetInputMute: Bool
    public let canSetOutputMute: Bool
    public init(id: UInt32, uid: String, name: String, hasInput: Bool = false, hasOutput: Bool = false,
                inputVolume: Double? = nil, outputVolume: Double? = nil, inputMuted: Bool? = nil, outputMuted: Bool? = nil,
                canSetInputVolume: Bool = false, canSetOutputVolume: Bool = false, canSetInputMute: Bool = false, canSetOutputMute: Bool = false) {
        self.id = id; self.uid = uid; self.name = name; self.hasInput = hasInput; self.hasOutput = hasOutput
        self.inputVolume = inputVolume; self.outputVolume = outputVolume; self.inputMuted = inputMuted; self.outputMuted = outputMuted
        self.canSetInputVolume = canSetInputVolume; self.canSetOutputVolume = canSetOutputVolume
        self.canSetInputMute = canSetInputMute; self.canSetOutputMute = canSetOutputMute
    }

}

public struct AudioApplication: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let bundleURL: URL?
    public let processObjectIDs: [UInt32]
    public let isPlaying: Bool
    public init(id: String, name: String, bundleURL: URL? = nil, processObjectIDs: [UInt32], isPlaying: Bool) {
        self.id = id; self.name = name; self.bundleURL = bundleURL; self.processObjectIDs = processObjectIDs; self.isPlaying = isPlaying
    }

}

public struct AudioHardwareSnapshot: Sendable, Equatable {
    public let devices: [AudioDeviceInfo]
    public let outputID: UInt32?
    public let inputID: UInt32?
    public let applications: [AudioApplication]
    public init(devices: [AudioDeviceInfo], outputID: UInt32?, inputID: UInt32?, applications: [AudioApplication]) {
        self.devices = devices; self.outputID = outputID; self.inputID = inputID; self.applications = applications
    }
    public static let empty = AudioHardwareSnapshot(devices: [], outputID: nil, inputID: nil, applications: [])
}

public enum AudioControlError: Error, Sendable, Equatable {
    case unavailable, unsupported, routeChanged, permissionRequired, unsupportedFormat, renderStalled
    case hardware(Int32)
}

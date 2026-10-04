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
            throw DecodingError.dataCorruptedError(forKey: .level, in: container, debugDescription: "Volume must be finite and in 0...1")
        }
        self = checked
    }

    public init?(level: Double, isMuted: Bool = false) {
        guard level.isFinite, (0...1).contains(level) else { return nil }
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
}

public struct AudioApplication: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let bundleURL: URL?
    public let processObjectIDs: [UInt32]
}

public struct AudioHardwareSnapshot: Sendable, Equatable {
    public let devices: [AudioDeviceInfo]
    public let outputID: UInt32?
    public let inputID: UInt32?
    public let applications: [AudioApplication]
    public static let empty = AudioHardwareSnapshot(devices: [], outputID: nil, inputID: nil, applications: [])
}

public enum AudioControlError: Error, Sendable, Equatable {
    case unavailable, unsupported, routeChanged, permissionRequired, unsupportedFormat
    case hardware(Int32)
}

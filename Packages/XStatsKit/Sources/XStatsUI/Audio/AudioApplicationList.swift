// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AudioControl

/// 展示候选与底层音频注册目录分离，暂停时保留用户刚控制的行。
struct AudioApplicationList {
    // 只保留仍存在的音频对象；同名应用重新启动时不会继承旧连接的展示记录。
    private var retainedConnections: [String: Set<UInt32>] = [:]

    /// 用户重置后保留当前行；仅影响展示，不代表播放或延长处理需求。
    mutating func retain(_ app: AudioApplication) {
        let objects = Set(app.processObjectIDs)
        guard !objects.isEmpty else { return }
        retainedConnections[app.id] = objects
    }

    mutating func update(_ applications: [AudioApplication]) {
        var retained: [String: Set<UInt32>] = [:]
        for app in applications {
            let objects = Set(app.processObjectIDs)
            if app.isPlaying {
                retained[app.id] = objects
            } else if let previous = retainedConnections[app.id] {
                let remaining = previous.intersection(objects)
                if !remaining.isEmpty { retained[app.id] = remaining }
            }
        }
        retainedConnections = retained
    }

    func visible(_ applications: [AudioApplication], volumes: [String: AudioAppVolume], outputs: [String: String]) -> [AudioApplication] {
        applications.filter {
            $0.isPlaying || retainedConnections[$0.id] != nil || volumes[$0.id]?.needsProcessing == true || outputs[$0.id] != nil
        }
    }

    mutating func reset() { retainedConnections.removeAll() }
}

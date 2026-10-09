// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import Foundation

/// 只保存应用内副本的文件名；个人原始路径和音频内容不进入设置备份。
struct RestCustomAudio: Codable, Equatable, Sendable {
    let filename: String
    let displayName: String

    func url(in directory: URL) -> URL? {
        let name = filename as NSString
        guard name.lastPathComponent == filename,
              UUID(uuidString: name.deletingPathExtension) != nil,
              !name.pathExtension.isEmpty else { return nil }
        return directory.appendingPathComponent(filename)
    }
}

/// 用户选择的文件只导入一次；校验和复制在 actor 上执行，不阻塞界面。
actor RestCustomAudioStore {
    enum Failure: Error { case tooLarge, unreadable }
    static let maximumBytes = 50 * 1024 * 1024
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XStats/RestAudio", isDirectory: true)
    }
    private let directory: URL
    init(directory: URL = defaultDirectory) { self.directory = directory }

    func importAudio(from source: URL) throws -> RestCustomAudio {
        try Task.checkCancellation()
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let info = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard info.isRegularFile == true else { throw Failure.unreadable }
        guard let size = info.fileSize, size <= Self.maximumBytes else { throw Failure.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let suffix = source.pathExtension.isEmpty ? "audio" : source.pathExtension.lowercased()
        let audio = RestCustomAudio(filename: UUID().uuidString + "." + suffix, displayName: source.lastPathComponent)
        guard let destination = audio.url(in: directory) else { throw Failure.unreadable }
        var imported = false
        defer { if !imported { try? FileManager.default.removeItem(at: destination) } }
        try FileManager.default.copyItem(at: source, to: destination)
        try Task.checkCancellation()
        let copiedSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard copiedSize > 0 && copiedSize <= Self.maximumBytes else { throw Failure.tooLarge }
        do {
            // AVAudioFile 只打开并读取元数据，避免为校验一次性解码整个音频文件。
            let file = try AVAudioFile(forReading: destination)
            guard file.length > 0, file.processingFormat.sampleRate > 0,
                  file.processingFormat.channelCount > 0 else { throw Failure.unreadable }
            // 播放器需支持该容器；prepare/play 留到用户试听时执行。
            _ = try AVAudioPlayer(contentsOf: destination)
        } catch { throw Failure.unreadable }
        try Task.checkCancellation()
        imported = true
        return audio
    }

    func remove(_ audio: RestCustomAudio) throws {
        guard let url = audio.url(in: directory) else { return }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

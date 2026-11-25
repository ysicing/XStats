// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import SwiftUI
import UniformTypeIdentifiers
import WebDAVSync

struct LegacySettingsBackupImport: View {
  let settings: AppSettings
  @State private var pickingFile = false
  @State private var selectedFile: URL?
  @State private var pendingBackup: SettingsBackup?
  @State private var message: String?

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.s2) {
      HStack {
        Button(tr("导入旧设置备份…")) {
          message = nil
          pickingFile = true
        }
        .buttonStyle(.link)
        .disabled(selectedFile != nil)
        if selectedFile != nil {
          ProgressView().controlSize(.small).accessibilityLabel(tr("正在读取旧设置备份"))
        }
      }
      if let message {
        Text(verbatim: message).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      }
    }
    .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.json]) { result in
      switch result {
      case .success(let url): selectedFile = url
      case .failure(let error):
        if (error as? CocoaError)?.code != .userCancelled { message = tr("无法读取设置备份") }
      }
    }
    .task(id: selectedFile, priority: .utility) {
      guard let selectedFile else { return }
      do {
        let backup = try await SettingsBackup.readLegacyFile(selectedFile)
        try Task.checkCancellation()
        pendingBackup = backup
      } catch {
        guard !Task.isCancelled else { return }
        switch error as? WebDAVError {
        case .tooLarge: message = tr("设置备份文件过大，无法导入")
        case .invalidDocument: message = tr("此文件不是有效的 XStats 设置备份")
        case .unsupportedVersion: message = tr("设置备份版本不受支持，请先更新 XStats")
        default: message = tr("无法读取设置备份")
        }
      }
      self.selectedFile = nil
    }
    .alert(
      tr("应用备份中的设置？"),
      isPresented: Binding(
        get: { pendingBackup != nil }, set: { if !$0 { pendingBackup = nil } }),
      presenting: pendingBackup
    ) { backup in
      Button(tr("取消"), role: .cancel) {}
      Button(tr("应用并覆盖"), role: .destructive) {
        settings.apply(backup.document)
        message = tr("已导入设置备份")
      }
    } message: { backup in
      let date = backup.savedAt.formatted(
        .dateTime.year().month().day().hour().minute().locale(L10n.locale))
      Text(tr("将应用 \(date) 保存的设置，覆盖本机对应偏好。"))
    }
    .onDisappear {
      selectedFile = nil
      pendingBackup = nil
    }
  }
}

extension SettingsBackup {
  nonisolated static func readLegacyFile(_ url: URL) async throws -> Self {
    try Task.checkCancellation()
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }

    let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard info.isRegularFile == true else { throw WebDAVError.invalidDocument }
    let limit = WebDAVClient.maximumBytes
    if let size = info.fileSize, size > limit { throw WebDAVError.tooLarge }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var data = Data()
    while true {
      try Task.checkCancellation()
      let remaining = limit - data.count
      guard let chunk = try file.read(upToCount: min(64 * 1024, remaining + 1)), !chunk.isEmpty
      else { break }
      guard chunk.count <= remaining else { throw WebDAVError.tooLarge }
      data.append(chunk)
    }
    return try decode(data)
  }
}

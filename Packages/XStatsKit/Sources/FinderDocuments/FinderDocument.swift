// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import Localization

public enum FinderDocumentKind: String, CaseIterable, Codable, Sendable {
  case pptx, xlsx, docx, txt, md, key, numbers, pages

  public var title: String {
    switch self {
    case .docx: "文字文档"
    case .xlsx: "电子表格"
    case .pptx: "演示文稿"
    case .txt: "文本文件"
    case .md: "Markdown 文档"
    case .key: "Keynote 演示文稿"
    case .numbers: "Numbers 表格"
    case .pages: "Pages 文稿"
    }
  }

  public var applicationBundleIdentifier: String? {
    switch self {
    case .key: "com.apple.iWork.Keynote"
    case .numbers: "com.apple.iWork.Numbers"
    case .pages: "com.apple.iWork.Pages"
    case .pptx, .xlsx, .docx, .txt, .md: nil
    }
  }
}

public enum FinderDocumentError: LocalizedError {
  case unavailable, invalidRequest, disabled, nameLimit

  public var errorDescription: String? {
    switch self {
    case .unavailable: tr("Finder 扩展暂不可用，请重新安装 XStats 后重试。")
    case .invalidRequest: tr("创建请求已失效，请在 Finder 中重试。")
    case .disabled: tr("请先在 XStats 中启用 Finder 新建文档。")
    case .nameLimit: tr("同名文档过多，请重命名后重试。")
    }
  }
}

public struct FinderDocumentConfiguration: Codable, Equatable, Sendable {
  public var enabled: Bool
  private var languageCode: String
  public var language: AppLanguage {
    get { AppLanguage(rawValue: languageCode) ?? .chinese }
    set { languageCode = newValue.rawValue }
  }

  public init(enabled: Bool = false, language: AppLanguage = .chinese) {
    self.enabled = enabled
    languageCode = language.rawValue
  }

  public var directoryURLs: Set<URL> {
    enabled ? [URL(fileURLWithPath: "/", isDirectory: true)] : []
  }

  public func permits(_ directory: URL) -> Bool {
    enabled && directory.isFileURL
      && (directory.host == nil || directory.host == "" || directory.host == "localhost")
      && directory.query == nil && directory.fragment == nil
  }
}

public struct FinderDocumentRequest: Codable, Sendable {
  public let kind: FinderDocumentKind
  public let directory: URL
  public let createdAt: Date

  public init(kind: FinderDocumentKind, directory: URL, createdAt: Date = Date()) {
    self.kind = kind
    self.directory = directory
    self.createdAt = createdAt
  }
}

public enum FinderDocumentCreator {
  public static func create(
    _ request: FinderDocumentRequest, configuration: FinderDocumentConfiguration
  ) throws -> URL {
    guard configuration.enabled else { throw FinderDocumentError.disabled }
    guard configuration.permits(request.directory) else { throw FinderDocumentError.invalidRequest }
    let directory = request.directory.standardizedFileURL.resolvingSymlinksInPath()
    let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard folder >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(folder) }
    guard
      let template = Bundle.module.url(
        forResource: "blank", withExtension: request.kind == .md ? "txt" : request.kind.rawValue,
        subdirectory: "Templates")
    else { throw FinderDocumentError.unavailable }
    let data = try Data(contentsOf: template)
    let title = L10n.translate(request.kind.title, language: configuration.language)
    for attempt in 0..<100 {
      try Task.checkCancellation()
      let suffix = attempt == 0 ? "" : " \(attempt + 1)"
      let name = "\(title)\(suffix).\(request.kind.rawValue)"
      let file = openat(folder, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
      if file < 0 {
        if errno == EEXIST { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
      do {
        try handle.write(contentsOf: data)
        try handle.close()
        return directory.appendingPathComponent(name)
      } catch {
        try? handle.close()
        unlinkat(folder, name, 0)
        throw error
      }
    }
    throw FinderDocumentError.nameLimit
  }
}

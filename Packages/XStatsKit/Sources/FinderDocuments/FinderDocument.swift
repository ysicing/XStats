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
  case unavailable, invalidRequest, disabled, nameLimit, invalidName

  public var errorDescription: String? {
    switch self {
    case .unavailable: tr("Finder 扩展暂不可用，请重新安装 XStats 后重试。")
    case .invalidRequest: tr("创建请求已失效，请在 Finder 中重试。")
    case .disabled: tr("请先在 XStats 中启用 Finder 新建文档。")
    case .nameLimit: tr("同名文档过多，请重命名后重试。")
    case .invalidName: tr("请输入有效文件名，不含路径分隔符或控制字符，且不超过 220 字节。")
    }
  }
}

public enum FinderDocumentNamingMode: String, CaseIterable, Codable, Sendable {
  case random, fixed, manual
}

public struct FinderDocumentConfiguration: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var namingMode: FinderDocumentNamingMode
  public var fixedName: String
  public var enabledKinds: Set<FinderDocumentKind>
  private var languageCode: String
  public var language: AppLanguage {
    get { AppLanguage(rawValue: languageCode) ?? .chinese }
    set { languageCode = newValue.rawValue }
  }

  public init(
    enabled: Bool = false, language: AppLanguage = .chinese,
    namingMode: FinderDocumentNamingMode = .fixed, fixedName: String = "",
    enabledKinds: Set<FinderDocumentKind> = Set(FinderDocumentKind.allCases)
  ) {
    self.enabled = enabled
    languageCode = language.rawValue
    self.namingMode = namingMode
    self.fixedName = fixedName
    self.enabledKinds = enabledKinds
  }

  private enum CodingKeys: String, CodingKey {
    case enabled, languageCode, namingMode, fixedName, enabledKinds
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try values.decode(Bool.self, forKey: .enabled)
    languageCode = try values.decode(String.self, forKey: .languageCode)
    namingMode =
      try values.decodeIfPresent(String.self, forKey: .namingMode)
      .flatMap(FinderDocumentNamingMode.init(rawValue:)) ?? .fixed
    fixedName = try values.decodeIfPresent(String.self, forKey: .fixedName) ?? ""
    let kinds = try values.decodeIfPresent([String].self, forKey: .enabledKinds)
    enabledKinds =
      kinds.map { Set($0.compactMap(FinderDocumentKind.init(rawValue:))) }
      ?? Set(FinderDocumentKind.allCases)
  }

  public func baseName(for kind: FinderDocumentKind, manualName: String? = nil) throws -> String {
    let input: String
    switch namingMode {
    case .random:
      input = UUID().uuidString.lowercased()
    case .fixed:
      input =
        fixedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? L10n.translate(kind.title, language: language) : fixedName
    case .manual:
      guard let manualName else { throw FinderDocumentError.invalidName }
      input = manualName
    }
    var name = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.lowercased().hasSuffix(".\(kind.rawValue)") {
      name.removeLast(kind.rawValue.count + 1)
      name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 220,
      name.rangeOfCharacter(from: .controlCharacters) == nil,
      !name.contains("/"), !name.contains("\\"), !name.contains(":")
    else { throw FinderDocumentError.invalidName }
    return name
  }

  public func directoryURLs(mountedVolumes: [URL]) -> Set<URL> {
    guard enabled else { return [] }
    return Set(mountedVolumes.filter(permits))
      .union([URL(fileURLWithPath: "/", isDirectory: true)])
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
    _ request: FinderDocumentRequest, configuration: FinderDocumentConfiguration,
    manualName: String? = nil
  ) throws -> URL {
    guard configuration.enabled else { throw FinderDocumentError.disabled }
    guard configuration.permits(request.directory),
      configuration.enabledKinds.contains(request.kind)
    else { throw FinderDocumentError.invalidRequest }
    let title = try configuration.baseName(for: request.kind, manualName: manualName)
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

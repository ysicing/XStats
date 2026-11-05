// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation

public struct FinderDocumentStore: Sendable {
  public static let changedNotification = "work.12306.xstats.finder.configuration-changed"
  public let directory: URL

  public init(directory: URL) { self.directory = directory }

  public static func shared(bundle: Bundle = .main) -> Self? {
    guard let group = bundle.object(forInfoDictionaryKey: "FinderDocumentsGroup") as? String,
      !group.contains("$"), group.first != ".",
      let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    else { return nil }
    return Self(directory: root.appendingPathComponent("FinderDocuments", isDirectory: true))
  }

  public func configuration() throws -> FinderDocumentConfiguration {
    let data = try read(directory.appendingPathComponent("configuration.json"), limit: 65_536)
    return try JSONDecoder().decode(FinderDocumentConfiguration.self, from: data)
  }

  public func save(_ configuration: FinderDocumentConfiguration) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(configuration)
    guard data.count <= 65_536 else { throw FinderDocumentError.invalidRequest }
    try data.write(to: directory.appendingPathComponent("configuration.json"), options: .atomic)
  }

  public func enqueue(_ request: FinderDocumentRequest) throws -> UUID {
    let configuration = try configuration()
    guard configuration.enabled else { throw FinderDocumentError.disabled }
    guard configuration.permits(request.directory),
      configuration.enabledKinds.contains(request.kind)
    else { throw FinderDocumentError.invalidRequest }
    let requests = directory.appendingPathComponent("Requests", isDirectory: true)
    try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
    guard
      let enumerator = FileManager.default.enumerator(
        at: requests, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsSubdirectoryDescendants])
    else { throw FinderDocumentError.unavailable }
    var count = 0
    for case let file as URL in enumerator {
      count += 1
      guard count <= 64 else { throw FinderDocumentError.invalidRequest }
      if let modified = try file.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate,
        Date().timeIntervalSince(modified) > 120
      {
        try? FileManager.default.removeItem(at: file)
      }
    }
    let identifier = UUID()
    let data = try JSONEncoder().encode(request)
    guard data.count <= 16_384 else { throw FinderDocumentError.invalidRequest }
    try data.write(to: requestURL(identifier), options: .withoutOverwriting)
    return identifier
  }

  public func consume(_ identifier: UUID, now: Date = Date()) throws -> FinderDocumentRequest {
    let file = requestURL(identifier)
    let data = try read(file, limit: 16_384)
    try FileManager.default.removeItem(at: file)
    let request = try JSONDecoder().decode(FinderDocumentRequest.self, from: data)
    guard request.directory.isFileURL,
      (0...120).contains(now.timeIntervalSince(request.createdAt))
    else { throw FinderDocumentError.invalidRequest }
    return request
  }

  public func discard(_ identifier: UUID) {
    try? FileManager.default.removeItem(at: requestURL(identifier))
  }

  public static func launchURL(_ identifier: UUID) -> URL {
    URL(string: "xstats://finder-create/\(identifier.uuidString)")!
  }

  private func requestURL(_ identifier: UUID) -> URL {
    directory.appendingPathComponent("Requests/\(identifier.uuidString).json")
  }

  private func read(_ url: URL, limit: Int) throws -> Data {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw FinderDocumentError.unavailable }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_size <= limit
    else { throw FinderDocumentError.invalidRequest }
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw FinderDocumentError.invalidRequest }
    return data
  }
}

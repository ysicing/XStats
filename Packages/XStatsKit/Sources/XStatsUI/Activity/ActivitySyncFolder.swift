// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation

struct ActivitySyncFolder: ActivitySyncRepository {
  let root: URL
  var isICloud = false
  var requestDownload: @Sendable (URL) throws -> Void = {
    try FileManager.default.startDownloadingUbiquitousItem(at: $0)
  }
  var exclusiveRename: @Sendable (Int32, String, String) -> Int32 = { directory, temporary, name in
    renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
  }
  private var rootComponents: [String] {
    ActivitySyncRemotePath.defaultRootComponents(for: root.lastPathComponent)
  }

  static func iCloudDrive() throws -> Self {
    let manager = FileManager.default
    let root = manager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    var info = stat()
    guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      manager.ubiquityIdentityToken != nil || manager.isUbiquitousItem(at: root)
    else { throw ActivitySyncFailure.cloudUnavailable }
    return Self(root: root, isICloud: true)
  }

  func list(_ path: [String]) async throws -> Set<String> {
    try await listActivityObjects(path).names
  }

  func listActivityObjects(_ path: [String]) async throws -> ActivitySyncListing {
    guard ActivitySyncRemotePath.validDirectory(path) else {
      throw ActivitySyncFailure.invalidListing
    }
    let components = rootComponents + path
    let directory = location(components, isDirectory: true)
    guard let parent = try openDirectory(components) else { return ActivitySyncListing() }
    defer { close(parent) }
    return try await coordinated(at: directory, writing: false) { [self] in
      let descriptor = dup(parent)
      guard descriptor >= 0 else { throw POSIXError(.EIO) }
      guard let iterator = fdopendir(descriptor) else {
        close(descriptor)
        throw POSIXError(.EIO)
      }
      defer { closedir(iterator) }
      var result = ActivitySyncListing()
      var count = 0
      while true {
        try Task.checkCancellation()
        errno = 0
        guard let entry = readdir(iterator) else {
          if errno != 0 { throw POSIXError(.EIO) }
          break
        }
        count += 1
        guard count <= ActivitySyncRemotePath.maximumEntries + 2 else {
          throw ActivitySyncFailure.limit
        }
        let length = Int(entry.pointee.d_namlen)
        let filename = withUnsafePointer(to: &entry.pointee.d_name) {
          $0.withMemoryRebound(to: UInt8.self, capacity: length + 1) { bytes in
            String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
          }
        }
        let placeholder = isICloud && filename.hasPrefix(".") && filename.hasSuffix(".icloud")
        let name = placeholder ? String(filename.dropFirst().dropLast(7)) : filename
        guard ActivitySyncRemotePath.validChild(name, in: path) else { continue }
        var info = stat()
        if fstatat(descriptor, filename, &info, AT_SYMLINK_NOFOLLOW) != 0 {
          if errno == ENOENT { continue }
          throw ActivitySyncFailure.folderUnavailable
        }
        let object = ActivitySyncRemotePath.validObject(path + [name])
        guard info.st_mode & S_IFMT == (object || placeholder ? S_IFREG : S_IFDIR) else {
          throw ActivitySyncFailure.invalidListing
        }
        result.names.insert(name)
        if placeholder { result.placeholders.insert(name) }
        if !placeholder, object {
          result.versions[name] = Self.version(of: info)
        }
      }
      return result
    }
  }

  func read(_ path: [String]) async throws -> Data? {
    guard ActivitySyncRemotePath.validObject(path), let name = path.last
    else { throw ActivitySyncFailure.invalidListing }
    let limit = ActivitySyncRemotePath.objectByteLimit(path)
    let components = rootComponents + path
    let url = location(components)
    guard let directory = try openDirectory(Array(components.dropLast())) else { return nil }
    defer { close(directory) }
    var metadata = stat()
    let present = fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0
    guard present || errno == ENOENT else { throw ActivitySyncFailure.folderUnavailable }
    if present {
      guard metadata.st_mode & S_IFMT == S_IFREG else { throw ActivitySyncFailure.invalidListing }
      guard metadata.st_size <= limit else { throw ActivitySyncFailure.limit }
    }
    try materialize(url, byteLimit: limit)
    guard present else { return nil }
    return try await coordinated(at: url, writing: false) {
      let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard file >= 0 else { throw ActivitySyncFailure.folderUnavailable }
      let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
      defer { try? handle.close() }
      var info = stat()
      guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
        info.st_size <= limit
      else { throw ActivitySyncFailure.limit }
      var data = Data()
      while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
        try Task.checkCancellation()
        guard chunk.count <= limit - data.count else {
          throw ActivitySyncFailure.limit
        }
        data.append(chunk)
      }
      return data
    }
  }

  func create(_ data: Data, at path: [String]) async throws -> Bool {
    try await createWithVersion(data, at: path).created
  }

  func createWithVersion(_ data: Data, at path: [String]) async throws
    -> (created: Bool, version: String?)
  {
    guard ActivitySyncRemotePath.validObject(path),
      !ActivitySyncRemotePath.validMetadataObject(path)
    else { throw ActivitySyncFailure.invalidListing }
    return try await write(data, at: path, replacing: false)
  }

  func replaceMetadata(_ data: Data, at path: [String]) async throws {
    guard ActivitySyncRemotePath.validMetadataObject(path) else {
      throw ActivitySyncFailure.invalidListing
    }
    _ = try await write(data, at: path, replacing: true)
  }

  private func write(_ data: Data, at path: [String], replacing: Bool) async throws
    -> (created: Bool, version: String?)
  {
    guard let name = path.last else { throw ActivitySyncFailure.invalidListing }
    let limit = ActivitySyncRemotePath.objectByteLimit(path)
    guard data.count <= limit else { throw ActivitySyncFailure.limit }
    let components = rootComponents + Array(path.dropLast())
    try await ensureDirectory(components)
    guard let directory = try openDirectory(components) else {
      throw ActivitySyncFailure.folderUnavailable
    }
    defer { close(directory) }
    let url = location(components + [name])
    return try await coordinated(at: url, writing: true) { [self] in
      var metadata = stat()
      if fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw ActivitySyncFailure.invalidListing }
        if !replacing { return (false, nil) }
      } else if errno != ENOENT {
        throw ActivitySyncFailure.folderUnavailable
      }
      try materialize(url, byteLimit: limit)
      let temporary = ".\(UUID().uuidString).tmp"
      let file = openat(
        directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard file >= 0 else { throw ActivitySyncFailure.folderUnavailable }
      defer { unlinkat(directory, temporary, 0) }
      let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
      defer { try? handle.close() }
      try handle.write(contentsOf: data)
      var written = stat()
      let canVersion = !replacing && fstat(file, &written) == 0
      try handle.close()
      try Task.checkCancellation()
      if replacing {
        guard renameat(directory, temporary, directory, name) == 0 else {
          throw ActivitySyncFailure.folderUnavailable
        }
        return (true, nil)
      }
      switch exclusiveRename(directory, temporary, name) {
      case 0: break
      case EEXIST: return (false, nil)
      case ENOTSUP, EINVAL, ENOSYS:
        // 在同一个协调写入范围内复查目标，兼容不支持独占重命名的文件系统。
        if fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 { return (false, nil) }
        guard errno == ENOENT, renameat(directory, temporary, directory, name) == 0 else {
          throw ActivitySyncFailure.folderUnavailable
        }
      default:
        throw ActivitySyncFailure.folderUnavailable
      }
      // SMB 等文件系统需要先关闭文件再重命名；只有目标仍对应这次写入时才缓存版本。
      guard canVersion, fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
        metadata.st_dev == written.st_dev, metadata.st_ino == written.st_ino,
        metadata.st_size == written.st_size,
        metadata.st_mtimespec.tv_sec == written.st_mtimespec.tv_sec,
        metadata.st_mtimespec.tv_nsec == written.st_mtimespec.tv_nsec
      else { return (true, nil) }
      return (true, Self.version(of: metadata))
    }
  }

  private static func version(of info: stat) -> String {
    "\(info.st_ino)/\(info.st_size)/\(info.st_mtimespec.tv_sec)/\(info.st_mtimespec.tv_nsec)"
      + "/\(info.st_ctimespec.tv_sec)/\(info.st_ctimespec.tv_nsec)"
  }

  private func location(_ components: [String], isDirectory: Bool = false) -> URL {
    var result = root
    for (index, name) in components.enumerated() {
      result.appendPathComponent(name, isDirectory: isDirectory || index < components.count - 1)
    }
    return result
  }

  private func materialize(_ url: URL, byteLimit: Int? = nil) throws {
    guard isICloud else { return }
    let placeholder = url.deletingLastPathComponent().appendingPathComponent(
      ".\(url.lastPathComponent).icloud")
    let values = try? url.resourceValues(forKeys: [
      .ubiquitousItemDownloadingStatusKey, .fileSizeKey,
    ])
    if let byteLimit, let size = values?.fileSize, size > byteLimit {
      throw ActivitySyncFailure.limit
    }
    if values?.ubiquitousItemDownloadingStatus == .notDownloaded
      || FileManager.default.fileExists(atPath: placeholder.path)
    {
      do { try requestDownload(url) } catch {
        if FileManager.default.fileExists(atPath: placeholder.path) {
          try requestDownload(placeholder)
        } else {
          throw error
        }
      }
      throw ActivitySyncFailure.downloadRequested
    }
  }

  private func ensureDirectory(_ components: [String]) async throws {
    var ancestors: [String] = []
    var url = root
    for component in components {
      try Task.checkCancellation()
      url.appendPathComponent(component, isDirectory: true)
      let parentComponents = ancestors
      ancestors.append(component)
      if let existing = try openDirectory(ancestors) {
        close(existing)
        continue
      }
      try await coordinated(at: url, writing: true) { [self] in
        guard let parent = try openDirectory(parentComponents) else {
          throw ActivitySyncFailure.folderUnavailable
        }
        defer { close(parent) }
        guard mkdirat(parent, component, 0o700) == 0 || errno == EEXIST else {
          throw ActivitySyncFailure.folderUnavailable
        }
      }
    }
  }

  private func openDirectory(_ components: [String]) throws -> Int32? {
    let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    var parent = open(root.path, flags)
    guard parent >= 0 else { throw ActivitySyncFailure.folderUnavailable }
    var url = root
    for name in components {
      url.appendPathComponent(name, isDirectory: true)
      var info = stat()
      let present = fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0
      let directoryOrMissing = present ? info.st_mode & S_IFMT == S_IFDIR : errno == ENOENT
      guard directoryOrMissing else {
        close(parent)
        throw ActivitySyncFailure.invalidListing
      }
      do {
        try materialize(url)
      } catch {
        close(parent)
        throw error
      }
      guard present else {
        close(parent)
        return nil
      }
      let child = openat(parent, name, flags)
      close(parent)
      guard child >= 0 else { throw ActivitySyncFailure.folderUnavailable }
      parent = child
    }
    return parent
  }

  private func coordinated<Value>(
    at url: URL, writing: Bool, _ action: @escaping () throws -> Value
  ) async throws -> Value {
    // cancel() 可在协调阻塞时从另一线程调用；其余操作均留在同一同步 access scope。
    nonisolated(unsafe) let coordinator = NSFileCoordinator()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      var result: Result<Value, Error>?
      var failure: NSError?
      let access: (URL) -> Void = { coordinatedURL in
        guard coordinatedURL.standardizedFileURL.path == url.standardizedFileURL.path else {
          result = .failure(ActivitySyncFailure.folderUnavailable)
          return
        }
        result = Result {
          try Task.checkCancellation()
          return try action()
        }
      }
      if writing {
        coordinator.coordinate(
          writingItemAt: url, options: .forReplacing, error: &failure, byAccessor: access)
      } else {
        coordinator.coordinate(readingItemAt: url, options: [], error: &failure, byAccessor: access)
      }
      if let failure { throw failure }
      guard let result else { throw ActivitySyncFailure.folderUnavailable }
      return try result.get()
    } onCancel: {
      coordinator.cancel()
    }
  }
}

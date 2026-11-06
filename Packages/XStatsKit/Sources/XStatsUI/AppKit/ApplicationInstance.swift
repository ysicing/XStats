// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Darwin

/// 锁文件不删除，避免等待者与新启动进程锁住不同 inode；进程退出时由内核释放锁。
@MainActor
final class ApplicationInstance: NSObject {
  struct Request {
    let arguments: [String]
    let urls: [URL]
    let reopen: Bool
  }

  private static let notification = Notification.Name("work.12306.xstats.app.relaunch")
  private let lockURL: URL
  private var descriptor: Int32 = -1
  private var pending: [Request] = []
  private var handler: ((Request) -> Void)?

  var isPrimary: Bool { descriptor >= 0 }

  static func acquire() throws -> ApplicationInstance {
    let directory = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true
    )
    .appendingPathComponent("XStats", isDirectory: true)
    return try ApplicationInstance(lockURL: directory.appendingPathComponent(".application.lock"))
  }

  init(lockURL: URL) throws {
    self.lockURL = lockURL.standardizedFileURL
    super.init()
    try FileManager.default.createDirectory(
      at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    // 先登记接收端再取锁，并缓存初始化期间的请求，避免并发冷启动丢失再次打开或 URL。
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(receive(_:)), name: Self.notification,
      object: self.lockURL.path, suspensionBehavior: .deliverImmediately)
    let file = Darwin.open(
      self.lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
      S_IRUSR | S_IWUSR)
    guard file >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    var info = stat()
    guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid()
    else {
      close(file)
      throw POSIXError(.EACCES)
    }
    var result: Int32
    repeat {
      result = flock(file, LOCK_EX | LOCK_NB)
    } while result != 0 && errno == EINTR
    if result == 0 {
      descriptor = file
    } else {
      let code = errno
      close(file)
      guard code == EWOULDBLOCK else {
        throw POSIXError(.init(rawValue: code) ?? .EIO)
      }
    }
  }

  deinit {
    if descriptor >= 0 { close(descriptor) }
    DistributedNotificationCenter.default().removeObserver(self)
  }

  func handleRequests(_ handler: @escaping (Request) -> Void) {
    self.handler = handler
    let requests = pending
    pending.removeAll()
    for request in requests { handler(request) }
  }

  func forward(_ request: Request) {
    DistributedNotificationCenter.default().postNotificationName(
      Self.notification, object: lockURL.path,
      userInfo: [
        "arguments": request.arguments,
        "urls": request.urls.map(\.absoluteString),
        "reopen": request.reopen,
      ], deliverImmediately: true)
  }

  @objc func receive(_ notification: Notification) {
    guard isPrimary,
      let arguments = notification.userInfo?["arguments"] as? [String],
      arguments.count <= 64, arguments.reduce(0, { $0 + $1.utf8.count }) <= 16_384,
      let urls = notification.userInfo?["urls"] as? [String], urls.count <= 16,
      urls.allSatisfy({ $0.utf8.count <= 2048 }),
      let reopen = notification.userInfo?["reopen"] as? Bool
    else { return }
    let request = Request(
      arguments: arguments, urls: urls.compactMap(URL.init(string:)), reopen: reopen)
    if let handler {
      handler(request)
    } else if pending.count < 16 {
      pending.append(request)
    }
  }
}

/// 重复进程只接收启动事件，不创建业务控制器；URL 事件在启动完成前由 AppKit 交付。
@MainActor
final class DuplicateApplicationLaunch: NSObject, NSApplicationDelegate {
  private let instance: ApplicationInstance
  private let arguments: [String]
  private var urls: [URL] = []

  init(instance: ApplicationInstance, arguments: [String]) {
    self.instance = instance
    self.arguments = arguments
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    self.urls.append(contentsOf: urls.prefix(16 - self.urls.count))
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let reopen = ApplicationLaunch.showsMainWindow(
      event: NSAppleEventManager.shared().currentAppleEvent, arguments: arguments,
      hasPendingDeepLink: !urls.isEmpty, showMainWindowOnLaunch: true)
    instance.forward(.init(arguments: arguments, urls: urls, reopen: reopen))
    NSApp.terminate(nil)
  }
}

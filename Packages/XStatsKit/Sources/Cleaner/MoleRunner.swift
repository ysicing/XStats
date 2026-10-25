// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation

public enum MoleCommand: Sendable {
  case scan, clean, optimizePreview, optimize, install

  public var isPreview: Bool { self == .scan || self == .optimizePreview }
  public var arguments: [String] {
    switch self {
    case .scan: ["clean", "--dry-run"]
    case .clean: ["clean"]
    case .optimizePreview: ["optimize", "--dry-run"]
    case .optimize: ["optimize"]
    case .install: ["install", "mole"]
    }
  }
  public var displayCommand: String {
    ([self == .install ? "brew" : "mo"] + arguments).joined(separator: " ")
  }
}

public struct MoleOutput: Sendable {
  public let text: String
  public let wasTruncated: Bool

  public init(text: String, wasTruncated: Bool) {
    self.text = text
    self.wasTruncated = wasTruncated
  }
}

/// 按需运行 Mole 或用户明确发起的 Homebrew 安装，不解释其输出为原生清理授权。
public enum MoleRunner {
  public static var homebrewExecutable: URL? {
    DeveloperToolRunner.executable(named: "brew", home: NSHomeDirectory())
  }

  @concurrent
  public static func detect() async -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let directories = [
      home.appendingPathComponent(".local/bin"),
      URL(fileURLWithPath: "/opt/homebrew/bin"),
      URL(fileURLWithPath: "/usr/local/bin"),
    ]
    // 同名的其他 `mo` 不能被当作 Mole 执行 clean / optimize；校验失败则继续找下一个目录。
    for directory in directories {
      if let url = executable(in: [directory]), identifiesAsMole(url) { return url }
    }
    return nil
  }

  /// 仅以 `--version` 输出判断身份：限时、关闭标准输入，只读取有限字节。
  /// 非阻塞读取并以进程退出为准，不等待 EOF：继承输出管道的子进程不能让检测卡住。
  static func identifiesAsMole(_ executable: URL, timeout: Duration = .seconds(3)) -> Bool {
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--version"]
    process.standardInput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return false }
    defer {
      // 超时或读取失败时进程可能仍在运行或忽略 SIGTERM，强制结束后再回收。
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
      try? pipe.fileHandleForReading.close()
    }
    let fd = pipe.fileHandleForReading.fileDescriptor
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return false }
    var data = Data()
    var bytes = [UInt8](repeating: 0, count: 1024)
    let deadline = ContinuousClock.now + timeout
    while true {
      // 持续输出或不退出的进程同样受截止时间约束。
      guard ContinuousClock.now < deadline else { return false }
      // 先记录退出状态再读取：读空且读取前已退出，说明退出前的输出均已读完。
      let exited = !process.isRunning
      let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      if count > 0 {
        data.append(contentsOf: bytes.prefix(min(count, max(0, 4096 - data.count))))
        continue
      }
      if count < 0, errno != EAGAIN, errno != EINTR { return false }
      if exited { break }
      usleep(20_000)
    }
    return process.terminationReason == .exit && process.terminationStatus == 0
      && String(decoding: data, as: UTF8.self).contains("Mole")
  }

  static func executable(in directories: [URL]) -> URL? {
    directories.map { $0.appendingPathComponent("mo") }.first {
      var directory: ObjCBool = false
      return FileManager.default.fileExists(atPath: $0.path, isDirectory: &directory)
        && !directory.boolValue && FileManager.default.isExecutableFile(atPath: $0.path)
    }
  }

  /// 标准输入关闭，Mole 与 Homebrew 安装共用非交互执行；不收集密码或自动回答授权提示。
  /// 每次最多读取 64 KiB，每 200 ms 发布最近 128 KiB，避免连续输出占满主线程。
  @concurrent
  public static func run(
    executable: URL, command: MoleCommand,
    output: @Sendable (MoleOutput) async -> Void
  ) async throws -> Int32 {
    try Task.checkCancellation()
    let pipe = Pipe()
    defer {
      try? pipe.fileHandleForReading.close()
      try? pipe.fileHandleForWriting.close()
    }
    let fd = pipe.fileHandleForReading.fileDescriptor
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
      throw POSIXError(.EIO)
    }
    let pid = try spawn(
      executable: executable, command: command,
      output: pipe.fileHandleForWriting.fileDescriptor)
    // 先结束整个私有进程组，再回收 leader；PID 在最后一次 kill 前不能被复用。
    defer { stopAndReap(pid) }
    try? pipe.fileHandleForWriting.close()
    var buffer = MoleLogBuffer()
    var bytes = [UInt8](repeating: 0, count: 16 * 1024)
    var publishedAt = ContinuousClock.now - .seconds(1)
    var dirty = false
    while true {
      try Task.checkCancellation()
      for _ in 0..<4 {
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count > 0 {
          buffer.append(Data(bytes.prefix(count)))
          dirty = true
        } else if count == 0 || errno == EAGAIN {
          break
        } else if errno != EINTR {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
      }
      var info = siginfo_t()
      let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
      if result == -1 && errno != EINTR { throw POSIXError(.ECHILD) }
      let exited = result == 0 && info.si_pid != 0
      if dirty, exited || publishedAt.duration(to: .now) >= .milliseconds(200) {
        await output(buffer.output)
        publishedAt = .now
        dirty = false
      }
      if exited {
        // 再排空一批末尾输出；不等待继承管道的孙进程关闭，否则退出后仍可能卡住。
        for _ in 0..<4 {
          let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
          guard count > 0 else { break }
          buffer.append(Data(bytes.prefix(count)))
          dirty = true
        }
        if dirty { await output(buffer.output) }
        try Task.checkCancellation()
        return info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
      }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  private static func spawn(executable: URL, command: MoleCommand, output: Int32) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    var error = posix_spawn_file_actions_init(&actions)
    guard error == 0 else { throw POSIXError(.ENOMEM) }
    defer { posix_spawn_file_actions_destroy(&actions) }
    error = posix_spawnattr_init(&attributes)
    guard error == 0 else { throw POSIXError(.ENOMEM) }
    defer { posix_spawnattr_destroy(&attributes) }
    var signals = sigset_t()
    sigemptyset(&signals)
    error = posix_spawnattr_setsigmask(&attributes, &signals)
    if error == 0 {
      sigfillset(&signals)
      error = posix_spawnattr_setsigdefault(&attributes, &signals)
    }
    if error == 0 {
      // 独立会话隔离继承的终端和进程组，取消只影响本次启动的 Mole 及其子进程。
      error = posix_spawnattr_setflags(
        &attributes,
        Int16(
          POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID
            | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
    }
    if error == 0 {
      error = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    }
    if error == 0 { error = posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO) }
    if error == 0 { error = posix_spawn_file_actions_adddup2(&actions, output, STDERR_FILENO) }
    guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EINVAL) }
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = [
      executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
      "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ].joined(separator: ":")
    environment["TERM"] = "dumb"
    environment["NO_COLOR"] = "1"
    if command == .install {
      // 只安装用户请求的 Mole，不附带更新索引或清理其他软件包。
      environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
      environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
    }
    let argv = ([executable.path] + command.arguments).map { strdup($0) }
    let env = environment.map { strdup("\($0.key)=\($0.value)") }
    defer { for value in argv + env { free(value) } }
    guard (argv + env).allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
    var pid: pid_t = 0
    error = (argv + [nil]).withUnsafeBufferPointer { args in
      (env + [nil]).withUnsafeBufferPointer { values in
        posix_spawn(
          &pid, executable.path, &actions, &attributes, args.baseAddress!, values.baseAddress!)
      }
    }
    guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EINVAL) }
    return pid
  }

  private static func stopAndReap(_ pid: pid_t) {
    _ = kill(-pid, SIGTERM)
    // 给脚本的退出 trap 留出清理时间；此时 leader 尚未回收，进程组身份稳定。
    usleep(150_000)
    _ = kill(-pid, SIGKILL)
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
  }
}

struct MoleLogBuffer {
  let maximumBytes: Int
  private var data = Data()
  private var wasTruncated = false

  init(maximumBytes: Int = 128 * 1024) { self.maximumBytes = max(0, maximumBytes) }

  mutating func append(_ chunk: Data) {
    data.append(chunk)
    if data.count > maximumBytes {
      // Data.removeFirst 只移动切片起点，不释放已丢弃的前部；复制尾部才能让内存随上限回收。
      data = Data(data.suffix(maximumBytes))
      // 裁剪到 UTF-8 起始边界，避免在日志开头显示半个字符。
      let boundary = data.prefix(while: { $0 & 0xC0 == 0x80 }).count
      if boundary > 0 { data = Data(data.dropFirst(boundary)) }
      wasTruncated = true
    }
  }

  var output: MoleOutput {
    let text = String(decoding: data, as: UTF8.self)
      .replacingOccurrences(
        of: #"\x1B\[[0-?]*[ -/]*[@-~]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)"#,
        with: "", options: .regularExpression
      )
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .filter {
        $0 == "\n" || $0 == "\t"
          || !$0.unicodeScalars.allSatisfy { $0.value < 32 || $0.value == 127 }
      }
    return MoleOutput(text: text, wasTruncated: wasTruncated)
  }
}

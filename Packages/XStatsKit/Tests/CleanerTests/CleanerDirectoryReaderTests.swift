// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import Testing
@testable import Cleaner

struct CleanerDirectoryReaderTests {
  @Test func cancellationStopsAndReapsBlockedReader() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try script(
      "#!/bin/sh\nprintf '%s' \"$$\" > \"$2/started\"\nexec /bin/sleep 30\n", root: root)
    var environment = CleanEnvironment(home: root.path, runningBundleIdentifiers: { [] })
    environment.directoryReaderExecutable = executable
    environment.activeProcessorCount = 2
    environment.scanLoad = { .init(cpuUsage: 0.1, memoryPressure: .normal) }
    let rule = CleanRule(
      id: "blocked", category: .downloads, title: "Fixture", detail: "", symbol: "folder",
      locate: { try RuleCatalog.children(of: $0.home) })
    let scanEnvironment = environment
    let operation = Task { await CleanEngine.scan([rule], environment: scanEnvironment) }
    let marker = root.appendingPathComponent("started")
    let deadline = ContinuousClock.now + .seconds(3)
    while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    // 失败时也先取消，避免夹具留下工作进程。
    operation.cancel()
    let cancelledAt = ContinuousClock.now
    let scans = await operation.value
    let scan = try #require(scans.first)
    #expect(scan.interruption == .cancelled && scan.items.isEmpty)
    #expect(cancelledAt.duration(to: .now) < .seconds(2))
    let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
    errno = 0
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
    var status: Int32 = 0
    #expect(waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD)
  }

  @Test func protocolPreservesNamesAndExcludesHiddenEntries() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let longName = String(repeating: "中", count: 200)
    let executable = try script(
      "#!/bin/sh\nprintf '.\\000..\\000.hidden\\000file with spaces\\000line\\nbreak\\000中文\\000\(longName)\\000'\n",
      root: root)
    let children = try RuleCatalog.children(
      of: root.path,
      budget: ScanBudget(limits: ScanLimits(), directoryReaderExecutable: executable))
    #expect(
      children.map(\.lastPathComponent) == ["file with spaces", "line\nbreak", "中文", longName])
  }

  @Test func failuresNeverReturnPartialLists() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for body in [
      "printf 'visible\\000'; exit 13",
      "printf 'unfinished'; exit 0",
      "printf 'invalid/path\\000'; exit 0",
    ] {
      let executable = try script("#!/bin/sh\n\(body)\n", root: root)
      #expect(throws: (any Error).self) {
        try RuleCatalog.children(
          of: root.path,
          budget: ScanBudget(limits: ScanLimits(), directoryReaderExecutable: executable))
      }
    }
  }

  @Test func missingAndPermissionErrorsKeepTheirMeaning() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try script("#!/bin/sh\nexit 2\n", root: root)
    let absent = try RuleCatalog.childrenIfExists(
      of: root.path,
      budget: ScanBudget(limits: ScanLimits(), directoryReaderExecutable: executable))
    #expect(absent.isEmpty)
    _ = try script("#!/bin/sh\nexit 13\n", root: root)
    #expect(throws: CleanerAccessError.permissionDenied) {
      try RuleCatalog.childrenIfExists(
        of: root.path,
        budget: ScanBudget(limits: ScanLimits(), directoryReaderExecutable: executable))
    }
  }

  @Test func boundedCallersStillCountHiddenNames() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try script("#!/bin/sh\nprintf '.hidden\\000visible\\000'\n", root: root)
    #expect(throws: ScanInterruption.entryLimit) {
      try RuleCatalog.children(
        of: root.path,
        budget: ScanBudget(
          limits: ScanLimits(maxEntries: 1), directoryReaderExecutable: executable))
    }
  }

  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func script(_ body: String, root: URL) throws -> URL {
    let url = root.appendingPathComponent("reader")
    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }
}

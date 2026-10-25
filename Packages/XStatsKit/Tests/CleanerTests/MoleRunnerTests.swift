// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import Testing
@testable import Cleaner

struct MoleRunnerTests {
  @Test func installationUsesHomebrewArgumentsAndDisablesUnrelatedCleanup() async throws {
    let fixture = try MoleFixture(
      #"""
      printf '%s\n' "$@"
      printf '%s:%s\n' "$HOMEBREW_NO_AUTO_UPDATE" "$HOMEBREW_NO_INSTALL_CLEANUP"
      if read -r answer; then exit 9; fi
      """#)
    defer { fixture.remove() }
    let received = MoleOutputProbe()
    let status = try await MoleRunner.run(executable: fixture.executable, command: .install) {
      await received.append($0)
    }
    #expect(status == 0)
    #expect(await received.outputs.last?.text == "install\nmole\n1:1\n")
    #expect(MoleCommand.install.displayCommand == "brew install mole")
  }

  @Test func optimizationUsesExactArguments() async throws {
    let fixture = try MoleFixture("printf '%s\\n' \"$@\"")
    defer { fixture.remove() }
    for command in [MoleCommand.optimizePreview, .optimize] {
      let received = MoleOutputProbe()
      let status = try await MoleRunner.run(executable: fixture.executable, command: command) {
        await received.append($0)
      }
      #expect(status == 0)
      #expect(await received.outputs.last?.text == command.arguments.joined(separator: "\n") + "\n")
      #expect(
        command.arguments
          == (command == .optimizePreview ? ["optimize", "--dry-run"] : ["optimize"]))
    }
  }

  @Test func resolvesOnlyExecutableMoleFiles() throws {
    let fixture = try MoleFixture("exit 0")
    defer { fixture.remove() }
    #expect(MoleRunner.executable(in: [fixture.directory]) == fixture.executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: fixture.executable.path)
    #expect(MoleRunner.executable(in: [fixture.directory]) == nil)
    #expect(MoleRunner.executable(in: []) == nil)
  }

  @Test func usesExactArgumentsAndStreamsBeforeExit() async throws {
    let fixture = try MoleFixture(
      #"""
      printf '%s\n' "$@"
      printf 'first\n'
      sleep 0.5
      printf 'last\n' >&2
      exit 7
      """#)
    defer { fixture.remove() }
    let received = MoleOutputProbe()
    let status = try await MoleRunner.run(executable: fixture.executable, command: .scan) {
      await received.append($0)
    }
    let outputs = await received.outputs
    #expect(status == 7)
    #expect(outputs.first?.text.contains("first") == true)
    #expect(outputs.first?.text.contains("last") == false)
    #expect(outputs.last?.text.contains("clean\n--dry-run\n") == true)
    #expect(outputs.last?.text.contains("last") == true)
    let clean = MoleOutputProbe()
    _ = try await MoleRunner.run(executable: fixture.executable, command: .clean) {
      await clean.append($0)
    }
    #expect(await clean.outputs.last?.text.contains("--dry-run") == false)
  }

  @Test func outputIsBoundedAndTerminalSequencesAreRemoved() {
    var buffer = MoleLogBuffer(maximumBytes: 64)
    buffer.append(Data("\u{1B}[31mhello\u{1B}[0m\r\n中文".utf8))
    #expect(buffer.output.text == "hello\n中文")
    buffer.append(Data(repeating: 65, count: 200))
    #expect(buffer.output.wasTruncated)
    #expect(buffer.output.text.utf8.count <= 64)
  }

  @Test func trimmingKeepsTheTailOnAUTF8BoundaryAndReleasesStorage() {
    var buffer = MoleLogBuffer(maximumBytes: 8)
    // 裁剪点落在“中”的中间字节，开头不能留下半个字符。
    buffer.append(Data("ab中文xyz".utf8))
    #expect(buffer.output.text == "文xyz")
    #expect(buffer.output.wasTruncated)
    for _ in 0..<1_000 { buffer.append(Data(repeating: 66, count: 4096)) }
    #expect(buffer.output.text == String(repeating: "B", count: 8))
  }

  @Test func onlyAnExecutableReportingMoleIsAccepted() throws {
    let mole = try MoleFixture("echo 'Mole version 1.63.0'")
    let other = try MoleFixture("echo 'mo 3.0.0'")
    let failing = try MoleFixture("echo Mole; exit 1")
    let hanging = try MoleFixture("sleep 30")
    defer { [mole, other, failing, hanging].forEach { $0.remove() } }
    #expect(MoleRunner.identifiesAsMole(mole.executable))
    #expect(!MoleRunner.identifiesAsMole(other.executable))
    #expect(!MoleRunner.identifiesAsMole(failing.executable))
    #expect(!MoleRunner.identifiesAsMole(hanging.executable, timeout: .milliseconds(300)))
  }

  @Test(.timeLimit(.minutes(1))) func identityCheckDoesNotWaitForInheritedOutputOrIgnoredTerm()
    throws
  {
    // 子进程继承输出管道后，EOF 要等它退出；身份检测只以 leader 退出为准。
    let inherited = try MoleFixture("sleep 3 &\necho 'Mole version 1.63.0'")
    let stubborn = try MoleFixture("trap '' TERM\nwhile :; do sleep 1; done")
    defer { [inherited, stubborn].forEach { $0.remove() } }
    let start = ContinuousClock.now
    #expect(MoleRunner.identifiesAsMole(inherited.executable))
    #expect(!MoleRunner.identifiesAsMole(stubborn.executable, timeout: .milliseconds(300)))
    #expect(start.duration(to: .now) < .seconds(2.5))
  }

  @Test(arguments: [false, true], [MoleCommand.scan, .install])
  func cancellationStopsTheOwnedProcessGroup(
    ignoresTermination: Bool, command: MoleCommand
  ) async throws {
    let fixture = try MoleFixture(
      (ignoresTermination ? "trap '' TERM\n" : "") + #"""
        sleep 30 &
        echo "$!"
        wait
        """#)
    defer { fixture.remove() }
    let received = MoleOutputProbe()
    let task = Task {
      try await MoleRunner.run(executable: fixture.executable, command: command) {
        await received.append($0)
      }
    }
    for _ in 0..<100 {
      if await received.outputs.first != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let child = try #require(
      await received.outputs.first.flatMap {
        Int32($0.text.trimmingCharacters(in: .whitespacesAndNewlines))
      })
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    for _ in 0..<100 {
      if kill(child, 0) != 0 { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(kill(child, 0) != 0)
  }

  @Test func cancellationBeforeLaunchDoesNotExecute() async throws {
    let fixture = try MoleFixture("touch \"$0.executed\"")
    defer { fixture.remove() }
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await MoleRunner.run(executable: fixture.executable, command: .clean) { _ in }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: fixture.executable.path + ".executed"))
  }

  @Test func inheritedOutputDoesNotKeepTheRunAlive() async throws {
    let fixture = try MoleFixture("sleep 30 &\necho \"$!\"\nexit 0")
    defer { fixture.remove() }
    let received = MoleOutputProbe()
    let clock = ContinuousClock()
    let started = clock.now
    let status = try await MoleRunner.run(executable: fixture.executable, command: .scan) {
      await received.append($0)
    }
    #expect(status == 0)
    #expect(started.duration(to: clock.now) < .seconds(3))
    let child = try #require(
      await received.outputs.last.flatMap {
        Int32($0.text.trimmingCharacters(in: .whitespacesAndNewlines))
      })
    for _ in 0..<100 {
      if kill(child, 0) != 0 { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(kill(child, 0) != 0)
  }

  @Test func largeOutputKeepsBoundedTailAndFinalDiagnostics() async throws {
    let fixture = try MoleFixture(
      "head -c 1048576 /dev/zero | tr '\\000' x\nprintf '\\nfinal diagnostic\\n'")
    defer { fixture.remove() }
    let received = MoleOutputProbe()
    let status = try await MoleRunner.run(executable: fixture.executable, command: .scan) {
      await received.append($0)
    }
    let outputs = await received.outputs
    #expect(status == 0)
    #expect(outputs.allSatisfy { $0.text.utf8.count <= 128 * 1024 })
    #expect(outputs.last?.wasTruncated == true)
    #expect(outputs.last?.text.hasSuffix("final diagnostic\n") == true)
  }
}

private actor MoleOutputProbe {
  var outputs: [MoleOutput] = []
  func append(_ output: MoleOutput) { outputs.append(output) }
}

private struct MoleFixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  var executable: URL { directory.appendingPathComponent("mo") }

  init(_ body: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try ("#!/bin/sh\n" + body + "\n").write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}

// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import Testing
@testable import Cleaner

struct MoleRunnerTests {
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

  @Test(arguments: [false, true])
  func cancellationStopsTheOwnedProcessGroup(ignoresTermination: Bool) async throws {
    let fixture = try MoleFixture(
      (ignoresTermination ? "trap '' TERM\n" : "") + #"""
        sleep 30 &
        echo "$!"
        wait
        """#)
    defer { fixture.remove() }
    let received = MoleOutputProbe()
    let task = Task {
      try await MoleRunner.run(executable: fixture.executable, command: .scan) {
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

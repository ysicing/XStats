// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import Testing
@testable import Cleaner

struct MoleRunnerTests {
  @Test(arguments: [MoleCommand.scan, .clean])
  func cleanupDoesNotRequestAuthorizationByDefault(command: MoleCommand) async throws {
    let fixture = try MoleFixture(
      "printf '%s\\n' \"$@\"", authorization: "printf 'unexpected authorization\\n'")
    defer { fixture.remove() }
    let received = MoleOutputProbe()
    let status = try await MoleRunner.run(executable: fixture.executable, command: command) {
      await received.append($0)
    }
    #expect(status == 0)
    #expect(await received.outputs.last?.text == command.arguments.joined(separator: "\n") + "\n")
  }

  @Test(arguments: [MoleCommand.scan, .clean])
  func cleanupUsesMoleGUIAuthorizationWhenRequested(command: MoleCommand) async throws {
    let fixture = try MoleFixture(
      "printf '%s\\n' \"$@\"",
      authorization: #"""
        [[ "$is_gui_mode" == true ]] || return 1
        printf 'GUI authorization\n'
        """#)
    defer { fixture.remove() }
    let received = MoleOutputProbe()
    let status = try await MoleRunner.run(
      executable: fixture.executable, command: command, requestAdministratorAccess: true
    ) {
      await received.append($0)
    }
    #expect(status == 0)
    #expect(
      await received.outputs.last?.text
        == "GUI authorization\n" + command.arguments.joined(separator: "\n") + "\n")
  }

  @Test(arguments: [MoleCommand.scan, .clean])
  func cleanupAuthorizesBeforeExecutingInTheSameProcess(command: MoleCommand) async throws {
    let fixture = try MoleFixture(
      #"""
      printf '%s\n' "$$"
      cat "$(dirname "$0")/lib/core/authorized-pid"
      printf '%s\n' "$@"
      """#,
      authorization: #"""
        printf '%s\n' "$$" > "$MOLE_FIXTURE_CORE/authorized-pid"
        """#)
    defer { fixture.remove() }
    let received = MoleOutputProbe()
    let status = try await MoleRunner.run(
      executable: fixture.executable, command: command, requestAdministratorAccess: true
    ) {
      await received.append($0)
    }
    let lines = try #require(await received.outputs.last?.text.split(separator: "\n"))
    #expect(status == 0)
    #expect(lines.count == 2 + command.arguments.count)
    #expect(lines.first == lines.dropFirst().first)
    #expect(lines.suffix(command.arguments.count).map(String.init) == command.arguments)
  }

  @Test(arguments: [1, 2, 130], [MoleCommand.scan, .clean])
  func deniedAuthorizationFallsBackToOrdinaryCleanup(
    authorizationStatus: Int, command: MoleCommand
  ) async throws {
    let fixture = try MoleFixture(
      "printf '%s\\n' \"$@\"", authorization: "return \(authorizationStatus)")
    defer { fixture.remove() }
    let received = MoleOutputProbe()
    let status = try await MoleRunner.run(
      executable: fixture.executable, command: command, requestAdministratorAccess: true
    ) {
      await received.append($0)
    }
    #expect(status == 0)
    #expect(
      await received.outputs.last?.text.hasSuffix(command.arguments.joined(separator: "\n") + "\n")
        == true)
  }

  @Test(arguments: [MoleCommand.scan, .clean])
  func missingAuthorizationSupportFallsBackToOrdinaryCleanup(command: MoleCommand) async throws {
    let fixture = try MoleFixture("printf '%s\\n' \"$@\"")
    defer { fixture.remove() }
    try FileManager.default.removeItem(
      at: fixture.directory.appendingPathComponent("lib/core/sudo.sh"))
    let received = MoleOutputProbe()
    let status = try await MoleRunner.run(
      executable: fixture.executable, command: command, requestAdministratorAccess: true
    ) {
      await received.append($0)
    }
    #expect(status == 0)
    #expect(
      await received.outputs.last?.text.hasSuffix(command.arguments.joined(separator: "\n") + "\n")
        == true)
  }

  @Test(
    arguments: ["", "request_sudo_access() { return 0; }\n", "return 1\n"],
    [MoleCommand.scan, .clean])
  func incompatibleAuthorizationLibraryFallsBackToOrdinaryCleanup(
    library: String, command: MoleCommand
  ) async throws {
    let fixture = try MoleFixture("printf '%s\\n' \"$@\"")
    defer { fixture.remove() }
    try library.write(
      to: fixture.directory.appendingPathComponent("lib/core/sudo.sh"),
      atomically: true, encoding: .utf8)
    let received = MoleOutputProbe()
    let status = try await MoleRunner.run(
      executable: fixture.executable, command: command, requestAdministratorAccess: true
    ) {
      await received.append($0)
    }
    #expect(status == 0)
    #expect(
      await received.outputs.last?.text.hasSuffix(command.arguments.joined(separator: "\n") + "\n")
        == true)
  }

  @Test func ordinaryPreviewFailureIsNotHiddenByAuthorizationFallback() async throws {
    let fixture = try MoleFixture("printf '%s\\n' \"$@\"; exit 7", authorization: "return 1")
    defer { fixture.remove() }
    let received = MoleOutputProbe()
    let status = try await MoleRunner.run(
      executable: fixture.executable, command: .scan, requestAdministratorAccess: true
    ) {
      await received.append($0)
    }
    #expect(status == 7)
    #expect(await received.outputs.last?.text.hasSuffix("clean\n--dry-run\n") == true)
  }

  @Test(arguments: [false, true])
  func previewResolvesAuthorizationLibrariesThroughSymlinks(homebrew: Bool) async throws {
    let fixture = try MoleFixture("printf '%s\\n' \"$@\"")
    defer { fixture.remove() }
    var target = fixture.executable
    if homebrew {
      let bin = fixture.directory.appendingPathComponent("bin")
      let libexec = fixture.directory.appendingPathComponent("libexec")
      try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: libexec, withIntermediateDirectories: true)
      target = bin.appendingPathComponent("mo")
      try FileManager.default.moveItem(at: fixture.executable, to: target)
      try FileManager.default.moveItem(
        at: fixture.directory.appendingPathComponent("lib"),
        to: libexec.appendingPathComponent("lib"))
    }
    let alias = fixture.directory.appendingPathComponent("mo alias ' $HOME")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
    let received = MoleOutputProbe()
    let status = try await MoleRunner.run(
      executable: alias, command: .scan, requestAdministratorAccess: true
    ) {
      await received.append($0)
    }
    #expect(status == 0)
    #expect(await received.outputs.last?.text == "clean\n--dry-run\n")
  }

  @Test func otherCommandsDoNotRequestCleanupAuthorization() async throws {
    let fixture = try MoleFixture("printf '%s\\n' \"$@\"", authorization: "return 1")
    defer { fixture.remove() }
    for command in [MoleCommand.optimizePreview, .optimize, .install] {
      let received = MoleOutputProbe()
      let status = try await MoleRunner.run(
        executable: fixture.executable, command: command, requestAdministratorAccess: true
      ) {
        await received.append($0)
      }
      #expect(status == 0)
      #expect(await received.outputs.last?.text == command.arguments.joined(separator: "\n") + "\n")
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [MoleCommand.scan, .clean])
  func cancellationDuringAuthorizationDoesNotStartCleanup(command: MoleCommand) async throws {
    let fixture = try MoleFixture(
      "touch \"$0.executed\"",
      authorization: #"""
        sleep 30 &
        echo "$!"
        wait
        """#)
    defer { fixture.remove() }
    let received = MoleOutputProbe()
    let task = Task {
      try await MoleRunner.run(
        executable: fixture.executable, command: command, requestAdministratorAccess: true
      ) {
        await received.append($0)
      }
    }
    defer { task.cancel() }
    for _ in 0..<100 {
      if await received.outputs.first != nil || task.isCancelled { break }
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
    #expect(!FileManager.default.fileExists(atPath: fixture.executable.path + ".executed"))
  }

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

  @Test(.timeLimit(.minutes(1))) func usesExactArgumentsAndStreamsBeforeExit() async throws {
    let fixture = try MoleFixture(
      #"""
      printf 'first\n'
      attempts=0
      while [ ! -f "$0.continue" ]; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 200 ] || exit 99
        sleep 0.05
      done
      printf '%s\n' "$@"
      printf 'last\n' >&2
      exit 7
      """#)
    defer { fixture.remove() }
    // 收到首段输出后才放行脚本，验证流式回调，不依赖测试线程能在固定时间内获调度。
    let acknowledgement = fixture.executable.appendingPathExtension("continue")
    let received = MoleOutputProbe()
    let status = try await MoleRunner.run(executable: fixture.executable, command: .scan) {
      await received.append($0)
      if $0.text.contains("first") {
        #expect(FileManager.default.createFile(atPath: acknowledgement.path, contents: nil))
      }
    }
    let outputs = await received.outputs
    #expect(status == 7)
    #expect(outputs.first?.text.contains("first") == true)
    #expect(outputs.first?.text.contains("last") == false)
    #expect(outputs.last?.text.contains("clean\n--dry-run\n") == true)
    #expect(outputs.last?.text.contains("last") == true)
    try FileManager.default.removeItem(at: acknowledgement)
    let clean = MoleOutputProbe()
    let cleanStatus = try await MoleRunner.run(executable: fixture.executable, command: .clean) {
      await clean.append($0)
      if $0.text.contains("first") {
        #expect(FileManager.default.createFile(atPath: acknowledgement.path, contents: nil))
      }
    }
    #expect(cleanStatus == 7)
    #expect(await clean.outputs.last?.text.contains("clean\n") == true)
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

  init(_ body: String, authorization: String = "return 0") throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try ("#!/bin/sh\n" + body + "\n").write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let core = directory.appendingPathComponent("lib/core")
    try FileManager.default.createDirectory(at: core, withIntermediateDirectories: true)
    try "".write(to: core.appendingPathComponent("base.sh"), atomically: true, encoding: .utf8)
    try
      ("MOLE_FIXTURE_CORE=\"$(dirname \"${BASH_SOURCE[0]}\")\"\n"
      + "request_sudo_access() {\nlocal is_gui_mode=false\n" + authorization + "\n}\n")
      .write(to: core.appendingPathComponent("sudo.sh"), atomically: true, encoding: .utf8)
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}

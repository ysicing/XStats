#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Compile Helper recovery methods with fake hardware; never start XPC or run tools."""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def fragment(source, start, end):
    return source[source.index(start):source.index(end)]


def main():
    helper = (ROOT / "Apps/XStats/Helper/main.swift").read_text()
    state = (ROOT / "Packages/XStatsKit/Sources/HelperShared/HelperRecoveryState.swift").read_text()
    methods = (
        fragment(helper, "  func setFanTarget(", "  func resetAllFans(")
        + fragment(helper, "  private func resetFans()", "  // MARK: 系统维护")
        + fragment(helper, "  private func persist(", "\n}\n\nHelperService")
    )
    fixture = r'''
import Foundation
import os

private let log = Logger(subsystem: "work.12306.xstats.helper.tests", category: "recovery")

enum Failure: Error { case simulated, assertion(String) }

func check(_ condition: Bool, _ message: String) throws {
  if !condition { throw Failure.assertion(message) }
}

final class FakeFans {
  var detectedFanCount: Int? = 2
  var manualWrites = 0
  var automaticWrites = 0
  var resetWrites = 0
  var failManual = false
  var failRestore = false
  var beforeManual: (() throws -> Void)?

  func setManual(fan: Int, rpm: Double) throws {
    try beforeManual?()
    manualWrites += 1
    if failManual { throw Failure.simulated }
  }

  func setAutomatic(fan: Int) throws {
    automaticWrites += 1
    if failRestore { throw Failure.simulated }
  }

  func resetAll() throws {
    resetWrites += 1
    if failRestore { throw Failure.simulated }
  }
}

final class Fixture: @unchecked Sendable {
  private let queue = DispatchQueue(label: "helper.recovery.test")
  let stateURL: URL
  var recoveryState = HelperRecoveryState()
  var fans: FakeFans? = FakeFans()
  var toolCalls: [[String]] = []
  var toolStatus: Int32 = 0
  var beforeTool: (() -> Void)?

  init(_ stateURL: URL) { self.stateURL = stateURL }

  func runTool(_ path: String, _ arguments: [String], timeout: TimeInterval)
    -> (status: Int32, output: String)
  {
    precondition(path == "/usr/bin/pmset")
    beforeTool?()
    toolCalls.append(arguments)
    return (toolStatus, "simulated")
  }

  func target() async -> String? {
    await withCheckedContinuation { continuation in
      setFanTarget(fan: 0, rpm: 2_000) { continuation.resume(returning: $0) }
    }
  }

  func automatic() async -> String? {
    await withCheckedContinuation { continuation in
      setFanAutomatic(fan: 0) { continuation.resume(returning: $0) }
    }
  }

  func sleep(_ disabled: Bool) -> String? { applySleepDisabled(disabled) }
  func reset() -> String? { resetFans() }

  func stored() throws -> HelperRecoveryState {
    try PropertyListDecoder().decode(HelperRecoveryState.self, from: Data(contentsOf: stateURL))
  }
'''
    tests = r'''
@main struct RecoveryTests {
  static func main() async throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let blocker = root.appendingPathComponent("blocker")
    try Data().write(to: blocker)
    let directory = root.appendingPathComponent("directory-state.plist")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for stateURL in [blocker.appendingPathComponent("state.plist"), directory] {
      let blocked = Fixture(stateURL)
      blocked.recoveryState.recordFanOverride(1)
      try check(blocked.sleep(true) != nil, "Sleep takeover must fail when intent cannot persist")
      try check(blocked.toolCalls.isEmpty, "Failed persistence must not run pmset")
      try check(!blocked.recoveryState.sleepDisabled, "Failed preflight must not change memory intent")
      try check(blocked.recoveryState.fansOverridden, "Other pending recovery must survive")
      let targetError = await blocked.target()
      try check(targetError != nil, "Fan takeover must fail when intent cannot persist")
      try check(blocked.fans?.manualWrites == 0, "Failed persistence must not write fan mode")
      blocked.recoveryState.recordFanRestored(1)
      try check(!blocked.recoveryState.fansOverridden, "Failed preflight must not add a fan marker")
      blocked.recoveryState.recordFanOverride(1)

      blocked.recoveryState.sleepDisabled = true
      try check(blocked.sleep(false) == nil, "Sleep restoration must run despite disk failure")
      try check(blocked.toolCalls == [["-a", "disablesleep", "0"]], "Only restoration may run")
      try check(!blocked.recoveryState.sleepDisabled, "Successful sleep restoration clears its flag")
      try check(blocked.recoveryState.fansOverridden, "Sleep restore must preserve fan flag")
      let automaticError = await blocked.automatic()
      try check(automaticError == nil, "Fan restoration must run despite disk failure")
      try check(blocked.fans?.automaticWrites == 1, "Automatic restore must reach hardware")
      try check(blocked.recoveryState.fansOverridden, "Other fan must remain pending")
      try check(blocked.reset() == nil, "Global restoration must run despite disk failure")
      try check(blocked.fans?.resetWrites == 1, "Global restore must reach hardware")
    }

    let sleep = Fixture(root.appendingPathComponent("sleep/state.plist"))
    sleep.recoveryState.recordFanOverride(1)
    sleep.beforeTool = {
      let stored = try! sleep.stored()
      precondition(stored.sleepDisabled && stored.fansOverridden)
    }
    sleep.toolStatus = -1
    try check(sleep.sleep(true) != nil, "Simulated partial pmset failure must be reported")
    try check(try sleep.stored().sleepDisabled, "Partial pmset failure keeps durable intent")
    sleep.beforeTool = nil
    try check(sleep.sleep(false) != nil, "Failed sleep restore must be reported")
    try check(try sleep.stored().sleepDisabled, "Failed restore keeps durable intent")
    sleep.toolStatus = 0
    try check(sleep.sleep(false) == nil, "Successful sleep restore")
    let sleepState = try sleep.stored()
    try check(!sleepState.sleepDisabled && sleepState.fansOverridden, "Keep independent fan flag")

    let fan = Fixture(root.appendingPathComponent("fan/state.plist"))
    fan.recoveryState.sleepDisabled = true
    fan.fans?.beforeManual = {
      let stored = try fan.stored()
      try check(stored.fansOverridden && stored.sleepDisabled, "Persist all intent before fan write")
    }
    fan.fans?.failManual = true
    let partialError = await fan.target()
    try check(partialError != nil, "Partial fan failure must be reported")
    try check(try fan.stored().fansOverridden, "Partial fan failure keeps durable intent")
    fan.fans?.failRestore = true
    try check(fan.reset() != nil, "Failed reset must be reported")
    try check(try fan.stored().fansOverridden, "Failed reset keeps durable intent")
    fan.fans?.failRestore = false
    try check(fan.reset() == nil, "Successful fan reset")
    let fanState = try fan.stored()
    try check(!fanState.fansOverridden && fanState.sleepDisabled, "Keep independent sleep flag")
    try check(fan.sleep(false) == nil, "Restore final pending setting")
    try check(!FileManager.default.fileExists(atPath: fan.stateURL.path), "Remove completed state")

    let clean = Fixture(root.appendingPathComponent("missing/state.plist"))
    try check(clean.sleep(false) == nil && clean.reset() == nil, "Missing recovery file is harmless")
    print("Helper recovery: persistence gate, partial failures and independent restoration passed")
  }
}
'''
    with tempfile.TemporaryDirectory(prefix="xstats-helper-recovery-") as temporary:
        work = Path(temporary)
        source = work / "RecoveryTests.swift"
        source.write_text(state + fixture + methods + "\n}\n" + tests)
        binary = work / "recovery-tests"
        subprocess.run(
            ["swiftc", "-swift-version", "6", "-parse-as-library",
             "-module-cache-path", str(work / "module-cache"), str(source), "-o", str(binary)],
            check=True,
        )
        subprocess.run([str(binary), str(work)], check=True, timeout=20)


if __name__ == "__main__":
    main()

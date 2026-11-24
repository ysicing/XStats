import Foundation
import Testing
@testable import Cleaner

@Suite struct LaunchItemsTests {
  @Test func parsesPlist() throws {
    let url = URL(fileURLWithPath: "/tmp/com.example.agent.plist")
    let item = try #require(
      LaunchItems.item(
        from: [
          "Label": "com.example.agent",
          "ProgramArguments": ["/Applications/Example.app/Contents/MacOS/agent", "--wake"],
          "RunAtLoad": true,
          "KeepAlive": ["SuccessfulExit": false],
        ], plist: url, scope: .user))
    #expect(item.program == "/Applications/Example.app/Contents/MacOS/agent")
    #expect(item.appBundlePath == "/Applications/Example.app")
    #expect(item.runAtLoad && item.keepAlive && !item.disabledInPlist)
    #expect(LaunchItems.item(from: ["Program": "/bin/true"], plist: url, scope: .user) == nil)
  }

  @Test func parsesLaunchctlOutput() {
    let list = "PID\tStatus\tLabel\n-\t78\tcom.example.idle\n2879\t-15\tcom.example.running\n"
    let status = LaunchItems.parseList(list)
    let loaded = status.loaded
    #expect(loaded["com.example.running"] == .some(2879))
    #expect(loaded["com.example.idle"] == .some(nil))
    #expect(loaded["com.example.missing"] == nil)
    #expect(status.exitStatuses == ["com.example.idle": 78, "com.example.running": -15])
    #expect(LaunchItems.parseList("Warning\n-\t78\tcom.example.idle").loaded.isEmpty)

    let disabled = LaunchItems.parseDisabled(
      """
      \tdisabled services = {
      \t\t"com.example.on" => enabled
      \t\t"com.example.off" => disabled
      \t}
      """)
    #expect(disabled["com.example.on"] == false)
    #expect(disabled["com.example.off"] == true)
  }

  @Test func parsesSchedulesAndLogsFromDictionaryAndArray() throws {
    let url = URL(fileURLWithPath: "/tmp/com.example.sync.plist")
    let item = try #require(
      LaunchItems.item(
        from: [
          "Label": "com.example.sync",
          "StartInterval": 300,
          "StartCalendarInterval": [
            ["Hour": 8, "Minute": 0],
            ["Weekday": 7, "Hour": 22],
            ["Month": 14],
            ["Hour": true],
          ] as [[String: Any]],
          "WatchPaths": ["/tmp/incoming"],
          "StandardOutPath": "/tmp/sync.log",
          "StandardErrorPath": "relative.log",
        ], plist: url, scope: .user))
    #expect(item.details.interval == 300)
    #expect(item.details.schedules.count == 2)
    #expect(item.details.schedules.first?.hour == 8 && item.details.schedules.first?.minute == 0)
    #expect(item.details.schedules.last?.weekday == 7 && item.details.schedules.last?.minute == nil)
    #expect(item.details.watchedPaths == ["/tmp/incoming"])
    #expect(item.details.standardOutput == "/tmp/sync.log")
    #expect(item.details.standardError == nil)

    let daemon = try #require(
      LaunchItems.item(
        from: ["Label": "daemon", "StartCalendarInterval": ["Day": 15]],
        plist: url, scope: .system))
    #expect(daemon.details.schedules.map(\.day) == [15])
  }

  @Test func invalidConfigurationsRemainVisibleAndCannotBeEnabled() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).plist")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(LaunchItems.scanItem(at: url, scope: .user).configurationIssue == .unreadable)
    try Data("invalid plist".utf8).write(to: url)
    let damaged = LaunchItems.scanItem(at: url, scope: .user)
    #expect(damaged.configurationIssue == .invalidPlist)
    #expect(damaged.label == url.lastPathComponent && damaged.scope == .user)
    let refused = LaunchItems.setEnabled(true, item: damaged) { _ in
      Issue.record("Invalid configuration reached launchctl")
      return (0, "")
    }
    #expect(refused != nil)

    let missingLabel = try PropertyListSerialization.data(
      fromPropertyList: ["RunAtLoad": true], format: .binary, options: 0)
    try missingLabel.write(to: url)
    #expect(LaunchItems.scanItem(at: url, scope: .user).configurationIssue == .missingLabel)
    try Data(count: 1_048_577).write(to: url)
    #expect(LaunchItems.scanItem(at: url, scope: .user).configurationIssue == .tooLarge)
  }

  @Test func refusesNonUserItems() {
    let item = LaunchItem(
      label: "com.example.daemon", plist: URL(fileURLWithPath: "/Library/LaunchDaemons/x.plist"),
      scope: .system,
      program: nil, runAtLoad: true, keepAlive: false, disabledInPlist: false)
    #expect(LaunchItems.setEnabled(false, item: item) != nil)
  }

  @Test(arguments: [true, false])
  func failedOverrideDoesNotAttemptLoading(_ enabled: Bool) throws {
    let item = try userItem()
    defer { try? FileManager.default.removeItem(at: item.plist) }
    var commands: [[String]] = []
    let error = LaunchItems.setEnabled(enabled, item: item) { arguments in
      commands.append(arguments)
      return arguments.first == (enabled ? "enable" : "disable")
        ? (1, "override denied") : (0, "")
    }
    #expect(error != nil)
    #expect(commands == [[enabled ? "enable" : "disable", "gui/\(getuid())/com.example.agent"]])
  }

  @Test(arguments: [Int32(5), 37, 1])
  func bootstrapFailureRequiresConfirmedLoadedService(_ status: Int32) throws {
    let item = try userItem()
    defer { try? FileManager.default.removeItem(at: item.plist) }
    var commands: [[String]] = []
    let error = LaunchItems.setEnabled(true, item: item) { arguments in
      commands.append(arguments)
      switch arguments.first {
      case "enable": return (0, "")
      case "bootstrap": return (status, "Input/output error")
      case "list": return (0, "PID\tStatus\tLabel\n")
      default: return (1, "unexpected command")
      }
    }
    #expect(error != nil)
    #expect(commands.last == ["list"])
  }

  @Test(arguments: ["-", "42"])
  func alreadyLoadedBootstrapIsIdempotentEvenWithoutPID(_ pid: String) throws {
    let item = try userItem()
    defer { try? FileManager.default.removeItem(at: item.plist) }
    let error = LaunchItems.setEnabled(true, item: item) { arguments in
      switch arguments.first {
      case "enable": return (0, "")
      case "bootstrap": return (5, "Input/output error")
      case "list": return (0, "PID\tStatus\tLabel\n\(pid)\t0\tcom.example.agent\n")
      default: return (1, "unexpected command")
      }
    }
    #expect(error == nil)
  }

  @Test(arguments: [Int32(0), 1])
  func failedStatusReadCannotConfirmUnloadedService(_ readStatus: Int32) throws {
    let item = try userItem()
    defer { try? FileManager.default.removeItem(at: item.plist) }
    let error = LaunchItems.setEnabled(false, item: item) { arguments in
      switch arguments.first {
      case "disable": return (0, "")
      case "bootout": return (3, "No such process")
      case "list": return (readStatus, "unrecognized output")
      default: return (1, "unexpected command")
      }
    }
    #expect(error != nil)
  }

  @Test(arguments: [false, true])
  func bootoutFailureRequiresConfirmedAbsence(_ loaded: Bool) throws {
    let item = try userItem()
    defer { try? FileManager.default.removeItem(at: item.plist) }
    let error = LaunchItems.setEnabled(false, item: item) { arguments in
      switch arguments.first {
      case "disable": return (0, "")
      case "bootout": return (3, "No such process")
      case "list":
        return (0, "PID\tStatus\tLabel\n" + (loaded ? "-\t0\tcom.example.agent\n" : ""))
      default: return (1, "unexpected command")
      }
    }
    #expect((error == nil) == !loaded)
  }

  private func userItem() throws -> LaunchItem {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "launch-item-\(UUID().uuidString).plist")
    let plist = ["Label": "com.example.agent"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: url)
    return try #require(LaunchItems.item(from: plist, plist: url, scope: .user))
  }

  @Test(arguments: ["Label", "Program", "ProgramArguments", "missing", "symlink"])
  func changedPlistIsRejectedBeforeAnyLaunchctlWrite(_ change: String) throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "launch-item-audit-\(UUID().uuidString).plist")
    let linkTarget = url.appendingPathExtension("target")
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: linkTarget)
    }
    var plist: [String: Any] = [
      "Label": "com.audit.original", "Program": "/usr/bin/true",
      "ProgramArguments": ["/usr/bin/true", "--original"],
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: url)
    let item = try #require(LaunchItems.item(from: plist, plist: url, scope: .user))
    switch change {
    case "Label": plist["Label"] = "com.audit.replacement"
    case "Program": plist["Program"] = "/usr/bin/false"
    case "ProgramArguments": plist["ProgramArguments"] = ["/usr/bin/true", "--replacement"]
    default: break
    }
    if change == "missing" || change == "symlink" {
      try FileManager.default.removeItem(at: url)
      if change == "symlink" {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
          .write(to: linkTarget)
        try FileManager.default.createSymbolicLink(
          at: url, withDestinationURL: linkTarget)
      }
    } else {
      try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: url)
    }
    var commands: [[String]] = []

    let error = LaunchItems.setEnabled(true, item: item) { arguments in
      commands.append(arguments)
      return (0, "")
    }

    #expect(error != nil)
    #expect(commands.isEmpty)
  }

  @Test(arguments: ["RunAtLoad", "KeepAlive", "integerToReal"], [true, false])
  func changedPlistValueTypeIsRejected(_ change: String, _ enabled: Bool) throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "launch-item-type-\(UUID().uuidString).plist")
    defer { try? FileManager.default.removeItem(at: url) }
    var plist: [String: Any] = [
      "Label": "com.example.agent", "RunAtLoad": true,
      "KeepAlive": ["SuccessfulExit": false], "ExitTimeOut": 1,
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: url)
    let item = try #require(LaunchItems.item(from: plist, plist: url, scope: .user))
    switch change {
    case "RunAtLoad": plist["RunAtLoad"] = 1
    case "KeepAlive": plist["KeepAlive"] = ["SuccessfulExit": 0]
    default: plist["ExitTimeOut"] = 1.0
    }
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: url)
    var commands: [[String]] = []
    let error = LaunchItems.setEnabled(enabled, item: item) {
      commands.append($0)
      return (0, "")
    }
    #expect(error != nil)
    #expect(commands.isEmpty)
  }

  @Test func equivalentPlistEncodingStillAllowsControl() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "launch-item-encoding-\(UUID().uuidString).plist")
    defer { try? FileManager.default.removeItem(at: url) }
    let plist: [String: Any] = [
      "Label": "com.example.agent", "RunAtLoad": true,
      "KeepAlive": ["SuccessfulExit": false], "ExitTimeOut": 1,
      "EnvironmentVariables": ["MODE": "test"],
      "ProgramArguments": ["/usr/bin/true", "--example"],
    ]
    let item = try #require(LaunchItems.item(from: plist, plist: url, scope: .user))
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: url)
    var commands: [[String]] = []
    let error = LaunchItems.setEnabled(true, item: item) {
      commands.append($0)
      return (0, "")
    }
    #expect(error == nil)
    #expect(commands.count == 2)
  }

  @Test func unchangedPlistStillEnablesTheReviewedService() throws {
    let item = try userItem()
    defer { try? FileManager.default.removeItem(at: item.plist) }
    var commands: [[String]] = []
    let error = LaunchItems.setEnabled(true, item: item) { arguments in
      commands.append(arguments)
      return (0, "")
    }
    #expect(error == nil)
    #expect(
      commands.map { Array($0.prefix(2)) } == [
        ["enable", "gui/\(getuid())/com.example.agent"],
        ["bootstrap", "gui/\(getuid())"],
      ])
    #expect(commands.last == ["bootstrap", "gui/\(getuid())", item.plist.path])
  }

  @Test(arguments: [true, false])
  func publicConstructionRequiresScanBeforeControl(_ enabled: Bool) throws {
    let parsed = try userItem()
    defer { try? FileManager.default.removeItem(at: parsed.plist) }
    let item = LaunchItem(
      label: parsed.label, plist: parsed.plist, scope: .user, program: nil,
      runAtLoad: false, keepAlive: false, disabledInPlist: false)
    var commands: [[String]] = []
    let unscannedError = LaunchItems.setEnabled(enabled, item: item) {
      commands.append($0)
      return (0, "")
    }
    #expect(unscannedError != nil)
    #expect(commands.isEmpty)
    commands.removeAll()
    let scannedError = LaunchItems.setEnabled(enabled, item: parsed) {
      commands.append($0)
      return (0, "")
    }
    #expect(scannedError == nil)
    #expect(
      commands.map { Array($0.prefix(2)) } == [
        [enabled ? "enable" : "disable", "gui/\(getuid())/com.example.agent"],
        enabled
          ? ["bootstrap", "gui/\(getuid())"]
          : ["bootout", "gui/\(getuid())/com.example.agent"],
      ])
    #expect(commands.last?.count == (enabled ? 3 : 2))
  }

  @Test func launchStatusDoesNotMixUserAndSystemDomains() {
    let url = URL(fileURLWithPath: "/tmp/shared.plist")
    let agent = LaunchItem(
      label: "shared", plist: url, scope: .user, program: nil,
      runAtLoad: true, keepAlive: false, disabledInPlist: false)
    let daemon = LaunchItem(
      label: "shared", plist: url, scope: .system, program: nil,
      runAtLoad: true, keepAlive: false, disabledInPlist: false)
    let status = LaunchStatus(
      loaded: ["shared": 42], disabled: ["shared": true],
      systemDisabled: ["shared": false], exitStatuses: ["shared": 78])
    #expect(status.isDisabled(agent))
    #expect(!status.isDisabled(daemon))
    #expect(status.pid(agent) == 42 && status.isLoaded(agent))
    #expect(status.pid(daemon) == nil && !status.isLoaded(daemon))
    #expect(status.lastExitStatus(agent) == 78 && status.lastExitStatus(daemon) == nil)
  }

}

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
    let list = "PID\tStatus\tLabel\n-\t0\tcom.example.idle\n2879\t0\tcom.example.running\n"
    let loaded = LaunchItems.parseList(list)
    #expect(loaded["com.example.running"] == .some(2879))
    #expect(loaded["com.example.idle"] == .some(nil))
    #expect(loaded["com.example.missing"] == nil)

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
      commands == [
        ["enable", "gui/\(getuid())/com.example.agent"],
        ["bootstrap", "gui/\(getuid())", item.plist.path],
      ])
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
      commands == [
        [enabled ? "enable" : "disable", "gui/\(getuid())/com.example.agent"],
        enabled
          ? ["bootstrap", "gui/\(getuid())", item.plist.path]
          : ["bootout", "gui/\(getuid())/com.example.agent"],
      ])
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
      systemDisabled: ["shared": false])
    #expect(status.isDisabled(agent))
    #expect(!status.isDisabled(daemon))
    #expect(status.pid(agent) == 42 && status.isLoaded(agent))
    #expect(status.pid(daemon) == nil && !status.isLoaded(daemon))
  }

}

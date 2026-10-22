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

  @Test(arguments: ["enable", "bootstrap"])
  func bootstrapUsesReviewedConfigurationDespiteConcurrentReplacement(_ replacementPoint: String)
    throws
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "launch-item-race-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("agent.plist")
    let original: [String: Any] = [
      "Label": "com.audit.original",
      "Program": "/usr/bin/true",
      "ProgramArguments": ["true", "--config", url.path, "relative/config.json"],
      "WorkingDirectory": directory.path,
      "StandardOutPath": directory.appendingPathComponent("stdout.log").path,
      "EnvironmentVariables": ["PLIST_PATH": url.path],
      "WatchPaths": [url.path],
      "KeepAlive": ["SuccessfulExit": false],
    ]
    try PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0)
      .write(to: url)
    let item = try #require(LaunchItems.item(from: original, plist: url, scope: .user))
    let replacement: [String: Any] = [
      "Label": "com.audit.replacement",
      "ProgramArguments": ["/usr/bin/false"],
    ]
    let replacementData = try PropertyListSerialization.data(
      fromPropertyList: replacement, format: .xml, options: 0)
    var commands: [[String]] = []
    var loadedConfiguration: [String: Any]?
    let error = LaunchItems.setEnabled(true, item: item) { arguments in
      commands.append(arguments)
      do {
        if arguments.first == replacementPoint {
          try replacementData.write(to: url, options: .atomic)
        }
        switch arguments.first {
        case "enable":
          return (0, "")
        case "bootstrap":
          guard arguments.count == 3 else { return (1, "missing bootstrap path") }
          let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
          loadedConfiguration =
            try PropertyListSerialization.propertyList(
              from: data, format: nil) as? [String: Any]
          return (0, "")
        default:
          return (1, "unexpected command")
        }
      } catch {
        Issue.record(error)
        return (1, "fixture I/O failed")
      }
    }
    #expect(error == nil)
    #expect(commands.first == ["enable", "gui/\(getuid())/com.audit.original"])
    #expect(commands.count == 2)
    let loaded = try #require(loadedConfiguration)
    #expect(NSDictionary(dictionary: loaded).isEqual(to: original))
    let current = try #require(
      PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        as? [String: Any])
    #expect(current["Label"] as? String == "com.audit.replacement")
  }

  @Test(arguments: [Int32(0), 5, 1])
  func bootstrapSnapshotIsPrivateAndCleanedAfterSuccessOrFailure(_ bootstrapStatus: Int32)
    throws
  {
    let item = try userItem()
    defer { try? FileManager.default.removeItem(at: item.plist) }
    var snapshotURL: URL?
    let error = LaunchItems.setEnabled(true, item: item) { arguments in
      switch arguments.first {
      case "enable":
        return (0, "")
      case "bootstrap":
        guard arguments.count == 3 else { return (1, "missing bootstrap path") }
        let url = URL(fileURLWithPath: arguments[2])
        snapshotURL = url
        do {
          let file = try FileManager.default.attributesOfItem(atPath: url.path)
          let directory = try FileManager.default.attributesOfItem(
            atPath: url.deletingLastPathComponent().path)
          #expect(file[.type] as? FileAttributeType == .typeRegular)
          #expect(directory[.type] as? FileAttributeType == .typeDirectory)
          #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
          #expect((directory[.posixPermissions] as? NSNumber)?.intValue == 0o700)
          let loaded =
            try PropertyListSerialization.propertyList(
              from: Data(contentsOf: url), format: nil) as? [String: Any]
          #expect(loaded?["Label"] as? String == "com.example.agent")
        } catch {
          Issue.record(error)
          return (1, "fixture I/O failed")
        }
        return (bootstrapStatus, "bootstrap fixture result")
      case "list":
        let loaded = bootstrapStatus == 5 ? "-\t0\tcom.example.agent\n" : ""
        return (0, "PID\tStatus\tLabel\n" + loaded)
      default:
        return (1, "unexpected command")
      }
    }
    #expect((error == nil) == (bootstrapStatus != 1))
    let snapshot = try #require(snapshotURL)
    #expect(snapshot != item.plist)
    if snapshot != item.plist {
      #expect(FileManager.default.fileExists(atPath: snapshot.path) == false)
      #expect(
        FileManager.default.fileExists(atPath: snapshot.deletingLastPathComponent().path) == false)
    }
    #expect(FileManager.default.fileExists(atPath: item.plist.path))
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
    #expect(commands.last?.count == 3)
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
      systemDisabled: ["shared": false])
    #expect(status.isDisabled(agent))
    #expect(!status.isDisabled(daemon))
    #expect(status.pid(agent) == 42 && status.isLoaded(agent))
    #expect(status.pid(daemon) == nil && !status.isLoaded(daemon))
  }

}

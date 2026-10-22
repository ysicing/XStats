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

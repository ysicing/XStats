// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

struct LauncherApplicationMetadataTests {
  private let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString)

  @Test func pwaShortcutNameTakesPriorityAndPreservesSearchIdentityAndCategory() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let application = try makeApplication(
      filename: "app-opaque",
      info: [
        "CrAppModeShortcutName": "  Web Workspace  ",
        "CFBundleDisplayName": "Generic Chrome App",
        "CFBundleName": "Internal Name",
        "LSApplicationCategoryType": "public.app-category.productivity",
      ])
    let commands = try CommandBarApplications.scan(directories: [root])
    let command = try #require(commands.first)
    #expect(commands.count == 1)
    #expect(command.title == "Web Workspace")
    #expect(command.applicationCategory == "public.app-category.productivity")
    #expect(command.action == .openApplication(application.resolvingSymlinksInPath()))
    let search = CommandBarSearch(commands: commands, supportsParameterQueries: false)
    #expect(search.results(for: "app-opaque").map(\.id) == [command.id])
    #expect(search.results(for: "test.launcher.metadata").map(\.id) == [command.id])
  }

  @Test func localizedDisplayNamePrecedesUnlocalizedBundleNames() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let application = try makeApplication(
      filename: "Opaque",
      info: ["CFBundleDisplayName": "Raw Display", "CFBundleName": "Raw Bundle"])
    try writeLocalizedInfo(
      ["CFBundleDisplayName": "Localized Display", "CFBundleName": "Localized Bundle"],
      application: application)
    let command = try #require(CommandBarApplications.scan(directories: [root]).first)
    #expect(command.title == "Localized Display")
    #expect(command.applicationCategory == nil)
  }

  @Test func localizedPwaNamePrecedesOtherLocalizedNames() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let application = try makeApplication(
      filename: "PWA",
      info: ["CrAppModeShortcutName": "Raw PWA", "CFBundleDisplayName": "Raw Display"])
    try writeLocalizedInfo(
      ["CrAppModeShortcutName": "Localized PWA", "CFBundleDisplayName": "Localized Display"],
      application: application)
    let command = try #require(CommandBarApplications.scan(directories: [root]).first)
    #expect(command.title == "Localized PWA")
  }

  @Test(arguments: ["CFBundleDisplayName", "CFBundleName"])
  func bundleNameFallbacks(nameKey: String) throws {
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try makeApplication(filename: "Fallback", info: [nameKey: "Visible Name"])
    let command = try #require(CommandBarApplications.scan(directories: [root]).first)
    #expect(command.title == "Visible Name")
  }

  @Test func invalidNameAndCategoryTypesFallBackSafely() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try makeApplication(
      filename: "Filename Fallback",
      info: [
        "CrAppModeShortcutName": 17,
        "CFBundleDisplayName": " \n ",
        "CFBundleName": ["invalid"],
        "LSApplicationCategoryType": 42,
      ])
    let command = try #require(CommandBarApplications.scan(directories: [root]).first)
    #expect(command.title == "Filename Fallback")
    #expect(command.applicationCategory == nil)
  }

  @Test func explicitDirectoryScanStaysIsolatedFromCustomPreferences() throws {
    let suite = "LauncherApplicationMetadataTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defer { try? FileManager.default.removeItem(at: root) }
    let custom = root.appendingPathComponent("Custom")
    let empty = root.appendingPathComponent("Empty")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    _ = try makeApplication(filename: "Custom/App", info: [:])
    let store = LauncherApplicationDirectories(
      defaults: defaults, notificationCenter: NotificationCenter())
    try store.add(custom)
    let combined = try CommandBarApplications.scanResult(
      directories: [empty], customDirectories: store)
    #expect(combined.commands.count == 1 && combined.isTruncated == false)
    #expect(try CommandBarApplications.scan(directories: [empty]).isEmpty)
    let explicit = try CommandBarApplications.scanResult(directories: [empty])
    #expect(explicit.commands.isEmpty && explicit.isTruncated == false)
    let overlapping = try CommandBarApplications.scanResult(
      directories: [root, custom, empty], customDirectories: store)
    #expect(overlapping.commands.count == 1 && overlapping.isTruncated == false)
  }

  private func makeApplication(filename: String, info: [String: Any]) throws -> URL {
    let application = root.appendingPathComponent("\(filename).app")
    let contents = application.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    var metadata = info
    metadata["CFBundleIdentifier"] = "test.launcher.metadata.\(UUID().uuidString)"
    metadata["CFBundlePackageType"] = "APPL"
    metadata["CFBundleDevelopmentRegion"] = "en"
    metadata["CFBundleLocalizations"] = ["en"]
    try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
      .write(to: contents.appendingPathComponent("Info.plist"))
    return application
  }

  private func writeLocalizedInfo(_ info: [String: String], application: URL) throws {
    let resources = application.appendingPathComponent("Contents/Resources/en.lproj")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: resources.appendingPathComponent("InfoPlist.strings"))
  }
}

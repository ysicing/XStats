// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import Testing
@testable import CaptureUI
@testable import XStatsUI

@MainActor
struct ShortcutSettingsTests {
  @Test func disabledFeaturesRemainEditableAndRejectDuplicatesAcrossHosts() throws {
    let suite = "ShortcutSettings.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.audioEnabled = false
    settings.restEnabled = false
    settings.commandBarEnabled = false
    settings.hotKeys = [:]
    let capture = CaptureShortcuts(defaults: defaults)
    let editor = ShortcutSettingsEditor(settings: settings, capture: capture)
    let first = HotKey(keyCode: 40, modifiers: [.command, .option], key: "k")
    let second = HotKey(keyCode: 37, modifiers: [.command, .option], key: "l")
    let third = HotKey(keyCode: 46, modifiers: [.command, .option], key: "m")
    #expect(ShortcutSettingsTarget.all.count == 17)
    #expect(editor.set(first, for: .action(.nextAudioOutput)))
    #expect(editor.set(second, for: .captureScreenshot))
    #expect(editor.set(third, for: .action(.openTimer)))

    var alias = first
    alias.key = "different layout"
    #expect(!editor.set(alias, for: .captureScreenshot))
    #expect(editor.key(for: .captureScreenshot) == second)
    #expect(!editor.set(second, for: .action(.openTimer)))
    #expect(editor.key(for: .action(.openTimer)) == third)
    #expect(!editor.set(alias, for: .action(.openTimer)))
    #expect(editor.conflict(for: alias, excluding: .captureScreenshot) == .action(.nextAudioOutput))
    #expect(!editor.set(second, for: .captureRecording))
    #expect(editor.key(for: .captureRecording) == nil)
    let standaloneEditor = ShortcutSettingsEditor(
      settings: settings, capture: capture, includesCapture: false)
    #expect(standaloneEditor.conflict(for: second, excluding: .action(.openTimer)) == nil)
    #expect(standaloneEditor.conflict(for: first, excluding: .action(.openTimer)) != nil)

    #expect(!settings.audioEnabled && !settings.restEnabled && !settings.commandBarEnabled)
    #expect(!capture.enabled)
    #expect(!HotKeyAction.nextAudioOutput.isEnabled(in: settings))
    #expect(!HotKeyAction.openTimer.isEnabled(in: settings))
    #expect(CaptureShortcuts(defaults: defaults).screenshotKey == capture.screenshotKey)
    #expect(AppSettings(defaults: defaults).hotKeys[.openTimer] == third)
    #expect(editor.set(nil, for: .action(.nextAudioOutput)))
    #expect(editor.set(first, for: .captureScreenshot))
    #expect(editor.set(nil, for: .captureScreenshot))
    #expect(CaptureShortcuts(defaults: defaults).screenshotKey == nil)
  }

  @Test func existingDuplicatesAreReportedWithoutChangingSavedBindings() throws {
    let suite = "ShortcutSettings.legacy.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let key = HotKey(keyCode: 40, modifiers: [.command, .option], key: "k")
    settings.hotKeys = [.toggleMainWindow: key, .openCalendar: key]
    let capture = CaptureShortcuts(defaults: defaults)
    capture.setShortcut(
      CaptureHotKey(code: key.keyCode, modifiers: key.modifiers, characters: key.key),
      for: .screenshot)
    let editor = ShortcutSettingsEditor(settings: settings, capture: capture)
    for target in [
      ShortcutSettingsTarget.action(.toggleMainWindow), .action(.openCalendar), .captureScreenshot,
    ] {
      #expect(editor.conflict(for: editor.key(for: target), excluding: target) != nil)
      #expect(editor.key(for: target) == key)
    }
    #expect(settings.hotKeys.count == 2)
    #expect(capture.screenshotKey != nil)
    #expect(editor.set(nil, for: .captureScreenshot))
    #expect(editor.set(nil, for: .action(.openCalendar)))
    #expect(editor.conflict(for: key, excluding: .action(.toggleMainWindow)) == nil)
  }

  @Test func captureRetainsItsSystemShortcutValidation() throws {
    let suite = "ShortcutSettings.validation.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let editor = ShortcutSettingsEditor(
      settings: AppSettings(defaults: defaults), capture: CaptureShortcuts(defaults: defaults))
    let saved = HotKey(keyCode: 40, modifiers: [.command, .option], key: "k")
    #expect(editor.set(saved, for: .captureScreenshot))
    #expect(
      !editor.set(
        HotKey(keyCode: 20, modifiers: [.command, .shift], key: "3"),
        for: .captureScreenshot))
    #expect(!editor.set(HotKey(keyCode: 0, modifiers: [], key: "a"), for: .captureScreenshot))
    #expect(editor.key(for: .captureScreenshot) == saved)
  }

  @Test func shortcutLinksPreserveTheirTargetAndHelperKeepsGeneralSelected() throws {
    let suite = "ShortcutSettings.navigation.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.historyEnabled = false
    settings.enabledMonitoringModules = []
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient(),
      networkCacheDefaults: defaults)
    var opened: PanelTab?
    model.openMainWindow = { opened = $0 }
    model.openShortcutSettings(.action(.nextAudioOutput))
    #expect(opened == .settingsShortcuts)
    #expect(model.shortcutSettingsTarget == .action(.nextAudioOutput))
    model.openShortcutSettings(.captureScreenshot)
    #expect(model.shortcutSettingsTarget == .captureScreenshot)
    model.openShortcutSettings()
    #expect(model.shortcutSettingsTarget == nil)
    #expect(PanelTab.settingsHelper.sidebarTab == .settingsGeneral)
    #expect(PanelTab.settingsHelper.isSettings)
  }

  @Test func newShortcutCopyIsTranslatedWithoutChangingGlobalLanguage() {
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      for source in [
        "快捷键", "管理快捷键", "设置快捷键", "功能未启用，启用后生效",
        "与「Test」的快捷键重复", "独立版快捷键请在 XStats Capture 的设置中管理。",
      ] {
        #expect(L10n.translate(source, language: language) != source)
      }
    }
  }
}

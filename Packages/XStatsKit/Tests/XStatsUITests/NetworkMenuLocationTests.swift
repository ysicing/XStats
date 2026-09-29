// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct NetworkMenuLocationTests {
    private func settings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "NetworkMenuLocationTests.\(UUID())")!)
    }

    @Test func optionalPreferencePersistsAndRoundTrips() throws {
        let defaults = UserDefaults(suiteName: "NetworkMenuLocationTests.\(UUID())")!
        let original = AppSettings(defaults: defaults)
        #expect(original.networkLocationStyle == .off)
        original.networkLocationStyle = .flag
        #expect(AppSettings(defaults: defaults).networkLocationStyle == .flag)
        let data = try JSONEncoder().encode(original.exportDocument())
        let restored = settings()
        restored.apply(try JSONDecoder().decode(SettingsDocument.self, from: data))
        #expect(restored.networkLocationStyle == .flag)
        var invalid = SettingsDocument()
        invalid.networkLocationStyle = "future-value"
        restored.apply(invalid)
        #expect(restored.networkLocationStyle == .flag)
        #expect(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)).networkLocationStyle == nil)
    }

    @Test func locationInvalidatesOnlyTheNetworkImage() {
        var first = MenuBarReading.sample
        first.networkCountryCode = "US"
        var second = first
        second.networkCountryCode = "JP"
        #expect(second.hasSameImage(as: first, item: .network, style: .stacked))
        first.networkLocationStyle = .flag
        second.networkLocationStyle = .flag
        #expect(!second.hasSameImage(as: first, item: .network, style: .stacked))
        #expect(second.hasSameImage(as: first, item: .cpu, style: .stacked))
        second = first
        second.networkLocationStyle = .text
        #expect(!second.hasSameImage(as: first, item: .network, style: .stacked))
    }

    @Test func menuImagesSupportFlagsTextAndUnavailableLocation() {
        var reading = MenuBarReading.sample
        func image() -> NSImage {
            MenuBarRenderer.image(reading: reading, items: [.network], style: { _ in .stacked },
                                  networkStyle: .dots, colorizeHighLoad: false, fahrenheit: false)
        }
        let base = image().size.width
        reading.networkLocationStyle = .flag
        #expect(image().size.width == base)
        reading.networkCountryCode = "US"
        let flag = image()
        #expect(flag.size.width > base && !flag.isTemplate)
        reading.networkLocationStyle = .text
        #expect(image().size.width > base)
        for dark in [false, true] {
            #expect(MenuBarRenderer.preview(flag, dark: dark).tiffRepresentation != nil)
            #expect(MenuBarRenderer.preview(image(), dark: dark).tiffRepresentation != nil)
        }
    }

}

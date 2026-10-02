// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct DesignAccessibilityTests {
    @Test(arguments: [false, true])
    func supportingTextRemainsReadableOnWindowAndCards(dark: Bool) throws {
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        for text in [DS.Palette.textSecondary, DS.Palette.textTertiary] {
            for background in [DS.Palette.background, DS.Palette.surface, DS.Palette.elevated] {
                #expect(try contrast(text, on: background, appearance: appearance) >= 4.5)
            }
        }
    }

    private func contrast(_ foreground: Color, on background: Color, appearance: NSAppearance) throws -> Double {
        let a = try luminance(foreground, appearance: appearance)
        let b = try luminance(background, appearance: appearance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func luminance(_ color: Color, appearance: NSAppearance) throws -> Double {
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        let rgb = try #require(resolved)
        let components: [Double] = [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)]
        let values: [Double] = components.map { value in
            if value <= 0.04045 { return value / 12.92 }
            return pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * values[0] + 0.7152 * values[1] + 0.0722 * values[2]
    }
}

@MainActor
@Observable
private final class SelectionFixture {
    var value = 0
}

@MainActor
private final class SelectionTransactions {
    var values: [(value: Int, animated: Bool)] = []
}

private struct SelectionTransactionProbe: NSViewRepresentable {
    let value: Int
    let transactions: SelectionTransactions

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        transactions.values.append((value, context.transaction.animation != nil && !context.transaction.disablesAnimations))
    }
}

private struct SelectionFixtureView: View {
    let model: SelectionFixture
    let transactions: SelectionTransactions

    var body: some View {
        SelectionTransactionProbe(value: model.value, transactions: transactions)
            .frame(width: 160, height: 40)
            .dsSelectionAnimation(DS.Motion.quick, value: model.value)
    }
}

@MainActor
struct DesignSelectionMotionTests {
    @Test(arguments: [NSEvent.EventType?.some(.leftMouseUp), .some(.keyDown), .some(.keyUp), .none])
    func selectionTransactionsRespectInputAndAccessibility(event: NSEvent.EventType?) async throws {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let model = SelectionFixture()
        let transactions = SelectionTransactions()
        let hosting = NSHostingView(rootView: SelectionFixtureView(model: model, transactions: transactions))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 40),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        DS.Motion.select(event: event) { model.value = 1 }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        let selected = try #require(transactions.values.last(where: { $0.value == 1 }))
        #expect(selected.animated == (!reduceMotion && event == .leftMouseUp))
        #expect(model.value == 1)
    }
}

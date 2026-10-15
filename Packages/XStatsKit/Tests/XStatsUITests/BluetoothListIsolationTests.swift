// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Observation
import Testing
@testable import Metrics
@testable import XStatsUI

@MainActor
struct BluetoothListIsolationTests {
    @Test(arguments: [false, true])
    func listContentCanBeBuiltOffTheMainQueue(batteryParts: Bool) async throws {
        let devices = [BluetoothDevice(name: "Headphones", address: "00:11:22:33:44:55", kind: .headphones,
                                       batteries: [("Left", 70), ("Right", 60), ("Case", 90)])]
        let lists = listProbes(in: BluetoothDeviceList(devices: devices).body)
        let list = try #require(lists.first)
        #expect(lists.count == 1)
        let probes = batteryParts ? list.content.nestedLists() : lists
        #expect(probes.count == 1)

        // macOS 15 的 DisplayLink 会直接在后台调用已由主线程创建的 ForEach.content。
        let counts = await Task.detached {
            return probes.map { $0.content.buildRows() }
        }.value
        #expect(counts == [batteryParts ? 3 : 1])
    }

    @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft])
    func loadingEmptyAndBatteryRowsFitThePopover(direction: LayoutDirection) async throws {
        _ = NSApplication.shared
        _ = try #require(NSScreen.main)
        let keyboard = BluetoothDevice(name: "Keyboard", address: "00:11:22:33:44:55", kind: .keyboard,
                                       batteries: [("Battery", 80)])
        let headphones = BluetoothDevice(name: "Headphones", address: "00:11:22:33:44:66", kind: .headphones,
                                         batteries: [("Left", 70), ("Right", 60), ("Case", 90)])
        var disconnected = headphones
        disconnected.isConnected = false
        disconnected.lastSeen = Date(timeIntervalSince1970: 1_700_000_000)
        let states: [[BluetoothDevice]?] = [nil, [], [keyboard], [headphones], [disconnected]]
        let host = NSHostingView(rootView: BluetoothDeviceList(devices: nil)
            .environment(\.layoutDirection, direction).frame(width: DS.Size.popoverWidth))
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for devices in states {
            host.rootView = BluetoothDeviceList(devices: devices)
                .environment(\.layoutDirection, direction).frame(width: DS.Size.popoverWidth)
            let size = host.fittingSize
            #expect(abs(size.width - DS.Size.popoverWidth) < 1)
            #expect(size.height > 0 && size.height < 300)
            host.frame.size = size
            window.setContentSize(size)
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            // 挂载窗口后让真实 DisplayLink 处理设备与电量部件变化。
            try await Task.sleep(for: .milliseconds(100))
            #expect(window.isVisible)
        }
    }
}

private protocol ListContentProbe {
    func buildRows() -> Int
    @MainActor func buildBodies()
    @MainActor func nestedLists() -> [BackgroundListProbe]
}

extension ForEach: ListContentProbe where Content: View {
    @MainActor fileprivate func buildBodies() {
        for element in data { _ = content(element).body }
    }
    fileprivate func buildRows() -> Int {
        #expect(!Thread.isMainThread)
        for element in data { _ = content(element) }
        return data.count
    }

    @MainActor fileprivate func nestedLists() -> [BackgroundListProbe] {
        data.flatMap { listProbes(in: content($0).body) }
    }
}

// 测试专用：传递由安全构建回调组成的列表，模拟旧 SwiftUI 未标注 Sendable 的回调边界。
private struct BackgroundListProbe: @unchecked Sendable {
    let content: any ListContentProbe
}

// body 的不透明返回类型由 ViewBuilder 包装；反射只用于取出实际 ForEach，避免测试另一份闭包。
@MainActor
private func listProbes(in value: Any) -> [BackgroundListProbe] {
    if let content = value as? any ListContentProbe { return [BackgroundListProbe(content: content)] }
    return Mirror(reflecting: value).children.flatMap { listProbes(in: $0.value) }
}

@MainActor
struct MainActorForEachIsolationTests {
    @Test func backgroundCallbackDefersModelReadsUntilBody() async throws {
        var built: [Int] = []
        let list = MainActorForEach([3, 1, 2], id: \.self) { element in
            #expect(Thread.isMainThread)
            built.append(element)
            return Text(verbatim: String(element))
        }
        let probe = try #require(listProbes(in: list.body).first)
        let count = await Task.detached { probe.content.buildRows() }.value
        #expect(count == 3)
        #expect(built.isEmpty)
        probe.content.buildBodies()
        #expect(built == [3, 1, 2])
        #expect(list.data.map { $0[keyPath: list.id] } == [3, 1, 2])
    }

    @Test func rangeAndIdentifiableListsKeepTheirElements() async throws {
        let range = MainActorForEach(0..<3) { Text(verbatim: String($0)) }
        let devices = [BluetoothDevice(name: "Keyboard", address: "fixture", kind: .keyboard, batteries: [])]
        let identified = MainActorForEach(devices) { Text(verbatim: $0.name) }
        let probes = listProbes(in: range.body) + listProbes(in: identified.body)
        let counts = await Task.detached { probes.map { $0.content.buildRows() } }.value
        #expect(counts == [3, 1])
        #expect(identified.data.map { $0[keyPath: identified.id] } == devices.map(\.id))
    }

    @Test func rowsObserveSelectionChanges() async throws {
        _ = NSApplication.shared
        let selection = ListSelectionFixture()
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            MainActorForEach([1, 2], id: \.self) { element in
                Text(verbatim: String(element)).frame(width: 100,
                    height: selection.value == element ? CGFloat(element * 30) : 10)
            }
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 150),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        let initialHeight = host.fittingSize.height
        selection.value = 2
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        #expect(abs(host.fittingSize.height - initialHeight - 30) < 1)
    }
}

@MainActor @Observable
private final class ListSelectionFixture {
    var value = 1
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 失败边界：RPC/SDK/准备期间退出、过期 idle 回调退出、shutdown 跳过未完成工作。
@MainActor private final class IdleGate {
    private(set) var waiting: [CheckedContinuation<Void, Never>] = []
    func sleep(_ duration: Duration) async throws { await withCheckedContinuation { waiting.append($0) } }
    func fireFirst() { waiting.removeFirst().resume() }
    func waitForTimer() async { while waiting.isEmpty { await Task.yield() } }
}

@main private struct LifecycleTests {
    @MainActor static func main() async {
        let gate = IdleGate()
        var exits = 0
        let lifetime = ComponentServiceLifetime(sleep: gate.sleep, onIdle: { exits += 1 })
        lifetime.start()
        await gate.waitForTimer()
        lifetime.beginRPC()
        gate.fireFirst()
        for _ in 0..<5 { await Task.yield() }
        precondition(exits == 0, "旧 idle 回调不能终止正在处理 RPC 的服务")
        lifetime.setSDKActive(true)
        lifetime.finishRPC()
        precondition(gate.waiting.isEmpty, "SDK 周期内不应排队 idle 退出")
        lifetime.requestShutdown()
        precondition(exits == 0, "shutdown 必须等待 SDK 周期")
        lifetime.setPreparationActive(true)
        lifetime.setSDKActive(false)
        precondition(gate.waiting.isEmpty, "安装准备未结束时不能退出")
        lifetime.setPreparationActive(false)
        await gate.waitForTimer()
        gate.fireFirst()
        while exits == 0 { await Task.yield() }
        precondition(exits == 1)
        let secondGate = IdleGate()
        var secondExits = 0
        let second = ComponentServiceLifetime(sleep: secondGate.sleep, onIdle: { secondExits += 1 })
        second.beginRPC(); second.finishRPC()
        await secondGate.waitForTimer()
        second.beginRPC(); second.finishRPC()
        secondGate.fireFirst()
        for _ in 0..<5 { await Task.yield() }
        precondition(secondExits == 0, "新 RPC 必须使旧 idle 代次失效")
        await secondGate.waitForTimer()
        secondGate.fireFirst()
        while secondExits == 0 { await Task.yield() }
        precondition(secondExits == 1)
        print("按需网络服务生命周期测试通过")
    }
}

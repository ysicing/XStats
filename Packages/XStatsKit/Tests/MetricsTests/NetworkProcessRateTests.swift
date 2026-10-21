// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Metrics

struct NetworkProcessRateTests {
  private func nettop(_ rows: [String]) -> String {
    (["time,,bytes_in,bytes_out,"] + rows).joined(separator: "\n")
  }

  @Test func firstReadOnlyEstablishesBaseline() {
    var sampler = NetworkProcessSampler()
    #expect(sampler.rates(output: nettop(["Safari.10,100,200,"]), now: 1_000_000_000) == [:])

    let rates = sampler.rates(output: nettop(["Safari.10,1100,1200,"]), now: 3_000_000_000)
    #expect(rates?[10]?.name == "Safari")
    #expect(rates?[10]?.download == 500)
    #expect(rates?[10]?.upload == 500)
  }

  /// 读取失败返回 nil 且保留基线，下一次按真实间隔计算，不把失败窗口算成速率
  @Test func failedReadKeepsBaseline() {
    var sampler = NetworkProcessSampler()
    _ = sampler.rates(output: nettop(["Safari.10,100,200,"]), now: 1_000_000_000)
    #expect(sampler.rates(output: nil, now: 2_000_000_000) == nil)

    let rates = sampler.rates(output: nettop(["Safari.10,300,200,"]), now: 3_000_000_000)
    #expect(rates?[10]?.download == 100)
    #expect(rates?[10]?.upload == 0)
  }

  /// 计数回退（进程重启或 PID 复用）时速率按 0 处理，不产生负值
  @Test func counterRollbackReportsZero() {
    var sampler = NetworkProcessSampler()
    _ = sampler.rates(output: nettop(["curl.42,5000,5000,"]), now: 1_000_000_000)
    let rates = sampler.rates(output: nettop(["curl.42,10,20,"]), now: 2_000_000_000)
    #expect(rates?[42]?.download == 0)
    #expect(rates?[42]?.upload == 0)
  }
}

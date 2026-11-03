// SPDX-License-Identifier: AGPL-3.0-or-later

extension Translations {
  static let dnsBenchmarkEnglish = #"""
    DNS 测试	DNS Test
    比较各家 DNS 的速度与稳定性	Compare DNS speed and reliability
    测试协议	Test Protocol
    测试轮数	Test Rounds
    自定义 DNS	Custom DNS
    最多添加 8 个自定义 DNS	Add up to 8 custom DNS servers
    系统 DNS	System DNS
    P90 延迟	P90 Latency
    失败率	Failure Rate
    握手耗时	Handshake Time
    解析结果	Resolved Addresses
    疑似 DNS 拦截	Possible DNS Interception
    普通 DNS 应答可能被沿途接管，相关结果不参与推荐。	Plain DNS responses may be intercepted along the route. These results are excluded from recommendations.
    检测到代理或 VPN，测试结果受当前路由影响；DoH 也可能经过系统代理。	Proxy or VPN detected; results depend on the current route. DoH may also use the system proxy.
    点击开始测试，比较当前系统与公共 DNS。	Start a test to compare current system and public DNS servers.
    先预热，再交错查询；握手单独计时，结果仅保留在窗口中。	Warm up, then interleave queries. Handshakes are timed separately; results stay in this window only.
    开始测试	Start Test
    测试中 {}/{}	Testing {}/{}
    测试已取消	Test Cancelled
    测试完成	Test Complete
    没有有效应答	No Valid Response
    查询超时	Query Timed Out
    连接失败	Connection Failed
    应答无效	Invalid Response
    按延迟排序	Sort by Latency
    按失败率排序	Sort by Failure Rate
    本次推荐	Recommended This Run
    移除自定义 DNS	Remove Custom DNS
    测试未完成，请重试。	The test did not complete. Try again.
    首次查询	First Query
    普通 DNS 推荐	Plain DNS Recommendation
    点击开始测试，并发比较各家 DNS 的四种协议。	Start a test to compare four DNS protocols across providers concurrently.
    四种协议并发实测；握手单独计时，结果仅保留在窗口中。	All four protocols are measured concurrently. Handshakes are timed separately; results stay in this window only.
    """#
}

// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Testing
@testable import Metrics

struct PortSamplerTests {
  private func socket(
    pid: Int32, transport: PortSocket.Transport = .tcp, state: PortSocket.State = .listening,
    local: String? = nil, port: Int, remote: String? = nil, remotePort: Int? = nil,
    socketID: UInt64? = nil, family: PortSocket.AddressFamily? = nil
  ) -> PortSocket {
    PortSocket(
      pid: pid, name: "proc\(pid)", uid: 501,
      socketID: socketID ?? (UInt64(pid) << 16 | UInt64(port)), transport: transport, state: state,
      localAddress: local, localPort: port, remoteAddress: remote, remotePort: remotePort,
      addressFamily: family)
  }

  @Test func sameTCPListenPortAcrossProcessesIsConflict() {
    let sockets = [
      socket(pid: 10, port: 3000), socket(pid: 11, port: 3000), socket(pid: 12, port: 4000),
    ]
    #expect(PortSampler.conflictingSocketIDs(sockets) == Set(sockets.prefix(2).map(\.socketID)))
  }

  @Test func sharedUDPPortAndSameProcessAreNotConflicts() {
    let sockets = [
      socket(pid: 10, transport: .udp, port: 5353), socket(pid: 11, transport: .udp, port: 5353),
      socket(pid: 20, port: 8080), socket(pid: 20, local: "::", port: 8080),
      socket(pid: 21, state: .established, port: 8080, remote: "1.1.1.1", remotePort: 443),
    ]
    #expect(PortSampler.conflictingSocketIDs(sockets).isEmpty)
  }

  /// fork 出的子进程继承同一个监听 socket 属于共享；另一个进程单独监听同一端口才是冲突
  @Test func inheritedListenerIsSharedNotConflict() {
    let shared = [
      socket(pid: 10, port: 8000, socketID: 1), socket(pid: 11, port: 8000, socketID: 1),
      socket(pid: 12, port: 8000, socketID: 1),
    ]
    #expect(PortSampler.conflictingSocketIDs(shared).isEmpty)
    #expect(
      PortSampler.conflictingSocketIDs(shared + [socket(pid: 13, port: 8000, socketID: 2)]) == [
        1, 2,
      ])
  }

  @Test func differentLocalAddressesDoNotConflictAndOnlyOverlappingRowsAreMarked() {
    let loopback = socket(pid: 10, local: "127.0.0.1", port: 8080)
    let lan = socket(pid: 11, local: "192.168.1.2", port: 8080)
    let anotherLoopback = socket(pid: 12, local: "127.0.0.1", port: 8080)
    #expect(PortSampler.conflictingSocketIDs([loopback, lan]).isEmpty)
    #expect(
      PortSampler.conflictingSocketIDs([loopback, lan, anotherLoopback])
        == [loopback.socketID, anotherLoopback.socketID])
  }

  @Test func wildcardListenersOnlyOverlapTheirSupportedAddressFamilies() {
    let ipv4 = socket(pid: 10, local: "127.0.0.1", port: 8080)
    let ipv6 = socket(pid: 11, local: "::1", port: 8080)
    let wildcard4 = socket(pid: 12, port: 8080, family: .ipv4)
    let wildcard6 = socket(pid: 13, port: 8080, family: .ipv6)
    let dualStack = socket(pid: 14, port: 8080, family: .dualStack)
    #expect(PortSampler.conflictingSocketIDs([ipv4, ipv6]).isEmpty)
    #expect(PortSampler.conflictingSocketIDs([wildcard4, ipv6]).isEmpty)
    #expect(PortSampler.conflictingSocketIDs([wildcard6, ipv4]).isEmpty)
    #expect(PortSampler.conflictingSocketIDs([wildcard4, wildcard6]).isEmpty)
    for peer in [ipv4, ipv6, wildcard4, wildcard6] {
      #expect(
        PortSampler.conflictingSocketIDs([dualStack, peer]) == [dualStack.socketID, peer.socketID])
    }
    #expect(
      PortSampler.conflictingSocketIDs([wildcard4, ipv4]) == [wildcard4.socketID, ipv4.socketID])
    #expect(
      PortSampler.conflictingSocketIDs([wildcard6, ipv6]) == [wildcard6.socketID, ipv6.socketID])
    #expect(wildcard4.id != socket(pid: 12, port: 8080, family: .ipv6).id)
  }

  /// 从内核读取 IPv6-only 与双栈通配监听，保证协议族信息没有在“*”显示时丢失。
  @Test(arguments: [true, false])
  func samplePreservesIPv6WildcardFamily(_ ipv6Only: Bool) throws {
    let fd = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
    try #require(fd >= 0)
    defer { close(fd) }
    var only: Int32 = ipv6Only ? 1 : 0
    try #require(
      setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size)) == 0)
    var address = sockaddr_in6()
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    address.sin6_family = sa_family_t(AF_INET6)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
      }
    }
    try #require(bound == 0)
    try #require(listen(fd, 1) == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
    let named = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    try #require(named == 0)
    let port = Int(UInt16(bigEndian: address.sin6_port))
    let sockets = try #require(PortSampler.sample())
    let own = try #require(sockets.first { $0.pid == getpid() && $0.localPort == port })
    #expect(own.localAddress == nil)
    #expect(own.addressFamily == (ipv6Only ? .ipv6 : .dualStack))
  }

  /// insi_lport 保存的是网络字节序，3000 在内核里以大端形式出现
  @Test func portsAreReadFromNetworkByteOrder() {
    #expect(PortSampler.port(Int32(UInt16(3000).bigEndian)) == 3000)
    #expect(PortSampler.port(Int32(UInt16(65535).bigEndian)) == 65535)
  }

  @Test func endpointsBracketIPv6Addresses() {
    let ipv6 = socket(
      pid: 1, state: .established, local: "::1", port: 8080, remote: "fe80::1", remotePort: 443)
    #expect(ipv6.localEndpoint == "[::1]:8080")
    #expect(ipv6.remoteEndpoint == "[fe80::1]:443")

    let ipv4 = socket(pid: 1, local: "127.0.0.1", port: 5432)
    #expect(ipv4.localEndpoint == "127.0.0.1:5432")
    #expect(ipv4.remoteEndpoint == nil)

    #expect(socket(pid: 1, port: 3000).localEndpoint == "*:3000")
  }

  @Test func connectionsToDifferentPeersHaveDifferentIdentity() {
    let first = socket(
      pid: 1, state: .established, local: "10.0.0.2", port: 50000, remote: "1.1.1.1",
      remotePort: 443)
    let second = socket(
      pid: 1, state: .established, local: "10.0.0.2", port: 50000, remote: "8.8.8.8",
      remotePort: 443)
    #expect(first.id != second.id)
  }

  /// 在 127.0.0.1 的临时端口上监听，返回描述符与端口；描述符不带 CLOEXEC，子进程会继承
  private func openListener() throws -> (fd: Int32, port: Int) {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    try #require(fd >= 0)

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
    }
    try #require(bound == 0)
    try #require(listen(fd, 1) == 0)

    var named = sockaddr_in()
    var namedLength = length
    let status = withUnsafeMutablePointer(to: &named) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &namedLength)
      }
    }
    try #require(status == 0)
    return (fd, Int(UInt16(bigEndian: named.sin_port)))
  }

  /// 真实读取一次：本进程绑定的临时端口必须出现在结果中
  @Test func sampleFindsOwnListeningSocket() throws {
    let (fd, port) = try openListener()
    defer { close(fd) }

    let sockets = try #require(PortSampler.sample())
    #expect(
      sockets.contains {
        $0.pid == getpid() && $0.transport == .tcp && $0.state == .listening
          && $0.localPort == port && $0.socketID != 0
      })
  }

  /// 真实读取：本进程持有自己的监听 socket，换一个 socket 标识或不存在的 PID 都不算持有
  @Test func holdsSocketRequiresTheSameKernelSocket() throws {
    let (fd, port) = try openListener()
    defer { close(fd) }

    let sockets = try #require(PortSampler.sample())
    let own = try #require(
      sockets.first { $0.pid == getpid() && $0.state == .listening && $0.localPort == port })
    #expect(PortSampler.holdsSocket(pid: getpid(), socketID: own.socketID))
    #expect(!PortSampler.holdsSocket(pid: getpid(), socketID: own.socketID &+ 1))
    #expect(!PortSampler.holdsSocket(pid: Int32.max, socketID: own.socketID))
  }

  /// 真实读取一次：子进程继承的监听 socket 与父进程标识相同，不标记冲突
  @Test func sampleTreatsInheritedListenerAsShared() throws {
    let (fd, port) = try openListener()
    defer { close(fd) }

    var child: pid_t = 0
    var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("10"), nil]
    defer { argv.forEach { free($0) } }
    try #require(posix_spawn(&child, "/bin/sleep", nil, nil, &argv, environ) == 0)
    defer {
      kill(child, SIGKILL)
      waitpid(child, nil, 0)
    }

    let sockets = try #require(PortSampler.sample()).filter {
      $0.transport == .tcp && $0.state == .listening && $0.localPort == port
    }
    let parent = try #require(sockets.first { $0.pid == getpid() })
    let inherited = try #require(sockets.first { $0.pid == child })
    #expect(parent.socketID == inherited.socketID)
    #expect(PortSampler.conflictingSocketIDs(sockets).isEmpty)
  }
}

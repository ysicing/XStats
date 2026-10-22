// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation

/// 本机一个 TCP / UDP socket 的端点与所属进程。
public struct PortSocket: Sendable, Equatable, Identifiable {
  public enum Transport: String, Sendable { case tcp, udp }
  /// 监听：TCP LISTEN 或尚未指定对端的已绑定 UDP；已建立：TCP ESTABLISHED 或已 connect 的 UDP。
  public enum State: String, Sendable { case listening, established }

  public let pid: Int32
  public let name: String
  public let appBundlePath: String?
  public let uid: UInt32
  /// 内核 socket 标识。fork 出的子进程继承同一个 socket 时各进程的值相同，用于区分共享与冲突。
  public let socketID: UInt64
  public let transport: Transport
  public let state: State
  /// nil 表示绑定到任意地址（0.0.0.0 / ::）
  public let localAddress: String?
  public let localPort: Int
  public let remoteAddress: String?
  public let remotePort: Int?
  /// 同一进程同时绑定 IPv4 与 IPv6 任意地址时标识相同，只保留一行。
  /// 排序、查找选中行都会反复读取，所以在初始化时算好。
  public let id: String

  public init(
    pid: Int32, name: String, appBundlePath: String? = nil, uid: UInt32, socketID: UInt64,
    transport: Transport, state: State, localAddress: String?, localPort: Int,
    remoteAddress: String? = nil, remotePort: Int? = nil
  ) {
    self.pid = pid
    self.name = name
    self.appBundlePath = appBundlePath
    self.uid = uid
    self.socketID = socketID
    self.transport = transport
    self.state = state
    self.localAddress = localAddress
    self.localPort = localPort
    self.remoteAddress = remoteAddress
    self.remotePort = remotePort
    id = [
      String(pid), transport.rawValue, state.rawValue, localAddress ?? "*", String(localPort),
      remoteAddress ?? "", remotePort.map(String.init) ?? "",
    ].joined(separator: "|")
  }

  /// 例如 “*:3000”“127.0.0.1:5432”“[::1]:8080”
  public var localEndpoint: String { Self.endpoint(localAddress ?? "*", localPort) }

  public var remoteEndpoint: String? {
    guard let remoteAddress, let remotePort else { return nil }
    return Self.endpoint(remoteAddress, remotePort)
  }

  static func endpoint(_ address: String, _ port: Int) -> String {
    address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
  }
}

/// 用 libproc 枚举本机 socket：进程列表 → 各进程的文件描述符 → socket 信息，不启动 lsof。
/// 未提权时内核只允许读取当前用户自己的进程，root 与其他用户的进程会被跳过。
/// 枚举思路参考 Burrow（https://github.com/caezium/burrow），未使用其源码。
public enum PortSampler {
  /// 单次结果上限：浏览器等进程可能持有大量连接，超过后丢弃多余的已建立连接，避免列表与内存无界增长。
  /// 监听端口单独计数，不会被大量连接挤掉。
  public static let maximumSockets = 4096

  struct Endpoint: Equatable {
    let socketID: UInt64
    let transport: PortSocket.Transport
    let state: PortSocket.State
    let localAddress: String?
    let localPort: Int
    var remoteAddress: String?
    var remotePort: Int?
  }

  /// 读取当前的监听端口与已建立连接；系统拒绝列出进程时返回 nil。取消后返回已收集的部分，由调用方丢弃。
  public static func sample() -> [PortSocket]? {
    let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard needed > 0 else { return nil }
    // 两次调用之间可能有新进程启动，多留一些空间
    var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride + 64)
    let filled = pids.withUnsafeMutableBytes {
      proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count))
    }
    guard filled > 0 else { return nil }

    var listening: [PortSocket] = []
    var established: [PortSocket] = []
    var seen = Set<String>()
    for pid in pids.prefix(Int(filled) / MemoryLayout<pid_t>.stride) where pid > 0 {
      if Task.isCancelled { return listening + established }
      let endpoints = endpoints(of: pid)
      guard !endpoints.isEmpty else { continue }
      let meta = ProcessSampler.meta(for: pid)
      let uid = owner(of: pid)
      for endpoint in endpoints {
        let socket = PortSocket(
          pid: pid, name: meta.name, appBundlePath: meta.bundle, uid: uid,
          socketID: endpoint.socketID, transport: endpoint.transport, state: endpoint.state,
          localAddress: endpoint.localAddress, localPort: endpoint.localPort,
          remoteAddress: endpoint.remoteAddress, remotePort: endpoint.remotePort)
        // 已建立连接达到上限后仍要继续扫描，后启动进程的监听端口才不会丢
        guard
          socket.state == .listening
            ? listening.count < maximumSockets
            : established.count < maximumSockets
        else { continue }
        guard seen.insert(socket.id).inserted else { continue }
        if socket.state == .listening {
          listening.append(socket)
        } else {
          established.append(socket)
        }
      }
    }
    return listening + established.prefix(max(0, maximumSockets - listening.count))
  }

  /// 进程是否仍持有这个 socket。PID 被回收复用后，新进程不会持有原来的内核 socket，
  /// 结束进程前用它确认目标没有换人。
  public static func holdsSocket(pid: Int32, socketID: UInt64) -> Bool {
    endpoints(of: pid).contains { $0.socketID == socketID }
  }

  /// 被两个及以上进程各自监听的 TCP 端口。
  /// nginx worker、gunicorn、Node cluster 等子进程继承父进程的同一个监听 socket，属于共享而非冲突，
  /// 因此只有两个进程持有的 socket 完全不重叠时才算冲突。
  /// UDP 端口复用很常见（例如 mDNS 的 5353 由多个进程共享），不算冲突。
  public static func conflictingPorts(_ sockets: [PortSocket]) -> Set<Int> {
    var holders: [Int: [Int32: Set<UInt64>]] = [:]
    for socket in sockets where socket.transport == .tcp && socket.state == .listening {
      holders[socket.localPort, default: [:]][socket.pid, default: []].insert(socket.socketID)
    }
    var conflicts = Set<Int>()
    for (port, byProcess) in holders where byProcess.count > 1 {
      let owned = Array(byProcess.values)
      let separate = owned.indices.contains { index in
        owned[(index + 1)...].contains { $0.isDisjoint(with: owned[index]) }
      }
      if separate { conflicts.insert(port) }
    }
    return conflicts
  }

  private static func endpoints(of pid: pid_t) -> [Endpoint] {
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return [] }
    let stride = MemoryLayout<proc_fdinfo>.stride
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
    let filled = descriptors.withUnsafeMutableBytes {
      proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
    }
    guard filled > 0 else { return [] }

    var result: [Endpoint] = []
    for descriptor in descriptors.prefix(Int(filled) / stride)
    where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
      var info = socket_fdinfo()
      let infoSize = Int32(MemoryLayout<socket_fdinfo>.stride)
      // 进程可能在两次调用之间关闭描述符，读取不完整的直接跳过
      guard
        proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
        let endpoint = endpoint(info.psi)
      else { continue }
      result.append(endpoint)
    }
    return result
  }

  static func endpoint(_ info: socket_info) -> Endpoint? {
    let socketID = info.soi_so
    switch info.soi_kind {
    case Int32(SOCKINFO_TCP):
      let tcp = info.soi_proto.pri_tcp
      let address = tcp.tcpsi_ini
      let localPort = port(address.insi_lport)
      switch tcp.tcpsi_state {
      case Int32(TSI_S_LISTEN):
        guard localPort > 0 else { return nil }
        return Endpoint(
          socketID: socketID, transport: .tcp, state: .listening,
          localAddress: localAddress(address),
          localPort: localPort)
      case Int32(TSI_S_ESTABLISHED):
        return Endpoint(
          socketID: socketID, transport: .tcp, state: .established,
          localAddress: localAddress(address),
          localPort: localPort, remoteAddress: remoteAddress(address),
          remotePort: port(address.insi_fport))
      default:
        return nil
      }
    case Int32(SOCKINFO_IN):
      guard info.soi_protocol == IPPROTO_UDP else { return nil }
      let address = info.soi_proto.pri_in
      let localPort = port(address.insi_lport)
      guard localPort > 0 else { return nil }
      // 已 connect 的 UDP（例如 QUIC）有固定对端，归入已建立
      let remotePort = port(address.insi_fport)
      return remotePort > 0
        ? Endpoint(
          socketID: socketID, transport: .udp, state: .established,
          localAddress: localAddress(address),
          localPort: localPort, remoteAddress: remoteAddress(address), remotePort: remotePort)
        : Endpoint(
          socketID: socketID, transport: .udp, state: .listening,
          localAddress: localAddress(address),
          localPort: localPort)
    default:
      return nil
    }
  }

  /// `insi_lport` / `insi_fport` 的低 16 位是网络字节序的端口号
  static func port(_ raw: Int32) -> Int {
    Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: raw)))
  }

  private static func localAddress(_ address: in_sockinfo) -> String? {
    let text = format(address, local: true)
    return text == "0.0.0.0" || text == "::" || text.isEmpty ? nil : text
  }

  private static func remoteAddress(_ address: in_sockinfo) -> String {
    format(address, local: false)
  }

  /// 与 lsof 一致：带 IPv4 标记（包括 IPv6 socket 上的 IPv4 映射连接）按 IPv4 显示，否则按 IPv6。
  private static func format(_ address: in_sockinfo, local: Bool) -> String {
    if Int32(address.insi_vflag) & INI_IPV4 != 0 {
      var value =
        local ? address.insi_laddr.ina_46.i46a_addr4 : address.insi_faddr.ina_46.i46a_addr4
      var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      guard inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count)) != nil else { return "" }
      return String(nullTerminated: buffer)
    }
    var value = local ? address.insi_laddr.ina_6 : address.insi_faddr.ina_6
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    guard inet_ntop(AF_INET6, &value, &buffer, socklen_t(buffer.count)) != nil else { return "" }
    return String(nullTerminated: buffer)
  }

  private static func owner(of pid: pid_t) -> UInt32 {
    var info = proc_bsdshortinfo()
    let size = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
    // 读不到时按 root 处理，界面据此只读展示、不提供结束
    return proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size ? info.pbsi_uid : 0
  }
}

/// 常用端口的约定服务名，只用于在端口旁做离线提示，不代表该端口实际运行的程序。
/// 端口与服务的对应是公开约定。
public enum PortServices {
  public static func name(for port: Int) -> String? { table[port] }

  private static let table: [Int: String] = [
    20: "FTP", 21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP", 53: "DNS", 67: "DHCP", 68: "DHCP",
    69: "TFTP", 80: "HTTP", 88: "Kerberos", 110: "POP3", 111: "rpcbind", 123: "NTP",
    137: "NetBIOS", 138: "NetBIOS", 139: "NetBIOS", 143: "IMAP", 161: "SNMP", 389: "LDAP",
    443: "HTTPS", 445: "SMB", 465: "SMTPS", 500: "IKE", 514: "syslog", 548: "AFP",
    587: "SMTP", 631: "IPP", 636: "LDAPS", 873: "rsync", 993: "IMAPS", 995: "POP3S",
    1080: "SOCKS", 1194: "OpenVPN", 1433: "SQL Server", 1521: "Oracle", 1701: "L2TP",
    1723: "PPTP", 2181: "ZooKeeper", 2375: "Docker", 2376: "Docker TLS", 3000: "Node / Rails",
    3283: "Apple Remote Desktop", 3306: "MySQL", 4200: "Angular", 4222: "NATS",
    4500: "IPsec NAT-T", 5000: "AirPlay", 5173: "Vite", 5353: "mDNS", 5432: "PostgreSQL",
    5671: "AMQPS", 5672: "RabbitMQ", 5900: "VNC", 5984: "CouchDB", 6006: "Storybook",
    6379: "Redis", 7000: "AirPlay", 8000: "Django", 8025: "Mailpit", 8080: "HTTP Alt",
    8086: "InfluxDB", 8443: "HTTPS Alt", 8888: "Jupyter", 9042: "Cassandra", 9090: "Prometheus",
    9092: "Kafka", 9200: "Elasticsearch", 9229: "Node Inspector", 9300: "Elasticsearch",
    11211: "Memcached", 15672: "RabbitMQ", 27017: "MongoDB", 51820: "WireGuard",
  ]
}

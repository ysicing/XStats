// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreFoundation
import Foundation
import Localization
import Metrics
import Network
import Observation
import OSLog

struct DashboardReading: Encodable {
  struct CPU: Encodable {
    let usage: Double
    let cores: [Double]
    let loadAverage: [Double]
  }

  struct Capacity: Encodable {
    let usedBytes: UInt64
    let totalBytes: UInt64
  }

  struct NetworkRate: Encodable {
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
    let interfaceName: String?
    let interfaceDisplayName: String?
    let ipv4: String?
  }

  struct Battery: Encodable {
    let level: Double
    let charging: Bool
    let pluggedIn: Bool
  }

  struct Process: Encodable {
    let name: String
    let cpu: Double
    let memoryBytes: UInt64
  }

  enum Status: String, Encodable {
    case sampling, live, paused, unavailable
  }

  let status: Status
  var timestamp: Double?
  var cpu: CPU?
  var gpuUsage: Double?
  var memory: Capacity?
  var network: NetworkRate?
  var disk: Capacity?
  var battery: Battery?
  var processes: [Process]?
}

@MainActor
@Observable
final class DashboardController {
  enum Status: Equatable {
    case off, starting, listening, failed
  }

  static let defaultPort: UInt16 = 3261
  // Fetch 标准的 bad ports 即使能成功监听，浏览器也会拒绝访问。
  static let browserBlockedPorts: Set<UInt16> = [
    0, 1, 7, 9, 11, 13, 15, 17, 19, 20, 21, 22, 23, 25, 37, 42, 43, 53, 69, 77, 79, 87, 95,
    101, 102, 103, 104, 109, 110, 111, 113, 115, 117, 119, 123, 135, 137, 139, 143, 161, 179,
    389, 427, 465, 512, 513, 514, 515, 526, 530, 531, 532, 540, 548, 554, 556, 563, 587, 601,
    636, 989, 990, 993, 995, 1719, 1720, 1723, 2049, 3659, 4045, 4190, 5060, 5061, 6000, 6566,
    6665, 6666, 6667, 6668, 6669, 6679, 6697, 10080,
  ]
  private static let log = Logger(subsystem: "work.12306.xstats.app", category: "Dashboard")
  private static let versions = ["2025-11-25", "2025-06-18", "2025-03-26"]
  private static let toolName = "get_monitoring_snapshot"
  private static let displayedModules: Set<MonitoringModule> = [
    .cpu, .memory, .network, .disk, .gpu,
  ]

  private(set) var status = Status.off
  private(set) var hasViewerDemand = false
  private(set) var tailscaleAddresses: [String] = []
  private(set) var tailscaleStatus = Status.off
  @ObservationIgnored private var server: DashboardHTTPServer?
  @ObservationIgnored private var tailscaleServers:
    [DashboardTailscaleEndpoint: DashboardHTTPServer] = [:]
  @ObservationIgnored private var readyTailscaleEndpoints: Set<DashboardTailscaleEndpoint> = []
  @ObservationIgnored private var tailscaleTask: Task<Void, Never>?
  @ObservationIgnored private var port: UInt16?
  @ObservationIgnored private var paused = false
  @ObservationIgnored private var lastRequest: ContinuousClock.Instant?
  @ObservationIgnored private var idleTask: Task<Void, Never>?
  @ObservationIgnored private var sampleDate: Date?
  @ObservationIgnored private var hasProcessSample = false

  func configure(port newPort: UInt16?, settings: AppSettings, store: MetricsStore) {
    if newPort == port {
      updateTailscale(settings: settings, store: store)
      return
    }
    stop()
    guard let newPort else { return }
    port = newPort
    status = .starting
    do {
      let server = try DashboardHTTPServer(port: newPort)
      self.server = server
      server.start { [weak self, weak server] state in
        guard let self, let server, self.server === server else { return }
        switch state {
        case .ready:
          self.status = .listening
          Self.log.notice("监控大屏开始监听 TCP \(newPort)")
          self.updateTailscale(settings: settings, store: store)
        case .failed(let error), .waiting(let error):
          self.fail(error, port: newPort)
        default:
          break
        }
      } handle: { [weak self, weak server] request, peer in
        guard let self, let server, self.server === server, settings.dashboardEnabled,
          settings.dashboardPort == newPort
        else { return DashboardHTTPResponse(status: 404) }
        let response = await self.respond(
          request, peer: peer, port: newPort, settings: settings, store: store)
        guard self.server === server, settings.dashboardEnabled, settings.dashboardPort == newPort
        else { return DashboardHTTPResponse(status: 404) }
        return response
      }
    } catch {
      fail(error, port: newPort)
    }
  }

  func stop() {
    if server != nil { Self.log.notice("监控大屏停止监听") }
    stopTailscale()
    server?.stop()
    server = nil
    port = nil
    status = .off
    clearDemand()
  }

  func setPaused(_ value: Bool) {
    guard paused != value else { return }
    paused = value
    if paused { clearDemand() }
  }

  func record(_ snapshot: MetricsSnapshot) {
    guard hasViewerDemand, !paused else { return }
    guard
      snapshot.cpu != nil || snapshot.memory != nil || snapshot.gpu != nil
        || snapshot.network != nil || snapshot.disk != nil || snapshot.battery != nil
        || snapshot.processes != nil
    else { return }
    sampleDate = snapshot.date
    if snapshot.processes != nil { hasProcessSample = true }
  }

  private func fail(_ error: any Error, port: UInt16) {
    Self.log.error(
      "监控大屏 TCP \(port) 监听失败：\(String(error.localizedDescription.prefix(160)), privacy: .private)"
    )
    server?.stop()
    server = nil
    stopTailscale()
    status = .failed
    clearDemand()
  }

  private func updateTailscale(settings: AppSettings, store: MetricsStore) {
    guard settings.dashboardTailscaleEnabled, status == .listening, let port else {
      stopTailscale()
      return
    }
    guard tailscaleTask == nil else { return }
    tailscaleStatus = .starting
    tailscaleTask = Task { [weak self] in
      await DashboardTailscaleEndpoint.watch { [weak self] endpoints in
        guard let self, self.port == port, settings.dashboardTailscaleEnabled else { return }
        self.reconcileTailscale(endpoints, port: port, settings: settings, store: store)
      }
    }
  }

  private func reconcileTailscale(
    _ endpoints: Set<DashboardTailscaleEndpoint>, port: UInt16, settings: AppSettings,
    store: MetricsStore
  ) {
    for staleEndpoint in Set(tailscaleServers.keys).subtracting(endpoints) {
      tailscaleServers.removeValue(forKey: staleEndpoint)?.stop()
      readyTailscaleEndpoints.remove(staleEndpoint)
    }
    for endpoint in endpoints where tailscaleServers[endpoint] == nil {
      do {
        let listener = try DashboardHTTPServer(port: port, tailscaleEndpoint: endpoint)
        tailscaleServers[endpoint] = listener
        listener.start { [weak self, weak listener] state in
          guard let self, let listener, self.tailscaleServers[endpoint] === listener else { return }
          switch state {
          case .ready:
            self.readyTailscaleEndpoints.insert(endpoint)
            Self.log.notice("监控大屏 Tailscale 监听已就绪")
          case .failed, .waiting:
            self.tailscaleServers.removeValue(forKey: endpoint)?.stop()
            self.readyTailscaleEndpoints.remove(endpoint)
            Self.log.error("监控大屏 Tailscale 监听失败")
          default:
            return
          }
          self.updateTailscaleStatus()
        } handle: { [weak self, weak listener] request, peer in
          guard let self, let listener, self.tailscaleServers[endpoint] === listener,
            settings.dashboardEnabled, settings.dashboardTailscaleEnabled,
            settings.dashboardPort == port
          else { return DashboardHTTPResponse(status: 404) }
          let response = await self.respond(
            request, peer: peer, port: port, settings: settings, store: store)
          guard self.tailscaleServers[endpoint] === listener, settings.dashboardEnabled,
            settings.dashboardTailscaleEnabled, settings.dashboardPort == port
          else { return DashboardHTTPResponse(status: 404) }
          return response
        }
      } catch {
        Self.log.error("监控大屏无法创建 Tailscale 监听")
      }
    }
    updateTailscaleStatus()
  }

  private func updateTailscaleStatus() {
    tailscaleAddresses = readyTailscaleEndpoints.map(\.address).sorted()
    tailscaleStatus =
      !tailscaleAddresses.isEmpty ? .listening : tailscaleServers.isEmpty ? .failed : .starting
  }

  private func stopTailscale() {
    tailscaleTask?.cancel()
    tailscaleTask = nil
    for listener in tailscaleServers.values { listener.stop() }
    tailscaleServers.removeAll()
    readyTailscaleEndpoints.removeAll()
    tailscaleAddresses = []
    tailscaleStatus = .off
  }

  private func clearDemand() {
    idleTask?.cancel()
    idleTask = nil
    lastRequest = nil
    sampleDate = nil
    hasProcessSample = false
    hasViewerDemand = false
  }

  private func requestSample() {
    guard !paused else { return }
    lastRequest = .now
    guard idleTask == nil else { return }
    hasViewerDemand = true
    idleTask = Task { [weak self] in
      // 连续刷新只延后同一个截止时间，避免给每个请求启动一个后台采样任务。
      while let expires = self?.lastRequest?.advanced(by: .seconds(8)) {
        try? await Task.sleep(until: expires, tolerance: .milliseconds(250), clock: .continuous)
        guard !Task.isCancelled else { return }
        if self?.lastRequest?.advanced(by: .seconds(8)) == expires {
          self?.clearDemand()
          return
        }
      }
    }
  }

  private func reading(settings: AppSettings, store: MetricsStore) -> DashboardReading {
    guard !paused else { return DashboardReading(status: .paused) }
    guard
      store.hasBattery || !settings.enabledMonitoringModules.isDisjoint(with: Self.displayedModules)
    else { return DashboardReading(status: .unavailable) }
    guard let sampleDate else { return DashboardReading(status: .sampling) }
    let cpu = settings.isModuleEnabled(.cpu) ? store.cpu : nil
    let memory = settings.isModuleEnabled(.memory) ? store.memory : nil
    let network = settings.isModuleEnabled(.network) ? store.network : nil
    let disk = settings.isModuleEnabled(.disk) ? store.disk : nil
    let uid = getuid()
    return DashboardReading(
      status: .live, timestamp: sampleDate.timeIntervalSince1970,
      cpu: cpu.map { .init(usage: $0.total, cores: $0.perCore, loadAverage: $0.loadAverage) },
      gpuUsage: settings.isModuleEnabled(.gpu) ? store.gpu?.utilization : nil,
      memory: memory.map { .init(usedBytes: $0.used, totalBytes: $0.total) },
      network: network.map { rate in
        let interface = store.networkInterface.flatMap {
          $0.bsdName == rate.interfaceName ? $0 : nil
        }
        return .init(
          downloadBytesPerSecond: rate.downloadBytesPerSecond,
          uploadBytesPerSecond: rate.uploadBytesPerSecond, interfaceName: rate.interfaceName,
          interfaceDisplayName: interface?.displayName, ipv4: interface?.ipv4)
      },
      disk: disk.map { .init(usedBytes: $0.used, totalBytes: $0.total) },
      battery: store.battery.map {
        .init(level: $0.level, charging: $0.isCharging, pluggedIn: $0.isPluggedIn)
      },
      processes: hasProcessSample && settings.isModuleEnabled(.cpu)
        ? store.processes.lazy.filter { $0.isOwned && $0.uid == uid }.prefix(8).map {
          .init(name: String($0.name.prefix(80)), cpu: $0.cpu, memoryBytes: $0.memory)
        } : nil)
  }

  func respond(
    _ request: DashboardHTTPRequest, peer: DashboardPeer, port: UInt16, settings: AppSettings,
    store: MetricsStore
  ) async -> DashboardHTTPResponse {
    let tailscaleHost: NWEndpoint.Host?
    if case .tailscale(let endpoint) = peer {
      guard settings.dashboardTailscaleEnabled else { return DashboardHTTPResponse(status: 403) }
      tailscaleHost = endpoint
    } else {
      tailscaleHost = nil
    }
    guard let host = request.headers["host"],
      let authority = DashboardPeer.authority(host, port: port, tailscaleHost: tailscaleHost),
      authority == peer || peer == .loopback
    else { return DashboardHTTPResponse(status: 403) }
    if let origin = request.headers["origin"],
      origin.caseInsensitiveCompare("http://\(host)") != .orderedSame
    {
      return DashboardHTTPResponse(status: 403)
    }
    if request.path != "/", let site = request.headers["sec-fetch-site"],
      site != "same-origin", site != "none"
    {
      return DashboardHTTPResponse(status: 403)
    }
    if request.path == "/mcp" {
      guard (peer == .loopback && authority == .loopback) || tailscaleHost != nil else {
        return DashboardHTTPResponse(status: 403)
      }
      guard request.method == "POST" else {
        return DashboardHTTPResponse(status: 405, allow: "POST")
      }
      return await mcp(request, settings: settings, store: store)
    }
    guard request.method == "GET", request.body.isEmpty else {
      return DashboardHTTPResponse(status: 405, allow: "GET")
    }
    switch request.path {
    case "/":
      return DashboardHTTPResponse(
        status: 200, type: "text/html; charset=utf-8",
        body: Data(DashboardPage.html(language: settings.language).utf8))
    case "/dashboard.js":
      return DashboardHTTPResponse(
        status: 200, type: "text/javascript; charset=utf-8", body: Data(DashboardPage.script.utf8))
    case "/api/snapshot":
      requestSample()
      var response = Self.json(try? JSONEncoder().encode(reading(settings: settings, store: store)))
      response.appLanguage = settings.language.languageCode
      return response
    case let path where path.hasPrefix(DashboardPage.languagePath):
      let code = String(path.dropFirst(DashboardPage.languagePath.count))
      guard let labels = DashboardPage.localization(for: code) else {
        return DashboardHTTPResponse(status: 404)
      }
      return Self.json(labels)
    case let path where path.hasPrefix(DashboardCalendar.path):
      let parts = path.dropFirst(DashboardCalendar.path.count)
        .split(separator: "/", omittingEmptySubsequences: false)
      guard parts.count == 2, let language = DashboardPage.language(for: String(parts[0])),
        let summary = DashboardCalendar.summary(for: String(parts[1]), language: language)
      else { return DashboardHTTPResponse(status: 404) }
      return Self.json(try? JSONEncoder().encode(summary))
    default:
      return DashboardHTTPResponse(status: 404)
    }
  }

  private func mcp(
    _ request: DashboardHTTPRequest, settings: AppSettings, store: MetricsStore
  ) async -> DashboardHTTPResponse {
    guard
      request.headers["content-type"]?.split(separator: ";").first?.lowercased()
        == "application/json"
    else { return DashboardHTTPResponse(status: 415) }
    if let version = request.headers["mcp-protocol-version"], !Self.versions.contains(version) {
      return DashboardHTTPResponse(status: 400)
    }
    guard
      let message = try? JSONSerialization.jsonObject(
        with: request.body, options: .fragmentsAllowed)
    else {
      return Self.rpcError(id: NSNull(), code: -32700, message: "Parse error")
    }
    guard let call = message as? [String: Any], call["jsonrpc"] as? String == "2.0",
      let method = call["method"] as? String
    else { return Self.rpcError(id: NSNull(), code: -32600, message: "Invalid request") }
    guard let id = call["id"] else { return DashboardHTTPResponse(status: 202) }
    guard id is String || (id as? NSNumber).map({ CFGetTypeID($0) != CFBooleanGetTypeID() }) == true
    else { return Self.rpcError(id: NSNull(), code: -32600, message: "Invalid request") }
    let params = call["params"] as? [String: Any]
    let result: [String: Any]
    switch method {
    case "initialize":
      let requested = params?["protocolVersion"] as? String
      result = [
        "protocolVersion": Self.versions.first(where: { $0 == requested }) ?? Self.versions[0],
        "capabilities": ["tools": [:] as [String: Any]],
        "serverInfo": [
          "name": "xstats-monitoring",
          "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1",
        ],
      ]
    case "ping":
      result = [:]
    case "tools/list":
      result = [
        "tools": [
          [
            "name": Self.toolName,
            "description":
              "Read this Mac's current CPU, GPU, memory, network, disk, battery, and top CPU processes when available. Usage is expressed as a fraction and process CPU is relative to one core. Missing fields are unavailable. Retry if status is sampling.",
            "inputSchema": [
              "type": "object", "properties": [:] as [String: Any], "additionalProperties": false,
            ],
            "annotations": [
              "readOnlyHint": true, "destructiveHint": false, "openWorldHint": false,
            ],
          ] as [String: Any]
        ]
      ]
    case "tools/call":
      guard params?["name"] as? String == Self.toolName,
        params?["arguments"] == nil || (params?["arguments"] as? [String: Any])?.isEmpty == true
      else { return Self.rpcError(id: id, code: -32602, message: "Invalid tool or arguments") }
      requestSample()
      if !paused, sampleDate == nil {
        try? await Task.sleep(for: .milliseconds(2500), tolerance: .milliseconds(100))
      }
      guard !Task.isCancelled else { return DashboardHTTPResponse(status: 404) }
      guard let data = try? JSONEncoder().encode(reading(settings: settings, store: store)),
        let object = try? JSONSerialization.jsonObject(with: data)
      else { return Self.rpcError(id: id, code: -32603, message: "Internal error") }
      result = [
        "content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
        "structuredContent": object,
      ]
    default:
      return Self.rpcError(id: id, code: -32601, message: "Method not found")
    }
    return Self.json(
      try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result]))
  }

  private static func rpcError(id: Any, code: Int, message: String) -> DashboardHTTPResponse {
    json(
      try? JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message],
      ]))
  }

  private static func json(_ body: Data?) -> DashboardHTTPResponse {
    guard let body else { return DashboardHTTPResponse(status: 500) }
    return DashboardHTTPResponse(status: 200, type: "application/json", body: body)
  }
}

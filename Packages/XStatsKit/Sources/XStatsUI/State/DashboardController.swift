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

  enum Sampling: Hashable {
    case snapshot, cpuProcesses, memoryProcesses, health
  }

  private enum ProcessSort: String {
    case cpu, memory

    var module: MonitoringModule { self == .cpu ? .cpu : .memory }
    var sampling: Sampling { self == .cpu ? .cpuProcesses : .memoryProcesses }
  }

  private struct ProcessReading: Encodable {
    let status: DashboardReading.Status
    var timestamp: Double?
    let sortBy: String
    var processes: [DashboardReading.Process]?
  }

  private struct HealthReading: Encodable {
    struct Battery: Encodable {
      let health: Double?
      let cycleCount: Int?
      let powerWatts: Double?
    }

    struct Temperature: Encodable {
      let group: String
      let averageCelsius: Double
      let maximumCelsius: Double
    }

    struct Disk: Encodable {
      let availableBytes: UInt64
      let totalBytes: UInt64
    }

    let status: DashboardReading.Status
    var timestamp: Double?
    var battery: Battery?
    var systemPowerWatts: Double?
    var temperatures: [Temperature]?
    var disk: Disk?
    var activeAlerts: [String]?
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
  private static let processToolName = "xstats_top_processes"
  private static let healthToolName = "xstats_system_health"
  private static let processLimit = 1...20
  private static let defaultProcessLimit = 10
  private static let displayedModules: Set<MonitoringModule> = [
    .cpu, .memory, .network, .disk, .gpu,
  ]

  private(set) var status = Status.off
  private(set) var sampling: Set<Sampling> = []
  var hasViewerDemand: Bool { sampling.contains(.snapshot) }
  private(set) var tailscaleAddresses: [String] = []
  private(set) var tailscaleStatus = Status.off
  @ObservationIgnored private var server: DashboardHTTPServer?
  @ObservationIgnored private var tailscaleServers:
    [DashboardTailscaleEndpoint: DashboardHTTPServer] = [:]
  @ObservationIgnored private var readyTailscaleEndpoints: Set<DashboardTailscaleEndpoint> = []
  @ObservationIgnored private var tailscaleTask: Task<Void, Never>?
  @ObservationIgnored private var port: UInt16?
  @ObservationIgnored private var paused = false
  @ObservationIgnored private var deadlines: [Sampling: ContinuousClock.Instant] = [:]
  @ObservationIgnored private var idleTask: Task<Void, Never>?
  @ObservationIgnored private var sampleDate: Date?
  @ObservationIgnored private var hasProcessSample = false
  @ObservationIgnored private var processSampleDate: Date?
  @ObservationIgnored private var healthSampleDate: Date?
  @ObservationIgnored private var healthTemperatures: [TemperatureSummary]?
  @ObservationIgnored weak var alerts: AlertController?

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
    guard !sampling.isEmpty, !paused else { return }
    if snapshot.processes != nil {
      if hasViewerDemand { hasProcessSample = true }
      if hasViewerDemand || sampling.contains(.cpuProcesses) || sampling.contains(.memoryProcesses)
      {
        processSampleDate = snapshot.date
      }
    }
    if sampling.contains(.health) {
      if let sensors = snapshot.sensors { healthTemperatures = sensors.temperatures }
      if snapshot.disk != nil || snapshot.battery != nil || snapshot.power != nil
        || snapshot.sensors != nil
      {
        healthSampleDate = snapshot.date
      }
    }
    if hasViewerDemand,
      snapshot.cpu != nil || snapshot.memory != nil || snapshot.gpu != nil
        || snapshot.network != nil || snapshot.disk != nil || snapshot.battery != nil
        || snapshot.processes != nil
    {
      sampleDate = snapshot.date
    }
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
    deadlines.removeAll()
    sampling = []
    sampleDate = nil
    hasProcessSample = false
    processSampleDate = nil
    healthSampleDate = nil
    healthTemperatures = nil
  }

  private func requestSample(_ demand: Sampling = .snapshot) {
    guard !paused else { return }
    deadlines[demand] = .now.advanced(by: .seconds(8))
    if !sampling.contains(demand) { sampling.insert(demand) }
    guard idleTask == nil else { return }
    idleTask = Task { [weak self] in
      // 各工具独立到期，持续打开的网页不会让诊断采样一直运行。
      while let expires = self?.deadlines.values.min() {
        try? await Task.sleep(until: expires, tolerance: .milliseconds(250), clock: .continuous)
        guard !Task.isCancelled, let self else { return }
        let now = ContinuousClock.now
        self.deadlines = self.deadlines.filter { $0.value > now }
        let remaining = Set(self.deadlines.keys)
        if self.sampling != remaining { self.sampling = remaining }
        if !remaining.contains(.snapshot) {
          self.sampleDate = nil
          self.hasProcessSample = false
        }
        if !remaining.contains(.snapshot), !remaining.contains(.cpuProcesses),
          !remaining.contains(.memoryProcesses)
        {
          self.processSampleDate = nil
        }
        if !remaining.contains(.health) {
          self.healthSampleDate = nil
          self.healthTemperatures = nil
        }
      }
      self?.idleTask = nil
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

  private func processReading(sort: ProcessSort, limit: Int, store: MetricsStore) -> ProcessReading
  {
    if paused { return ProcessReading(status: .paused, sortBy: sort.rawValue) }
    guard let processSampleDate else {
      return ProcessReading(status: .sampling, sortBy: sort.rawValue)
    }
    let uid = getuid()
    let owned = store.processes.lazy.filter { $0.isOwned && $0.uid == uid }
    // 采样器已经按 CPU 排序，只有内存排行需要重新排序。
    let top =
      sort == .cpu
      ? Array(owned.prefix(limit))
      : Array(owned.sorted { $0.memory > $1.memory }.prefix(limit))
    return ProcessReading(
      status: .live, timestamp: processSampleDate.timeIntervalSince1970, sortBy: sort.rawValue,
      processes: top.map {
        .init(name: String($0.name.prefix(80)), cpu: $0.cpu, memoryBytes: $0.memory)
      })
  }

  private func healthReading(settings: AppSettings, store: MetricsStore) -> HealthReading {
    if paused { return HealthReading(status: .paused) }
    let energyEnabled = settings.isModuleEnabled(.battery)
    let diskEnabled = settings.isModuleEnabled(.disk)
    let needsSample = energyEnabled || diskEnabled || store.hasBattery
    if needsSample { requestSample(.health) }
    let power = energyEnabled && healthSampleDate != nil ? store.power : nil
    let temperatures = energyEnabled ? healthTemperatures?.filter { $0.group != .palmRest } : nil
    // 磁盘和电池沿用原有低频缓存，避免诊断调用强制刷新系统读数。
    let battery = store.battery
    let disk = diskEnabled ? store.disk : nil
    let activeAlerts = alerts?.activeKinds.map(\.rawValue) ?? []
    let status: DashboardReading.Status =
      if needsSample && healthSampleDate == nil {
        .sampling
      } else if battery != nil || disk != nil || power?.system != nil
        || temperatures?.isEmpty == false
        || !activeAlerts.isEmpty
      {
        .live
      } else {
        .unavailable
      }
    return HealthReading(
      status: status, timestamp: healthSampleDate?.timeIntervalSince1970,
      battery: battery.map {
        .init(health: $0.health, cycleCount: $0.cycleCount, powerWatts: power?.battery)
      },
      systemPowerWatts: power?.system,
      temperatures: temperatures?.map {
        .init(group: $0.group.rawValue, averageCelsius: $0.average, maximumCelsius: $0.maximum)
      },
      disk: disk.map { .init(availableBytes: $0.available, totalBytes: $0.total) },
      activeAlerts: activeAlerts)
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
    let isDashboardPage = request.path == "/" || request.path.hasPrefix("/?")
    if !isDashboardPage, let site = request.headers["sec-fetch-site"],
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
    case _ where isDashboardPage:
      let kiosk =
        URLComponents(string: request.path)?.queryItems?
        .first(where: { $0.name == "kiosk" })?.value == "1"
      return DashboardHTTPResponse(
        status: 200, type: "text/html; charset=utf-8",
        body: Data(DashboardPage.html(language: settings.language, kiosk: kiosk).utf8))
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
      let emptySchema: [String: Any] = [
        "type": "object", "properties": [:] as [String: Any], "additionalProperties": false,
      ]
      let readOnly = ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false]
      result = [
        "tools": [
          [
            "name": Self.toolName,
            "description":
              "Read this Mac's current CPU, GPU, memory, network, disk, battery, and top CPU processes when available. Usage is expressed as a fraction and process CPU is relative to one core. Missing fields are unavailable. Retry if status is sampling.",
            "inputSchema": emptySchema,
            "annotations": readOnly,
          ],
          [
            "name": Self.processToolName,
            "description": tr("按 CPU 或内存占用查看当前用户的进程排行。"),
            "inputSchema": [
              "type": "object", "additionalProperties": false,
              "properties": [
                "sortBy": ["type": "string", "enum": ["cpu", "memory"], "default": "cpu"],
                "limit": [
                  "type": "integer", "minimum": Self.processLimit.lowerBound,
                  "maximum": Self.processLimit.upperBound, "default": Self.defaultProcessLimit,
                ],
              ],
            ],
            "annotations": readOnly,
          ],
          [
            "name": Self.healthToolName,
            "description": tr("读取本机的电池健康度、循环次数、功耗、温度、可用磁盘空间和活跃告警。"),
            "inputSchema": emptySchema,
            "annotations": readOnly,
          ],
        ] as [[String: Any]]
      ]
    case "tools/call":
      guard let params, let name = params["name"] as? String,
        let arguments = (params["arguments"] ?? [:] as [String: Any]) as? [String: Any]
      else {
        return Self.rpcError(id: id, code: -32602, message: "Invalid tool or arguments")
      }
      let data: Data?
      let encoder = JSONEncoder()
      switch name {
      case Self.toolName where arguments.isEmpty:
        requestSample()
        if !paused, sampleDate == nil {
          try? await Task.sleep(for: .milliseconds(2500), tolerance: .milliseconds(100))
        }
        guard !Task.isCancelled else { return DashboardHTTPResponse(status: 404) }
        data = try? encoder.encode(reading(settings: settings, store: store))
      case Self.processToolName:
        guard Set(arguments.keys).isSubset(of: ["sortBy", "limit"]),
          let sortName = (arguments["sortBy"] ?? "cpu") as? String,
          let sort = ProcessSort(rawValue: sortName),
          let number = (arguments["limit"] ?? Self.defaultProcessLimit) as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          let limit = number as? Int, Self.processLimit.contains(limit)
        else {
          return Self.rpcError(id: id, code: -32602, message: "Invalid tool or arguments")
        }
        if !paused, !settings.isModuleEnabled(sort.module) {
          data = try? encoder.encode(ProcessReading(status: .unavailable, sortBy: sort.rawValue))
        } else {
          requestSample(sort.sampling)
          data = try? encoder.encode(processReading(sort: sort, limit: limit, store: store))
        }
      case Self.healthToolName where arguments.isEmpty:
        data = try? encoder.encode(healthReading(settings: settings, store: store))
      default:
        return Self.rpcError(id: id, code: -32602, message: "Invalid tool or arguments")
      }
      guard let data,
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

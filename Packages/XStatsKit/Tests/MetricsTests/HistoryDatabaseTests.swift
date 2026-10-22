import Foundation
import Testing
import SQLite3
@testable import Metrics

@Suite struct HistoryDatabaseTests {
  @Test func accumulatesPerMinute() {
    var accumulator = HistoryAccumulator()
    let base = Date(timeIntervalSince1970: 1_800_000_000 / 60 * 60)
    #expect(
      accumulator.add(
        date: base, cpu: 0.2, memory: 0.5, pressure: 1, download: 100, upload: 10, gpu: nil,
        temperature: 50, power: nil) == nil)
    #expect(
      accumulator.add(
        date: base.addingTimeInterval(30), cpu: 0.6, memory: 0.7, pressure: 2, download: 300,
        upload: 30, gpu: nil, temperature: 60, power: nil) == nil)
    let record = accumulator.add(
      date: base.addingTimeInterval(61), cpu: 0.1, memory: 0.1, pressure: 1, download: 0, upload: 0,
      gpu: nil, temperature: 40, power: nil)
    #expect(record?.minute == Int(base.timeIntervalSince1970))
    #expect(abs((record?.cpu ?? 0) - 0.4) < 1e-9)
    #expect(record?.cpuMax == 0.6)
    #expect(record?.pressure == 2)
    #expect(record?.download == 200)
    #expect(record?.temperature == 60)
    #expect(record?.gpu == nil)
    #expect(accumulator.flush()?.minute == Int(base.timeIntervalSince1970) + 60)
    #expect(accumulator.flush() == nil)
  }

  @Test func flushPreservesSameMinuteSampleWeightsAndPeaks() throws {
    var accumulator = HistoryAccumulator()
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    _ = accumulator.add(
      date: base, cpu: 0.9, memory: 0.6, pressure: 4, download: 900, upload: nil, gpu: 0.9,
      temperature: 95, power: 30, battery: 0.9)
    let firstSnapshot = accumulator.flush()
    let first = try #require(firstSnapshot)
    #expect(first.cpuMax == 0.9 && first.temperature == 95 && first.pressure == 4)
    #expect(accumulator.flush() == nil)
    _ = accumulator.add(
      date: base.addingTimeInterval(20), cpu: 0.3, memory: nil, pressure: 1, download: 300,
      upload: 20, gpu: nil, temperature: 40, power: 10, battery: nil)
    _ = accumulator.add(
      date: base.addingTimeInterval(40), cpu: 0, memory: 0.2, pressure: 2, download: 0,
      upload: 40, gpu: 0.3, temperature: 60, power: 20, battery: 0.7)
    let resumedSnapshot = accumulator.flush()
    let resumed = try #require(resumedSnapshot)
    #expect(abs((resumed.cpu ?? 0) - 0.4) < 1e-9)
    #expect(resumed.cpuMax == 0.9 && resumed.temperature == 95 && resumed.pressure == 4)
    #expect(abs((resumed.memory ?? 0) - 0.4) < 1e-9)
    #expect(resumed.download == 400 && resumed.upload == 30)
    #expect(abs((resumed.gpu ?? 0) - 0.6) < 1e-9)
    #expect(resumed.power == 20)
    #expect(abs((resumed.battery ?? 0) - 0.8) < 1e-9)
    #expect(accumulator.flush() == nil)
    #expect(
      accumulator.add(
        date: base.addingTimeInterval(61), cpu: 0.1, memory: nil, pressure: 1, download: nil,
        upload: nil, gpu: nil, temperature: 35, power: nil) == nil)
    let nextSnapshot = accumulator.flush()
    let next = try #require(nextSnapshot)
    #expect(next.cpu == 0.1 && next.cpuMax == 0.1 && next.temperature == 35)
  }

  @Test func rolloverPersistsCumulativeRecordAfterMidMinuteFlush() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try HistoryDatabase(url: root.appendingPathComponent("history.sqlite"))
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    var accumulator = HistoryAccumulator()
    _ = accumulator.add(
      date: base, cpu: 0.9, memory: nil, pressure: 4, download: nil, upload: nil, gpu: nil,
      temperature: 95, power: nil)
    let initial = accumulator.flush()
    await database.insert(try #require(initial))
    _ = accumulator.add(
      date: base.addingTimeInterval(30), cpu: 0.1, memory: nil, pressure: 1, download: nil,
      upload: nil, gpu: nil, temperature: 40, power: nil)
    let finished = accumulator.add(
      date: base.addingTimeInterval(61), cpu: 0.2, memory: nil, pressure: 1, download: nil,
      upload: nil, gpu: nil, temperature: 35, power: nil)
    await database.insert(try #require(finished))
    let points = await database.query(from: base, to: base.addingTimeInterval(60), bucket: 60)
    let point = try #require(points.first)
    #expect(points.count == 1)
    #expect(point.cpu == 0.5 && point.cpuMax == 0.9)
    #expect(point.temperature == 95 && point.pressure == 4)
  }

  @Test func lockedWriterReportsFailureAndRecoversAfterUnlock() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("history.sqlite")
    let database = try HistoryDatabase(url: url)
    var blocker: OpaquePointer?
    try #require(sqlite3_open(url.path, &blocker) == SQLITE_OK)
    defer { sqlite3_close(blocker) }
    try #require(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
    let record = HistoryRecord(minute: 1_800_000_000, cpu: 0.5)
    // 持锁时确实写入失败，调用方必须能够区分失败与成功。
    #expect(await database.insert(record) == false)
    #expect(await database.count() == 0)
    try #require(sqlite3_exec(blocker, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
    #expect(await database.insert(record) == true)
    #expect(await database.count() == 1)
  }

  @Test func storesQueriesAndPrunes() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "history-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let database = try HistoryDatabase(url: url)
    let start = 1_800_000_000 / 3600 * 3600
    for index in 0..<120 {
      await database.insert(
        HistoryRecord(
          minute: start + index * 60, cpu: Double(index % 2), cpuMax: 1, memory: 0.5,
          pressure: index == 5 ? 4 : 1, download: 10, upload: nil))
    }
    #expect(await database.count() == 120)

    let hourly = await database.query(
      from: Date(timeIntervalSince1970: TimeInterval(start)),
      to: Date(timeIntervalSince1970: TimeInterval(start + 7200)), bucket: 3600)
    #expect(hourly.count == 2)
    #expect(hourly.first?.cpu == 0.5)
    #expect(hourly.first?.pressure == 4)
    #expect(hourly.last?.pressure == 1)
    #expect(hourly.first?.upload == nil)

    await database.prune(before: Date(timeIntervalSince1970: TimeInterval(start + 3600)))
    #expect(await database.count() == 60)
    await database.clear()
    #expect(await database.count() == 0)
  }
}

@Suite struct BluetoothBatteryTests {
  @Test func parsesConnectedDevices() {
    let json = """
      {"SPBluetoothDataType":[{"controller_properties":{},
        "device_connected":[
          {"AirPods Pro":{"device_address":"AA:BB","device_minorType":"Headphones","device_batteryLevelLeft":"80%","device_batteryLevelRight":"75 %","device_batteryLevelCase":"40%"}},
          {"Magic Keyboard":{"device_address":"CC:DD","device_minorType":"Keyboard","device_batteryLevelMain":"55%"}}
        ],
        "device_not_connected":[
          {"Old Mouse":{"device_address":"EE:FF","device_minorType":"Mouse"}},
          {"Nearby Phone":{"device_address":"11:22"}}
        ]}]}
      """
    let devices = BluetoothBatteryReader.parseSystemProfiler(Data(json.utf8))
    #expect(devices.count == 3)
    let airpods = devices.first { $0.name == "AirPods Pro" }
    #expect(airpods?.kind == .headphones)
    #expect(airpods?.batteries.map(\.percent) == [80, 75, 40])
    #expect(airpods?.batteries.map(\.label) == ["左耳", "右耳", "充电盒"])
    #expect(devices.first { $0.name == "Magic Keyboard" }?.batteries.first?.percent == 55)
    let oldMouse = devices.first { $0.name == "Old Mouse" }
    #expect(oldMouse?.kind == .mouse)
    #expect(oldMouse?.isConnected == false)
    #expect(oldMouse?.batteries.isEmpty == true)
    #expect(!devices.contains { $0.name == "Nearby Phone" })
    #expect(BluetoothBatteryReader.percentValue("120%") == nil)
    #expect(BluetoothBatteryReader.parseSystemProfiler(Data("oops".utf8)).isEmpty)
  }

  @Test func parsesNamedAccessoryPowerSources() {
    let output = """
      Now drawing from 'AC Power'
       -InternalBattery-0 (id=23134307)\t80%; AC attached; not charging present: true
       -Magic Keyboard (id=1234)\t98%; discharging present: true
       -大唐西域进贡上等白玉耳坠 (id=5678)\t76%; charging present: true
       - (id=9999)\t24%; discharging present: true
      """

    let devices = BluetoothBatteryReader.parsePMSet(output)

    #expect(devices.map(\.name) == ["Magic Keyboard", "大唐西域进贡上等白玉耳坠"])
    #expect(devices.map { $0.batteries.first?.percent } == [98, 76])
    #expect(devices.map(\.kind) == [.keyboard, .other])
    #expect(devices.map(\.isCharging) == [false, true])
  }

  @Test func anonymousChargingSourceMatchesOnlyOneConnectedBattery() {
    let output = """
      Now drawing from 'AC Power'
       - (id=53280768)\t69%; charging present: true
      """
    let trackpad = BluetoothDevice(
      name: "Magic Trackpad", address: "AA:BB", kind: .trackpad,
      batteries: [("电量", 69)])
    let connected = BluetoothBatteryReader.mergeChargingSources([trackpad], powerOutput: output)
    #expect(connected.first?.isCharging == true)

    let other = BluetoothDevice(
      name: "Headphones", address: "CC:DD", kind: .headphones,
      batteries: [("电量", 69)])
    let ambiguous = BluetoothBatteryReader.mergeChargingSources(
      [trackpad, other], powerOutput: output)
    #expect(ambiguous.allSatisfy { $0.isCharging == nil })
    var knownNotCharging = other
    knownNotCharging.isCharging = false
    let mixed = BluetoothBatteryReader.mergeChargingSources(
      [trackpad, knownNotCharging], powerOutput: output)
    #expect(mixed.first?.isCharging == nil)
  }

  @Test func mergesBatterySourcesByDeviceName() {
    let profiler = BluetoothDevice(
      name: "Magic Keyboard", address: "AA:BB", kind: .keyboard, batteries: [])
    let powerSource = BluetoothDevice(
      name: "Magic Keyboard", address: "", kind: .keyboard, batteries: [("电量", 98)])
    let headphones = BluetoothDevice(
      name: "Headphones", address: "", kind: .headphones, batteries: [("电量", 76)])

    let devices = BluetoothBatteryReader.merge([profiler], with: [powerSource, headphones])

    #expect(devices.count == 2)
    #expect(devices.first { $0.name == "Magic Keyboard" }?.address == "AA:BB")
    #expect(devices.first { $0.name == "Magic Keyboard" }?.batteries.first?.percent == 98)
  }

  @Test func mergesUnnamedHIDBatteryByNormalizedAddress() {
    let profiler = BluetoothDevice(
      name: "Magic Trackpad", address: "3C:A6:F6:BF:79:DC", kind: .trackpad, batteries: [])
    let hid = BluetoothDevice(
      name: "", address: "3c-a6-f6-bf-79-dc", kind: .trackpad, batteries: [("电量", 23)])

    let devices = BluetoothBatteryReader.merge([profiler], with: [hid])

    #expect(devices.count == 1)
    #expect(devices.first?.name == "Magic Trackpad")
    #expect(devices.first?.batteries.first?.percent == 23)
  }

  @Test func keepsSameNameDevicesSeparateWhenAddressesDiffer() {
    let first = BluetoothDevice(name: "Gamepad", address: "AA:AA", kind: .other, batteries: [])
    let second = BluetoothDevice(name: "Gamepad", address: "BB:BB", kind: .other, batteries: [])
    let firstBattery = BluetoothDevice(
      name: "Gamepad", address: "aa-aa", kind: .other, batteries: [("电量", 80)])
    let secondBattery = BluetoothDevice(
      name: "Gamepad", address: "bb-bb", kind: .other, batteries: [("电量", 60)])

    let devices = BluetoothBatteryReader.merge(
      [first, second], with: [firstBattery, secondBattery])

    #expect(devices.count == 2)
    #expect(devices.first { $0.address == "AA:AA" }?.batteries.first?.percent == 80)
    #expect(devices.first { $0.address == "BB:BB" }?.batteries.first?.percent == 60)
  }

  @Test func liveBatterySourcePromotesPairedDeviceToConnected() {
    var paired = BluetoothDevice(
      name: "Headphones", address: "AA:BB", kind: .headphones, batteries: [])
    paired.isConnected = false
    let powerSource = BluetoothDevice(
      name: "Headphones", address: "", kind: .headphones, batteries: [("电量", 76)])

    let devices = BluetoothBatteryReader.merge([paired], with: [powerSource])

    #expect(devices.first?.isConnected == true)
    #expect(devices.first?.batteries.first?.percent == 76)
  }
}

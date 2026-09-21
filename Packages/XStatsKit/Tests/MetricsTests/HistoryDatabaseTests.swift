import Foundation
import Testing
@testable import Metrics

@Suite struct HistoryDatabaseTests {
    @Test func accumulatesPerMinute() {
        var accumulator = HistoryAccumulator()
        let base = Date(timeIntervalSince1970: 1_800_000_000 / 60 * 60)
        #expect(accumulator.add(date: base, cpu: 0.2, memory: 0.5, pressure: 1, download: 100, upload: 10, gpu: nil, temperature: 50, power: nil) == nil)
        #expect(accumulator.add(date: base.addingTimeInterval(30), cpu: 0.6, memory: 0.7, pressure: 2, download: 300, upload: 30, gpu: nil, temperature: 60, power: nil) == nil)
        let record = accumulator.add(date: base.addingTimeInterval(61), cpu: 0.1, memory: 0.1, pressure: 1, download: 0, upload: 0, gpu: nil, temperature: 40, power: nil)
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

    @Test func storesQueriesAndPrunes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try HistoryDatabase(url: url)
        let start = 1_800_000_000 / 3600 * 3600
        for index in 0..<120 {
            await database.insert(HistoryRecord(minute: start + index * 60, cpu: Double(index % 2), cpuMax: 1, memory: 0.5,
                                                pressure: index == 5 ? 4 : 1, download: 10, upload: nil))
        }
        #expect(await database.count() == 120)

        let hourly = await database.query(from: Date(timeIntervalSince1970: TimeInterval(start)),
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
         -Magic Keyboard (id=1234)\t98%; discharging present: true
         -大唐西域进贡上等白玉耳坠 (id=5678)\t76%;
         - (id=9999)\t24%; discharging present: true
        """

        let devices = BluetoothBatteryReader.parsePMSet(output)

        #expect(devices.map(\.name) == ["Magic Keyboard", "大唐西域进贡上等白玉耳坠"])
        #expect(devices.map { $0.batteries.first?.percent } == [98, 76])
        #expect(devices.map(\.kind) == [.keyboard, .other])
    }

    @Test func mergesBatterySourcesByDeviceName() {
        let profiler = BluetoothDevice(name: "Magic Keyboard", address: "AA:BB", kind: .keyboard, batteries: [])
        let powerSource = BluetoothDevice(name: "Magic Keyboard", address: "", kind: .keyboard, batteries: [("电量", 98)])
        let headphones = BluetoothDevice(name: "Headphones", address: "", kind: .headphones, batteries: [("电量", 76)])

        let devices = BluetoothBatteryReader.merge([profiler], with: [powerSource, headphones])

        #expect(devices.count == 2)
        #expect(devices.first { $0.name == "Magic Keyboard" }?.address == "AA:BB")
        #expect(devices.first { $0.name == "Magic Keyboard" }?.batteries.first?.percent == 98)
    }

    @Test func mergesUnnamedHIDBatteryByNormalizedAddress() {
        let profiler = BluetoothDevice(name: "Magic Trackpad", address: "3C:A6:F6:BF:79:DC", kind: .trackpad, batteries: [])
        let hid = BluetoothDevice(name: "", address: "3c-a6-f6-bf-79-dc", kind: .trackpad, batteries: [("电量", 23)])

        let devices = BluetoothBatteryReader.merge([profiler], with: [hid])

        #expect(devices.count == 1)
        #expect(devices.first?.name == "Magic Trackpad")
        #expect(devices.first?.batteries.first?.percent == 23)
    }

    @Test func keepsSameNameDevicesSeparateWhenAddressesDiffer() {
        let first = BluetoothDevice(name: "Gamepad", address: "AA:AA", kind: .other, batteries: [])
        let second = BluetoothDevice(name: "Gamepad", address: "BB:BB", kind: .other, batteries: [])
        let firstBattery = BluetoothDevice(name: "Gamepad", address: "aa-aa", kind: .other, batteries: [("电量", 80)])
        let secondBattery = BluetoothDevice(name: "Gamepad", address: "bb-bb", kind: .other, batteries: [("电量", 60)])

        let devices = BluetoothBatteryReader.merge([first, second], with: [firstBattery, secondBattery])

        #expect(devices.count == 2)
        #expect(devices.first { $0.address == "AA:AA" }?.batteries.first?.percent == 80)
        #expect(devices.first { $0.address == "BB:BB" }?.batteries.first?.percent == 60)
    }

    @Test func liveBatterySourcePromotesPairedDeviceToConnected() {
        var paired = BluetoothDevice(name: "Headphones", address: "AA:BB", kind: .headphones, batteries: [])
        paired.isConnected = false
        let powerSource = BluetoothDevice(name: "Headphones", address: "", kind: .headphones, batteries: [("电量", 76)])

        let devices = BluetoothBatteryReader.merge([paired], with: [powerSource])

        #expect(devices.first?.isConnected == true)
        #expect(devices.first?.batteries.first?.percent == 76)
    }
}

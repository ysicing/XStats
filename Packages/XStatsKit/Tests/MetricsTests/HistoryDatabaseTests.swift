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
          "device_not_connected":[{"Old Mouse":{"device_address":"EE:FF","device_minorType":"Mouse"}}]}]}
        """
        let devices = BluetoothBatteryReader.parseSystemProfiler(Data(json.utf8))
        #expect(devices.count == 2)
        let airpods = devices.first { $0.name == "AirPods Pro" }
        #expect(airpods?.kind == .headphones)
        #expect(airpods?.batteries.map(\.percent) == [80, 75, 40])
        #expect(airpods?.batteries.map(\.label) == ["左耳", "右耳", "充电盒"])
        #expect(devices.first { $0.name == "Magic Keyboard" }?.batteries.first?.percent == 55)
        #expect(BluetoothBatteryReader.percentValue("120%") == nil)
        #expect(BluetoothBatteryReader.parseSystemProfiler(Data("oops".utf8)).isEmpty)
    }
}

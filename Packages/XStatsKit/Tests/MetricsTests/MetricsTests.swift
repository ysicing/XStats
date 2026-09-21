import Foundation
import Testing
@testable import Metrics
@testable import SMC

@Suite("SMC 编解码")
struct SMCDecoderTests {
    @Test func keyRoundTrip() {
        #expect(SMCKey("F0Ac").description == "F0Ac")
        #expect(SMCKey("#KEY").code == 0x234B_4559)
    }

    @Test func decodesCommonTypes() {
        let float = withUnsafeBytes(of: Float32(1464.5)) { Array($0) }
        #expect(SMCDecoder.decode(type: "flt ", bytes: float) == 1464.5)
        #expect(SMCDecoder.decode(type: "ui8 ", bytes: [2]) == 2)
        #expect(SMCDecoder.decode(type: "ui16", bytes: [0x01, 0x02]) == 258)
        #expect(SMCDecoder.decode(type: "sp78", bytes: [0x2A, 0x80]) == 42.5)
        #expect(SMCDecoder.decode(type: "fpe2", bytes: [0x16, 0xE0]) == 1464)
        #expect(SMCDecoder.decode(type: "????", bytes: [1, 2]) == nil)
    }

    @Test func encodeMatchesDecode() throws {
        for type in ["flt ", "fpe2"] {
            let bytes = try #require(SMCDecoder.encode(type: type, value: 2400))
            #expect(SMCDecoder.decode(type: type, bytes: bytes) == 2400)
        }
    }

    @Test func SMCStructMatchesKernelLayout() {
        #expect(MemoryLayout<SMCParam>.stride == 80)
    }

    @Test func temperatureGrouping() {
        #expect(TemperatureCatalog.group(for: "Tp0C") == .cpu)
        #expect(TemperatureCatalog.group(for: "Te05") == .cpu)
        #expect(TemperatureCatalog.group(for: "Tg1U") == .gpu)
        #expect(TemperatureCatalog.group(for: "TB0T") == .battery)
        #expect(TemperatureCatalog.group(for: "Ts0P") == .palmRest)
        #expect(TemperatureCatalog.group(for: "TC0P") == .cpu)
        #expect(TemperatureCatalog.group(for: "F0Ac") == nil)
        #expect(TemperatureCatalog.group(for: "TaLP") == nil)
    }
}

@Suite("格式化")
struct FormatTests {
    @Test func bytes() {
        #expect(Format.bytes(UInt64(512)) == "512 B")
        #expect(Format.bytes(UInt64(68_719_476_736)) == "64.0 GB")
        #expect(Format.bytes(UInt64(1_000_000_000_000), base: .decimal) == "1.0 TB")
        #expect(Format.bytes(UInt64(412_000_000_000), base: .decimal) == "412 GB")
    }

    @Test func formatsProcessCPU() {
        // 单核口径：一个核跑满是 100%，多线程可以超过
        #expect(Format.coreShare(0.995) == "99.5%")
        #expect(Format.coreShare(2.5) == "250.0%")
        // 整机口径：全部核心跑满是 100%
        let cores = Double(Format.logicalCores)
        #expect(Format.machineShare(cores) == "100.0%")
        #expect(Format.machineShare(cores / 2) == "50.0%")
        #expect(Format.machineShare(0) == "0.0%")
        #expect(Format.machineShare(0.0001) == "<0.1%")
    }

    @Test func menuBarRate() {
        #expect(Format.menuBarRate(0) == "0 B/s")
        #expect(Format.menuBarRate(512) == "512 B/s")
        #expect(Format.menuBarRate(12 * 1024) == "12 KB/s")
        #expect(Format.menuBarRate(154 * 1024) == "154 KB/s")
        #expect(Format.menuBarRate(1000 * 1024) == "1.0 MB/s")
        #expect(Format.menuBarRate(1.2 * 1024 * 1024) == "1.2 MB/s")
        #expect(Format.menuBarRate(12 * 1024 * 1024) == "12 MB/s")
        #expect(Format.menuBarRate(1.1 * 1024 * 1024 * 1024) == "1.1 GB/s")
    }

    @Test func percentAndDuration() {
        #expect(Format.percent(0.257) == "26%")
        #expect(Format.percent(1.4) == "100%")
        #expect(Format.duration(minutes: 45) == "45 分钟")
        #expect(Format.duration(minutes: 120) == "2 小时")
        #expect(Format.duration(minutes: 90) == "1 小时 30 分钟")
        #expect(Format.temperature(68.4) == "68°C")
        #expect(Format.temperature(100, fahrenheit: true) == "212°F")
    }

    @Test func historyDropsOldest() {
        var history = History<Int>(capacity: 3)
        (1...5).forEach { history.append($0) }
        #expect(history.elements == [3, 4, 5])
    }
}

@Suite("本机采样", .serialized)
struct LiveSamplerTests {
    @Test func cpuNeedsTwoSamples() async throws {
        var sampler = CPUSampler()
        #expect(sampler.sample() == nil)
        try await Task.sleep(for: .milliseconds(200))
        let sample = sampler.sample()
        let load = try #require(sample)
        #expect((0...1).contains(load.total))
        #expect(load.perCore.count == CPUSampler.topology().logicalCores)
    }

    @Test func topologyCoversAllCores() {
        let topology = CPUSampler.topology()
        let indices = topology.clusters.flatMap(\.coreIndices).sorted()
        #expect(indices == Array(0..<topology.logicalCores))
    }

    @Test func memoryIsWithinPhysicalLimits() throws {
        let memory = try #require(MemorySampler().sample())
        #expect(memory.total == ProcessInfo.processInfo.physicalMemory)
        #expect(memory.used <= memory.total)
    }

    @Test func networkRateIsNonNegative() async throws {
        var sampler = NetworkSampler()
        _ = sampler.sample()
        try await Task.sleep(for: .milliseconds(200))
        let sample = sampler.sample()
        let rate = try #require(sample)
        #expect(rate.downloadBytesPerSecond >= 0)
        #expect(rate.uploadBytesPerSecond >= 0)
    }

    @Test func processesIncludeCurrentProcess() {
        var sampler = ProcessSampler()
        let processes = sampler.sample(includeSystem: true)
        #expect(processes.contains { $0.pid == getpid() && $0.isOwned && $0.threads != nil })
        // 系统进程来自 ps：launchd（PID 1）属于 root
        #expect(processes.contains { $0.pid == 1 && !$0.isOwned && $0.userName == "root" })
    }

    @Test func diskHasCapacity() throws {
        let disk = try #require(DiskSampler.sample())
        #expect(disk.total > 0)
        #expect(disk.available <= disk.total)
    }
}

@Suite struct NetworkParsingTests {
    @Test func parsesNettopOutput() {
        let output = """
        ,bytes_in,bytes_out,
        launchd.1,0,0,
        Google Chrome H.4521,120127,95191,
        broken line
        """
        let parsed = NetworkProcessSampler.parse(output)
        #expect(parsed.count == 2)
        #expect(parsed[4521]?.name == "Google Chrome H")
        #expect(parsed[4521]?.download == 120_127)
        #expect(parsed[4521]?.upload == 95_191)
    }

    @Test func usesNettopNameWhenProcessMetadataIsUnavailable() throws {
        var sampler = NetworkProcessSampler()
        _ = sampler.sample(output: """
        ,bytes_in,bytes_out,
        kernel_task.0,1000,2000,
        """, now: 1_000_000_000)

        let usage = sampler.sample(output: """
        ,bytes_in,bytes_out,
        kernel_task.0,3000,5000,
        """, now: 2_000_000_000)

        let kernel = try #require(usage.first)
        #expect(kernel.pid == 0)
        #expect(kernel.name == "kernel_task")
        #expect(kernel.download == 2_000)
        #expect(kernel.upload == 3_000)
    }

    @Test func keepsLastUsageWhenNettopFails() throws {
        var sampler = NetworkProcessSampler()
        _ = sampler.sample(output: """
        ,bytes_in,bytes_out,
        kernel_task.0,1000,2000,
        """, now: 1_000_000_000)
        let valid = sampler.sample(output: """
        ,bytes_in,bytes_out,
        kernel_task.0,3000,5000,
        """, now: 2_000_000_000)

        let retained = sampler.sample(output: nil, now: 3_000_000_000)

        #expect(retained == valid)
    }

    @Test func stopsNettopCommandAfterTimeout() {
        let clock = ContinuousClock()
        let started = clock.now
        let output = NetworkProcessSampler.run(
            path: "/bin/sleep",
            arguments: ["1"],
            timeout: 0.01
        )

        #expect(output == nil)
        #expect(started.duration(to: clock.now) < .milliseconds(500))
    }

    @Test func cancellationStopsRunningCommand() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "xstats-process-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let clock = ContinuousClock()
        let task = Task.detached {
            NetworkProcessSampler.run(
                path: "/bin/sh",
                arguments: ["-c", "touch \"$1\"; sleep 5", "xstats-test", marker.path],
                timeout: 5
            )
        }

        let launchDeadline = clock.now + .seconds(1)
        while !FileManager.default.fileExists(atPath: marker.path), clock.now < launchDeadline {
            await Task.yield()
        }
        try #require(FileManager.default.fileExists(atPath: marker.path))
        let cancelled = clock.now
        task.cancel()
        let output = await task.value

        #expect(output == nil)
        #expect(cancelled.duration(to: clock.now) < .seconds(1))
    }

    @Test func parsesCloudflareTrace() {
        let fields = PublicAddressLookup.parseTrace("fl=123\nip=203.0.113.24\nloc=CN\n")
        #expect(fields["ip"] == "203.0.113.24")
        #expect(fields["loc"] == "CN")
        #expect(PublicAddressLookup.parseTrace("ip=<html>")["ip"] == nil)
    }

    @Test func matchesEchoReplyBySequenceAndToken() {
        // 20 字节 IPv4 头 + ICMP 回显应答（标识符被内核改写为 0x8e84）
        var reply = [UInt8](repeating: 0, count: 20)
        reply[0] = 0x45
        reply += [0, 0, 0, 0, 0x8E, 0x84, 0x00, 0x07, 0xDE, 0xAD, 0xBE, 0xEF]
        #expect(ConnectivityProbe.matches(reply, count: reply.count, family: AF_INET, sequence: 7, token: 0xDEADBEEF))
        #expect(!ConnectivityProbe.matches(reply, count: reply.count, family: AF_INET, sequence: 8, token: 0xDEADBEEF))
        #expect(!ConnectivityProbe.matches(reply, count: reply.count, family: AF_INET, sequence: 7, token: 1))
    }

    @Test func computesInternetChecksum() {
        let packet: [UInt8] = [8, 0, 0, 0, 0x12, 0x34, 0, 1]
        let sum = ConnectivityProbe.checksum(packet)
        var filled = packet
        filled[2] = UInt8(sum >> 8)
        filled[3] = UInt8(sum & 0xFF)
        #expect(ConnectivityProbe.checksum(filled) == 0)
    }
}

@Suite struct GeoParsingTests {
    @Test func parsesCleanIPResponse() throws {
        let json = #"{"ok":true,"ip":"32.5.140.2","hostname":"host.example.net","geo":{"country":"美国","country_code":"US","country_en":"United States","region":"佛罗里达州","city":"玛丽湖"},"geo_sources":[{"source":"maxmind","country_code":"US"},{"source":"ipinfo","region":"Florida","city":"Lake Mary"}],"network":{"asn":7018,"asn_name":"AT&T Enterprises, LLC","isp":"AT&T Enterprises, LLC","network_type":"Residential","connection_type":"Cable/DSL","native_or_broadcast":"NATIVE"},"risk":{"risk_score":2,"risk_label":"Very Clean","is_vpn":false,"is_proxy":false,"is_datacenter":false,"is_abuser":true},"purity":{"score":98,"grade":"A+","confidence":100,"ip_type":"Residential IP","is_native":true,"residential_probability":98,"recommendation":"该 IP 整体较干净"}}"#
        let info = try #require(PublicAddressLookup.parseCleanIP(Data(json.utf8)))
        #expect(info.countryCode == "US")
        #expect(info.city == "玛丽湖" && info.cityEnglish == "Lake Mary" && info.regionEnglish == "Florida")
        #expect(info.asn == "AS7018")
        #expect(info.organization == "AT&T Enterprises, LLC")
        #expect(info.hostname == "host.example.net")
        #expect(info.networkType == "Residential" && info.connectionType == "Cable/DSL")
        #expect(info.ipType == "Residential IP" && info.isNative == true && info.residentialProbability == 98)
        #expect(info.purity == PublicAddresses.Purity(score: 98, grade: "A+", confidence: 100, recommendation: "该 IP 整体较干净"))
        #expect(info.risk == PublicAddresses.Risk(score: 2, label: "Very Clean", flags: ["abuser"]))
        #expect(info.reportURL?.absoluteString == "https://cleanip.io/32.5.140.2")
        #expect(PublicAddressLookup.parseCleanIP(Data(#"{"ok":false,"error":"bad"}"#.utf8)) == nil)
    }

    @Test func parsesHTTPResponses() throws {
        let plain = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}".utf8)
        let (body, status) = AddressFamilyRequest.parse(plain)
        #expect(status == 200 && body == Data("{\"ok\":true}".utf8))

        let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;x=1\r\n world\r\n0\r\n\r\n".utf8)
        #expect(AddressFamilyRequest.parse(chunked).0 == Data("hello world".utf8))

        let limited = Data("HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\n\r\n".utf8)
        #expect(AddressFamilyRequest.parse(limited).1 == 429)

        // 读到一半断开：chunked 缺结尾、Content-Length 不够，都不能当成完整结果
        #expect(AddressFamilyRequest.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel".utf8)).0 == nil)
        #expect(AddressFamilyRequest.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\n{}".utf8)).0 == nil)
        #expect(AddressFamilyRequest.parse(Data("garbage".utf8)).1 == 0)
    }

    @Test func rejectsUnsafeCountryCode() {
        #expect(PublicAddressLookup.validCountryCode("cn") == "CN")
        #expect(PublicAddressLookup.validCountryCode("../x") == nil)
        #expect(PublicAddressLookup.validCountryCode("USA") == nil)
    }
}

@Suite struct ProcessParsingTests {
    @Test func parsesPSOutput() {
        let output = """
            1     0  99:12.26  28144 /sbin/launchd
          412    88 712:02.63 378656 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
          913   501   0:00.51   9120 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
        broken
        """
        let entries = ProcessSampler.parsePS(output)
        #expect(entries.count == 3)
        #expect(entries[0].pid == 1 && entries[0].uid == 0)
        #expect(entries[1].cpuTime == 712 * 60 + 2.63)
        #expect(entries[1].residentBytes == 378_656 * 1024)
        #expect(entries[2].command == "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    }

    @Test func parsesCPUTimeWithHours() {
        #expect(ProcessSampler.parseCPUTime("1:02:03.50") == 3723.5)
        #expect(ProcessSampler.parseCPUTime("0:00.51") == 0.51)
        #expect(ProcessSampler.parseCPUTime("abc") == nil)
    }

    @Test func readsSystemCounts() throws {
        let counts = try #require(SystemCounts.read())
        #expect(counts.processes > 0)
        #expect(counts.threads >= counts.processes)
    }
}

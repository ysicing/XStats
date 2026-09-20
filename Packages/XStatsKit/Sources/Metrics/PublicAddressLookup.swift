import Foundation

/// 公网地址与 cleanip.io 给出的归属地、网络类型与纯净度
public struct PublicAddresses: Sendable, Equatable, Codable {
    public var ipv4: String?
    public var ipv6: String?
    /// ISO 3166 两位国家 / 地区代码（大写），例如 “CN”
    public var countryCode: String?
    public var city: String?
    /// 省 / 州，例如 “New York”
    public var region: String?
    /// cleanip.io 给的是中文地名，这里是英文，供英文界面使用
    public var cityEnglish: String?
    public var regionEnglish: String?
    /// 自治系统号，例如 “AS4134”
    public var asn: String?
    /// 网络所属组织（英文），例如 “CHINANET-BACKBONE”
    public var organization: String?
    public var hostname: String?
    /// 网络类型：Residential / Business / Hosting / Mobile …
    public var networkType: String?
    /// 自治系统的类型：isp / hosting / business / education / government / mobile
    public var asnType: String?
    /// 接入方式：Cable/DSL / Cellular / Corporate …
    public var connectionType: String?
    /// IP 类型：Residential IP / Datacenter IP …
    public var ipType: String?
    /// 原生 IP（登记国、宣告 AS 注册国与定位国一致）还是广播 IP
    public var isNative: Bool?
    public var residentialProbability: Int?
    public var purity: Purity?
    public var risk: Risk?
    public var reportURL: URL?
    /// 查纯净度时 Cloudflare 给出的这一族地址。分流代理下 cleanip.io 看到的出口可能不同，
    /// 界面显示 cleanip.io 看到的那个，缓存按这个比对“地址变没变”
    public var queriedAddress: String?

    public struct Purity: Sendable, Equatable, Codable {
        public var score: Int
        public var grade: String
        public var confidence: Int?
        public var recommendation: String?
        public init(score: Int, grade: String, confidence: Int? = nil, recommendation: String? = nil) {
            self.score = score
            self.grade = grade
            self.confidence = confidence
            self.recommendation = recommendation
        }
    }

    public struct Risk: Sendable, Equatable, Codable {
        public var score: Int
        public var label: String?
        /// 命中的标记：vpn、proxy、tor、datacenter、hosting、relay、abuser、residentialProxy
        public var flags: [String]
        public init(score: Int, label: String? = nil, flags: [String] = []) {
            self.score = score
            self.label = label
            self.flags = flags
        }
    }

    public init(ipv4: String? = nil, ipv6: String? = nil, countryCode: String? = nil,
                city: String? = nil, region: String? = nil, asn: String? = nil, organization: String? = nil) {
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.countryCode = countryCode
        self.city = city
        self.region = region
        self.asn = asn
        self.organization = organization
    }

    /// 把 cleanip.io 查到的信息并进来；国家代码以 Cloudflare 给的为准，没有时才用 cleanip.io 的
    public mutating func apply(_ geo: PublicAddressLookup.GeoInfo) {
        city = geo.city
        region = geo.region
        cityEnglish = geo.cityEnglish
        regionEnglish = geo.regionEnglish
        asn = geo.asn
        organization = geo.organization
        hostname = geo.hostname
        networkType = geo.networkType
        asnType = geo.asnType
        connectionType = geo.connectionType
        ipType = geo.ipType
        isNative = geo.isNative
        residentialProbability = geo.residentialProbability
        purity = geo.purity
        risk = geo.risk
        reportURL = geo.reportURL
        if countryCode == nil { countryCode = geo.countryCode }
    }
}

/// 查询公网 IP 与归属地。只在用户打开网络详情时请求，不携带任何本机信息。
/// 公网地址来自 Cloudflare trace（直连 IP，不依赖 DNS，同时给出国家代码），回退 ipify；
/// 归属地、ASN、网络类型与纯净度由每台 Mac 自己直接向 cleanip.io 查，不经过我们的服务器。
/// 接口按客户端 IP 限额，所以同一个公网 IP 的结果会记住一小时，收到 429 后到当天（UTC）结束都不再请求
public enum PublicAddressLookup {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": "XStats"]
        return URLSession(configuration: configuration)
    }()

    private static let geoCache = GeoCache()

    /// `includeGeo` 为假时只查询公网 IP，不请求 cleanip.io
    public static func fetch(includeGeo: Bool = true) async -> PublicAddresses {
        async let v4 = lookup(trace: "https://1.1.1.1/cdn-cgi/trace", fallback: "https://api.ipify.org")
        async let v6 = lookup(trace: "https://[2606:4700:4700::1111]/cdn-cgi/trace", fallback: "https://api6.ipify.org")
        let (ipv4, ipv6) = await (v4, v6)
        var result = PublicAddresses(ipv4: ipv4.ip, ipv6: ipv6.ip, countryCode: ipv4.country ?? ipv6.country)
        guard includeGeo, let ip = result.ipv4 ?? result.ipv6, let geo = await geoCache.lookup(ip) else { return result }
        result.apply(geo)
        return result
    }

    /// 只查一个已知地址的归属地，公网 IP 没变时用它补全，不必重新取地址
    public static func geo(for ip: String) async -> GeoInfo? {
        await geoCache.lookup(ip)
    }

    // MARK: cleanip.io

    public struct GeoInfo: Sendable, Equatable {
        public var countryCode: String?
        public var city: String?
        public var region: String?
        public var cityEnglish: String?
        public var regionEnglish: String?
        public var asn: String?
        public var organization: String?
        public var hostname: String?
        public var networkType: String?
        public var asnType: String?
        public var connectionType: String?
        public var ipType: String?
        public var isNative: Bool?
        public var residentialProbability: Int?
        public var purity: PublicAddresses.Purity?
        public var risk: PublicAddresses.Risk?
        public var reportURL: URL?
        /// cleanip.io 看到的出口地址，也就是这份结果对应的地址
        public var ip: String?
    }

    /// 只查请求方自己的出口 IP：cleanip.io 的 /cli 自 2026-09-15 起不再接受 `ip` 参数（带了一律 400）。
    /// cleanip.io 在 Cloudflare 后面，A 与 AAAA 都有，所以锁定地址族各连一次，就能分别查到本机的公网 IPv4 与 IPv6
    static let cleanIPURL = URL(string: "https://cleanip.io/cli?json=1")!

    struct CleanIPResponse: Decodable {
        struct Geo: Decodable {
            let countryCode: String?
            let country: String?
            let countryEn: String?
            let region: String?
            let city: String?
        }
        struct GeoSource: Decodable {
            let source: String?
            let region: String?
            let city: String?
        }
        struct Network: Decodable {
            let asn: Int?
            let asnName: String?
            let asnType: String?
            let isp: String?
            let networkType: String?
            let connectionType: String?
            let nativeOrBroadcast: String?
        }
        struct Purity: Decodable {
            let score: Int?
            let grade: String?
            let confidence: Int?
            let ipType: String?
            let isNative: Bool?
            let residentialProbability: Int?
            let recommendation: String?
        }
        struct Risk: Decodable {
            let riskScore: Int?
            let riskLabel: String?
            let isVpn: Bool?
            let isProxy: Bool?
            let isTor: Bool?
            let isDatacenter: Bool?
            let isHosting: Bool?
            let isRelay: Bool?
            let isAbuser: Bool?
            let isResidentialProxy: Bool?
        }
        let ok: Bool?
        let ip: String?
        let hostname: String?
        let geo: Geo?
        let geoSources: [GeoSource]?
        let network: Network?
        let purity: Purity?
        let risk: Risk?
    }

    static func parseCleanIP(_ data: Data) -> GeoInfo? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? decoder.decode(CleanIPResponse.self, from: data), response.ok != false else { return nil }
        var info = GeoInfo()
        info.countryCode = response.geo?.countryCode.flatMap(validCountryCode)
        info.city = response.geo?.city.flatMap(nonEmpty)
        info.region = response.geo?.region.flatMap(nonEmpty)
        // 英文地名取 ipinfo 那一路的
        if let english = response.geoSources?.first(where: { $0.source == "ipinfo" }) {
            info.cityEnglish = english.city.flatMap(nonEmpty)
            info.regionEnglish = english.region.flatMap(nonEmpty)
        }
        if let asn = response.network?.asn, asn > 0 { info.asn = "AS\(asn)" }
        info.organization = response.network?.isp.flatMap(nonEmpty) ?? response.network?.asnName.flatMap(nonEmpty)
        if let hostname = response.hostname.flatMap(nonEmpty), hostname != response.ip { info.hostname = hostname }
        info.networkType = response.network?.networkType.flatMap(nonEmpty)
        info.asnType = response.network?.asnType.flatMap(nonEmpty)?.lowercased()
        info.connectionType = response.network?.connectionType.flatMap(nonEmpty)
        info.ipType = response.purity?.ipType.flatMap(nonEmpty)
        info.isNative = response.purity?.isNative ?? response.network?.nativeOrBroadcast.map { $0.uppercased() == "NATIVE" }
        info.residentialProbability = response.purity?.residentialProbability
        if let score = response.purity?.score, let grade = response.purity?.grade.flatMap(nonEmpty) {
            info.purity = PublicAddresses.Purity(score: min(100, max(0, score)), grade: grade,
                                                 confidence: response.purity?.confidence,
                                                 recommendation: response.purity?.recommendation.flatMap(nonEmpty))
        }
        if let risk = response.risk, let score = risk.riskScore {
            var flags: [String] = []
            if risk.isVpn == true { flags.append("vpn") }
            if risk.isProxy == true { flags.append("proxy") }
            if risk.isResidentialProxy == true { flags.append("residentialProxy") }
            if risk.isTor == true { flags.append("tor") }
            if risk.isRelay == true { flags.append("relay") }
            if risk.isDatacenter == true { flags.append("datacenter") }
            if risk.isHosting == true { flags.append("hosting") }
            if risk.isAbuser == true { flags.append("abuser") }
            info.risk = PublicAddresses.Risk(score: min(100, max(0, score)), label: risk.riskLabel.flatMap(nonEmpty), flags: flags)
        }
        if let ip = response.ip, isAddress(ip) {
            info.ip = ip
            info.reportURL = URL(string: "https://cleanip.io/\(ip)")
        }
        return info
    }

    /// 按 IP 缓存一小时；收到 429 后到当天（UTC）结束都不再请求
    actor GeoCache {
        private static let lifetime: TimeInterval = 60 * 60
        private var entries: [String: (info: GeoInfo, date: Date)] = [:]
        private var blockedUntil: Date?

        /// `ip` 是 Cloudflare 给出的地址，决定锁定哪一族、按它缓存；查不到的不缓存，下次打开详情再试
        func lookup(_ ip: String) async -> GeoInfo? {
            if let entry = entries[ip], Date().timeIntervalSince(entry.date) < Self.lifetime { return entry.info }
            if let blockedUntil, Date() < blockedUntil { return nil }
            let ipv6 = ip.contains(":")
            var (data, status) = await AddressFamilyRequest.get(PublicAddressLookup.cleanIPURL, ipv6: ipv6)
            // 锁定地址族的连接建不起来（比如只认系统 HTTP 代理的网络）时，退回系统默认的请求方式
            if status == 0 {
                (data, status) = await PublicAddressLookup.getWithStatus(PublicAddressLookup.cleanIPURL)
            }
            if status == 429 {
                blockedUntil = Self.nextUTCMidnight()
                return nil
            }
            // 退回的请求走哪一族由系统决定，查到的不是要查的那一族就不能拿来用
            guard status == 200, let data, let info = PublicAddressLookup.parseCleanIP(data),
                  let seen = info.ip, seen.contains(":") == ipv6 else { return nil }
            entries[ip] = (info, Date())
            return info
        }

        private static func nextUTCMidnight() -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let start = calendar.startOfDay(for: Date())
            return calendar.date(byAdding: .day, value: 1, to: start) ?? Date().addingTimeInterval(12 * 3600)
        }
    }

    /// 只接受两位字母，之后会用作国旗文件名
    static func validCountryCode(_ code: String) -> String? {
        let upper = code.uppercased()
        guard upper.count == 2, upper.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else { return nil }
        return upper
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: 回退

    private static func lookup(trace: String, fallback: String) async -> (ip: String?, country: String?) {
        if let data = await get(trace), let body = String(data: data, encoding: .utf8) {
            let fields = parseTrace(body)
            if let ip = fields["ip"] { return (ip, fields["loc"].flatMap(validCountryCode)) }
        }
        if let data = await get(fallback), let body = String(data: data, encoding: .utf8) {
            let ip = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if isAddress(ip) { return (ip, nil) }
        }
        return (nil, nil)
    }

    private static func get(_ string: String) async -> Data? {
        guard let url = URL(string: string) else { return nil }
        let (data, status) = await getWithStatus(url)
        return status == 200 ? data : nil
    }

    static func getWithStatus(_ url: URL) async -> (Data?, Int) {
        await getWithStatus(url, session: session)
    }

    static func getWithStatus(_ url: URL, session: URLSession) async -> (Data?, Int) {
        guard let (data, response) = try? await session.data(from: url) else { return (nil, 0) }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func parseTrace(_ body: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in body.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = String(parts[1])
        }
        if let ip = fields["ip"], !isAddress(ip) { fields["ip"] = nil }
        return fields
    }

    static func isAddress(_ text: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
    }
}

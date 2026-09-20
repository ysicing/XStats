import Foundation

// MARK: - 国内分省三网

/// 国内三大运营商
public enum ChinaCarrier: String, Sendable, CaseIterable, Codable {
    case telecom = "ct", unicom = "cu", mobile = "cm"

    public var name: String {
        switch self {
        case .telecom: "电信"
        case .unicom: "联通"
        case .mobile: "移动"
        }
    }

    public var nameEnglish: String {
        switch self {
        case .telecom: "Telecom"
        case .unicom: "Unicom"
        case .mobile: "Mobile"
        }
    }

    /// 标记里的字：三家的正式标志是注册商标，不随应用打包，用品牌色加一个字代替
    public var mark: String {
        switch self {
        case .telecom: "电"
        case .unicom: "联"
        case .mobile: "移"
        }
    }

    public var markEnglish: String {
        switch self {
        case .telecom: "CT"
        case .unicom: "CU"
        case .mobile: "CM"
        }
    }
}

/// 国内测速节点：zstaticcdn.com 的省级 TCPPing 节点，每省电信、联通、移动各一个。
/// 该站点只允许用于连通性与延迟参考，所以这里只做 TCP 建连计时，不下载任何数据
public struct ChinaNode: Sendable, Hashable, Identifiable {
    public let province: String
    public let provinceEnglish: String
    /// 节点域名里的省份代码，如 bj、gd
    public let code: String
    public let carrier: ChinaCarrier

    public var id: String { "\(code)-\(carrier.rawValue)" }
    public var host: String { "\(code)-\(carrier.rawValue)-v4.ip.zstaticcdn.com" }
    public var port: UInt16 { 80 }

    /// 31 个省级行政区 × 三网 = 93 个节点
    public static let all: [ChinaNode] = provinces.flatMap { province in
        ChinaCarrier.allCases.map {
            ChinaNode(province: province.name, provinceEnglish: province.english, code: province.code, carrier: $0)
        }
    }

    public static let provinces: [(code: String, name: String, english: String)] = [
        ("bj", "北京", "Beijing"), ("tj", "天津", "Tianjin"), ("he", "河北", "Hebei"), ("sx", "山西", "Shanxi"),
        ("nm", "内蒙古", "Inner Mongolia"), ("ln", "辽宁", "Liaoning"), ("jl", "吉林", "Jilin"),
        ("hl", "黑龙江", "Heilongjiang"), ("sh", "上海", "Shanghai"), ("js", "江苏", "Jiangsu"),
        ("zj", "浙江", "Zhejiang"), ("ah", "安徽", "Anhui"), ("fj", "福建", "Fujian"), ("jx", "江西", "Jiangxi"),
        ("sd", "山东", "Shandong"), ("ha", "河南", "Henan"), ("hb", "湖北", "Hubei"), ("hn", "湖南", "Hunan"),
        ("gd", "广东", "Guangdong"), ("gx", "广西", "Guangxi"), ("hi", "海南", "Hainan"),
        ("cq", "重庆", "Chongqing"), ("sc", "四川", "Sichuan"), ("gz", "贵州", "Guizhou"), ("yn", "云南", "Yunnan"),
        ("xz", "西藏", "Tibet"), ("sn", "陕西", "Shaanxi"), ("gs", "甘肃", "Gansu"), ("qh", "青海", "Qinghai"),
        ("nx", "宁夏", "Ningxia"), ("xj", "新疆", "Xinjiang"),
    ]
}

// MARK: - 全球节点

/// 全球测速节点所在的大区，界面按此分组
public enum GlobalRegion: String, Sendable, CaseIterable, Codable {
    case asiaPacific, europe, northAmerica, other

    public var name: String {
        switch self {
        case .asiaPacific: "亚太"
        case .europe: "欧洲"
        case .northAmerica: "北美"
        case .other: "其他地区"
        }
    }

    public var nameEnglish: String {
        switch self {
        case .asiaPacific: "Asia-Pacific"
        case .europe: "Europe"
        case .northAmerica: "North America"
        case .other: "Other"
        }
    }
}

/// 全球测速节点：各家云厂商公开提供的测速文件。
/// 延迟用 TCP 建连计时；下载测速按用户设定的时长与流量上限截断，不会整份下载
public struct GlobalNode: Sendable, Hashable, Identifiable {
    public let id: String
    public let city: String
    public let cityEnglish: String
    /// 两位国家代码，界面上显示国旗
    public let countryCode: String
    public let region: GlobalRegion
    /// 提供测速文件的服务商
    public let provider: String
    public let downloadURL: URL

    public var host: String { downloadURL.host ?? "" }
    public var port: UInt16 { 443 }

    init(_ id: String, _ city: String, _ cityEnglish: String, _ countryCode: String,
         _ region: GlobalRegion, _ provider: String, _ url: String) {
        self.id = id
        self.city = city
        self.cityEnglish = cityEnglish
        self.countryCode = countryCode
        self.region = region
        self.provider = provider
        // 清单写死在代码里，地址不合法属于编码错误
        downloadURL = URL(string: url)!
    }

    /// 24 个节点，四家服务商，逐个验证过可用
    public static let all: [GlobalNode] = [
        // 亚太
        .init("tokyo", "东京", "Tokyo", "JP", .asiaPacific, "Linode",
              "https://speedtest.tokyo2.linode.com/100MB-tokyo2.bin"),
        .init("osaka", "大阪", "Osaka", "JP", .asiaPacific, "Linode",
              "https://speedtest.osaka.linode.com/100MB-osaka.bin"),
        .init("seoul", "首尔", "Seoul", "KR", .asiaPacific, "DataPacket",
              "https://seo.download.datapacket.com/100mb.bin"),
        .init("hongkong", "香港", "Hong Kong", "HK", .asiaPacific, "DataPacket",
              "https://hkg.download.datapacket.com/100mb.bin"),
        .init("singapore", "新加坡", "Singapore", "SG", .asiaPacific, "Linode",
              "https://speedtest.singapore.linode.com/100MB-singapore.bin"),
        .init("mumbai", "孟买", "Mumbai", "IN", .asiaPacific, "Linode",
              "https://speedtest.mumbai1.linode.com/100MB-mumbai1.bin"),
        .init("sydney", "悉尼", "Sydney", "AU", .asiaPacific, "Linode",
              "https://speedtest.sydney.linode.com/100MB-sydney.bin"),
        // 欧洲
        .init("frankfurt", "法兰克福", "Frankfurt", "DE", .europe, "Linode",
              "https://speedtest.frankfurt.linode.com/100MB-frankfurt.bin"),
        .init("london", "伦敦", "London", "GB", .europe, "Linode",
              "https://speedtest.london.linode.com/100MB-london.bin"),
        .init("amsterdam", "阿姆斯特丹", "Amsterdam", "NL", .europe, "Vultr",
              "https://ams-nl-ping.vultr.com/vultr.com.100MB.bin"),
        .init("paris", "巴黎", "Paris", "FR", .europe, "Linode",
              "https://speedtest.paris.linode.com/100MB-paris.bin"),
        .init("stockholm", "斯德哥尔摩", "Stockholm", "SE", .europe, "Linode",
              "https://speedtest.stockholm.linode.com/100MB-stockholm.bin"),
        .init("madrid", "马德里", "Madrid", "ES", .europe, "Linode",
              "https://speedtest.madrid.linode.com/100MB-madrid.bin"),
        .init("warsaw", "华沙", "Warsaw", "PL", .europe, "Vultr",
              "https://waw-pl-ping.vultr.com/vultr.com.100MB.bin"),
        // 北美
        .init("newark", "纽瓦克", "Newark", "US", .northAmerica, "Linode",
              "https://speedtest.newark.linode.com/100MB-newark.bin"),
        .init("chicago", "芝加哥", "Chicago", "US", .northAmerica, "DataPacket",
              "https://chi.download.datapacket.com/100mb.bin"),
        .init("miami", "迈阿密", "Miami", "US", .northAmerica, "DataPacket",
              "https://mia.download.datapacket.com/100mb.bin"),
        .init("dallas", "达拉斯", "Dallas", "US", .northAmerica, "Linode",
              "https://speedtest.dallas.linode.com/100MB-dallas.bin"),
        .init("seattle", "西雅图", "Seattle", "US", .northAmerica, "Linode",
              "https://speedtest.seattle.linode.com/100MB-seattle.bin"),
        .init("losangeles", "洛杉矶", "Los Angeles", "US", .northAmerica, "Vultr",
              "https://lax-ca-us-ping.vultr.com/vultr.com.100MB.bin"),
        .init("toronto", "多伦多", "Toronto", "CA", .northAmerica, "Linode",
              "https://speedtest.toronto1.linode.com/100MB-toronto1.bin"),
        // 其他地区
        .init("saopaulo", "圣保罗", "São Paulo", "BR", .other, "Linode",
              "https://speedtest.sao-paulo.linode.com/100MB-sao-paulo.bin"),
        .init("mexicocity", "墨西哥城", "Mexico City", "MX", .other, "Vultr",
              "https://mex-mx-ping.vultr.com/vultr.com.100MB.bin"),
        .init("johannesburg", "约翰内斯堡", "Johannesburg", "ZA", .other, "Vultr",
              "https://jnb-za-ping.vultr.com/vultr.com.100MB.bin"),
    ]
}

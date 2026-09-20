import Foundation

/// 排行榜的平滑打分：给每个条目按指数移动平均记一个分数，列表按分数排序。
/// 瞬时速率每秒都在变，直接按它排会让条目忽隐忽现、上下乱跳；按最近十几秒的平均排，
/// 一个应用读写完之后还会在榜上停留一会儿慢慢退下去，列表看起来是稳的
struct ActivityRanking: Equatable {
    struct Entry: Equatable {
        let id: String
        let score: Double
    }

    private(set) var scores: [String: Double] = [:]
    /// 每次采样保留的旧分数比例；0.75 时约 3 次采样后旧值影响减半
    var decay = 0.75
    /// 分数低于这个值且当前没有活动的条目移出榜单（字节 / 秒）
    var floor: Double = 512

    /// 用本次采样的瞬时值更新分数；没出现在本次采样里的条目按 0 衰减
    mutating func update(_ current: [String: Double]) {
        var next: [String: Double] = [:]
        for id in Set(scores.keys).union(current.keys) {
            let value = current[id] ?? 0
            let score = (scores[id] ?? 0) * decay + value * (1 - decay)
            if score >= floor || value > 0 { next[id] = score }
        }
        scores = next
    }

    func ranked(limit: Int) -> [Entry] {
        Array(scores.map { Entry(id: $0.key, score: $0.value) }
            .sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
            .prefix(limit))
    }

    var isEmpty: Bool { scores.isEmpty }
}

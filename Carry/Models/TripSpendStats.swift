//
//  TripSpendStats.swift
//  Carry
//
//  Trip Book 花费聚合（spec: itinerary-cost-tracking.md / trip-book.md）。
//  把已发生行程下所有费用按本位币聚合，按 `SpendCategory` 7 类细分（交通/住宿 + 地点拆为
//  餐饮/景点/活动/购物/其他，复用单行程花费页同一口径）；优先用每笔快照、缺失退实时折算、
//  再缺 → 计入「未折算」并诚实标注，绝不静默漏算。
//

import Foundation

// MARK: - CostResolver（纯函数，便于单测）

enum CostResolver {
    /// 单笔费用 → 本位币值。优先快照（稳定），无快照（-1）退实时折算，再无汇率 → nil（未计入）。
    static func homeValue(snapshot: Double, amount: Double, code: String,
                          convert: (Double, String) -> Double?) -> Double? {
        if snapshot >= 0 { return snapshot }
        return convert(amount, code)
    }
}

// MARK: - Breakdown

struct TripSpendBreakdown: Equatable {
    /// 按 7 类消费类别（`SpendCategory`）聚合的本位币金额。交通/住宿单列，地点按 `StopCategory`
    /// 细分为 餐饮/景点/活动/购物/其他——与单行程花费页同一套口径（复用 `SpendCategory`），不漂移。
    var byCategory: [SpendCategory: Double] = [:]
    /// 交通**按方式**再拆（航班/火车/巴士/渡轮/租车/其他）的本位币金额，供「查看全部」下钻按方式分行展示——
    /// 避免把租车/火车塌缩成一个「交通」行只能取一个图标（飞机）。是 `byCategory[.transport]` 的细分，
    /// 两者同源、`byCategory[.transport]` == 各方式之和；卡片仍用 `byCategory`（交通合一）。
    var transportByMode: [TransportMode: Double] = [:]
    /// 是否记录过费用（即便某笔因无汇率未计入合计，也为 true）。
    var hadAnyRecorded: Bool = false

    var total: Double { byCategory.values.reduce(0, +) }
    func amount(_ category: SpendCategory) -> Double { byCategory[category] ?? 0 }

    /// 非零类目，按金额降序（bar 与图例的统一渲染序：额大在前 / 配深色）。
    var sortedNonZero: [(category: SpendCategory, amount: Double)] {
        SpendCategory.allCases.compactMap { c in
            let v = byCategory[c] ?? 0
            return v > 0 ? (category: c, amount: v) : nil
        }
        .sorted { $0.amount > $1.amount }
    }
}

struct TripSpendRow: Identifiable {
    let id: UUID
    let name: String
    /// 出发日期（无日期「规划中」行程为 nil）。用于「查看全部」section 头区分同地多次行程；
    /// 仅传 `Date`、格式化留给 View（保持本聚合 Locale-free、可单测）。
    let departureDate: Date?
    let breakdown: TripSpendBreakdown
}

// MARK: - TripSpendStats

struct TripSpendStats {
    var homeCode: String = ""
    var overall = TripSpendBreakdown()
    var perTrip: [TripSpendRow] = []
    /// 有费用因无汇率未计入合计 → UI 脚注诚实标注。
    var hasUnconverted = false
    /// 合计含外币折算 → 显示「≈」表近似。
    var approximate = false

    var hasAnyCost: Bool { overall.hadAnyRecorded }

    /// 只统计「已发生」行程（与 Trip Book 其它卡同口径）。`convert` 注入折算（便于单测 / 解耦汇率源）。
    static func compute(trips: [TripBundle], homeCode: String,
                        convert: (Double, String) -> Double?) -> TripSpendStats {
        var stats = TripSpendStats(homeCode: homeCode)
        let home = homeCode.uppercased()
        for trip in trips where trip.countsAsVisited {
            var b = TripSpendBreakdown()
            func add(_ entity: CostBearing, _ category: SpendCategory, mode: TransportMode? = nil) {
                b.hadAnyRecorded = true
                if let value = CostResolver.homeValue(snapshot: entity.costHomeAmount,
                                                      amount: entity.costAmount,
                                                      code: entity.costCurrencyCode,
                                                      convert: convert) {
                    b.byCategory[category, default: 0] += value
                    if let mode { b.transportByMode[mode, default: 0] += value }   // 交通再按方式拆
                    if entity.costCurrencyCode.uppercased() != home { stats.approximate = true }
                } else {
                    stats.hasUnconverted = true
                }
            }
            for day in trip.safeItineraryDays {
                // 地点按 StopCategory 细分（餐饮/景点/活动/购物/其他）；交通按方式拆；住宿单列。
                for stop in (day.stops ?? []) where stop.hasCost { add(stop, SpendCategory.from(stopCategory: stop.category)) }
                for seg in (day.segments ?? []) where seg.hasCost { add(seg, .transport, mode: seg.mode) }
            }
            for stay in trip.safeLodgingStays where stay.hasCost { add(stay, .lodging) }

            if b.hadAnyRecorded {
                for (cat, amt) in b.byCategory { stats.overall.byCategory[cat, default: 0] += amt }
                for (m, amt) in b.transportByMode { stats.overall.transportByMode[m, default: 0] += amt }
                stats.overall.hadAnyRecorded = true
                stats.perTrip.append(TripSpendRow(id: trip.id, name: trip.name,
                                                  departureDate: trip.isDateless ? nil : trip.departureDate,
                                                  breakdown: b))
            }
        }
        stats.perTrip.sort { $0.breakdown.total > $1.breakdown.total }
        return stats
    }
}

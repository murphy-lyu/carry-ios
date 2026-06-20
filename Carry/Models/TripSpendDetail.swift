//
//  TripSpendDetail.swift
//  Carry
//
//  单个行程的花费聚合（spec: itinerary-trip-spend.md）。
//  与 `TripSpendStats`（Trip Book 跨行程、只统计已发生行程、粗三类）区分：本聚合面向**任意单行程**，
//  提供更细的 7 类、按天 / 按币种维度、以及逐笔清单（供「分布 + 详细清单」页渲染）。
//  纯函数（`compute`），便于单测；复用 `CostResolver.homeValue` 的「快照优先 → 实时折算 → 缺汇率诚实漏标」口径。
//

import Foundation

// MARK: - 展示类别（7 类）

/// 花费分布的展示类别：由「实体类型 + StopCategory」归并而成。交通各 mode 合并为一类（细分在逐笔清单看）。
enum SpendCategory: String, CaseIterable, Identifiable, Hashable {
    case transport, lodging, food, sightseeing, activity, shopping, other
    var id: String { rawValue }

    /// 地点（ItineraryStop）的 StopCategory → 展示类别。非餐饮/景点/活动/购物的地点归「其他」。
    static func from(stopCategory: StopCategory) -> SpendCategory {
        switch stopCategory {
        case .food:        return .food
        case .sightseeing: return .sightseeing
        case .activity:    return .activity
        case .shopping:    return .shopping
        default:           return .other
        }
    }
}

// MARK: - 逐笔

/// 逐笔费用项的来源实体类型（点击清单行时据此跳对应编辑器）。
enum SpendEntityKind: Hashable { case stop, transport, lodging }

/// 一笔已记录费用。`amount`+`currencyCode` 是原币真相；`homeAmount` 为本位币折算（nil = 缺汇率未计入合计）。
struct SpendItem: Identifiable, Hashable {
    let id: UUID                 // 来源实体 id（导航用）
    let kind: SpendEntityKind
    let name: String             // 实体名（可空 → UI 回退显类别名）
    let category: SpendCategory
    let amount: Double           // 原币种金额
    let currencyCode: String
    let homeAmount: Double?      // 本位币折算（nil = 缺汇率）
    let dayOrder: Int            // 归属天（按天分组 / 清单默认序）
}

// MARK: - 聚合结果

struct TripSpendDetail {
    let homeCode: String
    /// 逐笔（默认按 天序 → 组内本位币降序）。
    let items: [SpendItem]
    /// 已折算本位币之和（缺汇率的笔不计入）。
    let total: Double
    /// 按类别（本位币，降序，0 元类别不含）。
    let byCategory: [(category: SpendCategory, amount: Double)]
    /// 按天（本位币，按天序）。
    let byDay: [(dayOrder: Int, amount: Double)]
    /// 按币种（**原币**，降序）。
    let byCurrency: [(code: String, amount: Double)]
    /// 合计含外币折算 → 显示「≈」表近似。
    let approximate: Bool
    /// 有费用因缺汇率未计入合计 → 脚注诚实标注。
    let unconvertedCount: Int

    var recordedCount: Int { items.count }
    var hasAnyCost: Bool { !items.isEmpty }
    var currencyCount: Int { byCurrency.count }

    /// `convert` 注入折算（解耦汇率源、便于单测），同 `TripSpendStats` 范式。
    static func compute(trip: TripBundle, homeCode: String,
                        convert: (Double, String) -> Double?) -> TripSpendDetail {
        let home = homeCode.uppercased()
        var items: [SpendItem] = []
        var approximate = false
        var unconverted = 0

        func append(id: UUID, kind: SpendEntityKind, name: String,
                    category: SpendCategory, entity: CostBearing, dayOrder: Int) {
            let homeVal = CostResolver.homeValue(snapshot: entity.costHomeAmount,
                                                 amount: entity.costAmount,
                                                 code: entity.costCurrencyCode, convert: convert)
            if homeVal == nil { unconverted += 1 }
            else if entity.costCurrencyCode.uppercased() != home { approximate = true }
            items.append(SpendItem(id: id, kind: kind, name: name, category: category,
                                   amount: entity.costAmount, currencyCode: entity.costCurrencyCode,
                                   homeAmount: homeVal, dayOrder: dayOrder))
        }

        for day in trip.safeItineraryDays {
            let d = day.sortOrder
            for stop in (day.stops ?? []) where stop.hasCost {
                append(id: stop.id, kind: .stop, name: stop.name,
                       category: SpendCategory.from(stopCategory: stop.category), entity: stop, dayOrder: d)
            }
            for seg in day.sortedSegments where seg.hasCost {
                append(id: seg.id, kind: .transport, name: transportName(seg),
                       category: .transport, entity: seg, dayOrder: d)
            }
        }
        for stay in trip.safeLodgingStays where stay.hasCost {
            append(id: stay.id, kind: .lodging, name: stay.name,
                   category: .lodging, entity: stay, dayOrder: stay.checkInDayOrder)
        }

        let total = items.compactMap(\.homeAmount).reduce(0, +)

        var catMap: [SpendCategory: Double] = [:]
        var dayMap: [Int: Double] = [:]
        var curMap: [String: Double] = [:]
        for it in items {
            if let h = it.homeAmount {
                catMap[it.category, default: 0] += h
                dayMap[it.dayOrder, default: 0] += h
            }
            curMap[it.currencyCode.uppercased(), default: 0] += it.amount   // 币种用原币、含未折算笔
        }
        let byCategory = SpendCategory.allCases
            .compactMap { c -> (category: SpendCategory, amount: Double)? in
                guard let v = catMap[c], v > 0 else { return nil }
                return (category: c, amount: v)
            }
            .sorted { $0.amount > $1.amount }
        let byDay = dayMap
            .map { (dayOrder: $0.key, amount: $0.value) }
            .sorted { $0.dayOrder < $1.dayOrder }
        let byCurrency = curMap
            .map { (code: $0.key, amount: $0.value) }
            .sorted { $0.amount > $1.amount }

        let sortedItems = items.sorted {
            if $0.dayOrder != $1.dayOrder { return $0.dayOrder < $1.dayOrder }
            return ($0.homeAmount ?? 0) > ($1.homeAmount ?? 0)
        }

        return TripSpendDetail(homeCode: homeCode, items: sortedItems, total: total,
                               byCategory: byCategory, byDay: byDay, byCurrency: byCurrency,
                               approximate: approximate, unconvertedCount: unconverted)
    }

    /// 交通段展示名：优先「起 → 讫」路线（花费场景最可识别），退班次号 → 承运方 → 单端名 → 空（UI 回退类别名）。
    private static func transportName(_ seg: TransportSegment) -> String {
        let ends = [seg.fromName, seg.toName].filter { !$0.isEmpty }
        if ends.count == 2 { return "\(ends[0]) → \(ends[1])" }
        if !seg.number.isEmpty { return seg.number }
        if !seg.carrier.isEmpty { return seg.carrier }
        return ends.first ?? ""
    }
}

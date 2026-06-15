//
//  Itinerary.swift
//  Carry
//
//  行程路线规划数据模型（spec: itinerary-route-planning.md）。
//  TripBundle 挂的「第二张脸」：行程 = 多个 ItineraryDay，每个 Day = 有序的 ItineraryStop。
//  与打包清单（PackingSection/PackingItem）完全并列、互不污染。
//

import Foundation
import SwiftData
import CoreLocation

// MARK: - StopCategory

/// 停靠点类型。rawValue 存库（技术常量，不面向用户展示）；
/// UI 文案统一走 localizationKey 对应的 Localizable.xcstrings。
enum StopCategory: String, Codable, CaseIterable {
    // 顺序即菜单顺序（allCases 取声明序）。按「在地体验（高频）→ 住宿+交通（后勤）→ 其他」排。
    // 在地体验
    case sightseeing   // 景点
    case food          // 餐饮
    case activity      // 活动
    case shopping      // 购物
    // 住宿 + 交通（后勤骨架）
    case lodging       // 住宿
    case flight        // 航班（机场/飞机）
    case train = "transport"  // 火车（高铁/动车/列车）。显式保留旧 rawValue "transport" → 旧数据零迁移
    case carRental     // 租车（取车门店 / 自驾）
    case cruise        // 邮轮 / 渡轮
    // 兜底
    case other         // 其他

    /// 解析存库字符串；未知值（旧数据/脏数据）一律退化为 .other，绝不崩。
    init(rawValueOrOther raw: String) {
        self = StopCategory(rawValue: raw) ?? .other
    }

    /// 结构化本地化 key（须在 xcstrings 显式写 en）。
    var localizationKey: String { "itinerary.category.\(rawValue)" }
}

// MARK: - ItineraryDay

/// 行程中的一天。有日期行程对应日历某天；isDateless 行程仅为相对序号（Day 1/2/3…）。
/// 顺序用 `sortOrder` 表达，不绑死绝对时间，使有日期/无日期行程共用同一套结构。
@Model
final class ItineraryDay {
    var id: UUID = UUID()
    /// 第几天，0-based。isDateless 与有日期行程统一用它排序。
    var sortOrder: Int = 0
    /// 可选自定义标题（"京都古寺线"）；空则 UI 展示 "Day N"。
    var title: String = ""
    /// 当天备注。
    var note: String = ""
    var bundle: TripBundle?
    @Relationship(deleteRule: .cascade, inverse: \ItineraryStop.day)
    var stops: [ItineraryStop]? = []
    /// 当天的交通段（边）。归出发日；与 stop 共享时间轴排序空间（spec: itinerary-transport-lodging.md）。
    @Relationship(deleteRule: .cascade, inverse: \TransportSegment.day)
    var segments: [TransportSegment]? = []

    init(sortOrder: Int = 0, title: String = "", note: String = "", stops: [ItineraryStop] = []) {
        self.id = UUID()
        self.sortOrder = sortOrder
        self.title = title
        self.note = note
        self.stops = stops
    }

    /// 当天停靠点按 sortOrder 升序。
    var sortedStops: [ItineraryStop] {
        (stops ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }

    /// 当天交通段按 sortOrder 升序。
    var sortedSegments: [TransportSegment] {
        (segments ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }

    /// 时间轴单一数据源（spec: itinerary-transport-lodging.md）。
    ///
    /// **排序规则**（与「地点排序」手动重排不冲突——后者只管 stop）：
    /// 1. 停靠点（节点）**始终保持手动 sortOrder 顺序**，绝不因时间被重排（尊重用户/重排模式的安排）。
    /// 2. **设了出发时间的交通段**按时间「就位」插入到停靠点序列里（避免「带时间的航班却排在最后」）；
    ///    比较基准用 carry-forward 时间（未设时间的停靠点继承上一处时间，充当时间墙）。
    /// 3. **未设时间的交通段**保持其 sortOrder 位置（落在添加处）。
    /// 交通段本就不可手动拖动（重排模式隐藏它），故按时间就位是它唯一合理的定位方式。
    var timeline: [TimelineItem] {
        // 基线：停靠点（手动序）+ 未设时间的交通段，按 sortOrder 合并——这部分顺序不动。
        let timedSegments = sortedSegments.filter { $0.departLocalMinutes >= 0 }
        let timedSegmentIDs = Set(timedSegments.map(\.id))
        var base: [TimelineItem] =
            ((stops ?? []).map { TimelineItem.stop($0) }
             + sortedSegments.filter { !timedSegmentIDs.contains($0.id) }.map { TimelineItem.transport($0) })
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return lhs.isStop && !rhs.isStop
            }

        // 把设了时间的交通段按时间插入 base（按时间升序逐个插，碰巧同段相对稳定）。
        for seg in timedSegments.sorted(by: { $0.departLocalMinutes < $1.departLocalMinutes }) {
            let t = seg.departLocalMinutes
            // carry-forward：逐项求「有效时间」，未设时间者继承前一处时间。
            var carry = -1
            var insertAt = base.count
            for (i, item) in base.enumerated() {
                let own = item.effectiveMinutes
                if own >= 0 { carry = own }
                let eff = own >= 0 ? own : carry
                if eff >= 0 && eff > t { insertAt = i; break }
            }
            base.insert(.transport(seg), at: insertAt)
        }
        return base
    }
}

/// 时间轴的一项：要么是停留的点（节点），要么是连接两点的交通（边）。
enum TimelineItem: Identifiable {
    case stop(ItineraryStop)
    case transport(TransportSegment)

    var id: UUID {
        switch self {
        case .stop(let s): return s.id
        case .transport(let t): return t.id
        }
    }
    var sortOrder: Int {
        switch self {
        case .stop(let s): return s.sortOrder
        case .transport(let t): return t.sortOrder
        }
    }
    var isStop: Bool { if case .stop = self { return true }; return false }

    /// 该项自身的「时间」（自午夜分钟数），未设为 -1。停靠点用计划起点、交通段用出发时间。
    /// 仅用于 timeline 的时间就位排序（carry-forward 基准）。
    var effectiveMinutes: Int {
        switch self {
        case .stop(let s): return s.plannedStartMinutes
        case .transport(let t): return t.departLocalMinutes
        }
    }
}

// MARK: - ItineraryStop

/// 一个停靠点（POI）。坐标复用项目既有范式（同 DestinationEntry：lat/long）。
@Model
final class ItineraryStop {
    var id: UUID = UUID()
    var name: String = ""
    /// lat/long == 0/0 视为「无坐标停靠点」——地图/连线/重排都必须先过滤，绝不画到几内亚湾。
    var latitude: Double = 0
    var longitude: Double = 0
    /// 反向地理编码得到的可读地址（可选）。
    var address: String = ""
    /// StopCategory.rawValue；读取统一走 `category` 计算属性做未知值兜底。
    var categoryRaw: String = StopCategory.other.rawValue
    /// 当天计划时段起点（自午夜起的分钟数，-1 = 未设）。
    var plannedStartMinutes: Int = -1
    /// 预计停留时长（分钟，0 = 未设）。
    var stayMinutes: Int = 0
    var note: String = ""
    /// 当天内顺序。
    var sortOrder: Int = 0
    var day: ItineraryDay?

    init(
        name: String = "",
        latitude: Double = 0,
        longitude: Double = 0,
        address: String = "",
        category: StopCategory = .other,
        plannedStartMinutes: Int = -1,
        stayMinutes: Int = 0,
        note: String = "",
        sortOrder: Int = 0
    ) {
        self.id = UUID()
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
        self.categoryRaw = category.rawValue
        self.plannedStartMinutes = plannedStartMinutes
        self.stayMinutes = stayMinutes
        self.note = note
        self.sortOrder = sortOrder
    }

    /// 未知 rawValue 兜底为 .other；写入时回落 rawValue。
    var category: StopCategory {
        get { StopCategory(rawValueOrOther: categoryRaw) }
        set { categoryRaw = newValue.rawValue }
    }

    /// 是否有有效坐标——地图渲染、连线、单日重排前的统一过滤条件。
    var hasCoordinate: Bool {
        latitude != 0 || longitude != 0
    }

    /// 有坐标时返回 CLLocationCoordinate2D，否则 nil。
    var coordinate: CLLocationCoordinate2D? {
        guard hasCoordinate else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - TransportMode

/// 交通方式。rawValue 存库（技术常量，不面向用户展示）；UI 文案走 localizationKey。
enum TransportMode: String, Codable, CaseIterable {
    case flight        // 航班
    case train         // 火车 / 高铁
    case bus           // 长途巴士
    case ferry         // 渡轮
    case carRental     // 租车 / 自驾
    case other         // 其他

    init(rawValueOrOther raw: String) {
        self = TransportMode(rawValue: raw) ?? .other
    }

    var localizationKey: String { "itinerary.transport.mode.\(rawValue)" }
}

// MARK: - TransportSegment

/// 一段交通（时间轴上的「边」）：连接两点的移动，有出发地+到达地、起降时间、承运方/班次。
/// 不硬绑两个具体 stop 对象——更鲁棒（能处理「到达后还没排地点」「跨天航班」）；
/// 归出发日，与 stop 共享时间轴排序空间。spec: itinerary-transport-lodging.md。
@Model
final class TransportSegment {
    var id: UUID = UUID()
    /// TransportMode.rawValue；读取统一走 `mode` 计算属性做未知值兜底。
    var modeRaw: String = TransportMode.flight.rawValue

    // 承运方 / 班次
    var carrier: String = ""        // 航司 / 铁路（"China Eastern" / "中国铁路"）
    var number: String = ""         // 航班号 / 车次（"MU5801" / "G403"）

    // 出发端
    var fromName: String = ""       // 站点名（"昆明长水国际机场" / "昆明南站"）
    var fromCode: String = ""       // IATA / 车站代码（"KMG"），可空
    var fromLatitude: Double = 0
    var fromLongitude: Double = 0
    var fromTimeZoneId: String = "" // IANA tz（"Asia/Shanghai"），跨时区正确显示用；可空
    var fromTerminal: String = ""

    // 到达端
    var toName: String = ""
    var toCode: String = ""
    var toLatitude: Double = 0
    var toLongitude: Double = 0
    var toTimeZoneId: String = ""
    var toTerminal: String = ""

    // 时间（按各自当地时间存；跨天用 dayOrder 偏移，呼应 ItineraryStop.plannedStartMinutes 范式）
    var departDayOrder: Int = 0     // 出发落在第几天（0-based，对齐 ItineraryDay.sortOrder）
    var departLocalMinutes: Int = -1// 出发当地时间（自午夜分钟数，-1 = 未设）
    var arriveDayOrder: Int = 0     // 到达落在第几天（可 > departDayOrder：红眼/跨天）
    var arriveLocalMinutes: Int = -1

    // 选填实用信息
    var seat: String = ""
    var confirmationCode: String = ""
    var note: String = ""

    /// 时间轴排序（与同日 stop 共享整数空间）。
    var sortOrder: Int = 0
    var day: ItineraryDay?

    /// 未来航班动态预留（本轮不接 API，留空）：JSON 编码的延误/登机口/转盘/实际起降。
    /// 可演进——接入时只填充本字段，不改表。
    var liveStatusData: Data = Data()

    init(
        mode: TransportMode = .flight,
        carrier: String = "",
        number: String = "",
        fromName: String = "",
        fromCode: String = "",
        fromLatitude: Double = 0,
        fromLongitude: Double = 0,
        fromTimeZoneId: String = "",
        fromTerminal: String = "",
        toName: String = "",
        toCode: String = "",
        toLatitude: Double = 0,
        toLongitude: Double = 0,
        toTimeZoneId: String = "",
        toTerminal: String = "",
        departDayOrder: Int = 0,
        departLocalMinutes: Int = -1,
        arriveDayOrder: Int = 0,
        arriveLocalMinutes: Int = -1,
        seat: String = "",
        confirmationCode: String = "",
        note: String = "",
        sortOrder: Int = 0
    ) {
        self.id = UUID()
        self.modeRaw = mode.rawValue
        self.carrier = carrier
        self.number = number
        self.fromName = fromName
        self.fromCode = fromCode
        self.fromLatitude = fromLatitude
        self.fromLongitude = fromLongitude
        self.fromTimeZoneId = fromTimeZoneId
        self.fromTerminal = fromTerminal
        self.toName = toName
        self.toCode = toCode
        self.toLatitude = toLatitude
        self.toLongitude = toLongitude
        self.toTimeZoneId = toTimeZoneId
        self.toTerminal = toTerminal
        self.departDayOrder = departDayOrder
        self.departLocalMinutes = departLocalMinutes
        self.arriveDayOrder = arriveDayOrder
        self.arriveLocalMinutes = arriveLocalMinutes
        self.seat = seat
        self.confirmationCode = confirmationCode
        self.note = note
        self.sortOrder = sortOrder
    }

    /// 未知 rawValue 兜底为 .other；写入回落 rawValue。
    var mode: TransportMode {
        get { TransportMode(rawValueOrOther: modeRaw) }
        set { modeRaw = newValue.rawValue }
    }

    var hasFromCoordinate: Bool { fromLatitude != 0 || fromLongitude != 0 }
    var hasToCoordinate: Bool { toLatitude != 0 || toLongitude != 0 }
    var fromCoordinate: CLLocationCoordinate2D? {
        guard hasFromCoordinate else { return nil }
        return CLLocationCoordinate2D(latitude: fromLatitude, longitude: fromLongitude)
    }
    var toCoordinate: CLLocationCoordinate2D? {
        guard hasToCoordinate else { return nil }
        return CLLocationCoordinate2D(latitude: toLatitude, longitude: toLongitude)
    }
    /// 两端都有坐标才能画弧线 / 计算航段。
    var hasRouteCoordinates: Bool { hasFromCoordinate && hasToCoordinate }
    /// 是否跨天（红眼航班等）。
    var crossesDays: Bool { arriveDayOrder > departDayOrder }
}

// MARK: - LodgingStay

/// 住宿（横跨若干晚的「跨度」）。归 TripBundle（不绑单天）；用 day sortOrder 锚定，
/// 兼容有日期 / 无日期行程（呼应 dateless-planning-trips.md）。spec: itinerary-transport-lodging.md。
@Model
final class LodgingStay {
    var id: UUID = UUID()
    var name: String = ""           // 酒店 / 民宿名
    var address: String = ""
    var latitude: Double = 0
    var longitude: Double = 0

    // 锚定：用 day sortOrder 表达「第几天 check-in，住几晚」
    var checkInDayOrder: Int = 0    // 0-based，对齐 ItineraryDay.sortOrder
    var nights: Int = 1             // 住几晚（check-out 日 = checkIn + nights）
    var checkInMinutes: Int = -1    // 入住时间（自午夜分钟数，可空）
    var checkOutMinutes: Int = -1   // 退房时间（可空）

    var confirmationCode: String = ""
    var note: String = ""
    var sortOrder: Int = 0
    var bundle: TripBundle?

    init(
        name: String = "",
        address: String = "",
        latitude: Double = 0,
        longitude: Double = 0,
        checkInDayOrder: Int = 0,
        nights: Int = 1,
        checkInMinutes: Int = -1,
        checkOutMinutes: Int = -1,
        confirmationCode: String = "",
        note: String = "",
        sortOrder: Int = 0
    ) {
        self.id = UUID()
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.checkInDayOrder = checkInDayOrder
        self.nights = max(1, nights)
        self.checkInMinutes = checkInMinutes
        self.checkOutMinutes = checkOutMinutes
        self.confirmationCode = confirmationCode
        self.note = note
        self.sortOrder = sortOrder
    }

    /// 退房落在第几天（= 入住日 + 住的晚数）。
    var checkOutDayOrder: Int { checkInDayOrder + max(1, nights) }

    var hasCoordinate: Bool { latitude != 0 || longitude != 0 }
    var coordinate: CLLocationCoordinate2D? {
        guard hasCoordinate else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// 是否覆盖某天（含入住日、不含退房日——退房日不在此处过夜）。
    func covers(dayOrder: Int) -> Bool {
        dayOrder >= checkInDayOrder && dayOrder < checkOutDayOrder
    }
}

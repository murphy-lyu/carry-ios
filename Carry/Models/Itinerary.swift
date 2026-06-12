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
    case sightseeing   // 景点
    case food          // 餐饮
    case lodging       // 住宿
    case transport     // 交通节点
    case activity      // 活动
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

import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// 出行日「下一程」Live Activity 的共享数据模型（spec: widget-transit-live-activity.md）。
/// 与打包 LA（`PackingActivityAttributes`）并列、互不干扰：不同 attributes 类型，ActivityKit 上可并存。
///
/// **schedule-based**：起降为计划时刻（绝对 `Date`，主 App 按段两端时区算好），锁屏/灵动岛用
/// `Text(timerInterval:)` 自走倒计时，本地 `pushType:nil` 即可、过程零 App 干预。
/// **实时数据就绪**：`liveStatus`/`gate`/`actualDepartureDate` 预留——将来接航班动态 API 时只
/// 填充并 `update`，**不改本结构**（呼应 `TransportSegment.liveStatusData` 预留字段）。
struct TransportActivityAttributes: ActivityAttributes {

    struct ContentState: Codable, Hashable {
        // ── 计划信息（schedule-based，必填）──
        var modeRaw: String        // TransportMode.rawValue → 图标 / 口吻
        var carrierAndNumber: String  // "MU5801" / "G403" / 自填名；可空
        var fromCode: String       // "KMG"（航班/火车）；无码交通回退 fromName
        var toCode: String
        var fromName: String
        var toName: String
        var departureDate: Date    // 绝对起飞/发车时刻（按 fromTimeZone 算）
        var arrivalDate: Date      // 绝对到达时刻（按 toTimeZone 算）
        var fromTerminal: String   // 可空
        var seat: String           // 可空

        // ── 租车专属（取车 / 还车段区分）──
        /// 租车还车段标记。true = 还车 LA（显示还车地）；false/缺省 = 取车 LA（显示取车地）。
        /// 仅 modeRaw == "carRental" 时有意义，其他交通类型忽略此字段。
        var isCarRentalDropoff: Bool = false

        // ── 实时预留（本轮恒为 nil，接 API 时填充，不改结构）──
        var liveStatus: String?    // "On Time" / "Delayed 20m" / "Boarding" …
        var gate: String?
        var actualDepartureDate: Date?

        /// 两端展示用标签：有 IATA/车站码用码，否则用站名。
        var fromLabel: String { fromCode.isEmpty ? fromName : fromCode }
        var toLabel: String { toCode.isEmpty ? toName : toCode }
    }

    var tripId: UUID
    var segmentId: UUID
}
#endif

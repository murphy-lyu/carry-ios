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

    /// 「添加地点」类别选择器可选项：在地体验 + 住宿 + 兜底。
    /// **剔除 flight / train / carRental / cruise** —— 它们是「边」（交通段），应走统一「+」的交通入口
    /// （`TransportSegment` / `TransportEditView`），不在「搜一个坐标点」的地点流程里建。
    /// 枚举本身保留全部 case，仅此选择器收窄，旧数据（已加成普通 stop 的航班/租车/邮轮）仍正常解析渲染。
    /// spec: itinerary-car-rental.md。
    static let placeSelectableCases: [StopCategory] =
        [.sightseeing, .food, .activity, .shopping, .lodging, .other]
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
            // 默认落点：
            // - base 里有可比的「定时项」→ 末尾（晚于全部已知时间，沿用原行为）；
            // - base 全是无时间地点（Carry 常见：地点只是带距离的路线、不填钟点）→ 不再无脑置底，
            //   按航段出发时间相对正午定位：上午（< 12:00）领起这一天、置顶；午后/傍晚 → 收束、置底。
            //   修「早班机被一堆无时间地点压到最底」——航班是硬时间锚点，8:00 就该是当天第一件事。
            let noon = 12 * 60
            let baseHasTimedAnchor = base.contains { $0.effectiveMinutes >= 0 }
            var carry = -1
            var insertAt = baseHasTimedAnchor ? base.count : (t < noon ? 0 : base.count)
            // carry-forward：逐项求「有效时间」，未设时间者继承前一处时间；遇到第一个晚于本段的项即插其前。
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

// MARK: - CostBearing

/// 可记录费用的行程实体（地点 / 交通 / 住宿）。spec: itinerary-cost-tracking.md。
/// 真相 = 金额 + 原币种（用户实付，永不丢）；costHomeAmount = 录入时按当时汇率折算成
/// 本位币的快照，-1 = 未捕获 → Trip Book 退回实时折算兜底。
protocol CostBearing: AnyObject {
    var costAmount: Double { get set }
    var costCurrencyCode: String { get set }
    var costHomeAmount: Double { get set }
}

extension CostBearing {
    /// 是否记录了费用。以「币种非空」判定（而非金额 >0），允许记录「0 元 / 免费」这类真实条目。
    var hasCost: Bool { !costCurrencyCode.isEmpty }
}

// MARK: - ItineraryStop

/// 一个停靠点（POI）。坐标复用项目既有范式（同 DestinationEntry：lat/long）。
@Model
final class ItineraryStop: CostBearing {
    var id: UUID = UUID()
    var name: String = ""
    /// lat/long == 0/0 视为「无坐标停靠点」——地图/连线/重排都必须先过滤，绝不画到几内亚湾。
    var latitude: Double = 0
    var longitude: Double = 0
    /// 反向地理编码得到的可读地址（可选）。
    var address: String = ""
    /// StopCategory.rawValue；读取统一走 `category` 计算属性做未知值兜底。
    var categoryRaw: String = StopCategory.other.rawValue
    /// 联系电话（餐厅/景点等；地点搜索可自动回填，可手填）。
    var phone: String = ""
    /// 该地点的 IANA 时区（如 "Europe/Paris"；地点搜索时从 placemark 自动捕获，空 = 未知）。
    /// spec: itinerary-timezone.md。时间字段是「该时区的当地墙上分钟数」，绝对时刻由它推出。
    var timeZoneId: String = ""
    /// 当天计划时段起点（自午夜起的分钟数，-1 = 未设）。
    var plannedStartMinutes: Int = -1
    /// 预计停留时长（分钟，0 = 未设）。
    var stayMinutes: Int = 0
    var note: String = ""
    /// 当天内顺序。
    var sortOrder: Int = 0
    var day: ItineraryDay?

    // 费用记录（spec: itinerary-cost-tracking.md，见 CostBearing）。
    var costAmount: Double = 0
    var costCurrencyCode: String = ""
    var costHomeAmount: Double = -1

    /// 是否由照片回溯生成（spec: photo-trip-reconstruction.md）。用户手动编辑后仍保留该出身标记。
    var fromPhotos: Bool = false

    /// 挂在该停靠点上的照片（照片回溯生成时填充；手动停靠点为空）。
    @Relationship(deleteRule: .cascade, inverse: \StopPhoto.stop)
    var photos: [StopPhoto]? = []

    /// 附件（文件/照片/链接，spec: itinerary-attachments.md）；删地点级联删附件（文件由 Store 漏斗清沙盒）。
    @Relationship(deleteRule: .cascade, inverse: \ItineraryAttachment.stop)
    var attachments: [ItineraryAttachment]? = []

    init(
        name: String = "",
        latitude: Double = 0,
        longitude: Double = 0,
        address: String = "",
        category: StopCategory = .other,
        plannedStartMinutes: Int = -1,
        stayMinutes: Int = 0,
        note: String = "",
        phone: String = "",
        timeZoneId: String = "",
        sortOrder: Int = 0,
        costAmount: Double = 0,
        costCurrencyCode: String = "",
        costHomeAmount: Double = -1,
        fromPhotos: Bool = false
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
        self.phone = phone
        self.timeZoneId = timeZoneId
        self.sortOrder = sortOrder
        self.costAmount = costAmount
        self.costCurrencyCode = costCurrencyCode
        self.costHomeAmount = costHomeAmount
        self.fromPhotos = fromPhotos
    }

    /// 该停靠点照片按时间升序。
    var sortedPhotos: [StopPhoto] {
        (photos ?? []).sorted { $0.sortOrder < $1.sortOrder }
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

// MARK: - StopPhoto

/// 挂在停靠点上的一张照片（spec: photo-trip-reconstruction.md）。
/// 真相 = 相册引用 + EXIF 元数据；缩略图字节随库/备份走，原图永远回相册按
/// `assetLocalIdentifier` 取（App 不囤原图）。换机/原图被删时退化为「仅缩略图」。
@Model
final class StopPhoto {
    var id: UUID = UUID()
    /// PHAsset.localIdentifier，回相册取原图。
    var assetLocalIdentifier: String = ""
    /// 小缩略图 JPEG 字节（约 320pt，列表展示 + 随备份持久化）。
    var thumbnailData: Data = Data()
    /// EXIF 拍摄时间（PHAsset.creationDate）。
    var timestamp: Date = Date()
    /// 已归一坐标系（境内 GCJ-02 / 境外 WGS-84），与项目库内坐标一致。
    var latitude: Double = 0
    var longitude: Double = 0
    /// 地点内按时间排序。
    var sortOrder: Int = 0
    var stop: ItineraryStop?

    init(
        assetLocalIdentifier: String = "",
        thumbnailData: Data = Data(),
        timestamp: Date = Date(),
        latitude: Double = 0,
        longitude: Double = 0,
        sortOrder: Int = 0
    ) {
        self.id = UUID()
        self.assetLocalIdentifier = assetLocalIdentifier
        self.thumbnailData = thumbnailData
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.sortOrder = sortOrder
    }
}

// MARK: - ItineraryAttachment

/// 附件类型（spec: itinerary-attachments.md）。rawValue 存库；UI 按类型取图标/交互。
enum AttachmentKind: String, Codable, CaseIterable {
    case file, photo, link
}

/// 通用行程附件：挂在 地点 / 交通 / 住宿 三类实体上（三选一关系）。
/// 文件/照片原图字节存沙盒（`AttachmentStore`，model 只存 `fileName`）；照片另存小缩略图字节（列表/详情快渲）；
/// 链接只存 `urlString`。私有数据——绝不进任何分享/导出路径（见 spec「分享过滤」）。
@Model
final class ItineraryAttachment {
    var id: UUID = UUID()
    var kindRaw: String = AttachmentKind.file.rawValue
    /// 文件名 / 用户起的名 / 链接标题；空则 UI 回退（链接显 URL、文件显 fileName）。
    var displayName: String = ""
    /// 沙盒文件名（file/photo 用；link 为空）。
    var fileName: String = ""
    /// UTType 标识或扩展名（图标/预览用）。
    var utiOrExt: String = ""
    /// 链接 URL（link 用）。
    var urlString: String = ""
    /// 照片小缩略图字节（约 640px；file/link 为空，列表用 SF 图标）。
    var thumbnailData: Data = Data()
    var sortOrder: Int = 0
    var addedAt: Date = Date()

    // 归属三选一（仅一个非空），镜像 StopPhoto ↔ ItineraryStop。
    var stop: ItineraryStop?
    var segment: TransportSegment?
    var stay: LodgingStay?

    init(
        kind: AttachmentKind = .file,
        displayName: String = "",
        fileName: String = "",
        utiOrExt: String = "",
        urlString: String = "",
        thumbnailData: Data = Data(),
        sortOrder: Int = 0,
        addedAt: Date = Date()
    ) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.displayName = displayName
        self.fileName = fileName
        self.utiOrExt = utiOrExt
        self.urlString = urlString
        self.thumbnailData = thumbnailData
        self.sortOrder = sortOrder
        self.addedAt = addedAt
    }

    var kind: AttachmentKind { AttachmentKind(rawValue: kindRaw) ?? .file }
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

// MARK: - CabinClass（舱位等级 · 受控词表）

/// 航班舱位等级。存 `rawValue`（稳定 key），展示按语言本地化（避免自由文本中英混填）。
/// 纯手动——航班号查询返回的是航班时刻表、不含舱位（舱位是「这张票」的属性）。空 = 未填。
enum CabinClass: String, CaseIterable, Identifiable {
    case economy
    case premiumEconomy = "premium_economy"
    case business
    case first

    var id: String { rawValue }

    /// 本地化 key（String，不耦合 SwiftUI；view 侧包 LocalizedStringKey）。与 TransportMode 同范式。
    var localizationKey: String { "cabin.\(rawValue)" }
}

// MARK: - TransportSegment

/// 一段交通（时间轴上的「边」）：连接两点的移动，有出发地+到达地、起降时间、承运方/班次。
/// 不硬绑两个具体 stop 对象——更鲁棒（能处理「到达后还没排地点」「跨天航班」）；
/// 归出发日，与 stop 共享时间轴排序空间。spec: itinerary-transport-lodging.md。
@Model
final class TransportSegment: CostBearing {
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
    var fromAddress: String = ""    // 详细地址（地点搜索 placemark.title 回填）；机场搜索无、留空

    // 到达端
    var toName: String = ""
    var toCode: String = ""
    var toLatitude: Double = 0
    var toLongitude: Double = 0
    var toTimeZoneId: String = ""
    var toTerminal: String = ""
    var toAddress: String = ""

    // 时间（按各自当地时间存；跨天用 dayOrder 偏移，呼应 ItineraryStop.plannedStartMinutes 范式）
    var departDayOrder: Int = 0     // 出发落在第几天（0-based，对齐 ItineraryDay.sortOrder）
    var departLocalMinutes: Int = -1// 出发当地时间（自午夜分钟数，-1 = 未设）
    var arriveDayOrder: Int = 0     // 到达落在第几天（可 > departDayOrder：红眼/跨天）
    var arriveLocalMinutes: Int = -1

    // 选填实用信息
    var seat: String = ""
    var confirmationCode: String = ""
    /// 电子客票号（13 位数字，如 781-2345678901）：与 confirmationCode(预订定位码/PNR) 不同——前者标识「已出票客票」、
    /// 退改/报销/部分航司值机用。仅航班有意义、纯手填（航班查询不返回）。空 = 未填。
    var eticketNumber: String = ""
    /// 地面/水路交通选填（火车/巴士/渡轮，spec: itinerary-ground-transport-fields.md）；空 = 未填、各 mode 显隐见 UI。
    var routeName: String = ""     // 线路/车次名（如「京沪高铁」/ Eurostar）；火/巴/渡。
    var coachNumber: String = ""   // 车厢号（仅火车，如 08）。
    var seatClass: String = ""     // 席别/座位等级，自由文本（火/巴，如 First class）；航班用 cabinClass、渡轮不展示。
    var serviceType: String = ""   // 服务类型（火=Train type·Intercity、巴=Bus type、渡=Ferry type）；火/巴/渡。
    var note: String = ""
    /// 机型（如 "A320" / "Boeing 787 Dreamliner"）；航班号查询可自动回填，可空（spec: itinerary-flight-lookup.md）。
    var aircraftType: String = ""
    /// 舱位等级（`CabinClass.rawValue`，空 = 未填）；纯手动，航班查询不返回。仅航班有意义。
    var cabinClass: String = ""
    /// 航程（米）+ 飞行时长（分钟）——航班号查询时取自接口（greatCircleDistance / 起降时刻差），0 = 未知。
    var distanceMeters: Double = 0
    var durationMinutes: Int = 0

    /// 租车专属选填：车型（"Toyota Corolla" / "经济型 SUV"）+ 车牌；其它交通不展示，空 = 未填。
    var vehicleModel: String = ""
    var licensePlate: String = ""
    /// 联系电话（租车点；取车地点搜索可自动回填，可手填）；其它交通不展示。
    var phone: String = ""

    /// 时间轴排序（与同日 stop 共享整数空间）。
    var sortOrder: Int = 0
    var day: ItineraryDay?

    // 费用记录（spec: itinerary-cost-tracking.md，见 CostBearing）。
    var costAmount: Double = 0
    var costCurrencyCode: String = ""
    var costHomeAmount: Double = -1

    /// 未来航班动态预留（本轮不接 API，留空）：JSON 编码的延误/登机口/转盘/实际起降。
    /// 可演进——接入时只填充本字段，不改表。
    var liveStatusData: Data = Data()

    /// 是否静音此交通段的通知（spec: notification-center.md）。默认 false = 按全局规则提醒。
    var remindersMuted: Bool = false

    /// 附件（文件/照片/链接，spec: itinerary-attachments.md）；删交通段级联删附件。
    @Relationship(deleteRule: .cascade, inverse: \ItineraryAttachment.segment)
    var attachments: [ItineraryAttachment]? = []

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
        fromAddress: String = "",
        toName: String = "",
        toCode: String = "",
        toLatitude: Double = 0,
        toLongitude: Double = 0,
        toTimeZoneId: String = "",
        toTerminal: String = "",
        toAddress: String = "",
        departDayOrder: Int = 0,
        departLocalMinutes: Int = -1,
        arriveDayOrder: Int = 0,
        arriveLocalMinutes: Int = -1,
        seat: String = "",
        confirmationCode: String = "",
        eticketNumber: String = "",
        routeName: String = "",
        coachNumber: String = "",
        seatClass: String = "",
        serviceType: String = "",
        note: String = "",
        aircraftType: String = "",
        cabinClass: String = "",
        distanceMeters: Double = 0,
        durationMinutes: Int = 0,
        vehicleModel: String = "",
        licensePlate: String = "",
        phone: String = "",
        sortOrder: Int = 0,
        costAmount: Double = 0,
        costCurrencyCode: String = "",
        costHomeAmount: Double = -1
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
        self.fromAddress = fromAddress
        self.toName = toName
        self.toCode = toCode
        self.toLatitude = toLatitude
        self.toLongitude = toLongitude
        self.toTimeZoneId = toTimeZoneId
        self.toTerminal = toTerminal
        self.toAddress = toAddress
        self.departDayOrder = departDayOrder
        self.departLocalMinutes = departLocalMinutes
        self.arriveDayOrder = arriveDayOrder
        self.arriveLocalMinutes = arriveLocalMinutes
        self.seat = seat
        self.confirmationCode = confirmationCode
        self.eticketNumber = eticketNumber
        self.routeName = routeName
        self.coachNumber = coachNumber
        self.seatClass = seatClass
        self.serviceType = serviceType
        self.note = note
        self.aircraftType = aircraftType
        self.cabinClass = cabinClass
        self.distanceMeters = distanceMeters
        self.durationMinutes = durationMinutes
        self.vehicleModel = vehicleModel
        self.licensePlate = licensePlate
        self.phone = phone
        self.sortOrder = sortOrder
        self.costAmount = costAmount
        self.costCurrencyCode = costCurrencyCode
        self.costHomeAmount = costHomeAmount
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
final class LodgingStay: CostBearing {
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
    /// 联系电话（酒店；地址搜索可自动回填，可手填）。
    var phone: String = ""
    /// 酒店所在地的 IANA 时区（如 "Europe/Paris"；地址搜索时从 placemark 捕获，空 = 未知）。
    /// spec: itinerary-timezone.md。入住/退房时间都是「该时区的当地墙上分钟数」。
    var timeZoneId: String = ""
    /// 是否静音此住宿的通知（spec: notification-center.md）。默认 false。
    var remindersMuted: Bool = false
    var sortOrder: Int = 0
    var bundle: TripBundle?

    // 费用记录（spec: itinerary-cost-tracking.md，见 CostBearing）。
    var costAmount: Double = 0
    var costCurrencyCode: String = ""
    var costHomeAmount: Double = -1

    /// 附件（文件/照片/链接，spec: itinerary-attachments.md）；删住宿级联删附件。
    @Relationship(deleteRule: .cascade, inverse: \ItineraryAttachment.stay)
    var attachments: [ItineraryAttachment]? = []

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
        phone: String = "",
        timeZoneId: String = "",
        sortOrder: Int = 0,
        costAmount: Double = 0,
        costCurrencyCode: String = "",
        costHomeAmount: Double = -1
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
        self.phone = phone
        self.timeZoneId = timeZoneId
        self.sortOrder = sortOrder
        self.costAmount = costAmount
        self.costCurrencyCode = costCurrencyCode
        self.costHomeAmount = costHomeAmount
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

// MARK: - 行程时区辅助（spec: itinerary-timezone.md）
//
// 时间字段存「当地墙上分钟数」，时区存在各活动的 timeZoneId（地点搜索自动捕获）。
// 任何活动缺自身时区时回退到「行程主时区」，保证通知/绝对时刻永远有合理时区；
// 「是否多时区」决定 UI 是否显示时区提示。

extension TripBundle {
    /// 全行程有时间活动捕获到的 IANA 时区（非空），按出现顺序。
    var activityTimeZoneIds: [String] {
        var ids: [String] = []
        func add(_ id: String) { if !id.isEmpty { ids.append(id) } }
        for day in safeItineraryDays {
            for stop in (day.stops ?? []) { add(stop.timeZoneId) }
            for seg in day.sortedSegments { add(seg.fromTimeZoneId); add(seg.toTimeZoneId) }
        }
        for stay in safeLodgingStays { add(stay.timeZoneId) }
        return ids
    }

    /// 行程「主时区」：活动里出现最多的时区（并列取最早出现）；一个都没有 → 设备当前时区。
    var primaryTimeZoneId: String {
        let ids = activityTimeZoneIds
        guard !ids.isEmpty else { return TimeZone.current.identifier }
        var counts: [String: Int] = [:]
        var firstIndex: [String: Int] = [:]
        for (i, id) in ids.enumerated() {
            counts[id, default: 0] += 1
            if firstIndex[id] == nil { firstIndex[id] = i }
        }
        return counts.max { a, b in
            a.value != b.value ? a.value < b.value : (firstIndex[a.key] ?? 0) > (firstIndex[b.key] ?? 0)
        }!.key
    }

    /// 行程是否跨 ≥2 个时区——决定 UI 是否显示时区提示（spec D1/D2）。
    var isMultiTimeZone: Bool { Set(activityTimeZoneIds).count >= 2 }

    /// 每天用于「显示」的时区（`[dayOrder: tzId]`）——carry-forward：
    /// 有活动的天按当天所在地；**空白天继承「上一次落地后所在的时区」**（飞抵巴黎后的空白天显示巴黎时区，
    /// 而非回退出发地）。spec: itinerary-timezone.md D3。
    func displayTimeZoneIds() -> [Int: String] {
        var result: [Int: String] = [:]
        let sorted = safeItineraryDays.sorted(by: { $0.sortOrder < $1.sortOrder })
        // 种子用「最早出现的所在地时区」(≈ 出发地/首站)，而非主时区(最频繁≈目的地)：
        //   首站之前的纯空白天应显示出发地，而非行程里出现最多的目的地时区。无任何时区信号才退回主时区。
        var current = sorted.compactMap { $0.ownTimeZoneId }.first ?? primaryTimeZoneId
        for day in sorted {
            let own = day.ownTimeZoneId
            result[day.sortOrder] = own ?? current
            if let arr = day.endArrivalTimeZoneId { current = arr }   // 当天有交通落地 → 之后所在地顺延到到达区
            else if let own { current = own }                         // 否则以当天所在地更新
        }
        return result
    }
}

/// 时区归一化：中国大陆全国统一民用「北京时间」（GMT+8）。
/// MapKit / 按坐标查时区时，新疆/西藏等地理上属 UTC+6，可能给出 `Asia/Urumqi`、`Asia/Kashgar` 等——
/// 但当地航班/酒店/营业时间一律按北京时间，对旅行规划而言相关时区就是北京时间。故把这些大陆境内别名
/// 统一归到 `Asia/Shanghai`，避免纯国内行程（如重庆→伊宁）被误判为「跨时区」而显示无意义的时区标签。
/// 只动**中国大陆境内**别名；港澳（独立法域）与一切境外时区不受影响。
nonisolated enum TimeZoneCanonicalizer {
    private static let mainlandChinaAliases: Set<String> = [
        "Asia/Urumqi", "Asia/Kashgar", "Asia/Harbin", "Asia/Chongqing", "Asia/Chungking",
    ]
    /// 归一后的 IANA 时区 id；非大陆别名原样返回（空串也原样返回）。
    static func canonical(_ id: String) -> String {
        mainlandChinaAliases.contains(id) ? "Asia/Shanghai" : id
    }
}

extension ItineraryStop {
    /// 该地点的有效时区（自身缺失则回退行程主时区）。
    func effectiveTimeZoneId(trip: TripBundle?) -> String {
        if !timeZoneId.isEmpty { return timeZoneId }
        return trip?.primaryTimeZoneId ?? TimeZone.current.identifier
    }
}

extension LodgingStay {
    func effectiveTimeZoneId(trip: TripBundle?) -> String {
        if !timeZoneId.isEmpty { return timeZoneId }
        return trip?.primaryTimeZoneId ?? TimeZone.current.identifier
    }
}

extension TransportSegment {
    /// 出发绝对时刻（按出发地时区，缺失回退设备时区）；未设出发时间 → nil。
    /// 与 `NotificationManager.absoluteDate` 同算法：年月日按行程布局推、时分按目标时区落。
    func absoluteDeparture(tripDeparture: Date) -> Date? {
        Self.itineraryAbsoluteDate(tripDeparture: tripDeparture, dayOrder: departDayOrder,
                                   minutes: departLocalMinutes, tzId: fromTimeZoneId)
    }
    /// 到达绝对时刻（按到达地时区）；未设到达时间 → nil。
    func absoluteArrival(tripDeparture: Date) -> Date? {
        Self.itineraryAbsoluteDate(tripDeparture: tripDeparture, dayOrder: arriveDayOrder,
                                   minutes: arriveLocalMinutes, tzId: toTimeZoneId)
    }
    static func itineraryAbsoluteDate(tripDeparture: Date, dayOrder: Int, minutes: Int, tzId: String) -> Date? {
        guard minutes >= 0 else { return nil }
        let tz = TimeZone(identifier: tzId) ?? .current
        guard let dayDate = Calendar.current.date(byAdding: .day, value: dayOrder, to: tripDeparture) else { return nil }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: dayDate)
        comps.hour = minutes / 60
        comps.minute = minutes % 60
        comps.timeZone = tz
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        return cal.date(from: comps)
    }
}

extension ItineraryDay {
    /// 当天代表时区：首个有时区的地点 → 首个交通段出发时区 → 行程主时区。用于「每日提醒」定点。
    func representativeTimeZoneId(trip: TripBundle) -> String {
        if let z = sortedStops.compactMap({ $0.timeZoneId.isEmpty ? nil : $0.timeZoneId }).first { return z }
        if let z = sortedSegments.compactMap({ $0.fromTimeZoneId.isEmpty ? nil : $0.fromTimeZoneId }).first { return z }
        return trip.primaryTimeZoneId
    }

    /// 当天「所在地时区」：地点/住宿优先 → 否则交通段出发区；都没有则 nil（空白天）。
    var ownTimeZoneId: String? {
        if let z = sortedStops.compactMap({ $0.timeZoneId.isEmpty ? nil : $0.timeZoneId }).first { return z }
        if let z = sortedSegments.compactMap({ $0.fromTimeZoneId.isEmpty ? nil : $0.fromTimeZoneId }).first { return z }
        return nil
    }

    /// 当天最后一段交通的到达时区——用于把「所在地」顺延到之后的空白天（飞抵后即在目的地）；无则 nil。
    var endArrivalTimeZoneId: String? {
        sortedSegments.compactMap { $0.toTimeZoneId.isEmpty ? nil : $0.toTimeZoneId }.last
    }
}

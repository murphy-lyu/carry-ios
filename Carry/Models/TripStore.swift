//
//  TripStore.swift
//  Carry
//

import Foundation
import Combine
import SwiftData
import CoreLocation
import UserNotifications
#if canImport(WidgetKit)
import WidgetKit
#endif

// MARK: - DestinationEntry

/// A single resolved destination (countryCode + coordinates).
/// Used to store the 2nd, 3rd… cities of a multi-destination trip.
struct DestinationEntry: Codable {
    let countryCode: String
    let latitude: Double
    let longitude: Double
}

// MARK: - TripBundle

@Model
final class TripBundle {
    var id: UUID = UUID()
    var name: String = ""
    var destinationCity: String = ""
    var days: Int = 1
    var dateRange: String = ""
    var departureDate: Date = Date()
    /// 无日期「规划中」行程标记。为真时 departureDate/days 退化为无意义占位值，
    /// 所有日期相关功能（提醒/Live Activity/日历/天气/经期/到访/排序）必须先 guard !isDateless。
    var isDateless: Bool = false
    var createdAt: Date = Date()
    var selectedSceneKeys: [String] = []
    var dismissedSurpriseNames: [String] = []

    var sceneCardDismissed: Bool = false
    var remindersEnabled: Bool = true
    var reminderConfigData: Data = Data()
    var countryCode: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    /// JSON-encoded [DestinationEntry] for the 2nd+ cities in a multi-destination trip.
    var additionalDestinationsData: Data = Data()
    /// JSON-encoded [TripBackgroundEntry] — user-chosen background image(s).
    /// Single entry for now; the array is multi-destination-ready (see specs/trip-background-image.md).
    /// Adding this field is a lightweight SwiftData migration (default value) — no SchemaV2 needed.
    var backgroundsData: Data = Data()
    @Relationship(deleteRule: .cascade, inverse: \PackingSection.bundle) var sections: [PackingSection]? = []
    /// 行程路线规划（spec: itinerary-route-planning.md）。打包清单的并列「第二张脸」，
    /// 默认空 → 所有存量行程零数据风险。新增 model 属轻量迁移（加表），无需 SchemaV2。
    @Relationship(deleteRule: .cascade, inverse: \ItineraryDay.bundle) var itineraryDays: [ItineraryDay]? = []
    /// 住宿跨度（spec: itinerary-transport-lodging.md）。横跨若干晚、归 TripBundle（不绑单天）；
    /// 默认空 → 存量行程零数据风险。新增 model 属轻量迁移（加表），无需 SchemaV2。
    @Relationship(deleteRule: .cascade, inverse: \LodgingStay.bundle) var lodgingStays: [LodgingStay]? = []

    /// 行程跨越的「实际天数」= 含出发日与返程日两端的日历天数。用于**显示**（首页卡片、行程页）
    /// 与行程页「天」的生成。与 `days` 区分：`days` 是「晚数/时长」（= returnDate − departureDate，
    /// 打包数量与提醒沿用，不变）；实际天数含两端 = days + 1。无日期「规划中」行程固定 1 天。
    var spanDays: Int { isDateless ? 1 : max(1, days + 1) }

    var reminderConfigs: [TripReminderConfig] {
        get {
            guard !reminderConfigData.isEmpty else { return TripReminderConfig.defaults }
            do {
                return try JSONDecoder().decode([TripReminderConfig].self, from: reminderConfigData)
            } catch {
                // 解码失败：记录原始数据长度（不含内容），留追溯线索。
                // ⚠️ 注意：UI 此处会展示 defaults，但本 getter 不主动改写 reminderConfigData
                //（避免被静默覆盖原始数据）。下次 setter 写入新值时才会替换。
                CarryLogger.shared.log(.dataCorrupted,
                    context: "reminderConfigs decode failed, dataLen=\(reminderConfigData.count)")
                return TripReminderConfig.defaults
            }
        }
        set {
            reminderConfigData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    /// Decoded list of extra destinations (2nd city onward) for multi-destination trips.
    var additionalDestinations: [DestinationEntry] {
        get {
            guard !additionalDestinationsData.isEmpty else { return [] }
            do {
                return try JSONDecoder().decode([DestinationEntry].self, from: additionalDestinationsData)
            } catch {
                CarryLogger.shared.log(.destinationDecodeFailed,
                    context: "error=\(error.localizedDescription)")
                return []
            }
        }
        set {
            additionalDestinationsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    /// Decoded user-chosen background images. Single for now; array = multi-destination ready.
    var backgrounds: [TripBackgroundEntry] {
        get {
            guard !backgroundsData.isEmpty else { return [] }
            do {
                return try JSONDecoder().decode([TripBackgroundEntry].self, from: backgroundsData)
            } catch {
                CarryLogger.shared.log(.dataCorrupted,
                    context: "backgrounds decode failed, len=\(backgroundsData.count)")
                return []
            }
        }
        set {
            backgroundsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    /// The primary (first) background entry, if any.
    var primaryBackground: TripBackgroundEntry? { backgrounds.first }

    init(
        id: UUID = UUID(),
        name: String = "",
        destinationCity: String = "",
        days: Int = 1,
        dateRange: String = "",
        departureDate: Date = Date(),
        isDateless: Bool = false,
        createdAt: Date = Date(),
        selectedSceneKeys: [String] = [],
        sections: [PackingSection] = []
    ) {
        self.id = id
        self.name = name
        self.destinationCity = destinationCity
        self.days = days
        self.dateRange = dateRange
        self.departureDate = departureDate
        self.isDateless = isDateless
        self.createdAt = createdAt
        self.selectedSceneKeys = selectedSceneKeys
        self.sections = sections
    }

    /// `true` = at least one destination is outside China, `false` = all destinations are China, `nil` = unknown (geocoding pending or no destination set).
    var isInternational: Bool? {
        // 基准 = 用户本国（storefront 推导，大陆→CN，零回归）；所有目的地都在本国 = 国内。
        let home = homeCountryCode
        let allCodes = ([countryCode] + additionalDestinations.map(\.countryCode))
            .filter { !$0.isEmpty }
            .map { $0.uppercased() }
        guard !allCodes.isEmpty else { return nil }
        return allCodes.contains(where: { $0 != home })
    }

    var safeSections: [PackingSection] { (sections ?? []).sorted { $0.sortOrder < $1.sortOrder } }
    /// 行程规划：按 sortOrder 升序的天。
    var safeItineraryDays: [ItineraryDay] { (itineraryDays ?? []).sorted { $0.sortOrder < $1.sortOrder } }
    /// 住宿跨度：按 sortOrder 升序（同序按入住日）。
    var safeLodgingStays: [LodgingStay] {
        (lodgingStays ?? []).sorted {
            $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.checkInDayOrder < $1.checkInDayOrder
        }
    }
    var packedCount: Int { safeSections.flatMap { $0.items ?? [] }.filter { $0.isPacked && !$0.name.isEmpty }.count }
    var totalCount:  Int { safeSections.flatMap { $0.items ?? [] }.filter { !$0.name.isEmpty }.count }

    /// 行程是否已计入"到访"——用于地图点亮（国家/城市）与首页 Trip Overview 的到访国家数。
    /// 规则：出发日期的**次日**起才算到访，出发当天及之前都不计入。
    /// `departureDate` 存的是出发当天 00:00（见 TripInfo），裸 `departureDate <= Date()`
    /// 会让"今天出发但尚未启程"的行程一过零点就被点亮，故改为按天比较且要求已过出发日。
    var countsAsVisited: Bool {
        // 无日期「规划中」行程永远不算到访——其 departureDate 是无意义占位值，
        // 不加此守卫会导致占位日期过期后误判为已到访（污染地图点亮 + 到访国家数）。
        guard !isDateless else { return false }
        let calendar = Calendar.current
        return calendar.startOfDay(for: Date()) > calendar.startOfDay(for: departureDate)
    }

    /// Locale-aware date range, computed at display time so it follows the current app language.
    var localizedDateRange: String {
        let returnDate = Calendar.current.date(byAdding: .day, value: days, to: departureDate) ?? departureDate
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("MMMd")
        return "\(fmt.string(from: departureDate)) – \(fmt.string(from: returnDate))"
    }
}

// MARK: - TripStore

final class TripStore: ObservableObject {
    @Published var trips: [TripBundle] = []
    @Published var myItems: [MyItem] = []
    @Published var isSceneCardDismissedGlobally: Bool
    @Published var isHomeEmptyStateMockEnabled: Bool
    @Published private(set) var draftTrip: TripBundle?

    private let context: ModelContext
    private let defaults = UserDefaults.standard
    private static let sceneCardDismissedGlobalKey = "scene_card_dismissed_global"
    private static let homeEmptyStateMockKey = "home_empty_state_mock_enabled"
    private var didCleanupCorruptedData = false

    init() {
        self.context = ModelContext(CarryApp.container)
        self.isSceneCardDismissedGlobally = defaults.bool(forKey: Self.sceneCardDismissedGlobalKey)
        // 「模拟首页空态」是 DEBUG 预览开关，**仅本次会话有效、不跨启动持久化**——每次启动重置为关。
        // 否则误开后值会存进 UserDefaults，每次启动都模拟空态（看着像白屏），而 Xcode 重装不清
        // UserDefaults → 重装也不好（已踩坑）。预览是一次性操作，本就不该跨启动留存。
        self.isHomeEmptyStateMockEnabled = false
        defaults.removeObject(forKey: Self.homeEmptyStateMockKey)
        Task { @MainActor in
            fetchTrips()
            reconcileBackgroundFiles()
        }
    }

    /// Reclaims background-image files no longer referenced by any trip. The inline delete in
    /// `removeTrip` handles the common path promptly; this is the lifecycle backstop that also
    /// covers full-wipe restores (where trips are deleted without going through `removeTrip`).
    /// Runs on launch and after each restore/merge — robust to every trip-removal path.
    private func reconcileBackgroundFiles() {
        let referenced = Set(trips.flatMap { $0.backgrounds.compactMap(\.localFileName) })
        BackgroundImageStore.deleteOrphans(keeping: referenced)
    }

    func setHomeEmptyStateMockEnabled(_ enabled: Bool) {
        isHomeEmptyStateMockEnabled = enabled
        defaults.set(enabled, forKey: Self.homeEmptyStateMockKey)
    }

    // MARK: - Persistence

    func refresh() { fetchTrips() }

    // MARK: - Backup & Restore

    /// Restore all data from the automatic device-local JSON backup.
    @discardableResult
    func restoreFromBackup() throws -> (trips: Int, myItems: Int) {
        let result = try DataBackupManager.shared.restore(into: context)
        applyPostRestoreSideEffects()
        return result
    }

    /// Restore all data from raw JSON data read from a user-selected file.
    @discardableResult
    func restoreFromData(_ data: Data) throws -> (trips: Int, myItems: Int) {
        let result = try DataBackupManager.shared.restoreFromData(data, into: context)
        applyPostRestoreSideEffects()
        return result
    }

    /// 合并导入：将备份中在本地不存在的行程 / 物品模板插入，不影响现有数据。
    @discardableResult
    func mergeFromData(_ data: Data) throws -> (trips: Int, myItems: Int) {
        let existingIds = Set(trips.map(\.id))   // 记录 merge 前的 trip ID，用于识别新增的
        let result = try DataBackupManager.shared.mergeFromData(data, into: context)
        applyPostMergeSideEffects(previousTripIds: existingIds)
        return result
    }

    /// 还原后清理副作用：旧 trip 的 pending 通知 / Live Activity 必须全清，否则会出现
    /// "通知 ID 指向已不存在的 trip" 或"灵动岛挂着旧行程"等幽灵。然后按新还原的 trip
    /// 重排所有提醒，并触发 widget snapshot 重写。
    private func applyPostRestoreSideEffects() {
        // 1. 全清旧通知
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        // 2. 全结束旧 Live Activity（含可能孤立的）
#if !targetEnvironment(macCatalyst)
        Task { @MainActor in LiveActivityManager.shared.endAll() }
#endif
        // 3. 刷 trips（也会刷自动备份）
        fetchTrips()
        // 4. 按新数据重排提醒
        for trip in trips where trip.remindersEnabled && !trip.isDateless {
            NotificationManager.scheduleReminders(for: trip)
        }
        // 5. 写一份新 widget snapshot
        writeWidgetSnapshot()
        // 6. 回收旧数据残留的孤儿背景图（整库 wipe 不走 removeTrip，靠这里兜底）
        reconcileBackgroundFiles()
    }

    /// 合并后清理副作用：与 restore 不同，**不能清旧通知 / 不能 endAll LA**——
    /// 本地原有行程仍然存在，那些通知和 Live Activity 是用户当前正在用的。
    /// 只需：① 刷 trips → ② 给"本次新合并进来"的 trip 排提醒 → ③ 刷 widget snapshot。
    private func applyPostMergeSideEffects(previousTripIds: Set<UUID>) {
        fetchTrips()
        // 只给"merge 后新出现"的 trip 排提醒；原有 trip 的提醒保持不动。
        for trip in trips where !previousTripIds.contains(trip.id)
                              && trip.remindersEnabled
                              && !trip.isDateless {
            NotificationManager.scheduleReminders(for: trip)
        }
        writeWidgetSnapshot()
        reconcileBackgroundFiles()
    }

    func setDraftTrip(_ trip: TripBundle?) {
        draftTrip = trip
    }

    func commitDraftTrip() {
        guard let trip = draftTrip else { return }
        trip.createdAt = Date()
        context.insert(trip)
        do {
            try context.save()
        } catch {
            CarryLogger.shared.log(.tripSaveFailed)
        }
        draftTrip = nil
        fetchTrips()
        NotificationManager.scheduleReminders(for: trip)
        if defaults.bool(forKey: "calendar_sync_enabled") {
            Task { CalendarManager.shared.addTrip(trip) }
        }
        CarryLogger.shared.log(.tripCreated)
    }

    private func fetchTrips() {
        let descriptor = FetchDescriptor<TripBundle>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let myItemDescriptor = FetchDescriptor<MyItem>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward), SortDescriptor(\.createdAt, order: .forward)]
        )
        do {
            var fetchedTrips = try context.fetch(descriptor)
            var fetchedMyItems = try context.fetch(myItemDescriptor)

            if !didCleanupCorruptedData && cleanupCorruptedData(trips: fetchedTrips, myItems: fetchedMyItems) {
                didCleanupCorruptedData = true
                try context.save()
                fetchedTrips = try context.fetch(descriptor)
                fetchedMyItems = try context.fetch(myItemDescriptor)
            }

            trips = fetchedTrips
            myItems = fetchedMyItems
            // Keep the JSON backup in sync after every data load.
            // Encoding a few trips worth of JSON is sub-millisecond, so doing it
            // inline here is safe and ensures the backup is always up-to-date.
            DataBackupManager.shared.backup(trips: fetchedTrips, myItems: fetchedMyItems)
            for trip in trips {
                if trip.sections == nil {
                    CarryLogger.shared.log(.dataCorrupted, context: "context=fetchTrips_nil_sections")
                } else if trip.sections?.isEmpty == true {
                    CarryLogger.shared.log(.orphanTrip)
                } else {
                    for section in trip.safeSections where (section.items ?? []).isEmpty {
                        CarryLogger.shared.log(.orphanSection)
                    }
                }
            }
        } catch {
            CarryLogger.shared.log(.loadFailed, context: "context=fetchTrips")
            trips = []
            myItems = []
        }
    }

    private func cleanupCorruptedData(trips: [TripBundle], myItems: [MyItem]) -> Bool {
        var didDelete = false

        for item in myItems where item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context.delete(item)
            didDelete = true
        }

        for trip in trips {
            for section in trip.safeSections {
                let invalidItems = (section.items ?? []).filter {
                    $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                if !invalidItems.isEmpty {
                    invalidItems.forEach { context.delete($0) }
                    didDelete = true
                }

                let remainingItems = (section.items ?? []).filter {
                    !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                if remainingItems.isEmpty {
                    context.delete(section)
                    didDelete = true
                }
            }
        }

        return didDelete
    }

    private func save(_ caller: String = #function) {
        do {
            try context.save()
        } catch {
            CarryLogger.shared.log(.persistFailed, context: "caller=\(caller)")
        }
        fetchTrips()
    }

    // MARK: - Trip background image (specs/trip-background-image.md)

    /// Sets a local background image (already saved to the sandbox via BackgroundImageStore).
    /// The caller saves the image and passes the stored filename; we delete any prior file.
    func setLocalBackground(fileName: String, crop: BackgroundCrop? = nil, forTripId id: UUID) {
        guard let trip = trips.first(where: { $0.id == id }) else { return }
        if let old = trip.primaryBackground?.localFileName, old != fileName {
            BackgroundImageStore.delete(named: old)
        }
        trip.backgrounds = [TripBackgroundEntry(source: .local, localFileName: fileName, destinationIndex: 0, crop: crop)]
        save()
    }

    /// Removes the custom background → card falls back to the style's default (monogram/map).
    func clearBackground(forTripId id: UUID) {
        guard let trip = trips.first(where: { $0.id == id }) else { return }
        if let old = trip.primaryBackground?.localFileName {
            BackgroundImageStore.delete(named: old)
        }
        trip.backgrounds = []
        save()
    }

    private let defaultMyItemCollection = "Default"

    private func normalizedCollectionName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultMyItemCollection : trimmed
    }

    // MARK: - Dev Tools

    /// Wipes all SwiftData records, UserDefaults, and pending notifications —
    /// equivalent to a fresh install. Call only from developer mode.
    func resetAllData() {
        do {
            try context.delete(model: TripBundle.self)
            try context.delete(model: MyItem.self)
            try context.save()
        } catch {
            CarryLogger.shared.log(.persistFailed, context: "resetAllData")
        }
        if let bundleId = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundleId)
        }
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
#if !targetEnvironment(macCatalyst)
        // 结束所有 Live Activity，避免重置后灵动岛挂着已不存在的行程
        Task { @MainActor in LiveActivityManager.shared.endAll() }
#endif
        trips = []
        myItems = []
        draftTrip = nil
        isSceneCardDismissedGlobally = false
        isHomeEmptyStateMockEnabled = false
    }

    // MARK: - Mutations

    func addTrip(_ bundle: TripBundle) {
        context.insert(bundle)
        do {
            try context.save()
        } catch {
            CarryLogger.shared.log(.tripSaveFailed)
        }
        fetchTrips()
        NotificationManager.scheduleReminders(for: bundle)
        CarryLogger.shared.log(.tripCreated)
    }

    func removeTrip(withId id: UUID) {
        guard let trip = trips.first(where: { $0.id == id }) else { return }
        NotificationManager.cancelReminders(forTripId: id)
#if !targetEnvironment(macCatalyst)
        Task { @MainActor in LiveActivityManager.shared.end(for: id) }
#endif
        // 同步清理日历事件，避免"删行程但日历残留"幽灵
        if UserDefaults.standard.bool(forKey: "calendar_sync_enabled") {
            Task { CalendarManager.shared.removeTrip(id) }
        }
        // 清理沙盒里的背景图字节，避免"删行程但图片残留"的孤儿文件（文件名是 UUID，
        // 各 trip 独立不共享，删除安全）。setLocalBackground/clearBackground 已对应处理。
        for name in trip.backgrounds.compactMap(\.localFileName) {
            BackgroundImageStore.delete(named: name)
        }
        context.delete(trip)
        save()
        CarryLogger.shared.log(.tripDeleted)
    }

    @discardableResult
    func duplicateTrip(withId id: UUID) -> UUID? {
        guard let originalIndex = trips.firstIndex(where: { $0.id == id }) else {
            CarryLogger.shared.log(.duplicateFailed, context: "context=trip_not_found")
            return nil
        }
        let original = trips[originalIndex]
        let copySuffix = NSLocalizedString("trip.copy_suffix", comment: "")
        let newSections = original.safeSections.map { section -> PackingSection in
            let items = section.sortedItems
                .filter { !$0.name.isEmpty }
                .enumerated()
                .map { idx, item in
                    PackingItem(name: item.name, quantity: item.quantity, isPacked: false, isAlert: item.isAlert, sortOrder: idx)
                }
            return PackingSection(title: section.title, items: items, sortOrder: section.sortOrder)
        }
        let newBundle = TripBundle(
            name: original.name + copySuffix,
            destinationCity: original.destinationCity,
            days: original.days,
            dateRange: original.dateRange,
            departureDate: original.departureDate,
            isDateless: original.isDateless,
            createdAt: Date(),
            selectedSceneKeys: original.selectedSceneKeys,
            sections: newSections
        )
        // 背景图深拷贝：每个条目的文件复制成独立新文件，副本拥有自己的字节（不与原行程共享
        // 文件名，否则删/换任一方都会误伤另一方）。无本地文件的条目（未来在线源）原样带过；
        // 复制失败的条目直接丢弃（副本退回 monogram 兜底），绝不残留共享引用。crop 等元数据保留。
        newBundle.backgrounds = original.backgrounds.compactMap { entry in
            guard let name = entry.localFileName else { return entry }
            guard let copiedName = BackgroundImageStore.copy(of: name) else { return nil }
            var copied = entry
            copied.localFileName = copiedName
            return copied
        }
        // 行程规划深拷贝：每天及其停靠点都建新实例（新 UUID），否则副本会与原行程
        // 共享/丢失规划数据。坐标全在 SwiftData 内，无沙盒外关联文件，直接复制字段即可。
        newBundle.itineraryDays = original.safeItineraryDays.map { day in
            let copiedStops = day.sortedStops.map { stop in
                ItineraryStop(
                    name: stop.name,
                    latitude: stop.latitude,
                    longitude: stop.longitude,
                    address: stop.address,
                    category: stop.category,
                    plannedStartMinutes: stop.plannedStartMinutes,
                    stayMinutes: stop.stayMinutes,
                    note: stop.note,
                    sortOrder: stop.sortOrder,
                    costAmount: stop.costAmount,
                    costCurrencyCode: stop.costCurrencyCode,
                    costHomeAmount: stop.costHomeAmount
                )
            }
            let copiedDay = ItineraryDay(sortOrder: day.sortOrder, title: day.title, note: day.note, stops: copiedStops)
            // 交通段深拷贝（新 UUID）；坐标/时间全在 SwiftData 内，直接复制字段。
            copiedDay.segments = day.sortedSegments.map { seg in
                TransportSegment(
                    mode: seg.mode,
                    carrier: seg.carrier, number: seg.number,
                    fromName: seg.fromName, fromCode: seg.fromCode,
                    fromLatitude: seg.fromLatitude, fromLongitude: seg.fromLongitude,
                    fromTimeZoneId: seg.fromTimeZoneId, fromTerminal: seg.fromTerminal,
                    toName: seg.toName, toCode: seg.toCode,
                    toLatitude: seg.toLatitude, toLongitude: seg.toLongitude,
                    toTimeZoneId: seg.toTimeZoneId, toTerminal: seg.toTerminal,
                    departDayOrder: seg.departDayOrder, departLocalMinutes: seg.departLocalMinutes,
                    arriveDayOrder: seg.arriveDayOrder, arriveLocalMinutes: seg.arriveLocalMinutes,
                    seat: seg.seat, confirmationCode: seg.confirmationCode,
                    note: seg.note, sortOrder: seg.sortOrder,
                    costAmount: seg.costAmount, costCurrencyCode: seg.costCurrencyCode,
                    costHomeAmount: seg.costHomeAmount
                )
            }
            return copiedDay
        }
        // 住宿跨度深拷贝（新 UUID），归副本 bundle。
        newBundle.lodgingStays = original.safeLodgingStays.map { stay in
            LodgingStay(
                name: stay.name, address: stay.address,
                latitude: stay.latitude, longitude: stay.longitude,
                checkInDayOrder: stay.checkInDayOrder, nights: stay.nights,
                checkInMinutes: stay.checkInMinutes, checkOutMinutes: stay.checkOutMinutes,
                confirmationCode: stay.confirmationCode, note: stay.note,
                sortOrder: stay.sortOrder,
                costAmount: stay.costAmount, costCurrencyCode: stay.costCurrencyCode,
                costHomeAmount: stay.costHomeAmount
            )
        }
        context.insert(newBundle)
        // Insert in-memory first to avoid full-list refetch jumpiness in UI.
        let insertIndex = min(originalIndex + 1, trips.count)
        trips.insert(newBundle, at: insertIndex)
        // ⚠️ save 必须同步：原 DispatchQueue.main.async 异步保存 + 紧随的同步
        // scheduleReminders/calendar addTrip 会产生"DB 里没这行程但通知/日历有"的幽灵
        // （save 失败时副作用已经执行）。改为同步 save，失败时回滚 in-memory 插入并跳过副作用。
        do {
            try context.save()
        } catch {
            CarryLogger.shared.log(.duplicateFailed, context: "context=save_failed")
            trips.remove(at: insertIndex)  // 回滚 in-memory 插入
            context.delete(newBundle)
            return nil
        }
        // 副作用链对齐 commitDraftTrip：排提醒 + 写日历事件（若开启同步）。
        // Live Activity 不在此激活：复制后行程默认未打开，进入清单页时 startIfNeeded 会判定。
        NotificationManager.scheduleReminders(for: newBundle)
        if UserDefaults.standard.bool(forKey: "calendar_sync_enabled") {
            Task { CalendarManager.shared.addTrip(newBundle) }
        }
        CarryLogger.shared.log(.tripDuplicated)
        return newBundle.id
    }

    func updateTripInfo(tripId: UUID, info: TripInfo) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        let cityChanged = trip.destinationCity != info.destinationCity
        trip.name = info.name
        trip.destinationCity = info.destinationCity
        trip.isDateless = info.isDateless
        // 无日期「规划中」行程：days/dateRange 退化为无意义占位值（不会被展示/计算读取）。
        trip.departureDate = info.departureDate
        trip.days = info.isDateless ? 1 : info.durationDays
        trip.dateRange = info.isDateless ? "" : info.dateRangeDisplay
        if cityChanged {
            // Clear stale coordinates immediately so the map doesn't show the old location
            trip.countryCode = ""
            trip.latitude = 0
            trip.longitude = 0
            trip.additionalDestinations = []
        }
        do {
            try context.save()
        } catch {
            CarryLogger.shared.log(.tripEditSaveFailed)
        }
        // 天数随行程日期/天数变化自动对齐（编辑日期 = 天数变化的主路径）。
        syncItineraryDays(tripId: tripId)
        fetchTrips()
        // scheduleReminders 内部已 guard isDateless：退回规划中时自动取消提醒，转正时重新排期。
        if trip.remindersEnabled {
            NotificationManager.scheduleReminders(for: trip)
        }
        if cityChanged && !info.destinationCity.isEmpty {
            updateCountryCode(for: tripId, city: info.destinationCity)
        }
        // 同步更新日历事件：退回规划中（无日期）→ 删除；否则按当前数据重写。
        if UserDefaults.standard.bool(forKey: "calendar_sync_enabled") {
            if info.isDateless {
                Task { CalendarManager.shared.removeTrip(tripId) }
            } else {
                Task { CalendarManager.shared.updateTrip(trip) }
            }
        }
#if !targetEnvironment(macCatalyst)
        Task { @MainActor in
            // 退回规划中：结束 Live Activity；其余情况正常更新。
            if info.isDateless {
                LiveActivityManager.shared.end(for: tripId)
            } else {
                LiveActivityManager.shared.update(for: trip)
            }
        }
#endif
    }

    func setRemindersEnabled(_ enabled: Bool, tripId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        trip.remindersEnabled = enabled
        save()
        if enabled {
            NotificationManager.scheduleReminders(for: trip)
        } else {
            NotificationManager.cancelReminders(forTripId: tripId)
        }
    }

    func addReminder(_ config: TripReminderConfig, tripId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        var configs = trip.reminderConfigs
        guard !configs.contains(where: { $0.isSameTrigger(as: config) }) else { return }
        configs.append(config)
        trip.reminderConfigs = configs
        save()
        NotificationManager.scheduleReminder(for: trip, config: config)
    }

    func removeReminder(configId: UUID, tripId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        var configs = trip.reminderConfigs
        configs.removeAll { $0.id == configId }
        trip.reminderConfigs = configs
        save()
        NotificationManager.cancelReminder(tripId: tripId, configId: configId)
    }

    func updateReminderTime(configId: UUID, hour: Int, minute: Int, tripId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        var configs = trip.reminderConfigs
        guard let index = configs.firstIndex(where: { $0.id == configId }) else { return }
        NotificationManager.cancelReminder(tripId: tripId, configId: configId)
        configs[index].hour = hour
        configs[index].minute = minute
        trip.reminderConfigs = configs
        save()
        // 只在行程总开关开 + 非 dateless 时重排：否则会挂上本不该存在的通知
        // （如总开关已 OFF 或行程已退回规划中时改某档时间）。
        if trip.remindersEnabled && !trip.isDateless {
            NotificationManager.scheduleReminder(for: trip, config: configs[index])
        }
    }

    func toggleItem(tripId: UUID, itemId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        for section in trip.safeSections {
            if let item = (section.items ?? []).first(where: { $0.id == itemId }) {
                item.isPacked.toggle()
                CarryLogger.shared.log(item.isPacked ? .itemChecked : .itemUnchecked)
                save()
#if !targetEnvironment(macCatalyst)
                Task { @MainActor in LiveActivityManager.shared.update(for: trip) }
#endif
                return
            }
        }
    }

    func markTripCompleted(tripId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        for section in trip.safeSections {
            for item in section.items ?? [] {
                item.isPacked = true
            }
        }
        save()
        CarryLogger.shared.log(.tripCompleted)
#if !targetEnvironment(macCatalyst)
        Task { @MainActor in LiveActivityManager.shared.update(for: trip) }
#endif
    }

    func markTripUncompleted(tripId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        for section in trip.safeSections {
            for item in section.items ?? [] {
                item.isPacked = false
            }
        }
        save()
        CarryLogger.shared.log(.tripUncompleted)
#if !targetEnvironment(macCatalyst)
        Task { @MainActor in LiveActivityManager.shared.update(for: trip) }
#endif
    }

    @discardableResult
    func addItem(tripId: UUID, sectionIndex: Int) -> UUID {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return UUID() }
        let sections = trip.safeSections
        guard sections.indices.contains(sectionIndex) else { return UUID() }
        let section = sections[sectionIndex]
        let existing = section.items ?? []
        let nextOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
        let newItem = PackingItem(name: "", isAlert: false, sortOrder: nextOrder)
        context.insert(newItem)
        if section.items == nil { section.items = [] }
        section.items?.append(newItem)
        fetchTrips()  // refresh UI without persisting the empty item to disk
        return newItem.id
    }

    func updateItemName(tripId: UUID, itemId: UUID, name: String) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        for section in trip.safeSections {
            if let item = (section.items ?? []).first(where: { $0.id == itemId }) {
                let wasNew = item.name.isEmpty
                item.name = name
                do {
                    try context.save()
                } catch {
                    CarryLogger.shared.log(wasNew ? .itemAddFailed : .persistFailed,
                                           context: "context=updateItemName")
                }
                fetchTrips()
                if wasNew && !name.isEmpty {
                    CarryLogger.shared.log(.itemAdded)
#if !targetEnvironment(macCatalyst)
                    Task { @MainActor in LiveActivityManager.shared.update(for: trip) }
#endif
                }
                return
            }
        }
    }

    func updateItemQuantity(tripId: UUID, itemId: UUID, quantity: Int) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        let clamped = min(9_999, max(1, quantity))
        for section in trip.safeSections {
            if let item = (section.items ?? []).first(where: { $0.id == itemId }) {
                guard item.quantity != clamped else { return }
                item.quantity = clamped
                save()
                return
            }
        }
    }

    func removeItem(tripId: UUID, itemId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        for section in trip.safeSections {
            if let item = (section.items ?? []).first(where: { $0.id == itemId }) {
                let wasNamed = !item.name.isEmpty
                context.delete(item)
                section.items?.removeAll { $0.id == itemId }
                do {
                    try context.save()
                } catch {
                    CarryLogger.shared.log(.itemDeleteFailed, context: "context=removeItem")
                }
                fetchTrips()
                if wasNamed {
                    CarryLogger.shared.log(.itemDeleted)
#if !targetEnvironment(macCatalyst)
                    Task { @MainActor in LiveActivityManager.shared.update(for: trip) }
#endif
                }
                return
            }
        }
    }

    /// Reorders items within a section. `newOrder` is an array of item IDs in
    /// the desired final order. Items not in `newOrder` are left untouched at
    /// the end. Sort orders are rewritten as 0, 1, 2, … so subsequent inserts
    /// continue using `max + 1`.
    func reorderItems(tripId: UUID, sectionId: UUID, newOrder: [UUID]) {
        guard let trip = trips.first(where: { $0.id == tripId }),
              let section = trip.safeSections.first(where: { $0.id == sectionId }) else {
            return
        }
        let items = section.items ?? []
        if newOrder.count > items.count {
            CarryLogger.shared.log(.sortIndexOutOfBounds,
                                   context: "index=\(newOrder.count) count=\(items.count)")
        }
        for (index, id) in newOrder.enumerated() {
            if let item = items.first(where: { $0.id == id }) {
                item.sortOrder = index
            }
        }
        do {
            try context.save()
        } catch {
            CarryLogger.shared.log(.reorderSaveFailed, context: "context=reorderItems")
        }
        fetchTrips()
    }

    /// Regenerates the trip's packing list based on a new scene selection.
    /// Strategy:
    /// - Build a name → isPacked map from the existing sections (case-insensitive)
    /// - Compute fresh sections from the new scene keys
    /// - Restore isPacked for any item whose name appears in the old map
    /// - Preserve user-added items (items whose names are not in the new
    ///   preset) by appending them to the section that matches their old
    ///   category title; if no matching section exists, drop them
    /// - Replace the trip's sections wholesale
    func regenerateScenes(tripId: UUID, keys: [String]) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }

        // Capture old state
        var oldPackedByName: [String: Bool] = [:]
        var customItemsBySection: [String: [(name: String, quantity: Int, isPacked: Bool)]] = [:]
        let presetNames = Set(presetItemNames(forSceneKeys: keys).map { $0.lowercased() })

        for section in trip.safeSections {
            for item in section.items ?? [] {
                let key = item.name.lowercased()
                oldPackedByName[key] = item.isPacked
                if !presetNames.contains(key) {
                    customItemsBySection[section.title, default: []].append((item.name, item.quantity, item.isPacked))
                }
            }
        }

        // Build fresh sections (sortOrder assigned by generatePackingSections position)
        let destCodes = ([trip.countryCode] + trip.additionalDestinations.map(\.countryCode)).filter { !$0.isEmpty }
        let newSections = generatePackingSections(selectedScenes: keys, tripDays: trip.days, isInternational: trip.isInternational, destinationCodes: destCodes)
        for (index, section) in newSections.enumerated() { section.sortOrder = index }

        // Restore packed states + append custom items to matching section
        for section in newSections {
            for item in section.items ?? [] {
                if let wasPacked = oldPackedByName[item.name.lowercased()] {
                    item.isPacked = wasPacked
                }
            }
            if let customs = customItemsBySection.removeValue(forKey: section.title) {
                let nextOrderStart = ((section.items ?? []).map(\.sortOrder).max() ?? -1) + 1
                for (offset, custom) in customs.enumerated() {
                    let item = PackingItem(
                        name: custom.name,
                        quantity: custom.quantity,
                        isPacked: custom.isPacked,
                        isAlert: false,
                        sortOrder: nextOrderStart + offset
                    )
                    section.items?.append(item)
                }
            }
        }

        // 兜底：若用户曾改过某 section 标题，customItemsBySection 里的 key（旧 title）
        // 在 newSections 中找不到匹配，会被静默丢弃。把剩下的自定义物品收容到
        // fallback "Other" section，避免数据丢失。
        var sectionsToWrite = newSections
        if !customItemsBySection.isEmpty {
            let fallbackTitle = NSLocalizedString("packing.section.other", comment: "")
            let fallback = PackingSection(title: fallbackTitle, sortOrder: sectionsToWrite.count)
            var order = 0
            for (_, customs) in customItemsBySection {
                for custom in customs {
                    let item = PackingItem(
                        name: custom.name,
                        quantity: custom.quantity,
                        isPacked: custom.isPacked,
                        isAlert: false,
                        sortOrder: order
                    )
                    fallback.items?.append(item)
                    order += 1
                }
            }
            sectionsToWrite.append(fallback)
            CarryLogger.shared.log(.autoPackTriggered,
                context: "rescued_orphan_customs=\(order)")
        }

        // Replace
        // Delete old sections explicitly (cascade should handle items)
        for section in trip.safeSections {
            context.delete(section)
        }
        // Insert new sections + their items
        for section in sectionsToWrite {
            context.insert(section)
            for item in section.items ?? [] {
                context.insert(item)
            }
        }
        trip.sections = sectionsToWrite
        trip.selectedSceneKeys = keys
        save()
        CarryLogger.shared.log(.autoPackTriggered, context: "scenes=\(keys.count)")
#if !targetEnvironment(macCatalyst)
        Task { @MainActor in LiveActivityManager.shared.update(for: trip) }
#endif
    }

    /// Returns all unique preset item names for the given scene keys (including base items).
    private func presetItemNames(forSceneKeys keys: [String]) -> [String] {
        var names = Set<String>()
        baseItems.forEach { names.insert($0.name) }
        keys.compactMap { sceneItemMap[$0] }.flatMap { $0 }.forEach { names.insert($0.name) }
        return Array(names)
    }

    func reorderSections(tripId: UUID, newOrder: [UUID]) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        let sectionCount = trip.safeSections.count
        if newOrder.count > sectionCount {
            CarryLogger.shared.log(.sortIndexOutOfBounds,
                                   context: "index=\(newOrder.count) count=\(sectionCount)")
        }
        for (index, id) in newOrder.enumerated() {
            if let section = trip.safeSections.first(where: { $0.id == id }) {
                section.sortOrder = index
            }
        }
        do {
            try context.save()
        } catch {
            CarryLogger.shared.log(.reorderSaveFailed, context: "context=reorderSections")
        }
        fetchTrips()
        CarryLogger.shared.log(.sectionReordered)
    }

    @discardableResult
    func addSection(tripId: UUID, name: String) -> PackingSection? {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return nil }
        let nextOrder = (trip.safeSections.map(\.sortOrder).max() ?? -1) + 1
        let blankItem = PackingItem(name: "", isAlert: false, sortOrder: 0)
        let section = PackingSection(title: name, items: [blankItem], sortOrder: nextOrder)
        context.insert(blankItem)
        context.insert(section)
        if trip.sections == nil { trip.sections = [] }
        trip.sections?.append(section)
        save()
        CarryLogger.shared.log(.sectionAdded)
        return section
    }

    func removeSection(tripId: UUID, sectionId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }),
              let section = trip.safeSections.first(where: { $0.id == sectionId }) else { return }
        context.delete(section)
        trip.sections?.removeAll { $0.id == sectionId }
        save()
        CarryLogger.shared.log(.sectionDeleted)
#if !targetEnvironment(macCatalyst)
        Task { @MainActor in LiveActivityManager.shared.update(for: trip) }
#endif
    }

    func renameSection(tripId: UUID, sectionId: UUID, newName: String) {
        guard let trip = trips.first(where: { $0.id == tripId }),
              let section = trip.safeSections.first(where: { $0.id == sectionId }) else { return }
        section.title = newName
        save()
        CarryLogger.shared.log(.sectionRenamed)
    }

    func insertPendingSections(tripId: UUID, sections: [PackingSection]) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        for section in sections {
            context.insert(section)
            for item in section.items ?? [] {
                context.insert(item)
            }
            if trip.sections == nil { trip.sections = [] }
            trip.sections?.append(section)
        }
        save()
#if !targetEnvironment(macCatalyst)
        Task { @MainActor in LiveActivityManager.shared.update(for: trip) }
#endif
    }

    // MARK: - Itinerary (行程路线规划, spec: itinerary-route-planning.md)

    /// 把行程的 ItineraryDay 数量对齐到 `trip.days`（天 = 行程天数，自动生成，用户永不手动增删）。
    /// - 不足 → 末尾补天（sortOrder 连续）。
    /// - 超出 → 删尾部多余的天；被删天的停靠点**按原序挪到「最后保留的那天」**（决策 B：不丢数据）。
    /// - 幂等：数量已匹配且 sortOrder 连续时**不写库**（避免 onAppear 兜底时反复 save → 多余刷新）。
    /// 调用点：编辑行程日期/天数后（updateTripInfo）、打开行程页兜底（ItineraryView.onAppear）。
    func syncItineraryDays(tripId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        // 行程页的「天」= 含两端的实际天数（见 TripBundle.spanDays）。
        let target = trip.spanDays
        if trip.itineraryDays == nil { trip.itineraryDays = [] }
        let current = trip.safeItineraryDays   // 按 sortOrder 排序的快照数组
        var changed = false

        if current.count < target {
            for order in current.count..<target {
                let day = ItineraryDay(sortOrder: order)
                context.insert(day)
                trip.itineraryDays?.append(day)
            }
            changed = true
        } else if current.count > target {
            // 保留前 target 天；多余尾部天的停靠点**与交通段**挪到最后保留的那天，
            // 否则 context.delete(day) 会级联删掉该天的 segments → 改日期静默丢交通数据。
            let keep = Array(current.prefix(target))
            let remove = Array(current.suffix(current.count - target))
            if let lastKept = keep.last {
                var nextOrder = max(
                    lastKept.sortedStops.map(\.sortOrder).max() ?? -1,
                    lastKept.sortedSegments.map(\.sortOrder).max() ?? -1
                ) + 1
                let keptOrder = lastKept.sortOrder
                for day in remove {
                    for stop in day.sortedStops {     // sortedStops 是快照，移动时安全
                        stop.day = lastKept           // 关系反向自动从旧天移除、加入新天
                        stop.sortOrder = nextOrder
                        nextOrder += 1
                    }
                    for seg in day.sortedSegments {   // 交通段同样改归属、不随天删除丢失
                        seg.day = lastKept
                        seg.sortOrder = nextOrder
                        nextOrder += 1
                        // 起降天序回收到保留天范围内，保持 arrive >= depart。
                        seg.departDayOrder = keptOrder
                        seg.arriveDayOrder = max(keptOrder, min(seg.arriveDayOrder, target - 1))
                    }
                    trip.itineraryDays?.removeAll { $0.id == day.id }
                    context.delete(day)
                }
            }
            changed = true
        }
        // 规整 sortOrder 连续（仅在确有错位时才标记写库）。
        for (i, d) in trip.safeItineraryDays.enumerated() where d.sortOrder != i {
            d.sortOrder = i
            changed = true
        }
        // 住宿挂在 TripBundle、用 checkInDayOrder 锚定，不随天删除丢失；但天数缩短后
        // 可能落在范围外 → 夹回有效区间，避免常驻条/导出里「看不见」的孤立住宿。
        let lastValidOrder = max(0, target - 1)
        for stay in trip.safeLodgingStays where stay.checkInDayOrder > lastValidOrder {
            stay.checkInDayOrder = lastValidOrder
            changed = true
        }
        if changed { save() }
    }

    /// 在某天末尾新增停靠点。坐标可缺省（手动输名的无坐标点）。返回新 Stop 的 id。
    @discardableResult
    func addItineraryStop(
        tripId: UUID,
        dayId: UUID,
        name: String,
        latitude: Double = 0,
        longitude: Double = 0,
        address: String = "",
        category: StopCategory = .other
    ) -> UUID? {
        guard let trip = trips.first(where: { $0.id == tripId }),
              let day = trip.safeItineraryDays.first(where: { $0.id == dayId }) else { return nil }
        let nextOrder = (day.sortedStops.map(\.sortOrder).max() ?? -1) + 1
        let stop = ItineraryStop(
            name: name,
            latitude: latitude,
            longitude: longitude,
            address: address,
            category: category,
            sortOrder: nextOrder
        )
        context.insert(stop)
        if day.stops == nil { day.stops = [] }
        day.stops?.append(stop)
        save()
        CarryLogger.shared.log(.itineraryStopAdded)
        return stop.id
    }

    /// 更新停靠点字段（nil 表示该字段不改）。
    func updateItineraryStop(
        tripId: UUID,
        stopId: UUID,
        name: String? = nil,
        category: StopCategory? = nil,
        plannedStartMinutes: Int? = nil,
        stayMinutes: Int? = nil,
        note: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        address: String? = nil
    ) {
        guard let trip = trips.first(where: { $0.id == tripId }),
              let stop = trip.safeItineraryDays.flatMap({ $0.stops ?? [] }).first(where: { $0.id == stopId }) else { return }
        if let name { stop.name = name }
        if let category { stop.category = category }
        if let plannedStartMinutes { stop.plannedStartMinutes = plannedStartMinutes }
        if let stayMinutes { stop.stayMinutes = stayMinutes }
        if let note { stop.note = note }
        if let latitude { stop.latitude = latitude }
        if let longitude { stop.longitude = longitude }
        if let address { stop.address = address }
        save()
    }

    func removeItineraryStop(tripId: UUID, dayId: UUID, stopId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }),
              let day = trip.safeItineraryDays.first(where: { $0.id == dayId }),
              let stop = (day.stops ?? []).first(where: { $0.id == stopId }) else { return }
        context.delete(stop)
        day.stops?.removeAll { $0.id == stopId }
        for (index, s) in day.sortedStops.enumerated() { s.sortOrder = index }
        save()
        CarryLogger.shared.log(.itineraryStopRemoved)
    }

    /// 重排某天内停靠点。`newOrder` 为期望顺序的 stop id 数组，sortOrder 重写为 0,1,2…
    /// 既服务手动拖拽，也服务单日智能重排「采纳」（Phase 3）。
    func reorderItineraryStops(tripId: UUID, dayId: UUID, newOrder: [UUID]) {
        guard let trip = trips.first(where: { $0.id == tripId }),
              let day = trip.safeItineraryDays.first(where: { $0.id == dayId }) else { return }
        let stops = day.stops ?? []
        if newOrder.count > stops.count {
            CarryLogger.shared.log(.sortIndexOutOfBounds,
                                   context: "index=\(newOrder.count) count=\(stops.count)")
        }
        for (index, id) in newOrder.enumerated() {
            if let stop = stops.first(where: { $0.id == id }) {
                stop.sortOrder = index
            }
        }
        save()
        CarryLogger.shared.log(.itineraryStopReordered)
    }

    /// 跨天/日内一次性应用「天→停靠点顺序」映射（spec: itinerary-route-planning.md，跨天拖拽）。
    /// 为每个停靠点重设所属 `day`（SwiftData 关系，inverse 自动维护两边数组）与 `sortOrder`。
    /// 调用方传入拖拽落定后的**完整结构**（每天一条 stopID 顺序）。
    func applyItineraryArrangement(tripId: UUID, dayOrders: [(dayID: UUID, stopIDs: [UUID])]) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        let daysByID = Dictionary(trip.safeItineraryDays.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let stopsByID = Dictionary(
            trip.safeItineraryDays.flatMap { $0.sortedStops }.map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        var didCross = false
        for (dayID, stopIDs) in dayOrders {
            guard let day = daysByID[dayID] else { continue }
            for (index, sid) in stopIDs.enumerated() {
                guard let stop = stopsByID[sid] else { continue }
                if stop.day?.id != dayID {
                    stop.day = day        // 关系反向自动从旧天移除、加入新天
                    didCross = true
                }
                stop.sortOrder = index
            }
        }
        save()
        CarryLogger.shared.log(didCross ? .itineraryStopMovedDay : .itineraryStopReordered)
    }

    // MARK: - Itinerary Transport（交通段 CRUD · spec: itinerary-transport-lodging.md）
    //
    // 埋点（transportAdded/Edited/Removed）随 UI 接入时一起补（CLAUDE.md「定义即接线」：
    // 调用点要可达，故等录入 UI 落地再加 CarryLogger.Event + 调用，避免死埋点。

    /// 在某天末尾新增一段交通。归出发日（dayId），与该天 stop 共享 sortOrder 空间。返回新段 id。
    @discardableResult
    func addTransportSegment(
        tripId: UUID,
        dayId: UUID,
        mode: TransportMode,
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
        departDayOrder: Int? = nil,
        departLocalMinutes: Int = -1,
        arriveDayOrder: Int? = nil,
        arriveLocalMinutes: Int = -1,
        seat: String = "",
        confirmationCode: String = "",
        note: String = ""
    ) -> UUID? {
        guard let trip = trips.first(where: { $0.id == tripId }),
              let day = trip.safeItineraryDays.first(where: { $0.id == dayId }) else { return nil }
        // 时间轴排序：取该天 stop 与 segment 的最大 sortOrder + 1，接到末尾。
        let maxOrder = max(
            day.sortedStops.map(\.sortOrder).max() ?? -1,
            day.sortedSegments.map(\.sortOrder).max() ?? -1
        )
        let segment = TransportSegment(
            mode: mode,
            carrier: carrier,
            number: number,
            fromName: fromName,
            fromCode: fromCode,
            fromLatitude: fromLatitude,
            fromLongitude: fromLongitude,
            fromTimeZoneId: fromTimeZoneId,
            fromTerminal: fromTerminal,
            toName: toName,
            toCode: toCode,
            toLatitude: toLatitude,
            toLongitude: toLongitude,
            toTimeZoneId: toTimeZoneId,
            toTerminal: toTerminal,
            departDayOrder: departDayOrder ?? day.sortOrder,
            departLocalMinutes: departLocalMinutes,
            arriveDayOrder: arriveDayOrder ?? day.sortOrder,
            arriveLocalMinutes: arriveLocalMinutes,
            seat: seat,
            confirmationCode: confirmationCode,
            note: note,
            sortOrder: maxOrder + 1
        )
        context.insert(segment)
        if day.segments == nil { day.segments = [] }
        day.segments?.append(segment)
        save()
        CarryLogger.shared.log(.transportAdded, context: "mode=\(mode.rawValue)")
        return segment.id
    }

    /// 更新交通段字段（nil 表示不改）。
    func updateTransportSegment(
        tripId: UUID,
        segmentId: UUID,
        mode: TransportMode? = nil,
        carrier: String? = nil,
        number: String? = nil,
        fromName: String? = nil,
        fromCode: String? = nil,
        fromLatitude: Double? = nil,
        fromLongitude: Double? = nil,
        fromTimeZoneId: String? = nil,
        fromTerminal: String? = nil,
        toName: String? = nil,
        toCode: String? = nil,
        toLatitude: Double? = nil,
        toLongitude: Double? = nil,
        toTimeZoneId: String? = nil,
        toTerminal: String? = nil,
        departDayOrder: Int? = nil,
        departLocalMinutes: Int? = nil,
        arriveDayOrder: Int? = nil,
        arriveLocalMinutes: Int? = nil,
        seat: String? = nil,
        confirmationCode: String? = nil,
        note: String? = nil
    ) {
        guard let trip = trips.first(where: { $0.id == tripId }),
              let seg = trip.safeItineraryDays.flatMap({ $0.segments ?? [] }).first(where: { $0.id == segmentId }) else { return }
        if let mode { seg.mode = mode }
        if let carrier { seg.carrier = carrier }
        if let number { seg.number = number }
        if let fromName { seg.fromName = fromName }
        if let fromCode { seg.fromCode = fromCode }
        if let fromLatitude { seg.fromLatitude = fromLatitude }
        if let fromLongitude { seg.fromLongitude = fromLongitude }
        if let fromTimeZoneId { seg.fromTimeZoneId = fromTimeZoneId }
        if let fromTerminal { seg.fromTerminal = fromTerminal }
        if let toName { seg.toName = toName }
        if let toCode { seg.toCode = toCode }
        if let toLatitude { seg.toLatitude = toLatitude }
        if let toLongitude { seg.toLongitude = toLongitude }
        if let toTimeZoneId { seg.toTimeZoneId = toTimeZoneId }
        if let toTerminal { seg.toTerminal = toTerminal }
        if let departDayOrder { seg.departDayOrder = departDayOrder }
        if let departLocalMinutes { seg.departLocalMinutes = departLocalMinutes }
        if let arriveDayOrder { seg.arriveDayOrder = arriveDayOrder }
        if let arriveLocalMinutes { seg.arriveLocalMinutes = arriveLocalMinutes }
        if let seat { seg.seat = seat }
        if let confirmationCode { seg.confirmationCode = confirmationCode }
        if let note { seg.note = note }
        save()
    }

    func removeTransportSegment(tripId: UUID, dayId: UUID, segmentId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }),
              let day = trip.safeItineraryDays.first(where: { $0.id == dayId }),
              let seg = (day.segments ?? []).first(where: { $0.id == segmentId }) else { return }
        context.delete(seg)
        day.segments?.removeAll { $0.id == segmentId }
        save()
        CarryLogger.shared.log(.transportRemoved)
    }

    // MARK: - Lodging（住宿跨度 CRUD · spec: itinerary-transport-lodging.md）

    /// 新增一段住宿（横跨 nights 晚，从 checkInDayOrder 起）。归 TripBundle。返回新 stay id。
    @discardableResult
    func addLodgingStay(
        tripId: UUID,
        name: String = "",
        address: String = "",
        latitude: Double = 0,
        longitude: Double = 0,
        checkInDayOrder: Int = 0,
        nights: Int = 1,
        checkInMinutes: Int = -1,
        checkOutMinutes: Int = -1,
        confirmationCode: String = "",
        note: String = ""
    ) -> UUID? {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return nil }
        let nextOrder = (trip.safeLodgingStays.map(\.sortOrder).max() ?? -1) + 1
        let stay = LodgingStay(
            name: name,
            address: address,
            latitude: latitude,
            longitude: longitude,
            checkInDayOrder: checkInDayOrder,
            nights: nights,
            checkInMinutes: checkInMinutes,
            checkOutMinutes: checkOutMinutes,
            confirmationCode: confirmationCode,
            note: note,
            sortOrder: nextOrder
        )
        context.insert(stay)
        if trip.lodgingStays == nil { trip.lodgingStays = [] }
        trip.lodgingStays?.append(stay)
        save()
        CarryLogger.shared.log(.lodgingAdded)
        return stay.id
    }

    /// 更新住宿字段（nil 表示不改）。
    func updateLodgingStay(
        tripId: UUID,
        stayId: UUID,
        name: String? = nil,
        address: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        checkInDayOrder: Int? = nil,
        nights: Int? = nil,
        checkInMinutes: Int? = nil,
        checkOutMinutes: Int? = nil,
        confirmationCode: String? = nil,
        note: String? = nil
    ) {
        guard let trip = trips.first(where: { $0.id == tripId }),
              let stay = (trip.lodgingStays ?? []).first(where: { $0.id == stayId }) else { return }
        if let name { stay.name = name }
        if let address { stay.address = address }
        if let latitude { stay.latitude = latitude }
        if let longitude { stay.longitude = longitude }
        if let checkInDayOrder { stay.checkInDayOrder = checkInDayOrder }
        if let nights { stay.nights = max(1, nights) }
        if let checkInMinutes { stay.checkInMinutes = checkInMinutes }
        if let checkOutMinutes { stay.checkOutMinutes = checkOutMinutes }
        if let confirmationCode { stay.confirmationCode = confirmationCode }
        if let note { stay.note = note }
        save()
    }

    func removeLodgingStay(tripId: UUID, stayId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }),
              let stay = (trip.lodgingStays ?? []).first(where: { $0.id == stayId }) else { return }
        context.delete(stay)
        trip.lodgingStays?.removeAll { $0.id == stayId }
        save()
        CarryLogger.shared.log(.lodgingRemoved)
    }

    // MARK: - 费用记录（spec: itinerary-cost-tracking.md）

    /// 单一写入漏斗：写费用并就地捕获本位币快照。`currencyCode` 为空 = 清除费用。
    /// 快照取不到（无汇率/离线）→ -1，Trip Book 退回实时折算兜底。@MainActor 因要读 ExchangeRateManager。
    @MainActor
    private func applyCost(to entity: CostBearing, amount: Double, currencyCode: String) {
        let code = currencyCode.uppercased()
        if code.isEmpty {
            entity.costAmount = 0
            entity.costCurrencyCode = ""
            entity.costHomeAmount = -1
        } else {
            entity.costAmount = amount
            entity.costCurrencyCode = code
            entity.costHomeAmount = ExchangeRateManager.shared.convertToHome(amount, from: code) ?? -1
        }
    }

    @MainActor
    func setStopCost(tripId: UUID, stopId: UUID, amount: Double, currencyCode: String) {
        guard let trip = trips.first(where: { $0.id == tripId }),
              let stop = trip.safeItineraryDays.flatMap({ $0.stops ?? [] }).first(where: { $0.id == stopId }) else { return }
        let had = stop.hasCost
        applyCost(to: stop, amount: amount, currencyCode: currencyCode)
        save()
        logCostChange(had: had, has: stop.hasCost, category: "stop")
    }

    @MainActor
    func setTransportCost(tripId: UUID, segmentId: UUID, amount: Double, currencyCode: String) {
        guard let trip = trips.first(where: { $0.id == tripId }),
              let seg = trip.safeItineraryDays.flatMap({ $0.segments ?? [] }).first(where: { $0.id == segmentId }) else { return }
        let had = seg.hasCost
        applyCost(to: seg, amount: amount, currencyCode: currencyCode)
        save()
        logCostChange(had: had, has: seg.hasCost, category: "transport")
    }

    @MainActor
    func setLodgingCost(tripId: UUID, stayId: UUID, amount: Double, currencyCode: String) {
        guard let trip = trips.first(where: { $0.id == tripId }),
              let stay = (trip.lodgingStays ?? []).first(where: { $0.id == stayId }) else { return }
        let had = stay.hasCost
        applyCost(to: stay, amount: amount, currencyCode: currencyCode)
        save()
        logCostChange(had: had, has: stay.hasCost, category: "lodging")
    }

    private func logCostChange(had: Bool, has: Bool, category: String) {
        if !had && has { CarryLogger.shared.log(.costAdded, context: "category=\(category)") }
        else if had && !has { CarryLogger.shared.log(.costRemoved, context: "category=\(category)") }
    }

    /// 改本位币后重算所有费用快照（单一不变式：costHomeAmount 永远以当前本位币计）。
    /// 始终从原始 `costAmount + costCurrencyCode` 折算，绝不「折快照的快照」；取不到汇率 → -1。
    @MainActor
    func recomputeCostSnapshots() {
        let mgr = ExchangeRateManager.shared
        for trip in trips {
            for day in trip.safeItineraryDays {
                for stop in (day.stops ?? []) where stop.hasCost {
                    stop.costHomeAmount = mgr.convertToHome(stop.costAmount, from: stop.costCurrencyCode) ?? -1
                }
                for seg in (day.segments ?? []) where seg.hasCost {
                    seg.costHomeAmount = mgr.convertToHome(seg.costAmount, from: seg.costCurrencyCode) ?? -1
                }
            }
            for stay in trip.safeLodgingStays where stay.hasCost {
                stay.costHomeAmount = mgr.convertToHome(stay.costAmount, from: stay.costCurrencyCode) ?? -1
            }
        }
        save()
    }

    /// Adds scene keys to a trip and merges the supplied sections.
    /// Used by the suggestion preview flow so scene context is saved alongside the items.
    func addScenesAndMerge(tripId: UUID, keys: [String], sections: [PackingSection]) {
        guard let trip = bundle(for: tripId) else { return }
        let existing = Set(trip.selectedSceneKeys)
        trip.selectedSceneKeys.append(contentsOf: keys.filter { !existing.contains($0) })
        if draftTrip?.id == tripId {
            // Force @Published emission for draft preview flows.
            draftTrip = trip
        }
        mergeItems(tripId: tripId, sections: sections)
    }

    /// Merges additional items into an existing trip.
    /// Sections with a matching title have items appended (skipping name duplicates).
    /// Sections with no matching title are appended as new sections.
    func mergeItems(tripId: UUID, sections newSections: [PackingSection]) {
        guard let trip = bundle(for: tripId) else { return }
        let isDraftTarget = (draftTrip?.id == tripId)
        let existing = trip.safeSections
        var nextSectionOrder = (existing.map(\.sortOrder).max() ?? -1) + 1

        for newSection in newSections {
            if let existingSection = existing.first(where: { $0.title == newSection.title }) {
                let existingNames = Set((existingSection.items ?? []).map { $0.name.lowercased() })
                let maxOrder = ((existingSection.items ?? []).map(\.sortOrder).max() ?? -1)
                var offset = 0
                for item in (newSection.items ?? []) {
                    guard !existingNames.contains(item.name.lowercased()) else { continue }
                    item.sortOrder = maxOrder + 1 + offset
                    offset += 1
                    if !isDraftTarget { context.insert(item) }
                    existingSection.items?.append(item)
                }
            } else {
                newSection.sortOrder = nextSectionOrder
                nextSectionOrder += 1
                if !isDraftTarget { context.insert(newSection) }
                for item in newSection.items ?? [] {
                    if !isDraftTarget { context.insert(item) }
                }
                if trip.sections == nil { trip.sections = [] }
                trip.sections?.append(newSection)
            }
        }
        if isDraftTarget {
            // Force @Published emission for draft preview flows.
            draftTrip = trip
        } else {
            save()
#if !targetEnvironment(macCatalyst)
            Task { @MainActor in LiveActivityManager.shared.update(for: trip) }
#endif
        }
    }

    func dismissSurpriseItem(tripId: UUID, itemName: String) {
        guard let trip = bundle(for: tripId),
              !trip.dismissedSurpriseNames.contains(itemName) else { return }
        trip.dismissedSurpriseNames.append(itemName)
        save()
    }


    func dismissSceneCard(tripId: UUID) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        trip.sceneCardDismissed = true
        if !isSceneCardDismissedGlobally {
            isSceneCardDismissedGlobally = true
            defaults.set(true, forKey: Self.sceneCardDismissedGlobalKey)
        }
        save()
    }

    func setSelectedSceneKeys(tripId: UUID, keys: [String]) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        trip.selectedSceneKeys = keys
        save()
    }

#if DEBUG
    func debugResetSceneCardDismissState() {
        isSceneCardDismissedGlobally = false
        defaults.set(false, forKey: Self.sceneCardDismissedGlobalKey)
        for trip in trips {
            trip.sceneCardDismissed = false
        }
        save()
    }
#endif

    /// Adds a surprise item to the most relevant existing section, or creates a new one.
    func addSurpriseItem(tripId: UUID, item: SurpriseItem) {
        guard let trip = bundle(for: tripId) else { return }
        let categoryTitle = item.category.rawValue
        if let section = trip.safeSections.first(where: { $0.title == categoryTitle }) {
            let existing = section.items ?? []
            let nextOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
            let newItem = PackingItem(name: item.name, isAlert: false, sortOrder: nextOrder)
            context.insert(newItem)
            section.items?.append(newItem)
        } else {
            let nextSectionOrder = (trip.safeSections.map(\.sortOrder).max() ?? -1) + 1
            let newItem = PackingItem(name: item.name, isAlert: false, sortOrder: 0)
            let newSection = PackingSection(title: categoryTitle, items: [newItem], sortOrder: nextSectionOrder)
            context.insert(newItem)
            context.insert(newSection)
            if trip.sections == nil { trip.sections = [] }
            trip.sections?.append(newSection)
        }
        dismissSurpriseItem(tripId: tripId, itemName: item.name)
        save()
#if !targetEnvironment(macCatalyst)
        Task { @MainActor in LiveActivityManager.shared.update(for: trip) }
#endif
    }

    // MARK: - My Items

    func myItemCollections() -> [String] {
        let names = Set(myItems.map { normalizedCollectionName($0.collectionName) })
        return [defaultMyItemCollection] + names.filter { $0 != defaultMyItemCollection }.sorted()
    }

    func myItems(in collectionName: String? = nil) -> [MyItem] {
        let target = normalizedCollectionName(collectionName ?? defaultMyItemCollection)
        return myItems.filter { normalizedCollectionName($0.collectionName) == target }
    }

    @discardableResult
    func addMyItem(
        name: String,
        category: String = "",
        defaultQuantity: Int = 1,
        quantityMode: MyItemQuantityMode = .fixed,
        quantityIntervalDays: Int = 2,
        collectionName: String = "Default"
    ) -> MyItem {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return MyItem(name: "", collectionName: normalizedCollectionName(collectionName), category: "", defaultQuantity: 1, quantityMode: quantityMode, quantityIntervalDays: quantityIntervalDays)
        }
        let targetCollection = normalizedCollectionName(collectionName)
        if let existing = myItems.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(trimmed) == .orderedSame
            && $0.category.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(category.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            && normalizedCollectionName($0.collectionName) == targetCollection
        }) {
            existing.defaultQuantity = max(1, defaultQuantity)
            existing.quantityMode = quantityMode
            existing.quantityIntervalDays = max(1, quantityIntervalDays)
            existing.updatedAt = Date()
            save()
            return existing
        }
        let nextOrder = (myItems.map(\.sortOrder).max() ?? -1) + 1
        let item = MyItem(
            name: trimmed,
            collectionName: targetCollection,
            category: category,
            defaultQuantity: defaultQuantity,
            quantityMode: quantityMode,
            quantityIntervalDays: quantityIntervalDays,
            sortOrder: nextOrder
        )
        context.insert(item)
        save()
        CarryLogger.shared.log(.myItemAdded)
        return item
    }

    func copyMyItem(_ item: MyItem) {
        let baseName = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = NSLocalizedString("trip.copy_suffix", comment: "")
        let nextOrder = (myItems.map(\.sortOrder).max() ?? -1) + 1
        let copy = MyItem(
            name: baseName + suffix,
            collectionName: normalizedCollectionName(item.collectionName),
            category: item.category,
            defaultQuantity: item.defaultQuantity,
            quantityMode: item.quantityMode,
            quantityIntervalDays: item.quantityIntervalDays,
            sortOrder: nextOrder
        )
        context.insert(copy)
        save()
    }

    func updateMyItem(
        _ item: MyItem,
        name: String,
        category: String,
        defaultQuantity: Int,
        quantityMode: MyItemQuantityMode? = nil,
        quantityIntervalDays: Int? = nil,
        collectionName: String? = nil
    ) {
        item.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        item.category = category
        item.defaultQuantity = max(1, defaultQuantity)
        if let quantityMode {
            item.quantityMode = quantityMode
        }
        if let quantityIntervalDays {
            item.quantityIntervalDays = max(1, quantityIntervalDays)
        }
        if let collectionName {
            item.collectionName = normalizedCollectionName(collectionName)
        }
        item.updatedAt = Date()
        save()
    }

    func removeMyItem(id: UUID) {
        guard let item = myItems.first(where: { $0.id == id }) else { return }
        context.delete(item)
        save()
        CarryLogger.shared.log(.myItemDeleted)
    }

    func reorderMyItems(newOrder: [UUID]) {
        let orderedItems = newOrder.compactMap { id in myItems.first(where: { $0.id == id }) }
        let remainingItems = myItems
            .filter { !newOrder.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return lhs.createdAt < rhs.createdAt
            }
        let finalOrder = orderedItems + remainingItems
        for (index, item) in finalOrder.enumerated() {
            item.sortOrder = index
        }
        save()
    }

    func addMyItemsToTrip(tripId: UUID, items: [MyItem]) {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return }
        var sectionsByTitle: [String: PackingSection] = Dictionary(
            uniqueKeysWithValues: trip.safeSections.map { ($0.title, $0) }
        )
        var nextSectionOrder = (trip.safeSections.map(\.sortOrder).max() ?? -1) + 1

        for source in items {
            let sectionTitle = source.category.isEmpty ? "Essentials" : source.category
            let section: PackingSection
            if let existing = sectionsByTitle[sectionTitle] {
                section = existing
            } else {
                section = PackingSection(title: sectionTitle, items: [], sortOrder: nextSectionOrder)
                nextSectionOrder += 1
                sectionsByTitle[sectionTitle] = section
                context.insert(section)
                if trip.sections == nil { trip.sections = [] }
                trip.sections?.append(section)
            }

            let existingNames = Set((section.items ?? []).map { $0.name.lowercased() })
            guard !existingNames.contains(source.name.lowercased()) else { continue }
            let nextOrder = ((section.items ?? []).map(\.sortOrder).max() ?? -1) + 1
            let item = PackingItem(
                name: source.name,
                quantity: source.defaultQuantity,
                isAlert: false,
                sortOrder: nextOrder
            )
            context.insert(item)
            section.items?.append(item)
        }
        save()
#if !targetEnvironment(macCatalyst)
        Task { @MainActor in LiveActivityManager.shared.update(for: trip) }
#endif
    }

    // MARK: - Queries

    func bundle(for id: UUID) -> TripBundle? {
        if let draftTrip, draftTrip.id == id {
            return draftTrip
        }
        return trips.first(where: { $0.id == id })
    }

    // MARK: - Geocoding

    // MARK: - City lookup table

    /// Local city → (countryCode, lat, lon) table.
    /// Covers ~600 cities/regions in Chinese and English names.
    /// Used as the primary resolver so the globe works without network access.
    private static let cityLookup: [String: (code: String, lat: Double, lon: Double)] = {
        // (cityName, countryCode, lat, lon)
        let entries: [(String, String, Double, Double)] = [

            // ── 中国大陆 ──────────────────────────────────────────────────────
            ("北京",    "CN",  39.91, 116.39), ("上海",    "CN",  31.23, 121.47),
            ("广州",    "CN",  23.13, 113.27), ("深圳",    "CN",  22.54, 114.06),
            ("成都",    "CN",  30.66, 104.08), ("杭州",    "CN",  30.25, 120.16),
            ("武汉",    "CN",  30.59, 114.31), ("西安",    "CN",  34.27, 108.95),
            ("南京",    "CN",  32.06, 118.80), ("重庆",    "CN",  29.56, 106.55),
            ("天津",    "CN",  39.13, 117.20), ("苏州",    "CN",  31.30, 120.62),
            ("青岛",    "CN",  36.07, 120.37), ("大连",    "CN",  38.91, 121.60),
            ("厦门",    "CN",  24.48, 118.09), ("哈尔滨",  "CN",  45.75, 126.63),
            ("长春",    "CN",  43.88, 125.32), ("沈阳",    "CN",  41.81, 123.43),
            ("济南",    "CN",  36.67, 116.99), ("郑州",    "CN",  34.75, 113.63),
            ("昆明",    "CN",  25.04, 102.71), ("贵阳",    "CN",  26.58, 106.71),
            ("南昌",    "CN",  28.69, 115.86), ("合肥",    "CN",  31.86, 117.28),
            ("福州",    "CN",  26.08, 119.30), ("石家庄",  "CN",  38.05, 114.48),
            ("太原",    "CN",  37.87, 112.55), ("南宁",    "CN",  22.82, 108.32),
            ("长沙",    "CN",  28.23, 112.94), ("乌鲁木齐","CN",  43.83,  87.62),
            ("拉萨",    "CN",  29.65,  91.13), ("兰州",    "CN",  36.06, 103.83),
            ("西宁",    "CN",  36.62, 101.78), ("银川",    "CN",  38.47, 106.27),
            ("呼和浩特","CN",  40.84, 111.75), ("海口",    "CN",  20.04, 110.32),
            ("南通",    "CN",  31.98, 120.89), ("无锡",    "CN",  31.57, 120.30),
            ("宁波",    "CN",  29.87, 121.54), ("温州",    "CN",  28.00, 120.67),
            ("义乌",    "CN",  29.31, 120.07), ("嘉兴",    "CN",  30.75, 120.76),
            ("绍兴",    "CN",  29.99, 120.54), ("舟山",    "CN",  29.98, 122.21),
            ("南阳",    "CN",  33.00, 112.53), ("洛阳",    "CN",  34.62, 112.45),
            ("烟台",    "CN",  37.54, 121.39), ("威海",    "CN",  37.52, 122.12),
            ("潍坊",    "CN",  36.71, 119.16), ("临沂",    "CN",  35.10, 118.36),
            ("唐山",    "CN",  39.63, 118.18), ("保定",    "CN",  38.87, 115.46),
            ("邯郸",    "CN",  36.62, 114.53), ("廊坊",    "CN",  39.54, 116.69),
            ("东莞",    "CN",  23.02, 113.75), ("佛山",    "CN",  23.02, 113.12),
            ("珠海",    "CN",  22.27, 113.56), ("汕头",    "CN",  23.35, 116.68),
            ("中山",    "CN",  22.52, 113.39), ("惠州",    "CN",  23.11, 114.42),
            ("揭阳",    "CN",  23.55, 116.37), ("湛江",    "CN",  21.27, 110.36),
            ("泉州",    "CN",  24.87, 118.68), ("漳州",    "CN",  24.51, 117.65),
            ("南宁",    "CN",  22.82, 108.32), ("柳州",    "CN",  24.33, 109.41),
            ("桂林",    "CN",  25.27, 110.29), ("三亚",    "CN",  18.25, 109.51),
            ("丽江",    "CN",  26.87, 100.23), ("张家界",  "CN",  29.12, 110.48),
            ("九寨沟",  "CN",  33.26, 103.92), ("黄山",    "CN",  29.72, 118.33),
            ("香格里拉","CN",  27.83,  99.71), ("西双版纳","CN",  22.01, 100.80),
            ("大理",    "CN",  25.60, 100.27), ("腾冲",    "CN",  25.02,  98.49),
            ("敦煌",    "CN",  40.14,  94.66), ("喀什",    "CN",  39.47,  75.98),
            ("伊犁",    "CN",  43.92,  81.32), ("吐鲁番",  "CN",  42.95,  89.19),
            ("额尔古纳","CN",  50.24, 120.19), ("呼伦贝尔","CN",  49.22, 119.74),
            ("稻城",    "CN",  29.04, 100.30), ("色达",    "CN",  32.27, 100.34),
            ("甘南",    "CN",  34.99, 102.91), ("阿坝",    "CN",  32.90, 101.70),
            ("峨眉山",  "CN",  29.60, 103.48), ("乐山",    "CN",  29.56, 103.77),
            ("都江堰",  "CN",  31.00, 103.62), ("黄龙",    "CN",  32.75, 103.82),
            ("武夷山",  "CN",  27.77, 118.05), ("庐山",    "CN",  29.57, 116.04),
            ("张掖",    "CN",  38.93, 100.46), ("嘉峪关",  "CN",  39.77,  98.29),

            // ── 港澳台 ──────────────────────────────────────────────────────
            ("香港",    "HK",  22.40, 114.11), ("澳门",    "MO",  22.20, 113.55),
            ("台北",    "TW",  25.05, 121.56), ("高雄",    "TW",  22.63, 120.30),
            ("台中",    "TW",  24.15, 120.67), ("台南",    "TW",  22.99, 120.21),
            ("花莲",    "TW",  23.99, 121.60), ("垦丁",    "TW",  21.94, 120.82),

            // ── 日本 ────────────────────────────────────────────────────────
            ("东京",    "JP",  35.69, 139.69), ("大阪",    "JP",  34.69, 135.50),
            ("京都",    "JP",  35.01, 135.77), ("福冈",    "JP",  33.59, 130.40),
            ("札幌",    "JP",  43.06, 141.35), ("冲绳",    "JP",  26.21, 127.68),
            ("那霸",    "JP",  26.21, 127.68), ("名古屋",  "JP",  35.18, 136.91),
            ("横滨",    "JP",  35.44, 139.64), ("神户",    "JP",  34.69, 135.20),
            ("奈良",    "JP",  34.68, 135.83), ("广岛",    "JP",  34.39, 132.46),
            ("仙台",    "JP",  38.27, 140.87), ("金泽",    "JP",  36.56, 136.66),
            ("长崎",    "JP",  32.74, 129.87), ("熊本",    "JP",  32.80, 130.71),
            ("箱根",    "JP",  35.23, 139.11), ("轻井泽",  "JP",  36.35, 138.60),
            ("富士山",  "JP",  35.36, 138.73), ("白川乡",  "JP",  36.26, 136.91),
            ("镰仓",    "JP",  35.32, 139.55), ("日光",    "JP",  36.75, 139.60),

            // ── 韩国 ────────────────────────────────────────────────────────
            ("首尔",    "KR",  37.57, 126.98), ("釜山",    "KR",  35.10, 129.04),
            ("济州岛",  "KR",  33.49, 126.53), ("仁川",    "KR",  37.46, 126.71),
            ("大邱",    "KR",  35.87, 128.60), ("光州",    "KR",  35.16, 126.85),
            ("庆州",    "KR",  35.86, 129.22), ("全州",    "KR",  35.82, 127.15),

            // ── 东南亚 ──────────────────────────────────────────────────────
            ("曼谷",    "TH",  13.75, 100.52), ("清迈",    "TH",  18.79,  98.98),
            ("普吉",    "TH",   7.89,  98.40), ("普吉岛",  "TH",   7.89,  98.40),
            ("芭提雅",  "TH",  12.93, 100.88), ("苏梅岛",  "TH",   9.53,  99.93),
            ("甲米",    "TH",   8.09,  98.91), ("清莱",    "TH",  19.91,  99.83),
            ("河内",    "VN",  21.03, 105.85), ("胡志明",  "VN",  10.82, 106.63),
            ("胡志明市","VN",  10.82, 106.63), ("岘港",    "VN",  16.05, 108.22),
            ("会安",    "VN",  15.88, 108.34), ("芽庄",    "VN",  12.24, 109.19),
            ("下龙湾",  "VN",  20.95, 107.06), ("顺化",    "VN",  16.47, 107.59),
            ("富国岛",  "VN",  10.29, 103.98), ("大叻",    "VN",  11.94, 108.44),
            ("新加坡",  "SG",   1.35, 103.82),
            ("吉隆坡",  "MY",   3.14, 101.69), ("槟城",    "MY",   5.41, 100.33),
            ("兰卡威",  "MY",   6.35, 100.13), ("亚庇",    "MY",   5.98, 116.07),
            ("古晋",    "MY",   1.55, 110.34), ("马六甲",  "MY",   2.19, 102.25),
            ("雅加达",  "ID",  -6.21, 106.85), ("巴厘",    "ID",  -8.34, 115.09),
            ("巴厘岛",  "ID",  -8.34, 115.09), ("日惹",    "ID",  -7.80, 110.36),
            ("苏拉巴亚","ID",  -7.25, 112.75), ("龙目岛",  "ID",  -8.57, 116.35),
            ("科莫多",  "ID",  -8.55, 119.49), ("望加锡",  "ID",  -5.13, 119.42),
            ("马尼拉",  "PH",  14.60, 120.98), ("宿务",    "PH",  10.32, 123.89),
            ("长滩岛",  "PH",  11.96, 121.92), ("巴拉望",  "PH",   9.84, 118.74),
            ("仰光",    "MM",  16.87,  96.19), ("蒲甘",    "MM",  21.17,  94.86),
            ("曼德勒",  "MM",  21.97,  96.08), ("茵莱湖",  "MM",  20.58,  96.90),
            ("金边",    "KH",  11.56, 104.92), ("暹粒",    "KH",  13.36, 103.86),
            ("吴哥",    "KH",  13.41, 103.87),
            ("万象",    "LA",  17.97, 102.60), ("琅勃拉邦","LA",  19.89, 102.14),
            ("科伦坡",  "LK",   6.93,  79.85), ("康提",    "LK",   7.29,  80.63),
            ("加德满都","NP",  27.72,  85.32), ("博卡拉",  "NP",  28.21,  83.99),
            ("达卡",    "BD",  23.81,  90.41),

            // ── 南亚 ────────────────────────────────────────────────────────
            ("孟买",    "IN",  19.08,  72.88), ("新德里",  "IN",  28.61,  77.21),
            ("德里",    "IN",  28.61,  77.21), ("班加罗尔","IN",  12.97,  77.59),
            ("金奈",    "IN",  13.08,  80.27), ("加尔各答","IN",  22.57,  88.36),
            ("海得拉巴","IN",  17.39,  78.49), ("斋浦尔",  "IN",  26.91,  75.79),
            ("阿格拉",  "IN",  27.18,  78.01), ("瓦拉纳西","IN",  25.32,  83.01),
            ("果阿",    "IN",  15.30,  74.08), ("科钦",    "IN",   9.93,  76.26),
            ("乌代浦尔","IN",  24.57,  73.68), ("焦特布尔","IN",  26.29,  73.03),
            ("卡朱拉霍","IN",  24.85,  79.92), ("迈索尔",  "IN",  12.30,  76.65),
            ("伊斯兰堡","PK",  33.72,  73.04), ("卡拉奇",  "PK",  24.86,  67.01),
            ("拉合尔",  "PK",  31.55,  74.34),

            // ── 中东 ────────────────────────────────────────────────────────
            ("迪拜",    "AE",  25.20,  55.27), ("阿布扎比","AE",  24.47,  54.37),
            ("沙迦",    "AE",  25.36,  55.39),
            ("多哈",    "QA",  25.29,  51.53),
            ("科威特城","KW",  29.37,  47.98),
            ("利雅得",  "SA",  24.69,  46.72), ("吉达",    "SA",  21.49,  39.19),
            ("麦加",    "SA",  21.39,  39.86), ("麦地那",  "SA",  24.47,  39.61),
            ("马斯喀特","OM",  23.61,  58.59),
            ("巴林",    "BH",  26.21,  50.59),
            ("特拉维夫","IL",  32.08,  34.78), ("耶路撒冷","IL",  31.78,  35.22),
            ("安曼",    "JO",  31.95,  35.93), ("佩特拉",  "JO",  30.33,  35.48),
            ("瓦迪拉姆","JO",  29.57,  35.42),
            ("贝鲁特",  "LB",  33.89,  35.50),
            ("伊斯坦布尔","TR",41.01,  28.95), ("安卡拉",  "TR",  39.93,  32.86),
            ("安塔利亚","TR",  36.90,  30.70), ("卡帕多西亚","TR",38.67, 34.85),
            ("博德鲁姆","TR",  37.03,  27.43), ("伊兹密尔","TR",  38.42,  27.14),
            ("德黑兰",  "IR",  35.69,  51.39), ("伊斯法罕","IR",  32.66,  51.68),
            ("设拉子",  "IR",  29.61,  52.53),

            // ── 非洲 ────────────────────────────────────────────────────────
            ("开罗",    "EG",  30.04,  31.24), ("卢克索",  "EG",  25.69,  32.64),
            ("亚历山大","EG",  31.20,  29.92), ("阿斯旺",  "EG",  24.09,  32.90),
            ("马拉喀什","MA",  31.63,  -7.99), ("卡萨布兰卡","MA",33.59,  -7.62),
            ("非斯",    "MA",  34.04,  -5.00), ("舍夫沙万","MA",  35.17,  -5.27),
            ("拉巴特",  "MA",  34.02,  -6.84), ("阿加迪尔","MA",  30.43,  -9.60),
            ("突尼斯",  "TN",  36.82,  10.18), ("杰尔巴岛","TN",  33.87,  10.90),
            ("的黎波里","LY",  32.89,  13.18),
            ("开普敦",  "ZA", -33.93,  18.42), ("约翰内斯堡","ZA",-26.20, 28.04),
            ("德班",    "ZA", -29.86,  31.02), ("克鲁格",  "ZA", -24.00,  31.50),
            ("内罗毕",  "KE",  -1.29,  36.82), ("蒙巴萨",  "KE",  -4.05,  39.66),
            ("马赛马拉","KE",  -1.52,  35.14),
            ("坦桑尼亚","TZ",  -6.37,  34.89), ("桑给巴尔","TZ",  -6.16,  39.19),
            ("塞伦盖蒂","TZ",  -2.33,  34.83), ("乞力马扎罗","TZ",-3.07,  37.35),
            ("阿鲁沙",  "TZ",  -3.37,  36.68),
            ("亚的斯亚贝巴","ET",9.03,  38.74),
            ("拉各斯",  "NG",   6.46,   3.39), ("阿布贾",  "NG",   9.06,   7.49),
            ("达喀尔",  "SN",  14.72, -17.47),
            ("阿克拉",  "GH",   5.56,  -0.20),
            ("卢萨卡",  "ZM", -15.42,  28.28), ("利文斯顿","ZM", -17.85,  25.87),
            ("哈拉雷",  "ZW", -17.83,  31.05),
            ("卢旺达",  "RW",  -1.94,  29.87), ("基加利",  "RW",  -1.94,  30.06),
            ("马达加斯加","MG",-18.77,  46.87),

            // ── 俄罗斯/中亚 ─────────────────────────────────────────────────
            ("莫斯科",  "RU",  55.75,  37.62), ("圣彼得堡","RU",  59.94,  30.32),
            ("符拉迪沃斯托克","RU",43.12,131.90),("贝加尔湖","RU",53.50,108.17),
            ("叶卡捷琳堡","RU",56.84, 60.60),
            ("阿拉木图","KZ",  43.24,  76.89), ("努尔苏丹","KZ",  51.18,  71.45),
            ("塔什干",  "UZ",  41.30,  69.24), ("撒马尔罕","UZ",  39.65,  66.98),
            ("布哈拉",  "UZ",  39.77,  64.42),
            ("比什凯克","KG",  42.87,  74.59),
            ("杜尚别",  "TJ",  38.56,  68.77),
            ("阿什哈巴德","TM",37.95, 58.38),

            // ── 欧洲 ────────────────────────────────────────────────────────
            ("巴黎",    "FR",  48.86,   2.35), ("尼斯",    "FR",  43.71,   7.26),
            ("马赛",    "FR",  43.30,   5.37), ("里昂",    "FR",  45.75,   4.83),
            ("波尔多",  "FR",  44.84,  -0.58), ("斯特拉斯堡","FR",48.57,  7.75),
            ("蒙特卡洛","MC",  43.73,   7.42),
            ("伦敦",    "GB",  51.51,  -0.13), ("爱丁堡",  "GB",  55.95,  -3.19),
            ("曼彻斯特","GB",  53.48,  -2.24), ("利物浦",  "GB",  53.41,  -2.99),
            ("牛津",    "GB",  51.75,  -1.26), ("剑桥",    "GB",  52.21,   0.12),
            ("巴斯",    "GB",  51.38,  -2.36), ("约克",    "GB",  53.96,  -1.08),
            ("罗马",    "IT",  41.90,  12.50), ("米兰",    "IT",  45.46,   9.19),
            ("威尼斯",  "IT",  45.44,  12.33), ("佛罗伦萨","IT",  43.77,  11.25),
            ("那不勒斯","IT",  40.84,  14.25), ("西西里",  "IT",  37.60,  14.02),
            ("博洛尼亚","IT",  44.50,  11.34), ("都灵",    "IT",  45.07,   7.69),
            ("五渔村",  "IT",  44.13,   9.73), ("阿马尔菲","IT",  40.63,  14.60),
            ("马德里",  "ES",  40.42,  -3.70), ("巴塞罗那","ES",  41.39,   2.15),
            ("塞维利亚","ES",  37.39,  -5.99), ("格拉纳达","ES",  37.18,  -3.60),
            ("瓦伦西亚","ES",  39.47,  -0.38), ("毕尔巴鄂","ES",  43.26,  -2.93),
            ("马略卡岛","ES",  39.70,   2.99), ("特内里费","ES",  28.29, -16.63),
            ("柏林",    "DE",  52.52,  13.40), ("慕尼黑",  "DE",  48.14,  11.58),
            ("汉堡",    "DE",  53.55,   9.99), ("法兰克福","DE",  50.11,   8.68),
            ("科隆",    "DE",  50.94,   6.96), ("德累斯顿","DE",  51.05,  13.74),
            ("海德堡",  "DE",  49.40,   8.69), ("罗滕堡",  "DE",  49.38,  10.18),
            ("维也纳",  "AT",  48.21,  16.37), ("萨尔茨堡","AT",  47.80,  13.04),
            ("因斯布鲁克","AT",47.27,  11.39), ("哈尔施塔特","AT",47.56,13.65),
            ("苏黎世",  "CH",  47.38,   8.54), ("日内瓦",  "CH",  46.20,   6.14),
            ("伯尔尼",  "CH",  46.95,   7.45), ("琉森",    "CH",  47.05,   8.31),
            ("因特拉肯","CH",  46.69,   7.86), ("泽马特",  "CH",  46.02,   7.75),
            ("格林德瓦","CH",  46.62,   8.04),
            ("阿姆斯特丹","NL",52.37,   4.90), ("鹿特丹",  "NL",  51.92,   4.48),
            ("海牙",    "NL",  52.08,   4.31), ("乌得勒支","NL",  52.09,   5.12),
            ("布鲁塞尔","BE",  50.85,   4.35), ("布鲁日",  "BE",  51.21,   3.22),
            ("根特",    "BE",  51.05,   3.72),
            ("布拉格",  "CZ",  50.08,  14.44), ("克鲁姆洛夫","CZ",48.81, 14.32),
            ("布达佩斯","HU",  47.50,  19.04),
            ("华沙",    "PL",  52.23,  21.01), ("克拉科夫","PL",  50.06,  19.94),
            ("格但斯克","PL",  54.35,  18.65), ("弗罗茨瓦夫","PL",51.11, 17.04),
            ("雅典",    "GR",  37.98,  23.73), ("圣托里尼","GR",  36.39,  25.46),
            ("米科诺斯","GR",  37.45,  25.37), ("克里特岛","GR",  35.24,  24.81),
            ("罗德岛",  "GR",  36.44,  28.22), ("科孚岛",  "GR",  39.62,  19.92),
            ("里斯本",  "PT",  38.72,  -9.14), ("波尔图",  "PT",  41.15,  -8.61),
            ("阿尔加维","PT",  37.13,  -7.98), ("马德拉",  "PT",  32.75, -17.00),
            ("赫尔辛基","FI",  60.17,  24.94), ("罗瓦涅米","FI",  66.50,  25.72),
            ("斯德哥尔摩","SE",59.33,  18.07), ("哥德堡",  "SE",  57.71,  11.97),
            ("哥本哈根","DK",  55.68,  12.57), ("奥尔胡斯","DK",  56.16,  10.21),
            ("奥斯陆",  "NO",  59.91,  10.75), ("卑尔根",  "NO",  60.39,   5.32),
            ("特罗姆瑟","NO",  69.65,  18.96),
            ("雷克雅未克","IS",64.13, -21.94),
            ("都柏林",  "IE",  53.33,  -6.25), ("戈尔韦",  "IE",  53.27,  -9.06),
            ("萨格勒布","HR",  45.81,  15.98), ("杜布罗夫尼克","HR",42.65,18.09),
            ("斯普利特","HR",  43.51,  16.44), ("赫瓦尔岛","HR",  43.17,  16.44),
            ("布拉迪斯拉发","SK",48.15, 17.11),
            ("布加勒斯特","RO",44.44,  26.10), ("锡纳亚",  "RO",  45.35,  25.54),
            ("布拉索夫","RO",  45.65,  25.61),
            ("索菲亚",  "BG",  42.70,  23.32), ("大特尔诺沃","BG",43.08, 25.62),
            ("基辅",    "UA",  50.45,  30.52), ("利沃夫",  "UA",  49.84,  24.03),
            ("卢布尔雅那","SI",46.05,  14.51), ("布莱德",  "SI",  46.37,  14.09),
            ("斯科普里","MK",  41.99,  21.43),
            ("贝尔格莱德","RS",44.80,  20.46),
            ("萨拉热窝","BA",  43.85,  18.42),
            ("地拉那",  "AL",  41.33,  19.83),
            ("科托尔",  "ME",  42.42,  18.77),
            ("里加",    "LV",  56.95,  24.11), ("塔林",    "EE",  59.44,  24.75),
            ("维尔纽斯","LT",  54.69,  25.28),
            ("华沙",    "PL",  52.23,  21.01),
            ("卢森堡",  "LU",  49.61,   6.13),
            ("安道尔",  "AD",  42.51,   1.52),
            ("梵蒂冈",  "VA",  41.90,  12.45),
            ("摩纳哥",  "MC",  43.73,   7.42),
            ("直布罗陀","GI",  36.14,  -5.35),

            // ── 北美洲 ──────────────────────────────────────────────────────
            ("纽约",    "US",  40.71, -74.01), ("洛杉矶",  "US",  34.05,-118.24),
            ("旧金山",  "US",  37.77,-122.42), ("拉斯维加斯","US",36.17,-115.14),
            ("芝加哥",  "US",  41.88, -87.63), ("波士顿",  "US",  42.36, -71.06),
            ("西雅图",  "US",  47.61,-122.33), ("迈阿密",  "US",  25.77, -80.19),
            ("华盛顿",  "US",  38.91, -77.04), ("奥兰多",  "US",  28.54, -81.38),
            ("檀香山",  "US",  21.31,-157.86), ("夏威夷",  "US",  21.31,-157.86),
            ("纳什维尔","US",  36.17, -86.78), ("新奥尔良","US",  29.95, -90.07),
            ("丹佛",    "US",  39.74,-104.98), ("凤凰城",  "US",  33.45,-112.07),
            ("圣地亚哥","US",  32.72,-117.16), ("波特兰",  "US",  45.52,-122.68),
            ("奥斯汀",  "US",  30.27, -97.74), ("达拉斯",  "US",  32.78, -96.80),
            ("休斯顿",  "US",  29.76, -95.37), ("亚特兰大","US",  33.75, -84.39),
            ("明尼阿波利斯","US",44.98,-93.27),("圣路易斯","US",  38.63, -90.20),
            ("大峡谷",  "US",  36.10,-112.11), ("黄石",    "US",  44.43,-110.59),
            ("优胜美地","US",  37.75,-119.59), ("阿拉斯加","US",  64.20,-153.00),
            ("多伦多",  "CA",  43.65, -79.38), ("温哥华",  "CA",  49.26,-123.11),
            ("蒙特利尔","CA",  45.50, -73.57), ("班夫",    "CA",  51.18,-115.57),
            ("魁北克",  "CA",  46.81, -71.21), ("卡尔加里","CA",  51.05,-114.06),
            ("维多利亚","CA",  48.43,-123.37), ("惠斯勒",  "CA",  50.12,-122.96),
            ("尼亚加拉","CA",  43.10, -79.07),
            ("墨西哥城","MX",  19.43, -99.13), ("坎昆",    "MX",  21.16, -86.85),
            ("洛斯卡沃斯","MX",22.89,-109.92), ("瓦哈卡",  "MX",  17.07, -96.72),
            ("危地马拉城","GT",14.63,-90.51),
            ("哈瓦那",  "CU",  23.13, -82.38),
            ("圣多明各","DO",  18.47, -69.90),
            ("拿骚",    "BS",  25.05, -77.34),

            // ── 加勒比海/中美洲 ─────────────────────────────────────────────
            ("圣胡安",  "PR",  18.47, -66.11),
            ("金斯敦",  "JM",  17.99, -76.79),
            ("圣卢西亚","LC",  13.91, -60.98),
            ("巴巴多斯","BB",  13.19, -59.54),

            // ── 南美洲 ──────────────────────────────────────────────────────
            ("布宜诺斯艾利斯","AR",-34.60,-58.38),
            ("巴塔哥尼亚","AR",-45.00,-70.00), ("门多萨",  "AR", -32.89, -68.83),
            ("圣保罗",  "BR", -23.55, -46.63), ("里约",    "BR", -22.91, -43.17),
            ("里约热内卢","BR",-22.91,-43.17), ("萨尔瓦多","BR", -12.97, -38.51),
            ("福塔雷萨","BR",  -3.73, -38.52), ("马瑙斯",  "BR",  -3.10, -60.03),
            ("伊瓜苏",  "BR", -25.69, -54.44),
            ("利马",    "PE", -12.04, -77.03), ("库斯科",  "PE", -13.52, -71.97),
            ("马丘比丘","PE", -13.16, -72.54),
            ("波哥大",  "CO",   4.71, -74.07), ("卡塔赫纳","CO",  10.40, -75.52),
            ("麦德林",  "CO",   6.25, -75.57),
            ("基多",    "EC",  -0.22, -78.51), ("加拉帕戈斯","EC",-0.80,-90.97),
            ("圣地亚哥","CL", -33.46, -70.65), ("巴塔哥尼亚","CL",-51.00,-73.00),
            ("拉巴斯",  "BO", -16.50, -68.15), ("玻利维亚盐湖","BO",-20.14,-67.49),
            ("蒙得维的亚","UY",-34.91,-56.19),
            ("阿松森",  "PY", -25.28, -57.63),

            // ── 大洋洲 ──────────────────────────────────────────────────────
            ("悉尼",    "AU", -33.87, 151.21), ("墨尔本",  "AU", -37.81, 144.96),
            ("布里斯班","AU", -27.47, 153.02), ("黄金海岸","AU", -28.02, 153.40),
            ("凯恩斯",  "AU", -16.92, 145.77), ("珀斯",    "AU", -31.95, 115.86),
            ("阿德莱德","AU", -34.93, 138.60), ("达尔文",  "AU", -12.46, 130.84),
            ("乌鲁鲁",  "AU", -25.34, 131.04), ("大堡礁",  "AU", -18.29, 147.70),
            ("奥克兰",  "NZ", -36.86, 174.77), ("皇后镇",  "NZ", -45.03, 168.66),
            ("惠灵顿",  "NZ", -41.29, 174.78), ("基督城",  "NZ", -43.53, 172.64),
            ("罗托鲁瓦","NZ", -38.14, 176.25),
            ("斐济",    "FJ",  -17.71, 178.06), ("楠迪",   "FJ",  -17.78, 177.41),
            ("瓦努阿图","VU", -15.37, 166.96),
            ("大溪地",  "PF", -17.65,-149.43),
            ("马尔代夫","MV",   3.20,  73.22), ("马累",    "MV",   4.18,  73.51),
        ]

        var dict: [String: (code: String, lat: Double, lon: Double)] = [:]
        for (city, code, lat, lon) in entries {
            dict[city]                = (code, lat, lon)
            dict[city.lowercased()]   = (code, lat, lon)
        }

        // English / pinyin names (stored lowercase, already unique)
        let latin: [(String, String, Double, Double)] = [
            // East Asia
            ("beijing","CN",39.91,116.39),("shanghai","CN",31.23,121.47),
            ("guangzhou","CN",23.13,113.27),("shenzhen","CN",22.54,114.06),
            ("chengdu","CN",30.66,104.08),("hangzhou","CN",30.25,120.16),
            ("wuhan","CN",30.59,114.31),("xian","CN",34.27,108.95),
            ("xi'an","CN",34.27,108.95),("nanjing","CN",32.06,118.80),
            ("chongqing","CN",29.56,106.55),("tianjin","CN",39.13,117.20),
            ("qingdao","CN",36.07,120.37),("dalian","CN",38.91,121.60),
            ("xiamen","CN",24.48,118.09),("harbin","CN",45.75,126.63),
            ("shenyang","CN",41.81,123.43),("suzhou","CN",31.30,120.62),
            ("zhengzhou","CN",34.75,113.63),("kunming","CN",25.04,102.71),
            ("sanya","CN",18.25,109.51),("guilin","CN",25.27,110.29),
            ("lijiang","CN",26.87,100.23),("zhangjiajie","CN",29.12,110.48),
            ("jiuzhaigou","CN",33.26,103.92),("huangshan","CN",29.72,118.33),
            ("shangri-la","CN",27.83,99.71),("xishuangbanna","CN",22.01,100.80),
            ("dali","CN",25.60,100.27),("dunhuang","CN",40.14,94.66),
            ("kashgar","CN",39.47,75.98),("yili","CN",43.92,81.32),
            ("urumqi","CN",43.83,87.62),("lhasa","CN",29.65,91.13),
            ("hong kong","HK",22.40,114.11),("macau","MO",22.20,113.55),
            ("taiwan","TW",23.69,120.96),
            ("taipei","TW",25.05,121.56),("kaohsiung","TW",22.63,120.30),
            ("taichung","TW",24.15,120.67),
            ("tokyo","JP",35.69,139.69),("osaka","JP",34.69,135.50),
            ("kyoto","JP",35.01,135.77),("fukuoka","JP",33.59,130.40),
            ("sapporo","JP",43.06,141.35),("okinawa","JP",26.21,127.68),
            ("naha","JP",26.21,127.68),("nagoya","JP",35.18,136.91),
            ("yokohama","JP",35.44,139.64),("kobe","JP",34.69,135.20),
            ("nara","JP",34.68,135.83),("hiroshima","JP",34.39,132.46),
            ("sendai","JP",38.27,140.87),("nagasaki","JP",32.74,129.87),
            ("hakone","JP",35.23,139.11),("mount fuji","JP",35.36,138.73),
            ("seoul","KR",37.57,126.98),("busan","KR",35.10,129.04),
            ("jeju","KR",33.49,126.53),("incheon","KR",37.46,126.71),
            ("gyeongju","KR",35.86,129.22),
            // Southeast Asia
            ("bangkok","TH",13.75,100.52),("chiang mai","TH",18.79,98.98),
            ("phuket","TH",7.89,98.40),("pattaya","TH",12.93,100.88),
            ("koh samui","TH",9.53,99.93),("krabi","TH",8.09,98.91),
            ("hanoi","VN",21.03,105.85),("ho chi minh","VN",10.82,106.63),
            ("ho chi minh city","VN",10.82,106.63),("saigon","VN",10.82,106.63),
            ("da nang","VN",16.05,108.22),("hoi an","VN",15.88,108.34),
            ("nha trang","VN",12.24,109.19),("halong bay","VN",20.95,107.06),
            ("singapore","SG",1.35,103.82),
            ("kuala lumpur","MY",3.14,101.69),("kl","MY",3.14,101.69),
            ("penang","MY",5.41,100.33),("langkawi","MY",6.35,100.13),
            ("kota kinabalu","MY",5.98,116.07),
            ("jakarta","ID",-6.21,106.85),("bali","ID",-8.34,115.09),
            ("yogyakarta","ID",-7.80,110.36),("lombok","ID",-8.57,116.35),
            ("komodo","ID",-8.55,119.49),
            ("manila","PH",14.60,120.98),("cebu","PH",10.32,123.89),
            ("boracay","PH",11.96,121.92),("palawan","PH",9.84,118.74),
            ("yangon","MM",16.87,96.19),("bagan","MM",21.17,94.86),
            ("mandalay","MM",21.97,96.08),
            ("phnom penh","KH",11.56,104.92),("siem reap","KH",13.36,103.86),
            ("angkor","KH",13.41,103.87),
            ("vientiane","LA",17.97,102.60),("luang prabang","LA",19.89,102.14),
            ("colombo","LK",6.93,79.85),("kandy","LK",7.29,80.63),
            ("kathmandu","NP",27.72,85.32),("pokhara","NP",28.21,83.99),
            ("dhaka","BD",23.81,90.41),
            // South Asia
            ("mumbai","IN",19.08,72.88),("new delhi","IN",28.61,77.21),
            ("delhi","IN",28.61,77.21),("bangalore","IN",12.97,77.59),
            ("bengaluru","IN",12.97,77.59),("chennai","IN",13.08,80.27),
            ("kolkata","IN",22.57,88.36),("hyderabad","IN",17.39,78.49),
            ("jaipur","IN",26.91,75.79),("agra","IN",27.18,78.01),
            ("varanasi","IN",25.32,83.01),("goa","IN",15.30,74.08),
            ("udaipur","IN",24.57,73.68),
            ("islamabad","PK",33.72,73.04),("karachi","PK",24.86,67.01),
            ("lahore","PK",31.55,74.34),
            // Middle East
            ("dubai","AE",25.20,55.27),("abu dhabi","AE",24.47,54.37),
            ("doha","QA",25.29,51.53),
            ("riyadh","SA",24.69,46.72),("jeddah","SA",21.49,39.19),
            ("mecca","SA",21.39,39.86),
            ("muscat","OM",23.61,58.59),
            ("tel aviv","IL",32.08,34.78),("jerusalem","IL",31.78,35.22),
            ("amman","JO",31.95,35.93),("petra","JO",30.33,35.48),
            ("beirut","LB",33.89,35.50),
            ("istanbul","TR",41.01,28.95),("ankara","TR",39.93,32.86),
            ("antalya","TR",36.90,30.70),("cappadocia","TR",38.67,34.85),
            ("bodrum","TR",37.03,27.43),
            ("tehran","IR",35.69,51.39),("isfahan","IR",32.66,51.68),
            // Africa
            ("cairo","EG",30.04,31.24),("luxor","EG",25.69,32.64),
            ("alexandria","EG",31.20,29.92),("aswan","EG",24.09,32.90),
            ("marrakech","MA",31.63,-7.99),("marrakesh","MA",31.63,-7.99),
            ("casablanca","MA",33.59,-7.62),("fez","MA",34.04,-5.00),
            ("chefchaouen","MA",35.17,-5.27),("rabat","MA",34.02,-6.84),
            ("cape town","ZA",-33.93,18.42),("johannesburg","ZA",-26.20,28.04),
            ("durban","ZA",-29.86,31.02),
            ("nairobi","KE",-1.29,36.82),("mombasa","KE",-4.05,39.66),
            ("masai mara","KE",-1.52,35.14),
            ("zanzibar","TZ",-6.16,39.19),("serengeti","TZ",-2.33,34.83),
            ("kilimanjaro","TZ",-3.07,37.35),
            ("addis ababa","ET",9.03,38.74),
            ("lagos","NG",6.46,3.39),("abuja","NG",9.06,7.49),
            ("dakar","SN",14.72,-17.47),("accra","GH",5.56,-0.20),
            ("lusaka","ZM",-15.42,28.28),("livingstone","ZM",-17.85,25.87),
            ("kigali","RW",-1.94,30.06),
            // Russia / Central Asia
            ("moscow","RU",55.75,37.62),("saint petersburg","RU",59.94,30.32),
            ("st petersburg","RU",59.94,30.32),("st. petersburg","RU",59.94,30.32),
            ("lake baikal","RU",53.50,108.17),
            ("almaty","KZ",43.24,76.89),("nur-sultan","KZ",51.18,71.45),
            ("astana","KZ",51.18,71.45),
            ("tashkent","UZ",41.30,69.24),("samarkand","UZ",39.65,66.98),
            ("bukhara","UZ",39.77,64.42),
            // Europe
            ("paris","FR",48.86,2.35),("nice","FR",43.71,7.26),
            ("lyon","FR",45.75,4.83),("marseille","FR",43.30,5.37),
            ("bordeaux","FR",44.84,-0.58),("strasbourg","FR",48.57,7.75),
            ("london","GB",51.51,-0.13),("edinburgh","GB",55.95,-3.19),
            ("manchester","GB",53.48,-2.24),("liverpool","GB",53.41,-2.99),
            ("oxford","GB",51.75,-1.26),("cambridge","GB",52.21,0.12),
            ("bath","GB",51.38,-2.36),
            ("rome","IT",41.90,12.50),("milan","IT",45.46,9.19),
            ("venice","IT",45.44,12.33),("florence","IT",43.77,11.25),
            ("naples","IT",40.84,14.25),("sicily","IT",37.60,14.02),
            ("bologna","IT",44.50,11.34),("turin","IT",45.07,7.69),
            ("cinque terre","IT",44.13,9.73),("amalfi","IT",40.63,14.60),
            ("madrid","ES",40.42,-3.70),("barcelona","ES",41.39,2.15),
            ("seville","ES",37.39,-5.99),("granada","ES",37.18,-3.60),
            ("valencia","ES",39.47,-0.38),("bilbao","ES",43.26,-2.93),
            ("mallorca","ES",39.70,2.99),("majorca","ES",39.70,2.99),
            ("ibiza","ES",38.91,1.43),("tenerife","ES",28.29,-16.63),
            ("berlin","DE",52.52,13.40),("munich","DE",48.14,11.58),
            ("hamburg","DE",53.55,9.99),("frankfurt","DE",50.11,8.68),
            ("cologne","DE",50.94,6.96),("dresden","DE",51.05,13.74),
            ("heidelberg","DE",49.40,8.69),("rothenburg","DE",49.38,10.18),
            ("vienna","AT",48.21,16.37),("salzburg","AT",47.80,13.04),
            ("innsbruck","AT",47.27,11.39),("hallstatt","AT",47.56,13.65),
            ("zurich","CH",47.38,8.54),("geneva","CH",46.20,6.14),
            ("bern","CH",46.95,7.45),("lucerne","CH",47.05,8.31),
            ("interlaken","CH",46.69,7.86),("zermatt","CH",46.02,7.75),
            ("grindelwald","CH",46.62,8.04),
            ("amsterdam","NL",52.37,4.90),("rotterdam","NL",51.92,4.48),
            ("the hague","NL",52.08,4.31),("utrecht","NL",52.09,5.12),
            ("brussels","BE",50.85,4.35),("bruges","BE",51.21,3.22),
            ("ghent","BE",51.05,3.72),
            ("prague","CZ",50.08,14.44),("cesky krumlov","CZ",48.81,14.32),
            ("budapest","HU",47.50,19.04),
            ("warsaw","PL",52.23,21.01),("krakow","PL",50.06,19.94),
            ("gdansk","PL",54.35,18.65),("wroclaw","PL",51.11,17.04),
            ("athens","GR",37.98,23.73),("santorini","GR",36.39,25.46),
            ("mykonos","GR",37.45,25.37),("crete","GR",35.24,24.81),
            ("rhodes","GR",36.44,28.22),("corfu","GR",39.62,19.92),
            ("lisbon","PT",38.72,-9.14),("porto","PT",41.15,-8.61),
            ("algarve","PT",37.13,-7.98),("madeira","PT",32.75,-17.00),
            ("helsinki","FI",60.17,24.94),("rovaniemi","FI",66.50,25.72),
            ("stockholm","SE",59.33,18.07),("gothenburg","SE",57.71,11.97),
            ("copenhagen","DK",55.68,12.57),
            ("oslo","NO",59.91,10.75),("bergen","NO",60.39,5.32),
            ("tromso","NO",69.65,18.96),("tromsø","NO",69.65,18.96),
            ("reykjavik","IS",64.13,-21.94),
            ("dublin","IE",53.33,-6.25),("galway","IE",53.27,-9.06),
            ("zagreb","HR",45.81,15.98),("dubrovnik","HR",42.65,18.09),
            ("split","HR",43.51,16.44),("hvar","HR",43.17,16.44),
            ("bratislava","SK",48.15,17.11),
            ("bucharest","RO",44.44,26.10),("brasov","RO",45.65,25.61),
            ("sofia","BG",42.70,23.32),
            ("kyiv","UA",50.45,30.52),("kiev","UA",50.45,30.52),
            ("lviv","UA",49.84,24.03),
            ("ljubljana","SI",46.05,14.51),("bled","SI",46.37,14.09),
            ("skopje","MK",41.99,21.43),
            ("belgrade","RS",44.80,20.46),("sarajevo","BA",43.85,18.42),
            ("tirana","AL",41.33,19.83),("kotor","ME",42.42,18.77),
            ("riga","LV",56.95,24.11),("tallinn","EE",59.44,24.75),
            ("vilnius","LT",54.69,25.28),("luxembourg","LU",49.61,6.13),
            ("monaco","MC",43.73,7.42),("andorra","AD",42.51,1.52),
            ("monte carlo","MC",43.73,7.42),
            // Americas
            ("new york","US",40.71,-74.01),("los angeles","US",34.05,-118.24),
            ("san francisco","US",37.77,-122.42),("las vegas","US",36.17,-115.14),
            ("chicago","US",41.88,-87.63),("boston","US",42.36,-71.06),
            ("seattle","US",47.61,-122.33),("miami","US",25.77,-80.19),
            ("washington","US",38.91,-77.04),("orlando","US",28.54,-81.38),
            ("honolulu","US",21.31,-157.86),("hawaii","US",21.31,-157.86),
            ("nashville","US",36.17,-86.78),("new orleans","US",29.95,-90.07),
            ("denver","US",39.74,-104.98),("phoenix","US",33.45,-112.07),
            ("san diego","US",32.72,-117.16),("portland","US",45.52,-122.68),
            ("austin","US",30.27,-97.74),("dallas","US",32.78,-96.80),
            ("houston","US",29.76,-95.37),("atlanta","US",33.75,-84.39),
            ("grand canyon","US",36.10,-112.11),("yellowstone","US",44.43,-110.59),
            ("yosemite","US",37.75,-119.59),("alaska","US",64.20,-153.00),
            ("toronto","CA",43.65,-79.38),("vancouver","CA",49.26,-123.11),
            ("montreal","CA",45.50,-73.57),("banff","CA",51.18,-115.57),
            ("quebec","CA",46.81,-71.21),("calgary","CA",51.05,-114.06),
            ("victoria","CA",48.43,-123.37),("whistler","CA",50.12,-122.96),
            ("niagara falls","CA",43.10,-79.07),
            ("mexico city","MX",19.43,-99.13),("cancun","MX",21.16,-86.85),
            ("cabo","MX",22.89,-109.92),("oaxaca","MX",17.07,-96.72),
            ("havana","CU",23.13,-82.38),("santo domingo","DO",18.47,-69.90),
            ("nassau","BS",25.05,-77.34),
            ("buenos aires","AR",-34.60,-58.38),("patagonia","AR",-45.00,-70.00),
            ("mendoza","AR",-32.89,-68.83),
            ("sao paulo","BR",-23.55,-46.63),("rio de janeiro","BR",-22.91,-43.17),
            ("rio","BR",-22.91,-43.17),("salvador","BR",-12.97,-38.51),
            ("manaus","BR",-3.10,-60.03),("iguazu","BR",-25.69,-54.44),
            ("lima","PE",-12.04,-77.03),("cusco","PE",-13.52,-71.97),
            ("machu picchu","PE",-13.16,-72.54),
            ("bogota","CO",4.71,-74.07),("cartagena","CO",10.40,-75.52),
            ("medellin","CO",6.25,-75.57),
            ("quito","EC",-0.22,-78.51),("galapagos","EC",-0.80,-90.97),
            ("santiago","CL",-33.46,-70.65),
            ("la paz","BO",-16.50,-68.15),("bolivian salt flats","BO",-20.14,-67.49),
            ("montevideo","UY",-34.91,-56.19),
            // Oceania
            ("sydney","AU",-33.87,151.21),("melbourne","AU",-37.81,144.96),
            ("brisbane","AU",-27.47,153.02),("gold coast","AU",-28.02,153.40),
            ("cairns","AU",-16.92,145.77),("perth","AU",-31.95,115.86),
            ("adelaide","AU",-34.93,138.60),("darwin","AU",-12.46,130.84),
            ("uluru","AU",-25.34,131.04),("great barrier reef","AU",-18.29,147.70),
            ("auckland","NZ",-36.86,174.77),("queenstown","NZ",-45.03,168.66),
            ("wellington","NZ",-41.29,174.78),("christchurch","NZ",-43.53,172.64),
            ("rotorua","NZ",-38.14,176.25),
            ("fiji","FJ",-17.71,178.06),("nadi","FJ",-17.78,177.41),
            ("tahiti","PF",-17.65,-149.43),
            ("maldives","MV",3.20,73.22),("male","MV",4.18,73.51),
        ]
        for (city, code, lat, lon) in latin {
            dict[city] = (code, lat, lon)
        }

        // zh-Hant / 台港用语别名 → 复用已有规范条目（坐标保持单一来源）。
        // 覆盖两类：①简繁字形差异（東京/橫濱）②台港不同译名（雪梨/杜拜/巴塞隆納）。
        // 只收录与简体写法「确实不同」的目的地；简繁同形的（香港、台北、曼谷等）已在上方表中，无需重复。
        // 非穷举：本地未覆盖的繁体输入仍由 CLGeocoder 兜底。
        let hantAliases: [(alias: String, canonical: String)] = [
            // 东亚（字形差异）
            ("東京","东京"), ("沖繩","冲绳"), ("橫濱","横滨"), ("廣島","广岛"),
            ("神戶","神户"), ("福岡","福冈"), ("長崎","长崎"), ("輕井澤","轻井泽"),
            ("鎌倉","镰仓"), ("首爾","首尔"), ("濟州島","济州岛"), ("慶州","庆州"),
            // 东南亚 / 南亚（字形差异 + 台港译名）
            ("清邁","清迈"), ("普吉島","普吉岛"), ("蘇梅島","苏梅岛"), ("芭達雅","芭提雅"),
            ("河內","河内"), ("峴港","岘港"), ("會安","会安"), ("順化","顺化"),
            ("富國島","富国岛"), ("檳城","槟城"), ("馬六甲","马六甲"), ("雅加達","雅加达"),
            ("峇里島","巴厘岛"), ("馬尼拉","马尼拉"), ("宿霧","宿务"), ("長灘島","长滩岛"),
            ("吳哥","吴哥"), ("萬象","万象"), ("科倫坡","科伦坡"), ("加德滿都","加德满都"),
            ("孟買","孟买"), ("班加羅爾","班加罗尔"), ("加爾各答","加尔各答"), ("齋浦爾","斋浦尔"),
            // 中东 / 非洲（字形差异 + 台港译名）
            ("杜拜","迪拜"), ("阿布達比","阿布扎比"), ("麥加","麦加"),
            ("開羅","开罗"), ("卡薩布蘭卡","卡萨布兰卡"), ("開普敦","开普敦"),
            // 欧洲（字形差异）
            ("馬賽","马赛"), ("倫敦","伦敦"), ("愛丁堡","爱丁堡"), ("曼徹斯特","曼彻斯特"),
            ("劍橋","剑桥"), ("羅馬","罗马"), ("米蘭","米兰"), ("維也納","维也纳"),
            ("蘇黎世","苏黎世"), ("日內瓦","日内瓦"), ("漢堡","汉堡"), ("法蘭克福","法兰克福"),
            ("布魯塞爾","布鲁塞尔"), ("布達佩斯","布达佩斯"), ("華沙","华沙"),
            ("聖托里尼","圣托里尼"), ("赫爾辛基","赫尔辛基"), ("斯德哥爾摩","斯德哥尔摩"),
            ("奧斯陸","奥斯陆"), ("聖彼得堡","圣彼得堡"),
            // 欧洲（台港不同译名）
            ("巴塞隆納","巴塞罗那"), ("佛羅倫斯","佛罗伦萨"), ("拿坡里","那不勒斯"), ("塞維亞","塞维利亚"),
            // 美洲（字形差异 + 台港译名）
            ("紐約","纽约"), ("洛杉磯","洛杉矶"), ("舊金山","旧金山"), ("波士頓","波士顿"),
            ("西雅圖","西雅图"), ("邁阿密","迈阿密"), ("華盛頓","华盛顿"), ("多倫多","多伦多"),
            ("溫哥華","温哥华"), ("蒙特婁","蒙特利尔"), ("聖保羅","圣保罗"), ("里約","里约"),
            ("庫斯科","库斯科"),
            // 大洋洲（字形差异 + 台港译名）
            ("雪梨","悉尼"), ("墨爾本","墨尔本"), ("布里斯本","布里斯班"), ("黃金海岸","黄金海岸"),
            ("凱恩斯","凯恩斯"), ("奧克蘭","奥克兰"), ("皇后鎮","皇后镇"), ("威靈頓","惠灵顿"),
            ("斐濟","斐济"), ("馬爾地夫","马尔代夫"),
        ]
        for (alias, canonical) in hantAliases where dict[alias] == nil {
            if let r = dict[canonical] { dict[alias] = r }
        }

        return dict
    }()

    /// Chinese country/region keywords → (code, lat, lon).
    /// Used to resolve compound inputs like "泰国曼谷" or "意大利罗马" when
    /// the exact city name isn't in cityLookup.
    private static let countryKeywords: [(keyword: String, code: String, lat: Double, lon: Double)] = [
        // sorted longest-first so "澳大利亚" matches before "澳"
        ("澳大利亚","AU",-25.27,133.78), ("新西兰",  "NZ",-40.90,174.89),
        ("新加坡",  "SG",  1.35,103.82), ("菲律宾",  "PH", 12.88,121.77),
        ("印度尼西亚","ID",-0.79,113.92),("马来西亚","MY",  4.21,108.10),
        ("越南",    "VN", 14.06,108.28), ("泰国",    "TH", 15.87,100.99),
        ("缅甸",    "MM", 16.87, 96.19), ("柬埔寨",  "KH", 12.57,104.99),
        ("老挝",    "LA", 17.96,102.60), ("斯里兰卡","LK",  7.87, 80.77),
        ("尼泊尔",  "NP", 28.39, 84.12), ("孟加拉国","BD", 23.68, 90.36),
        ("巴基斯坦","PK", 30.38, 69.35), ("印度",    "IN", 20.59, 78.96),
        ("日本",    "JP", 36.20,138.25), ("韩国",    "KR", 35.91,127.77),
        ("朝鲜",    "KP", 40.34,127.51), ("蒙古",    "MN", 46.86,103.85),
        ("哈萨克斯坦","KZ",48.02,66.92),("乌兹别克斯坦","UZ",41.38,63.97),
        ("吉尔吉斯斯坦","KG",41.20,74.77),
        ("土库曼斯坦","TM",38.97,59.56),("塔吉克斯坦","TJ",38.86,71.28),
        ("阿富汗",  "AF", 33.93, 67.71),
        ("伊朗",    "IR", 32.43, 53.69), ("伊拉克",  "IQ", 33.22, 43.68),
        ("叙利亚",  "SY", 34.80, 38.99), ("黎巴嫩",  "LB", 33.85, 35.86),
        ("约旦",    "JO", 30.59, 36.24), ("以色列",  "IL", 31.05, 34.85),
        ("沙特阿拉伯","SA",23.89,45.08),("也门",    "YE", 15.55, 48.52),
        ("阿联酋",  "AE", 23.42, 53.85), ("卡塔尔",  "QA", 25.35, 51.18),
        ("科威特",  "KW", 29.31, 47.48), ("巴林",    "BH", 26.21, 50.59),
        ("阿曼",    "OM", 21.51, 55.92), ("土耳其",  "TR", 38.96, 35.24),
        ("俄罗斯",  "RU", 61.52,105.32), ("乌克兰",  "UA", 48.38, 31.17),
        ("白俄罗斯","BY", 53.71, 27.95), ("摩尔多瓦","MD", 47.41, 28.37),
        ("格鲁吉亚","GE", 42.32, 43.36), ("亚美尼亚","AM", 40.07, 45.04),
        ("阿塞拜疆","AZ", 40.14, 47.58),
        ("法国",    "FR", 46.23,  2.21), ("英国",    "GB", 55.38, -3.44),
        ("德国",    "DE", 51.17, 10.45), ("意大利",  "IT", 41.87, 12.57),
        ("西班牙",  "ES", 40.46, -3.75), ("葡萄牙",  "PT", 39.40, -8.22),
        ("荷兰",    "NL", 52.13,  5.29), ("比利时",  "BE", 50.50,  4.47),
        ("瑞士",    "CH", 46.82,  8.23), ("奥地利",  "AT", 47.52, 14.55),
        ("希腊",    "GR", 39.07, 21.82), ("捷克",    "CZ", 49.82, 15.47),
        ("匈牙利",  "HU", 47.16, 19.50), ("波兰",    "PL", 51.92, 19.15),
        ("罗马尼亚","RO", 45.94, 24.97), ("保加利亚","BG", 42.73, 25.49),
        ("克罗地亚","HR", 45.10, 15.20), ("斯洛文尼亚","SI",46.15,14.99),
        ("塞尔维亚","RS", 44.02, 21.01), ("黑山",    "ME", 42.71, 19.37),
        ("北马其顿","MK", 41.61, 21.75), ("波黑",    "BA", 43.92, 17.68),
        ("阿尔巴尼亚","AL",41.15,20.17),("科索沃",  "XK", 42.60, 20.90),
        ("斯洛伐克","SK", 48.67, 19.70), ("挪威",    "NO", 60.47,  8.47),
        ("瑞典",    "SE", 60.13, 18.64), ("丹麦",    "DK", 56.26,  9.50),
        ("芬兰",    "FI", 61.92, 25.75), ("冰岛",    "IS", 64.96,-19.02),
        ("爱尔兰",  "IE", 53.41, -8.24), ("苏格兰",  "GB", 56.49, -4.20),
        ("埃及",    "EG", 26.82, 30.80), ("摩洛哥",  "MA", 31.79, -7.09),
        ("突尼斯",  "TN", 33.89,  9.54), ("阿尔及利亚","DZ",28.03, 1.66),
        ("利比亚",  "LY", 26.34, 17.23), ("埃塞俄比亚","ET",9.15, 40.49),
        ("肯尼亚",  "KE", -0.02, 37.91), ("坦桑尼亚","TZ", -6.37, 34.89),
        ("南非",    "ZA",-30.56, 22.94), ("尼日利亚","NG",  9.08,  8.68),
        ("加纳",    "GH",  7.95, -1.02), ("塞内加尔","SN", 14.50,-14.45),
        ("卢旺达",  "RW", -1.94, 29.87), ("津巴布韦","ZW",-19.02, 29.15),
        ("赞比亚",  "ZM",-13.13, 27.85), ("莫桑比克","MZ",-18.67, 35.53),
        ("马达加斯加","MG",-18.77,46.87),("坦桑尼亚","TZ", -6.37, 34.89),
        ("美国",    "US", 37.09,-95.71), ("加拿大",  "CA", 56.13,-106.35),
        ("墨西哥",  "MX", 23.63,-102.55),("古巴",    "CU", 21.52,-77.78),
        ("巴西",    "BR",-14.24,-51.93), ("阿根廷",  "AR",-38.42,-63.62),
        ("智利",    "CL",-35.68,-71.54), ("秘鲁",    "PE", -9.19,-75.02),
        ("哥伦比亚","CO",  4.57,-74.30), ("厄瓜多尔","EC", -1.83,-78.18),
        ("玻利维亚","BO",-16.29,-63.59), ("乌拉圭",  "UY",-32.52,-55.77),
        ("巴拉圭",  "PY",-23.44,-58.44), ("委内瑞拉","VE",  6.42,-66.59),
        ("斐济",    "FJ",-17.71,178.06), ("马尔代夫","MV",  3.20, 73.22),
        ("大溪地",  "PF",-17.65,-149.43),("夏威夷",  "US", 21.31,-157.86),
        // 中国省份/地区关键词 (handles "新疆伊犁", "西藏拉萨" etc.)
        ("新疆",    "CN", 43.45, 85.00), ("西藏",    "CN", 31.00, 88.00),
        ("内蒙古",  "CN", 44.09,113.95), ("广西",    "CN", 23.73,108.90),
        ("宁夏",    "CN", 37.20,106.20), ("青海",    "CN", 35.74, 96.40),
        ("甘肃",    "CN", 36.06,103.83), ("云南",    "CN", 24.97,101.49),
        ("贵州",    "CN", 26.82,106.87), ("四川",    "CN", 30.66,103.00),
        ("西藏",    "CN", 31.00, 88.00), ("海南",    "CN", 20.04,110.32),
        ("黑龙江",  "CN", 45.75,126.64), ("吉林",    "CN", 43.88,125.32),
        ("辽宁",    "CN", 41.81,123.43), ("山东",    "CN", 36.67,117.00),
        ("河南",    "CN", 34.75,113.63), ("湖北",    "CN", 30.59,114.31),
        ("湖南",    "CN", 28.23,112.94), ("江西",    "CN", 28.69,115.86),
        ("安徽",    "CN", 31.86,117.28), ("福建",    "CN", 26.08,119.30),
        ("浙江",    "CN", 30.25,120.16), ("江苏",    "CN", 32.06,118.76),
        ("山西",    "CN", 37.87,112.55), ("河北",    "CN", 38.05,114.48),
        ("陕西",    "CN", 34.27,108.95), ("中国",    "CN", 35.86,104.20),
        ("台湾",    "TW", 23.69,120.96), ("台灣",    "TW", 23.69,120.96),
        // zh-Hant / 台港国家·地区关键词（longest-first；坐标复用上方简体质心）
        ("印度尼西亞","ID",-0.79,113.92),("澳大利亞","AU",-25.27,133.78),
        ("馬來西亞","MY",  4.21,108.10),("斯里蘭卡","LK",  7.87, 80.77),
        ("馬爾地夫","MV",  3.20, 73.22),("菲律賓",  "PH", 12.88,121.77),
        ("紐西蘭",  "NZ",-40.90,174.89),("尼泊爾",  "NP", 28.39, 84.12),
        ("義大利",  "IT", 41.87, 12.57),("寮國",    "LA", 17.96,102.60),
        ("緬甸",    "MM", 16.87, 96.19),("韓國",    "KR", 35.91,127.77),
        ("俄羅斯",  "RU", 61.52,105.32),("烏克蘭",  "UA", 48.38, 31.17),
        ("德國",    "DE", 51.17, 10.45),("法國",    "FR", 46.23,  2.21),
        ("英國",    "GB", 55.38, -3.44),("美國",    "US", 37.09,-95.71),
        ("希臘",    "GR", 39.07, 21.82),("肯亞",    "KE", -0.02, 37.91),
        ("斐濟",    "FJ",-17.71,178.06),("澳洲",    "AU",-25.27,133.78),
        ("印尼",    "ID", -0.79,113.92),
    ]

    // MARK: - Multi-city splitting

    /// Splits a free-form destination string into individual city tokens.
    /// Handles: comma variants, slash, ampersand, plus, " and ", " 和 ".
    /// Deliberately avoids splitting on bare "和" to protect city names like "和田".
    private func splitCities(_ input: String) -> [String] {
        var tokens = [input]
        // Multi-char separators first (order matters)
        for sep in [" and ", " And ", " AND ", " 和 "] {
            tokens = tokens.flatMap { $0.components(separatedBy: sep) }
        }
        // Single-char separators
        for sep in [",", "，", "、", "/", "／", "&", "＆", "+", "＋"] {
            tokens = tokens.flatMap { $0.components(separatedBy: sep) }
        }
        return tokens
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
    }

    private func lookupCity(_ city: String) -> (code: String, lat: Double, lon: Double)? {
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }

        // 1. Exact match (original case or lowercased)
        if let r = Self.cityLookup[trimmed] ?? Self.cityLookup[trimmed.lowercased()] {
            return r
        }

        // 2. Country/province keyword prefix: handles "泰国曼谷", "新疆伊犁", "意大利罗马" etc.
        for entry in Self.countryKeywords where trimmed.contains(entry.keyword) {
            let remainder = trimmed
                .replacingOccurrences(of: entry.keyword, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // If the remaining part is a known city, use city coords for precision
            if !remainder.isEmpty,
               let cityResult = Self.cityLookup[remainder] ?? Self.cityLookup[remainder.lowercased()] {
                return cityResult
            }
            // Otherwise fall back to country/province centroid
            return (entry.code, entry.lat, entry.lon)
        }

        return nil
    }

    // MARK: - Country centroids

    /// Synchronously infers isInternational from the local city table.
    /// Returns nil if the city can't be resolved (geocoding still needed).
    /// Used to avoid showing Passport for domestic trips before geocoding completes.
    func inferIsInternational(for city: String) -> Bool? {
        let home = homeCountryCode
        let codes = inferCountryCodes(for: city).map { $0.uppercased() }
        guard !codes.isEmpty else { return nil }
        return codes.contains(where: { $0 != home })
    }

    /// Synchronously resolves destination city to country codes using the local city table.
    /// Returns an empty array if the city can't be resolved.
    func inferCountryCodes(for city: String) -> [String] {
        let tokens = splitCities(city)
        return tokens.compactMap { lookupCity($0)?.code }
    }

    /// Approximate country centroids used as a fallback when CLGeocoder returns
    /// a valid isoCountryCode but a nil CLLocation (can happen for broad queries).

    func updateCountryCode(for tripId: UUID, city: String) {
        let tokens = splitCities(city)
        guard !tokens.isEmpty else { return }

        // Fast path: every token resolves from local table, no network needed.
        let localResults = tokens.compactMap { lookupCity($0) }
        if localResults.count == tokens.count {
            guard let bundle = bundle(for: tripId) else { return }
            bundle.countryCode = localResults[0].code
            bundle.latitude    = localResults[0].lat
            bundle.longitude   = localResults[0].lon
            bundle.additionalDestinations = localResults.dropFirst().map {
                DestinationEntry(countryCode: $0.code, latitude: $0.lat, longitude: $0.lon)
            }
            do { try context.save() } catch {
                CarryLogger.shared.log(.persistFailed, context: "caller=updateCountryCode")
            }
            CarryLogger.shared.log(.geocodeResolved,
                context: "tokens=\(tokens.count) resolved=\(localResults.count) city=\(city)")
            return
        }

        // Slow path: at least one token needs CLGeocoder.
        Task {
            let geocoder = CLGeocoder()
            var resolved: [(code: String, lat: Double, lon: Double)] = []
            var geocodedCount = 0

            for token in tokens {
                // Try local lookup first (instant, no network)
                if let local = lookupCity(token) {
                    resolved.append((local.code, local.lat, local.lon))
                    continue
                }
                // Rate limit: respect CLGeocoder's ~1 req/s recommendation
                if geocodedCount > 0 { try? await Task.sleep(for: .milliseconds(400)) }
                geocodedCount += 1
                guard let placemark = try? await geocoder.geocodeAddressString(token).first else {
                    await MainActor.run {
                        #if DEBUG
                        CarryLogger.shared.log(.geocodeFailed, context: "city=\(token)")
                        #else
                        CarryLogger.shared.log(.geocodeFailed, context: "city_len=\(token.count)")
                        #endif
                    }
                    continue
                }
                let code = placemark.isoCountryCode ?? ""
                if let loc = placemark.location, loc.coordinate.latitude != 0 {
                    resolved.append((code, loc.coordinate.latitude, loc.coordinate.longitude))
                } else if !code.isEmpty, let centroid = GeocodingData.countryCentroid(for: code) {
                    resolved.append((code, centroid.lat, centroid.lon))
                }
            }

            guard !resolved.isEmpty else { return }
            await MainActor.run {
                guard let bundle = self.bundle(for: tripId) else { return }
                bundle.countryCode = resolved[0].code
                bundle.latitude    = resolved[0].lat
                bundle.longitude   = resolved[0].lon
                bundle.additionalDestinations = Array(resolved.dropFirst()).map {
                    DestinationEntry(countryCode: $0.code, latitude: $0.lat, longitude: $0.lon)
                }
                do { try self.context.save() } catch {
                    CarryLogger.shared.log(.persistFailed, context: "caller=updateCountryCode_async")
                }
                CarryLogger.shared.log(.geocodeResolved,
                    context: "tokens=\(tokens.count) resolved=\(resolved.count) city=\(city)")
            }
        }
    }

    /// Corrects trips whose countryCode / coordinates were set incorrectly by
    /// an old CLGeocoder call. Uses the local city lookup table as the source
    /// of truth: if the table disagrees with the stored countryCode, overwrite.
    func correctMisgecodedTrips() {
        var changed = false
        for trip in trips {
            guard !trip.destinationCity.isEmpty else { continue }
            let tokens = splitCities(trip.destinationCity)
            guard let primaryToken = tokens.first,
                  let local = lookupCity(primaryToken),
                  trip.countryCode.uppercased() != local.code.uppercased() else { continue }
            trip.countryCode = local.code
            trip.latitude    = local.lat
            trip.longitude   = local.lon
            trip.additionalDestinations = tokens.dropFirst().compactMap { token in
                guard let r = lookupCity(token) else { return nil }
                return DestinationEntry(countryCode: r.code, latitude: r.lat, longitude: r.lon)
            }
            changed = true
        }
        if changed {
            do { try context.save() } catch {
                CarryLogger.shared.log(.persistFailed, context: "caller=correctMisgecodedTrips")
            }
            fetchTrips()
        }
    }

    func geocodeMissingTrips() {
        // Re-geocode if countryCode is missing OR if coordinates are still zero.
        // The second condition catches the case where a previous geocode call
        // resolved isoCountryCode but returned a nil location, leaving latitude = 0
        // and permanently hiding the country from the map.
        let missing = trips.filter {
            !$0.destinationCity.isEmpty && ($0.countryCode.isEmpty || $0.latitude == 0)
        }
        // Also pick up multi-destination trips whose extras haven't been resolved yet.
        let missingExtras = trips.filter {
            !$0.destinationCity.isEmpty &&
            !$0.countryCode.isEmpty &&
            $0.latitude != 0 &&
            $0.additionalDestinationsData.isEmpty &&
            splitCities($0.destinationCity).count > 1
        }

        guard !missing.isEmpty || !missingExtras.isEmpty else { return }

        Task {
            let geocoder = CLGeocoder()
            var geocodedCount = 0

            // Helper: geocode a single token with rate limiting
            func geocodeToken(_ token: String) async -> (code: String, lat: Double, lon: Double)? {
                if geocodedCount > 0 { try? await Task.sleep(for: .milliseconds(400)) }
                geocodedCount += 1
                guard let placemark = try? await geocoder.geocodeAddressString(token).first else {
                    await MainActor.run {
                        #if DEBUG
                        CarryLogger.shared.log(.geocodeFailed, context: "city=\(token)")
                        #else
                        CarryLogger.shared.log(.geocodeFailed, context: "city_len=\(token.count)")
                        #endif
                    }
                    return nil
                }
                let code = placemark.isoCountryCode ?? ""
                if let loc = placemark.location, loc.coordinate.latitude != 0 {
                    return (code, loc.coordinate.latitude, loc.coordinate.longitude)
                } else if !code.isEmpty, let centroid = GeocodingData.countryCentroid(for: code) {
                    return (code, centroid.lat, centroid.lon)
                }
                return nil
            }

            // 1. Trips with no primary country resolved yet
            for trip in missing {
                let tokens = splitCities(trip.destinationCity)
                guard let primaryToken = tokens.first else { continue }

                // Try local table first
                if let local = lookupCity(primaryToken) {
                    let extras = tokens.dropFirst().compactMap { token -> DestinationEntry? in
                        guard let r = lookupCity(token) else { return nil }
                        return DestinationEntry(countryCode: r.code, latitude: r.lat, longitude: r.lon)
                    }
                    await MainActor.run {
                        guard let bundle = self.bundle(for: trip.id) else { return }
                        bundle.countryCode = local.code
                        bundle.latitude    = local.lat
                        bundle.longitude   = local.lon
                        bundle.additionalDestinations = extras
                        do { try self.context.save() } catch {
                            CarryLogger.shared.log(.persistFailed, context: "caller=geocodeMissingTrips_local")
                        }
                    }
                    continue
                }

                // Fall back to CLGeocoder for primary
                guard let primary = await geocodeToken(primaryToken) else { continue }

                // Resolve extras (local then geocoder)
                var extras: [DestinationEntry] = []
                for token in tokens.dropFirst() {
                    if let r = lookupCity(token) {
                        extras.append(DestinationEntry(countryCode: r.code, latitude: r.lat, longitude: r.lon))
                    } else if let r = await geocodeToken(token) {
                        extras.append(DestinationEntry(countryCode: r.code, latitude: r.lat, longitude: r.lon))
                    }
                }

                await MainActor.run {
                    guard let bundle = self.bundle(for: trip.id) else { return }
                    if !primary.code.isEmpty { bundle.countryCode = primary.code }
                    bundle.latitude  = primary.lat
                    bundle.longitude = primary.lon
                    bundle.additionalDestinations = extras
                    do { try self.context.save() } catch {
                        CarryLogger.shared.log(.persistFailed, context: "caller=geocodeMissingTrips_geocoder")
                    }
                }
            }

            // 2. Trips whose primary is already resolved but extras are missing
            for trip in missingExtras {
                let tokens = splitCities(trip.destinationCity)
                var extras: [DestinationEntry] = []
                for token in tokens.dropFirst() {
                    if let r = lookupCity(token) {
                        extras.append(DestinationEntry(countryCode: r.code, latitude: r.lat, longitude: r.lon))
                    } else if let r = await geocodeToken(token) {
                        extras.append(DestinationEntry(countryCode: r.code, latitude: r.lat, longitude: r.lon))
                    }
                }
                guard !extras.isEmpty else { continue }
                await MainActor.run {
                    guard let bundle = self.bundle(for: trip.id) else { return }
                    bundle.additionalDestinations = extras
                    do { try self.context.save() } catch {
                        CarryLogger.shared.log(.persistFailed, context: "caller=geocodeMissingTrips_extras")
                    }
                }
            }
        }
    }
}

// MARK: - Home Screen Widget snapshot

/// Lightweight, SwiftData-free mirror of a trip, shared with CarryWidget via the
/// App Group UserDefaults. The widget defines a field-identical struct and decodes
/// the same JSON — no shared type / pbxproj change needed.
///
/// ⚠️ 升级兼容：加字段时，**主 App 此处和 CarryWidget/CarryWidget.swift 的 WidgetTrip
/// 必须同步修改**，且新字段在 widget 侧应为可选 / 有默认值，否则旧 Widget extension
/// 解码新 JSON 会失败、显示空白或崩溃。删字段同理（保持向后兼容字段）。
struct WidgetTripSnapshot: Codable {
    let tripId: String
    let name: String
    let destinationCity: String
    let departureDate: Date
    let packedCount: Int
    let totalCount: Int
}

extension TripStore {
    /// App Group shared with CarryWidgetExtension. Requires the matching App Group
    /// capability on both targets; absent it, `UserDefaults(suiteName:)` is nil and
    /// the write is a safe no-op (widget shows its empty state).
    static let widgetAppGroup = "group.com.murphy.carry"
    static let widgetSnapshotKey = "carry_widget_trips"

    /// Publishes the next up-to-3 upcoming trips to the widget and reloads timelines.
    /// Called from CarryApp lifecycle hooks (launch / entering background).
    func writeWidgetSnapshot() {
        let today = Calendar.current.startOfDay(for: Date())
        let upcoming = trips
            .filter { !$0.isDateless && $0.departureDate >= today }
            .sorted { $0.departureDate < $1.departureDate }
            .prefix(3)
        let snapshots = upcoming.map {
            WidgetTripSnapshot(
                tripId: $0.id.uuidString,
                name: $0.name,
                destinationCity: $0.destinationCity,
                departureDate: $0.departureDate,
                packedCount: $0.packedCount,
                totalCount: $0.totalCount
            )
        }
        guard let defaults = UserDefaults(suiteName: Self.widgetAppGroup) else { return }
        if let data = try? JSONEncoder().encode(Array(snapshots)) {
            defaults.set(data, forKey: Self.widgetSnapshotKey)
        }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

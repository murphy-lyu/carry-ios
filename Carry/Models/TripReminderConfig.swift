//
//  TripReminderConfig.swift
//  Carry

import Foundation

struct TripReminderConfig: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var daysBeforeDeparture: Int  // 0 = departure day
    var hour: Int
    var minute: Int = 0

    /// 行程未显式设置提醒时的回退默认（仅作用于 reminderConfigData 为空 Data 的行程，
    /// 主要是存量老行程）。已从早期强默认 [提前3天 + 出发当天] 软化为
    /// [出发当天 + 出发前1天]（去掉提前3天）。
    /// 新建行程不走此回退——创建时由 ReminderPreferences.defaultConfigs 显式写入。
    static let defaults: [TripReminderConfig] = [
        TripReminderConfig(daysBeforeDeparture: 0, hour: 9),
        TripReminderConfig(daysBeforeDeparture: 1, hour: 9),
    ]

    /// 出发提醒档位（=「行程倒计时」，spec: notification-center.md）。刻意精简成「当天 → 明天 →
    /// 几天后 → 一周」的有节奏阶梯：去掉「前2天」(夹在 1/3 天间冗余) 与「前2周」(对休闲游太远)。
    /// 注：hour 仅名义占位——实际时间统一取 `ReminderPreferences.defaultMinutes`（设置页可改）。
    static let presets: [TripReminderConfig] = [
        TripReminderConfig(daysBeforeDeparture: 0, hour: 7),
        TripReminderConfig(daysBeforeDeparture: 1, hour: 9),
        TripReminderConfig(daysBeforeDeparture: 3, hour: 9),
        TripReminderConfig(daysBeforeDeparture: 7, hour: 9),
    ]

    var timeString: String {
        String(format: "%02d:%02d", hour, minute)
    }

    /// 档位本地化标签（出发当天 / 出发前 N 天 / 出发前 N 周）。
    /// 设置页与 per-trip 提醒选择器共用，避免文案漂移。
    var localizedLabel: String {
        if daysBeforeDeparture == 0 {
            return String(localized: "reminder.label.departureDay")
        } else if daysBeforeDeparture % 7 == 0 {
            let weeks = daysBeforeDeparture / 7
            return weeks == 1
                ? String(localized: "reminder.label.oneWeekBefore")
                : String.localizedStringWithFormat(NSLocalizedString("reminder.label.weeksBefore", comment: ""), weeks)
        } else {
            return daysBeforeDeparture == 1
                ? String(localized: "reminder.label.oneDayBefore")
                : String.localizedStringWithFormat(NSLocalizedString("reminder.label.daysBefore", comment: ""), daysBeforeDeparture)
        }
    }

    func fireDate(relativeTo departureDate: Date) -> Date? {
        let calendar = Calendar.current
        guard let base = calendar.date(byAdding: .day, value: -daysBeforeDeparture, to: departureDate) else { return nil }
        var comps = calendar.dateComponents([.year, .month, .day], from: base)
        comps.hour = hour
        comps.minute = minute
        return calendar.date(from: comps)
    }

    func isSameTrigger(as other: TripReminderConfig) -> Bool {
        daysBeforeDeparture == other.daysBeforeDeparture && hour == other.hour && minute == other.minute
    }
}

// MARK: - 全局默认提醒偏好（设置 →「通知」）

/// 用户在设置里选择的"新建行程默认提醒档位"。创建行程时快照进该行程的
/// reminderConfigData（非实时联动），之后改设置不影响已建行程。
/// 存储：UserDefaults 一个逗号分隔的 daysBeforeDeparture 串。
/// - 从未设置（key 不存在）→ 默认 [0, 1]（出发当天 + 出发前1天）
/// - 显式设为空串 ""        → []（全部关闭，新行程默认无提醒，合法）
enum ReminderPreferences {
    // 所有 Carry 自有 UserDefaults key 用 "carry." 前缀，与系统/第三方裸 key 区分，
    // 也便于未来排查、迁移。⚠️ key 一旦发布到生产，**禁止改名**——需新 key + 一次性
    // 迁移旧值（见 docs/decisions.md「UserDefaults / AppStorage key 一旦发布不能改名」）。
    static let storageKey = "carry.notif.default_offsets"
    static let timeKey = "carry.notif.default_minutes"  // 自午夜起的分钟数；默认 540 = 09:00

    static var enabledOffsets: Set<Int> {
        get {
            guard let raw = UserDefaults.standard.string(forKey: storageKey) else { return [0, 1] }
            return Set(raw.split(separator: ",").compactMap { Int($0) })
        }
        set {
            let raw = newValue.sorted().map(String.init).joined(separator: ",")
            UserDefaults.standard.set(raw, forKey: storageKey)
        }
    }

    /// 全局默认提醒时间（所有档位统一用此时间；per-trip 仍可逐条覆盖）。默认 09:00。
    static var defaultMinutes: Int {
        get { UserDefaults.standard.object(forKey: timeKey) as? Int ?? 540 }
        set { UserDefaults.standard.set(newValue, forKey: timeKey) }
    }

    /// 新建行程的默认提醒配置 = 已开启档位，统一用全局默认时间。
    static var defaultConfigs: [TripReminderConfig] {
        let h = defaultMinutes / 60, m = defaultMinutes % 60
        return enabledOffsets.sorted().map {
            TripReminderConfig(daysBeforeDeparture: $0, hour: h, minute: m)
        }
    }
}

// MARK: - 通知中心：多类别全局配置（spec: notification-center.md）
//
// Settings 为唯一真相源、无 per-trip 快照。出发提醒沿用上面 ReminderPreferences 的
// enabledOffsets / defaultMinutes（旧 key 向后兼容）；下面是新增类别。
// 所有 key 用 "carry.notif." 前缀，一旦发布禁止改名（见 decisions.md）。
extension ReminderPreferences {

    private static func intList(_ key: String, default def: [Int]) -> [Int] {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return def }
        let parsed = raw.split(separator: ",").compactMap { Int($0) }
        return parsed.isEmpty ? [] : Array(Set(parsed)).sorted(by: >)   // 提前量大→小
    }
    private static func setIntList(_ key: String, _ value: [Int]) {
        UserDefaults.standard.set(Set(value).sorted(by: >).map(String.init).joined(separator: ","), forKey: key)
    }
    private static func bool(_ key: String, default def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? def
    }
    private static func int(_ key: String, default def: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? def
    }

    // MARK: 出发提醒开关（A）——总开关；档位仍走 enabledOffsets
    static let departureEnabledKey = "carry.notif.departure_enabled"
    static var departureEnabled: Bool {
        get { bool(departureEnabledKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: departureEnabledKey) }
    }

    // MARK: 打包进度提醒（A，仅未打完才发「还剩 N 件」）
    static let packProgressEnabledKey = "carry.notif.pack_progress_enabled"
    static let packProgressOffsetKey = "carry.notif.pack_progress_offset_days"
    static var packProgressEnabled: Bool {
        get { bool(packProgressEnabledKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: packProgressEnabledKey) }
    }
    /// 出发前 N 天触发。默认前 1 天。
    static var packProgressOffsetDays: Int {
        get { int(packProgressOffsetKey, default: 1) }
        set { UserDefaults.standard.set(newValue, forKey: packProgressOffsetKey) }
    }
    /// 打包提醒**独立时间**（自午夜分钟）。默认 1260=21:00——打包发生在出发前一晚，
    /// 与出发提醒（清晨倒计时）刻意分开。
    static let packMinutesKey = "carry.notif.pack_minutes"
    static var packReminderMinutes: Int {
        get { int(packMinutesKey, default: 1260) }
        set { UserDefaults.standard.set(newValue, forKey: packMinutesKey) }
    }

    // MARK: 交通出发提醒（B，多档提前量分钟）——航班/火车/巴士/渡轮
    static let transportEnabledKey = "carry.notif.transport_enabled"
    static let transportLeadsKey = "carry.notif.transport_leads_min"
    static var transportEnabled: Bool {
        get { bool(transportEnabledKey, default: true) }   // 默认开
        set { UserDefaults.standard.set(newValue, forKey: transportEnabledKey) }
    }
    /// 起飞/发车前多少分钟提醒；可多条（如 [180, 60]）。默认 [180]=3 小时。
    static var transportLeadsMinutes: [Int] {
        get { intList(transportLeadsKey, default: [180]) }
        set { setIntList(transportLeadsKey, newValue) }
    }

    // MARK: 租车取/还车提醒（B，默认关）
    static let carRentalEnabledKey = "carry.notif.carrental_enabled"
    static let carRentalLeadsKey = "carry.notif.carrental_leads_min"
    static var carRentalEnabled: Bool {
        get { bool(carRentalEnabledKey, default: false) }  // 默认关
        set { UserDefaults.standard.set(newValue, forKey: carRentalEnabledKey) }
    }
    /// 还车前多少分钟提醒；可多条。默认 [60]=1 小时（同日，正文「今天 X 还车」才成立）。
    static var carRentalLeadsMinutes: [Int] {
        get { intList(carRentalLeadsKey, default: [60]) }
        set { setIntList(carRentalLeadsKey, newValue) }
    }

    // MARK: 住宿提醒（C 类，行程日锚，默认关）——退房当天清晨固定时刻（只退房、入住不提醒）
    // 退房本质是「当天 deadline 前撤离」、人已在房间，不是「提前赶去」的交通型事件——故用
    // 清晨唤醒锚（同出发提醒/每日摘要），而非提前量倒计时。
    static let lodgingEnabledKey = "carry.notif.lodging_enabled"
    static let lodgingCheckOutMinKey = "carry.notif.lodging_checkout_min"
    static var lodgingEnabled: Bool {
        get { bool(lodgingEnabledKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: lodgingEnabledKey) }
    }
    /// 退房当天提醒时刻（自午夜分钟）。默认 540=09:00。
    static var lodgingCheckOutMinutes: Int {
        get { int(lodgingCheckOutMinKey, default: 540) }
        set { UserDefaults.standard.set(newValue, forKey: lodgingCheckOutMinKey) }
    }

    // MARK: 每日行程摘要（C，默认关）
    static let dailySummaryEnabledKey = "carry.notif.daily_enabled"
    static let dailySummaryMinKey = "carry.notif.daily_min"
    static var dailySummaryEnabled: Bool {
        get { bool(dailySummaryEnabledKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: dailySummaryEnabledKey) }
    }
    /// 每个行程日的推送时刻（自午夜分钟）。默认 540=09:00。
    static var dailySummaryMinutes: Int {
        get { int(dailySummaryMinKey, default: 540) }
        set { UserDefaults.standard.set(newValue, forKey: dailySummaryMinKey) }
    }
}

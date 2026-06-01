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
    /// 主要是存量老行程）。已从早期强默认 [提前3天 + 出发当天] 软化为「出发前1天」。
    /// 新建行程不走此回退——创建时由 ReminderPreferences.defaultConfigs 显式写入。
    static let defaults: [TripReminderConfig] = [
        TripReminderConfig(daysBeforeDeparture: 1, hour: 9),
    ]

    /// 全部可选档位（连带各自固有时间）：设置页开关与 per-trip 选择器共用同一组。
    static let presets: [TripReminderConfig] = [
        TripReminderConfig(daysBeforeDeparture: 0, hour: 7),
        TripReminderConfig(daysBeforeDeparture: 1, hour: 9),
        TripReminderConfig(daysBeforeDeparture: 2, hour: 9),
        TripReminderConfig(daysBeforeDeparture: 3, hour: 9),
        TripReminderConfig(daysBeforeDeparture: 7, hour: 9),
        TripReminderConfig(daysBeforeDeparture: 14, hour: 9),
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
/// - 从未设置（key 不存在）→ 默认 [1]（出发前1天）
/// - 显式设为空串 ""        → []（全部关闭，新行程默认无提醒，合法）
enum ReminderPreferences {
    static let storageKey = "default_reminder_offsets"

    static var enabledOffsets: Set<Int> {
        get {
            guard let raw = UserDefaults.standard.string(forKey: storageKey) else { return [1] }
            return Set(raw.split(separator: ",").compactMap { Int($0) })
        }
        set {
            let raw = newValue.sorted().map(String.init).joined(separator: ",")
            UserDefaults.standard.set(raw, forKey: storageKey)
        }
    }

    /// 新建行程的默认提醒配置 = presets 中"已开启"的档位（连带其固有时间）。
    static var defaultConfigs: [TripReminderConfig] {
        TripReminderConfig.presets.filter { enabledOffsets.contains($0.daysBeforeDeparture) }
    }
}

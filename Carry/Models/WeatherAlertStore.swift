//
//  WeatherAlertStore.swift
//  Carry
//
//  天气预警 per-trip 持久化载荷（spec: weather-aware-packing.md, Part 2）。
//  天气是异步拉的、而 NotificationManager.reschedule 是同步遍历 + 64 预算差集删除——
//  所以预警结论必须落成持久载荷，让 `collectWeatherAlerts` 同步读到、进候选集，才不会被差集删掉。
//  评估器（WeatherAlertEvaluator）异步写入；NotificationManager 同步读取。UserDefaults 轻量存储。
//

import Foundation

/// 单个行程的天气预警结论。`kind` 决定（本地化）通知文案；`fetchedAt` 用于新鲜度判断。
nonisolated struct WeatherAlertPayload: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case severe, snow, heat, cold, rain }
    var kind: Kind
    var fetchedAt: Date
}

nonisolated enum WeatherAlertStore {
    private static let key = "carry.weather_alerts_cache"

    static func loadAll() -> [String: WeatherAlertPayload] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: WeatherAlertPayload].self, from: data)
        else { return [:] }
        return dict
    }

    static func payload(for id: UUID) -> WeatherAlertPayload? { loadAll()[id.uuidString] }

    /// 写入（payload 为 nil → 删除该行程的载荷，用于天气转好后撤销）。
    static func set(_ payload: WeatherAlertPayload?, for id: UUID) {
        var dict = loadAll()
        if let payload { dict[id.uuidString] = payload } else { dict.removeValue(forKey: id.uuidString) }
        if let data = try? JSONEncoder().encode(dict) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// 回收：仅保留仍存在的行程，删掉已删除行程的残留载荷。
    static func prune(keeping keep: Set<UUID>) {
        let keepStr = Set(keep.map(\.uuidString))
        let dict = loadAll().filter { keepStr.contains($0.key) }
        if let data = try? JSONEncoder().encode(dict) { UserDefaults.standard.set(data, forKey: key) }
    }
}

//
//  WeatherAlertEvaluator.swift
//  Carry
//
//  天气预警评估（spec: weather-aware-packing.md, Part 2）。为「即将出发」的行程异步拉 WeatherKit，
//  判断是否有值得**推送**的天气（门槛高于打包 nudge——只极端/可能打乱行程的才发）：
//    1) WeatherKit 官方 Severe Weather Alert（台风/风暴等，权威）优先；
//    2) 否则阈值类：暴雪 / 极端高温(≥35℃) / 极端低温(≤−5℃) / 持续强降雨(≥2 天且概率≥70%)。
//  结论写入 WeatherAlertStore；NotificationManager.collectWeatherAlerts 同步读取并排进 64 预算。
//

import Foundation
import CoreLocation
import WeatherKit

enum WeatherAlertEvaluator {

    /// 单飞守卫（@MainActor 静态 → 竞态安全）：同一时刻只跑一个评估 pass，
    /// 避免并发 detached 任务对 WeatherAlertStore 读-改-写互相覆盖。
    @MainActor private static var isEvaluating = false

    /// 评估即将出发行程的天气预警，写入 store；有变化则回主线程触发一次重排。
    /// 节流：cache 新鲜（<6h）的行程跳过，避免频繁调 WeatherKit。`onUpdated` 在主线程执行。
    @MainActor
    static func refresh(trips: [TripBundle], onUpdated: @escaping @MainActor @Sendable () -> Void) {
        WeatherAlertStore.prune(keeping: Set(trips.map(\.id)))
        guard ReminderPreferences.weatherAlertsEnabled else { return }
        guard !isEvaluating else { return }   // 单飞：上一轮还没跑完就跳过
        let now = Date()
        // 候选：有日期、有坐标、出发在未来且在预报窗口(~10 天)内。
        let snaps: [Snapshot] = trips.compactMap { t in
            guard !t.isDateless, t.latitude != 0, t.departureDate >= now else { return nil }
            let daysAway = Calendar.current.dateComponents([.day], from: now, to: t.departureDate).day ?? 999
            guard daysAway <= 10 else { return nil }
            let end = Calendar.current.date(byAdding: .day, value: max(t.days - 1, 0), to: t.departureDate) ?? t.departureDate
            return Snapshot(id: t.id, lat: t.latitude, lon: t.longitude, start: t.departureDate, end: end)
        }
        guard !snaps.isEmpty else { return }

        isEvaluating = true
        Task.detached {
            var changed = false
            for s in snaps {
                if let p = WeatherAlertStore.payload(for: s.id),
                   Date().timeIntervalSince(p.fetchedAt) < 6 * 3600 { continue }   // 节流
                let payload = await evaluate(s)
                let before = WeatherAlertStore.payload(for: s.id)
                if before != payload {            // 仅在结论变化时标记需重排，避免无谓重排
                    WeatherAlertStore.set(payload, for: s.id)
                    changed = true
                }
                if let payload {
                    await MainActor.run {
                        CarryLogger.shared.log(.weatherAlertScheduled, context: "kind=\(payload.kind.rawValue)")
                    }
                }
            }
            let didChange = changed   // 绑不可变，避免闭包捕获可变变量（Swift 6 并发安全）
            await MainActor.run {
                isEvaluating = false
                if didChange { onUpdated() }
            }
        }
    }

    private struct Snapshot: Sendable {
        let id: UUID; let lat: Double; let lon: Double; let start: Date; let end: Date
    }

    /// 拉一个行程目的地的天气，按门槛判断是否产生预警载荷。失败/无事 → nil。
    nonisolated private static func evaluate(_ s: Snapshot) async -> WeatherAlertPayload? {
        do {
            let weather = try await WeatherFetchCache.shared.weather(lat: s.lat, lon: s.lon)
            // 1) 官方 severe / extreme 预警优先（用本地化文案推送，不直接塞可能是外语的官方摘要）
            if weather.weatherAlerts?.contains(where: { $0.severity == .severe || $0.severity == .extreme }) == true {
                return WeatherAlertPayload(kind: .severe, fetchedAt: Date())
            }
            // 2) 阈值类——仅行程窗口内的日预报
            let cal = Calendar.current
            let windowStart = cal.startOfDay(for: max(s.start, Date()))
            let days = weather.dailyForecast.filter { $0.date >= windowStart && $0.date <= s.end }
            guard !days.isEmpty else { return nil }

            if days.contains(where: { $0.condition == .blizzard || $0.condition == .heavySnow || $0.condition == .snow }) {
                return WeatherAlertPayload(kind: .snow, fetchedAt: Date())
            }
            if days.contains(where: { $0.highTemperature.converted(to: .celsius).value >= 35 }) {
                return WeatherAlertPayload(kind: .heat, fetchedAt: Date())
            }
            if days.contains(where: { $0.lowTemperature.converted(to: .celsius).value <= -5 }) {
                return WeatherAlertPayload(kind: .cold, fetchedAt: Date())
            }
            if days.filter({ $0.precipitationChance >= 0.7 }).count >= 2 {
                return WeatherAlertPayload(kind: .rain, fetchedAt: Date())
            }
            return nil
        } catch {
            return nil   // 拉取失败：不写、不发（优雅降级）
        }
    }
}

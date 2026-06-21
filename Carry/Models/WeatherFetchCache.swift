//
//  WeatherFetchCache.swift
//  Carry
//
//  WeatherKit 拉取的共享缓存 + 单飞合并（spec: weather-aware-packing.md）。
//  天气展示（WeatherManager）与天气预警（WeatherAlertEvaluator）都按目的地拉同一份预报；
//  经此 actor 统一：同一地点 TTL 内只打一次网，并发请求合并到同一个在途 Task，避免重复调用 WeatherKit。
//

import Foundation
import CoreLocation
import WeatherKit

actor WeatherFetchCache {
    static let shared = WeatherFetchCache()

    private struct Entry { let weather: Weather; let at: Date }
    private var cache: [String: Entry] = [:]
    private var inFlight: [String: Task<Weather, Error>] = [:]
    private let ttl: TimeInterval = 15 * 60   // 15 分钟：天气分钟级不变，远短于行程窗口

    func weather(lat: Double, lon: Double) async throws -> Weather {
        let key = "\(lat),\(lon)"
        if let e = cache[key], Date().timeIntervalSince(e.at) < ttl { return e.weather }
        if let running = inFlight[key] { return try await running.value }   // 合并并发请求

        let task = Task {
            try await WeatherService.shared.weather(for: CLLocation(latitude: lat, longitude: lon))
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let w = try await task.value
        cache[key] = Entry(weather: w, at: Date())
        return w
    }
}

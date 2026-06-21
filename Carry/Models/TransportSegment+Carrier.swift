//
//  TransportSegment+Carrier.swift
//  Carry
//
//  承运方展示名的本地化（render-time resolution）。spec: itinerary-flight-name-localization.md
//

import Foundation

extension TransportSegment {
    /// 承运方展示名：**航班**按航班号解析本地化航司名（跟随界面语言、切语言也变）；非航班、未识别号、
    /// 或用户自定义承运方 → 用存的 `carrier` 原文。gate 在 `.flight`，避免火车号被误判为航司。
    /// 航司名查 `AirlineDatabase`（同步、单一数据源），不存固定语言字符串。
    var displayCarrier: String {
        if mode == .flight, let name = AirlineDatabase.airlineName(forFlightNumber: number) {
            return name
        }
        return carrier.trimmingCharacters(in: .whitespaces)
    }
}

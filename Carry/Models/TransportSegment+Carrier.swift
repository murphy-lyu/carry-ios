//
//  TransportSegment+Carrier.swift
//  Carry
//
//  承运方展示名的本地化（render-time resolution）。spec: itinerary-flight-name-localization.md
//

import Foundation

extension TransportSegment {
    /// 承运方名（按**指定语言键**）：**航班**按航班号解析该语言的航司名；非航班、未识别号、或用户
    /// 自定义承运方 → 用存的 `carrier` 原文。gate 在 `.flight`，避免火车号被误判为航司。
    /// 航司名查 `AirlineDatabase`（同步、单一数据源），不存固定语言字符串。
    /// 显式键让「App 内显示（设备语言）」与「导出（所选语言）」共用同一逻辑、各传各的键。
    func carrierName(forLanguageKey key: String?) -> String {
        if mode == .flight, let name = AirlineDatabase.airlineName(forFlightNumber: number, languageKey: key) {
            return name
        }
        return carrier.trimmingCharacters(in: .whitespaces)
    }

    /// 按**设备**语言的承运方名（App 内时间轴/详情显示用，跟随界面语言、切语言也变）。
    var displayCarrier: String { carrierName(forLanguageKey: AirportLocale.languageKey) }
}

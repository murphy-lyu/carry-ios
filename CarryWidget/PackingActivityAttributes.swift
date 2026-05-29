//
//  PackingActivityAttributes.swift
//  CarryWidget
//
//  与 Carry/Models/PackingActivityAttributes.swift 保持结构同步。
//  ActivityKit 通过 Codable 在 App 和 Widget Extension 之间传递数据，
//  两侧只要属性名称/类型一致即可正常工作。

import ActivityKit
import Foundation

struct PackingActivityAttributes: ActivityAttributes {

    struct ContentState: Codable, Hashable {
        var packedItems: Int
        var isCompleted: Bool
    }

    var tripName: String
    var destinationCity: String
    var departureDate: Date
    var totalItems: Int
}

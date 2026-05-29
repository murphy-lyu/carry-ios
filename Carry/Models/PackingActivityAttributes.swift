//
//  PackingActivityAttributes.swift
//  Carry
//
//  ⚠️ 此文件需同时加入 App target 和 CarryWidget target 的 "Target Membership"。

import Foundation

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

struct PackingActivityAttributes: ActivityAttributes {

    // MARK: - 动态状态（每次打包勾选时更新）

    struct ContentState: Codable, Hashable {
        /// 已勾选物品数量
        var packedItems: Int
        /// 是否全部打包完成
        var isCompleted: Bool
    }

    // MARK: - 静态数据（Activity 启动后不变）

    /// 行程名称
    var tripName: String
    /// 目的地城市（用于展示）
    var destinationCity: String
    /// 出发日期
    var departureDate: Date
    /// 全部物品总数
    var totalItems: Int
}

#endif

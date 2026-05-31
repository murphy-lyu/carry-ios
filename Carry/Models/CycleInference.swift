//
//  CycleInference.swift
//  Carry
//
//  本地经期预测：读取 HealthKit Cycle Tracking 记录，预测某段行程区间是否
//  与经期/经期附近重叠。仅用于在 ScenePicker 中轻推「🌸 On / near period」场景。
//
//  隐私约定（见 specs/healthkit-cycle-nudge.md）：
//  - 健康数据全程仅在设备本地用于一次性预测，不持久化、不上传、不写回 HealthKit。
//  - 整个 App 中对 HealthKit 的引用只允许出现在本文件。
//  - 不依赖授权状态分支：读到就用、读不到就静默降级（HealthKit 读权限不可查询）。
//

import Foundation
import HealthKit

enum CycleInference {

    // MARK: - Tuning

    /// 拉取多久的历史经期样本用于推断周期长度。
    private static let lookbackDays = 190
    /// 相邻样本日间隔 ≤ 此值视为同一段经期。
    private static let segmentGapDays = 2
    /// 至少需要几段经期才进行预测（不足则不做单点外推）。
    private static let minSegments = 2
    /// 缺省周期长度（仅样本足够时启用，作为异常值兜底）。
    private static let fallbackCycleLength = 28
    /// 预测经期窗口：起始日前置缓冲（覆盖 "near period"）。
    private static let windowLeadDays = 2
    /// 预测经期窗口：起始日之后持续天数。
    private static let windowDurationDays = 5

    private static let store = HKHealthStore()

    private static var menstrualFlowType: HKCategoryType? {
        HKCategoryType.categoryType(forIdentifier: .menstrualFlow)
    }

    // MARK: - Public API

    /// 当前设备是否支持 HealthKit（部分 iPad / Mac Catalyst 不支持）。
    static var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// 主动请求经期记录的只读授权（弹出系统授权弹窗）。
    /// 返回值表示"请求是否正常完成"，并不代表用户已授予（HealthKit 读权限不可查询）。
    @discardableResult
    static func requestAuthorization() async -> Bool {
        guard isAvailable, let type = menstrualFlowType else { return false }
        return await requestReadAuthorization(for: type)
    }

    /// 行程区间 `[start, end]` 是否预计与经期重叠。
    /// 设备不支持 / 未授权 / 样本不足 / 无重叠 → 返回 false（静默降级）。
    static func tripOverlapsPredictedPeriod(start: Date, end: Date) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable(),
              let type = menstrualFlowType else { return false }

        // 首次惰性申请读权限（系统弹窗只弹一次；拒绝后 query 返回空，不影响降级路径）。
        let granted = await requestReadAuthorization(for: type)
        guard granted else { return false }

        guard let segments = await fetchPeriodStartDates(type: type), segments.count >= minSegments else {
            return false
        }

        guard let predictedStart = predictPeriodStart(from: segments, near: start) else { return false }

        let calendar = Calendar.current
        let windowStart = calendar.date(byAdding: .day, value: -windowLeadDays, to: predictedStart) ?? predictedStart
        let windowEnd = calendar.date(byAdding: .day, value: windowDurationDays, to: predictedStart) ?? predictedStart

        // 区间相交：windowStart <= end && start <= windowEnd
        return windowStart <= end && start <= windowEnd
    }

    // MARK: - Authorization

    private static func requestReadAuthorization(for type: HKCategoryType) async -> Bool {
        await withCheckedContinuation { continuation in
            store.requestAuthorization(toShare: [], read: [type]) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    // MARK: - Query

    /// 拉取最近 `lookbackDays` 天的经期样本，聚合成「经期段」并返回每段的起始日（升序）。
    /// query 永远成功；无权限或无数据时返回空数组。
    private static func fetchPeriodStartDates(type: HKCategoryType) async -> [Date]? {
        let calendar = Calendar.current
        let now = Date()
        guard let lookbackStart = calendar.date(byAdding: .day, value: -lookbackDays, to: now) else { return nil }

        let predicate = HKQuery.predicateForSamples(withStart: lookbackStart, end: now, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        let samples: [HKCategorySample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, results, _ in
                continuation.resume(returning: (results as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }

        guard !samples.isEmpty else { return [] }

        // 去重到「日」粒度后聚合成段：相邻有记录日间隔 > segmentGapDays 则视为新段。
        let days = Set(samples.map { calendar.startOfDay(for: $0.startDate) }).sorted()
        var segmentStarts: [Date] = []
        var previousDay: Date?
        for day in days {
            if let prev = previousDay,
               let gap = calendar.dateComponents([.day], from: prev, to: day).day,
               gap <= segmentGapDays {
                // 同一段，跳过
            } else {
                segmentStarts.append(day)
            }
            previousDay = day
        }
        return segmentStarts
    }

    // MARK: - Prediction

    /// 基于经期段起始日推断周期长度，外推到 `reference` 附近的预测经期起始日。
    private static func predictPeriodStart(from segmentStarts: [Date], near reference: Date) -> Date? {
        guard segmentStarts.count >= minSegments else { return nil }

        let calendar = Calendar.current
        // 相邻段起始日之差（天）的中位数 = 周期长度。
        var intervals: [Int] = []
        for i in 1..<segmentStarts.count {
            if let d = calendar.dateComponents([.day], from: segmentStarts[i - 1], to: segmentStarts[i]).day, d > 0 {
                intervals.append(d)
            }
        }
        guard !intervals.isEmpty else { return nil }

        let cycleLength = median(intervals).flatMap { value -> Int in
            // 异常周期（过短/过长）回退到缺省值，避免离谱外推。
            (value >= 20 && value <= 40) ? value : fallbackCycleLength
        } ?? fallbackCycleLength

        guard let lastStart = segmentStarts.last else { return nil }

        // 从最近一次经期起始日，按周期长度向前推进到 reference 附近。
        var candidate = lastStart
        // 防御性上限：最多推进 ~2 年的周期数。
        for _ in 0..<26 {
            guard let next = calendar.date(byAdding: .day, value: cycleLength, to: candidate) else { break }
            if next > reference { break }
            candidate = next
        }
        return candidate
    }

    private static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}

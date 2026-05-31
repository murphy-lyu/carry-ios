//
//  TripInfo.swift
//  Carry
//

import Foundation

struct TripInfo: Hashable {
    var name: String = ""
    var destinationCity: String = ""
    var departureDate: Date
    var returnDate: Date
    /// 无日期「规划中」行程。为真时 departureDate/returnDate 为占位值，调用方不应读取。
    var isDateless: Bool = false

    init(
        name: String = "",
        destinationCity: String = "",
        departureDate: Date? = nil,
        returnDate: Date? = nil,
        isDateless: Bool = false
    ) {
        self.name = name
        self.destinationCity = destinationCity
        self.isDateless = isDateless

        let calendar = Calendar.current
        let base = calendar.startOfDay(for: departureDate ?? Date())
        let computedReturn = calendar.date(byAdding: .day, value: 6, to: base) ?? base

        self.departureDate = base
        self.returnDate = calendar.startOfDay(for: returnDate ?? computedReturn)
    }

    var durationDays: Int {
        max(1, Calendar.current.dateComponents([.day], from: departureDate, to: returnDate).day ?? 1)
    }

    var dateRangeDisplay: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return "\(fmt.string(from: departureDate)) – \(fmt.string(from: returnDate))"
    }
}

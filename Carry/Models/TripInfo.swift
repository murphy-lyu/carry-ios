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

    init(
        name: String = "",
        destinationCity: String = "",
        departureDate: Date? = nil,
        returnDate: Date? = nil
    ) {
        self.name = name
        self.destinationCity = destinationCity

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

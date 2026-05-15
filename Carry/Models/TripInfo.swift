//
//  TripInfo.swift
//  Carry
//

import Foundation

struct TripInfo: Hashable {
    var name: String = ""
    var destinationCity: String = ""
    var departureDate: Date = Date()
    var returnDate: Date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()

    var durationDays: Int {
        max(1, Calendar.current.dateComponents([.day], from: departureDate, to: returnDate).day ?? 1)
    }

    var dateRangeDisplay: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return "\(fmt.string(from: departureDate)) – \(fmt.string(from: returnDate))"
    }
}

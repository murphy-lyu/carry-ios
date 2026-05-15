//
//  Trip.swift
//  Carry
//

import Foundation

struct Trip: Identifiable, Hashable {
    let id = UUID()
    let destination: String
    let days: Int
    let dateRange: String
    let packedCount: Int
    let totalCount: Int

    static func == (lhs: Trip, rhs: Trip) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

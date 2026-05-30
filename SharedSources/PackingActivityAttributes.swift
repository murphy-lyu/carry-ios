import Foundation

#if canImport(ActivityKit)
import ActivityKit

struct PackingActivityAttributes: ActivityAttributes {

    struct ContentState: Codable, Hashable {
        var packedItems: Int
        var totalItems: Int
        var isCompleted: Bool
        var tripName: String
        var destinationCity: String
        var departureDate: Date
    }

    var tripId: UUID
}
#endif

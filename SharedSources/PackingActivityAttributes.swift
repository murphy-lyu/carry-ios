import Foundation

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

// The app target defaults declarations to @MainActor. ActivityKit invokes this
// value-type conformance from concurrent contexts, so keep the shared payload
// explicitly nonisolated (the widget target compiles the same source file).
nonisolated struct PackingActivityAttributes: ActivityAttributes {

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

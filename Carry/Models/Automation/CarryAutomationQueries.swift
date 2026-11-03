import Foundation
import MapKit

/// Read-only device queries use the same service credentials and geographic policy as Carry.
/// Search results are data, not a command to create a stop or trust third-party instructions.
@MainActor
enum CarryAutomationQueries {
    static let names: Set<String> = ["search_airports", "search_places", "lookup_flight", "preview_route", "get_packing_recommendations", "open_trip"]

    static func run(_ operation: AutomationOperation, snapshots: [AutomationTripSnapshot]) async throws -> [String: AutomationValue] {
        let fields = AutomationFields(values: operation.arguments.data ?? [:])
        switch operation.name {
        case "open_trip":
            try fields.validate(allowed: ["face"])
            guard let trip = snapshots.first(where: { $0.id == operation.arguments.tripId }) else { throw AutomationError.notFound }
            let face = try fields.string("face") ?? "itinerary"
            guard ["packing", "itinerary"].contains(face) else { throw AutomationError.invalidInput }
            return ["tripId": .string(trip.id.uuidString), "face": .string(face), "navigationState": .string("requested_not_visually_verified")]
        case "search_airports":
            try fields.validate(allowed: ["query"])
            let airports = await AirportDatabase.shared.search(try fields.string("query", required: true, max: 200) ?? "", limit: 10)
            return ["results": .array(airports.map { .object([
                "iata": .string($0.iata), "name": .string($0.displayName), "city": .string($0.city),
                "country": .string($0.country), "latitude": .number($0.lat), "longitude": .number($0.lon), "timeZoneId": .string($0.tz)
            ]) })]
        case "search_places":
            try fields.validate(allowed: ["query", "latitude", "longitude"])
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = try fields.string("query", required: true, max: 200)
            let lat = try fields.number("latitude", range: -90...90), lon = try fields.number("longitude", range: -180...180)
            guard (lat == nil) == (lon == nil) else { throw AutomationError.invalidInput }
            if let lat, let lon {
                request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon), latitudinalMeters: 50_000, longitudinalMeters: 50_000)
            }
            // MapKit selects its regional provider. This path never forwards a domestic
            // query to the overseas Mapbox proxy, including ambiguous Chinese queries.
            let response = try await MKLocalSearch(request: request).start()
            return ["results": .array(response.mapItems.prefix(10).map { item in .object([
                "name": .string(item.name ?? ""), "address": .string(item.placemark.title ?? ""),
                "latitude": .number(item.placemark.coordinate.latitude), "longitude": .number(item.placemark.coordinate.longitude),
                "timeZoneId": .string(item.timeZone?.identifier ?? ""), "countryCode": .string(item.placemark.isoCountryCode ?? "")
            ]) })]
        case "lookup_flight":
            try fields.validate(allowed: ["number", "departureDate"])
            let number = try fields.string("number", required: true, max: 20) ?? ""
            let date = try fields.string("departureDate", required: true) ?? ""
            _ = try AutomationCodec.date(date)
            let flight = try await FlightLookupService.lookup(number: number, dateString: date)
            func endpoint(_ value: FlightLookupResult.Endpoint) -> AutomationValue {
                var result: [String: AutomationValue] = ["iata": .string(value.iata), "name": .string(value.name),
                    "latitude": .number(value.latitude), "longitude": .number(value.longitude), "timeZoneId": .string(value.timeZoneId), "terminal": .string(value.terminal)]
                if let scheduled = value.scheduledLocal {
                    let formatter = ISO8601DateFormatter()
                    formatter.timeZone = TimeZone(identifier: value.timeZoneId) ?? TimeZone(secondsFromGMT: 0)
                    result["scheduledAt"] = .string(formatter.string(from: scheduled))
                }
                return .object(result)
            }
            return ["flightNumber": .string(flight.flightNumber), "airline": .string(flight.airlineName),
                "from": endpoint(flight.from), "to": endpoint(flight.to), "durationMinutes": .number(Double(flight.durationMinutes))]
        case "preview_route":
            try fields.validate(allowed: ["dayOrder"])
            guard let trip = snapshots.first(where: { $0.id == operation.arguments.tripId }),
                  let order = try fields.integer("dayOrder", range: 0...3660), let day = trip.days.first(where: { $0.dayOrder == order }) else { throw AutomationError.notFound }
            // Detached objects are only algorithm inputs; they never enter a ModelContext.
            let stops = day.stops.map { value in
                let stop = ItineraryStop(name: value.name, latitude: value.latitude, longitude: value.longitude)
                stop.id = value.id
                return stop
            }
            guard let result = RouteOptimizer.optimize(stops: stops) else { throw AutomationError.invalidInput }
            let missing = stops.filter { !$0.hasCoordinate }.map(\.id)
            return ["ids": .array((result.orderedStopIDs + missing).map { .string($0.uuidString) }),
                "revision": .string(trip.revision), "distanceBasis": .string("straight_line_not_road_distance"),
                "originalDistanceMeters": .number(result.originalDistanceMeters), "optimizedDistanceMeters": .number(result.optimizedDistanceMeters),
                "isImprovement": .bool(result.isImprovement), "applyWith": .string("reorder_stops")]
        default: throw AutomationError.unsupportedOperation
        }
    }
}

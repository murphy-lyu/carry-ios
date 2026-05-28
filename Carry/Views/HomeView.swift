//
//  HomeView.swift
//  Carry
//

import SwiftUI
import MapKit

fileprivate let homeDarkBackdropTop = Color(red: 0.03, green: 0.03, blue: 0.04)
fileprivate let homeDarkBackdropBottom = Color(red: 0.07, green: 0.07, blue: 0.08)
fileprivate let homeDarkHeroTop = Color(red: 0.12, green: 0.12, blue: 0.13)
fileprivate let homeDarkHeroBottom = Color(red: 0.17, green: 0.17, blue: 0.18)
fileprivate let homeDarkStatTop = Color(red: 0.15, green: 0.15, blue: 0.16)
fileprivate let homeDarkStatBottom = Color(red: 0.20, green: 0.20, blue: 0.21)
fileprivate let homeDarkCardTop = Color(red: 0.10, green: 0.10, blue: 0.11)
fileprivate let homeDarkCardBottom = Color(red: 0.14, green: 0.14, blue: 0.15)
fileprivate let homeDarkCardTopRefined = Color(red: 0.09, green: 0.09, blue: 0.10)
fileprivate let homeDarkCardBottomRefined = Color(red: 0.12, green: 0.12, blue: 0.13)

// MARK: - HomeView

struct HomeView: View {

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var store: TripStore
    @EnvironmentObject var router: NavigationRouter

    @State private var tripToDelete: TripBundle?
    @State private var showDeleteConfirmation = false
    @State private var listIdentity = UUID()
    @State private var didPlayInitialReveal = false
    @State private var initialRevealProgress: Double = 0
    @State private var revealCurtainOpacity: Double = 1
    @State private var didRevealUpcoming = false

    private let heroRevealThreshold: Double = 0.16
    private let listRevealThreshold: Double = 0.58
    private let pastRevealThreshold: Double = 0.78

    private func revealProgress(start: Double, duration: Double) -> Double {
        guard duration > 0 else { return initialRevealProgress >= start ? 1 : 0 }
        return min(max((initialRevealProgress - start) / duration, 0), 1)
    }

    private func triggerUpcomingReveal(after delay: Double = 0.24) {
        didRevealUpcoming = false
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard router.path.isEmpty else { return }
            withAnimation(.easeOut(duration: 0.30)) {
                didRevealUpcoming = true
            }
        }
    }

    // Cached sorted trip lists — recomputed only when store.trips changes,
    // not on every body re-evaluation (e.g. initialRevealProgress animation ticks).
    @State private var cachedUpcoming: [TripBundle] = []
    @State private var cachedPastByYear: [(year: Int, trips: [TripBundle])] = []

    /// True when the list should appear empty — either no real trips exist,
    /// or the developer mock is active.
    private var isEffectivelyEmpty: Bool {
        store.trips.isEmpty || store.isHomeEmptyStateMockEnabled
    }

    private func returnDate(for trip: TripBundle) -> Date {
        Calendar.current.date(byAdding: .day, value: trip.days, to: trip.departureDate) ?? trip.departureDate
    }

    /// Recomputes both sorted lists in one pass. Called from onAppear and
    /// onChange(of: store.trips) so sorting never runs during animation frames.
    private func rebuildTripLists() {
        let calendar = Calendar.current
        // Compute today's boundary once and share across all trip evaluations.
        let todayStart = calendar.startOfDay(for: Date())

        func isPast(_ trip: TripBundle) -> Bool {
            let ret = returnDate(for: trip)
            return todayStart > calendar.startOfDay(for: ret)
        }

        // Upcoming
        if store.isHomeEmptyStateMockEnabled {
            cachedUpcoming = []
        } else {
            struct Decorated { let trip: TripBundle; let isComplete: Bool }
            let decorated = store.trips
                .filter { !isPast($0) }
                .map { Decorated(trip: $0, isComplete: $0.totalCount > 0 && $0.packedCount == $0.totalCount) }
            cachedUpcoming = decorated
                .sorted {
                    if $0.isComplete != $1.isComplete { return !$0.isComplete }
                    if $0.trip.departureDate != $1.trip.departureDate { return $0.trip.departureDate < $1.trip.departureDate }
                    if $0.trip.createdAt != $1.trip.createdAt { return $0.trip.createdAt > $1.trip.createdAt }
                    return $0.trip.id.uuidString < $1.trip.id.uuidString
                }
                .map(\.trip)
        }

        // Past by year
        if store.isHomeEmptyStateMockEnabled {
            cachedPastByYear = []
        } else {
            let grouped = Dictionary(grouping: store.trips.filter { isPast($0) }) {
                calendar.component(.year, from: returnDate(for: $0))
            }
            cachedPastByYear = grouped.keys.sorted(by: >).map { year in
                let trips = grouped[year, default: []].sorted { lhs, rhs in
                    let l = returnDate(for: lhs), r = returnDate(for: rhs)
                    if l != r { return l > r }
                    if lhs.departureDate != rhs.departureDate { return lhs.departureDate > rhs.departureDate }
                    if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return (year: year, trips: trips)
            }
        }
    }

    private var upcomingTrips: [TripBundle] { cachedUpcoming }
    private var pastTripsByYear: [(year: Int, trips: [TripBundle])] { cachedPastByYear }

    private func startNewTrip() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            router.path.append(CreationRoute.tripInfo(UUID(), startInMyItems: false))
        }
    }

    private func openTrip(_ bundle: TripBundle) {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            router.path.append(bundle.id)
        }
    }

    /// Opacity for GlobeMapView city dots and the map style button.
    /// Written by CarryBottomSheet.onSnapChanged via easeOut(0.18s).
    @State private var mapCityOpacity: Double = 0
    /// Set to true to programmatically collapse the sheet (Siri, map button).
    @State private var collapseRequest: Bool = false
    /// Observes the UserDefaults key written by the Dev Options toggle.
    @AppStorage(sheetVariantDefaultsKey) private var sheetVariantRaw: String = SheetVariant.fallback.rawValue
    @AppStorage("mapStyleOption") private var mapStyleRaw: String = MapStyleOption.hybrid.rawValue
    @AppStorage("hasShownFirstTripShimmer") private var hasShownFirstTripShimmer = false
    @AppStorage("firstTripCreatedAt") private var firstTripCreatedAtInterval: Double = 0
    @State private var shimmerTripId: UUID? = nil

    private static let shimmerWindowSeconds: Double = 15 * 60
    @State private var locationPermission = LocationPermissionManager()
    private var mapStyleOption: MapStyleOption {
        MapStyleOption(rawValue: mapStyleRaw) ?? .hybrid
    }

    private var expandedSheetHeight: CGFloat {
        // Reduce sheet height when empty so the CTA sits centered without
        // large blank areas. Full height is restored once trips exist.
        UIScreen.main.bounds.height * (isEffectivelyEmpty ? 0.58 : 0.90)
    }

    private var collapsedSheetOffset: CGFloat {
        max(0, expandedSheetHeight - 188)
    }

    /// Normalizes country codes so that HK, MO, and TW are treated as CN.
    /// This ensures Hong Kong, Macau, and Taiwan are not counted as
    /// independent countries in trip statistics or globe highlights.
    private static func normalizedCountryCode(_ code: String) -> String {
        switch code.uppercased() {
        case "HK", "MO", "TW": return "CN"
        default: return code.uppercased()
        }
    }

    /// Unique country codes from all trips whose departure date has passed.
    /// Includes both the primary destination and any additional destinations
    /// stored for multi-city trips.
    private var visitedCountriesCount: Int {
        var codes = Set<String>()
        for trip in store.trips where trip.departureDate <= Date() {
            if !trip.countryCode.isEmpty { codes.insert(Self.normalizedCountryCode(trip.countryCode)) }
            for dest in trip.additionalDestinations where !dest.countryCode.isEmpty {
                codes.insert(Self.normalizedCountryCode(dest.countryCode))
            }
        }
        return codes.count
    }

    /// Deduplicated city dots for departed trips with valid coordinates.
    /// Rounded to ~1 km precision so multiple trips to the same city collapse to one dot.
    /// Includes additional destinations from multi-city trips.
    private var visitedCities: [VisitedCity] {
        // key → index in cities array
        var keyIndex: [String: Int] = [:]
        var cities: [VisitedCity] = []

        func addCoordinate(lat: Double, lon: Double, name: String = "") {
            guard lat != 0 else { return }
            let key = "\(Int(lat * 100)),\(Int(lon * 100))"
            if let idx = keyIndex[key] {
                // Already seen this coordinate — upgrade the name if we now have one
                if !name.isEmpty && cities[idx].cityName.isEmpty {
                    cities[idx] = VisitedCity(
                        id: key,
                        coordinate: cities[idx].coordinate,
                        cityName: name
                    )
                }
            } else {
                keyIndex[key] = cities.count
                cities.append(VisitedCity(
                    id: key,
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    cityName: name
                ))
            }
        }

        for trip in store.trips where trip.departureDate <= Date() {
            // Split using the same separators as geocoding so token[n] aligns with destination[n]
            var raw = [trip.destinationCity]
            for sep in [" and ", " And ", " AND ", " 和 "] {
                raw = raw.flatMap { $0.components(separatedBy: sep) }
            }
            for sep in [",", "，", "、", "/", "／", "&", "＆", "+", "＋"] {
                raw = raw.flatMap { $0.components(separatedBy: sep) }
            }
            let tokens = raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

            addCoordinate(lat: trip.latitude, lon: trip.longitude, name: tokens.first ?? "")
            for (idx, dest) in trip.additionalDestinations.enumerated() {
                addCoordinate(lat: dest.latitude, lon: dest.longitude,
                              name: (idx + 1) < tokens.count ? tokens[idx + 1] : "")
            }
        }
        return cities
    }

    private var visitedCountries: [VisitedCountry] {
        // For each country code, keep the coordinates from the most-recent trip that includes it.
        // HK/MO/TW are normalized to CN so they appear as a single China pin on the globe.
        var best: [String: (lat: Double, lon: Double, date: Date)] = [:]

        func consider(code: String, lat: Double, lon: Double, date: Date) {
            guard !code.isEmpty, lat != 0 else { return }
            let normalized = Self.normalizedCountryCode(code)
            // When normalizing to CN, use the China centroid so the pin lands correctly.
            let (pinLat, pinLon): (Double, Double) = {
                if normalized != code.uppercased(),
                   let centroid = GeocodingData.countryCentroid(for: normalized) {
                    return (centroid.lat, centroid.lon)
                }
                return (lat, lon)
            }()
            if let existing = best[normalized] {
                if date > existing.date { best[normalized] = (pinLat, pinLon, date) }
            } else {
                best[normalized] = (pinLat, pinLon, date)
            }
        }

        for trip in store.trips where trip.departureDate <= Date() {
            consider(code: trip.countryCode, lat: trip.latitude, lon: trip.longitude, date: trip.departureDate)
            for dest in trip.additionalDestinations {
                consider(code: dest.countryCode, lat: dest.latitude, lon: dest.longitude, date: trip.departureDate)
            }
        }

        return best.map { code, info in
            let name = Locale.current.localizedString(forRegionCode: code) ?? code
            return VisitedCountry(
                countryCode: code,
                name: name,
                coordinate: CLLocationCoordinate2D(latitude: info.lat, longitude: info.lon)
            )
        }
    }

    var body: some View {
        ZStack {
            // Globe — stays completely static; only updated by mapCityOpacity easeOut
            GlobeMapView(
                visitedCountries: visitedCountries,
                visitedCities: visitedCities,
                cityOpacity: mapCityOpacity,
                mapStyleOption: mapStyleOption,
                showUserLocation: locationPermission.isTracking
            )
            .equatable()
            .ignoresSafeArea()

            // Map controls — fade in as sheet collapses
            mapStyleButton
                .ignoresSafeArea(edges: .top)

            // Bottom sheet — UIKit-driven, zero SwiftUI re-evaluates during animation.
            // Variant is controlled by SheetFeatureFlag / Dev Options toggle.
            Group {
                switch SheetVariant(rawValue: sheetVariantRaw) ?? .fallback {
                case .fallback:
                    CarryBottomSheet(
                        expandedHeight: expandedSheetHeight,
                        collapsedOffset: collapsedSheetOffset,
                        mapCityOpacity: $mapCityOpacity,
                        collapseRequest: $collapseRequest,
                        isListEmpty: isEffectivelyEmpty
                    ) {
                        sheetContent
                    }
                case .ultimate:
                    CarryBottomSheetFX(
                        expandedHeight: expandedSheetHeight,
                        collapsedOffset: collapsedSheetOffset,
                        mapCityOpacity: $mapCityOpacity,
                        collapseRequest: $collapseRequest,
                        isListEmpty: isEffectivelyEmpty
                    ) {
                        sheetContent
                    }
                }
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Sheet content (hosted inside UIHostingController by CarryBottomSheet)

    @ViewBuilder
    private var sheetContent: some View {
        VStack(spacing: 0) {
            // Drag handle — no gesture needed; SheetViewController.sheetPan handles it
            Capsule()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity)

            if isEffectivelyEmpty {
                VStack(spacing: 4) {
                    Text("home.empty.header.title")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("home.empty.header.subtitle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary.opacity(colorScheme == .dark ? 0.97 : 0.89))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)
                .padding(.bottom, 20)
                .padding(.horizontal, 26)
                .frame(maxWidth: .infinity)
            }

            ZStack {
                List {
                    if !isEffectivelyEmpty {
                        heroSection
                            .opacity(initialRevealProgress >= heroRevealThreshold ? 1 : 0)
                            .offset(y: initialRevealProgress >= heroRevealThreshold ? 0 : 12)
                            .scaleEffect(initialRevealProgress >= heroRevealThreshold ? 1 : 0.99)
                            .animation(.easeOut(duration: 0.26), value: initialRevealProgress)
                            .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 4, trailing: 12))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)

                        upcomingSection
                        pastSection

                        listFooter
                            .opacity(initialRevealProgress >= pastRevealThreshold ? 1 : 0)
                            .offset(y: initialRevealProgress >= pastRevealThreshold ? 0 : 8)
                            .animation(.easeOut(duration: 0.20), value: initialRevealProgress)
                            .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 4, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)

                        Color.clear
                            .frame(height: colorScheme == .dark ? 124 : 72)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                .id(listIdentity)
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .background(Color.clear)

                if isEffectivelyEmpty {
                    emptyState
                }
            }
            .frame(maxHeight: .infinity)
            .overlay {
                if revealCurtainOpacity > 0 {
                    LinearGradient(
                        colors: [
                            Color(UIColor.systemBackground).opacity(revealCurtainOpacity),
                            Color(UIColor.systemBackground).opacity(revealCurtainOpacity * 0.5),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                store.refresh()
                store.correctMisgecodedTrips()
                store.geocodeMissingTrips()
                rebuildTripLists()
                if !didPlayInitialReveal {
                    didPlayInitialReveal = true
                    initialRevealProgress = 0
                    revealCurtainOpacity = 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                        withAnimation(.easeOut(duration: 0.22)) { revealCurtainOpacity = 0 }
                        withAnimation(.easeOut(duration: 0.52)) { initialRevealProgress = 1 }
                    }
                    triggerUpcomingReveal(after: 0.28)
                }
            }
            .onReceive(router.$path) { path in
                if path.isEmpty {
                    store.refresh()
                    rebuildTripLists()
                    if !hasShownFirstTripShimmer,
                       firstTripCreatedAtInterval > 0,
                       Date().timeIntervalSince1970 - firstTripCreatedAtInterval <= Self.shimmerWindowSeconds,
                       let first = store.trips.first {
                        hasShownFirstTripShimmer = true
                        shimmerTripId = first.id
                    }
                }
            }
            .onChange(of: store.trips) { oldTrips, newTrips in
                rebuildTripLists()
                if !hasShownFirstTripShimmer && oldTrips.isEmpty && newTrips.count == 1 {
                    firstTripCreatedAtInterval = Date().timeIntervalSince1970
                }
            }
            .onChange(of: router.showMapFullscreen) { _, show in
                guard show else { return }
                router.showMapFullscreen = false
                collapseRequest = true  // SheetViewController.snap handles the animation
            }
            .alert(
                String(format: NSLocalizedString("Delete %@?", comment: ""), tripToDelete?.name ?? ""),
                isPresented: $showDeleteConfirmation
            ) {
                Button("Delete", role: .destructive) {
                    if let trip = tripToDelete { store.removeTrip(withId: trip.id) }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will permanently delete your packing list and all progress.")
            }
        }
        .frame(maxWidth: .infinity)
        .background(CarrySubtleBackground())
    }

    // MARK: - Map style button

    private var mapStyleButton: some View {
        VStack {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Menu {
                        ForEach(MapStyleOption.allCases, id: \.rawValue) { option in
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                mapStyleRaw = option.rawValue
                            } label: {
                                Label(option.label, systemImage: option.icon)
                            }
                        }
                    } label: {
                        Image(systemName: mapStyleOption.icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 48, height: 48)
                            .background(
                                Circle()
                                    .fill(Color(UIColor.secondarySystemBackground).opacity(colorScheme == .dark ? 0.92 : 1.0))
                            )
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.05), lineWidth: 1)
                            )
                    }

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        locationPermission.handleTap()
                    } label: {
                        Image(systemName: locationPermission.isTracking ? "location.fill" : "location")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(locationPermission.isTracking ? Color.orange : Color.primary)
                            .frame(width: 48, height: 48)
                            .background(
                                Circle()
                                    .fill(Color(UIColor.secondarySystemBackground).opacity(colorScheme == .dark ? 0.92 : 1.0))
                            )
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.05), lineWidth: 1)
                            )
                    }
                }
                .padding(.trailing, 16)
                .padding(.top, 56)
            }
            Spacer()
        }
        // Fade in as sheet collapses, invisible when fully expanded
        .opacity(mapCityOpacity)
        .allowsHitTesting(mapCityOpacity > 0.05)
    }

    @ViewBuilder
    private var upcomingSection: some View {
        if !upcomingTrips.isEmpty {
            let sectionProgress = didRevealUpcoming ? 1.0 : 0.0
            sectionLabel("home.upcoming", uppercase: true)
                .opacity(sectionProgress)
                .offset(y: (1 - sectionProgress) * 14)
                .animation(.easeOut(duration: 0.22), value: didRevealUpcoming)
                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            ForEach(Array(upcomingTrips.enumerated()), id: \.element.id) { index, bundle in
                let staggerIndex = min(index, 5)
                let itemProgress = didRevealUpcoming ? 1.0 : 0.0
                tripRow(bundle: bundle, isPast: false)
                    .opacity(itemProgress)
                    .offset(y: (1 - itemProgress) * 14)
                    .scaleEffect(0.99 + itemProgress * 0.01)
                    .animation(.easeOut(duration: 0.24).delay(Double(staggerIndex) * 0.035), value: didRevealUpcoming)
            }
        }
    }

    @ViewBuilder
    private var pastSection: some View {
        ForEach(Array(pastTripsByYear.enumerated()), id: \.element.year) { index, section in
            let isFirst = upcomingTrips.isEmpty && index == 0
            let sectionDelay = 0.34 + Double(index) * 0.06
            pastSectionLabel(year: section.year, isFirst: isFirst, delay: sectionDelay)

            ForEach(Array(section.trips.enumerated()), id: \.element.id) { tripIndex, bundle in
                let cappedTripIndex = min(tripIndex, 4)
                let delay = 0.26 + Double(index) * 0.036 + Double(cappedTripIndex) * 0.016
                pastTripRow(bundle: bundle, delay: delay)
            }
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "airplane.departure")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Trip overview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(1.4)
            }

            HStack(alignment: .top) {
                Text("home.title")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                Button {
                    startNewTrip()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(UIColor.systemBackground))
                        .frame(width: 34, height: 34)
                        .background(
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.primary.opacity(0.95),
                                            Color.primary.opacity(0.82)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                            )
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
                }
                .buttonStyle(PressableScaleButtonStyle(scale: 0.92, pressedBrightness: -0.03, pressedOpacity: 0.94))
            }

            if !isEffectivelyEmpty {
                HStack(spacing: 10) {
                    statPill(value: "\(store.trips.count)", label: "home.allTrips")
                    statPill(value: "\(upcomingTrips.count)", label: "home.upcoming")
                    statPill(value: "\(visitedCountriesCount)", label: visitedCountriesCount == 1 ? "home.country" : "home.countries")
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    colorScheme == .dark
                    ? AnyShapeStyle(
                        LinearGradient(
                            colors: [
                                homeDarkHeroTop.opacity(0.92),
                                homeDarkHeroBottom.opacity(0.88)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    : AnyShapeStyle(
                        LinearGradient(
                            colors: [
                                Color(UIColor.systemBackground).opacity(0.95),
                                Color(UIColor.systemBackground).opacity(0.82)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.03 : 0.05), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.14 : 0.045), radius: colorScheme == .dark ? 12 : 16, x: 0, y: colorScheme == .dark ? 8 : 10)
    }

    private func sectionLabel(_ key: LocalizedStringKey, uppercase: Bool = false) -> some View {
        Text(key)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.98) : Color(UIColor.tertiaryLabel))
            .textCase(uppercase ? .uppercase : nil)
            .tracking(1.6)
    }

    private func sectionLabel(verbatim: String) -> some View {
        Text(verbatim: verbatim)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.98) : Color(UIColor.tertiaryLabel))
            .tracking(1.6)
    }

    private func pastSectionLabel(year: Int, isFirst: Bool, delay: Double) -> some View {
        sectionLabel(verbatim: "\(year)")
            .opacity(initialRevealProgress >= pastRevealThreshold ? 1 : 0)
            .offset(y: initialRevealProgress >= pastRevealThreshold ? 0 : 10)
            .animation(.easeOut(duration: 0.24).delay(delay), value: initialRevealProgress)
            .listRowInsets(EdgeInsets(top: isFirst ? 0 : 14, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private func pastTripRow(bundle: TripBundle, delay: Double) -> some View {
        tripRow(bundle: bundle, isPast: true)
            .opacity(initialRevealProgress >= pastRevealThreshold ? 1 : 0)
            .offset(y: initialRevealProgress >= pastRevealThreshold ? 0 : 10)
            .scaleEffect(initialRevealProgress >= pastRevealThreshold ? 1 : 0.99)
            .animation(.easeOut(duration: 0.22).delay(delay), value: initialRevealProgress)
    }

    private func statPill(value: String, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(statPillFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.015 : 0.04), lineWidth: 1)
        )
    }

    private var statPillFill: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    homeDarkStatTop,
                    homeDarkStatBottom
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [
                Color(UIColor.systemBackground).opacity(0.96),
                Color(UIColor.systemBackground).opacity(0.88)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var listFooter: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 1)

                Image(systemName: "airplane.departure")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)

                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 1)
            }
            .frame(maxWidth: 220)

            Text(homeFooterText())
                .font(.caption.weight(.medium))
                .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.9) : .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private func homeFooterText() -> String {
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        let isChinese = preferred.lowercased().hasPrefix("zh")
        if isChinese {
            return "第一次出发的地方"
        }
        return "The place where your first departure began"
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0).frame(maxHeight: 8)
            VStack(spacing: 18) {
                VStack(spacing: 14) {
                    ZStack {
                        Image("HomeEmptyTrip1")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 114, height: 78)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .rotationEffect(.degrees(-14))
                            .offset(x: -52, y: 2)
                            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.10 : 0.08), radius: 10, x: 0, y: 5)

                        Image("HomeEmptyTrip2")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 118, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.10 : 0.08), radius: 10, x: 0, y: 5)

                        Image("HomeEmptyTrip3")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 114, height: 78)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .rotationEffect(.degrees(14))
                            .offset(x: 52, y: 2)
                            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.10 : 0.08), radius: 10, x: 0, y: 5)
                    }
                    .frame(height: 130)
                    .padding(.top, 6)

                    Text("home.empty.title")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.top, -1)
                        .padding(.horizontal, 26)
                }

                Button {
                    startNewTrip()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "airplane.departure")
                            .font(.system(size: 13, weight: .semibold))
                        Text("home.empty.cta")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Color(UIColor.systemBackground))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.primary.opacity(0.90),
                                        Color.primary.opacity(0.76)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.14 : 0.08), radius: 10, x: 0, y: 5)
                }
                .buttonStyle(PressableScaleButtonStyle(scale: 0.97, pressedBrightness: -0.02, pressedOpacity: 0.95))
                .padding(.horizontal, 26)
            }
            .padding(.vertical, 22)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(UIColor.systemBackground).opacity(colorScheme == .dark ? 0.60 : 0.86),
                                Color(UIColor.systemBackground).opacity(colorScheme == .dark ? 0.48 : 0.74)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.035), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.10 : 0.08), radius: 14, x: 0, y: 8)
            .padding(.horizontal, 22)
            Spacer(minLength: 72)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Sheet drag in empty-state area handled by SheetViewController.sheetPan
    }

    @ViewBuilder
    private func tripRow(bundle: TripBundle, isPast: Bool) -> some View {
        Button {
            openTrip(bundle)
        } label: {
            TripCard(bundle: bundle, isPast: isPast, shimmer: bundle.id == shimmerTripId)
        }
        .buttonStyle(PressableScaleButtonStyle(scale: 0.982, pressedBrightness: -0.02, pressedOpacity: 0.96))
        .id("\(bundle.id.uuidString)-\(bundle.packedCount)-\(bundle.totalCount)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .none) {
                tripToDelete = bundle
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                // Force-close any active swipe row state before mutating data to avoid
                // temporary blank placeholder gaps in List.
                listIdentity = UUID()
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.24)) {
                        _ = store.duplicateTrip(withId: bundle.id)
                    }
                }
            } label: {
                Label("trip.swipe.duplicate", systemImage: "doc.on.doc")
            }
            .tint(.blue)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

}

// MARK: - Trip Card

struct TripCard: View {

    @Environment(\.colorScheme) private var colorScheme

    let bundle: TripBundle
    var isPast: Bool = false
    var shimmer: Bool = false

    @State private var shimmerProgress: CGFloat = 0
    @State private var didPlayShimmer = false

    private var progress: Double {
        bundle.totalCount == 0 ? 0 : Double(bundle.packedCount) / Double(bundle.totalCount)
    }
    
    private var dateAndDurationText: String {
        let format = NSLocalizedString("%@ · %lld days", comment: "Trip date range and duration")
        return String(format: format, locale: Locale.current, bundle.localizedDateRange, Int64(bundle.days))
    }

    private var remainingText: String {
        if isComplete { return NSLocalizedString("packing.complete.status", comment: "All items packed") }
        let left = bundle.totalCount - bundle.packedCount
        let format = NSLocalizedString("%lld left", comment: "Remaining item count")
        return String(format: format, locale: Locale.current, Int64(left))
    }

    private var isComplete: Bool {
        bundle.totalCount > 0 && bundle.packedCount == bundle.totalCount
    }

    private var destinationTextColor: Color {
        if isPast {
            return colorScheme == .dark ? Color.white.opacity(0.62) : Color(uiColor: .secondaryLabel)
        }
        return Color(uiColor: .secondaryLabel)
    }

    private var dateTextColor: Color {
        if isPast {
            return colorScheme == .dark ? Color.white.opacity(0.45) : Color(uiColor: .tertiaryLabel)
        }
        return colorScheme == .dark ? Color.white.opacity(0.44) : Color(uiColor: .tertiaryLabel)
    }

    private var progressMetaTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.62) : Color(uiColor: .secondaryLabel)
    }

    private var progressTrackColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.05)
            : Color(uiColor: .systemGray5)
    }

    private var cardFill: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    homeDarkCardTopRefined,
                    homeDarkCardBottomRefined
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        return LinearGradient(
            colors: [
                Color(UIColor.systemBackground).opacity(0.90),
                Color(UIColor.systemBackground).opacity(0.84)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var cardShadow: Color {
        if colorScheme == .dark {
            return Color.black.opacity(0.16)
        }
        return Color.black.opacity(0.068)
    }

    private var statusPillText: String? {
        guard !isPast else { return nil }
        if bundle.totalCount == 0 {
            return NSLocalizedString("home.empty.items", comment: "No items in packing list")
        }
        if isComplete {
            return NSLocalizedString("home.packed.all", comment: "All items packed")
        }
        let left = bundle.totalCount - bundle.packedCount
        let format = NSLocalizedString("%lld left", comment: "Remaining item count")
        return String(format: format, locale: Locale.current, Int64(left))
    }

    private var statusPillFillColor: Color {
        if bundle.totalCount == 0 {
            return colorScheme == .dark ? Color.white.opacity(0.028) : Color(UIColor.systemGray5).opacity(0.58)
        }
        if isComplete {
            return colorScheme == .dark ? Color.white.opacity(0.032) : Color(UIColor.systemGray5).opacity(0.72)
        }
        if colorScheme == .dark {
            return Color.white.opacity(0.045)
        }
        return Color(UIColor.systemGray5).opacity(0.80)
    }

    private var statusPillStrokeColor: Color {
        if bundle.totalCount == 0 {
            return Color.primary.opacity(colorScheme == .dark ? 0.025 : 0.03)
        }
        if isComplete {
            return Color.primary.opacity(colorScheme == .dark ? 0.03 : 0.025)
        }
        if colorScheme == .dark {
            return Color.white.opacity(0.09)
        }
        return Color.primary.opacity(0.07)
    }

    private var statusPillForeground: Color {
        if bundle.totalCount == 0 {
            return colorScheme == .dark ? .secondary.opacity(0.72) : .secondary.opacity(0.82)
        }
        if isComplete {
            return colorScheme == .dark ? .secondary.opacity(0.74) : .secondary.opacity(0.76)
        }
        return .primary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(isPast ? 0.10 : 0.34),
                            Color.primary.opacity(isPast ? 0.04 : 0.14)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 2.5, height: isPast ? 48 : 62)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(bundle.name)
                        .font(.headline.weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
                .padding(.bottom, 3)

                Text(bundle.destinationCity)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(colorScheme == .dark ? Color.white.opacity(0.64) : Color(.systemGray))
                    .lineLimit(1)
                    .padding(.bottom, 4)

                HStack(spacing: 8) {
                    Text(dateAndDurationText)
                        .font(.caption.weight(.medium))
                        .foregroundColor(colorScheme == .dark ? Color.white.opacity(0.40) : Color(.systemGray2))
                        .lineLimit(1)

                    if let statusPillText {
                        Spacer(minLength: 8)
                        statusPill(statusPillText)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: isComplete)

                if !isPast && !isComplete {
                    Color.clear.frame(height: 10)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(progressTrackColor)
                                .frame(height: 3)
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.primary.opacity(0.90),
                                            Color.primary.opacity(0.64)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(0, geo.size.width * progress), height: 3)
                                .animation(.spring(response: 0.42, dampingFraction: 0.82), value: progress)
                        }
                    }
                    .frame(height: 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 13)
        .padding(.bottom, 13)
        .padding(.horizontal, 18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: cardShadow, radius: 14, x: 0, y: 7)
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            if shimmer {
                GeometryReader { geo in
                    let w = geo.size.width
                    let stripW = w * 0.62
                    let peakOpacity: Double = colorScheme == .dark ? 0.10 : 0.48
                    let midOpacity: Double = colorScheme == .dark ? 0.05 : 0.26
                    return LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(midOpacity), location: 0.3),
                            .init(color: .white.opacity(peakOpacity), location: 0.5),
                            .init(color: .white.opacity(midOpacity), location: 0.7),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: stripW)
                    .offset(x: -stripW + (w + stripW) * shimmerProgress)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            playShimmerIfNeeded()
        }
        .onChange(of: shimmer) { _, newValue in
            guard newValue else { return }
            playShimmerIfNeeded()
        }
    }

    private func playShimmerIfNeeded() {
        guard shimmer, !didPlayShimmer else { return }
        didPlayShimmer = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            withAnimation(.easeInOut(duration: 0.72)) {
                shimmerProgress = 1
            }
        }
    }

    private func statusPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(statusPillForeground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(statusPillFillColor)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(statusPillStrokeColor, lineWidth: 1)
            )
    }
}

struct PressableScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    var pressedBrightness: Double = 0
    var pressedOpacity: Double = 1.0

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .brightness(configuration.isPressed ? pressedBrightness : 0)
            .opacity(configuration.isPressed ? pressedOpacity : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}


// MARK: - Preview

#Preview {
    HomeView()
        .environmentObject(TripStore())
        .environmentObject(NavigationRouter())
}

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

// MARK: - Empty-state card height measurement

private struct EmptyCardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - HomeView

struct HomeView: View {

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var store: TripStore
    @EnvironmentObject var router: NavigationRouter

    @State private var tripToDelete: TripBundle?
    @State private var showDeleteConfirmation = false
    @State private var showSettings = false
    @State private var settingsPath = NavigationPath()
    @State private var showSearch = false
    @State private var showTripBook = false
    @State private var searchText = ""
    @State private var listIdentity = UUID()
    @State private var didPlayInitialReveal = false
    @State private var initialRevealProgress: Double = 0
    @State private var revealCurtainOpacity: Double = 1

    // 全部分组(Hero / Upcoming / Planning / Past)统一由 initialRevealProgress(0→1)
    // 按阈值揭示，形成一条连续级联，不再有独立的 didRevealUpcoming 状态。
    private let heroRevealThreshold: Double = 0.16
    private let listRevealThreshold: Double = 0.58
    private let pastRevealThreshold: Double = 0.78

    // Cached sorted trip lists — recomputed only when store.trips changes,
    // not on every body re-evaluation (e.g. initialRevealProgress animation ticks).
    @State private var cachedUpcoming: [TripBundle] = []
    @State private var cachedPlanning: [TripBundle] = []
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

        // Upcoming（排除无日期「规划中」行程——其占位 departureDate 不能参与时间判定）
        if store.isHomeEmptyStateMockEnabled {
            cachedUpcoming = []
        } else {
            struct Decorated { let trip: TripBundle; let isComplete: Bool }
            let decorated = store.trips
                .filter { !$0.isDateless && !isPast($0) }
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

        // Planning（无日期行程，单独分组，按创建时间倒序）
        if store.isHomeEmptyStateMockEnabled {
            cachedPlanning = []
        } else {
            cachedPlanning = store.trips
                .filter { $0.isDateless }
                .sorted {
                    if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
        }

        // Past by year（同样排除无日期行程）
        if store.isHomeEmptyStateMockEnabled {
            cachedPastByYear = []
        } else {
            let grouped = Dictionary(grouping: store.trips.filter { !$0.isDateless && isPast($0) }) {
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
    private var planningTrips: [TripBundle] { cachedPlanning }
    private var pastTripsByYear: [(year: Int, trips: [TripBundle])] { cachedPastByYear }
    private var searchableTrips: [TripBundle] { store.trips }
    private var filteredSearchTrips: [TripBundle] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return searchableTrips }
        let lowered = query.lowercased()
        return searchableTrips.filter {
            $0.name.lowercased().contains(lowered)
                || $0.destinationCity.lowercased().contains(lowered)
                || $0.localizedDateRange.lowercased().contains(lowered)
        }
    }

    private func startNewTrip() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            router.path.append(CreationRoute.tripInfo(UUID(), startInMyItems: false))
        }
    }

    private func openSettings() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showSettings = true
    }

    private func openSearch() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showSearch = true
    }

    private func openTripBook() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showTripBook = true
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
    @AppStorage("mapStyleOption") private var mapStyleRaw: String = MapStyleOption.hybrid.rawValue
    @AppStorage("hasShownFirstTripShimmer") private var hasShownFirstTripShimmer = false
    @AppStorage("firstTripCreatedAt") private var firstTripCreatedAtInterval: Double = 0
    @State private var shimmerTripId: UUID? = nil

    private static let shimmerWindowSeconds: Double = 15 * 60
    @State private var locationPermission = LocationPermissionManager()
    private var mapStyleOption: MapStyleOption {
        MapStyleOption(rawValue: mapStyleRaw) ?? .hybrid
    }

    /// Measured natural height of the empty-state card (driven by SwiftUI layout,
    /// so it tracks Dynamic Type / localized title length instead of a guessed constant).
    @State private var emptyCardHeight: CGFloat = 0

    private var expandedSheetHeight: CGFloat {
        guard isEffectivelyEmpty else {
            return UIScreen.main.bounds.height * 0.86
        }
        // Empty state: size the sheet to its CONTENT, not a screen-height fraction —
        // so the gap below the card is constant across devices (the old 0.44 fraction
        // left ~65pt of slack on large phones, ~15pt on small ones). The card is laid
        // out at its natural height (measured below) and we add a fixed breathing gap +
        // the home-indicator safe area so the CTA always clears the bottom edge.
        let handle: CGFloat = 21          // capsule: padding(top10) + h5 + padding(bottom6)
        let topBar: CGFloat = 6 + 40 + 8  // homeTopBar padding(top6,bottom8) + 40pt avatar row
        let cardTopInset: CGFloat = 6     // emptyState .padding(.top, 6)
        let bottomBreathing: CGFloat = 28 // gap between content bottom and the safe-area inset
        let card = emptyCardHeight > 0 ? emptyCardHeight : 244  // 244 ≈ natural content height (fallback)
        return handle + topBar + cardTopInset + card + bottomBreathing + Self.bottomSafeAreaInset
    }

    /// Bottom safe-area inset (home indicator). The sheet's content host is flush with
    /// the physical screen bottom, so this must be folded into the empty-state height.
    private static var bottomSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.safeAreaInsets.bottom ?? 0
    }

    private var collapsedSheetOffset: CGFloat {
        max(0, expandedSheetHeight - 188)
    }

    /// Normalizes HK, MO, TW → CN only for the mainland China App Store storefront,
    /// where local regulations require treating them as part of China.
    /// All other storefronts preserve the original country code.
    private static func normalizedCountryCode(_ code: String) -> String {
        guard isChinaStorefront else { return code.uppercased() }
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
        for trip in store.trips where trip.countsAsVisited {
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

        for trip in store.trips where trip.countsAsVisited {
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
        // HK/MO/TW are normalized to CN on the mainland China storefront only.
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

        for trip in store.trips where trip.countsAsVisited {
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
        #if targetEnvironment(macCatalyst)
        macBody
        #else
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
            CarryBottomSheetFX(
                expandedHeight: expandedSheetHeight,
                collapsedOffset: collapsedSheetOffset,
                mapCityOpacity: $mapCityOpacity,
                collapseRequest: $collapseRequest,
                isListEmpty: isEffectivelyEmpty
            ) {
                sheetContent
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea(edges: .bottom)
        .safeAreaInset(edge: .bottom) {
            if !isEffectivelyEmpty {
                bottomActionBar
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack(path: $settingsPath) {
                SettingsView(path: $settingsPath)
            }
            .tint(CarryAccent.color)
        }
        .sheet(isPresented: $showSearch) {
            NavigationStack {
                searchSheet
            }
            .tint(CarryAccent.color)
        }
        .sheet(isPresented: $showTripBook) {
            tripBookSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        #endif
    }

    // MARK: - Mac Catalyst layout

    #if targetEnvironment(macCatalyst)
    private var macBody: some View {
        List {
            if !isEffectivelyEmpty {
                upcomingSection
                planningSection
                pastSection
                listFooter
                    .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                Color.clear.frame(height: 20)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if isEffectivelyEmpty { emptyState }
        }
        .onAppear {
            initialRevealProgress = 1.0
            store.refresh()
            store.correctMisgecodedTrips()
            store.geocodeMissingTrips()
            rebuildTripLists()
            CarryLogger.shared.log(.mapOpened)
        }
        .onReceive(router.$path) { path in
            if path.isEmpty {
                store.refresh()
                rebuildTripLists()
            }
        }
        .onChange(of: store.trips) { _, _ in rebuildTripLists() }
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
    #endif

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

            homeTopBar
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 8)

            ZStack {
                List {
                    if !isEffectivelyEmpty {
                        upcomingSection
                        planningSection
                        pastSection

                        listFooter
                            .opacity(initialRevealProgress >= pastRevealThreshold ? 1 : 0)
                            .offset(y: initialRevealProgress >= pastRevealThreshold ? 0 : 8)
                            .animation(.easeOut(duration: 0.20), value: initialRevealProgress)
                            .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 4, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)

                        Color.clear
                            .frame(height: colorScheme == .dark ? 176 : 124)
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
                        // 同一条 ramp 驱动 Hero/Upcoming/Planning/Past 的阈值揭示，
                        // 无需再用 asyncAfter 单独对齐 Upcoming 的时序。
                        withAnimation(.easeOut(duration: 0.52)) { initialRevealProgress = 1 }
                    }
                }
            }
            .onReceive(router.$path) { path in
                if path.isEmpty {
                    store.refresh()
                    rebuildTripLists()
                    // 从 Widget / Quick Action 深链进入时会先 push 目标页，冷启动揭示动画
                    // 可能在用户看不到首页时就已播放/未播完。回到首页根（path 清空）时兜底
                    // 把 initialRevealProgress 推到 1，确保所有分组（含 Upcoming/Planning）可见。
                    if initialRevealProgress < 1 {
                        withAnimation(.easeOut(duration: 0.30)) { initialRevealProgress = 1 }
                    }
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
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        let all = MapStyleOption.allCases
                        let next = ((all.firstIndex(of: mapStyleOption) ?? 0) + 1) % all.count
                        mapStyleRaw = all[next].rawValue
                        CarryLogger.shared.log(.mapStyleChanged, context: "style=\(all[next].rawValue)")
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
                    .buttonStyle(.plain)

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
            let revealed = initialRevealProgress >= listRevealThreshold
            let sectionProgress = revealed ? 1.0 : 0.0
            sectionLabel("home.upcoming", uppercase: true)
                .opacity(sectionProgress)
                .offset(y: (1 - sectionProgress) * 14)
                .animation(.easeOut(duration: 0.22), value: initialRevealProgress)
                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            ForEach(Array(upcomingTrips.enumerated()), id: \.element.id) { index, bundle in
                let staggerIndex = min(index, 5)
                let itemProgress = revealed ? 1.0 : 0.0
                tripRow(bundle: bundle, isPast: false)
                    .opacity(itemProgress)
                    .offset(y: (1 - itemProgress) * 14)
                    .scaleEffect(0.99 + itemProgress * 0.01)
                    .animation(.easeOut(duration: 0.24).delay(Double(staggerIndex) * 0.035), value: initialRevealProgress)
            }
        }
    }

    @ViewBuilder
    private var planningSection: some View {
        if !planningTrips.isEmpty {
            // 与 Upcoming 共用同一阈值 listRevealThreshold，保持折叠线内分组揭示节奏一致；
            // 基准 delay 让 Planning 读起来是接在 Upcoming 之后浮入，避免断层。
            let revealed = initialRevealProgress >= listRevealThreshold
            let sectionProgress = revealed ? 1.0 : 0.0
            sectionLabel("home.planning", uppercase: true)
                .opacity(sectionProgress)
                .offset(y: (1 - sectionProgress) * 14)
                .animation(.easeOut(duration: 0.22).delay(0.08), value: initialRevealProgress)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            ForEach(Array(planningTrips.enumerated()), id: \.element.id) { index, bundle in
                let staggerIndex = min(index, 5)
                let itemProgress = revealed ? 1.0 : 0.0
                tripRow(bundle: bundle, isPast: false)
                    .opacity(itemProgress)
                    .offset(y: (1 - itemProgress) * 14)
                    .scaleEffect(0.99 + itemProgress * 0.01)
                    .animation(.easeOut(duration: 0.24).delay(0.10 + Double(staggerIndex) * 0.035), value: initialRevealProgress)
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

    private var homeTopBar: some View {
        HStack(alignment: .center) {
            Text("home.title")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 12)

            Button {
                openSettings()
            } label: {
                Image("Murphy")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    .background(
                        Circle()
                            .fill(Color(UIColor.systemBackground).opacity(colorScheme == .dark ? 0.92 : 0.98))
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.08 : 0.05), radius: 5, x: 0, y: 2)
            }
            .buttonStyle(PressableScaleButtonStyle(scale: 0.94, pressedBrightness: -0.02, pressedOpacity: 0.95))
            .accessibilityLabel(Text("Settings"))
        }
    }

    private var bottomActionBar: some View {
        HStack(spacing: 14) {
            bottomSearchButton
            bottomTripBookButton
            bottomCreateButton
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var bottomSearchButton: some View {
        Button {
            openSearch()
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 54, height: 54)
                .background(glassSurfaceBackground(Circle()))
                .clipShape(Circle())
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.14), radius: 16, x: 0, y: 9)
        }
        .buttonStyle(PressableScaleButtonStyle(scale: 0.95, pressedBrightness: -0.02, pressedOpacity: 0.95))
        .accessibilityLabel(Text("Search"))
    }

    @ViewBuilder
    private var bottomTripBookButton: some View {
        Button {
            openTripBook()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Trip Book")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("\(store.trips.count) 个行程，\(visitedCountriesCount) 个国家")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(glassSurfaceBackground(RoundedRectangle(cornerRadius: 26, style: .continuous)))
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.14), radius: 16, x: 0, y: 9)
        }
        .buttonStyle(PressableScaleButtonStyle(scale: 0.985, pressedBrightness: -0.02, pressedOpacity: 0.97))
        .accessibilityLabel(Text("Trip Book"))
    }

    @ViewBuilder
    private var bottomCreateButton: some View {
        Button {
            startNewTrip()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    CarryAccent.color.opacity(0.96),
                                    CarryAccent.color.opacity(0.86)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.26), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.40 : 0.22), radius: 18, x: 0, y: 10)
                )
        }
        .buttonStyle(PressableScaleButtonStyle(scale: 0.95, pressedBrightness: -0.03, pressedOpacity: 0.96))
        .accessibilityLabel(Text("home.create_trip"))
    }

    private func glassSurfaceBackground<S: InsettableShape>(_ shape: S) -> some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(
                shape
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.02 : 0.20))
            )
            .overlay(
                shape
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.34), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.10), radius: 14, x: 0, y: 8)
    }

    private var tripBookSheet: some View {
        NavigationStack {
            List {
                Section {
                    statRow(value: "\(store.trips.count)", label: "home.allTrips")
                    statRow(value: "\(upcomingTrips.count)", label: "home.upcoming")
                    statRow(value: "\(visitedCountriesCount)", label: visitedCountriesCount == 1 ? "home.country" : "home.countries")
                }

                Section {
                    Button {
                        openSearch()
                    } label: {
                        Label("Search trips", systemImage: "magnifyingglass")
                    }
                    Button {
                        showTripBook = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            startNewTrip()
                        }
                    } label: {
                        Label("Create trip", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Trip Book")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var searchSheet: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search trips", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .submitLabel(.search)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(UIColor.secondarySystemBackground))
                )

                Button("Cancel") {
                    searchText = ""
                    showSearch = false
                }
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(CarryAccent.color)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            List {
                if filteredSearchTrips.isEmpty {
                    Text(searchText.isEmpty ? "No trips yet" : "No matching trips")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(filteredSearchTrips, id: \.id) { trip in
                        Button {
                            showSearch = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                openTrip(trip)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(trip.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(trip.destinationCity)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(trip.localizedDateRange)
                                    .font(.caption)
                                    .foregroundStyle(.secondary.opacity(0.8))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(CarrySubtleBackground())
        .onAppear {
            searchText = ""
        }
    }

    private func statRow(value: String, label: LocalizedStringKey) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.headline.weight(.bold))
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
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
            // Single clean surface: photos / title / CTA breathe directly on the sheet —
            // no nested card panel (panel-on-panel reads heavier than Apple's empty states).
            VStack(spacing: 0) {
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
                .frame(height: 108)  // hug the photo stack (≈105pt rotated extent) — trims the dead air under the header

                // Title — rounded to match the 30pt "我的行程" header (same typeface family).
                Text("home.empty.title")
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.top, 14)

                // CTA gets the most air below the message (clear message → action hierarchy).
                Button {
                    startNewTrip()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "airplane.departure")
                            .font(.system(size: 14, weight: .semibold))
                        Text("home.empty.cta")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    }
                    .foregroundStyle(Color(UIColor.systemBackground))
                    .padding(.horizontal, 28)  // hug the label — a centered invitation pill,
                    .frame(height: 52)         // not an edge-to-edge form bar (matches the centered column)
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
                .padding(.top, 22)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .background(
                // Measure the content's natural height so expandedSheetHeight can size the
                // sheet to content (device-independent bottom gap).
                GeometryReader { proxy in
                    Color.clear.preference(key: EmptyCardHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 6)
        .onPreferenceChange(EmptyCardHeightKey.self) { height in
            if height > 0 { emptyCardHeight = height }
        }
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
            .tint(CarryAccent.color)
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

    /// The trip's background entry (photo + chosen crop), if the user set one.
    private var featuredEntry: TripBackgroundEntry? {
        guard let entry = bundle.primaryBackground,
              entry.localFileName != nil else { return nil }
        return entry
    }

    /// The full (uncropped) photo — framing is applied at display by PositionedImage.
    private var featuredPhoto: UIImage? {
        guard let name = featuredEntry?.localFileName else { return nil }
        return BackgroundImageStore.image(named: name)
    }

    /// True when the card is rendered over a filled photo → text/chips switch to light.
    private var onPhoto: Bool { featuredPhoto != nil }

    @State private var shimmerProgress: CGFloat = 0
    @State private var didPlayShimmer = false

    // MARK: Redesign style helpers

    /// The "live" accent for spine + progress.
    // Over a photo the accent (a dark colour in Light mode) reads as a black bar; switch the
    // spine + progress fill to white so they match the white text on the scrimmed photo.
    private var styleAccent: Color { onPhoto ? .white : Color.accentColor }

    private var progress: Double {
        bundle.totalCount == 0 ? 0 : Double(bundle.packedCount) / Double(bundle.totalCount)
    }
    
    private var dateAndDurationText: String {
        // 无日期「规划中」行程不显示日期区间，改显示轻标签。
        if bundle.isDateless {
            return NSLocalizedString("trip.card.no_dates", comment: "Planning trip with no dates set")
        }
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
        if onPhoto { return Color.white.opacity(0.28) }   // translucent white track over a photo
        return colorScheme == .dark
            ? Color.white.opacity(0.05)
            : Color.primary.opacity(0.14)
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
                Color(UIColor.systemBackground).opacity(0.88),
                Color(UIColor.systemBackground).opacity(0.82)
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

    /// Leading accent spine for the compact card (white over a photo, muted for past trips).
    private var cardLeading: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(
                LinearGradient(
                    colors: onPhoto
                        ? [Color.white.opacity(0.95), Color.white.opacity(0.6)]   // white spine over a photo (incl. past)
                        : (isPast
                            ? [Color.primary.opacity(0.10), Color.primary.opacity(0.04)]
                            : [styleAccent.opacity(0.95), styleAccent.opacity(0.55)]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: isPast ? 2.5 : 3.5, height: isPast ? 48 : 62)
            .padding(.top, 2)
    }

    /// The card's actual background: a filled photo (2·Map with a user photo) over the original
    /// card, else the normal style surface. Photo gets a dark scrim so the text stays legible.
    @ViewBuilder
    private var cardBackground: some View {
        if let photo = featuredPhoto {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground))
                .overlay(
                    PositionedImage(image: photo, crop: featuredEntry?.crop)
                )
                .overlay(
                    LinearGradient(
                        colors: [.black.opacity(0.14), .black.opacity(0.28), .black.opacity(0.66)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            cardSurface
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.03 : 0.06),
                            Color.clear,
                            Color.black.opacity(colorScheme == .dark ? 0.06 : 0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.045), lineWidth: 1)
                )
        }
    }

    /// The card's monochrome surface (used when there's no photo to fill it).
    private var cardSurface: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(cardFill)
            .shadow(color: colorScheme == .dark ? .clear : Color.black.opacity(0.028), radius: 7, x: 0, y: 3)
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
            return colorScheme == .dark ? Color.white.opacity(0.022) : Color(UIColor.systemGray5).opacity(0.52)
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

    /// True when this card should render as a full-bleed destination banner (map style,
    /// upcoming/planning trips with a coordinate). Past trips stay compact thumbnail rows.
    var body: some View {
        compactCard
    }

    private var cardInner: some View {
        HStack(alignment: .top, spacing: 12) {
            cardLeading

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(bundle.name)
                        .font(.headline.weight(.semibold))
                        .foregroundColor(onPhoto ? .white : .primary)
                        .shadow(color: onPhoto ? .black.opacity(0.35) : .clear, radius: 2, y: 1)
                        .lineLimit(1)
                }
                .padding(.bottom, 3)

                Text(bundle.destinationCity)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(onPhoto ? Color.white.opacity(0.88) : (colorScheme == .dark ? Color.white.opacity(0.64) : Color(.systemGray)))
                    .shadow(color: onPhoto ? .black.opacity(0.3) : .clear, radius: 1.5, y: 0.5)
                    .lineLimit(1)
                    .padding(.bottom, 4)

                HStack(spacing: 8) {
                    Text(dateAndDurationText)
                        .font(.caption.weight(.medium))
                        .foregroundColor(onPhoto ? Color.white.opacity(0.78) : (colorScheme == .dark ? Color.white.opacity(0.40) : Color(.systemGray2)))
                        .shadow(color: onPhoto ? .black.opacity(0.3) : .clear, radius: 1.5, y: 0.5)
                        .lineLimit(1)

                    if let statusPillText {
                        Spacer(minLength: 8)
                        statusPill(statusPillText)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: isComplete)

                if !isPast && !isComplete {
                    Color.clear.frame(height: 8)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(progressTrackColor)
                                .frame(height: 3)
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            styleAccent,
                                            styleAccent.opacity(0.7)
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
    }

    private var compactCard: some View {
        Group {
            if onPhoto {
                // Photo card = fixed aspect K (== reposition preview) so framing is WYSIWYG.
                // The clear spacer sets a MINIMUM height (width/K); content top-aligned, so long
                // text / a progress bar just grows the card taller (revealing more photo), never
                // clipping text and never cropping the framed subject.
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .aspectRatio(BackgroundRepositionView.displayAspect, contentMode: .fit)
                    cardInner
                        .padding(.top, 13)
                        .padding(.bottom, 13)
                        .padding(.horizontal, 18)
                }
            } else {
                cardInner
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 14)
                    .padding(.bottom, 14)
                    .padding(.horizontal, 18)
            }
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    onPhoto ? Color.white.opacity(0.16) : Color.primary.opacity(0.05),
                    lineWidth: 1
                )
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
            // Over a photo the default translucent-grey chip washes out; use a dark scrim chip
            // with white text so it reads on any photo, bright or dark.
            .foregroundStyle(onPhoto ? Color.white : statusPillForeground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(onPhoto ? Color.black.opacity(0.32) : statusPillFillColor)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(onPhoto ? Color.white.opacity(0.22) : statusPillStrokeColor, lineWidth: 1)
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

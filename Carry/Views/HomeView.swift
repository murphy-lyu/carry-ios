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
fileprivate let homeDarkCardTop = Color(red: 0.10, green: 0.10, blue: 0.11)
fileprivate let homeDarkCardBottom = Color(red: 0.14, green: 0.14, blue: 0.15)
fileprivate let homeDarkCardTopRefined = Color(red: 0.09, green: 0.09, blue: 0.10)
fileprivate let homeDarkCardBottomRefined = Color(red: 0.12, green: 0.12, blue: 0.13)

// MARK: - DEBUG-only：模拟空态开关变化时重建行程列表
//
// 「模拟首页数据为空」只能由 DEBUG-only 的开发者选项拨动；该 flag 是 rebuildTripLists
// 的输入（开启时清空缓存列表），故它变化时必须重建（尤其关闭时要把列表填回来）。
// 用 ViewModifier 而非内联 `#if`：#if 落在函数体内、两个分支各返回一个完整视图，
// DEBUG / Release 两种构建配置都能确定性编译；release 下为 no-op，不携带该逻辑。
private struct DebugMockEmptyStateRefresh: ViewModifier {
    let mockEnabled: Bool
    let rebuild: () -> Void

    func body(content: Content) -> some View {
        #if DEBUG
        content.onChange(of: mockEnabled) { _, _ in rebuild() }
        #else
        content
        #endif
    }
}

// MARK: - Empty-state card height measurement

private struct EmptyCardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    /// 底栏玻璃按钮的按压样式。iOS 26 用 `.plain`——交给 `.glassEffect(.interactive())`
    /// 处理按压反馈与跟手形变；额外的缩放会把玻璃往里缩、抵消与相邻元素的水滴融合。
    /// iOS 17–25 无原生 glass，保留 `PressableScaleButtonStyle` 提供按压缩放反馈。
    @ViewBuilder
    func bottomGlassPressStyle(fallbackScale: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.plain)
        } else {
            buttonStyle(PressableScaleButtonStyle(scale: fallbackScale, pressedBrightness: -0.02, pressedOpacity: 0.96))
        }
    }
}

// MARK: - Exchange-rate observation scope

/// 把对 `ExchangeRateManager` 的观察「收」在真正用到它的子视图层（如 Trip Book 花费卡），
/// 避免在更高层观察。根 HomeView 是首页 UIKit FX sheet + 底栏的宿主：若在根层挂
/// `@ObservedObject ExchangeRateManager`，汇率每次 publish 都会让根整体失效，透过 UIKit 宿主
/// 破坏底栏按钮的命中测试（已复现：底栏三按钮永久点不动）。把观察下沉到此 scope，
/// 汇率到达时仅 scope 内的内容重算刷新，根首页与底栏不受牵连。
private struct ExchangeRateScope<Content: View>: View {
    @ObservedObject private var rate = ExchangeRateManager.shared
    @ViewBuilder let content: (ExchangeRateManager) -> Content
    var body: some View {
        content(rate)
            .onAppear { rate.fetchIfNeeded() }
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
    // Settings 以 sheet 呈现，是独立呈现上下文，不会自动继承根的 .preferredColorScheme。
    // 读同一份 appearance 设置，给 sheet 内容显式套 preferredColorScheme，使在设置页内
    // 切换外观时设置页本身也立即生效（否则要关掉重开才更新）。
    @AppStorage("appearance_mode") private var appearanceModeRaw = AppearanceMode.system.rawValue
    @AppStorage("distance_unit") private var distanceUnitRaw = DistanceUnit.automatic.rawValue
    private var distanceUnit: DistanceUnit { DistanceUnit(rawValue: distanceUnitRaw) ?? .automatic }
    @State private var showSearch = false
    @State private var showTripBook = false
    @State private var showSpendDetail = false
    @State private var showAllCountries = false
    @State private var showAllAirports = false
    @State private var searchText = ""
    @State private var searchFieldFocused: Bool = false   // 普通 Bool：CarrySearchField 内部走 UITextField，焦点不能用 @FocusState（见 IMESafeTextField）
    /// 点搜索结果时暂存目标行程；在 sheet 真正 dismiss 完成后（onDismiss）再跳转，
    /// 避免在 sheet 关闭动画期间向根 router 压栈（事件驱动，非定时延迟）。
    @State private var pendingSearchTrip: UUID?
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
            #if targetEnvironment(macCatalyst)
            router.path.append(CreationRoute.tripInfo(UUID()))
            #else
            router.beginCreation()   // 创建走 fullScreenCover（自包含任务），不压根 path
            #endif
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
            // Populated state: content-first. Leave only a deliberate, device-constant
            // sliver of globe above the sheet — a clean starry edge, not the old ~14%
            // mid-size peek that showed cut-off ocean labels (北冰洋…) and read as noise.
            // Derived from the real top safe area (like the empty state below) instead of
            // a screen-height fraction, so the gap below the status bar / Dynamic Island
            // is the same on every device. The globe is the pull-down reveal, not the
            // default hero. topBreathing mirrors the 28pt used in the empty state.
            let topBreathing: CGFloat = 28
            let peek = Self.topSafeAreaInset + topBreathing
            return UIScreen.main.bounds.height - peek
        }
        // Empty state: size the sheet to its CONTENT, not a screen-height fraction —
        // so the gap below the card is constant across devices (the old 0.44 fraction
        // left ~65pt of slack on large phones, ~15pt on small ones). The card is laid
        // out at its natural height (measured below) and we add a fixed breathing gap +
        // the home-indicator safe area so the CTA always clears the bottom edge.
        let handle: CGFloat = 16          // 空态无把手，用 16pt 顶部呼吸替代（见 sheetContent）
        let topBar: CGFloat = 6 + 40 + 8  // homeTopBar padding(top6,bottom8) + 40pt avatar row
        let cardTopInset: CGFloat = 6     // emptyState .padding(.top, 6)
        let bottomBreathing: CGFloat = 28 // 原始空态比例（顶对齐；浮卡态 CTA→圆角底可视间距 ≈ 5+此值）
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

    /// Top safe-area inset (status bar / Dynamic Island). Used to keep the globe peek
    /// above the expanded sheet a device-constant band rather than a screen fraction.
    private static var topSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.safeAreaInsets.top ?? 0
    }

    private var collapsedSheetOffset: CGFloat {
        max(0, expandedSheetHeight - 188)
    }

    /// Unique country codes from all trips whose departure date has passed.
    /// Includes both the primary destination and any additional destinations
    /// stored for multi-city trips.
    private var visitedCountriesCount: Int {
        var codes = Set<String>()
        for trip in store.trips where trip.countsAsVisited {
            if !trip.countryCode.isEmpty { codes.insert(normalizedCountryCode(trip.countryCode)) }
            for dest in trip.additionalDestinations where !dest.countryCode.isEmpty {
                codes.insert(normalizedCountryCode(dest.countryCode))
            }
        }
        return codes.count
    }

    /// 已发生（已出发 + 进行中）的行程数。与行程册口径一致（同 `countsAsVisited`），
    /// 使首页 Trip Book 胶囊副标题与行程册内的「旅行」数对齐，不再「胶囊 16 / 册内 13」打架。
    private var visitedTripsCount: Int {
        store.trips.filter { $0.countsAsVisited }.count
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
            let normalized = normalizedCountryCode(code)
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
            // 底栏（bottomBar）也移进 Sheet 控制器，与卡片由同一 animator 驱动 → 像素级同步缩放。
            // 底栏左右/底 18pt 边距由控制器约束接管（见 FX.installBottomBar）；空状态时返回空、不显示。
            // 底栏穿透：空白区域不吃 touch（HostingController 对非交互区返回 nil），pan 落到下方列表/卡片
            // → 从底栏上滑仍能滚列表；按钮照常吃 tap；列表底部 124/176pt 占位行保证穿透的点落在空白。
            CarryBottomSheetFX(
                expandedHeight: expandedSheetHeight,
                collapsedOffset: collapsedSheetOffset,
                mapCityOpacity: $mapCityOpacity,
                collapseRequest: $collapseRequest,
                isListEmpty: isEffectivelyEmpty,
                content: { sheetContent }
            ) {
                if !isEffectivelyEmpty {
                    bottomActionBar
                }
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea(edges: .bottom)
        .sheet(isPresented: $showSettings) {
            NavigationStack(path: $settingsPath) {
                SettingsView(path: $settingsPath)
            }
            .tint(CarryAccent.color)
            .preferredColorScheme((AppearanceMode(rawValue: appearanceModeRaw) ?? .system).colorScheme)
            // Invisible driver: recedes the home behind this sheet, tracking the drag.
            .background(PresenterRecedeEffect())
        }
        .sheet(isPresented: $showSearch, onDismiss: {
            // sheet 已完全收起，此刻压栈不会与关闭动画相互打断。
            if let id = pendingSearchTrip {
                pendingSearchTrip = nil
                if let trip = store.bundle(for: id) { openTrip(trip) }
            }
        }) {
            NavigationStack {
                searchSheet
            }
            .tint(CarryAccent.color)
            .background(PresenterRecedeEffect())
        }
        .sheet(isPresented: $showTripBook) {
            tripBookSheet
                .presentationDragIndicator(.visible)
                .background(PresenterRecedeEffect())
        }
        // 深链（通知/Widget/快捷指令）唤起行程时，关掉所有根级 sheet——否则被 push 的行程详情会被
        // 这些盖在导航栈之上的 sheet 挡住（用户停在某个 sheet 时按 Home 退出、收到通知再点进来即触发）。
        // 信号来自 ContentView.handlePendingTripId（spec: app-navigation-framework.md）。
        .onChange(of: router.rootModalDismissalRequest) { _, _ in
            showSettings = false
            showSearch = false
            showTripBook = false
            showSpendDetail = false
            showAllCountries = false
            showAllAirports = false
        }
        // 空态：Sheet 是固定缩放浮卡（不折叠、无 snap 回调驱动 mapCityOpacity），
        // 故把它视同折叠态 = 1，让地图样式/定位按钮显示可点、城市点行为一致。
        // 退出空态恢复 0，之后由 sheet 的 snap 回调接管。
        .onAppear { if isEffectivelyEmpty { mapCityOpacity = 1 } }
        .onChange(of: isEffectivelyEmpty) { _, empty in
            withAnimation(.easeOut(duration: 0.25)) { mapCityOpacity = empty ? 1 : 0 }
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
            // 空态 Sheet 是固定缩放浮卡、禁止拖拽 → 不显示把手（把手会误导可拖）；
            // 用一小段顶部呼吸替代，避免「My Trips」标题贴到圆角。
            if isEffectivelyEmpty {
                Color.clear.frame(height: 16)
            } else {
                // Drag handle — no gesture needed; SheetViewController.sheetPan handles it
                Capsule()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 36, height: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity)
            }

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
            // 底部消隐渐变已移到 FX 层（`CarryBottomSheetFX` 的 `bottomFadeView`，钉卡片可视底边），
            // 以便收起态也能在可视底部消隐内容；此处不再在 SwiftUI 列表上铺（否则收起态被裁到屏外不可见）。
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
                // 复制行程后回首页：复用扫光高亮指向新副本，让用户感知到它的出现（与「首个行程」同一种高亮）。
                if let pending = store.pendingShimmerTripId {
                    shimmerTripId = pending
                    store.pendingShimmerTripId = nil
                }
            }
            // 模拟空态 flag 也是 rebuildTripLists 的输入（开启时把缓存列表置空），
            // 故它变化时必须重建——否则关闭开关后缓存仍为空，列表空白直到重启。
            // 该 flag 只能由 DEBUG-only 的开发者选项拨动，故响应逻辑同样 DEBUG-only：
            // 用 ViewModifier 封装（#if 在函数体内返回两种完整视图，两种构建配置都成立），
            // release 包里这层是 no-op，不带该逻辑。
            .modifier(DebugMockEmptyStateRefresh(
                mockEnabled: store.isHomeEmptyStateMockEnabled,
                rebuild: rebuildTripLists
            ))
            .onChange(of: router.showMapFullscreen) { _, show in
                guard show else { return }
                router.showMapFullscreen = false
                collapseRequest = true  // SheetViewController.snap handles the animation
            }
            .onChange(of: router.showTripBookRequest) { _, req in
                guard req else { return }
                router.showTripBookRequest = false
                openTripBook()   // 长按 Quick Action「My Trip Book」→ 打开行程册 sheet
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
        // 空态 + 深色：背景留透明，让卡片表面由 FX 的磨砂玻璃层提供（地球从卡后透/糊上来，有真实景深）。
        // 其余（有行程态、或浅色）：沿用不透明的 CarrySubtleBackground（可读性 / 白卡本就立体）。
        .background {
            if !(isEffectivelyEmpty && colorScheme == .dark) {
                CarrySubtleBackground()
            }
        }
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
        // 齿轮随 Sheet 收起渐隐、展开渐显（与地图控件浮层同源、方向相反）。
        // 空态是固定缩放浮卡、mapCityOpacity 恒为 1，直接绑会隐藏齿轮 → 空态进不了设置，
        // 故空态强制常显。无需显式 .animation：mapCityOpacity 的写入点已在 withAnimation(.easeOut) 内。
        let gearOpacity = isEffectivelyEmpty ? 1.0 : (1.0 - mapCityOpacity)
        return HStack(alignment: .center) {
            Text("home.title")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 12)

            // Settings entry — a circular gear (secondary), per design-system.md §124.
            // 未登录态就是这枚齿轮；登录功能落地后，在此按登录态切换为用户头像
            // （已登录 → Image(avatar)，未登录 → 本齿轮）。现在不写空壳分支以免留死代码。
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    // Soft neutral fill (adaptive light/dark) so it reads clearly as a
                    // tappable button on the near-white sheet — like Apple's circular
                    // toolbar buttons. No border/shadow: the fill alone defines the chip.
                    .background(Circle().fill(Color(UIColor.tertiarySystemFill)))
            }
            .buttonStyle(PressableScaleButtonStyle(scale: 0.94, pressedBrightness: -0.02, pressedOpacity: 0.95))
            .accessibilityLabel(Text("Settings"))
            .opacity(gearOpacity)
            .allowsHitTesting(gearOpacity > 0.05)   // 渐隐到几近不可见即不可点，避免点到收起态背后的元素
        }
    }

    private var bottomActionBar: some View {
        Group {
            if #available(iOS 26.0, *) {
                // Liquid Glass：同容器内相邻玻璃元素（搜索圆 ⇄ Trip Book 胶囊）会在边缘
                // 像液滴一样融合/吸附，.interactive() 让玻璃跟手。
                // spacing 必须 < 按钮间隙（HStack 14）——否则静止态就融合，会把边缘元素
                // 拉成水滴尖尾；调小后静止态保持干净圆形，只在长按胀大时才融合。
                GlassEffectContainer(spacing: 13.5) {
                    bottomBarStack
                }
            } else {
                bottomBarStack
            }
        }
        .padding(.horizontal, 4)
        // ⚠️ 防底栏点击穿透到背后卡片的防护**不在这里**——它是结构性地放在 UIKit 根层
        // `CarryBottomSheetFX` 的 `FXPassthroughView.hitTest`（底栏 frame = 不放行区）。
        // 这里**不要**再加 SwiftUI 层的 `.background(...).onTapGesture{}` 吸收补丁：那种补丁依赖
        // 底栏内部布局恰好盖住点击区，每次改底栏 UI（间距/玻璃/背景）就被绕过 → 穿透反复复发
        // （已踩坑 5+ 次，见 home-sheet-debug-playbook §33）。改底栏布局放心改，根层防护盖全程。
    }

    private var bottomBarStack: some View {
        HStack(spacing: 14) {
            bottomSearchButton
            bottomTripBookButton
            bottomCreateButton
        }
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
                .modifier(BottomBarGlass(shape: Circle()))
                .contentShape(Rectangle())   // 满帧命中区，避免 glass 把命中区裁成圆、边角点空穿透
        }
        .bottomGlassPressStyle(fallbackScale: 0.95)
        .accessibilityLabel(Text("Search"))
    }

    @ViewBuilder
    private var bottomTripBookButton: some View {
        Button {
            openTripBook()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "globe.europe.africa.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 1) {
                    Text("home.tripbook.title")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(String(format: NSLocalizedString("home.tripbook.subtitle", comment: "Trip Book subtitle: trip count · visited country count"), locale: Locale.current, Int64(visitedTripsCount), Int64(visitedCountriesCount)))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .modifier(BottomBarGlass(shape: RoundedRectangle(cornerRadius: 26, style: .continuous)))
            .contentShape(Rectangle())   // 满帧命中区
        }
        .bottomGlassPressStyle(fallbackScale: 0.985)
        .accessibilityLabel(Text("home.tripbook.title"))
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
                .modifier(FABGlass())
                .contentShape(Rectangle())   // 满帧命中区
        }
        .bottomGlassPressStyle(fallbackScale: 0.95)
        .accessibilityLabel(Text("home.create_trip"))
    }

    /// 创建 FAB 的背景。iOS 26 用**带 accent tint 的 Liquid Glass**——保留烟蓝身份，
    /// 同时在 `GlassEffectContainer` 内可与左侧 Trip Book 胶囊水滴融合；
    /// iOS 17–25 回退为原实心烟蓝渐变 + 描边 + 阴影（无融合）。
    private struct FABGlass: ViewModifier {
        @Environment(\.colorScheme) private var colorScheme
        func body(content: Content) -> some View {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular.tint(CarryAccent.color).interactive(), in: Circle())
            } else {
                content.background(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [CarryAccent.color.opacity(0.96), CarryAccent.color.opacity(0.86)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(Circle().strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.26), lineWidth: 1))
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.30 : 0.16), radius: 20, x: 0, y: 7)
                )
            }
        }
    }


    private var tripBookSheet: some View {
        let stats = TripBookStats.from(trips: store.trips)
        return NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    // 叙事顺序：总量 → 去了哪（国家/大洲）→ 走了多远（飞行/机场/住宿）
                    // → 我是哪类旅行者（国内国际/季节）→ 花了多少。高光「旅程」段（部分覆盖、
                    // hide-when-empty）紧贴地理段，把「跨 N 国 → 飞 X 公里 → 住 Y 晚」接成一条弧线；
                    // 偏分析的出行习惯（国内国际/季节）退到中后段；花费性质特殊、压轴。
                    tripBookOverviewCard(stats)
                    tripBookCountriesCard(stats)
                    if stats.visitedContinentCount > 0 { tripBookContinentsCard(stats) }
                    // 旅程段（仅加了航班/住宿的行程有数；无则整块隐藏，自动让位给下方习惯段）。
                    if stats.hasFlightStats { tripBookFlightCard(stats) }
                    if !stats.airportTallies.isEmpty { tripBookAirportsCard(stats) }
                    if stats.totalNights > 0 { tripBookLodgingCard(stats) }
                    // 出行习惯段。
                    if stats.domesticCount + stats.internationalCount > 0 { tripBookScopeCard(stats) }
                    if stats.seasonCounts.values.reduce(0, +) > 0 { tripBookSeasonsCard(stats) }
                    // 在地足迹（去过多少景点/餐厅/购物）：与花费同为「行程数据沉淀」，紧贴费用卡收尾——
                    // 「你体验了什么 → 花了多少」。仅有行程规划的 trip 有数，无则隐藏。
                    if !stats.footprintTallies.isEmpty { tripBookFootprintCard(stats) }
                    // 费用压轴：前面都是出行习惯/统计，花费性质特殊（用户记账数据），单独置于最后。
                    // 对汇率管理器的观察收在 ExchangeRateScope 这一层子视图（花费卡的真正消费者），
                    // 不上抬到根 HomeView——根是首页 UIKit FX sheet（含底栏）的宿主，在根层观察会令其
                    // 因汇率 publish 整体失效、透过 UIKit 宿主破坏底栏交互（已复现）。依赖放回正确作用域：
                    // 汇率异步到达时仅此 scope 内重算刷新，根首页/底栏不受牵连。
                    ExchangeRateScope { rate in
                        let spend = TripSpendStats.compute(
                            trips: store.trips,
                            homeCode: rate.baseCurrencyCode,
                            convert: { rate.convertToHome($0, from: $1) }
                        )
                        Group {
                            if spend.hasAnyCost { tripBookSpendCard(spend) }
                        }
                        .sheet(isPresented: $showSpendDetail) { spendDetailSheet(spend) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollContentBackground(.hidden)
            .background(CarrySubtleBackground())
            // 国家/机场超过预览上限时的「查看全部」全列表（大洲天生 ≤7、不会触发，故无需）。
            .sheet(isPresented: $showAllCountries) {
                tripBookListSheet("tripbook.countries.title", dismiss: { showAllCountries = false }) {
                    ForEach(stats.countryTallies, id: \.code) { tripBookCountryRow($0) }
                }
            }
            .sheet(isPresented: $showAllAirports) {
                tripBookListSheet("tripbook.airports.title", dismiss: { showAllAirports = false }) {
                    ForEach(stats.airportTallies, id: \.label) { tripBookAirportRow($0) }
                }
            }
            .navigationTitle("home.tripbook.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { showTripBook = false }
                }
            }
        }
    }

    // MARK: Trip Book cards

    private func tripBookCard<Content: View>(_ titleKey: LocalizedStringKey,
                                             systemImage: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(titleKey, systemImage: systemImage)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .carrySurfaceCardBackground(cornerRadius: 20)
    }

    // MARK: 花费卡（spec: itinerary-cost-tracking.md）

    /// 「总花费」聚合卡：大号总额 + 比例带（单一烟蓝 rank 深浅）+ 按 7 类细分类目（仅非零）+ 查看全部。
    private func tripBookSpendCard(_ s: TripSpendStats) -> some View {
        let total = s.overall.total
        let legend = spendLegend(s.overall)   // (类别, 金额, 单烟蓝透明度)，按额降序
        return tripBookCard("tripbook.spend.title", systemImage: "creditcard") {
            VStack(alignment: .leading, spacing: 14) {
                Text(spendTotalText(total, approximate: s.approximate, code: s.homeCode))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                if total > 0 { spendBar(legend) }
                VStack(spacing: 0) {
                    ForEach(legend, id: \.category) { item in
                        spendLegendRow(spendCategoryName(item.category), amount: item.amount,
                                       opacity: item.opacity, code: s.homeCode)
                    }
                }
                // 「最高一趟」小料行（镜像机型「mostly」texture 行）：仅 ≥2 趟有花费时出，
                // 把藏在「查看全部」里的「按行程」维度抬到卡面，并作其引子。中性措辞、不渲染超支。
                if s.perTrip.count >= 2, let top = s.perTrip.first {
                    Divider()
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(width: 16, alignment: .center)
                        Text(String(format: NSLocalizedString("tripbook.spend.top_trip", comment: ""),
                                    top.name))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(spendTotalText(top.breakdown.total, approximate: s.approximate, code: s.homeCode))
                            .font(.system(.footnote, design: .rounded).weight(.medium))
                            .foregroundStyle(.secondary)
                            .layoutPriority(1)
                    }
                }
                if !s.perTrip.isEmpty {
                    Button { showSpendDetail = true } label: {
                        HStack(spacing: 4) {
                            Text("tripbook.see_all")
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        }
                        .font(.subheadline)
                        .foregroundStyle(CarryAccent.color)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                if s.hasUnconverted {
                    Text("tripbook.spend.approx_note")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func spendTotalText(_ amount: Double, approximate: Bool, code: String) -> String {
        (approximate ? "≈ " : "") + CurrencyCatalog.format(amount, code: code)
    }

    /// 类别名（复用单行程花费页同一套 `tripspend.cat.*`，跨行程/单行程口径一致、零新增文案）。
    private func spendCategoryName(_ c: SpendCategory) -> String {
        NSLocalizedString("tripspend.cat.\(c.rawValue)", comment: "")
    }

    /// 非零类目按额降序 + 单烟蓝 rank 透明度（额大色深 1.0 → 额小色浅 0.28）；bar 与图例同序同色，
    /// 维持 Trip Book 单一强调色纪律（不引入单行程页的多彩配色）。
    private func spendLegend(_ b: TripSpendBreakdown) -> [(category: SpendCategory, amount: Double, opacity: Double)] {
        let items = b.sortedNonZero
        let n = items.count
        return items.enumerated().map { i, it in
            let opacity = n <= 1 ? 1.0 : 1.0 - Double(i) * (0.72 / Double(n - 1))
            return (category: it.category, amount: it.amount, opacity: opacity)
        }
    }

    /// 比例带：单一烟蓝、各段按 `spendLegend` 的额降序与透明度，跳过 0 段，整条 capsule 收边。
    private func spendBar(_ legend: [(category: SpendCategory, amount: Double, opacity: Double)]) -> some View {
        let total = max(legend.reduce(0) { $0 + $1.amount }, 0.0001)
        return GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(legend, id: \.category) { part in
                    CarryAccent.color.opacity(part.opacity)
                        .frame(width: max(2, geo.size.width * part.amount / total))
                }
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
    }

    private func spendLegendRow(_ label: String, amount: Double, opacity: Double, code: String) -> some View {
        HStack(spacing: 10) {
            Circle().fill(CarryAccent.color.opacity(opacity)).frame(width: 8, height: 8)
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(CurrencyCatalog.format(amount, code: code))
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 5)
    }

    /// 「查看全部花费」：按每趟分组（承接 Q2「每趟总花费」），每趟列非零类目 + 该趟合计。
    /// 「查看全部」= 时间轴流水账：年分段（倒序）→ 每趟左侧日期标记 + 圆点（呼应行程页 timeline）
    /// → 趟内按方式/类目逐行。总额上提到行名行；无日期行程归底部「未排期」组（不塞进某年）。
    private func spendDetailSheet(_ s: TripSpendStats) -> some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(spendTimelineGroups(s.perTrip)) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(group.title)
                                    .font(.system(.title2, design: .rounded).weight(.bold))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(CurrencyCatalog.format(group.total, code: s.homeCode))
                                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 4)
                            ForEach(group.trips) { row in
                                spendTimelineTrip(row, code: s.homeCode)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollContentBackground(.hidden)
            .background(CarrySubtleBackground())
            .navigationTitle("tripbook.spend.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { showSpendDetail = false }
                }
            }
        }
    }

    /// 一趟的时间轴块：上方一行日期标记（烟蓝圆点 + 月日，左对齐成竖向时间线）+ 下方**整宽卡片**
    /// （行名·总额 + 逐笔明细）。日期不再占左列，卡片得以撑满，避免整体右偏。
    private func spendTimelineTrip(_ row: TripSpendRow, code: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let date = row.departureDate {
                Text(date.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(CarryAccent.color)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.name)
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(CurrencyCatalog.format(row.breakdown.total, code: code))
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.primary)
                        .layoutPriority(1)
                }
                VStack(spacing: 9) {
                    ForEach(spendDetailRows(row.breakdown)) { r in
                        spendDetailLine(symbol: r.symbol, label: r.label, amount: r.amount, code: code)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)   // 撑满整宽
            .padding(14)
            .carrySurfaceCardBackground(cornerRadius: 16)
        }
    }

    private struct SpendTimelineGroup: Identifiable {
        let id: String
        let title: String
        let total: Double          // 该年（/未排期组）花费小计，本位币
        let trips: [TripSpendRow]
    }

    /// 按年分组（倒序，年内按出发日倒序）；无日期行程单列底部「未排期」组。各组带本位币花费小计。
    private func spendTimelineGroups(_ trips: [TripSpendRow]) -> [SpendTimelineGroup] {
        let dated = trips.compactMap { r -> (date: Date, row: TripSpendRow)? in
            guard let d = r.departureDate else { return nil }
            return (d, r)
        }
        .sorted { $0.date > $1.date }   // 最近在上

        var groups: [SpendTimelineGroup] = []
        var currentYear: Int? = nil
        var bucket: [TripSpendRow] = []
        func flush() {
            if let y = currentYear, !bucket.isEmpty {
                let total = bucket.reduce(0) { $0 + $1.breakdown.total }
                groups.append(SpendTimelineGroup(id: "y\(y)", title: String(y), total: total, trips: bucket))
            }
        }
        for item in dated {
            let year = Calendar.current.component(.year, from: item.date)
            if year != currentYear { flush(); currentYear = year; bucket = [] }
            bucket.append(item.row)
        }
        flush()

        let undated = trips.filter { $0.departureDate == nil }
        if !undated.isEmpty {
            let total = undated.reduce(0) { $0 + $1.breakdown.total }
            groups.append(SpendTimelineGroup(id: "undated",
                title: NSLocalizedString("tripbook.spend.undated", comment: ""), total: total, trips: undated))
        }
        return groups
    }

    /// 下钻明细一行（图标 + 名称 + 金额）。交通段或类目都复用此通用行。
    private struct SpendDetailRow: Identifiable {
        let id: String
        let symbol: String
        let label: String
        let amount: Double
    }

    /// 「查看全部」每趟的明细行：**交通按方式拆**（航班/火车/租车…各自图标，修「租车显示成飞机」），
    /// 其余类目各一行；统一按金额降序。交通合计 = 各方式之和，与 Trip total 口径一致。
    private func spendDetailRows(_ b: TripSpendBreakdown) -> [SpendDetailRow] {
        var rows: [SpendDetailRow] = []
        for (mode, amt) in b.transportByMode where amt > 0 {
            rows.append(SpendDetailRow(id: "m.\(mode.rawValue)", symbol: mode.symbolName,
                                       label: NSLocalizedString(mode.localizationKey, comment: ""), amount: amt))
        }
        for (cat, amt) in b.byCategory where cat != .transport && amt > 0 {
            rows.append(SpendDetailRow(id: "c.\(cat.rawValue)", symbol: cat.symbolName,
                                       label: spendCategoryName(cat), amount: amt))
        }
        return rows.sorted { $0.amount > $1.amount }
    }

    /// 下钻行：图标（单烟蓝，跟随花费卡的单一强调色，不用单行程页的多彩）+ 名称 + 金额。
    private func spendDetailLine(symbol: String, label: String, amount: Double, code: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(CarryAccent.color)
                .frame(width: 22)
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(CurrencyCatalog.format(amount, code: code))
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.primary)
        }
    }

    private func tripBookBigStat(_ value: Int, _ label: LocalizedStringKey) -> some View {
        VStack(spacing: 4) {
            CountUpText(value: value, font: .system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func tripBookOverviewCard(_ s: TripBookStats) -> some View {
        ZStack {
            tripBookArcOrnament()
            VStack(spacing: 14) {
                if !s.countryTallies.isEmpty {
                    tripBookFlagsRow(s.countryTallies.map(\.code))
                }
                if let year = s.firstTravelYear {
                    Text(String(format: NSLocalizedString("tripbook.first_trip", comment: "first recorded trip year"), Int64(year)))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 0) {
                    tripBookBigStat(s.tripCount, "tripbook.trips")
                    Divider().frame(height: 36)
                    tripBookBigStat(s.totalDays, "tripbook.days")
                }
                .padding(.top, 2)
            }
            .padding(.vertical, 22)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .carryHeroCardBackground(cornerRadius: 24)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// 「在地足迹」卡：各 StopCategory 累计地点数（景点/餐饮/活动/购物/其他），降序、N× 计数。
    /// 仅覆盖加了行程规划的 trip，无则整块隐藏（同航班/花费卡）。spec 🟡→🟢 前提反转见 trip-book.md。
    private func tripBookFootprintCard(_ s: TripBookStats) -> some View {
        tripBookCard("tripbook.footprint.title", systemImage: "mappin.and.ellipse") {
            VStack(spacing: 10) {
                ForEach(s.footprintTallies, id: \.category) { tally in
                    HStack(spacing: 10) {
                        Image(systemName: tally.category.symbolName)
                            .font(.footnote)
                            .foregroundStyle(CarryAccent.color)
                            .frame(width: 22)
                        Text(tally.category.titleKey)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(verbatim: "\(tally.count)×")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// 到访国家国旗排（重叠圆形徽章，最多 8 枚 + 余量）。
    private func tripBookFlagsRow(_ codes: [String]) -> some View {
        let shown = Array(codes.prefix(8))
        let extra = codes.count - shown.count
        return HStack(spacing: -7) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, code in
                Text(flagEmoji(for: code))
                    .font(.system(size: 17))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color(.secondarySystemBackground)))
                    .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
            }
            if extra > 0 {
                Text(verbatim: "+\(extra)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color(.secondarySystemBackground)))
                    .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
            }
        }
    }

    /// 装饰性「航线」弧线 + 端点圆点（抽象，非地理地图）。烟蓝低透明，随明暗自适应。
    private func tripBookArcOrnament() -> some View {
        // 浅色底上弧线更易被冲淡，提一档透明度让点缀读得到；深色维持低调。
        let lineOpacity = colorScheme == .dark ? 0.13 : 0.20
        let dotOpacity = colorScheme == .dark ? 0.28 : 0.40
        return Canvas { ctx, size in
            let accent = CarryAccent.color
            for i in 0..<3 {
                let y = size.height * (0.30 + 0.20 * CGFloat(i))
                let startX = size.width * 0.06
                let endX = size.width * 0.94
                let ctrlY = y - size.height * 0.24
                var path = Path()
                path.move(to: CGPoint(x: startX, y: y))
                path.addQuadCurve(to: CGPoint(x: endX, y: y),
                                  control: CGPoint(x: (startX + endX) / 2, y: ctrlY))
                ctx.stroke(path, with: .color(accent.opacity(lineOpacity)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2.5, 5]))
                for x in [startX, endX] {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)),
                             with: .color(accent.opacity(dotOpacity)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func tripBookCountriesCard(_ s: TripBookStats) -> some View {
        let percent = s.globalCountryTotal > 0
            ? Int((Double(s.visitedCountryCount) / Double(s.globalCountryTotal) * 100).rounded())
            : 0
        return tripBookCard("tripbook.countries.title", systemImage: "globe.asia.australia.fill") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                CountUpText(value: s.visitedCountryCount,
                            font: .system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(verbatim: "/ \(s.globalCountryTotal) · \(percent)%")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            if !s.countryTallies.isEmpty {
                // 统一规则：预览前 10，超出给「查看全部」。国家是回顾册核心，预览给得宽（10）。
                VStack(spacing: 10) {
                    ForEach(s.countryTallies.prefix(tripBookListPreviewCap), id: \.code) { tripBookCountryRow($0) }
                    if s.countryTallies.count > tripBookListPreviewCap {
                        tripBookViewAllButton { showAllCountries = true }
                    }
                }
            }
        }
    }

    /// 列表卡预览上限（统一规则：最多预览 N 条，超出给「查看全部」）。大洲天生 ≤7 → 永不触发、全展示。
    private var tripBookListPreviewCap: Int { 10 }

    private func tripBookCountryRow(_ tally: CountryTally) -> some View {
        HStack(spacing: 10) {
            Text(flagEmoji(for: tally.code)).font(.system(size: 18))
            Text(countryDisplayName(tally.code))
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
            Text(verbatim: "\(tally.count)×")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func tripBookAirportRow(_ tally: LabelTally) -> some View {
        HStack(spacing: 10) {
            Text(tally.label)
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(CarryAccent.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(CarryAccent.color.opacity(0.12)))
            Spacer()
            Text(verbatim: "\(tally.count)×")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    /// 卡内「查看全部」入口（与花费卡同款）。
    private func tripBookViewAllButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("tripbook.see_all")
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
            }
            .font(.subheadline)
            .foregroundStyle(CarryAccent.color)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    /// 全列表 sheet（国家 / 机场「查看全部」共用）：单张 surface 卡内列出全部行。
    private func tripBookListSheet<Content: View>(_ titleKey: LocalizedStringKey,
                                                  dismiss: @escaping () -> Void,
                                                  @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .carrySurfaceCardBackground(cornerRadius: 20)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
            }
            .scrollContentBackground(.hidden)
            .background(CarrySubtleBackground())
            .navigationTitle(titleKey)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { SheetCloseButton(action: dismiss) }
            }
        }
    }

    private func tripBookContinentsCard(_ s: TripBookStats) -> some View {
        let ordered = s.continentCounts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
        return tripBookCard("tripbook.continents.title", systemImage: "globe") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                CountUpText(value: s.visitedContinentCount,
                            font: .system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            VStack(spacing: 10) {
                ForEach(ordered, id: \.key) { item in
                    HStack {
                        Text(continentNameKey(item.key))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(verbatim: "\(item.value)×")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func tripBookScopeCard(_ s: TripBookStats) -> some View {
        let total = max(1, s.domesticCount + s.internationalCount)
        let intlFrac = CGFloat(s.internationalCount) / CGFloat(total)
        return tripBookCard("tripbook.scope.title", systemImage: "map") {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(CarryAccent.color)
                        .frame(width: geo.size.width * intlFrac)
                    Rectangle().fill(Color(.quaternaryLabel))
                }
            }
            .frame(height: 12)
            .clipShape(Capsule())

            HStack(spacing: 16) {
                tripBookLegend(color: CarryAccent.color, label: "tripbook.scope.international", count: s.internationalCount)
                tripBookLegend(color: Color(.quaternaryLabel), label: "tripbook.scope.domestic", count: s.domesticCount)
                Spacer()
            }
        }
    }

    private func tripBookLegend(color: Color, label: LocalizedStringKey, count: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.footnote).foregroundStyle(.secondary)
            Text(verbatim: "\(count)").font(.system(.footnote, design: .rounded).weight(.semibold)).foregroundStyle(.primary)
        }
    }

    private func tripBookSeasonsCard(_ s: TripBookStats) -> some View {
        tripBookCard("tripbook.seasons.title", systemImage: "calendar") {
            HStack(spacing: 0) {
                ForEach(Season.allCases, id: \.self) { season in
                    VStack(spacing: 6) {
                        Image(systemName: seasonIcon(season))
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(.secondary)
                        Text("\(s.seasonCounts[season] ?? 0)")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(seasonNameKey(season))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: 航班 / 住宿卡（spec 前提反转见 trip-book.md）

    /// 「飞行」卡：累计里程 + 飞行时长（合一），机型作轻量小行收底。
    private func tripBookFlightCard(_ s: TripBookStats) -> some View {
        let distance = s.flightDistanceMeters > 0
            ? CarryDistanceFormat.string(meters: s.flightDistanceMeters, unit: distanceUnit) : "—"
        let duration = s.flightDurationMinutes > 0
            ? tripBookDurationText(s.flightDurationMinutes) : "—"
        return tripBookCard("tripbook.flight.title", systemImage: "airplane") {
            HStack(spacing: 0) {
                tripBookBigStatText(distance, "tripbook.flight.distance")
                Divider().frame(height: 36)
                tripBookBigStatText(duration, "tripbook.flight.duration")
            }
            // 最远一程（距离 + 时长合一，标杆航班一行交代）：仅 ≥2 段有距离的航班时出（=1 段时等于累计距离、冗余）。
            if let text = longestFlightText(s) {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "airplane.departure")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, alignment: .center)
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if let summary = aircraftSummaryText(s) {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "airplane.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, alignment: .center)
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 「最远一程」文案：路线 · 距离 [· 时长]。≥2 段有距离的航班 + 有路线标注才出；缺时长则只显距离。
    private func longestFlightText(_ s: TripBookStats) -> String? {
        guard s.flightLegCount >= 2,
              let route = s.longestFlightRoute, !route.isEmpty,
              s.longestFlightMeters > 0 else { return nil }
        let dist = CarryDistanceFormat.string(meters: s.longestFlightMeters, unit: distanceUnit)
        if s.longestFlightMinutes > 0 {
            return String(format: NSLocalizedString("tripbook.longest_flight", comment: ""),
                          route, dist, tripBookDurationText(s.longestFlightMinutes))
        }
        return String(format: NSLocalizedString("tripbook.longest_flight_nodur", comment: ""),
                      route, dist)
    }

    /// 「常经停机场」卡：按 IATA 码计数降序（镜像「最常去国家」），码作烟蓝胶囊 chip。
    private func tripBookAirportsCard(_ s: TripBookStats) -> some View {
        // 统一规则：预览前 10，超出给「查看全部」（替掉旧的「+N」静默兜底）。
        tripBookCard("tripbook.airports.title", systemImage: "airplane.departure") {
            VStack(spacing: 10) {
                ForEach(s.airportTallies.prefix(tripBookListPreviewCap), id: \.label) { tripBookAirportRow($0) }
                if s.airportTallies.count > tripBookListPreviewCap {
                    tripBookViewAllButton { showAllAirports = true }
                }
            }
        }
    }

    /// 「住宿」卡：累计住宿晚数（住宿改「入住日 + 退房日」后可派生）。
    private func tripBookLodgingCard(_ s: TripBookStats) -> some View {
        tripBookCard("tripbook.lodging.title", systemImage: "bed.double") {
            VStack(spacing: 4) {
                CountUpText(value: s.totalNights,
                            font: .system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("tripbook.lodging.nights_label")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// 字符串版大数字（里程/时长含单位、无法用 Int 滚动），长值自动缩放保持单行。
    private func tripBookBigStatText(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// 累计飞行时长「127h 30m」（h/m 通用、与详情页同范式）。
    private func tripBookDurationText(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    /// 机型小行文案：1 种 → 「机型 · A320」；≥2 种 → 「N 种机型 · 最常 A320」。无机型 → nil。
    private func aircraftSummaryText(_ s: TripBookStats) -> String? {
        guard let top = s.aircraftTallies.first else { return nil }
        if s.distinctAircraftCount == 1 {
            return String(format: NSLocalizedString("tripbook.aircraft.one", comment: ""), top.label)
        }
        return String(format: NSLocalizedString("tripbook.aircraft.many", comment: ""),
                      Int64(s.distinctAircraftCount), top.label)
    }

    // MARK: Trip Book helpers

    /// 本地化国家/地区名，直接用系统（大陆 storefront 下的区域命名已由 Apple 审定，
    /// 我们不自定义区域名以规避合规风险）。
    private func countryDisplayName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    private func continentNameKey(_ c: Continent) -> LocalizedStringKey {
        switch c {
        case .asia:          return "tripbook.continent.asia"
        case .europe:        return "tripbook.continent.europe"
        case .africa:        return "tripbook.continent.africa"
        case .northAmerica:  return "tripbook.continent.northAmerica"
        case .southAmerica:  return "tripbook.continent.southAmerica"
        case .oceania:       return "tripbook.continent.oceania"
        case .antarctica:    return "tripbook.continent.antarctica"
        }
    }

    private func seasonNameKey(_ s: Season) -> LocalizedStringKey {
        switch s {
        case .spring: return "tripbook.season.spring"
        case .summer: return "tripbook.season.summer"
        case .autumn: return "tripbook.season.autumn"
        case .winter: return "tripbook.season.winter"
        }
    }

    private func seasonIcon(_ s: Season) -> String {
        switch s {
        case .spring: return "leaf"
        case .summer: return "sun.max"
        case .autumn: return "wind"
        case .winter: return "snowflake"
        }
    }

    /// 统计大数字。**首帧即真实值、不从 0 滚**——消除 sheet 入场时「先 0 再刷新」的残影
    /// （count-up 与 sheet 上滑同时跑会打架成闪烁；且数据是打开即定的快照、入场期间不变，
    /// 无可靠的「入场结束后再数」时机）。仅当数值【真的变化】时才滚动；尊重「减弱动态效果」。
    private struct CountUpText: View {
        let value: Int
        let font: Font
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var shown: Double

        init(value: Int, font: Font) {
            self.value = value
            self.font = font
            _shown = State(initialValue: Double(value))   // 首帧 = 真实值，无 0 残影
        }

        var body: some View {
            Text("\(Int(shown.rounded()))")
                .font(font)
                .monospacedDigit()
                .onChange(of: value) { _, newValue in
                    guard !reduceMotion else { shown = Double(newValue); return }
                    withAnimation(.easeOut(duration: 0.7)) { shown = Double(newValue) }
                }
        }
    }

    private var searchSheet: some View {
        VStack(spacing: 0) {
            // 延续首页「我的行程」大标题进入搜索态：顶部不空、保留页面归属感，
            // 接近原生大标题搜索。标题与 placeholder 文案不重复，避免冗余。
            HStack {
                Text("home.title")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            HStack(spacing: 12) {
                CarrySearchField(
                    text: $searchText,
                    placeholder: "Search trips",
                    focus: $searchFieldFocused
                )

                Button("Cancel") {
                    searchText = ""
                    showSearch = false
                }
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(CarryAccent.color)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            if filteredSearchTrips.isEmpty {
                searchEmptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredSearchTrips, id: \.id) { trip in
                            Button {
                                // 暂存目标，收起 sheet；真正跳转在 onDismiss 完成后发生。
                                pendingSearchTrip = trip.id
                                searchText = ""
                                showSearch = false
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
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
                                .padding(.vertical, 11)
                                .padding(.horizontal, 16)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                }
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .background(CarrySubtleBackground())
        .onAppear {
            searchText = ""
            searchFieldFocused = true
        }
    }

    /// 搜索无结果 / 尚无行程时的居中空状态。沿用行程页空状态的视觉规格
    /// （SF Symbol 44pt light · headline 标题 · subheadline 副标题），不带卡片/CTA。
    private var searchEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: searchText.isEmpty ? "suitcase" : "magnifyingglass")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(searchText.isEmpty ? "No trips yet" : "No matching trips")
                .font(.headline)
                .foregroundStyle(.primary)
            Text(searchText.isEmpty
                 ? "Your trips will appear here."
                 : "Try a different name or destination.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(.bottom, 48)
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
                // 统一空态胶囊样式（与行程空态共用 CarryEmptyStatePrimaryButtonStyle）。
                Button {
                    startNewTrip()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "airplane.departure")
                            .font(.system(size: 14, weight: .semibold))
                        Text("home.empty.cta")
                    }
                }
                .buttonStyle(CarryEmptyStatePrimaryButtonStyle())
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
        // 左滑只保留「删除」。复制行程已移到行程内的 ··· 菜单——避免「左滑展开态 + 插入新行」时
        // SwiftUI 无法平滑收起该行而出现空白闪烁（详见复制流程：在行程内复制后回首页 + 扫光高亮副本）。
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .none) {
                tripToDelete = bundle
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
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

    /// The "live" accent for the trip's leading spine.
    // Over a photo the accent (a dark colour in Light mode) reads as a black bar; switch the
    // spine fill to white so it matches the white text on the scrimmed photo.
    private var styleAccent: Color { onPhoto ? .white : Color.accentColor }

    private var dateAndDurationText: String {
        // 无日期「规划中」行程不显示日期区间，改显示轻标签「未来某天」（单一来源 tripdates.unset，
        // 与行程详情页头部共用，避免重复维护）。
        if bundle.isDateless {
            return NSLocalizedString("tripdates.unset", comment: "Dateless trip label")
        }
        let format = NSLocalizedString("%@ · %lld days", comment: "Trip date range and duration")
        // 显示「实际天数」（含两端），与行程页一致；bundle.days 是晚数、仅打包数量用。
        return String(format: format, locale: Locale.current, bundle.localizedDateRange, Int64(bundle.spanDays))
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

    /// 最高一级层级：临近、要行动的「即将出发」行程（非已结束、非无日期规划）。
    /// 三级深度阶梯：hero 抬起（表面更实 + 阴影更大更强）＞ 规划中 平放 ＞ 已结束 扁平。
    /// 只用 elevation/材质拉层级，不加任何装饰——契合「克制 + 深度」。
    private var isHero: Bool { !isPast && !bundle.isDateless }

    private var cardFill: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: isHero
                    ? [homeDarkCardTop, homeDarkCardBottom]            // 略亮 → 抬起
                    : [homeDarkCardTopRefined, homeDarkCardBottomRefined],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        return LinearGradient(
            colors: isHero
                ? [Color(UIColor.systemBackground).opacity(1.0),      // 接近纯白、最实 → 抬起
                   Color(UIColor.systemBackground).opacity(0.96)]
                : [Color(UIColor.systemBackground).opacity(0.88),
                   Color(UIColor.systemBackground).opacity(0.82)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var cardShadow: Color {
        if colorScheme == .dark {
            return Color.black.opacity(isHero ? 0.24 : 0.16)
        }
        return Color.black.opacity(isHero ? 0.14 : 0.068)
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
        // 仅「即将出发」展示打包件数：规划中行程日期未定、打包信息不可行动 → 不展示（噪音）；
        // 已结束行程同样不展示。isHero = !isPast && !isDateless。
        guard isHero else { return nil }
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
        .shadow(color: cardShadow, radius: isHero ? 18 : 14, x: 0, y: isHero ? 9 : 7)
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


// MARK: - Presenter recede effect (native sheet-stacking look over the root)

#if !targetEnvironment(macCatalyst)
/// Recreates iOS's "stacked sheets" recede for a sheet presented over the *root*
/// HomeView (which UIKit normally does NOT scale). Hosted invisibly inside the sheet
/// content; on present/dismiss it transforms the **presenting** view alongside the
/// system transition via `transitionCoordinator`, so the recede tracks the interactive
/// drag-to-dismiss — something a `@State`-bool-driven SwiftUI animation cannot do.
/// 复用于首页的 sheet（设置 / 搜索 / Trip Book）与创建行程 sheet（ContentView）：
/// 弹出时把背后的首页 host 往后缩成卡片、跟手拖拽，营造 Apple 原生「卡片叠层」观感。
struct PresenterRecedeEffect: UIViewControllerRepresentable {
    var scale: CGFloat = 0.92
    var cornerRadius: CGFloat = 16

    func makeUIViewController(context: Context) -> RecedeController {
        let c = RecedeController()
        c.scale = scale
        c.cornerRadius = cornerRadius
        return c
    }
    func updateUIViewController(_ controller: RecedeController, context: Context) {}

    final class RecedeController: UIViewController {
        var scale: CGFloat = 0.92
        var cornerRadius: CGFloat = 16

        /// The presenter of our sheet = the HomeView host. `presentingViewController`
        /// resolves up from this embedded child to the controller that presented the sheet.
        private var presenterView: UIView? { presentingViewController?.view }

        /// The recede only reads as native when the sheet is a bottom sheet — i.e. iPhone.
        /// On iPad sheets are centered form/page sheets; scaling the root behind one looks
        /// wrong, so skip there entirely.
        private var effectApplies: Bool {
            UIDevice.current.userInterfaceIdiom == .phone
                && !UIAccessibility.isReduceMotionEnabled
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            animateRecede(to: true)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            animateRecede(to: false)
        }

        private func animateRecede(to receded: Bool) {
            guard effectApplies, let v = presenterView else { return }

            // Never rasterize while the transform is animating (it would re-cache every
            // frame). Continuous curve matches Apple's card squircle.
            v.layer.shouldRasterize = false
            let displayScale = v.traitCollection.displayScale
            v.layer.rasterizationScale = displayScale > 0 ? displayScale : 3
            v.layer.masksToBounds = true
            v.layer.cornerCurve = .continuous

            let apply: (Bool) -> Void = { on in
                v.transform = on ? CGAffineTransform(scaleX: self.scale, y: self.scale) : .identity
                v.layer.cornerRadius = on ? self.cornerRadius : 0
            }
            let settle: (Bool) -> Void = { finalReceded in
                apply(finalReceded)
                if finalReceded {
                    // Static held state (Settings sitting open): cache the receded home as
                    // a bitmap so the live globe behind it doesn't force a full-screen
                    // offscreen pass (cornerRadius + masksToBounds) on every frame. The
                    // globe freezes in the cache, but it's hidden behind Settings anyway.
                    v.layer.shouldRasterize = true
                } else {
                    v.layer.masksToBounds = false
                }
            }
            guard let coordinator = transitionCoordinator else {
                settle(receded)
                return
            }
            coordinator.animate(alongsideTransition: { _ in apply(receded) },
                                completion: { _ in
                // End state = reality, not cancel-arithmetic. A cancelled interactive
                // dismiss fires viewWillDisappear THEN a spurious viewWillAppear, and BOTH
                // complete as `cancelled=true`; inverting `receded` there wrongly drove the
                // home to identity (un-receded) while the sheet was still up, which killed
                // the scale tracking on every subsequent drag. Instead: if our sheet is
                // still presented, the home stays receded; if it's gone, restore identity.
                settle(self.presentingViewController != nil)
            })
        }
    }
}
#endif

// MARK: - Preview

#Preview {
    HomeView()
        .environmentObject(TripStore())
        .environmentObject(NavigationRouter())
}

//
//  HomeView.swift
//  Carry
//

import SwiftUI
import MapKit

// MARK: - HomeView

struct HomeView: View {

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var store: TripStore
    @EnvironmentObject var router: NavigationRouter

    @State private var tripToDelete: TripBundle?
    @State private var showDeleteConfirmation = false
    @State private var listIdentity = UUID()
    @State private var didPlayInitialReveal = false
    @State private var initialRevealPhase = 0
    @State private var revealCurtainOpacity: Double = 1

    private func isPast(_ trip: TripBundle) -> Bool {
        let calendar = Calendar.current
        let returnDayStart = calendar.startOfDay(for: returnDate(for: trip))
        let todayStart = calendar.startOfDay(for: Date())
        return todayStart > returnDayStart
    }

    private func returnDate(for trip: TripBundle) -> Date {
        Calendar.current.date(byAdding: .day, value: trip.days, to: trip.departureDate) ?? trip.departureDate
    }

    private var upcomingTrips: [TripBundle] {
        guard !store.isHomeEmptyStateMockEnabled else { return [] }
        struct Decorated {
            let trip: TripBundle
            let isComplete: Bool
        }

        let decorated = store.trips
            .filter { !isPast($0) }
            .map { trip in
                let complete = trip.totalCount > 0 && trip.packedCount == trip.totalCount
                return Decorated(trip: trip, isComplete: complete)
            }

        return decorated
            .sorted { a, b in
                if a.isComplete != b.isComplete { return !a.isComplete }
                if a.trip.departureDate != b.trip.departureDate { return a.trip.departureDate < b.trip.departureDate }
                if a.trip.createdAt != b.trip.createdAt { return a.trip.createdAt > b.trip.createdAt }
                return a.trip.id.uuidString < b.trip.id.uuidString
            }
            .map(\.trip)
    }

    private var pastTripsByYear: [(year: Int, trips: [TripBundle])] {
        guard !store.isHomeEmptyStateMockEnabled else { return [] }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: store.trips.filter { isPast($0) }) { trip in
            calendar.component(.year, from: returnDate(for: trip))
        }

        return grouped.keys.sorted(by: >).map { year in
            let trips = grouped[year, default: []].sorted { lhs, rhs in
                let lhsReturn = returnDate(for: lhs)
                let rhsReturn = returnDate(for: rhs)
                if lhsReturn != rhsReturn { return lhsReturn > rhsReturn }
                if lhs.departureDate != rhs.departureDate { return lhs.departureDate > rhs.departureDate }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return (year: year, trips: trips)
        }
    }

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

    @State private var sheetOffset: CGFloat = 0
    @State private var capsuleDrag: CGFloat = 0
    @State private var listDrag: CGFloat = 0

    private var expandedSheetHeight: CGFloat {
        UIScreen.main.bounds.height * 0.90
    }

    private var collapsedSheetOffset: CGFloat {
        max(0, expandedSheetHeight - 144)
    }

    /// 0 = fully expanded, 1 = fully collapsed (includes live drag)
    private var sheetProgress: CGFloat {
        guard collapsedSheetOffset > 0 else { return 0 }
        let raw = sheetOffset + capsuleDrag + listDrag
        return min(max(0, raw), collapsedSheetOffset) / collapsedSheetOffset
    }

    /// Horizontal scale: 1.0 when expanded → 0.97 when fully collapsed
    private var sheetScaleX: CGFloat { 1.0 - sheetProgress * 0.03 }

    /// Top corner radius: 36 when expanded → 42 when fully collapsed
    private var sheetCornerRadius: CGFloat { 36 + sheetProgress * 6 }

    /// Unique country codes from all trips whose departure date has passed,
    /// regardless of whether coordinates have been resolved yet.
    private var visitedCountriesCount: Int {
        Set(
            store.trips
                .filter { $0.departureDate <= Date() && !$0.countryCode.isEmpty }
                .map { $0.countryCode.uppercased() }
        ).count
    }

    /// Deduplicated city dots for departed trips with valid coordinates.
    /// Rounded to ~1 km precision so multiple trips to the same city collapse to one dot.
    private var visitedCities: [VisitedCity] {
        var seen = Set<String>()
        return store.trips
            .filter { $0.departureDate <= Date() && $0.latitude != 0 }
            .compactMap { trip -> VisitedCity? in
                let key = "\(Int(trip.latitude * 100)),\(Int(trip.longitude * 100))"
                guard seen.insert(key).inserted else { return nil }
                return VisitedCity(
                    id: key,
                    coordinate: CLLocationCoordinate2D(latitude: trip.latitude, longitude: trip.longitude)
                )
            }
    }

    private var visitedCountries: [VisitedCountry] {
        let departed = store.trips.filter {
            $0.departureDate <= Date() && !$0.countryCode.isEmpty && $0.latitude != 0
        }
        var grouped: [String: [TripBundle]] = [:]
        for trip in departed {
            grouped[trip.countryCode.uppercased(), default: []].append(trip)
        }
        return grouped.map { code, trips in
            let latest = trips.max(by: { $0.departureDate < $1.departureDate }) ?? trips[0]
            let name = Locale.current.localizedString(forRegionCode: code) ?? code
            return VisitedCountry(
                countryCode: code,
                name: name,
                coordinate: CLLocationCoordinate2D(latitude: latest.latitude, longitude: latest.longitude)
            )
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Globe background
            GlobeMapView(
                visitedCountries: visitedCountries,
                visitedCities: visitedCities,
                cityOpacity: Double(sheetProgress)
            )
                .ignoresSafeArea()

            // Trip list sheet
            VStack(spacing: 0) {
                // Drag handle — gesture lives only here so List scrolls freely
                Capsule()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 36, height: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .global)
                            .onChanged { v in
                                capsuleDrag = v.translation.height
                            }
                            .onEnded { v in
                                let velocity = v.velocity.height
                                let translation = v.translation.height
                                let currentOffset = min(max(0, sheetOffset + translation), collapsedSheetOffset)
                                let shouldCollapse: Bool
                                if velocity > 650 || translation > collapsedSheetOffset * 0.46 {
                                    shouldCollapse = true
                                } else if velocity < -350 || translation < -70 {
                                    shouldCollapse = false
                                } else {
                                    shouldCollapse = currentOffset > collapsedSheetOffset * 0.68
                                }
                                let target: CGFloat = shouldCollapse ? collapsedSheetOffset : 0
                                let travel = target - currentOffset
                                let normalizedV = abs(travel) < 1 ? 0 : max(-2.5, min(2.5, velocity / travel))
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                withAnimation(.interpolatingSpring(stiffness: 280, damping: 30, initialVelocity: normalizedV)) {
                                    capsuleDrag = 0
                                    sheetOffset = target
                                }
                            }
                    )

                ZStack {
                    List {
                        heroSection
                            .opacity(initialRevealPhase >= 1 ? 1 : 0)
                            .offset(y: initialRevealPhase >= 1 ? 0 : 18)
                            .scaleEffect(initialRevealPhase >= 1 ? 1 : 0.985)
                            .blur(radius: initialRevealPhase >= 1 ? 0 : 6)
                            .animation(.spring(response: 0.48, dampingFraction: 0.86).delay(0.02), value: initialRevealPhase)
                            .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 4, trailing: 12))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)

                        if store.trips.isEmpty {
                            emptyState
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 10, trailing: 12))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        } else {
                            if !upcomingTrips.isEmpty {
                                sectionLabel("home.upcoming", uppercase: true)
                                    .opacity(initialRevealPhase >= 2 ? 1 : 0)
                                    .offset(y: initialRevealPhase >= 2 ? 0 : 10)
                                    .blur(radius: initialRevealPhase >= 2 ? 0 : 4)
                                    .animation(.easeOut(duration: 0.24).delay(0.16), value: initialRevealPhase)
                                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 4, trailing: 16))
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)

                                ForEach(Array(upcomingTrips.enumerated()), id: \.element.id) { index, bundle in
                                    tripRow(bundle: bundle, isPast: false)
                                        .opacity(initialRevealPhase >= 2 ? 1 : 0)
                                        .offset(y: initialRevealPhase >= 2 ? 0 : 14)
                                        .scaleEffect(initialRevealPhase >= 2 ? 1 : 0.97)
                                        .blur(radius: initialRevealPhase >= 2 ? 0 : 5)
                                        .animation(.spring(response: 0.42, dampingFraction: 0.84).delay(0.20 + Double(index) * 0.05), value: initialRevealPhase)
                                }
                            }

                            ForEach(Array(pastTripsByYear.enumerated()), id: \.element.year) { index, section in
                                pastSectionLabel(year: section.year, isFirst: upcomingTrips.isEmpty && index == 0, delay: 0.34 + Double(index) * 0.06)

                                ForEach(Array(section.trips.enumerated()), id: \.element.id) { tripIndex, bundle in
                                    pastTripRow(
                                        bundle: bundle,
                                        delay: 0.38 + Double(index) * 0.06 + Double(tripIndex) * 0.03
                                    )
                                }
                            }

                            listFooter
                                .opacity(initialRevealPhase >= 3 ? 1 : 0)
                                .offset(y: initialRevealPhase >= 3 ? 0 : 8)
                                .blur(radius: initialRevealPhase >= 3 ? 0 : 3)
                                .animation(.easeOut(duration: 0.24).delay(0.56), value: initialRevealPhase)
                                .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 4, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)

                            Color.clear
                                .frame(height: 72)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                    .id(listIdentity)
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.hidden)
                    .background(Color.clear)
                    .background(
                        ListDragBridge(
                            sheetOffset: $sheetOffset,
                            listDrag: $listDrag,
                            collapsedSheetOffset: collapsedSheetOffset
                        )
                    )
                }
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
                .navigationBarHidden(true)
                .onAppear {
                    store.refresh()
                    store.correctMisgecodedTrips()
                    store.geocodeMissingTrips()
                    if !didPlayInitialReveal {
                        didPlayInitialReveal = true
                        initialRevealPhase = 0
                        revealCurtainOpacity = 1
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                            withAnimation(.easeOut(duration: 0.38)) {
                                revealCurtainOpacity = 0
                            }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                            withAnimation(.spring(response: 0.48, dampingFraction: 0.88)) {
                                initialRevealPhase = 1
                            }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            withAnimation(.spring(response: 0.44, dampingFraction: 0.84)) {
                                initialRevealPhase = 2
                            }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                            withAnimation(.spring(response: 0.44, dampingFraction: 0.84)) {
                                initialRevealPhase = 3
                            }
                        }
                    }
                }
                .onReceive(router.$path) { path in
                    if path.isEmpty {
                        store.refresh()
                    }
                }
                .alert(
                    "Delete \(tripToDelete?.name ?? "")?",
                    isPresented: $showDeleteConfirmation
                ) {
                    Button("Delete", role: .destructive) {
                        if let trip = tripToDelete {
                            store.removeTrip(withId: trip.id)
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This will permanently delete your packing list and all progress.")
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: expandedSheetHeight)
            .background(CarryAtmosphereBackground())
            .compositingGroup()
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: sheetCornerRadius, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: sheetCornerRadius, style: .continuous))
            .scaleEffect(x: sheetScaleX, y: 1.0, anchor: .bottom)
            .offset(y: min(max(0, sheetOffset + capsuleDrag + listDrag), collapsedSheetOffset))
    }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - List drag bridge

    private struct ListDragBridge: UIViewRepresentable {
        @Binding var sheetOffset: CGFloat
        @Binding var listDrag: CGFloat
        let collapsedSheetOffset: CGFloat

        func makeUIView(context: Context) -> UIView { UIView(frame: .zero) }

        func updateUIView(_ uiView: UIView, context: Context) {
            context.coordinator.sheetOffset = $sheetOffset
            context.coordinator.listDrag = $listDrag
            context.coordinator.collapsedSheetOffset = collapsedSheetOffset
            context.coordinator.attachIfNeeded(from: uiView)
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        // Delegate proxy that intercepts two UIScrollViewDelegate methods:
        // • scrollViewWillBeginDecelerating — cancels deceleration when cancelNext is armed
        // • scrollViewDidScroll — locks contentOffset while lockedOffsetY is set (belt-and-suspenders)
        // All other delegate messages are forwarded to the original delegate via forwardingTarget.
        private class DecelerationCanceller: NSObject, UIScrollViewDelegate {
            weak var original: AnyObject?
            var cancelNext = false
            var lockedOffsetY: CGFloat? = nil

            func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
                if cancelNext {
                    cancelNext = false
                    scrollView.setContentOffset(scrollView.contentOffset, animated: false)
                }
                (original as? UIScrollViewDelegate)?.scrollViewWillBeginDecelerating?(scrollView)
            }

            func scrollViewDidScroll(_ scrollView: UIScrollView) {
                if let locked = lockedOffsetY, abs(scrollView.contentOffset.y - locked) > 0.5 {
                    // Deceleration slipped through — force the offset back every frame
                    scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: locked), animated: false)
                }
                (original as? UIScrollViewDelegate)?.scrollViewDidScroll?(scrollView)
            }

            override func responds(to sel: Selector!) -> Bool {
                sel == #selector(UIScrollViewDelegate.scrollViewWillBeginDecelerating(_:))
                    || sel == #selector(UIScrollViewDelegate.scrollViewDidScroll(_:))
                    || (original?.responds(to: sel) ?? false)
            }

            override func forwardingTarget(for sel: Selector!) -> Any? {
                guard sel != #selector(UIScrollViewDelegate.scrollViewWillBeginDecelerating(_:)),
                      sel != #selector(UIScrollViewDelegate.scrollViewDidScroll(_:)) else { return nil }
                return (original?.responds(to: sel) == true) ? original : nil
            }
        }

        final class Coordinator: NSObject {
            var sheetOffset: Binding<CGFloat>?
            var listDrag: Binding<CGFloat>?
            var collapsedSheetOffset: CGFloat = 0
            private weak var attachedScrollView: UIScrollView?
            private var capturedTranslationAtTop: CGFloat? = nil
            private var wasAtTop = false
            private var savedScrollOffsetY: CGFloat = 0
            private var isExpandingFromCollapsed = false
            private var decelerationCanceller: DecelerationCanceller?
            // Watches sv.delegate so we can reinstall the proxy if SwiftUI resets it
            private var delegateObservation: NSKeyValueObservation?

            func attachIfNeeded(from view: UIView) {
                guard attachedScrollView == nil else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.attachedScrollView == nil else { return }
                    if let sv = self.findScrollView(from: view) {
                        self.attachedScrollView = sv
                        sv.panGestureRecognizer.addTarget(self, action: #selector(self.handleScrollPan(_:)))
                        self.installDelegateProxy(on: sv)
                        // SwiftUI may reset sv.delegate on each render cycle.
                        // KVO ensures the proxy is always in place when needed.
                        self.delegateObservation = sv.observe(\.delegate, options: []) { [weak self, weak sv] _, _ in
                            guard let self, let sv, sv.delegate !== self.decelerationCanceller else { return }
                            self.installDelegateProxy(on: sv)
                        }
                    }
                }
            }

            private func installDelegateProxy(on sv: UIScrollView) {
                let canceller = decelerationCanceller ?? DecelerationCanceller()
                canceller.original = sv.delegate
                sv.delegate = canceller
                decelerationCanceller = canceller
            }

            private func findScrollView(from view: UIView) -> UIScrollView? {
                var ancestor: UIView? = view.superview
                while let parent = ancestor {
                    for sub in parent.subviews where sub !== view {
                        if let sv = sub as? UIScrollView { return sv }
                        if let sv = firstScrollView(in: sub) { return sv }
                    }
                    ancestor = parent.superview
                }
                return nil
            }

            private func firstScrollView(in view: UIView) -> UIScrollView? {
                if let sv = view as? UIScrollView { return sv }
                for child in view.subviews {
                    if let sv = firstScrollView(in: child) { return sv }
                }
                return nil
            }

            @objc private func handleScrollPan(_ pan: UIPanGestureRecognizer) {
                guard let sv = attachedScrollView else { return }
                let topInset = -sv.adjustedContentInset.top
                let translation = pan.translation(in: sv).y
                let velocity  = pan.velocity(in: sv).y
                let atTop = sv.contentOffset.y <= topInset + 1
                let isCollapsed = (sheetOffset?.wrappedValue ?? 0) >= collapsedSheetOffset - 1

                switch pan.state {
                case .changed:
                    // --- Collapse: scroll is at top and moving downward ---
                    if atTop && velocity > 0 {
                        if !wasAtTop {
                            // Just arrived at top mid-gesture — capture this translation as baseline
                            capturedTranslationAtTop = translation
                        }
                        if let captured = capturedTranslationAtTop {
                            let drag = max(0, translation - captured)
                            listDrag?.wrappedValue = drag
                            sv.contentOffset.y = topInset  // prevent overscroll
                        }
                    } else if capturedTranslationAtTop != nil && !atTop {
                        // Scrolled back above top — cancel sheet drag
                        capturedTranslationAtTop = nil
                        listDrag?.wrappedValue = 0
                    }

                    // --- Expand: sheet is collapsed and moving upward ---
                    // Use translation (cumulative) not velocity so slow drags are caught reliably
                    if isCollapsed && translation < 0 {
                        if !isExpandingFromCollapsed {
                            // Collapsed state always shows the top of the list.
                            // Read contentOffset only after we've locked it to topInset;
                            // using the live value here races with UIKit's own scroll update
                            // on fast swipes and captures a stale, already-scrolled offset.
                            savedScrollOffsetY = topInset
                            isExpandingFromCollapsed = true
                        }
                        listDrag?.wrappedValue = min(0, translation)
                        sv.contentOffset.y = topInset  // lock scroll while expanding
                        // Pre-arm the deceleration canceller NOW — scrollViewWillBeginDecelerating
                        // fires inside UIKit's own .ended handler, before ours, so setting this
                        // flag in .ended would be too late
                        decelerationCanceller?.cancelNext = true
                    }

                    // While sheet is fully collapsed, block all list scrolling
                    if isCollapsed {
                        sv.contentOffset.y = topInset
                    }

                    wasAtTop = atTop

                case .ended, .cancelled, .failed:
                    let drag = listDrag?.wrappedValue ?? 0
                    capturedTranslationAtTop = nil
                    wasAtTop = false

                    guard drag != 0 else {
                        isExpandingFromCollapsed = false
                        return
                    }
                    let wasExpanding = drag < 0
                    if isExpandingFromCollapsed {
                        let targetY = savedScrollOffsetY
                        isExpandingFromCollapsed = false
                        // Primary: cancel deceleration via scrollViewWillBeginDecelerating
                        decelerationCanceller?.cancelNext = true
                        // Backup: lock contentOffset in scrollViewDidScroll every frame in
                        // case deceleration slips through (e.g. proxy was briefly uninstalled)
                        decelerationCanceller?.lockedOffsetY = targetY
                        sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: targetY), animated: false)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                            self?.decelerationCanceller?.lockedOffsetY = nil
                        }
                    } else if wasExpanding {
                        decelerationCanceller?.cancelNext = true
                        sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: topInset), animated: false)
                    }
                    let shouldCollapse: Bool
                    if drag > 0 {
                        let current = (sheetOffset?.wrappedValue ?? 0) + drag
                        shouldCollapse = velocity > 650 || current > collapsedSheetOffset * 0.46
                    } else {
                        shouldCollapse = !(velocity < -350 || drag < -70)
                    }
                    let currentOffset = min(max(0, (sheetOffset?.wrappedValue ?? 0) + drag), collapsedSheetOffset)
                    let target: CGFloat = shouldCollapse ? collapsedSheetOffset : 0
                    let travel = target - currentOffset
                    let normalizedV = abs(travel) < 1 ? 0 : max(-2.5, min(2.5, velocity / travel))
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    withAnimation(.interpolatingSpring(stiffness: 280, damping: 30, initialVelocity: normalizedV)) {
                        listDrag?.wrappedValue = 0
                        sheetOffset?.wrappedValue = target
                    }

                default: break
                }
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

            HStack(spacing: 10) {
                statPill(value: "\(store.trips.count)", label: "home.allTrips")
                statPill(value: "\(upcomingTrips.count)", label: "home.upcoming")
                statPill(value: "\(visitedCountriesCount)", label: "home.countries")
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
                                Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.96),
                                Color(red: 0.20, green: 0.20, blue: 0.21).opacity(0.90)
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
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.05), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.045), radius: colorScheme == .dark ? 18 : 16, x: 0, y: colorScheme == .dark ? 12 : 10)
    }

    private func sectionLabel(_ key: LocalizedStringKey, uppercase: Bool = false) -> some View {
        Text(key)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(colorScheme == .dark ? .secondary : .tertiary)
            .textCase(uppercase ? .uppercase : nil)
            .tracking(2)
    }

    private func sectionLabel(verbatim: String) -> some View {
        Text(verbatim: verbatim)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(colorScheme == .dark ? .secondary : .tertiary)
            .tracking(2)
    }

    private func pastSectionLabel(year: Int, isFirst: Bool, delay: Double) -> some View {
        sectionLabel(verbatim: "\(year)")
            .opacity(initialRevealPhase >= 3 ? 1 : 0)
            .offset(y: initialRevealPhase >= 3 ? 0 : 10)
            .blur(radius: initialRevealPhase >= 3 ? 0 : 4)
            .animation(.easeOut(duration: 0.24).delay(delay), value: initialRevealPhase)
            .listRowInsets(EdgeInsets(top: isFirst ? 0 : 14, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private func pastTripRow(bundle: TripBundle, delay: Double) -> some View {
        tripRow(bundle: bundle, isPast: true)
            .opacity(initialRevealPhase >= 3 ? 1 : 0)
            .offset(y: initialRevealPhase >= 3 ? 0 : 14)
            .scaleEffect(initialRevealPhase >= 3 ? 1 : 0.97)
            .blur(radius: initialRevealPhase >= 3 ? 0 : 5)
            .animation(.spring(response: 0.42, dampingFraction: 0.84).delay(delay), value: initialRevealPhase)
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
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.03 : 0.04), lineWidth: 1)
        )
    }

    private var statPillFill: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.17, green: 0.17, blue: 0.18),
                    Color(red: 0.20, green: 0.20, blue: 0.21)
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
                .foregroundStyle(.secondary)
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
            return "第一次出行的地方"
        }
        return "The place where your first trip began"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "suitcase")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .frame(width: 78, height: 78)
                .background(
                    Circle()
                        .fill(Color(UIColor.systemBackground))
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
                )

            VStack(spacing: 8) {
                Text("No trips yet")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Tap the plus button to create your first trip")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }

            Button {
                startNewTrip()
            } label: {
                Text("Create Trip")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary)
                    )
                    .foregroundStyle(Color(UIColor.systemBackground))
            }
            .buttonStyle(PressableScaleButtonStyle(scale: 0.96, pressedBrightness: -0.02, pressedOpacity: 0.96))
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private func tripRow(bundle: TripBundle, isPast: Bool) -> some View {
        Button {
            openTrip(bundle)
        } label: {
            TripCard(bundle: bundle, isPast: isPast)
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
            ? Color.white.opacity(0.06)
            : Color(uiColor: .systemGray5)
    }

    private var cardFill: LinearGradient {
        if isPast {
            if colorScheme == .dark {
                return LinearGradient(
                    colors: [
                        Color(red: 0.12, green: 0.12, blue: 0.13),
                        Color(red: 0.14, green: 0.14, blue: 0.15)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            return LinearGradient(
                colors: [
                    Color(UIColor.systemBackground).opacity(colorScheme == .dark ? 0.82 : 0.90),
                    Color(UIColor.systemBackground).opacity(colorScheme == .dark ? 0.76 : 0.84)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.14, green: 0.14, blue: 0.15),
                    Color(red: 0.17, green: 0.17, blue: 0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        return LinearGradient(
            colors: [
                Color(red: 0.99, green: 0.98, blue: 0.95),
                Color(UIColor.systemBackground).opacity(colorScheme == .dark ? 0.82 : 0.94)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var cardShadow: Color {
        if colorScheme == .dark {
            return Color.black.opacity(isPast ? 0.16 : 0.22)
        }
        return isPast ? Color.black.opacity(0.048) : Color.black.opacity(0.068)
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
            return colorScheme == .dark ? Color.white.opacity(0.035) : Color(UIColor.systemGray5).opacity(0.58)
        }
        if isComplete {
            return colorScheme == .dark ? Color.white.opacity(0.045) : Color(UIColor.systemGray5).opacity(0.72)
        }
        return colorScheme == .dark ? Color.blue.opacity(0.07) : Color.blue.opacity(0.10)
    }

    private var statusPillStrokeColor: Color {
        if bundle.totalCount == 0 {
            return Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.03)
        }
        if isComplete {
            return Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.025)
        }
        return Color.blue.opacity(colorScheme == .dark ? 0.08 : 0.16)
    }

    private var statusPillForeground: Color {
        if bundle.totalCount == 0 {
            return colorScheme == .dark ? .secondary.opacity(0.65) : .secondary.opacity(0.82)
        }
        if isComplete {
            return colorScheme == .dark ? .secondary.opacity(0.68) : .secondary.opacity(0.76)
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
                    .foregroundColor(colorScheme == .dark ? Color.white.opacity(0.56) : Color(.systemGray))
                    .lineLimit(1)
                    .padding(.bottom, 4)

                HStack(spacing: 8) {
                    Text(dateAndDurationText)
                        .font(.caption.weight(.medium))
                        .foregroundColor(colorScheme == .dark ? Color.white.opacity(0.30) : Color(.systemGray2))
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
                .strokeBorder(Color.primary.opacity(isPast ? 0.035 : 0.05), lineWidth: 1)
        )
        .shadow(color: cardShadow, radius: isPast ? 10 : 14, x: 0, y: isPast ? 5 : 7)
        .contentShape(RoundedRectangle(cornerRadius: 18))
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

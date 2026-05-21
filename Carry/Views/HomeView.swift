//
//  HomeView.swift
//  Carry
//

import SwiftUI

// MARK: - HomeView

struct HomeView: View {

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var store: TripStore
    @EnvironmentObject var router: NavigationRouter

    @State private var tripToDelete: TripBundle?
    @State private var showDeleteConfirmation = false
    @State private var listIdentity = UUID()

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
        router.path.append(CreationRoute.tripInfo(UUID(), startInMyItems: false))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("home.title")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                Spacer()
                Button {
                    startNewTrip()
                } label: {
                    plusButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)

            if store.trips.isEmpty {
                Spacer()
                Spacer()
                VStack(spacing: 0) {
                    Image(systemName: "suitcase")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No trips yet")
                        .font(.headline)
                        .foregroundColor(.primary)
                        .padding(.top, 12)
                    Text("Tap + to start packing for your next trip")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity)
                Spacer()
                Spacer()
                Spacer()
            } else {
                List {
                    if !upcomingTrips.isEmpty {
                        Text("home.upcoming")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(colorScheme == .dark ? .secondary : .tertiary)
                            .tracking(2)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)

                        ForEach(upcomingTrips) { bundle in
                            tripRow(bundle: bundle, isPast: false)
                        }
                    }

                    ForEach(Array(pastTripsByYear.enumerated()), id: \.element.year) { index, section in
                        Text(verbatim: "\(section.year)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(colorScheme == .dark ? .secondary : .tertiary)
                            .tracking(2)
                            .listRowInsets(EdgeInsets(top: upcomingTrips.isEmpty && index == 0 ? 0 : 24, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)

                        ForEach(section.trips) { bundle in
                            tripRow(bundle: bundle, isPast: true)
                        }
                    }
                }
                .id(listIdentity)
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
        }
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .navigationBarHidden(true)
        .onAppear { store.refresh() }
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

    private var plusButton: some View {
        Image(systemName: "plus")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .glassCircleButton()
    }

    @ViewBuilder
    private func tripRow(bundle: TripBundle, isPast: Bool) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            router.path.append(bundle.id)
        } label: {
            TripCard(bundle: bundle, isPast: isPast)
        }
        .buttonStyle(PressableScaleButtonStyle(scale: 0.985))
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

    private var cardBackgroundColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.09)
            : Color(uiColor: .systemBackground)
    }

    private var cardBorderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.18)
            : Color(uiColor: .separator).opacity(0.4)
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
            ? Color.white.opacity(0.18)
            : Color(uiColor: .systemGray5)
    }

    private var cardHighlightColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.white.opacity(0.55)
    }

    private var cardShadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.24) : Color.black.opacity(0.08)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(bundle.name)
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                if isComplete && !isPast {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
            }
            .padding(.bottom, 2)

            Text(bundle.destinationCity)
                .font(.subheadline)
                .foregroundColor(Color(.systemGray))
                .padding(.bottom, 2)

            HStack {
                Text(dateAndDurationText)
                    .font(.caption)
                    .foregroundColor(Color(.systemGray2))
                if !isPast {
                    Spacer()
                    Text(remainingText)
                        .font(.caption.weight(.medium))
                        .foregroundColor(Color(.systemGray2))
                        .transition(.opacity)
                        .frame(width: 90, alignment: .trailing)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: isComplete)

            if !isPast {
                Color.clear.frame(height: 8)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(.systemGray5))
                            .frame(height: 3)
                        Capsule()
                            .fill(Color.primary)
                            .frame(width: max(0, geo.size.width * progress), height: 3)
                            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: progress)
                    }
                }
                .frame(height: 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(cardBackgroundColor)
                .overlay(
                    LinearGradient(
                        colors: [cardHighlightColor, .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .opacity(0.34)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(cardBorderColor, lineWidth: 0.6)
        )
        .shadow(color: cardShadowColor, radius: 14, x: 0, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct PressableScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    var pressedBrightness: Double = 0

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .brightness(configuration.isPressed ? pressedBrightness : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}


// MARK: - Preview

#Preview {
    NavigationStack {
        HomeView()
    }
    .environmentObject(TripStore())
    .environmentObject(NavigationRouter())
}

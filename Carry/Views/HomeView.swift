//
//  HomeView.swift
//  Carry
//

import SwiftUI

// MARK: - HomeView

struct HomeView: View {

    @EnvironmentObject var store: TripStore
    @EnvironmentObject var router: NavigationRouter

    @State private var tripToDelete: TripBundle?
    @State private var showDeleteConfirmation = false

    private static let archiveThresholdDays = 30

    private func isPast(_ trip: TripBundle) -> Bool {
        let cutoff = Calendar.current.date(byAdding: .day, value: Self.archiveThresholdDays, to: trip.departureDate)
            ?? trip.departureDate
        return cutoff < Date()
    }

    private var upcomingTrips: [TripBundle] {
        store.trips
            .filter { !isPast($0) }
            .sorted { a, b in
                let aComplete = a.packedCount == a.totalCount && a.totalCount > 0
                let bComplete = b.packedCount == b.totalCount && b.totalCount > 0
                if aComplete != bComplete { return !aComplete }
                return a.departureDate < b.departureDate
            }
    }

    private var pastTrips: [TripBundle] {
        store.trips
            .filter { isPast($0) }
            .sorted { $0.departureDate > $1.departureDate }
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
                    router.path.append(CreationRoute.tripInfo)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 38, height: 38)
                        .background(Color(UIColor.secondarySystemFill))
                        .clipShape(Circle())
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
                        Text(upcomingTrips.count == 1 ? "1 trip upcoming" : "\(upcomingTrips.count) trips upcoming")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)

                        ForEach(upcomingTrips) { bundle in
                            tripRow(bundle: bundle, isPast: false)
                        }
                    }

                    if !pastTrips.isEmpty {
                        Text("home.past")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .kerning(1.5)
                            .textCase(.uppercase)
                            .listRowInsets(EdgeInsets(top: upcomingTrips.isEmpty ? 0 : 16, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)

                        ForEach(pastTrips) { bundle in
                            tripRow(bundle: bundle, isPast: true)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationBarHidden(true)
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

    @ViewBuilder
    private func tripRow(bundle: TripBundle, isPast: Bool) -> some View {
        Button {
            router.path.append(bundle.id)
        } label: {
            TripCard(bundle: bundle, isPast: isPast)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .none) {
                tripToDelete = bundle
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 10, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

}

// MARK: - Trip Card

struct TripCard: View {

    let bundle: TripBundle
    var isPast: Bool = false

    private var progress: Double {
        bundle.totalCount == 0 ? 0 : Double(bundle.packedCount) / Double(bundle.totalCount)
    }

    private var isComplete: Bool {
        bundle.totalCount > 0 && bundle.packedCount == bundle.totalCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(bundle.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(isPast ? .secondary : .primary)
                        if isComplete && !isPast {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                    }
                    Text(bundle.destinationCity)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(bundle.dateRange) · \(bundle.days) days")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if !isPast {
                    Text(isComplete ? "All packed" : "\(bundle.packedCount) / \(bundle.totalCount)")
                        .font(.caption)
                        .foregroundStyle(isComplete ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .padding(.top, 1)
                }
            }

            if !isPast {
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(UIColor.tertiarySystemFill))
                                .frame(height: 4)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.primary)
                                .frame(width: max(0, geo.size.width * progress), height: 4)
                        }
                    }
                    .frame(height: 4)

                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, isPast ? 12 : 16)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(16)
        .opacity(isPast ? 0.6 : 1.0)
    }

    private var statusText: String {
        if isComplete { return "All packed — you're ready to go!" }
        if bundle.totalCount == 0 { return "No items yet" }
        let remaining = bundle.totalCount - bundle.packedCount
        return "\(remaining) item\(remaining == 1 ? "" : "s") left to pack"
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

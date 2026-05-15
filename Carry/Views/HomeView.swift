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

    private var sortedTrips: [TripBundle] {
        store.trips.sorted { a, b in
            let aComplete = a.packedCount == a.totalCount && a.totalCount > 0
            let bComplete = b.packedCount == b.totalCount && b.totalCount > 0
            if aComplete != bComplete { return !aComplete }
            return a.departureDate < b.departureDate
        }
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
                        .frame(width: 32, height: 32)
                        .background(Color(UIColor.tertiarySystemFill))
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
                    Text(store.trips.count == 1 ? "1 trip upcoming" : "\(store.trips.count) trips upcoming")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                    ForEach(sortedTrips) { bundle in
                        Button {
                            router.path.append(bundle.id)
                        } label: {
                            TripCard(bundle: bundle)
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
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
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

}

// MARK: - Trip Card

struct TripCard: View {

    let bundle: TripBundle

    private var progress: Double {
        bundle.totalCount == 0 ? 0 : Double(bundle.packedCount) / Double(bundle.totalCount)
    }

    private var isComplete: Bool {
        bundle.totalCount > 0 && bundle.packedCount == bundle.totalCount
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(bundle.name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        if isComplete {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                        Text("· \(bundle.days) days")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text(bundle.dateRange)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if isComplete {
                    Text("All packed")
                        .font(.caption)
                        .foregroundColor(.primary)
                } else {
                    Text("\(bundle.packedCount) / \(bundle.totalCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(UIColor.tertiarySystemFill))
                        .frame(height: 3)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary)
                        .frame(width: max(0, geo.size.width * progress), height: 3)
                }
            }
            .frame(height: 3)
        }
        .padding(12)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
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

//
//  EditTripView.swift
//  Carry
//

import SwiftUI

struct EditTripView: View {

    let tripId: UUID

    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss

    @State private var info: TripInfo

    init(trip: TripBundle) {
        self.tripId = trip.id
        let returnDate = Calendar.current.date(byAdding: .day, value: trip.days, to: trip.departureDate) ?? trip.departureDate
        _info = State(initialValue: TripInfo(
            name: trip.name,
            destinationCity: trip.destinationCity,
            departureDate: trip.departureDate,
            returnDate: returnDate
        ))
    }

    private var canSave: Bool {
        !info.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !info.destinationCity.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    fieldGroup(label: "Trip Name") {
                        TextField("e.g. Japan · Hokkaido", text: $info.name)
                            .font(.subheadline)
                            .padding(12)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(12)
                    }

                    fieldGroup(label: "Destination City") {
                        TextField("e.g. Sapporo", text: $info.destinationCity)
                            .font(.subheadline)
                            .padding(12)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(12)
                    }

                    fieldGroup(label: "Dates") {
                        VStack(spacing: 0) {
                            DatePicker("Departure", selection: $info.departureDate,
                                       displayedComponents: .date)
                                .font(.subheadline)
                                .padding(12)
                                .onChange(of: info.departureDate) { _, newVal in
                                    if info.returnDate < newVal {
                                        info.returnDate = Calendar.current.date(byAdding: .day, value: 1, to: newVal) ?? newVal
                                    }
                                }

                            Rectangle()
                                .fill(Color(UIColor.separator))
                                .frame(height: 0.5)
                                .padding(.horizontal, 12)

                            DatePicker("Return", selection: $info.returnDate,
                                       in: info.departureDate...,
                                       displayedComponents: .date)
                                .font(.subheadline)
                                .padding(12)
                        }
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .navigationTitle("Edit trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        store.updateTripInfo(tripId: tripId, info: info)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
        }
    }

    private func fieldGroup<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .kerning(1.5)
                .padding(.horizontal, 16)
            content()
                .padding(.horizontal, 16)
        }
    }
}

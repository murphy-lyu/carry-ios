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
    @State private var isSaved = false

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
                        stableField("e.g. Italy · Tuscany", text: $info.name)
                    }

                    fieldGroup(label: "Destination City") {
                        stableField("e.g. Florence", text: $info.destinationCity)
                    }

                    fieldGroup(label: "Dates") {
                        VStack(spacing: 0) {
                            DatePicker("Departure", selection: $info.departureDate,
                                       displayedComponents: .date)
                                .font(.subheadline)
                                .tint(.primary)
                                .padding(12)
                                .onChange(of: info.departureDate) { oldVal, newVal in
                                    let days = Calendar.current.dateComponents([.day], from: oldVal, to: info.returnDate).day ?? 7
                                    info.returnDate = Calendar.current.date(byAdding: .day, value: max(1, days), to: newVal) ?? newVal
                                }

                            Rectangle()
                                .fill(Color(UIColor.separator))
                                .frame(height: 0.5)
                                .padding(.horizontal, 12)

                            DatePicker("Return", selection: $info.returnDate,
                                       in: info.departureDate...,
                                       displayedComponents: .date)
                                .font(.subheadline)
                                .tint(.primary)
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
                    Button {
                        guard !isSaved else { return }
                        store.updateTripInfo(tripId: tripId, info: info)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        withAnimation(.easeInOut(duration: 0.2)) { isSaved = true }
                        Task {
                            try? await Task.sleep(for: .milliseconds(600))
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isSaved {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .transition(.scale.combined(with: .opacity))
                            }
                            Text(isSaved ? "Saved" : "Save")
                                .transition(.opacity)
                        }
                        .animation(.easeInOut(duration: 0.2), value: isSaved)
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave || isSaved)
                }
            }
        }
    }

    private func stableField(_ placeholder: LocalizedStringKey, text: Binding<String>) -> some View {
        ZStack(alignment: .leading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.subheadline)
                    .foregroundColor(Color(UIColor.placeholderText))
                    .allowsHitTesting(false)
            }
            TextField("", text: text)
                .font(.subheadline)
                .tint(.primary)
        }
        .frame(height: 44)
        .padding(.horizontal, 12)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func fieldGroup<Content: View>(
        label: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .kerning(1.5)
                .textCase(.uppercase)
                .padding(.horizontal, 16)
            content()
                .padding(.horizontal, 16)
        }
    }
}

//
//  EditTripView.swift
//  Carry
//

import SwiftUI
import UIKit

struct EditTripView: View {

    let tripId: UUID

    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss

    @State private var info: TripInfo
    @State private var isSaved = false
    @State private var showDatePicker = false
    @FocusState private var focusedField: FocusField?
    @Environment(\.colorScheme) private var colorScheme

    private enum FocusField: Hashable {
        case tripName
        case destinationCity
    }

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

    private func hideKeyboard() {
        focusedField = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CarrySubtleBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        heroSection

                        fieldGroup(label: "Trip Name") {
                            stableField("e.g. Italy · Tuscany", text: $info.name, focus: .tripName)
                        }

                        fieldGroup(label: "Destination City") {
                            stableField("e.g. Florence", text: $info.destinationCity, focus: .destinationCity)
                        }

                        fieldGroup(label: "Dates") {
                            Button { showDatePicker = true } label: {
                                HStack(spacing: 0) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Departure")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        Text(info.departureDate.formatted(date: .long, time: .omitted))
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 3) {
                                        Text("Return")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        Text(info.returnDate.formatted(date: .long, time: .omitted))
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                    }
                                }
                                .padding(14)
                            }
                            .buttonStyle(.plain)
                            .background(
                                colorScheme == .dark
                                    ? Color(UIColor.secondarySystemBackground)
                                    : Color(UIColor.systemBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                TapGesture().onEnded {
                    hideKeyboard()
                }
            )
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showDatePicker) {
                TripDateRangePickerSheet(
                    departure: info.departureDate,
                    return: info.returnDate
                ) { start, end in
                    info.departureDate = start
                    info.returnDate = max(end, Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        CarryLogger.shared.log(.tripEditCancelled)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        guard !isSaved else { return }
                        hideKeyboard()
                        store.updateTripInfo(tripId: tripId, info: info)
                        CarryLogger.shared.log(.tripEditSaved)
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

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit trip")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text("Update trip details without changing your list structure")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func stableField(
        _ placeholder: LocalizedStringKey,
        text: Binding<String>,
        focus: FocusField
    ) -> some View {
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
                .focused($focusedField, equals: focus)
                .textFieldStyle(.plain)
        }
        .frame(height: 44)
        .padding(.horizontal, 12)
        .background(
            colorScheme == .dark
                ? Color(UIColor.secondarySystemBackground)
                : Color(UIColor.systemBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

#Preview {
    let trip = TripBundle(name: "Tokyo", destinationCity: "Tokyo", days: 6, departureDate: Date())
    EditTripView(trip: trip)
        .environmentObject(TripStore())
}

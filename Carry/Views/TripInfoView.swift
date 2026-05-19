//
//  TripInfoView.swift
//  Carry
//

import SwiftUI
import UIKit

struct TripInfoView: View {

    @State private var tripName: String
    @State private var destinationCity: String
    @State private var departureDate: Date
    @State private var returnDate: Date
    @FocusState private var focusedField: FocusField?
    @State private var activePicker: ActiveDatePicker?
    @EnvironmentObject var router: NavigationRouter

    private enum FocusField: Hashable {
        case tripName
        case destinationCity
    }

    private enum ActiveDatePicker: String, Identifiable {
        case departure
        case `return`

        var id: String { rawValue }
    }

    init() {
        let initial = TripInfo()
        _tripName = State(initialValue: initial.name)
        _destinationCity = State(initialValue: initial.destinationCity)
        _departureDate = State(initialValue: initial.departureDate)
        _returnDate = State(initialValue: initial.returnDate)
    }

    private var canContinue: Bool {
        !tripName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !destinationCity.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var info: TripInfo {
        TripInfo(
            name: tripName,
            destinationCity: destinationCity,
            departureDate: departureDate,
            returnDate: returnDate
        )
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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                Text("Where are you headed?")
                    .font(.headline)
                    .fontWeight(.medium)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                fieldGroup(label: "Trip Name") {
                    stableField("e.g. Italy · Tuscany", text: $tripName, focus: .tripName)
                }

                fieldGroup(label: "Destination City") {
                    stableField("e.g. Florence", text: $destinationCity, focus: .destinationCity)
                }

                fieldGroup(label: "Dates") {
                    VStack(spacing: 0) {
                        dateRow(
                            title: "Departure",
                            value: departureDate,
                            action: { activePicker = .departure }
                        )

                        Rectangle()
                            .fill(Color(UIColor.separator))
                            .frame(height: 0.5)
                            .padding(.horizontal, 12)

                        dateRow(
                            title: "Return",
                            value: returnDate,
                            action: { activePicker = .return }
                        )
                    }
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                }
            }
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(
            TapGesture().onEnded {
                hideKeyboard()
            }
        )
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Button(action: {
                    hideKeyboard()
                    router.path.append(CreationRoute.itemPicker(info))
                }) {
                    Text("Continue")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(Color(UIColor.systemBackground))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.primary)
                        .cornerRadius(14)
                }
                .disabled(!canContinue)
                .opacity(canContinue ? 1 : 0.3)
                .padding(.horizontal, 16)
            }
            .padding(.top, 12)
            .padding(.bottom, 16)
            .background(Color(UIColor.systemBackground))
        }
        .navigationTitle("New trip")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activePicker) { picker in
            NavigationStack {
                VStack(spacing: 0) {
                    if picker == .departure {
                        DatePicker(
                            "Departure",
                            selection: $departureDate,
                            displayedComponents: .date
                        )
                        .datePickerStyle(.graphical)
                        .tint(.primary)
                        .padding(16)
                    } else {
                        DatePicker(
                            "Return",
                            selection: $returnDate,
                            in: departureDate...,
                            displayedComponents: .date
                        )
                        .datePickerStyle(.graphical)
                        .tint(.primary)
                        .padding(16)
                    }
                }
                .navigationTitle(picker == .departure ? "Departure" : "Return")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { activePicker = nil }
                    }
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: departureDate, initial: false) { _, newVal in
            returnDate = Calendar.current.date(byAdding: .day, value: 7, to: newVal) ?? newVal
        }
        .onChange(of: returnDate, initial: false) { _, newVal in
            if newVal < departureDate {
                returnDate = departureDate
            }
        }
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
        }
        .frame(height: 44)
        .padding(.horizontal, 12)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func dateRow(title: LocalizedStringKey, value: Date, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Text(value.formatted(date: .abbreviated, time: .omitted))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(UIColor.systemGray5))
                    .clipShape(Capsule())
            }
            .font(.subheadline)
            .padding(12)
        }
        .buttonStyle(.plain)
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
    NavigationStack {
        TripInfoView()
    }
    .environmentObject(NavigationRouter())
}

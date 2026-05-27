//
//  TripInfoView.swift
//  Carry
//

import SwiftUI
import UIKit

struct TripInfoView: View {

    let routeID: UUID?
    let startInMyItems: Bool
    @State private var tripName: String
    @State private var destinationCity: String
    @State private var departureDate: Date
    @State private var returnDate: Date
    @State private var showDatePicker = false
    @FocusState private var focusedField: FocusField?
    @EnvironmentObject var router: NavigationRouter
    @Environment(\.colorScheme) private var colorScheme

    private enum FocusField: Hashable {
        case tripName
        case destinationCity
    }

    init(routeID: UUID? = nil, startInMyItems: Bool = false) {
        self.routeID = routeID
        self.startInMyItems = startInMyItems
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

    private var continueButtonBackground: Color {
        if canContinue {
            return colorScheme == .dark ? Color(.label) : Color(.label)
        }
        return colorScheme == .dark ? Color(.secondarySystemBackground) : Color(.systemGray3)
    }

    private var continueButtonForeground: Color {
        canContinue ? Color(.systemBackground) : Color(.secondaryLabel)
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
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    heroSection

                    fieldGroup(label: "Trip Name") {
                        stableField("e.g. Italy · Tuscany", text: $tripName, focus: .tripName)
                    }

                    fieldGroup(label: "Destination City") {
                        stableField("e.g. Florence", text: $destinationCity, focus: .destinationCity)
                    }

                    fieldGroup(label: "Dates") {
                        Button { showDatePicker = true } label: {
                            HStack(spacing: 0) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Departure")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary.opacity(0.82))
                                    Text(departureDate.formatted(date: .long, time: .omitted))
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                }
                                Spacer()
                                Image(systemName: "arrow.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary.opacity(0.88))
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text("Return")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary.opacity(0.82))
                                    Text(returnDate.formatted(date: .long, time: .omitted))
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                }
                            }
                            .padding(14)
                        }
                        .buttonStyle(.plain)
                        .background(Color(UIColor.systemBackground).opacity(0.64))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.07),
                                    lineWidth: 1
                                )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(.bottom, 16)
            }
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
                    guard canContinue else { return }
                    hideKeyboard()
                    router.path.append(CreationRoute.itemPicker(info, startInMyItems: startInMyItems))
                }) {
                    Text("Continue")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(continueButtonForeground)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(continueButtonBackground)
                        .cornerRadius(14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color(.separator).opacity(canContinue ? 0.08 : 0.14), lineWidth: 1)
                        )
                }
                .buttonStyle(SolidPressButtonStyle())
                .allowsHitTesting(canContinue)
                .padding(.horizontal, 16)
            }
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
            .background(Color.clear)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDatePicker) {
            TripDateRangePickerSheet(
                departure: departureDate,
                return: returnDate
            ) { start, end in
                departureDate = start
                returnDate = max(end, Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start)
            }
        }
        .onAppear {
            #if DEBUG
            let dep = departureDate.formatted(date: .abbreviated, time: .omitted)
            let ret = returnDate.formatted(date: .abbreviated, time: .omitted)
            let context = "route=\(routeID?.uuidString ?? "nil") departure=\(dep) return=\(ret)"
            CarryLogger.shared.log(.tripInfoOpened, context: context)
            #endif
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New trip")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text("Add the essentials first, then choose your items")
                .font(.subheadline)
                .foregroundStyle(.secondary.opacity(0.86))
        }
        .padding(16)
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
        .background(Color(UIColor.systemBackground).opacity(0.66))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.07),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func fieldGroup<Content: View>(
        label: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary.opacity(0.86))
                .kerning(1.5)
                .textCase(.uppercase)
                .padding(.horizontal, 16)
            content()
                .padding(.horizontal, 16)
        }
    }
}

#Preview {
    TripInfoView()
        .environmentObject(NavigationRouter())
}

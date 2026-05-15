//
//  TripInfoView.swift
//  Carry
//

import SwiftUI

struct TripInfoView: View {

    @State private var info = TripInfo()
    @EnvironmentObject var router: NavigationRouter

    private var canContinue: Bool {
        !info.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !info.destinationCity.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // — Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tell us about your trip")
                        .font(.headline)
                        .fontWeight(.medium)
                    Text("We'll use this to build your list")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                // — Trip name
                fieldGroup(label: "Trip Name") {
                    TextField("e.g. Japan · Hokkaido", text: $info.name)
                        .font(.subheadline)
                        .padding(12)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                }

                // — Destination city
                fieldGroup(label: "Destination City") {
                    TextField("e.g. Sapporo", text: $info.destinationCity)
                        .font(.subheadline)
                        .padding(12)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                }

                // — Dates
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
            .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: { router.path.append(CreationRoute.scenePicker(info)) }) {
                Text("Continue")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(Color(UIColor.systemBackground))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.primary)
                    .cornerRadius(12)
            }
            .disabled(!canContinue)
            .opacity(canContinue ? 1 : 0.3)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(Color(UIColor.systemBackground))
        }
        .navigationTitle("New trip")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Helpers

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

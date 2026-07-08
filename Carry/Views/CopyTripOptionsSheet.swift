//
//  CopyTripOptionsSheet.swift
//  Carry
//
//  「复制行程」轻量弹层：新行程名称（预填原名，不自动加后缀）+ 新日期 +
//  要不要带上打包清单（默认不带，不同季节物品往往不同）+ 要不要带上交通/住宿具体预订信息（默认不带）。
//  行程规划的地点安排始终保留、不作为选项（spec: copy-trip-options.md）。
//

import SwiftUI

struct CopyTripOptionsSheet: View {
    let trip: TripBundle
    /// 复制成功后回调（新行程 id），由调用方负责关闭本 sheet + 后续导航/高亮。
    var onCompleted: (UUID) -> Void

    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss

    /// 预填原行程名称，不自动加"（副本）"后缀——改不改由用户自己决定（用户反馈）。
    @State private var name: String
    @State private var departureDate: Date
    @State private var returnDate: Date
    @State private var isDateless: Bool
    @State private var includeTransportAndLodging = false
    /// 默认不带打包清单——不同季节/行程物品往往不同，交给用户重新规划更合理（用户反馈）。
    @State private var includePackingList = false
    @State private var showDatePicker = false

    init(trip: TripBundle, onCompleted: @escaping (UUID) -> Void) {
        self.trip = trip
        self.onCompleted = onCompleted
        let ret = Calendar.current.date(byAdding: .day, value: trip.days, to: trip.departureDate) ?? trip.departureDate
        _name = State(initialValue: trip.name)
        _departureDate = State(initialValue: trip.departureDate)
        _returnDate = State(initialValue: ret)
        _isDateless = State(initialValue: trip.isDateless)
    }

    private var canConfirm: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $name) { Text("trip.copy.name_placeholder") }
                } header: {
                    Text("trip.copy.name_section")
                }

                Section {
                    if isDateless {
                        Button { showDatePicker = true } label: {
                            HStack {
                                Text("tripdates.unset")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Image(systemName: "calendar.badge.plus")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } else {
                        Button { showDatePicker = true } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("itinerary.transport.field.date")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(verbatim: "\(departureDate.formatted(date: .abbreviated, time: .omitted)) → \(returnDate.formatted(date: .abbreviated, time: .omitted))")
                                        .foregroundStyle(.primary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text("trip.copy.date_section")
                }
                .buttonStyle(.plain)

                Section {
                    Toggle(isOn: $includePackingList) {
                        Text("trip.copy.include_packing_list")
                    }
                } footer: {
                    Text("trip.copy.include_packing_list.footer")
                }

                Section {
                    Toggle(isOn: $includeTransportAndLodging) {
                        Text("trip.copy.include_transport_lodging")
                    }
                } footer: {
                    Text("trip.copy.include_transport_lodging.footer")
                }
            }
            .navigationTitle("trip.copy.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: confirm) {
                        Text("trip.copy.confirm").fontWeight(.semibold)
                    }
                    .disabled(!canConfirm)
                }
            }
            .sheet(isPresented: $showDatePicker) {
                TripDateRangePickerSheet(
                    departure: departureDate,
                    return: returnDate,
                    onSkipDates: { isDateless = true }
                ) { start, end in
                    departureDate = start
                    returnDate = max(end, Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start)
                    isDateless = false
                }
            }
        }
    }

    private func confirm() {
        guard let newId = store.duplicateTrip(
            withId: trip.id,
            includeTransportAndLodging: includeTransportAndLodging,
            includePackingList: includePackingList
        ) else {
            dismiss()
            return
        }
        if let newBundle = store.bundle(for: newId) {
            let info = TripInfo(
                name: name.trimmingCharacters(in: .whitespaces),
                destinationCity: newBundle.destinationCity,
                departureDate: departureDate,
                returnDate: returnDate,
                isDateless: isDateless
            )
            store.updateTripInfo(tripId: newId, info: info)
        }
        onCompleted(newId)
    }
}

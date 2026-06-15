//
//  LodgingEditView.swift
//  Carry
//
//  住宿（跨度）的新增 / 编辑表单。spec: itinerary-transport-lodging.md。
//  名称 / 地址（可地理搜索取坐标）+ 入住日 + 住几晚 + 入住/退房时间 + 确认号 / 备注。
//  归 TripBundle（不绑单天），用 day sortOrder 锚定，兼容有/无日期行程。
//
//  字体：系统 Form（SF 默认），符合 design-system「表单输入 / 系统控件 = SF」。
//

import SwiftUI

struct LodgingEditView: View {
    let tripId: UUID
    /// 非 nil = 编辑现有住宿；nil = 新增。
    var stayId: UUID? = nil
    /// 新增时的默认入住日（统一「+」入口按当前天传入）。
    var initialCheckInDayOrder: Int = 0

    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var address = ""
    @State private var latitude: Double = 0
    @State private var longitude: Double = 0
    @State private var checkInDayOrder = 0
    @State private var nights = 1
    @State private var hasCheckInTime = false
    @State private var checkInTime = Date()
    @State private var hasCheckOutTime = false
    @State private var checkOutTime = Date()
    @State private var confirmationCode = ""
    @State private var note = ""
    @State private var costAmountText = ""
    @State private var costCurrencyCode = ""

    @State private var didLoad = false
    @State private var searching = false

    private var isEditing: Bool { stayId != nil }
    private var bundle: TripBundle? { store.bundle(for: tripId) }
    private var days: [ItineraryDay] { bundle?.safeItineraryDays ?? [] }
    /// 住宿可跨到的最大晚数：行程总天数（够松，不会卡住正常用法）。
    private var maxNights: Int { max(1, bundle?.spanDays ?? 1) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        searching = true
                    } label: {
                        HStack {
                            Image(systemName: "bed.double")
                                .foregroundStyle(.secondary)
                            (name.isEmpty ? Text("itinerary.lodging.field.name") : Text(name))
                                .foregroundStyle(name.isEmpty ? .secondary : .primary)
                            Spacer()
                            Image(systemName: "magnifyingglass")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    TextField("itinerary.lodging.field.address", text: $address, axis: .vertical)
                        .lineLimit(1...3)
                }

                Section {
                    if days.count > 1 {
                        Picker(selection: $checkInDayOrder) {
                            ForEach(days, id: \.sortOrder) { day in
                                Text(dayLabel(day.sortOrder)).tag(day.sortOrder)
                            }
                        } label: {
                            Text("itinerary.lodging.field.checkin_day")
                        }
                    }
                    Stepper(value: $nights, in: 1...maxNights) {
                        HStack {
                            Text("itinerary.lodging.field.nights")
                            Spacer()
                            Text(String(format: NSLocalizedString("itinerary.lodging.nights_value", comment: ""), nights))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("itinerary.lodging.field.checkin_time", isOn: $hasCheckInTime.animation())
                    if hasCheckInTime {
                        DatePicker("itinerary.lodging.field.checkin_time", selection: $checkInTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Toggle("itinerary.lodging.field.checkout_time", isOn: $hasCheckOutTime.animation())
                    if hasCheckOutTime {
                        DatePicker("itinerary.lodging.field.checkout_time", selection: $checkOutTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } header: {
                    Text("itinerary.lodging.section.stay")
                }

                Section {
                    CostInputRow(amountText: $costAmountText, currencyCode: $costCurrencyCode)
                    TextField("itinerary.transport.field.confirmation", text: $confirmationCode)
                        .autocorrectionDisabled()
                    TextField("itinerary.transport.field.note", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                } header: {
                    Text("itinerary.transport.section.more")
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            deleteAndDismiss()
                        } label: {
                            Text("itinerary.lodging.delete")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                }
            }
            .navigationTitle(Text(isEditing ? "itinerary.lodging.edit.title" : "itinerary.lodging.add.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveAndDismiss() }
                        .fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $searching) {
                ItineraryPlaceSearchSheet(
                    titleKey: "itinerary.lodging.field.name",
                    placeholderKey: "itinerary.lodging.search.placeholder",
                    biasLatitude: bundle?.latitude ?? 0,
                    biasLongitude: bundle?.longitude ?? 0
                ) { pickedName, lat, lon, pickedAddress in
                    name = pickedName
                    latitude = lat
                    longitude = lon
                    if address.isEmpty { address = pickedAddress }
                }
            }
            .onAppear(perform: loadIfNeeded)
        }
    }

    // MARK: Helpers

    private func dayLabel(_ order: Int) -> String {
        if let bundle, !bundle.isDateless {
            let base = Calendar.current.startOfDay(for: bundle.departureDate)
            let date = Calendar.current.date(byAdding: .day, value: order, to: base) ?? base
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return String(format: NSLocalizedString("itinerary.day.title", comment: ""), order + 1)
    }

    private func minutes(from date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func dateFromMinutes(_ m: Int) -> Date {
        let start = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .minute, value: max(0, m), to: start) ?? start
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        if let stayId, let stay = (bundle?.lodgingStays ?? []).first(where: { $0.id == stayId }) {
            name = stay.name; address = stay.address
            latitude = stay.latitude; longitude = stay.longitude
            checkInDayOrder = stay.checkInDayOrder
            nights = max(1, stay.nights)
            if stay.checkInMinutes >= 0 { hasCheckInTime = true; checkInTime = dateFromMinutes(stay.checkInMinutes) }
            if stay.checkOutMinutes >= 0 { hasCheckOutTime = true; checkOutTime = dateFromMinutes(stay.checkOutMinutes) }
            confirmationCode = stay.confirmationCode; note = stay.note
            if stay.hasCost { costAmountText = CurrencyCatalog.amountText(stay.costAmount); costCurrencyCode = stay.costCurrencyCode }
        } else {
            checkInDayOrder = initialCheckInDayOrder
        }
    }

    private var costAmountValue: Double {
        CurrencyCatalog.parseAmount(costAmountText)
    }

    private var costCurrencyToSave: String {
        costAmountText.trimmingCharacters(in: .whitespaces).isEmpty
            ? ""
            : (costCurrencyCode.isEmpty ? CurrencyCatalog.homeCurrencyCode : costCurrencyCode.uppercased())
    }

    private func saveAndDismiss() {
        let inMinutes = hasCheckInTime ? minutes(from: checkInTime) : -1
        let outMinutes = hasCheckOutTime ? minutes(from: checkOutTime) : -1
        if let stayId {
            store.updateLodgingStay(
                tripId: tripId, stayId: stayId,
                name: name, address: address,
                latitude: latitude, longitude: longitude,
                checkInDayOrder: checkInDayOrder, nights: nights,
                checkInMinutes: inMinutes, checkOutMinutes: outMinutes,
                confirmationCode: confirmationCode, note: note
            )
            store.setLodgingCost(tripId: tripId, stayId: stayId,
                                 amount: costAmountValue, currencyCode: costCurrencyToSave)
        } else {
            if let newId = store.addLodgingStay(
                tripId: tripId,
                name: name, address: address,
                latitude: latitude, longitude: longitude,
                checkInDayOrder: checkInDayOrder, nights: nights,
                checkInMinutes: inMinutes, checkOutMinutes: outMinutes,
                confirmationCode: confirmationCode, note: note
            ) {
                store.setLodgingCost(tripId: tripId, stayId: newId,
                                     amount: costAmountValue, currencyCode: costCurrencyToSave)
            }
        }
        dismiss()
    }

    private func deleteAndDismiss() {
        guard let stayId else { return }
        store.removeLodgingStay(tripId: tripId, stayId: stayId)
        dismiss()
    }
}

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
    @State private var checkInTime = LodgingEditView.noonToday
    @State private var hasCheckOutTime = false
    @State private var checkOutTime = LodgingEditView.noonToday
    @State private var confirmationCode = ""
    @State private var note = ""
    @State private var phone = ""
    @State private var costAmountText = ""
    @State private var costCurrencyCode = ""

    @State private var didLoad = false
    @State private var searching = false
    @State private var attachmentRequest: AttachmentAddRequest?
    @State private var pendingAttachments: [PendingAttachment] = []   // 新建住宿：保存后再 flush 入库
    @State private var timeSheet: LodgingTimeField?   // 入住/退房时间弹层（chip+弹出，统一交通范式）

    private enum LodgingTimeField: Identifiable { case checkIn, checkOut; var id: Int { hashValue } }

    private var isEditing: Bool { stayId != nil }
    /// 正在编辑的住宿（附件挂载用，需已持久化）；新增态为 nil。
    private var editingStay: LodgingStay? {
        guard let stayId else { return nil }
        return (bundle?.lodgingStays ?? []).first { $0.id == stayId }
    }
    private var bundle: TripBundle? { store.bundle(for: tripId) }
    private var days: [ItineraryDay] { bundle?.safeItineraryDays ?? [] }
    private var lastDayOrder: Int { days.last?.sortOrder ?? 0 }

    /// 退房日 ↔ nights 的桥接：录入选「退房日」（更符合心智、退房恒在行程内），内部仍存 nights。
    /// spec: itinerary-transport-lodging.md（增补：两日期录入）。
    private var checkOutDayBinding: Binding<Int> {
        Binding(
            get: { min(checkInDayOrder + nights, lastDayOrder) },
            set: { nights = max(1, $0 - checkInDayOrder) }
        )
    }

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
                        // 入住日：排除最后一天（最后一天无法开始过夜）。
                        Picker(selection: $checkInDayOrder) {
                            ForEach(days.dropLast(), id: \.sortOrder) { day in
                                Text(dayLabel(day.sortOrder)).tag(day.sortOrder)
                            }
                        } label: {
                            Text("itinerary.lodging.field.checkin_day")
                        }
                        // 退房日：只列入住日之后的天 → 退房恒在行程内、「退房」事件必然可渲染。
                        // nights 由「退房日 − 入住日」派生（checkOutDayBinding）。
                        Picker(selection: checkOutDayBinding) {
                            ForEach(days.filter { $0.sortOrder > checkInDayOrder }, id: \.sortOrder) { day in
                                Text(dayLabel(day.sortOrder)).tag(day.sortOrder)
                            }
                        } label: {
                            Text("itinerary.lodging.field.checkout_day")
                        }
                        // 由「入住日/退房日」派生的晚数（只读行，跟在两日期下方做确认）。
                        LabeledContent {
                            Text(String(format: NSLocalizedString("itinerary.lodging.nights_value", comment: ""), nights))
                                .foregroundStyle(.secondary)
                        } label: {
                            Text("itinerary.lodging.field.nights")
                        }
                    }
                    // 入住/退房时间：chip + 弹出（统一交通范式，去 toggle+内联）。未设显示「时间」占位。
                    timeChipRow("itinerary.lodging.field.checkin_time", has: hasCheckInTime, time: checkInTime) { timeSheet = .checkIn }
                    timeChipRow("itinerary.lodging.field.checkout_time", has: hasCheckOutTime, time: checkOutTime) { timeSheet = .checkOut }
                } header: {
                    Text("itinerary.lodging.section.stay")
                }

                Section {
                    TextField("itinerary.transport.field.confirmation", text: $confirmationCode)
                        .autocorrectionDisabled()
                    // 电话：搜酒店时可自动回填，也可手填（方便行程中联系）。
                    TextField("itinerary.transport.field.phone", text: $phone)
                        .keyboardType(.phonePad)
                } header: {
                    Text("itinerary.transport.section.more")
                }
                // 固定顺序：费用 → 备注 → 附件，各自独立 Section。
                Section {
                    CostInputRow(amountText: $costAmountText, currencyCode: $costCurrencyCode)
                }
                Section {
                    TextField("itinerary.transport.field.note", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                }

                // 附件：既有住宿直接入库；新建缓冲到 pending、保存后 flush。呈现挂到 Form（见 .attachmentAddFlow）。
                AttachmentEditSection(
                    owner: editingStay.map { .lodging($0.id) },
                    existing: editingStay?.attachments ?? [],
                    pending: $pendingAttachments,
                    tripId: tripId,
                    request: $attachmentRequest)

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
            .attachmentAddFlow(tripId: tripId, owner: editingStay.map { .lodging($0.id) },
                               pending: $pendingAttachments, request: $attachmentRequest)
            .navigationTitle(Text(isEditing ? "itinerary.lodging.edit.title" : "itinerary.lodging.add.title"))
            .navigationBarTitleDisplayMode(.inline)
            // 入住日改动时夹断 nights，保证退房日始终落在行程内（≥入住次日、≤末日）。
            .onChange(of: checkInDayOrder) { _, newVal in
                nights = max(1, min(nights, lastDayOrder - newVal))
            }
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
                ) { pickedName, lat, lon, pickedAddress, pickedPhone in
                    name = pickedName
                    latitude = lat
                    longitude = lon
                    if address.isEmpty { address = pickedAddress }
                    if phone.isEmpty { phone = pickedPhone }   // 自动回填，已填则不覆盖
                }
            }
            // 入住/退房时间弹层（chip+弹出，统一交通范式）；挂在 Form 稳定祖先上。
            .sheet(item: $timeSheet) { field in
                switch field {
                case .checkIn:
                    ItineraryTimePickerSheet(hasTime: $hasCheckInTime, time: $checkInTime)
                case .checkOut:
                    ItineraryTimePickerSheet(hasTime: $hasCheckOutTime, time: $checkOutTime)
                }
            }
            .onAppear(perform: loadIfNeeded)
        }
    }

    // MARK: Helpers

    /// 时间行：标签 + 时间 chip（点开弹出滚轮，可清除回未设）。统一交通的 chip+弹出范式，去 toggle+内联。
    @ViewBuilder
    private func timeChipRow(_ titleKey: LocalizedStringKey, has: Bool, time: Date, onTap: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(titleKey)
            Spacer()
            Button(action: onTap) {
                FormChip(text: has ? itineraryTimeString(time)
                                   : NSLocalizedString("itinerary.transport.field.time", comment: ""),
                         filled: has)
            }
            .buttonStyle(.plain)
        }
    }

    private func dayLabel(_ order: Int) -> String {
        if let bundle, !bundle.isDateless {
            let base = Calendar.current.startOfDay(for: bundle.departureDate)
            let date = Calendar.current.date(byAdding: .day, value: order, to: base) ?? base
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return String(format: NSLocalizedString("itinerary.day.title", comment: ""), order + 1)
    }

    /// 新建住宿时 check-in/out 时间的默认值 = 当天 12:00（多数酒店标准入住/退房在中午前后，
    /// 比「取当前时刻」更贴合常见情况）。只用其时钟时间（minutes(from:) 取 时:分），日期部分无意义。
    private static var noonToday: Date {
        let cal = Calendar.current
        return cal.date(byAdding: .hour, value: 12, to: cal.startOfDay(for: Date())) ?? Date()
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
            confirmationCode = stay.confirmationCode; note = stay.note; phone = stay.phone
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
                confirmationCode: confirmationCode, note: note, phone: phone
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
                confirmationCode: confirmationCode, note: note, phone: phone
            ) {
                store.setLodgingCost(tripId: tripId, stayId: newId,
                                     amount: costAmountValue, currencyCode: costCurrencyToSave)
                // 新建住宿：把缓冲的附件落到刚建好的住宿。
                for p in pendingAttachments {
                    _ = store.addAttachment(tripId: tripId, owner: .lodging(newId), kind: p.data.kind,
                                            displayName: p.data.displayName, fileName: p.data.fileName,
                                            utiOrExt: p.data.utiOrExt, urlString: p.data.urlString,
                                            thumbnailData: p.data.thumbnailData)
                }
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

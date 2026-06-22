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
    /// 是否自带 NavigationStack。独立呈现（编辑住宿）为 true；被 `LodgingSearchSheet` 的「手动添加」push 时为 false，
    /// 复用其导航栈，避免嵌套栈。
    var embedInOwnNavigationStack: Bool = true
    /// 保存/删除完成回调。被 push 时由 `LodgingSearchSheet` 传入以关闭整张搜索 sheet；nil（独立呈现）则退回 dismiss()。
    var onFinish: (() -> Void)? = nil
    /// 搜索预填（来自 `LodgingSearchSheet` 选中的酒店）：新建时把名称/地址/坐标/电话/时区带进表单，
    /// 用户只需补入住/退房日期——避免「选中即落 1 晚」的问题。nil = 手动添加（空表单）/编辑既有。
    var prefill: ResolvedPlace? = nil

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
    @State private var timeZoneId = ""   // 酒店所在地时区（地址搜索自动捕获）
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
        if embedInOwnNavigationStack {
            NavigationStack { formContent }
        } else {
            formContent
        }
    }

    private var formContent: some View {
            Form {
                // 名称/地址段：与「地点编辑」同款——名称可直接编辑（输自定义名 / 搜索回填都行）、地址只读展示、
                // 「Change location」重搜改地点。结构统一，且名称不再被 Form 默认蓝染（TextField 黑字、动作才蓝）。
                Section {
                    TextField(text: $name) { Text("itinerary.lodging.field.name") }
                    if (latitude != 0 || longitude != 0), !address.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "mappin.and.ellipse")
                                .foregroundStyle(.secondary)
                            Text(address)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        searching = true
                    } label: {
                        Label((latitude != 0 || longitude != 0) ? "itinerary.stop.edit.relocate"
                                                                 : "itinerary.stop.edit.set_location",
                              systemImage: "mappin.circle")
                    }
                } header: {
                    // 实体名作段标题（与地点编辑「Place/地点」同款处理：每个实体段以实体名分组）。复用类别文案，零新增本地化。
                    Text("itinerary.category.lodging")
                }

                Section {
                    // 入住 / 退房各一行：标签左 · 日期 chip + 时间 chip 右（统一租车 dateTimeChipsRow 范式）。
                    // 入住日排除最后一天；退房日只列入住日之后（退房恒在行程内）；nights 由两日期派生。
                    stayEndpointRow("itinerary.lodging.field.checkin_day",
                                    dayBinding: $checkInDayOrder,
                                    dayOptions: Array(days.dropLast()),
                                    has: hasCheckInTime, time: checkInTime) { timeSheet = .checkIn }
                    stayEndpointRow("itinerary.lodging.field.checkout_day",
                                    dayBinding: checkOutDayBinding,
                                    dayOptions: days.filter { $0.sortOrder > checkInDayOrder },
                                    has: hasCheckOutTime, time: checkOutTime) { timeSheet = .checkOut }
                    // 晚数（Nights）不在编辑态展示：派生值（退房−入住），编辑时正设这两个日期、回显是噪声；
                    // 详情里作辅助参考即可（与租车 Days 同处理）。内部 nights 仍由两日期派生、保存照常。
                } header: {
                    Text("itinerary.lodging.section.stay")
                }

                // Booking code 归「More」段——与航班/租车编辑一致（确认号都在 More），且它是订单凭据、与入住日期关系不大。
                // 标签左·值右 + ABC123 占位。电话不在编辑态露出（自动回填的辅助信息、详情只读）。
                Section {
                    LabeledContent {
                        TextField("itinerary.transport.field.confirmation.placeholder",
                                  text: $confirmationCode.filteringInput(ItineraryInputFilter.alphanumeric))
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    } label: {
                        Text("itinerary.transport.field.confirmation")
                    }
                } header: {
                    Text("itinerary.transport.section.more")
                }

                // 固定顺序：费用 → 备注 → 附件，各自独立 Section。
                Section {
                    CostInputRow(amountText: $costAmountText, currencyCode: $costCurrencyCode)
                }
                Section {
                    // 前导图标（详情 NoteDetailRow 同款 note.text）：与 Total cost / Attachments 统一。
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "note.text")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                            .padding(.top, 2)
                            .accessibilityHidden(true)
                        TextField("itinerary.transport.field.note", text: $note, axis: .vertical)
                            .lineLimit(1...4)
                    }
                }

                // 附件：既有住宿直接入库；新建缓冲到 pending、保存后 flush。呈现挂到 Form（见 .attachmentAddFlow）。
                AttachmentEditSection(
                    owner: editingStay.map { .lodging($0.id) },
                    existing: editingStay?.attachments ?? [],
                    pending: $pendingAttachments,
                    tripId: tripId,
                    request: $attachmentRequest)
                // 删除不在编辑态露出：详情弹层「···」菜单已有删除（干净，详情自身 dismiss）；编辑态放删除既冗余、
                // 又因详情/编辑叠层在编辑里删后露出悬空详情。
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
                // 被 push 时（embed=false）系统返回按钮已提供「返回搜索」，不再叠加 Cancel。
                if embedInOwnNavigationStack {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("common.cancel") { dismiss() }
                    }
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
                ) { pickedName, lat, lon, pickedAddress, pickedPhone, pickedTZ in
                    name = pickedName
                    latitude = lat
                    longitude = lon
                    address = pickedAddress   // 地址只读、由搜索权威回填（换地点即更新，不再保留手改值）
                    if phone.isEmpty { phone = pickedPhone }   // 自动回填，已填则不覆盖（电话仍捕获、详情展示）
                    if !pickedTZ.isEmpty { timeZoneId = pickedTZ }   // 换地址即更新时区（地址变了时区也该跟着变）
                }
            }
            // 入住/退房时间弹层（chip+弹出，统一交通范式）；挂在 Form 稳定祖先上。
            .sheet(item: $timeSheet) { field in
                // 入住/退房共用酒店所在地时区；多时区行程或自动推导失败时点亮兜底「时区」行。
                let showZone = (bundle?.isMultiTimeZone ?? false) || timeZoneId.isEmpty
                switch field {
                case .checkIn:
                    ItineraryTimePickerSheet(hasTime: $hasCheckInTime, time: $checkInTime,
                                             timeZoneId: $timeZoneId, showZone: showZone)
                case .checkOut:
                    ItineraryTimePickerSheet(hasTime: $hasCheckOutTime, time: $checkOutTime,
                                             timeZoneId: $timeZoneId, showZone: showZone)
                }
            }
            .onAppear(perform: loadIfNeeded)
    }

    // MARK: Helpers

    /// 住宿端点行（入住/退房）：标签 + 日期 chip（多天可点选换天）+ 时间 chip（点开弹出滚轮，可清除）。
    /// 统一租车 dateTimeChipsRow 范式：日期与时间同一行。`dayOptions` 为空（单天行程）时只显时间。
    @ViewBuilder
    private func stayEndpointRow(_ labelKey: LocalizedStringKey,
                                 dayBinding: Binding<Int>,
                                 dayOptions: [ItineraryDay],
                                 has: Bool, time: Date,
                                 onTapTime: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(labelKey)
            Spacer()
            if dayOptions.count > 1 {
                Menu {
                    Picker(selection: dayBinding) {
                        ForEach(dayOptions, id: \.sortOrder) { day in
                            Text(dayLabel(day.sortOrder)).tag(day.sortOrder)
                        }
                    } label: { EmptyView() }
                } label: {
                    FormChip(text: dayLabel(dayBinding.wrappedValue))
                }
            } else if dayOptions.count == 1 {
                FormChip(text: dayLabel(dayBinding.wrappedValue))
            }
            Button(action: onTapTime) {
                FormChip(text: has ? itineraryTimeString(time)
                                   : NSLocalizedString("itinerary.transport.field.time", comment: ""),
                         filled: has,
                         monospacedDigits: has)
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
            timeZoneId = stay.timeZoneId
            if stay.hasCost { costAmountText = CurrencyCatalog.amountText(stay.costAmount); costCurrencyCode = stay.costCurrencyCode }
        } else {
            checkInDayOrder = initialCheckInDayOrder
            // 新建住宿默认时刻（国际通用）：入住 15:00（多数酒店下午入住）、退房 12:00（中午）。用户可改。
            hasCheckInTime = true; checkInTime = dateFromMinutes(15 * 60)
            hasCheckOutTime = true; checkOutTime = dateFromMinutes(12 * 60)
            // 搜索预填：把选中酒店的名称/地址/坐标/电话/时区带进来；日期用上面默认，待用户补（多晚）。
            if let prefill {
                name = prefill.name
                address = prefill.address
                latitude = prefill.latitude
                longitude = prefill.longitude
                phone = prefill.phone
                timeZoneId = prefill.timeZoneId
            }
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
                confirmationCode: confirmationCode, note: note, phone: phone,
                timeZoneId: timeZoneId
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
                confirmationCode: confirmationCode, note: note, phone: phone,
                timeZoneId: timeZoneId
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
        finish()
    }

    /// 完成（保存/删除后）：被 push 时走 onFinish 关闭整张搜索 sheet；独立呈现退回 dismiss。
    private func finish() {
        if let onFinish { onFinish() } else { dismiss() }
    }
}

// MARK: - LodgingSearchSheet

/// 住宿「搜索优先」添加流（spec: itinerary-transport-lodging.md）：与「添加地点」/「航班搜索」同款——
/// 点「+」住宿先进搜索；搜到选中 → 解析坐标 → **push 进预填表单**（名称/地址带入，用户补入住/退房日期、可多晚）；
/// 底部常驻「搜不到酒店？手动添加」push 进空表单（复用本栈、不叠 sheet）。
struct LodgingSearchSheet: View {
    let tripId: UUID
    let initialCheckInDayOrder: Int

    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var completer = StopSearchCompleter()
    @State private var isResolving = false
    @State private var route: Route?
    @State private var resolvedPlace: ResolvedPlace?   // 选中并解析后的酒店，供预填表单读取（同航班 result 范式）
    @FocusState private var searchFocused: Bool

    private enum Route: Hashable { case prefilled, manual }

    private var bundle: TripBundle? { store.bundle(for: tripId) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(completer.results) { result in
                        Button {
                            resolveAndProceed(result)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title)
                                    .foregroundStyle(.primary)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    if !completer.results.isEmpty { Text("itinerary.add_stop.results") }
                }
            }
            .listStyle(.insetGrouped)
            // 与 AddStopView 同：显式铺 grouped 底，消除 band 与列表区的接缝。
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .safeAreaInset(edge: .top) { searchField }
            .safeAreaInset(edge: .bottom) { manualFooter }
            .disabled(isResolving)
            .overlay { if isResolving { ProgressView() } }
            .navigationTitle(Text("itinerary.lodging.add.title"))   // 「Add lodging / 添加住宿」（与添加地点的搜索窗口平行）
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
            // 选中结果 → 预填表单（用户补日期）；手动添加 → 空表单。都 push（复用本搜索栈，不叠 sheet），
            // 保存/取消后关闭整张搜索 sheet。
            .navigationDestination(item: $route) { route in
                switch route {
                case .prefilled:
                    LodgingEditView(tripId: tripId, initialCheckInDayOrder: initialCheckInDayOrder,
                                    embedInOwnNavigationStack: false, onFinish: { dismiss() },
                                    prefill: resolvedPlace)
                case .manual:
                    LodgingEditView(tripId: tripId, initialCheckInDayOrder: initialCheckInDayOrder,
                                    embedInOwnNavigationStack: false, onFinish: { dismiss() })
                }
            }
            .onAppear {
                completer.biasRegion(toLatitude: bundle?.latitude ?? 0, longitude: bundle?.longitude ?? 0)
                // 聚焦推迟到下一帧（在 sheet 呈现更新周期内同步设 @FocusState 会触发 AttributeGraph 崩溃）。
                DispatchQueue.main.async { searchFocused = true }
            }
            .onDisappear { completer.tearDown() }   // 取消在途海外请求 + 停 MapKit 补全
        }
    }

    /// 常驻搜索框（统一 CarrySearchField，.grouped 表面），固定在导航栏下方。
    private var searchField: some View {
        CarrySearchField(
            text: $completer.query,
            placeholder: "itinerary.lodging.search.placeholder",
            focus: $searchFocused
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color(.systemGroupedBackground))
    }

    /// 底部常驻·低权重手动兜底（搜不到的民宿/小店）：弱提示 secondary + 强调动作 accent，安静的逃生口。
    private var manualFooter: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                searchFocused = false
                route = .manual
            } label: {
                HStack(spacing: 5) {
                    Text("itinerary.lodging.search.manual_hint")
                        .foregroundStyle(.secondary)
                    Text("itinerary.lodging.search.manual")
                        .foregroundStyle(CarryAccent.color)
                }
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
        }
        .background(Color(.systemGroupedBackground))
    }

    /// 选中结果 → 解析坐标 → 带数据 push 进**预填表单**（用户补入住/退房日期，支持多晚）。
    /// 解析失败也带名字进表单（无坐标），不让点击石沉大海。
    private func resolveAndProceed(_ suggestion: PlaceSuggestion) {
        isResolving = true
        Task {
            let r = await completer.resolve(suggestion)   // 国内走 MapKit、海外走 Worker
            isResolving = false
            resolvedPlace = r ?? ResolvedPlace(name: suggestion.title, latitude: 0, longitude: 0,
                                               address: "", phone: "", timeZoneId: "")
            searchFocused = false
            route = .prefilled
        }
    }
}

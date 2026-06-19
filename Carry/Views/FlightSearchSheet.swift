//
//  FlightSearchSheet.swift
//  Carry
//
//  添加航班的第 1 段：搜索优先 + 渐进披露（对标 Flighty / Tripsy 的「单框 → 识别 → 挑日期 → 出结果」）。
//  输航班号 → 即时识别航司 → 展开「本行程的天」日期快捷 chip（比通用今天/明天更贴场景）→ 回车或点天即查
//  → 结果确认卡 → 点卡 push 进预填的 TransportEditView；查不到（如春秋 9C）走底部常驻「手动输入」进空表单。
//  spec: itinerary-flight-search-first.md。
//
//  字体：航班号 / 日期短标签等「展示型数字/短标签」用圆体（design-system §Typography）。
//

import SwiftUI

struct FlightSearchSheet: View {
    let tripId: UUID
    let dayId: UUID

    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss

    @State private var number = ""
    @State private var date = Date()
    @State private var recognized: Airline?      // 即时识别的航司（按航班号前缀）
    @State private var status: Status = .idle
    @State private var result: FlightLookupResult?
    @State private var routeFrom = ""            // 结果卡的出发城市（异步从机场库解析）
    @State private var routeTo = ""
    @State private var route: Route?             // 当前 push 的目的地

    @FocusState private var numberFocused: Bool

    private enum Status: Equatable { case idle, loading, found, notFound, failed }
    private enum Route: Hashable { case prefilled, manual }

    private var bundle: TripBundle? { store.bundle(for: tripId) }
    private var trimmedNumber: String { number.trimmingCharacters(in: .whitespaces) }
    private var parsedFlight: (airline: String, number: String)? { FlightNumberParser.split(trimmedNumber) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    numberCard
                    if parsedFlight != nil {
                        dateSection
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    statusArea
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .animation(.spring(duration: 0.3, bounce: 0.2), value: parsedFlight?.airline)
                .animation(.spring(duration: 0.3, bounce: 0.2), value: status)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("flight.search.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { manualFooter }
            .navigationDestination(item: $route) { route in
                switch route {
                case .prefilled:
                    TransportEditView(tripId: tripId, dayId: dayId, initialMode: .flight,
                                      prefill: result, embedInOwnNavigationStack: false,
                                      onFinish: { dismiss() })
                case .manual:
                    TransportEditView(tripId: tripId, dayId: dayId, initialMode: .flight,
                                      embedInOwnNavigationStack: false, onFinish: { dismiss() })
                }
            }
            .onAppear(perform: setup)
            .onChange(of: number) { _, _ in numberChanged() }
        }
    }

    // MARK: 航班号卡（聚焦单框 + 即时航司识别）

    private var numberCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 字体：表单输入 + placeholder 走 SF（design-system §Typography「表单与输入=SF」），
            // 不用圆体——圆体留给展示型标题/数字短标签；输入框文字属功能声音。title3 给 hero 输入适度醒目。
            TextField("flight.search.placeholder", text: $number)
                .font(.title3)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .focused($numberFocused)
                .submitLabel(.done)
                // 触发 = 选日期（Flighty 模型），不在回车里偷偷用默认日期查；回车只收键盘、让日期列表完整露出。
                .onSubmit { numberFocused = false }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            if let recognized {
                Divider().padding(.leading, 16)
                Label {
                    Text(recognized.displayName)
                } icon: {
                    Image(systemName: "airplane")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: 日期（Flighty 模型：选日期这个动作 = 触发查询；不预填、不要按钮）

    @State private var showCalendar = false

    private struct DateOption: Identifiable { let label: String; let date: Date; var id: TimeInterval { date.timeIntervalSince1970 } }

    /// 日期选项：有日期行程 = 本行程的天（比通用今天/明天更贴）；无日期行程 = 今天/明天。
    /// 超长行程（>31 天）不铺几十行，只留「选择其他日期」日历。
    private var dateOptions: [DateOption] {
        let cal = Calendar.current
        if let bundle, !bundle.isDateless {
            let span = max(1, bundle.spanDays)
            guard span <= 31 else { return [] }
            let base = cal.startOfDay(for: bundle.departureDate)
            return (0..<span).compactMap { i in
                guard let d = cal.date(byAdding: .day, value: i, to: base) else { return nil }
                return DateOption(label: d.formatted(.dateTime.month(.abbreviated).day().weekday(.wide)), date: d)
            }
        }
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today) ?? today
        return [
            DateOption(label: NSLocalizedString("flight.search.today", comment: ""), date: today),
            DateOption(label: NSLocalizedString("flight.search.tomorrow", comment: ""), date: tomorrow),
        ]
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("flight.search.pick_date")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(dateOptions.enumerated()), id: \.element.id) { idx, opt in
                    if idx > 0 { Divider().padding(.leading, 16) }
                    dateRow(label: opt.label, date: opt.date)
                }
                if !dateOptions.isEmpty { Divider().padding(.leading, 16) }
                otherDateRow
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .sheet(isPresented: $showCalendar) { calendarSheet }
    }

    private func dateRow(label: String, date optDate: Date) -> some View {
        Button {
            date = optDate
            runQuery()
        } label: {
            HStack {
                Text(label).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var otherDateRow: some View {
        Button { showCalendar = true } label: {
            HStack {
                Label("flight.search.other_date", systemImage: "calendar")
                    .foregroundStyle(CarryAccent.color)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var calendarSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 点某天即提交：设日期→关历→查询（与「行程天」行的点选即触发一致，不要 Done）。
                // `.fixedSize(vertical)` 钉本征高度 + 单档 detent → 选日期/翻月都不重排跳动。
                DatePicker("flight.search.date", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(CarryAccent.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
                    .onChange(of: date) { showCalendar = false; runQuery() }
                Spacer(minLength: 0)
            }
            .navigationTitle("flight.search.pick_date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { showCalendar = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: 状态区（加载 / 结果卡 / 提示）

    @ViewBuilder
    private var statusArea: some View {
        switch status {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("flight.search.searching").foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
        case .found:
            if let result { resultCard(result) }
        case .notFound, .failed:
            Text(status == .notFound ? "flight.search.notfound" : "flight.search.failed")
                .font(.footnote)
                .foregroundStyle(Color(.systemOrange))
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 结果确认卡：航司 + 航线 + 起降时刻，点击 push 进预填表单。让用户先核对「是不是这班」。
    private func resultCard(_ r: FlightLookupResult) -> some View {
        Button {
            numberFocused = false
            route = .prefilled
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(r.airlineName.isEmpty ? (recognized?.displayName ?? "") : r.airlineName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(r.flightNumber)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 10) {
                    endpointView(code: r.from.iata, time: r.from.scheduledLocal,
                                 tz: r.from.timeZoneId, city: routeFrom)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 3)
                    endpointView(code: r.to.iata, time: r.to.scheduledLocal,
                                 tz: r.to.timeZoneId, city: routeTo)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 3)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    /// 单端：IATA（圆体）+ 当地时刻 + 城市名。
    private func endpointView(code: String, time: Date?, tz: String, city: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(code)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.primary)
                if let t = localTimeString(time, tzId: tz) {
                    Text(t)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(CarryAccent.color)
                }
            }
            if !city.isEmpty {
                Text(city)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 底部常驻·低权重手动兜底（春秋 9C 等查不到的航班）

    private var manualFooter: some View {
        // 克制版：细分隔线 + 同底色（不铺 .bar 磨砂板，对一个轻链接过重）；
        // 两段式文案居中成一句（弱化提示 secondary + 强调动作 accent）——安静的逃生口，非工具栏。
        VStack(spacing: 0) {
            Divider()
            Button {
                CarryLogger.shared.log(.flightSearchManualFallback,
                                       context: status == .notFound ? "after_notfound" : "direct")
                numberFocused = false
                route = .manual
            } label: {
                HStack(spacing: 5) {
                    Text("flight.search.manual_hint")
                        .foregroundStyle(.secondary)
                    Text("flight.search.manual")
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

    // MARK: Logic

    private func setup() {
        // 默认日期 = 出发日对应真实日期（有日期行程）；无日期行程用今天。
        if let bundle, !bundle.isDateless {
            let order = bundle.safeItineraryDays.first(where: { $0.id == dayId })?.sortOrder ?? 0
            let base = Calendar.current.startOfDay(for: bundle.departureDate)
            date = Calendar.current.date(byAdding: .day, value: order, to: base) ?? base
        }
        DispatchQueue.main.async { numberFocused = true }
    }

    /// 航班号变化：重置上次结果 + 即时识别航司。
    private func numberChanged() {
        if status != .idle { status = .idle; result = nil }
        guard let parts = parsedFlight else { recognized = nil; return }
        let code = parts.airline
        Task {
            let a = await AirlineDatabase.shared.airline(forIATA: code)
            await MainActor.run { if parsedFlight?.airline == code { recognized = a } }
        }
    }

    private func runQuery() {
        guard parsedFlight != nil else { return }
        numberFocused = false
        let num = trimmedNumber
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        let dateStr = f.string(from: date)
        status = .loading
        result = nil
        CarryLogger.shared.log(.flightLookupStarted)
        Task {
            do {
                let r = try await FlightLookupService.lookup(number: num, dateString: dateStr)
                await resolveCities(r)
                await MainActor.run {
                    result = r
                    status = .found
                    CarryLogger.shared.log(.flightLookupResolved,
                                           context: "from=\(r.from.hasAirport) to=\(r.to.hasAirport)")
                }
            } catch FlightLookupError.notFound {
                await MainActor.run { status = .notFound; CarryLogger.shared.log(.flightLookupNotFound) }
            } catch {
                await MainActor.run { status = .failed; CarryLogger.shared.log(.flightLookupFailed) }
            }
        }
    }

    /// 结果卡城市名：用 IATA 从机场库解析（接口只给机场名，城市更易读）。失败留空，不阻断。
    private func resolveCities(_ r: FlightLookupResult) async {
        let from = r.from.iata, to = r.to.iata
        let fc = from.isEmpty ? nil : await AirportDatabase.shared.search(from).first(where: { $0.iata == from })
        let tc = to.isEmpty ? nil : await AirportDatabase.shared.search(to).first(where: { $0.iata == to })
        await MainActor.run {
            routeFrom = fc?.city ?? ""
            routeTo = tc?.city ?? ""
        }
    }

    private func localTimeString(_ date: Date?, tzId: String) -> String? {
        guard let date else { return nil }
        let f = DateFormatter()
        f.locale = .current
        f.timeZone = TimeZone(identifier: tzId) ?? .current
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

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

    /// 手动兜底预填：查不到航班时，把用户已输入的航班号 + 即时识别到的航司带进手动表单
    /// （别让用户在手动页从头重打）；其余字段留空给用户补。
    private var manualPrefill: FlightLookupResult {
        FlightLookupResult(airlineName: recognized?.displayName ?? "",
                           flightNumber: trimmedNumber.uppercased())
    }

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
                                      prefill: manualPrefill, embedInOwnNavigationStack: false,
                                      onFinish: { dismiss() })
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
            // 强制大写：航班号习惯全大写；自动大写键盘可能被绕过（如小写输入法），故 binding 兜底转大写。
            TextField("flight.search.placeholder", text: Binding(
                get: { number },
                // 只保留字母+数字（航班号字符集），其余（空格/符号/中文/emoji）即时过滤掉；并强制大写。
                set: { number = String($0.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }).uppercased() }
            ))
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

    private struct DateOption: Identifiable { let label: String; let date: Date; let isAddDay: Bool; var id: TimeInterval { date.timeIntervalSince1970 } }

    /// 加航班所在的那天（点「+」的天）= 建议当天，色卡点亮强调色。无日期行程则 nil。
    private var addDayDate: Date? {
        guard let bundle, !bundle.isDateless else { return nil }
        let order = bundle.safeItineraryDays.first(where: { $0.id == dayId })?.sortOrder ?? 0
        let base = Calendar.current.startOfDay(for: bundle.departureDate)
        return Calendar.current.date(byAdding: .day, value: order, to: base)
    }

    /// 日期选项：有日期行程 = 本行程的天（比通用今天/明天更贴）；无日期行程 = 今天/明天。
    /// 超长行程（>31 天）不铺几十行，只留「选择其他日期」日历。label = 星期全称（月/日由色卡承载）。
    private var dateOptions: [DateOption] {
        let cal = Calendar.current
        if let bundle, !bundle.isDateless {
            let span = max(1, bundle.spanDays)
            guard span <= 31 else { return [] }
            let base = cal.startOfDay(for: bundle.departureDate)
            let add = addDayDate
            return (0..<span).compactMap { i in
                guard let d = cal.date(byAdding: .day, value: i, to: base) else { return nil }
                let isAdd = add.map { cal.isDate(d, inSameDayAs: $0) } ?? false
                return DateOption(label: d.formatted(.dateTime.weekday(.wide)), date: d, isAddDay: isAdd)
            }
        }
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today) ?? today
        return [
            DateOption(label: NSLocalizedString("flight.search.today", comment: ""), date: today, isAddDay: false),
            DateOption(label: NSLocalizedString("flight.search.tomorrow", comment: ""), date: tomorrow, isAddDay: false),
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
                    if idx > 0 { Divider().padding(.leading, 68) }
                    dateRow(opt)
                }
                if !dateOptions.isEmpty { Divider().padding(.leading, 68) }
                otherDateRow
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .sheet(isPresented: $showCalendar) { calendarSheet }
    }

    /// 行 = 日期色卡（视觉锚点）+ 星期；点即查询，无 chevron（点选是「提交」、非「导航」）。
    private func dateRow(_ opt: DateOption) -> some View {
        Button {
            date = opt.date
            runQuery()
        } label: {
            HStack(spacing: 12) {
                dateBadge(opt.date, suggested: opt.isAddDay)
                Text(opt.label).foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 日期小色卡：月缩写 + 日号（圆体数字）。纯黑白灰——建议当天（加航班那天）只用「更亮一档的灰底」
    /// 做极轻提示，不引入强调色（避免整块颜色杂）。
    private func dateBadge(_ d: Date, suggested: Bool) -> some View {
        VStack(spacing: 0) {
            Text(d.formatted(.dateTime.month(.abbreviated)))
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(d.formatted(.dateTime.day()))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)   // 大字号/窄机型下 2 位日号缩放适配，避免被 clipShape 裁成 1 位
        }
        .frame(width: 42, height: 42)
        .background(suggested ? Color(.systemFill) : Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var otherDateRow: some View {
        Button { showCalendar = true } label: {
            HStack(spacing: 12) {
                // 与日期色卡同款 42×42 色卡（放日历图标）→ 和上面三行同一视觉语言，不再是孤立细图标。
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                    Image(systemName: "calendar")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 42, height: 42)
                Text("flight.search.other_date")
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // 系统 graphical 日历（用户取舍：接受首次出现的 ~3px 微落定，换取系统原生观感）。
    // 点某天即提交（设日期→关历→查询），与「行程天」行一致。固定高度把落定压到最小。
    private var calendarSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DatePicker("flight.search.date", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(CarryAccent.color)
                    .frame(height: 360)
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

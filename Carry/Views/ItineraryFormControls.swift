//
//  ItineraryFormControls.swift
//  Carry
//
//  行程编辑表单共用的「日期/时间」交互组件（spec: itinerary-transport-lodging.md / carry-form-datetime-chip-pattern）。
//  统一范式：**chip + 弹出滚轮**（非 toggle+内联，避免行高跳变；选择即生效、可清除回未设）。
//  交通 / 地点 / 住宿三处编辑共用，保证交互一致。
//

import SwiftUI

/// 表单 chip：圆体短标签 + 胶囊底。filled=false（占位/未设）用次要色。
/// monospacedDigits：时刻 chip 用等宽数字，与详情页时间列对齐（读写一致）。
struct FormChip: View {
    let text: String
    var filled: Bool = true
    var monospacedDigits: Bool = false

    var body: some View {
        Text(text)
            .font(.system(.subheadline, design: .rounded).weight(.medium))
            .monospacedDigit(monospacedDigits)
            .foregroundStyle(filled ? Color.primary : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(.tertiarySystemFill))
            .clipShape(Capsule())
    }
}

private extension Text {
    /// 条件性等宽数字（true 才套 .monospacedDigit）。
    @ViewBuilder func monospacedDigit(_ on: Bool) -> some View {
        if on { self.monospacedDigit() } else { self }
    }
}

/// 机型显示：去掉厂商品牌前缀，只留型号（"Airbus A330-200" → "A330-200"、"Boeing 737-800" → "737-800"）。
/// 多数 App 只显型号、不显厂商。仅剥**会冗余**的品牌词；ATR 等「品牌即型号一部分」的不剥（"ATR 72-600" 原样）。
/// 非破坏：仅展示层过滤，存储仍保留接口原值。
func aircraftModelDisplay(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    // 注意顺序：双词品牌（McDonnell Douglas）在前，避免被单词前缀误截。
    let brandPrefixes = ["McDonnell Douglas ", "Airbus ", "Boeing ", "Embraer ", "Bombardier ", "COMAC ", "Comac "]
    for p in brandPrefixes where trimmed.lowercased().hasPrefix(p.lowercased()) {
        return String(trimmed.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
    }
    return trimmed
}

/// 时间「HH:mm」（跟随设备 locale）。
func itineraryTimeString(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = .current
    f.dateFormat = "HH:mm"
    return f.string(from: date)
}

/// 共用时间选择器弹层：滚轮选时分；「完成」提交、「取消」回退、编辑既有时可「清除时间」回到未设。
/// 自管 dismiss——调用方用 `.sheet(item:)` 在**稳定祖先（Form / NavigationStack）**上呈现（勿挂列表行）。
///
/// 内部用本地草稿 `draft`：滚轮只改草稿、「完成」才写回调用方状态 → 「取消 / 下滑关闭」都能干净回退，
/// 不会出现「滚一下就实时改了入住/退房时间、关掉也回不去」的问题。
struct ItineraryTimePickerSheet: View {
    @Binding var hasTime: Bool
    @Binding var time: Date

    /// 可选：该活动端点的 IANA 时区（""=自动按地点推导）。传入且 `showZone` 时，弹层底部出现安静的
    /// 「时区」兜底行——只在多时区行程 / 自动推导失败时由调用方点亮（spec: itinerary-timezone.md Phase 3）。
    private let zoneBinding: Binding<String>?
    private let showZone: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var draft: Date
    @State private var showZonePicker = false
    private let wasSet: Bool

    init(hasTime: Binding<Bool>, time: Binding<Date>,
         timeZoneId: Binding<String>? = nil, showZone: Bool = false) {
        _hasTime = hasTime
        _time = time
        zoneBinding = timeZoneId
        self.showZone = showZone
        _draft = State(initialValue: time.wrappedValue)
        wasSet = hasTime.wrappedValue
    }

    private var zoneRowVisible: Bool { showZone && zoneBinding != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DatePicker("itinerary.transport.field.time", selection: $draft, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .padding(.top, 8)
                if wasSet {
                    Button(role: .destructive) {
                        hasTime = false
                        dismiss()
                    } label: {
                        Text("itinerary.transport.field.clear_time").frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 8)
                }
                if zoneRowVisible, let zone = zoneBinding {
                    Divider().padding(.horizontal, 16)
                    Button { showZonePicker = true } label: {
                        HStack(spacing: 8) {
                            Text("itinerary.timezone.field")
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            Text(TimeZoneDisplay.label(zone.wrappedValue))
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.system(.subheadline))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .navigationTitle("itinerary.transport.field.time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }   // 不写回 draft → 自动回退
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") {
                        time = draft       // 仅此刻提交
                        hasTime = true
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showZonePicker) {
                if let zone = zoneBinding { TimeZonePickerSheet(timeZoneId: zone) }
            }
        }
        .presentationDetents([.height(zoneRowVisible ? 430 : 360)])
    }
}

// MARK: - 时区显示 / 选择（spec: itinerary-timezone.md Phase 3）

/// IANA 时区的友好显示。
enum TimeZoneDisplay {
    /// 城市名（IANA 末段、下划线转空格），如 "Europe/Paris" → "Paris"；空 → 本地化「自动」。
    static func city(_ id: String) -> String {
        guard !id.isEmpty else { return NSLocalizedString("itinerary.timezone.auto", comment: "") }
        let last = id.split(separator: "/").last.map(String.init) ?? id
        return last.replacingOccurrences(of: "_", with: " ")
    }

    /// "GMT+8" / "GMT−3:30"（默认按「当前」算偏移）。仅用于时区**选择器/选择行**这类通用 UI——
    /// 不绑某个具体事件日期，故用「当前」即可；按事件日期算偏移（夏令时）的是详情卡，见
    /// `TransportDetailView.gmtZoneLabel(_:on:)` 与 `ItineraryView.dayZoneLabel`。
    static func gmt(_ id: String, now: Date = Date()) -> String? {
        guard !id.isEmpty, let tz = TimeZone(identifier: id) else { return nil }
        let secs = tz.secondsFromGMT(for: now)
        let sign = secs < 0 ? "−" : "+"
        let mins = abs(secs) / 60, h = mins / 60, m = mins % 60
        return m == 0 ? "GMT\(sign)\(h)" : String(format: "GMT%@%d:%02d", sign, h, m)
    }

    /// 行内标签：空→「自动」；否则「城市 · GMT±N」。
    static func label(_ id: String) -> String {
        guard !id.isEmpty else { return NSLocalizedString("itinerary.timezone.auto", comment: "") }
        if let g = gmt(id) { return "\(city(id)) · \(g)" }
        return city(id)
    }
}

/// 可搜索的 IANA 时区列表 + 顶部「自动（按地点）」复位项。写回 `timeZoneId`（""=自动）。
struct TimeZonePickerSheet: View {
    @Binding var timeZoneId: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private struct Row: Identifiable { let id: String; let city: String; let gmt: String; let offset: Int }

    private var rows: [Row] {
        let now = Date()
        return TimeZone.knownTimeZoneIdentifiers.compactMap { id -> Row? in
            guard let tz = TimeZone(identifier: id) else { return nil }
            return Row(id: id, city: TimeZoneDisplay.city(id),
                       gmt: TimeZoneDisplay.gmt(id, now: now) ?? "", offset: tz.secondsFromGMT(for: now))
        }
        .sorted { $0.offset != $1.offset ? $0.offset < $1.offset : $0.city < $1.city }
    }

    private var filtered: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { $0.city.lowercased().contains(q) || $0.id.lowercased().contains(q) || $0.gmt.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { timeZoneId = ""; dismiss() } label: {
                        HStack {
                            Text("itinerary.timezone.auto").foregroundStyle(.primary)
                            Spacer()
                            if timeZoneId.isEmpty { Image(systemName: "checkmark").foregroundStyle(CarryAccent.color) }
                        }
                    }
                }
                Section {
                    ForEach(filtered) { row in
                        Button { timeZoneId = row.id; dismiss() } label: {
                            HStack(spacing: 8) {
                                Text(row.city).foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                Text(row.gmt).font(.footnote).foregroundStyle(.secondary)
                                if row.id == timeZoneId {
                                    Image(systemName: "checkmark").foregroundStyle(CarryAccent.color)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("itinerary.timezone.picker.title")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: Text("itinerary.timezone.search"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 输入格式过滤

/// 行程表单里「格式固定」字段的输入限制（spec: 见各编辑表单）。
/// 只用于**代码/编号/电话**这类字符集确定的字段；**自由文本**（名称/备注/地址/承运方/车型/车牌等，
/// 可能含中文或各国字符）一律不限。
enum ItineraryInputFilter {
    /// ASCII 字母 + 数字（航班/车次号、机场代码、航站楼、座位等）。
    /// `nonisolated`：纯函数、无 actor 状态，需可在 Binding setter 的 nonisolated 上下文（`.filter`）里调用。
    nonisolated static func alphanumeric(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
    /// 纯数字（仅 ASCII 0–9）：电子客票号等纯数字编号；剥全角/阿拉伯数字与分隔符。
    nonisolated static func numeric(_ c: Character) -> Bool { c.isASCII && c.isNumber }
    /// 电话：数字 + `+ - ( ) 空格`（国际区号/分隔符）。
    nonisolated static func phone(_ c: Character) -> Bool { c.isNumber || "+-() ".contains(c) }
}

extension Binding where Value == String {
    /// 过滤输入：只保留 `allowed` 字符；`uppercase` 时转大写。代码/编号类字段套此即只能输入对应格式。
    /// 即时过滤（空格/符号/中文/emoji 进不去）；自由文本字段**不要**套，会误伤合法输入。
    func filteringInput(_ allowed: @escaping (Character) -> Bool, uppercase: Bool = false) -> Binding<String> {
        Binding(
            get: { wrappedValue },
            set: { newValue in
                let filtered = String(newValue.filter(allowed))
                wrappedValue = uppercase ? filtered.uppercased() : filtered
            }
        )
    }
}

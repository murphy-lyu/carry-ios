//
//  TripDateRangePickerSheet.swift
//  Carry
//

import SwiftUI

struct TripDateRangePickerSheet: View {

    let onConfirm: (Date, Date) -> Void
    /// 可选「暂不设置日期，先做计划」出口。传入即在底部显示该入口（→ 行程作为「规划中」无日期行程）。
    var onSkipDates: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedStart: Date
    @State private var selectedEnd: Date
    @State private var isSelectingEnd = false

    /// 与 CarrySubtleBackground 渐变底色一致，让底部入口无缝融入、不撞色。
    private var footerBlendColor: Color {
        colorScheme == .dark
            ? Color(red: 0.08, green: 0.08, blue: 0.09)
            : Color(red: 0.98, green: 0.98, blue: 0.97)
    }

    private let calendar = Calendar.current
    private let today: Date
    private let months: [Date]

    init(departure: Date, return returnDate: Date, onSkipDates: (() -> Void)? = nil, onConfirm: @escaping (Date, Date) -> Void) {
        self.onConfirm = onConfirm
        self.onSkipDates = onSkipDates
        let cal = Calendar.current
        let now = cal.startOfDay(for: Date())
        self.today = now
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        var ms: [Date] = []
        for i in -120...120 {
            if let m = cal.date(byAdding: .month, value: i, to: monthStart) {
                ms.append(m)
            }
        }
        self.months = ms
        _selectedStart = State(initialValue: cal.startOfDay(for: departure))
        _selectedEnd = State(initialValue: cal.startOfDay(for: returnDate))
    }

    private var nightsCount: Int {
        max(0, calendar.dateComponents([.day], from: selectedStart, to: selectedEnd).day ?? 0)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CarrySubtleBackground()

                VStack(spacing: 0) {
                    summaryStrip
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)

                    Divider()

                    weekdayHeader
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)

                    Divider()

                    monthsScrollView
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let onSkipDates {
                    Button {
                        onSkipDates()
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar.badge.clock")
                                .font(.footnote.weight(.semibold))
                            Text("tripdates.clear")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                    }
                    .buttonStyle(.plain)
                    // 月历滚动内容在「跳过日期」栏上沿柔和淡出（全 App 统一，见 BottomBarScrim），
                    // 取代原硬分隔线；淡出到 footerBlendColor（= 背景底端色）故无缝。
                    .bottomBarScrim(footerBlendColor)
                }
            }
            .navigationTitle("Select Dates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringKey("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringKey("Done")) {
                        onConfirm(selectedStart, selectedEnd)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Summary strip

    private var summaryStrip: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Departure")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(!isSelectingEnd ? AnyShapeStyle(Color.accentColor.opacity(0.92)) : AnyShapeStyle(.secondary))
                dateValueText(selectedStart)
            }

            Image(systemName: "arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary.opacity(0.88))

            VStack(alignment: .leading, spacing: 3) {
                Text("Return")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(isSelectingEnd ? AnyShapeStyle(Color.accentColor.opacity(0.92)) : AnyShapeStyle(.secondary))
                dateValueText(selectedEnd)
            }

            Spacer()

            if nightsCount > 0 {
                // 只显「天数」（天 = 含两端实际天数 = 晚数+1，与 TripBundle.spanDays 同口径）：短，单行原大小放得下，
                // 真机窄屏/大字号也不截断（原「x天x晚」太长会被截）。chip 在同一行右侧出现/消失只影响横向、不改行高、不跳。
                Text(String.localizedStringWithFormat(NSLocalizedString("date.days_only", comment: "Trip span in days"),
                            Int64(nightsCount + 1)))
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary.opacity(0.90))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())
            }
        }
    }

    /// 日期值文本：固定列宽，杜绝箭头 / Return 随日期文案宽度抖动。
    /// 用「本 locale 最长缩写月名 + 28 日」作隐藏参考撑出恒定宽度，真实日期左对齐叠上；
    /// 数字 monospacedDigit 让 1/2 位日的数字等宽。无论日位数、月名宽窄，起点都不位移。
    private func dateValueText(_ date: Date) -> some View {
        let fmt: Date.FormatStyle = .dateTime.month(.abbreviated).day().year()
        return ZStack(alignment: .leading) {
            Text(widestDateReference.formatted(fmt)).hidden()   // 占位撑出最宽宽度
            Text(date.formatted(fmt))
        }
        .font(.system(.subheadline, design: .rounded).weight(.medium))
        .monospacedDigit()
        // 强制单行：否则空间紧时「隐藏参考」（比真实日期更宽）会悄悄换行 → 该列变两行高 → 把「出发/返回」
        // 标题顶歪、与另一列不齐（真实日期仍单行，所以看着像标题莫名上移）。单行后两列恒等高、标题永远对齐。
        .lineLimit(1)
        .foregroundStyle(.primary)
    }

    /// 最宽参考日期：当前 locale 缩写月名最长的那个月 + 28 日（2 位日）。保证任何真实日期都不超过它。
    private var widestDateReference: Date {
        let symbols = calendar.shortMonthSymbols
        let monthIdx = (symbols.indices.max { symbols[$0].count < symbols[$1].count } ?? 0) + 1
        var c = DateComponents(); c.year = 2026; c.month = monthIdx; c.day = 28
        return calendar.date(from: c) ?? selectedStart
    }

    // MARK: - Weekday header

    private var weekdayHeader: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let firstIdx = calendar.firstWeekday - 1
        let ordered = Array(symbols[firstIdx...]) + Array(symbols[..<firstIdx])
        return HStack(spacing: 0) {
            ForEach(ordered, id: \.self) { symbol in
                Text(symbol)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(.tertiary.opacity(0.86))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Months scroll view

    private var monthsScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 24) {
                    ForEach(months, id: \.self) { month in
                        MonthGrid(
                            month: month,
                            today: today,
                            selectedStart: selectedStart,
                            selectedEnd: selectedEnd,
                            onTap: handleSelect
                        )
                        .id(month)
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.bottom, 40)
            }
            // 顶部留白用 `.contentMargins`（而非 LazyVStack 的 .padding.top）：scrollTo(anchor:.top) 会把内容 padding
            // 顶出视口、白白浪费；contentMargins 是 scroll 的内容内缩，scrollTo **尊重**它 → 锚定月份稳定落在顶边下方
            // 一段距离（无论起始月是首个还是中段），月标题不再贴星期栏。根因：scroll 锚点对齐的是「内容内缩边」。
            .contentMargins(.top, 20, for: .scrollContent)
            .onAppear {
                let startMonth = calendar.date(
                    from: calendar.dateComponents([.year, .month], from: selectedStart)
                ) ?? months.first ?? Date()
                let targetMonth = months.contains(startMonth) ? startMonth : (selectedStart < months.first ?? startMonth ? months.first : months.last)
                DispatchQueue.main.async {
                    if let targetMonth {
                        proxy.scrollTo(targetMonth, anchor: .top)
                    }
                }
            }
        }
    }

    // MARK: - Selection

    private func handleSelect(_ date: Date) {
        let d = calendar.startOfDay(for: date)
        if !isSelectingEnd {
            selectedStart = d
            selectedEnd = d
            isSelectingEnd = true
        } else if d < selectedStart {
            selectedStart = d
            selectedEnd = d
        } else {
            selectedEnd = d
            isSelectingEnd = false
        }
    }
}

// MARK: - MonthGrid

private struct MonthGrid: View {

    let month: Date
    let today: Date
    let selectedStart: Date
    let selectedEnd: Date
    let onTap: (Date) -> Void

    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.bottom, 4)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(Array(cells().enumerated()), id: \.offset) { _, date in
                    if let date {
                        DayCell(
                            date: date,
                            today: today,
                            selectedStart: selectedStart,
                            selectedEnd: selectedEnd,
                            onTap: { onTap(date) }
                        )
                    } else {
                        Color.clear.frame(height: 44)
                    }
                }
            }
        }
    }

    private func cells() -> [Date?] {
        guard
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
            let range = calendar.range(of: .day, in: .month, for: month)
        else { return [] }

        let weekday = calendar.component(.weekday, from: monthStart)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        var result: [Date?] = Array(repeating: nil, count: lead)
        for d in range {
            result.append(calendar.date(byAdding: .day, value: d - 1, to: monthStart))
        }
        return result
    }
}

// MARK: - DayCell

private struct DayCell: View {

    let date: Date
    let today: Date
    let selectedStart: Date
    let selectedEnd: Date
    let onTap: () -> Void

    private let calendar = Calendar.current
    @Environment(\.colorScheme) private var colorScheme

    private var isStart: Bool { calendar.isDate(date, inSameDayAs: selectedStart) }
    private var isEnd: Bool { calendar.isDate(date, inSameDayAs: selectedEnd) }
    private var hasRange: Bool { selectedStart < selectedEnd }
    private var isInRange: Bool { date > selectedStart && date < selectedEnd }
    private var isToday: Bool { calendar.isDate(date, inSameDayAs: today) }
    private var columnIndex: Int {
        (calendar.component(.weekday, from: date) - calendar.firstWeekday + 7) % 7
    }
    private var isRowStart: Bool { columnIndex == 0 }
    private var isRowEnd: Bool { columnIndex == 6 }
    private var selectedDayForeground: Color {
        // 选中日数字恒为白色：与选中态的白色「今天」圆点统一；浅蓝实心圆上白字比黑字更协调、不突兀。
        Color.white
    }
    private var rangeOpacity: Double {
        colorScheme == .dark ? 0.10 : 0.10
    }
    private var maxCornerRadius: CGFloat {
        // 大于半高即可，SwiftUI 自动 clamp 到半高 = 完美半圆端头，与端点实心圆视觉一致。
        100
    }
    private var endpointCircleScale: CGFloat {
        0.96
    }
    private var endpointEdgeInset: CGFloat {
        7
    }

    var body: some View {
        ZStack {
            if hasRange {
                if isStart {
                    selectionBackground
                } else if isEnd {
                    selectionBackground
                } else if isInRange {
                    selectionBackground
                }
            }

            if isStart || isEnd {
                Circle()
                    .fill(Color.accentColor)
                    .scaleEffect(endpointCircleScale)
            }

            Text("\(calendar.component(.day, from: date))")
                .font(.system(size: 15, weight: (isStart || isEnd) ? .semibold : .regular, design: .rounded))
                .foregroundStyle(
                    (isStart || isEnd) ? AnyShapeStyle(selectedDayForeground) :
                    AnyShapeStyle(Color.primary)
                )
        }
        .padding(.vertical, 2)
        .frame(height: 44)
        // 「今天」= 数字下方小实心圆点（区别于选中的实心大圆：点在下、大小悬殊，绝不混淆）。
        // 选中态用白色：浅蓝实心圆上深色小点会像污点，白点更像「指示器」、且与浅蓝对比清晰。未选中时用 accent。
        .overlay(alignment: .bottom) {
            if isToday {
                Circle()
                    .fill((isStart || isEnd) ? Color.white : Color.accentColor)
                    .frame(width: 5, height: 5)
                    .padding(.bottom, 5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    @ViewBuilder
    private var selectionBackground: some View {
        let r = maxCornerRadius
        // 所有"端点"（真实起止日 + 换行断点）的圆角侧统一加 endpointEdgeInset，
        // 保证相同圆角半径在相同宽度的形状上，视觉效果一致。
        if isStart {
            UnevenRoundedRectangle(
                topLeadingRadius: r, bottomLeadingRadius: r,
                bottomTrailingRadius: isRowEnd ? r : 0,
                topTrailingRadius: isRowEnd ? r : 0,
                style: .continuous
            )
            .fill(Color.accentColor.opacity(rangeOpacity))
            .padding(.leading, endpointEdgeInset)
            .padding(.trailing, isRowEnd ? endpointEdgeInset : 0)
        } else if isEnd {
            UnevenRoundedRectangle(
                topLeadingRadius: isRowStart ? r : 0,
                bottomLeadingRadius: isRowStart ? r : 0,
                bottomTrailingRadius: r, topTrailingRadius: r,
                style: .continuous
            )
            .fill(Color.accentColor.opacity(rangeOpacity))
            .padding(.leading, isRowStart ? endpointEdgeInset : 0)
            .padding(.trailing, endpointEdgeInset)
        } else {
            UnevenRoundedRectangle(
                topLeadingRadius: isRowStart ? r : 0,
                bottomLeadingRadius: isRowStart ? r : 0,
                bottomTrailingRadius: isRowEnd ? r : 0,
                topTrailingRadius: isRowEnd ? r : 0,
                style: .continuous
            )
            .fill(Color.accentColor.opacity(rangeOpacity))
            .padding(.leading, isRowStart ? endpointEdgeInset : 0)
            .padding(.trailing, isRowEnd ? endpointEdgeInset : 0)
        }
    }
}

#Preview {
    TripDateRangePickerSheet(
        departure: Date(),
        return: Calendar.current.date(byAdding: .day, value: 6, to: Date())!
    ) { _, _ in }
}

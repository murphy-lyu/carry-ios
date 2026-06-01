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
    @State private var selectedStart: Date
    @State private var selectedEnd: Date
    @State private var isSelectingEnd = false

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
                        .frame(height: 44)
                    }
                    .buttonStyle(.plain)
                    .background(.ultraThinMaterial)
                    .overlay(Divider(), alignment: .top)
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
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(!isSelectingEnd ? AnyShapeStyle(Color.accentColor.opacity(0.92)) : AnyShapeStyle(.secondary))
                Text(selectedStart.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }

            Image(systemName: "arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary.opacity(0.88))

            VStack(alignment: .leading, spacing: 3) {
                Text("Return")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelectingEnd ? AnyShapeStyle(Color.accentColor.opacity(0.92)) : AnyShapeStyle(.secondary))
                Text(selectedEnd.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }

            Spacer()

            if nightsCount > 0 {
                Text("\(nightsCount) \(nightsCount == 1 ? NSLocalizedString("date.night", comment: "") : NSLocalizedString("date.nights", comment: ""))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary.opacity(0.90))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - Weekday header

    private var weekdayHeader: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let firstIdx = calendar.firstWeekday - 1
        let ordered = Array(symbols[firstIdx...]) + Array(symbols[..<firstIdx])
        return HStack(spacing: 0) {
            ForEach(ordered, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption.weight(.medium))
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
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
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
    private var selectedDayForeground: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    private var rangeOpacity: Double {
        colorScheme == .dark ? 0.10 : 0.10
    }
    private var maxCornerRadius: CGFloat {
        18
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
            } else if isToday {
                Circle()
                    .strokeBorder(Color.accentColor.opacity(0.92), lineWidth: 1.5)
                    .padding(5)
            }

            Text("\(calendar.component(.day, from: date))")
                .font(.system(size: 15, weight: (isStart || isEnd) ? .semibold : .regular))
                .foregroundStyle(
                    (isStart || isEnd) ? AnyShapeStyle(selectedDayForeground) :
                    AnyShapeStyle(Color.primary)
                )
        }
        .padding(.vertical, 2)
        .frame(height: 44)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isStart {
            UnevenRoundedRectangle(
                topLeadingRadius: maxCornerRadius,
                bottomLeadingRadius: maxCornerRadius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Color.accentColor.opacity(rangeOpacity))
            .padding(.leading, endpointEdgeInset)
        } else if isEnd {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: maxCornerRadius,
                topTrailingRadius: maxCornerRadius,
                style: .continuous
            )
            .fill(Color.accentColor.opacity(rangeOpacity))
            .padding(.trailing, endpointEdgeInset)
        } else {
            Rectangle()
                .fill(Color.accentColor.opacity(rangeOpacity))
        }
    }
}

#Preview {
    TripDateRangePickerSheet(
        departure: Date(),
        return: Calendar.current.date(byAdding: .day, value: 6, to: Date())!
    ) { _, _ in }
}

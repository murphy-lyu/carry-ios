//
//  TripSpendView.swift
//  Carry
//
//  单个行程的花费页（spec: itinerary-trip-spend.md）：
//  总额 → 类别比例带 → 一个维度控件（类别/时间/币种）统领「分布条 + 逐笔清单」→ 诚实脚注。
//  纯展示，聚合走 `TripSpendDetail`；折算用 `ExchangeRateManager`。点逐笔行跳对应编辑器。
//

import SwiftUI

// MARK: - SpendCategory 的 UI 映射（颜色/图标/标题；放 View 层，模型保持纯数据）

extension SpendCategory {
    /// 系统语义色（暗色自适应、非硬编码 hex），用于比例带与类别点。
    var color: Color {
        switch self {
        case .transport:   return .blue
        case .lodging:     return .indigo
        case .restaurant:  return .orange
        case .cafe:        return Color(red: 0.6, green: 0.4, blue: 0.2)  // 咖啡棕
        case .bar:         return .purple
        case .sightseeing: return .teal
        case .museum:      return Color(red: 0.3, green: 0.5, blue: 0.7)  // 蓝灰
        case .park:        return .green
        case .beach:       return Color(red: 0.0, green: 0.7, blue: 0.8)  // 海蓝
        case .shopping:    return Color(red: 0.9, green: 0.4, blue: 0.5)  // 玫红
        case .experience:  return .pink
        case .other:       return .gray
        }
    }
    var symbolName: String {
        switch self {
        case .transport:   return "airplane"
        case .lodging:     return "bed.double.fill"
        case .restaurant:  return "fork.knife"
        case .cafe:        return "cup.and.saucer.fill"
        case .bar:         return "wineglass.fill"
        case .sightseeing: return "binoculars.fill"
        case .museum:      return "paintpalette.fill"
        case .park:        return "tree.fill"
        case .beach:       return "beach.umbrella.fill"
        case .shopping:    return "bag.fill"
        case .experience:  return "ferriswheel"
        case .other:       return "mappin"
        }
    }
}

// MARK: - TripSpendView

struct TripSpendView: View {
    let tripId: UUID

    @EnvironmentObject var store: TripStore
    @ObservedObject private var rate = ExchangeRateManager.shared
    @Environment(\.dismiss) private var dismiss

    enum Dimension: String, CaseIterable, Identifiable { case category, time, currency; var id: String { rawValue } }
    @State private var dimension: Dimension = .category
    @State private var editTarget: EditTarget?

    private struct EditTarget: Identifiable { let id: String; let entityId: UUID; let kind: SpendEntityKind }

    private var trip: TripBundle? { store.bundle(for: tripId) }

    private var detail: TripSpendDetail? {
        guard let trip else { return nil }
        return TripSpendDetail.compute(trip: trip, homeCode: rate.baseCurrencyCode,
                                       convert: { rate.convertToHome($0, from: $1) })
    }

    /// 维度选项：币种维度仅在 ≥2 种币种时出现。
    private func dimensions(_ d: TripSpendDetail) -> [Dimension] {
        d.currencyCount > 1 ? [.category, .time, .currency] : [.category, .time]
    }

    var body: some View {
        NavigationStack {
            Group {
                if let d = detail, d.hasAnyCost {
                    ScrollView(showsIndicators: false) { content(d) }
                } else {
                    // 空态：在整片可用区域内垂直+水平居中（无内容可滚，故不套 ScrollView，
                    // 用 maxHeight:.infinity 撑满 + frame 默认居中对齐，而非停在顶部固定高度里）。
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("tripspend.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                }
            }
            .sheet(item: $editTarget) { target in
                switch target.kind {
                case .stop:
                    if let stop = stop(for: target.entityId) { StopEditView(tripId: tripId, stop: stop) }
                case .transport:
                    TransportEditView(tripId: tripId, segmentId: target.entityId)
                case .lodging:
                    LodgingEditView(tripId: tripId, stayId: target.entityId)
                }
            }
        }
    }

    // MARK: 主体

    @ViewBuilder
    private func content(_ d: TripSpendDetail) -> some View {
        VStack(spacing: 22) {
            heroSection(d)
            proportionBar(d)
            dimensionPicker(d)
            distributionSection(d)
            itemizedSection(d)
            footnote(d)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .animation(.spring(duration: 0.3, bounce: 0.2), value: dimension)
    }

    // MARK: Hero 总额

    private func heroSection(_ d: TripSpendDetail) -> some View {
        VStack(spacing: 6) {
            Text(totalText(d))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(metaText(d))
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func totalText(_ d: TripSpendDetail) -> String {
        (d.approximate ? "≈" : "") + CurrencyCatalog.format(d.total, code: d.homeCode)
    }

    private func metaText(_ d: TripSpendDetail) -> String {
        let days = max(1, trip?.spanDays ?? 1)
        let daily = CurrencyCatalog.format(d.total / Double(days), code: d.homeCode)
        // 措辞规避复数：英文「N recorded · ¥X/day」、中文「N 笔 · 日均 ¥X」。
        return String.localizedStringWithFormat(NSLocalizedString("tripspend.meta", comment: ""), d.recordedCount, daily)
    }

    // MARK: 类别比例带（始终为类别口径的格式塔，独立于维度）

    @ViewBuilder
    private func proportionBar(_ d: TripSpendDetail) -> some View {
        if d.total > 0 {
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(d.byCategory, id: \.category) { item in
                        item.category.color
                            .frame(width: max(2, geo.size.width * item.amount / d.total))
                    }
                }
            }
            .frame(height: 12)
            .clipShape(Capsule())
        }
    }

    // MARK: 维度切换

    private func dimensionPicker(_ d: TripSpendDetail) -> some View {
        Picker("", selection: $dimension) {
            ForEach(dimensions(d)) { dim in
                // 运行时拼 key → 用 NSLocalizedString 查；`LocalizedStringKey("前缀\(变量)")` 会被当成
                // 带 %@ 占位的格式 key、查不到而回显原始字符串（已踩坑）。
                Text(NSLocalizedString("tripspend.dim.\(dim.rawValue)", comment: "")).tag(dim)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: d.currencyCount) { _, count in
            if count <= 1, dimension == .currency { dimension = .category }   // 币种维度消失时回退
        }
    }

    // MARK: 分布（按所选维度，钱包式条形行）

    @ViewBuilder
    private func distributionSection(_ d: TripSpendDetail) -> some View {
        let rows = distributionRows(d)
        let maxAmount = rows.map(\.amount).max() ?? 1
        VStack(spacing: 0) {
            ForEach(rows) { row in
                if row.id != rows.first?.id { Divider().padding(.leading, 38) }
                distributionRow(row, maxAmount: maxAmount, total: d.total, code: d.homeCode,
                                isCurrency: dimension == .currency)
            }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    private struct DistRow: Identifiable {
        let id: String
        let color: Color
        let label: String
        let amount: Double      // 展示用（类别/天=本位币；币种=原币）
        let code: String        // 金额币种
    }

    private func distributionRows(_ d: TripSpendDetail) -> [DistRow] {
        switch dimension {
        case .category:
            return d.byCategory.map {
                DistRow(id: "c-\($0.category.rawValue)", color: $0.category.color,
                        label: NSLocalizedString("tripspend.cat.\($0.category.rawValue)", comment: ""),
                        amount: $0.amount, code: d.homeCode)
            }
        case .time:
            return d.byDay.map {
                DistRow(id: "d-\($0.dayOrder)", color: dayColor($0.dayOrder),
                        label: dayLabel($0.dayOrder), amount: $0.amount, code: d.homeCode)
            }
        case .currency:
            return d.byCurrency.map {
                DistRow(id: "x-\($0.code)", color: .secondary,
                        label: CurrencyCatalog.localizedName(for: $0.code), amount: $0.amount, code: $0.code)
            }
        }
    }

    private func distributionRow(_ row: DistRow, maxAmount: Double, total: Double,
                                 code: String, isCurrency: Bool) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Circle().fill(row.color).frame(width: 10, height: 10)
                Text(row.label)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(CurrencyCatalog.format(row.amount, code: row.code))
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                // 币种维度无「占总额百分比」概念（原币不可加总）→ 不显百分比。
                if !isCurrency, total > 0 {
                    Text(percentText(row.amount / total))
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
            // 占比细条（按本组最大值归一，强调相对高低）。
            GeometryReader { geo in
                Capsule().fill(row.color.opacity(0.25))
                    .frame(width: max(3, geo.size.width * row.amount / max(maxAmount, 0.0001)))
            }
            .frame(height: 4)
            .padding(.leading, 22)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: 逐笔清单（按所选维度分组）

    @ViewBuilder
    private func itemizedSection(_ d: TripSpendDetail) -> some View {
        let groups = itemGroups(d)
        VStack(alignment: .leading, spacing: 14) {
            Text("tripspend.list.title")
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(group.title)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        Spacer()
                        Text(group.subtitle)
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12).padding(.bottom, 6)
                    ForEach(group.items) { item in
                        if item.id != group.items.first?.id { Divider().padding(.leading, 48) }
                        itemRow(item, homeCode: d.homeCode)
                    }
                    .padding(.bottom, 4)
                }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            }
        }
    }

    private struct ItemGroup: Identifiable { let id: String; let title: String; let subtitle: String; let items: [SpendItem] }

    private func itemGroups(_ d: TripSpendDetail) -> [ItemGroup] {
        switch dimension {
        case .category:
            return d.byCategory.map { entry in
                let items = d.items.filter { $0.category == entry.category }
                return ItemGroup(id: "c-\(entry.category.rawValue)",
                                 title: NSLocalizedString("tripspend.cat.\(entry.category.rawValue)", comment: ""),
                                 subtitle: CurrencyCatalog.format(entry.amount, code: d.homeCode), items: items)
            }
        case .time:
            return d.byDay.map { entry in
                let items = d.items.filter { $0.dayOrder == entry.dayOrder }
                return ItemGroup(id: "d-\(entry.dayOrder)", title: dayLabel(entry.dayOrder),
                                 subtitle: CurrencyCatalog.format(entry.amount, code: d.homeCode), items: items)
            }
        case .currency:
            return d.byCurrency.map { entry in
                let items = d.items.filter { $0.currencyCode.uppercased() == entry.code }
                return ItemGroup(id: "x-\(entry.code)", title: CurrencyCatalog.localizedName(for: entry.code),
                                 subtitle: CurrencyCatalog.format(entry.amount, code: entry.code), items: items)
            }
        }
    }

    private func itemRow(_ item: SpendItem, homeCode: String) -> some View {
        Button {
            editTarget = EditTarget(id: "\(item.kind)-\(item.id)", entityId: item.id, kind: item.kind)
        } label: {
            HStack(spacing: 12) {
                // 交通项按**具体方式**取图标（航班/火车/租车…），非交通用类别图标——避免租车/火车显示成飞机。
                Image(systemName: item.mode?.symbolName ?? item.category.symbolName)
                    .font(.system(size: 14)).foregroundStyle(item.category.color)
                    .frame(width: 22)
                Text(item.name.isEmpty ? NSLocalizedString("tripspend.cat.\(item.category.rawValue)", comment: "") : item.name)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    // 原币真相。
                    Text(CurrencyCatalog.format(item.amount, code: item.currencyCode))
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                    // 原币 ≠ 本位币 → 副行显本位币折算（缺汇率则诚实标「未折算」）。
                    if item.currencyCode.uppercased() != homeCode.uppercased() {
                        if let h = item.homeAmount {
                            Text("≈ " + CurrencyCatalog.format(h, code: homeCode))
                                .font(.system(.caption2, design: .rounded)).foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else {
                            Text("tripspend.unconverted_tag")
                                .font(.system(.caption2, design: .rounded)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 脚注（诚实）

    @ViewBuilder
    private func footnote(_ d: TripSpendDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if d.approximate {
                Text(String(format: NSLocalizedString("tripspend.foot.approx", comment: ""),
                            CurrencyCatalog.localizedName(for: d.homeCode)))
            }
            if d.unconvertedCount > 0 {
                Text(String.localizedStringWithFormat(NSLocalizedString("tripspend.foot.unconverted", comment: ""), d.unconvertedCount))
            }
        }
        .font(.system(.caption2, design: .rounded))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    // MARK: 空态

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "yensign.circle")
                .font(.system(size: 44)).foregroundStyle(.tertiary)
            Text("tripspend.empty.title")
                .font(.system(.headline, design: .rounded))
            Text("tripspend.empty.subtitle")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
    }

    // MARK: 辅助

    private func percentText(_ frac: Double) -> String {
        let pct = Int((frac * 100).rounded())
        return "\(max(pct, frac > 0 ? 1 : 0))%"
    }

    /// 天序 → 标签：有日期行程显真实日期，无日期显「第 N 天」。
    private func dayLabel(_ order: Int) -> String {
        if let trip, !trip.isDateless {
            let base = Calendar.current.startOfDay(for: trip.departureDate)
            let date = Calendar.current.date(byAdding: .day, value: order, to: base) ?? base
            return date.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated))
        }
        return String(format: NSLocalizedString("itinerary.day.title", comment: ""), order + 1)
    }

    private func dayColor(_ order: Int) -> Color { ItineraryDayPalette.color(forDayIndex: order) }

    private func stop(for id: UUID) -> ItineraryStop? {
        trip?.safeItineraryDays.flatMap { $0.stops ?? [] }.first { $0.id == id }
    }
}

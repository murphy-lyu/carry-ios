//
//  ScenePickerView.swift
//  Carry
//

import SwiftUI
import UIKit

// MARK: - ScenePickerView

struct ScenePickerView: View {

    enum Mode {
        case edit(tripId: UUID)
        case autoPack(tripInfo: TripInfo, seedSections: [PackingSection])
        case suggest(tripId: UUID)
    }

    private let mode: Mode
    private let preselectedSceneKeys: [String]

    init(editingTripId: UUID) {
        self.mode = .edit(tripId: editingTripId)
        self.preselectedSceneKeys = []
    }

    init(autoPackTripInfo: TripInfo, seedSections: [PackingSection], initialSceneKeys: [String] = []) {
        self.mode = .autoPack(tripInfo: autoPackTripInfo, seedSections: seedSections)
        self.preselectedSceneKeys = initialSceneKeys
    }

    init(suggestForTripId: UUID) {
        self.mode = .suggest(tripId: suggestForTripId)
        self.preselectedSceneKeys = []
    }

    @EnvironmentObject var store: TripStore
    @EnvironmentObject var router: NavigationRouter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedItems: Set<String> = []
    @State private var didLoadInitialSelection = false
    @State private var isSaved = false
    @State private var confirmedSuggestKeys: [String]? = nil
    @State private var didFinishSuggest = false
    /// HealthKit 预测：本次行程区间是否赶上经期。读不到/不重叠时保持 false（静默降级）。
    @State private var cycleNudgeActive = false
    @State private var didRunCyclePrediction = false
    /// 「经期打包提醒」总开关（设置内，默认关）。关闭时不跑预测、不触碰 HealthKit。
    @AppStorage("cycleNudgeFeatureEnabled") private var cycleNudgeFeatureEnabled = false

    private var hasSelection: Bool { !selectedItems.isEmpty }
    private var selectionCount: Int { selectedItems.count }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var isAutoPack: Bool {
        if case .autoPack = mode { return true }
        return false
    }

    private var isSuggest: Bool {
        if case .suggest = mode { return true }
        return false
    }

    private var primaryButtonLabelKey: LocalizedStringKey {
        if isSaved { return "scenes.updated" }
        if isEditing {
            return hasSelection ? "scenes.update_list" : "scenes.select_one"
        } else if isAutoPack {
            return hasSelection ? "scenes.update" : "scenes.select_one"
        } else if isSuggest {
            return hasSelection ? "See suggestions" : "scenes.skip"
        } else {
            return hasSelection ? "Generate my list" : "scenes.select_one"
        }
    }

    private var isPrimaryButtonEnabled: Bool {
        if isSaved { return false }
        if isSuggest { return true }
        return hasSelection
    }

    private var isPrimaryButtonHighlighted: Bool {
        if isSaved { return false }
        if isSuggest { return true }
        return hasSelection
    }

    private var footerBackgroundColor: Color {
        colorScheme == .dark ? Color(red: 0.08, green: 0.08, blue: 0.09) : Color(UIColor.systemBackground)
    }

    private var primaryButtonBackground: Color {
        if isPrimaryButtonHighlighted {
            return Color(UIColor.label)
        }
        return colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color(UIColor.systemGray3)
    }

    private var primaryButtonForeground: Color {
        isPrimaryButtonHighlighted ? Color(UIColor.systemBackground) : Color(UIColor.secondaryLabel)
    }

    var body: some View {
        ZStack {
            CarrySubtleBackground()

            VStack(spacing: 0) {
                heroSection

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if showCycleNudge {
                            cycleNudgeSection
                        }

                        if !nudgeSceneKeys.isEmpty {
                            climateNudgeSection
                        }

                        ForEach(Array(defaultSceneGroups.enumerated()), id: \.element.id) { index, group in
                            SceneGroupSection(group: group, selectedItems: $selectedItems)
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Button(action: { primaryAction() }) {
                    HStack(spacing: 8) {
                        if isSaved {
                            Image(systemName: "checkmark")
                                .fontWeight(.medium)
                                .transition(.scale.combined(with: .opacity))
                        }
                        Text(primaryButtonLabelKey)
                            .transition(.opacity)
                    }
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(primaryButtonForeground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(primaryButtonBackground)
                    .cornerRadius(14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color(.separator).opacity(isPrimaryButtonHighlighted ? 0.08 : 0.14), lineWidth: 1)
                    )
                    .animation(.easeInOut(duration: 0.2), value: isSaved)
                }
                .buttonStyle(SolidPressButtonStyle())
                .allowsHitTesting(isPrimaryButtonEnabled)
                .padding(.horizontal, 20)
            }
            .padding(.top, 12)
            .padding(.bottom, 16)
            .background(footerBackgroundColor)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadInitialSelectionIfNeeded() }
        .task { await runCyclePredictionIfNeeded() }
        .sheet(isPresented: Binding(
            get: { confirmedSuggestKeys != nil },
            set: { if !$0 { confirmedSuggestKeys = nil } }
        )) {
            if case .suggest(let tripId) = mode, let keys = confirmedSuggestKeys {
                SuggestionPreviewView(tripId: tripId, sceneKeys: keys, didFinish: $didFinishSuggest)
            }
        }
        .onChange(of: didFinishSuggest) { _, finished in
            if finished { dismiss() }
        }
    }

    // MARK: - Climate nudge

    private var tripBundle: TripBundle? {
        switch mode {
        case .edit(let id), .suggest(let id): return store.bundle(for: id)
        default: return nil
        }
    }

    private var nudgeSceneKeys: [String] {
        guard let bundle = tripBundle else { return [] }
        // 优先用已落库的 countryCode；未回填（如刚创建、地理编码未完成）时回退到按目的地
        // 文字即时推断，与 ItemPickerView 同源，避免气候 nudge 因时序缺失。
        let code = bundle.countryCode.isEmpty
            ? (store.inferCountryCodes(for: bundle.destinationCity).first ?? "")
            : bundle.countryCode
        guard !code.isEmpty else { return [] }
        let inferred = ClimateInference.inferredSceneKeys(
            countryCode: code,
            departureDate: bundle.departureDate
        )
        let selectedKeys = Set(selectedItems.compactMap { sceneLabelToKey[$0] })
        return inferred.filter { !selectedKeys.contains($0) }
    }

    private static let sceneKeyToLabel: [String: String] = Dictionary(
        uniqueKeysWithValues: sceneLabelToKey.map { ($1, $0) }
    )

    private static let periodSceneKey = "personal_period"

    /// 仅当预测命中、且用户尚未手动选中经期场景时，才展示经期轻推。
    private var showCycleNudge: Bool {
        guard cycleNudgeActive,
              let label = Self.sceneKeyToLabel[Self.periodSceneKey] else { return false }
        return !selectedItems.contains(label)
    }

    private var climateNudgeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("scenepicker.nudge.title")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(.systemGray))
                .kerning(1.5)
                .textCase(.uppercase)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(nudgeSceneKeys, id: \.self) { key in
                        if let label = Self.sceneKeyToLabel[key] {
                            SceneChip(
                                label: label,
                                isSelected: selectedItems.contains(label)
                            ) {
                                selectedItems.insert(label)
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 6)
        }
    }

    private var cycleNudgeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("scenepicker.nudge.cycle.title")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(.systemGray))
                .kerning(1.5)
                .textCase(.uppercase)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let label = Self.sceneKeyToLabel[Self.periodSceneKey] {
                        SceneChip(
                            label: label,
                            isSelected: selectedItems.contains(label)
                        ) {
                            selectedItems.insert(label)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            CarryLogger.shared.log(.cycleNudgeAccepted)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 6)
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Choose scenes")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("Pick travel scenes to generate a better list")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isAutoPack || isEditing || isSuggest {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                            .glassCircleButton()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
    }

    // MARK: Private

    /// 仅 edit / suggest 模式（已有 TripBundle 落库）才运行经期预测，且每个生命周期只跑一次。
    private func runCyclePredictionIfNeeded() async {
        guard !didRunCyclePrediction else { return }
        didRunCyclePrediction = true

#if DEBUG
        // 调试开关：跳过 HealthKit + 总开关，强制显示经期 nudge（任意 mode），便于纯 UI 验收。
        if UserDefaults.standard.bool(forKey: "debugForceCycleNudge") {
            cycleNudgeActive = true
            CarryLogger.shared.log(.cycleNudgeShown)
            return
        }
#endif

        // 总闸：用户未在设置里开启「经期打包提醒」则完全不跑预测、不触碰 HealthKit。
        guard cycleNudgeFeatureEnabled else { return }
        guard let range = tripDateRange else { return }

        let overlaps = await CycleInference.tripOverlapsPredictedPeriod(start: range.start, end: range.end)
        guard overlaps else { return }

        cycleNudgeActive = true
        CarryLogger.shared.log(.cycleNudgeShown)
    }

    /// 跨 mode 提取行程日期区间。autoPack 用 TripInfo（创建当下即有日期，
    /// 无需等待 countryCode），编辑 / 推荐用已落库的 TripBundle。
    private var tripDateRange: (start: Date, end: Date)? {
        let calendar = Calendar.current
        switch mode {
        case .autoPack(let info, _):
            return (calendar.startOfDay(for: info.departureDate),
                    calendar.startOfDay(for: info.returnDate))
        case .edit(let id), .suggest(let id):
            guard let bundle = store.bundle(for: id) else { return nil }
            let start = calendar.startOfDay(for: bundle.departureDate)
            guard let end = calendar.date(byAdding: .day, value: max(0, bundle.days), to: start) else { return nil }
            return (start, end)
        }
    }

    private func loadInitialSelectionIfNeeded() {
        guard !didLoadInitialSelection else { return }
        didLoadInitialSelection = true
        switch mode {
        case .autoPack:
            guard !preselectedSceneKeys.isEmpty else { return }
            let keysSet = Set(preselectedSceneKeys)
            let labels = sceneLabelToKey.compactMap { (label, key) -> String? in
                keysSet.contains(key) ? label : nil
            }
            selectedItems = Set(labels)
        case .edit(let id), .suggest(let id):
            guard let trip = store.bundle(for: id) else { return }
            let savedKeys = Set(trip.selectedSceneKeys)
            let labels = sceneLabelToKey.compactMap { (label, key) -> String? in
                savedKeys.contains(key) ? label : nil
            }
            selectedItems = Set(labels)
        }
    }

    private func primaryAction() {
        let keys = selectedItems.compactMap { sceneLabelToKey[$0] }
        let modeLabel: String
        switch mode {
        case .edit:     modeLabel = "edit"
        case .autoPack: modeLabel = "auto_pack"
        case .suggest:  modeLabel = "suggest"
        }
        CarryLogger.shared.log(.sceneSelected, context: "mode=\(modeLabel) count=\(keys.count)")
        switch mode {
        case .edit(let tripId):
            guard !isSaved else { return }
            store.regenerateScenes(tripId: tripId, keys: keys)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.easeInOut(duration: 0.2)) { isSaved = true }
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                dismiss()
            }
        case .autoPack(let info, _):
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            router.path = NavigationPath()
            router.path.append(CreationRoute.autoPackPicker(info, sceneKeys: keys))
            dismiss()
        case .suggest:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            guard !keys.isEmpty else {
                if case .suggest(let tripId) = mode {
                    store.setSelectedSceneKeys(tripId: tripId, keys: [])
                }
                dismiss()
                return
            }
            confirmedSuggestKeys = keys
        }
    }

}

// MARK: - Scene Group Section

struct SceneGroupSection: View {

    let group: SceneGroup
    @Binding var selectedItems: Set<String>
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey(group.title))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(colorScheme == .dark ? Color(.systemGray2) : Color(.systemGray))
                .kerning(1.5)
                .textCase(.uppercase)
                .padding(.horizontal, 16)

            GeometryReader { geo in
                let rows = chipRows(for: group.items, maxWidth: max(1, geo.size.width))
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 8) {
                            ForEach(row, id: \.self) { item in
                                SceneChip(
                                    label: item,
                                    isSelected: selectedItems.contains(item)
                                ) {
                                    if selectedItems.contains(item) {
                                        selectedItems.remove(item)
                                    } else {
                                        selectedItems.insert(item)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: chipsHeight(for: group.items))
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    private func chipRows(for items: [String], maxWidth: CGFloat) -> [[String]] {
        var rows: [[String]] = [[]]
        var currentRowWidth: CGFloat = 0
        let spacing: CGFloat = 8

        for item in items {
            let chipWidth = estimatedChipWidth(for: item)
            let nextWidth = rows[rows.count - 1].isEmpty
                ? chipWidth
                : currentRowWidth + spacing + chipWidth

            if nextWidth > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([item])
                currentRowWidth = chipWidth
            } else {
                rows[rows.count - 1].append(item)
                currentRowWidth = nextWidth
            }
        }
        return rows
    }

    private func chipsHeight(for items: [String]) -> CGFloat {
        let available = max(1, UIScreen.main.bounds.width - 32) // section has 16 + 16 padding
        let rowCount = chipRows(for: items, maxWidth: available).count
        let rowH: CGFloat = 30
        let spacing: CGFloat = 8
        return CGFloat(rowCount) * rowH + CGFloat(max(0, rowCount - 1)) * spacing
    }

    private func estimatedChipWidth(for item: String) -> CGFloat {
        let text = NSLocalizedString(item, comment: "") as NSString
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        let textW = ceil(text.size(withAttributes: [.font: font]).width)
        let iconW: CGFloat = 16
        let innerSpacing: CGFloat = 6
        let horizontalPadding: CGFloat = 20
        return textW + iconW + innerSpacing + horizontalPadding
    }
}

// MARK: - Scene Chip

private let sceneSymbols: [String: String] = [
    "🚗 Road trip":            "car.fill",
    "✈️ Long-haul flight":     "airplane",
    "🚢 Cruise":               "ferry.fill",
    "☀️ Tropical / beach":     "sun.max.fill",
    "🌧 Rainy city":           "cloud.rain.fill",
    "⛰ High altitude":        "mountain.2.fill",
    "❄️ Winter / cold":        "snowflake",
    "💼 Business":             "briefcase.fill",
    "💻 Remote work":          "laptopcomputer",
    "👶 Travelling with kids": "figure.and.child.holdinghands",
    "🥾 Hiking / camping":     "tent.fill",
    "💍 Honeymoon":            "heart.fill",
    "🎒 Backpacking":          "backpack.fill",
    "🏨 City break":           "building.2.fill",
    "🌸 On / near period":     "leaf.fill",
    "☕ Coffee lover":          "cup.and.saucer.fill",
    "🍵 Tea lover":            "cup.and.saucer.fill",
    "💊 Daily medication":     "pill.fill",
]

struct SceneChip: View {

    let label: String
    let isSelected: Bool
    let action: () -> Void

    private var displayKey: LocalizedStringKey {
        LocalizedStringKey(label)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol = sceneSymbols[label] {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .frame(width: 16, height: 16)
                        .foregroundStyle(isSelected ? Color(UIColor.systemBackground) : .primary)
                }
                Text(displayKey)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color(UIColor.systemBackground) : .primary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.primary : Color.clear)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.secondary.opacity(isSelected ? 0 : 0.5), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ScenePickerView(
            autoPackTripInfo: TripInfo(name: "Tokyo", destinationCity: "Tokyo"),
            seedSections: []
        )
        .environmentObject(TripStore())
        .environmentObject(NavigationRouter())
    }
}

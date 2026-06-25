//
//  TripInfoView.swift
//  Carry
//

import SwiftUI
import UIKit

struct TripInfoView: View {

    let routeID: UUID?
    @State private var tripName: String
    @State private var destinationCity: String
    @State private var departureDate: Date
    @State private var returnDate: Date
    @State private var showDatePicker = false
    /// 下滑/取消时若已有草稿，弹「放弃更改?」确认（对齐 Apple 新建表单范式）。
    @State private var showDiscardConfirm = false
    /// 是否设置了日期。预填默认 true；点「无需日期」清除则为 false（→ 规划中行程）。
    @State private var hasDates = true
    /// 防快速双击重复建行程（一击即建、无中间步，必须自守）。
    @State private var isCreating = false
    /// 目的地「输入即解析」：复用统一检索补全器（国内 MapKit/高德、海外 places Worker），
    /// 选中建议即捕获权威 ISO 国家码 + 坐标，建行程时直接点亮地图、免文本反解析。
    @StateObject private var destinationCompleter = StopSearchCompleter()
    /// 已选定的结构化主目的地（含 countryCode/坐标）。用户改动文本与其不一致即作废、回退文本路径。
    @State private var resolvedPrimary: ResolvedPlace?
    /// 选中建议后解析坐标/国家码的在途态（海外走网络），期间在列表上覆盖一个轻量指示。
    @State private var isResolvingDestination = false
    @FocusState private var focusedField: FocusField?
    @EnvironmentObject var router: NavigationRouter
    @EnvironmentObject var store: TripStore
    @Environment(\.colorScheme) private var colorScheme

    private enum FocusField: Hashable {
        case tripName
        case destinationCity
    }

    init(routeID: UUID? = nil) {
        self.routeID = routeID
        let initial = TripInfo()
        _tripName = State(initialValue: initial.name)
        _destinationCity = State(initialValue: initial.destinationCity)
        _departureDate = State(initialValue: initial.departureDate)
        _returnDate = State(initialValue: initial.returnDate)
    }

    private var canContinue: Bool {
        !tripName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !destinationCity.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 是否已填了内容（名字或城市）。日期是预填默认值，不算草稿。
    /// 有草稿时下滑被拦、取消需确认，避免误删；空表单则可直接关闭。
    private var hasDraft: Bool {
        !tripName.trimmingCharacters(in: .whitespaces).isEmpty ||
        !destinationCity.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var continueButtonBackground: Color {
        if canContinue {
            return colorScheme == .dark ? Color(.label) : Color(.label)
        }
        return colorScheme == .dark ? Color(.secondarySystemBackground) : Color(.systemGray3)
    }

    private var continueButtonForeground: Color {
        canContinue ? Color(.systemBackground) : Color(.secondaryLabel)
    }

    private var info: TripInfo {
        // 仅当已选结构化目的地、且当前文本仍等于所选显示名时，才携带权威码（防选后改字用了陈旧码）。
        let resolved = (resolvedPrimary?.name == destinationCity) ? resolvedPrimary : nil
        return TripInfo(
            name: tripName,
            destinationCity: destinationCity,
            departureDate: departureDate,
            returnDate: returnDate,
            isDateless: !hasDates,
            resolvedCountryCode: resolved.flatMap { $0.countryCode.isEmpty ? nil : $0.countryCode },
            resolvedLatitude: resolved.map(\.latitude),
            resolvedLongitude: resolved.map(\.longitude)
        )
    }

    private func hideKeyboard() {
        focusedField = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    heroSection

                    fieldGroup(label: "Trip Name") {
                        stableField("e.g. Italy · Tuscany", text: $tripName, focus: .tripName)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        fieldGroup(label: "Destination City") {
                            stableField("e.g. Florence", text: $destinationCity, focus: .destinationCity)
                        }
                        // 建议列表是目的地字段的**兄弟视图**（不叠在 TextField 上、不在输入法预编辑态改写其文本/视图树），
                        // 故中文选词不被打断（见 stableField 注释）。仅聚焦且未选定、有结果时显示。
                        if showDestinationSuggestions {
                            destinationSuggestionList
                                .padding(.horizontal, 16)
                        }
                    }

                    fieldGroup(label: "Dates") {
                        if hasDates {
                            Button { showDatePicker = true } label: {
                                HStack(spacing: 0) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Departure")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary.opacity(0.82))
                                        Text(departureDate.formatted(date: .long, time: .omitted))
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary.opacity(0.88))
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 3) {
                                        Text("Return")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary.opacity(0.82))
                                        Text(returnDate.formatted(date: .long, time: .omitted))
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                    }
                                }
                                .padding(14)
                            }
                            .buttonStyle(.plain)
                            .background(Color(UIColor.systemBackground).opacity(0.64))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(
                                        Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.07),
                                        lineWidth: 1
                                    )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else {
                            datesUnsetCard
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(
            TapGesture().onEnded {
                hideKeyboard()
            }
        )
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Button(action: {
                    guard canContinue, !isCreating else { return }   // 防双击重复创建
                    isCreating = true
                    hideKeyboard()
                    // 新链路：填完行程信息直接建空行程并落到该行程（默认进「行程规划」面），
                    // 用户再按习惯做规划或加打包——不再强制走「添加物品」。物品/智能打包仍可在行程内添加。
                    let newId = store.createTrip(from: info)
                    router.finishCreation(landingTripId: newId)
                    Task { await NotificationManager.requestAuthorizationIfNeeded() }
                }) {
                    Text("Create")          // 直接建行程的 CTA（不再是「下一步选物品」）
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(continueButtonForeground)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(continueButtonBackground)
                        .cornerRadius(14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color(.separator).opacity(canContinue ? 0.08 : 0.14), lineWidth: 1)
                        )
                }
                .buttonStyle(SolidPressButtonStyle())
                .allowsHitTesting(canContinue)
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
            // 内容在按钮上沿柔和淡出（全 App 统一，见 BottomBarScrim）；一级页淡出到 systemBackground。
            .bottomBarScrim(Color(UIColor.systemBackground))
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 创建 cover 的根步无返回 chevron——给「取消」放弃草稿。push 流（Mac）不显示，
            // 沿用系统返回。语义：离开模态 = 放弃草稿，而非「返回上一级」。
            if router.showCreation {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringKey("common.cancel")) {
                        if hasDraft { showDiscardConfirm = true } else { router.cancelCreation() }
                    }
                }
            }
        }
        // 有草稿时拦截下滑关闭，逼用户走「取消」→ 确认，避免手滑误删（空表单不拦，可直接下滑关）。
        .interactiveDismissDisabled(hasDraft)
        // 二元「放弃草稿 + 取消」用 .alert（居中两按钮模态）而非 .confirmationDialog：
        // 后者在 regular 宽度（iPad / Catalyst / 某些 iOS 26 上下文）会降级成锚到「取消」按钮的
        // popover 气泡，且自动隐藏 .cancel 按钮（只剩一个），弹到页顶、不好操作。.alert 各平台一致。
        .alert(
            LocalizedStringKey("tripinfo.discard.title"),
            isPresented: $showDiscardConfirm
        ) {
            Button(LocalizedStringKey("tripinfo.discard.confirm"), role: .destructive) {
                router.cancelCreation()
            }
            Button(LocalizedStringKey("tripinfo.discard.keep"), role: .cancel) { }
        }
        .sheet(isPresented: $showDatePicker) {
            TripDateRangePickerSheet(
                departure: departureDate,
                return: returnDate,
                onSkipDates: { hasDates = false }   // 选择器内「暂不设置日期」→ 规划中行程
            ) { start, end in
                departureDate = start
                returnDate = max(end, Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start)
                hasDates = true   // 选定日期 = 有日期行程
            }
        }
        .onChange(of: destinationCity) { _, newValue in
            // 选了 A 又改字（与所选显示名不一致）→ 作废结构化结果，回退自由文本（updateCountryCode 文本路径）。
            if let picked = resolvedPrimary, newValue != picked.name {
                resolvedPrimary = nil
            }
            // 选中态不再驱动检索（列表已收起，避免选完又弹回）；只读 text 喂补全器，绝不反向改写 TextField。
            if resolvedPrimary == nil {
                destinationCompleter.query = newValue
            }
        }
        .onDisappear { destinationCompleter.tearDown() }   // 取消在途海外请求 + 停 MapKit 补全
        .onAppear {
            // 目的地字段走「城市模式」：只补全国家/地区/城市，让「Tokyo→东京市」成首条、不掺同名 POI。
            // 建行程时尚无目的地坐标可做 proximity 偏置，故靠 types 过滤拿到正确的城市本体。
            destinationCompleter.placeMode = true
            #if DEBUG
            let dep = departureDate.formatted(date: .abbreviated, time: .omitted)
            let ret = returnDate.formatted(date: .abbreviated, time: .omitted)
            let context = "route=\(routeID?.uuidString ?? "nil") departure=\(dep) return=\(ret)"
            CarryLogger.shared.log(.tripInfoOpened, context: context)
            #endif
        }
    }

    /// 清除日期后的空态卡片：点此可重新选择日期（→ 恢复有日期行程）。
    private var datesUnsetCard: some View {
        Button { showDatePicker = true } label: {
            HStack {
                Text("tripdates.unset")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "calendar.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
        }
        .buttonStyle(.plain)
        .background(Color(UIColor.systemBackground).opacity(0.64))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.07), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New trip")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text("Add the essentials first, then choose your items")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.86))
        }
        .padding(16)
    }

    private func stableField(
        _ placeholder: LocalizedStringKey,
        text: Binding<String>,
        focus: FocusField
    ) -> some View {
        // 原生占位符（UITextField 自渲染）：有 marked text（输入法预编辑态）即隐藏，且不像
        // 「if isEmpty 显隐 Text 叠层」那样在选词提交时增删视图树——后者会打断输入法提交，
        // 导致中文（如微信输入法）选词后内容丢失、预编辑态与占位符叠加。样式与原叠层一致。
        TextField(placeholder, text: text)
            .font(.subheadline)
            .tint(.primary)
            .focused($focusedField, equals: focus)
            .textFieldStyle(.plain)
            .frame(height: 44)
            .padding(.horizontal, 12)
            .background(Color(UIColor.systemBackground).opacity(0.66))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.07),
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 建议列表显示条件：目的地字段聚焦、尚未选定结构化结果、文本非空、且有候选。
    /// 选定后（resolvedPrimary 非 nil）即收起，避免选完又弹回；失焦也收起。
    private var showDestinationSuggestions: Bool {
        focusedField == .destinationCity &&
        resolvedPrimary == nil &&
        !destinationCity.trimmingCharacters(in: .whitespaces).isEmpty &&
        !destinationCompleter.results.isEmpty
    }

    /// 目的地候选列表（最多 5 条，匹配表单卡片观感）。行是 plain Button——与本页 Dates 按钮同构、
    /// 不受根 ZStack 的 .simultaneousGesture 影响（那个问题只在 List 行内按钮出现，VStack 内 Button 正常）。
    private var destinationSuggestionList: some View {
        VStack(spacing: 0) {
            ForEach(Array(destinationCompleter.results.prefix(5).enumerated()), id: \.element.id) { index, result in
                if index > 0 {
                    Divider().padding(.leading, 12)
                }
                Button {
                    selectDestination(result)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(UIColor.systemBackground).opacity(0.66))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.07),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if isResolvingDestination {
                ZStack {
                    Color(UIColor.systemBackground).opacity(0.5)
                    ProgressView()
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .disabled(isResolvingDestination)
    }

    /// 选中一条建议：解析其权威国家码 + 坐标并暂存。先写 resolvedPrimary 再写文本，
    /// 让 onChange 看到「文本==所选名 且 已选定」→ 不再触发检索、列表收起。解析失败则保持自由文本不强改。
    private func selectDestination(_ suggestion: PlaceSuggestion) {
        isResolvingDestination = true
        Task {
            let resolved = await destinationCompleter.resolve(suggestion)
            await MainActor.run {
                isResolvingDestination = false
                guard let resolved else { return }   // 网络/上游失败 → 维持用户已输入文本，走文本兜底路径
                resolvedPrimary = resolved
                destinationCity = resolved.name
                destinationCompleter.results = []
                hideKeyboard()                        // 选定即完成该字段、收键盘（非预编辑态，安全）
            }
        }
    }

    private func fieldGroup<Content: View>(
        label: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary.opacity(0.86))
                .kerning(1.5)
                .textCase(.uppercase)
                .padding(.horizontal, 16)
            content()
                .padding(.horizontal, 16)
        }
    }
}

#Preview {
    TripInfoView()
        .environmentObject(NavigationRouter())
}

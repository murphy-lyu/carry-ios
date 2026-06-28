//
//  TripInfoView.swift
//  Carry
//

import SwiftUI
import UIKit

struct TripInfoView: View {

    let routeID: UUID?
    @State private var tripName: String
    /// 多目的地：已选/已输入的有序目的地 chip（首=主，其余=additionalDestinations）。
    @State private var destinations: [ResolvedDestination] = []
    /// 目的地输入框当前未提交文本（与 chips 一起组装成 destinationCity）。
    @State private var destinationText: String = ""
    @State private var departureDate: Date
    @State private var returnDate: Date
    @State private var showDatePicker = false
    /// 下滑/取消时若已有草稿，弹「放弃更改?」确认（对齐 Apple 新建表单范式）。
    @State private var showDiscardConfirm = false
    /// 是否设置了日期。预填默认 true；点「无需日期」清除则为 false（→ 规划中行程）。
    @State private var hasDates = true
    /// 防快速双击重复建行程（一击即建、无中间步，必须自守）。
    @State private var isCreating = false
    // 名称输入框（IMESafeTextField）焦点：必须用普通 @State Bool，不能用 @FocusState。
    // IMESafeTextField 持有 UITextField、无法挂 .focused()，@FocusState 因无所有者会被 SwiftUI
    // 持续重置为 false → 每敲一字 updateUIView 误 resignFirstResponder 收键盘（见 commit a24cd03）。
    @State private var nameFieldFocused: Bool = false
    @EnvironmentObject var router: NavigationRouter
    @EnvironmentObject var store: TripStore
    @Environment(\.colorScheme) private var colorScheme


    init(routeID: UUID? = nil) {
        self.routeID = routeID
        let initial = TripInfo()
        _tripName = State(initialValue: initial.name)
        _departureDate = State(initialValue: initial.departureDate)
        _returnDate = State(initialValue: initial.returnDate)
    }

    /// 目的地是否已填（任一 chip 或残留输入文本）。
    private var hasDestination: Bool {
        !destinations.isEmpty || !destinationText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canContinue: Bool {
        !tripName.trimmingCharacters(in: .whitespaces).isEmpty && hasDestination
    }

    /// 是否已填了内容（名字或城市）。日期是预填默认值，不算草稿。
    /// 有草稿时下滑被拦、取消需确认，避免误删；空表单则可直接关闭。
    private var hasDraft: Bool {
        !tripName.trimmingCharacters(in: .whitespaces).isEmpty || hasDestination
    }

    /// 全部目的地（chips + 残留输入文本作一个未解析 chip），大小写不敏感去重、保持顺序。
    /// 单一真源：destinationCity 文本与传给 store 的结构化数组都由它派生，保证一致。
    private var allChips: [ResolvedDestination] {
        DestinationComposer.allChips(destinations, pendingText: destinationText)
    }

    /// chips 显示名用 ` & ` 拼接 → Trip 卡片/通知/分享展示用的字符串真相（与 splitCities 可逆）。
    private var composedDestinationCity: String {
        allChips.map(\.name).joined(separator: " & ")
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
        TripInfo(
            name: tripName,
            destinationCity: composedDestinationCity,
            departureDate: departureDate,
            returnDate: returnDate,
            isDateless: !hasDates,
            resolvedDestinations: allChips
        )
    }

    private func hideKeyboard() {
        nameFieldFocused = false
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

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {

                    heroSection

                    fieldGroup(label: "Trip Name") {
                        stableField("e.g. Italy · Tuscany", text: $tripName)
                    }

                    fieldGroup(label: "Destination City") {
                        DestinationChipsField(
                            destinations: $destinations,
                            text: $destinationText,
                            placeholder: "e.g. Florence"
                        )
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
        .onAppear {
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
        text: Binding<String>
    ) -> some View {
        // 用 IMESafeTextField（替代原生 TextField）：与目的地字段同款，修复微信等第三方输入法
        // 选词上屏后 text binding 不更新的缺陷（见 ViewModifiers.swift 的 IMESafeTextField）。
        // 占位符由 SwiftUI overlay 渲染、空文本时显示，颜色用 .secondary，与目的地/搜索框统一。
        // 焦点用普通 @State Bool（nameFieldFocused），不可用 @FocusState（见其声明处注释 / commit a24cd03）。
        IMESafeTextField(
            text: text,
            font: .preferredFont(forTextStyle: .subheadline),
            returnKeyType: .done,
            isFocused: $nameFieldFocused
        )
            .frame(height: 44)
            .padding(.horizontal, 12)
            .overlay(alignment: .leading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .allowsHitTesting(false)
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

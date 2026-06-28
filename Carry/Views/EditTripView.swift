//
//  EditTripView.swift
//  Carry
//

import SwiftUI
import UIKit

struct EditTripView: View {

    let tripId: UUID

    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss

    @State private var info: TripInfo
    /// 多目的地：从既有行程回填的有序 chip（首=主，其余=additionalDestinations）。
    @State private var destinations: [ResolvedDestination] = []
    /// 目的地输入框当前未提交文本。
    @State private var destinationText: String = ""
    /// 回填只做一次（onAppear），避免重渲染时覆盖用户编辑。
    @State private var didBackfill = false
    @State private var isSaved = false
    @State private var showDatePicker = false
    // 名称输入框（IMESafeTextField）焦点：必须用普通 @State Bool，不能用 @FocusState。
    // IMESafeTextField 持有 UITextField、无法挂 .focused()，@FocusState 因无所有者会被 SwiftUI
    // 持续重置为 false → 每敲一字 updateUIView 误 resignFirstResponder 收键盘（见 commit a24cd03）。
    @State private var nameFieldFocused: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    init(trip: TripBundle) {
        self.tripId = trip.id
        let returnDate = Calendar.current.date(byAdding: .day, value: trip.days, to: trip.departureDate) ?? trip.departureDate
        _info = State(initialValue: TripInfo(
            name: trip.name,
            destinationCity: trip.destinationCity,
            departureDate: trip.departureDate,
            returnDate: returnDate,
            isDateless: trip.isDateless
        ))
    }

    /// 目的地是否已填（任一 chip 或残留输入文本）。
    private var hasDestination: Bool {
        !destinations.isEmpty || !destinationText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canSave: Bool {
        !info.name.trimmingCharacters(in: .whitespaces).isEmpty && hasDestination
    }

    /// 全部目的地（chips + 残留输入文本作一个未解析 chip），去重、保持顺序——单一真源。
    private var allChips: [ResolvedDestination] {
        DestinationComposer.allChips(destinations, pendingText: destinationText)
    }

    /// chips 显示名用 ` & ` 拼接 → destinationCity 字符串真相（与 splitCities 可逆）。
    private var composedDestinationCity: String {
        allChips.map(\.name).joined(separator: " & ")
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
        NavigationStack {
            ZStack {
                Color(UIColor.systemBackground)
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        heroSection

                        fieldGroup(label: "Trip Name") {
                            stableField("e.g. Italy · Tuscany", text: $info.name)
                        }

                        fieldGroup(label: "Destination City") {
                            DestinationChipsField(
                                destinations: $destinations,
                                text: $destinationText,
                                placeholder: "e.g. Florence"
                            )
                        }

                        fieldGroup(label: "Dates") {
                            if info.isDateless {
                                // 无日期态：点此设置日期即转正为普通行程。
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
                            } else {
                                Button { showDatePicker = true } label: {
                                    HStack(spacing: 0) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Departure")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary.opacity(0.82))
                                            Text(info.departureDate.formatted(date: .long, time: .omitted))
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
                                            Text(info.returnDate.formatted(date: .long, time: .omitted))
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
                            }
                        }

                    }
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                TapGesture().onEnded {
                    hideKeyboard()
                }
            )
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // 回填只做一次：把既有行程的目的地文本 + 已存结构化码重建成 chips。
                guard !didBackfill else { return }
                destinations = store.resolvedDestinations(forTripId: tripId)
                didBackfill = true
            }
            .sheet(isPresented: $showDatePicker) {
                TripDateRangePickerSheet(
                    departure: info.departureDate,
                    return: info.returnDate,
                    onSkipDates: { info.isDateless = true }   // 选择器内「暂不设置日期」→ 退回规划中
                ) { start, end in
                    info.departureDate = start
                    info.returnDate = max(end, Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start)
                    info.isDateless = false   // 选定日期即转正为普通行程
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        CarryLogger.shared.log(.tripEditCancelled)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        guard !isSaved else { return }
                        hideKeyboard()
                        var out = info
                        out.destinationCity = composedDestinationCity
                        out.resolvedDestinations = allChips
                        store.updateTripInfo(tripId: tripId, info: out)
                        CarryLogger.shared.log(.tripEditSaved)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        withAnimation(.easeInOut(duration: 0.2)) { isSaved = true }
                        Task {
                            try? await Task.sleep(for: .milliseconds(600))
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isSaved {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .transition(.scale.combined(with: .opacity))
                            }
                            Text(LocalizedStringKey(isSaved ? "Saved" : "Save"))
                                .transition(.opacity)
                        }
                        .animation(.easeInOut(duration: 0.2), value: isSaved)
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave || isSaved)
                }
            }
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit trip")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text("Update trip details without changing your list structure")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.86))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
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
    let trip = TripBundle(name: "Tokyo", destinationCity: "Tokyo", days: 6, departureDate: Date())
    EditTripView(trip: trip)
        .environmentObject(TripStore())
}

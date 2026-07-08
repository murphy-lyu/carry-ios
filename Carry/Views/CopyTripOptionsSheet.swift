//
//  CopyTripOptionsSheet.swift
//  Carry
//
//  「复制行程」轻量弹层：新行程名称（预填原名，不自动加后缀）+ 新日期 +
//  要不要带上打包清单（默认不带，不同季节物品往往不同）+ 要不要带上交通/住宿具体预订信息（默认不带）。
//  行程规划的地点安排始终保留、不作为选项（spec: copy-trip-options.md）。
//  视觉对齐 EditTripView 的「创建/编辑行程」描边卡片语言（hero + fieldGroup + 边框主导容器），
//  不用原生 Form/Section 列表样式——这是一次迷你的创建流程，不是单字段快速操作（用户反馈）。
//

import SwiftUI

struct CopyTripOptionsSheet: View {
    let trip: TripBundle
    /// 复制成功后回调（新行程 id），由调用方负责关闭本 sheet + 后续导航/高亮。
    var onCompleted: (UUID) -> Void

    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    /// 预填原行程名称，不自动加"（副本）"后缀——改不改由用户自己决定（用户反馈）。
    @State private var name: String
    @State private var departureDate: Date
    @State private var returnDate: Date
    @State private var isDateless: Bool
    @State private var includeTransportAndLodging = false
    /// 默认不带打包清单——不同季节/行程物品往往不同，交给用户重新规划更合理（用户反馈）。
    @State private var includePackingList = false
    @State private var showDatePicker = false
    // 名称输入框（IMESafeTextField）焦点：与 EditTripView 同款，必须用普通 @State Bool，不能用 @FocusState
    // （IMESafeTextField 持有 UITextField、@FocusState 因无所有者会被 SwiftUI 持续重置，见 commit a24cd03）。
    @State private var nameFieldFocused: Bool = false

    init(trip: TripBundle, onCompleted: @escaping (UUID) -> Void) {
        self.trip = trip
        self.onCompleted = onCompleted
        let ret = Calendar.current.date(byAdding: .day, value: trip.days, to: trip.departureDate) ?? trip.departureDate
        _name = State(initialValue: trip.name)
        _departureDate = State(initialValue: trip.departureDate)
        _returnDate = State(initialValue: ret)
        _isDateless = State(initialValue: trip.isDateless)
    }

    private var canConfirm: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
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

                        fieldGroup(label: "trip.copy.name_section") {
                            nameField
                        }

                        fieldGroup(label: "trip.copy.date_section") {
                            dateField
                        }

                        toggleCard(
                            title: "trip.copy.include_transport_lodging",
                            footer: "trip.copy.include_transport_lodging.footer",
                            isOn: $includeTransportAndLodging
                        )
                        .padding(.horizontal, 16)

                        toggleCard(
                            title: "trip.copy.include_packing_list",
                            footer: "trip.copy.include_packing_list.footer",
                            isOn: $includePackingList
                        )
                        .padding(.horizontal, 16)
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: confirm) {
                        Text("trip.copy.confirm").fontWeight(.semibold)
                    }
                    .disabled(!canConfirm)
                }
            }
            .sheet(isPresented: $showDatePicker) {
                TripDateRangePickerSheet(
                    departure: departureDate,
                    return: returnDate,
                    onSkipDates: { isDateless = true }
                ) { start, end in
                    departureDate = start
                    returnDate = max(end, Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start)
                    isDateless = false
                }
            }
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("trip.copy.title")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text("trip.copy.subtitle")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.86))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var nameField: some View {
        // 与 EditTripView 同款 IMESafeTextField：修复微信等第三方输入法选词上屏后 text binding 不更新的缺陷。
        IMESafeTextField(
            text: $name,
            font: .preferredFont(forTextStyle: .subheadline),
            returnKeyType: .done,
            isFocused: $nameFieldFocused
        )
            .frame(height: 44)
            .padding(.horizontal, 12)
            .overlay(alignment: .leading) {
                if name.isEmpty {
                    Text("trip.copy.name_placeholder")
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

    @ViewBuilder
    private var dateField: some View {
        if isDateless {
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
                        Text(departureDate.formatted(date: .abbreviated, time: .omitted))
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
                        Text(returnDate.formatted(date: .abbreviated, time: .omitted))
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
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.07), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func toggleCard(
        title: LocalizedStringKey,
        footer: LocalizedStringKey,
        isOn: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .tint(CarryAccent.color)
            }
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.86))
        }
        .padding(14)
        .background(Color(UIColor.systemBackground).opacity(0.64))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.07), lineWidth: 1)
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

    private func confirm() {
        hideKeyboard()
        guard let newId = store.duplicateTrip(
            withId: trip.id,
            includeTransportAndLodging: includeTransportAndLodging,
            includePackingList: includePackingList
        ) else {
            dismiss()
            return
        }
        if let newBundle = store.bundle(for: newId) {
            let info = TripInfo(
                name: name.trimmingCharacters(in: .whitespaces),
                destinationCity: newBundle.destinationCity,
                departureDate: departureDate,
                returnDate: returnDate,
                isDateless: isDateless
            )
            store.updateTripInfo(tripId: newId, info: info)
        }
        onCompleted(newId)
    }
}

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
struct FormChip: View {
    let text: String
    var filled: Bool = true

    var body: some View {
        Text(text)
            .font(.system(.subheadline, design: .rounded).weight(.medium))
            .foregroundStyle(filled ? Color.primary : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(.tertiarySystemFill))
            .clipShape(Capsule())
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

    @Environment(\.dismiss) private var dismiss

    @State private var draft: Date
    private let wasSet: Bool

    init(hasTime: Binding<Bool>, time: Binding<Date>) {
        _hasTime = hasTime
        _time = time
        _draft = State(initialValue: time.wrappedValue)
        wasSet = hasTime.wrappedValue
    }

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
        }
        .presentationDetents([.height(360)])
    }
}

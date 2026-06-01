import SwiftUI

/// 设置 →「通知」二级页。首版仅「一般旅行提醒」组：用户选择新建行程的默认提醒
/// 档位（开关）。该选择仅作用于"之后新建"的行程（创建时快照进行程），每个行程
/// 仍可在物品清单里单独增删提醒、互不影响。未来航班 / 协作等通知场景在此页按分组扩展。
struct NotificationSettingsView: View {
    @AppStorage(ReminderPreferences.storageKey) private var offsetsRaw = "0,1"
    @AppStorage(ReminderPreferences.timeKey) private var defaultMinutes = 540  // 09:00
    @Environment(\.colorScheme) private var colorScheme

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(hour: defaultMinutes / 60, minute: defaultMinutes % 60)) ?? Date()
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                defaultMinutes = (c.hour ?? 9) * 60 + (c.minute ?? 0)
            }
        )
    }

    private var cardFill: Color {
        colorScheme == .dark
            ? Color(UIColor.secondarySystemGroupedBackground).opacity(0.72)
            : Color(UIColor.secondarySystemGroupedBackground)
    }

    private var cardStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.045)
            : Color.primary.opacity(0.05)
    }

    private var enabled: Set<Int> {
        Set(offsetsRaw.split(separator: ",").compactMap { Int($0) })
    }

    private func setOn(_ days: Int, _ on: Bool) {
        var set = enabled
        if on { set.insert(days) } else { set.remove(days) }
        offsetsRaw = set.sorted().map(String.init).joined(separator: ",")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                VStack(alignment: .leading, spacing: 8) {
                    Text("settings.notifications.section.general")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .kerning(0.4)
                        .padding(.horizontal, 4)

                    VStack(spacing: 0) {
                        // 全局默认提醒时间：下方所有档位统一用它（per-trip 仍可逐条覆盖）
                        HStack(spacing: 12) {
                            Text("settings.notifications.time")
                                .font(.body)
                                .foregroundStyle(.primary)
                            Spacer()
                            DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                        .padding(.horizontal, 18)
                        .frame(height: 58)

                        Divider().padding(.leading, 18)

                        ForEach(Array(TripReminderConfig.presets.enumerated()), id: \.element.daysBeforeDeparture) { index, preset in
                            HStack(spacing: 12) {
                                Text(preset.localizedLabel)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { enabled.contains(preset.daysBeforeDeparture) },
                                    set: { setOn(preset.daysBeforeDeparture, $0) }
                                ))
                                .labelsHidden()
                                .tint(Color.accentColor)
                            }
                            .padding(.horizontal, 18)
                            .frame(height: 58)

                            if index < TripReminderConfig.presets.count - 1 {
                                Divider().padding(.leading, 18)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(cardFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(cardStroke, lineWidth: 1)
                            )
                    )

                    Text("settings.notifications.footer")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .lineSpacing(1.4)
                        .padding(.horizontal, 4)
                }

            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(Text("settings.notifications.entry"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}

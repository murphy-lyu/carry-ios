import SwiftUI
import UserNotifications

/// 设置 →「行程提醒」二级页 = 通知中心（spec: notification-center.md）。
/// 按类型分组、每类是一条全局规则、自动套到所有行程/事件；改任一项即 `rescheduleAllTrips`。
/// Settings 为唯一真相源（无 per-trip 快照；逐航班/住宿静音在各自详情页就近放）。
struct NotificationSettingsView: View {
    @EnvironmentObject private var store: TripStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    // 出发提醒（A）
    @AppStorage(ReminderPreferences.departureEnabledKey) private var departureEnabled = true
    @AppStorage(ReminderPreferences.storageKey) private var offsetsRaw = "0,1"
    @AppStorage(ReminderPreferences.timeKey) private var departureMinutes = 540
    // 打包进度（A）
    @AppStorage(ReminderPreferences.packProgressEnabledKey) private var packEnabled = true
    @AppStorage(ReminderPreferences.packProgressOffsetKey) private var packOffsetDays = 1
    @AppStorage(ReminderPreferences.packMinutesKey) private var packMinutes = 1260  // 21:00 独立时间
    // 交通（B）
    @AppStorage(ReminderPreferences.transportEnabledKey) private var transportEnabled = true
    @AppStorage(ReminderPreferences.transportLeadsKey) private var transportLeadsRaw = "180"
    // 还车（B，默认关；只还车、取车不提醒）
    @AppStorage(ReminderPreferences.carRentalEnabledKey) private var carRentalEnabled = false
    @AppStorage(ReminderPreferences.carRentalLeadsKey) private var carRentalLeadsRaw = "60"
    // 退房（C，默认关；只退房、入住不提醒；退房当天清晨固定时刻）
    @AppStorage(ReminderPreferences.lodgingEnabledKey) private var lodgingEnabled = false
    @AppStorage(ReminderPreferences.lodgingCheckOutMinKey) private var lodgingCheckOutMin = 660
    // 每日摘要（C，默认关）
    @AppStorage(ReminderPreferences.dailySummaryEnabledKey) private var dailyEnabled = false
    @AppStorage(ReminderPreferences.dailySummaryMinKey) private var dailyMinutes = 540

    @AppStorage(ReminderPreferences.weatherAlertsEnabledKey) private var weatherAlertsEnabled = true

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    private var notificationsBlocked: Bool { notificationStatus == .denied }

    // MARK: 样式
    private var cardFill: Color {
        colorScheme == .dark ? Color(UIColor.secondarySystemGroupedBackground).opacity(0.72)
                             : Color(UIColor.secondarySystemGroupedBackground)
    }
    private var cardStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.045) : Color.primary.opacity(0.05)
    }

    private func minutesBinding(_ value: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(from: DateComponents(hour: value.wrappedValue / 60, minute: value.wrappedValue % 60)) ?? Date() },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                value.wrappedValue = (c.hour ?? 9) * 60 + (c.minute ?? 0)
                store.rescheduleAllTrips()
            }
        )
    }

    private func refreshStatus() async { notificationStatus = await NotificationManager.authorizationStatus() }
    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: Body
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                permissionBanner

                departureSection
                packSection
                transportSection
                carRentalSection
                lodgingSection
                dailySection
                weatherAlertsSection

                Text("settings.notif.footer")
                    .font(.footnote).foregroundStyle(.tertiary).lineSpacing(1.4)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
            .opacity(notificationsBlocked ? 0.5 : 1)
            .disabled(notificationsBlocked)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(Text("settings.notifications.entry"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task { await refreshStatus() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refreshStatus() } } }
    }

    // MARK: 分组卡片骨架
    @ViewBuilder
    private func sectionCard<Content: View>(_ titleKey: LocalizedStringKey, subtitle: LocalizedStringKey?,
                                            isOn: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(titleKey).font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Toggle("", isOn: isOn).labelsHidden().tint(CarryAccent.color)
                    .onChange(of: isOn.wrappedValue) { _, _ in store.rescheduleAllTrips() }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            if isOn.wrappedValue {
                Divider().padding(.leading, 16)
                content().padding(.horizontal, 16).padding(.vertical, 4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(cardFill)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(cardStroke, lineWidth: 1))
        )
    }

    // MARK: 出发提醒（A）
    private var departureSection: some View {
        sectionCard("settings.notif.departure.title", subtitle: "settings.notif.departure.subtitle", isOn: $departureEnabled) {
            VStack(spacing: 0) {
                timeRow("settings.notifications.time", binding: minutesBinding($departureMinutes))
                ForEach(TripReminderConfig.presets, id: \.daysBeforeDeparture) { preset in
                    Divider()
                    HStack {
                        Text(preset.localizedLabel).font(.body)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { enabledOffsets.contains(preset.daysBeforeDeparture) },
                            set: { setOffset(preset.daysBeforeDeparture, $0) }
                        )).labelsHidden().tint(CarryAccent.color)
                    }
                    .frame(height: 50)
                }
            }
        }
    }

    private var enabledOffsets: Set<Int> { Set(offsetsRaw.split(separator: ",").compactMap { Int($0) }) }
    private func setOffset(_ day: Int, _ on: Bool) {
        var s = enabledOffsets
        if on { s.insert(day) } else { s.remove(day) }
        offsetsRaw = s.sorted().map(String.init).joined(separator: ",")
        store.rescheduleAllTrips()
    }

    // MARK: 打包进度（A）
    private var packSection: some View {
        // 打包有自己的时间（默认出发前一晚 20:00），与出发提醒分开。
        sectionCard("settings.notif.pack.title", subtitle: "settings.notif.pack.subtitle", isOn: $packEnabled) {
            VStack(spacing: 0) {
                timeRow("settings.notifications.time", binding: minutesBinding($packMinutes))
                Divider()
                HStack {
                    Text("settings.notif.pack.when").font(.body)
                    Spacer()
                    Picker("", selection: Binding(get: { packOffsetDays }, set: { packOffsetDays = $0; store.rescheduleAllTrips() })) {
                        ForEach([0, 1, 2, 3], id: \.self) { d in Text(offsetLabel(d)).tag(d) }
                    }.labelsHidden().tint(CarryAccent.color)
                }.frame(height: 50)
            }
        }
    }

    // MARK: 交通（B）
    private var transportSection: some View {
        sectionCard("settings.notif.transport.title", subtitle: "settings.notif.transport.subtitle", isOn: $transportEnabled) {
            LeadListEditor(leadsRaw: $transportLeadsRaw, onChange: { store.rescheduleAllTrips() })
        }
    }
    private var carRentalSection: some View {
        sectionCard("settings.notif.carrental.title", subtitle: "settings.notif.carrental.subtitle", isOn: $carRentalEnabled) {
            LeadListEditor(leadsRaw: $carRentalLeadsRaw, onChange: { store.rescheduleAllTrips() })
        }
    }

    // MARK: 住宿（B）
    private var lodgingSection: some View {
        // 只「退房」提醒（入住不提醒）。退房当天清晨固定时刻（晨间唤醒，非提前量倒计时）。
        sectionCard("settings.notif.lodging.title", subtitle: "settings.notif.lodging.subtitle", isOn: $lodgingEnabled) {
            timeRow("settings.notifications.time", binding: minutesBinding($lodgingCheckOutMin))
        }
    }

    // MARK: 每日摘要（C）
    private var dailySection: some View {
        sectionCard("settings.notif.daily.title", subtitle: "settings.notif.daily.subtitle", isOn: $dailyEnabled) {
            timeRow("settings.notif.daily.time", binding: minutesBinding($dailyMinutes))
        }
    }

    // MARK: 天气提醒（spec: weather-aware-packing.md, Part 2）——例外驱动、平时不响
    private var weatherAlertsSection: some View {
        sectionCard("settings.notif.weather.title", subtitle: "settings.notif.weather.subtitle", isOn: $weatherAlertsEnabled) {
            Text("settings.notif.weather.note")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
        }
    }

    // MARK: 通用行
    private func timeRow(_ titleKey: LocalizedStringKey, binding: Binding<Date>) -> some View {
        HStack {
            Text(titleKey).font(.body)
            Spacer()
            DatePicker("", selection: binding, displayedComponents: .hourAndMinute).labelsHidden()
        }.frame(height: 50)
    }

    private func offsetLabel(_ d: Int) -> String {
        d == 0 ? String(localized: "reminder.label.departureDay")
               : (d == 1 ? String(localized: "reminder.label.oneDayBefore")
                         : String.localizedStringWithFormat(NSLocalizedString("reminder.label.daysBefore", comment: ""), d))
    }

    // MARK: 权限横幅（沿用既有三态）
    @ViewBuilder private var permissionBanner: some View {
        if notificationStatus == .denied || notificationStatus == .notDetermined {
            let denied = notificationStatus == .denied
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: denied ? "bell.slash.fill" : "bell.badge.fill")
                        .font(.system(size: 18)).foregroundStyle(CarryAccent.color).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(denied ? "settings.notifications.permission.denied.title" : "settings.notifications.permission.undetermined.title")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                        Text(denied ? "settings.notifications.permission.denied.subtitle" : "settings.notifications.permission.undetermined.subtitle")
                            .font(.footnote).foregroundStyle(.secondary).lineSpacing(1.4).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                Button {
                    if denied { openNotificationSettings() }
                    else { Task { await NotificationManager.requestAuthorizationIfNeeded(); await refreshStatus() } }
                } label: {
                    Text(denied ? "settings.notifications.permission.denied.button" : "settings.notifications.permission.undetermined.button")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(CarryAccent.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(cardFill)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(cardStroke, lineWidth: 1))
            )
            // 通知被拒时横幅本身不该被禁用/置灰（它是唯一出路）。
            .opacity(1).allowsHitTesting(true)
        }
    }
}

// MARK: - 提前量工具
enum NotifLead {
    /// 可添加的预设提前量（分钟）。
    static let presets: [Int] = [30, 60, 120, 180, 360, 720, 1440, 2880]
    static func text(_ minutes: Int) -> String {
        if minutes == 0 { return String(localized: "notif.lead.atTime") }
        if minutes % 1440 == 0 { return String.localizedStringWithFormat(NSLocalizedString("notif.lead.days", comment: ""), minutes / 1440) }
        if minutes % 60 == 0 { return String.localizedStringWithFormat(NSLocalizedString("notif.lead.hours", comment: ""), minutes / 60) }
        return String.localizedStringWithFormat(NSLocalizedString("notif.lead.minutes", comment: ""), minutes)
    }
}

/// 多档提前量编辑器：列出每条「· X 前」+ 删除，底部「添加提醒时间」选预设。可见可增删（spec 要求）。
private struct LeadListEditor: View {
    @Binding var leadsRaw: String
    var onChange: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var leads: [Int] { Array(Set(leadsRaw.split(separator: ",").compactMap { Int($0) })).sorted(by: >) }
    private func write(_ v: [Int]) {
        leadsRaw = Set(v).sorted(by: >).map(String.init).joined(separator: ",")
        onChange()
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(leads, id: \.self) { lead in
                Divider().opacity(lead == leads.first ? 0 : 1)
                HStack {
                    Text(String(format: NSLocalizedString("settings.notif.lead_before", comment: ""), NotifLead.text(lead)))
                        .font(.body)
                    Spacer()
                    // 至少留一档：开着却没档位 = 什么都不发，反而困惑。最后一档时禁用减号。
                    Button { write(leads.filter { $0 != lead }) } label: {
                        Image(systemName: "minus.circle.fill").font(.system(size: 18))
                            .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.9) : .secondary)
                    }.buttonStyle(.plain)
                    .disabled(leads.count <= 1)
                    .opacity(leads.count <= 1 ? 0.3 : 1)
                }.frame(height: 50)
            }
            Divider()
            Menu {
                ForEach(NotifLead.presets.filter { !leads.contains($0) }, id: \.self) { m in
                    Button(NotifLead.text(m)) { write(leads + [m]) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 15, weight: .semibold))
                    Text("settings.notif.add_lead").font(.body)
                    Spacer()
                }
                .foregroundStyle(CarryAccent.color).frame(height: 50)
            }
            .disabled(NotifLead.presets.allSatisfy { leads.contains($0) })
        }
    }
}

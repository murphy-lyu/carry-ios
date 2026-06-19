import SwiftUI
import UserNotifications

/// 设置 →「通知」二级页。首版仅「一般旅行提醒」组：用户选择新建行程的默认提醒
/// 档位（开关）。该选择仅作用于"之后新建"的行程（创建时快照进行程），每个行程
/// 仍可在物品清单里单独增删提醒、互不影响。未来航班 / 协作等通知场景在此页按分组扩展。
struct NotificationSettingsView: View {
    @AppStorage(ReminderPreferences.storageKey) private var offsetsRaw = "0,1"
    @AppStorage(ReminderPreferences.timeKey) private var defaultMinutes = 540  // 09:00
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    /// 系统通知授权态。`.denied` → 这里所有档位都形同虚设（通知发不出去），必须给用户一条出路。
    /// 在 `.task` 与「从系统设置返回前台」时刷新，让横幅随真实授权态出现/消失。
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    private var notificationsBlocked: Bool { notificationStatus == .denied }

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

    private func refreshStatus() async {
        notificationStatus = await NotificationManager.authorizationStatus()
    }

    /// 深链到本 App 的系统通知设置页（iOS 16+，比通用设置页更直达）。
    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// 授权态横幅：仅在「已拒绝 / 未设置」时出现，给被首次引导漏掉授权的用户一条出路。
    /// - 已拒绝 → 深链系统设置（系统不再二次弹窗，只能去设置开）。
    /// - 未设置 → 应用内直接请求授权（补回「首次没看到 / 划掉」的场景）。
    /// 已授权则整块不渲染，页面回到纯净的提醒配置。
    @ViewBuilder
    private var permissionBanner: some View {
        if notificationStatus == .denied || notificationStatus == .notDetermined {
            let denied = notificationStatus == .denied
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: denied ? "bell.slash.fill" : "bell.badge.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(CarryAccent.color)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(denied ? "settings.notifications.permission.denied.title"
                                    : "settings.notifications.permission.undetermined.title")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(denied ? "settings.notifications.permission.denied.subtitle"
                                    : "settings.notifications.permission.undetermined.subtitle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineSpacing(1.4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                Button {
                    if denied {
                        openNotificationSettings()
                    } else {
                        Task { await NotificationManager.requestAuthorizationIfNeeded(); await refreshStatus() }
                    }
                } label: {
                    Text(denied ? "settings.notifications.permission.denied.button"
                                : "settings.notifications.permission.undetermined.button")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(CarryAccent.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(cardStroke, lineWidth: 1)
                    )
            )
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                permissionBanner

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
                                .accessibilityLabel(Text("settings.notifications.time"))
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
                                .tint(CarryAccent.color)
                                .accessibilityLabel(Text(preset.localizedLabel))
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
                    // 通知被拒时这些档位发不出通知 → 置灰 + 禁用，把「去开通知」引导给上方横幅。
                    .opacity(notificationsBlocked ? 0.5 : 1)
                    .disabled(notificationsBlocked)

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
        .task { await refreshStatus() }
        // 用户去系统设置改了授权回到 App → 重读，让横幅 / 置灰随真实态更新。
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshStatus() } }
        }
    }
}

import SwiftUI

/// 「经期打包提醒」设置页：用户主动开启后，新建行程时若预测行程赶上经期，
/// 会在场景选择里轻推经期场景。健康数据仅本机读取、不存储、不上传（见 CycleInference）。
struct CycleReminderSettingsView: View {
    @AppStorage("cycleNudgeFeatureEnabled") private var isEnabled = false
    @Environment(\.colorScheme) private var colorScheme

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // MARK: 经期提醒分组
                VStack(alignment: .leading, spacing: 8) {
                    Text("settings.cycle.section.period")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .kerning(0.4)
                        .padding(.horizontal, 4)

                    // 卡片：描述 + 开关
                    VStack(alignment: .leading, spacing: 0) {
                        Text("settings.cycle.description")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineSpacing(1.6)
                            .padding(.horizontal, 18)
                            .padding(.top, 16)
                            .padding(.bottom, 14)

                        Divider()
                            .padding(.horizontal, 18)

                        HStack(spacing: 12) {
                            Text("settings.cycle.toggle")
                                .font(.body)
                                .foregroundStyle(.primary)
                            Spacer()
                            Toggle("", isOn: $isEnabled)
                                .labelsHidden()
                                .tint(CarryAccent.color)
                                .accessibilityLabel(Text("settings.cycle.toggle"))
                        }
                        .padding(.horizontal, 18)
                        .frame(height: 58)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(cardFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(cardStroke, lineWidth: 1)
                            )
                    )

                    Text("settings.cycle.privacy")
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
        .onChange(of: isEnabled) { _, enabled in
            guard enabled else { return }
            // 开启即触发系统授权弹窗。若设备不支持或用户已拒绝，预测层会静默降级，
            // 此处不强行回退开关状态（HealthKit 读权限不可查询，无法可靠判断已授予）。
            Task { await CycleInference.requestAuthorization() }
        }
        .navigationTitle(Text("settings.cycle.entry"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}

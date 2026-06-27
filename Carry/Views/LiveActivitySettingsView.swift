import SwiftUI

#if !targetEnvironment(macCatalyst)
struct LiveActivitySettingsView: View {
    @AppStorage(LiveActivityManager.enabledKey) private var isEnabled = true
    @AppStorage(LiveActivityManager.transitEnabledKey) private var isTransitEnabled = true
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

    private func toggleRow(titleKey: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Text(titleKey)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(CarryAccent.color)
                .accessibilityLabel(Text(titleKey))
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(cardStroke, lineWidth: 1)
                )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Image("LiveActivityPreview")
                    .resizable()
                    .scaledToFit()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.14 : 0.10), radius: 10, x: 0, y: 3)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                Text("settings.liveactivity.description")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(1.6)

                toggleRow(titleKey: "settings.liveactivity.packing", isOn: $isEnabled)
                toggleRow(titleKey: "settings.liveactivity.transit", isOn: $isTransitEnabled)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                // 仅关打包 LA——不可误伤交通 LA（两开关独立）。
                Task { @MainActor in LiveActivityManager.shared.endAllPacking() }
            }
        }
        .onChange(of: isTransitEnabled) { _, enabled in
            if !enabled {
                Task { @MainActor in LiveActivityManager.shared.endTransit() }
            }
        }
        .navigationTitle(Text("settings.liveactivity.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}


#endif

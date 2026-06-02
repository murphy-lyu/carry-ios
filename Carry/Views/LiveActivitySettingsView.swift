import SwiftUI

#if !targetEnvironment(macCatalyst)
struct LiveActivitySettingsView: View {
    @AppStorage("liveActivityPackingEnabled") private var isEnabled = false
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

                HStack(spacing: 12) {
                    Text("settings.liveactivity.packing")
                        .font(.body)
                        .foregroundStyle(.primary)
                    Spacer()
                    Toggle("", isOn: $isEnabled)
                        .labelsHidden()
                        .tint(.blue)
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
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                Task { @MainActor in LiveActivityManager.shared.endAll() }
            }
        }
        .navigationTitle(Text("settings.liveactivity.packing"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}


#endif

import SwiftUI

#if !targetEnvironment(macCatalyst)
struct LiveActivitySettingsView: View {
    @AppStorage("liveActivityPackingEnabled") private var isEnabled = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        List {
            // ── 预览图 + 功能说明（同一 Section，无额外间距）──
            Section {
                ZStack(alignment: .top) {
                    Color(.secondarySystemGroupedBackground)
                    Image("LiveActivityPreview")
                        .resizable()
                        .scaledToFit()
                        .padding(.horizontal, 28)
                        .padding(.bottom, 20)
                        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 4)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 2)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Text("settings.liveactivity.description")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            // ── 开关 ──
            Section {
                Toggle(isOn: $isEnabled) {
                    Text("settings.liveactivity.packing")
                        .font(.body)
                        .foregroundStyle(.primary)
                }
                .tint(colorScheme == .dark ? Color(.systemGray2) : Color(.label))
                .padding(.horizontal, 18)
                .frame(height: 58)
                .listRowInsets(EdgeInsets())
                .onChange(of: isEnabled) { _, enabled in
                    if !enabled {
                        Task { @MainActor in LiveActivityManager.shared.endAll() }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .navigationTitle("settings.liveactivity.packing")
        .navigationBarTitleDisplayMode(.inline)
    }
}


#endif

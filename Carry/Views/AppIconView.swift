//
//  AppIconView.swift
//  Carry
//

import SwiftUI
import UIKit

// MARK: - Icon options
//
// To add a new alternate icon (Asset Catalog approach — single 1024×1024, no @2x/@3x):
//  1. Add a 1024×1024 PNG (NO alpha channel) named e.g. "IconDog.png".
//  2. In Assets.xcassets create "<Name>.appiconset" with a Contents.json that
//     references the PNG as a single 1024x1024 universal/ios image.
//     (INCLUDE_ALL_APPICON_ASSETS = YES auto-registers it as an alternate icon.)
//  3. Add an AppIconOption entry below with id == the appiconset name.
//
// The Asset Catalog name is also the identifier passed to setAlternateIconName.

struct AppIconOption: Identifiable {
    /// Matches the .appiconset name in Assets.xcassets. nil = primary icon.
    let id: String?
    /// Localization key (String, so the name can also be resolved to a plain String
    /// for the Settings row value — LocalizedStringKey can't be read back).
    let nameKey: String
    let descriptionKey: String

    var name: LocalizedStringKey { LocalizedStringKey(nameKey) }
    var description: LocalizedStringKey { LocalizedStringKey(descriptionKey) }

    /// Plain localized name, used by the Settings row to show the current icon.
    var localizedName: String { NSLocalizedString(nameKey, comment: "") }
}

let appIconOptions: [AppIconOption] = [
    AppIconOption(
        id: nil,
        nameKey: "icon.default.name",
        descriptionKey: "icon.default.description"
    ),
    AppIconOption(
        id: "IconCat",
        nameKey: "icon.cat.name",
        descriptionKey: "icon.cat.description"
    ),
    AppIconOption(
        id: "IconDog",
        nameKey: "icon.dog.name",
        descriptionKey: "icon.dog.description"
    ),
]

/// Localized name of the currently active app icon (for the Settings row value).
/// Falls back to the default icon's name if the active id isn't in the list.
func currentAppIconDisplayName() -> String {
    let activeId = UIApplication.shared.alternateIconName
    let match = appIconOptions.first { $0.id == activeId } ?? appIconOptions[0]
    return match.localizedName
}

/// Companion preview-imageset name of the currently active app icon (same artwork
/// as the selected icon). Used by SplashView so the splash logo matches the icon
/// the user picked. Mirrors `iconPreview(for:)` naming: "<id>Preview" / "IconDefaultPreview".
func currentAppIconPreviewName() -> String {
    (UIApplication.shared.alternateIconName ?? "IconDefault") + "Preview"
}

// MARK: - AppIconView

struct AppIconView: View {

    @Environment(\.colorScheme) private var colorScheme
    @State private var currentIconName: String? = UIApplication.shared.alternateIconName
    @State private var isChanging = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader
                iconList
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("icon.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Section header

    private var sectionHeader: some View {
        Text("icon.section.header")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(colorScheme == .dark
                ? Color.secondary.opacity(0.65)
                : Color(UIColor.tertiaryLabel))
            .kerning(1.5)
            .textCase(.uppercase)
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 8)
    }

    // MARK: Icon list card

    private var iconList: some View {
        VStack(spacing: 0) {
            ForEach(Array(appIconOptions.enumerated()), id: \.element.id) { index, option in
                iconRow(option: option, isLast: index == appIconOptions.count - 1)
            }
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(cardStroke, lineWidth: 1)
        )
        .shadow(color: cardShadow, radius: colorScheme == .dark ? 8 : 10,
                x: 0, y: colorScheme == .dark ? 3 : 5)
    }

    @ViewBuilder
    private func iconRow(option: AppIconOption, isLast: Bool) -> some View {
        let isSelected = option.id == currentIconName

        Button {
            guard !isSelected, !isChanging else { return }
            switchIcon(to: option.id)
        } label: {
            HStack(spacing: 14) {
                iconPreview(for: option)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(option.description)
                        .font(.caption)
                        .foregroundStyle(colorScheme == .dark
                            ? Color.secondary.opacity(0.78)
                            : .secondary)
                        // 恒单行：窄机型/大字号下极轻微缩字以容纳，不换行、不截断。
                        // （根因——选中时多出的对勾会挤窄文案宽度，单行文案才不会「选中即换行」。）
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Spacer(minLength: 8)

                // 对勾位置**恒定预留**（选中可见、未选中透明占位），故选中/未选中布局完全一致、
                // 不再因选中而重排把副标题挤换行。淡入淡出由下方 .animation(value: isSelected) 驱动。
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)   // 选中态由 .isSelected 传达
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])

        if !isLast {
            Divider()
                .padding(.leading, 78)
        }
    }

    // MARK: Icon thumbnail
    //
    // Shows the actual icon image once the PNG file is added to the project.
    // Falls back to a placeholder until then.

    @ViewBuilder
    private func iconPreview(for option: AppIconOption) -> some View {
        let size: CGFloat = 52
        // iOS forbids loading app-icon assets via UIImage(named:), so each icon has a
        // companion "<id>Preview" imageset (same artwork) used purely for this thumbnail.
        let imageName = (option.id ?? "IconDefault") + "Preview"

        if let uiImage = UIImage(named: imageName) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        } else {
            // Placeholder shown until icon files are added
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(placeholderFill)
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "suitcase.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        }
    }

    /// Neutral gradient shown only if a preview image can't be resolved.
    private var placeholderFill: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.80, green: 0.80, blue: 0.82),
                     Color(red: 0.68, green: 0.68, blue: 0.70)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Switch logic

    private func switchIcon(to iconName: String?) {
        isChanging = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        UIApplication.shared.setAlternateIconName(iconName) { error in
            DispatchQueue.main.async {
                isChanging = false
                if let error {
                    CarryLogger.shared.log(.iconSwitchFailed,
                        context: "icon=\(iconName ?? "default") error=\(error.localizedDescription)")
                } else {
                    withAnimation {
                        currentIconName = iconName
                    }
                    CarryLogger.shared.log(.iconSwitched,
                        context: "icon=\(iconName ?? "default")")
                }
            }
        }
    }

    // MARK: Styling

    private var cardFill: some ShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(Color(UIColor.secondarySystemBackground).opacity(0.76))
        } else {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(UIColor.systemBackground).opacity(0.94),
                        Color(UIColor.systemBackground).opacity(0.82),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private var cardStroke: Color {
        colorScheme == .dark ? .white.opacity(0.045) : Color.primary.opacity(0.04)
    }

    private var cardShadow: Color {
        colorScheme == .dark ? .black.opacity(0.18) : .black.opacity(0.022)
    }
}

#Preview {
    NavigationStack {
        AppIconView()
    }
}

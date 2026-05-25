//
//  AppIconView.swift
//  Carry
//

import SwiftUI
import UIKit

// MARK: - Icon options
//
// To add a new icon:
//  1. Design a 1024×1024 PNG named e.g. "CarryIconDark.png"
//  2. Add the file to Xcode project root (NOT inside Assets.xcassets),
//     make sure "Copy Bundle Resources" is checked in Build Phases.
//  3. Declare it in Info.plist under CFBundleIcons → CFBundleAlternateIcons.
//  4. Add a new AppIconOption entry below with the matching iconName.

struct AppIconOption: Identifiable {
    /// Matches CFBundleAlternateIcons key in Info.plist. nil = primary icon.
    let id: String?
    let name: LocalizedStringKey
    let description: LocalizedStringKey
}

private let iconOptions: [AppIconOption] = [
    AppIconOption(
        id: nil,
        name: "icon.default.name",
        description: "icon.default.description"
    ),
    AppIconOption(
        id: "IconDark",
        name: "icon.dark.name",
        description: "icon.dark.description"
    ),
    AppIconOption(
        id: "IconLight",
        name: "icon.light.name",
        description: "icon.light.description"
    ),
    AppIconOption(
        id: "IconPride",
        name: "icon.pride.name",
        description: "icon.pride.description"
    ),
    AppIconOption(
        id: "IconSoft",
        name: "icon.soft.name",
        description: "icon.soft.description"
    ),
    AppIconOption(
        id: "IconPink",
        name: "icon.pink.name",
        description: "icon.pink.description"
    ),
    AppIconOption(
        id: "IconBlue",
        name: "icon.blue.name",
        description: "icon.blue.description"
    ),
    AppIconOption(
        id: "IconOrange",
        name: "icon.orange.name",
        description: "icon.orange.description"
    ),
    AppIconOption(
        id: "IconButter",
        name: "icon.butter.name",
        description: "icon.butter.description"
    ),
    AppIconOption(
        id: "IconGreen",
        name: "icon.green.name",
        description: "icon.green.description"
    ),
    AppIconOption(
        id: "HandDrawn",
        name: "icon.handdrawn.name",
        description: "icon.handdrawn.description"
    ),
]

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
        .background(CarrySubtleBackground())
        .navigationTitle("icon.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Section header

    private var sectionHeader: some View {
        Text("icon.section.header")
            .font(.system(size: 11, weight: .medium))
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
            ForEach(Array(iconOptions.enumerated()), id: \.element.id) { index, option in
                iconRow(option: option, isLast: index == iconOptions.count - 1)
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
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(option.description)
                        .font(.caption)
                        .foregroundStyle(colorScheme == .dark
                            ? Color.secondary.opacity(0.78)
                            : .secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accentColor)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelected)

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
        let imageName = option.id ?? "IconDark"

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
                .fill(placeholderFill(for: option))
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

    private func placeholderFill(for option: AppIconOption) -> LinearGradient {
        switch option.id {
        case nil:
            return LinearGradient(
                colors: [Color(red: 0.20, green: 0.22, blue: 0.28),
                         Color(red: 0.14, green: 0.16, blue: 0.22)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case "HandDrawn":
            return LinearGradient(
                colors: [Color(red: 0.96, green: 0.92, blue: 0.84),
                         Color(red: 0.82, green: 0.76, blue: 0.66)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case "IconBlue":
            return LinearGradient(
                colors: [Color(red: 0.28, green: 0.56, blue: 0.96),
                         Color(red: 0.14, green: 0.36, blue: 0.80)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case "IconBusiness":
            return LinearGradient(
                colors: [Color(red: 0.18, green: 0.20, blue: 0.24),
                         Color(red: 0.10, green: 0.12, blue: 0.16)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case "IconGreen":
            return LinearGradient(
                colors: [Color(red: 0.28, green: 0.76, blue: 0.48),
                         Color(red: 0.14, green: 0.56, blue: 0.32)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case "IconPink":
            return LinearGradient(
                colors: [Color(red: 0.98, green: 0.60, blue: 0.76),
                         Color(red: 0.90, green: 0.38, blue: 0.58)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case "IconPride":
            return LinearGradient(
                colors: [Color(red: 0.98, green: 0.76, blue: 0.26),
                         Color(red: 0.92, green: 0.36, blue: 0.62)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case "IconSoft":
            return LinearGradient(
                colors: [Color(red: 0.82, green: 0.74, blue: 0.96),
                         Color(red: 0.62, green: 0.52, blue: 0.88)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case "IconButter":
            return LinearGradient(
                colors: [Color(red: 1.00, green: 0.92, blue: 0.56),
                         Color(red: 0.94, green: 0.78, blue: 0.32)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            return LinearGradient(
                colors: [Color(red: 0.80, green: 0.80, blue: 0.82),
                         Color(red: 0.68, green: 0.68, blue: 0.70)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
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
        colorScheme == .dark ? .white.opacity(0.045) : Color.primary.opacity(0.05)
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

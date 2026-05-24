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
        id: "CarryIconDark",
        name: "icon.dark.name",
        description: "icon.dark.description"
    ),
    AppIconOption(
        id: "CarryIconMono",
        name: "icon.mono.name",
        description: "icon.mono.description"
    ),
    AppIconOption(
        id: "CarryIconSunny",
        name: "icon.sunny.name",
        description: "icon.sunny.description"
    ),
    AppIconOption(
        id: "CarryIconAurora",
        name: "icon.aurora.name",
        description: "icon.aurora.description"
    ),
    AppIconOption(
        id: "CarryIconMidnight",
        name: "icon.midnight.name",
        description: "icon.midnight.description"
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
        let imageName = option.id ?? "AppIcon"

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
        case "CarryIconDark":
            return LinearGradient(
                colors: [Color(red: 0.08, green: 0.08, blue: 0.10),
                         Color(red: 0.05, green: 0.05, blue: 0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case "CarryIconMono":
            return LinearGradient(
                colors: [Color(red: 0.88, green: 0.86, blue: 0.82),
                         Color(red: 0.72, green: 0.70, blue: 0.68)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case "CarryIconSunny":
            return LinearGradient(
                colors: [Color(red: 0.99, green: 0.78, blue: 0.30),
                         Color(red: 0.96, green: 0.55, blue: 0.20)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case "CarryIconAurora":
            return LinearGradient(
                colors: [Color(red: 0.28, green: 0.72, blue: 0.82),
                         Color(red: 0.48, green: 0.30, blue: 0.86)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case "CarryIconMidnight":
            return LinearGradient(
                colors: [Color(red: 0.06, green: 0.08, blue: 0.20),
                         Color(red: 0.02, green: 0.04, blue: 0.14)],
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
                if error == nil {
                    withAnimation {
                        currentIconName = iconName
                    }
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

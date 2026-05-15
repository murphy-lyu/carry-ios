//
//  AboutView.swift
//  Carry
//

import SwiftUI

struct AboutView: View {

    private var appVersion: String {
        let dict = Bundle.main.infoDictionary
        let version = dict?["CFBundleShortVersionString"] as? String ?? "—"
        let build = dict?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // — Tagline
                Text("about.tagline")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(7)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 28)

                // — Made with
                HStack(spacing: 6) {
                    Text("about.madeWith")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                    Text("❤️")
                        .font(.footnote)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)

                // — Author card
                Divider()
                    .padding(.horizontal, 16)

                HStack(spacing: 12) {
                    Image("murphy")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("about.author.name")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        Text("about.author.role")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

                Divider()
                    .padding(.horizontal, 16)

                // — Follow us
                VStack(alignment: .leading, spacing: 0) {
                    Text("about.follow")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .kerning(1.5)
                        .textCase(.uppercase)
                        .padding(.horizontal, 16)
                        .padding(.top, 24)
                        .padding(.bottom, 8)

                    socialRow(label: "Twitter / X", handle: "@lumastudio", url: "https://twitter.com/lumastudio")
                    socialRow(label: "about.social.xiaohongshu", handle: "Luma Studio", url: "https://xiaohongshu.com")
                }

                // — App info
                VStack(alignment: .leading, spacing: 0) {
                    Text("about.app")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .kerning(1.5)
                        .textCase(.uppercase)
                        .padding(.horizontal, 16)
                        .padding(.top, 24)
                        .padding(.bottom, 8)

                    infoRow(label: "settings.about.appName", value: "Carry")
                    infoRow(label: "settings.about.version", value: appVersion)
                }

                // — Dedication (last line of the page, like a book's final page)
                Text("about.dedication")
                    .font(.footnote)
                    .italic()
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 80)
                    .padding(.bottom, 8)
            }
            .padding(.bottom, 32)
        }
        .background(Color(UIColor.systemBackground))
        .navigationTitle("about.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Subviews

    private func socialRow(label: LocalizedStringKey, handle: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { UIApplication.shared.open(u) }
        } label: {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Spacer()
                Text(handle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(UIColor.separator))
                .frame(height: 0.5)
                .padding(.leading, 16)
        }
    }

    private func infoRow(label: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.primary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(UIColor.separator))
                .frame(height: 0.5)
                .padding(.leading, 16)
        }
    }
}

#Preview {
    NavigationStack {
        AboutView()
    }
}

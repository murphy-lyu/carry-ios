//
//  LegalViews.swift
//  Carry
//

import SwiftUI

/// Returns the URL for a hosted legal document, switching to the Chinese
/// page when the user's preferred language is Chinese.
private func legalURL(_ slug: String) -> URL {
    // 自营域名（Cloudflare Pages），国内可达——GitHub Pages（github.io）在中国大陆被
    // GFW 干扰、无 VPN 打不开法务页，对大陆上架是合规 + 体验缺口。源文件在 neve-web 仓库
    // 的 legal/ 站点（Pages root=legal/，每 app 一文件夹），对外按 /<app>/<doc>/ 组织。
    let base = "https://legal.nevestudio.app/carry/\(slug)/"
    let preferred = Locale.preferredLanguages.first ?? "en"
    if preferred.hasPrefix("zh") {
        // 用干净地址（无 .html）——Cloudflare Pages 会把 /xxx.html 308 跳到去 .html 的地址，
        // 这里直接指向终点、省掉一跳。
        return URL(string: base + "zh")!
    }
    return URL(string: base)!
}

struct TermsView: View {
    var body: some View {
        LegalScrollView(
            contentBody: "legal.terms.body",
            updated: "legal.updated",
            fullURL: legalURL("terms")
        )
        .navigationTitle("settings.legal.terms")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PrivacyView: View {
    var body: some View {
        LegalScrollView(
            contentBody: "legal.privacy.body",
            updated: "legal.updated",
            fullURL: legalURL("privacy")
        )
        .navigationTitle("settings.legal.privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LegalScrollView: View {

    let contentBody: LocalizedStringKey
    let updated: LocalizedStringKey
    let fullURL: URL

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            legalContent
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
        }
        .background(CarrySubtleBackground())
    }

    private var legalContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(updated)
                    .font(.caption)
                    .foregroundStyle(colorScheme == .dark ? Color.secondary.opacity(0.68) : Color(UIColor.tertiaryLabel))

                Text(contentBody)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineSpacing(6)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(colorScheme == .dark ? Color(UIColor.secondarySystemBackground).opacity(0.76) : Color(UIColor.systemBackground).opacity(0.80))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.045) : Color.primary.opacity(0.035), lineWidth: 1)
            )
            .shadow(color: colorScheme == .dark ? Color.black.opacity(0.16) : Color.black.opacity(0.012), radius: colorScheme == .dark ? 8 : 6, x: 0, y: 3)

            Button {
                UIApplication.shared.open(fullURL)
            } label: {
                HStack(spacing: 6) {
                    Text("legal.viewFull")
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(colorScheme == .dark ? Color.primary.opacity(0.92) : .primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(colorScheme == .dark ? Color(UIColor.secondarySystemBackground).opacity(0.58) : Color(UIColor.systemBackground).opacity(0.56))
            )
        }
    }
}

#Preview("Terms") { TermsView() }
#Preview("Privacy") { PrivacyView() }

//
//  LegalViews.swift
//  Carry
//

import SwiftUI

/// Returns the URL for a hosted legal document, switching to the Chinese
/// page when the user's preferred language is Chinese.
private func legalURL(_ slug: String) -> URL {
    let base = "https://murphy-lyu.github.io/carry-legal/\(slug)/"
    let preferred = Locale.preferredLanguages.first ?? "en"
    if preferred.hasPrefix("zh") {
        return URL(string: base + "zh.html")!
    }
    return URL(string: base)!
}

struct TermsView: View {
    var body: some View {
        legalScroll(
            body: "legal.terms.body",
            updated: "legal.updated",
            fullURL: legalURL("terms")
        )
        .navigationTitle("settings.legal.terms")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PrivacyView: View {
    var body: some View {
        legalScroll(
            body: "legal.privacy.body",
            updated: "legal.updated",
            fullURL: legalURL("privacy")
        )
        .navigationTitle("settings.legal.privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

@ViewBuilder
private func legalScroll(
    body: LocalizedStringKey,
    updated: LocalizedStringKey,
    fullURL: URL
) -> some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {

            Text(updated)
                .font(.caption)
                .foregroundStyle(.tertiary)

            Text(body)
                .font(.subheadline)
                .foregroundColor(.primary)
                .lineSpacing(6)

            Button {
                UIApplication.shared.open(fullURL)
            } label: {
                HStack(spacing: 6) {
                    Text("legal.viewFull")
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                }
                .font(.subheadline)
                .foregroundColor(.primary)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Color(UIColor.systemBackground))
}

#Preview("Terms") {
    NavigationStack { TermsView() }
}

#Preview("Privacy") {
    NavigationStack { PrivacyView() }
}

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
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(updated)
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Text(body)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineSpacing(6)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(UIColor.systemBackground).opacity(0.86),
                                Color(UIColor.systemBackground).opacity(0.72)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.035), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.012), radius: 6, x: 0, y: 3)

            Button {
                UIApplication.shared.open(fullURL)
            } label: {
                HStack(spacing: 6) {
                    Text("legal.viewFull")
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(UIColor.systemBackground).opacity(0.56))
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
    }
    .background(CarrySubtleBackground())
}

#Preview("Terms") { TermsView() }
#Preview("Privacy") { PrivacyView() }

//
//  LegalViews.swift
//  Carry
//

import SwiftUI

struct TermsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("legal.terms.body")
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineSpacing(4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Color(UIColor.systemBackground))
        .navigationTitle("settings.legal.terms")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("legal.privacy.body")
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineSpacing(4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Color(UIColor.systemBackground))
        .navigationTitle("settings.legal.privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Terms") {
    NavigationStack { TermsView() }
}

#Preview("Privacy") {
    NavigationStack { PrivacyView() }
}

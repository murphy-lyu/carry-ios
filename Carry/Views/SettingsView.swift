//
//  SettingsView.swift
//  Carry
//

import SwiftUI

struct SettingsView: View {

    private var appVersion: String {
        let dict = Bundle.main.infoDictionary
        let version = dict?["CFBundleShortVersionString"] as? String ?? "—"
        let build = dict?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("Settings")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)

            List {
                Section("About") {
                    LabeledContent("App name", value: "Carry")
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Developer", value: "Luma Studio")
                }

                Section("Connect") {
                    Button {
                        // placeholder
                    } label: {
                        HStack {
                            Text("Twitter / X")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundColor(.primary)

                    Button {
                        // placeholder
                    } label: {
                        HStack {
                            Text("Instagram")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundColor(.primary)
                }

                Section("Legal") {
                    Button {
                        // placeholder
                    } label: {
                        HStack {
                            Text("Privacy Policy")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundColor(.primary)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationBarHidden(true)
    }
}

#Preview {
    SettingsView()
}

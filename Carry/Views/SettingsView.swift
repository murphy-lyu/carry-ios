//
//  SettingsView.swift
//  Carry
//

import SwiftUI

struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        let dict = Bundle.main.infoDictionary
        let version = dict?["CFBundleShortVersionString"] as? String ?? "—"
        let build = dict?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
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
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}

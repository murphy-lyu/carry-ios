//
//  ExportItinerarySheet.swift
//  Carry
//
//  签证行程单导出选项：语言（EN/ZH）+ 申请人姓名/目的（选填，本地存）+ 含路线地图开关 → 导出 PDF。
//  spec: itinerary-export-document.md。不收集护照号；申请人信息仅本地、不上云。
//

import SwiftUI

struct ExportItinerarySheet: View {
    let trip: TripBundle

    @Environment(\.dismiss) private var dismiss

    // 本地偏好（不上云）。语言默认跟随：中文设备→中文，否则英文。
    @AppStorage("export_doc_language") private var languageRaw = ""
    @AppStorage("export_applicant_name") private var applicantName = ""
    @AppStorage("export_purpose") private var purpose = ""
    @AppStorage("export_include_map") private var includeMap = true

    @State private var isRendering = false

    private var language: DocLanguage {
        get { DocLanguage(rawValue: languageRaw) ?? defaultLanguage }
        nonmutating set { languageRaw = newValue.rawValue }
    }
    private var defaultLanguage: DocLanguage {
        let lang = Locale.current.language
        guard lang.languageCode?.identifier == "zh" else { return .en }
        // 繁体脚本 / 台·港·澳 → 繁体；其余中文 → 简体（与 AirportLocale 口径一致）。
        if lang.script?.identifier == "Hant" { return .zhHant }
        switch Locale.current.region?.identifier {
        case "TW", "HK", "MO": return .zhHant
        default:               return .zh
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: Binding(get: { language }, set: { language = $0 })) {
                        ForEach(DocLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    } label: {
                        Text("itinerary.export.language")
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    TextField("itinerary.export.applicant", text: $applicantName)
                    TextField("itinerary.export.purpose", text: $purpose)
                } footer: {
                    Text("itinerary.export.applicant_footer")
                }

                Section {
                    Toggle("itinerary.share.include_map", isOn: $includeMap)
                }
            }
            .navigationTitle(Text("itinerary.export.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("itinerary.export.button") { export() }
                        .fontWeight(.semibold)
                        .disabled(isRendering)
                }
            }
            .overlay {
                if isRendering {
                    ProgressView().controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
        }
    }

    private func export() {
        guard !isRendering else { return }
        isRendering = true
        let options = ItineraryExportOptions(
            language: language,
            applicantName: applicantName,
            purpose: purpose,
            includeMap: includeMap
        )
        Task { @MainActor in
            defer { isRendering = false }
            guard let data = await ItineraryPDFRenderer.render(trip: trip, options: options) else {
                CarryLogger.shared.log(.itineraryExportFailed)
                return
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(ItineraryPDFRenderer.fileName(for: trip, date: Date()))
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try data.write(to: url, options: .atomic)
            } catch {
                CarryLogger.shared.log(.itineraryExportFailed, context: "write")
                return
            }
            CarryLogger.shared.log(.itineraryExported, context: "lang=\(options.language.rawValue) map=\(options.includeMap)")
            // 在导出页之上呈现系统分享单；用户分享/存储后返回导出页，再自行关闭（不在此 dismiss，避免拆掉呈现者）。
            present(url)
        }
    }

    private func present(_ url: URL) {
        UIApplication.shared.presentActivitySheet(items: [url])
    }
}

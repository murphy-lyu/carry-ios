//
//  TripsyImportView.swift
//  Carry
//
//  从 Tripsy 导入（spec: tripsy-import.md）——预览页：逐行程勾选 → 合并导入。
//  解析在 SettingsView 完成后把草稿传入；本页只负责选择 + 触发 store.mergeFromData。
//

import SwiftUI

/// 驱动 `.sheet(item:)` 的会话包装（携带解析好的行程草稿）。
struct TripsyImportSession: Identifiable {
    let id = UUID()
    let drafts: [TripsyTripDraft]
}

struct TripsyImportView: View {
    let drafts: [TripsyTripDraft]
    /// 导入完成回调（新增行程数）——由 SettingsView 弹 toast / 刷新备份缓存。
    let onImported: (Int) -> Void

    @EnvironmentObject private var store: TripStore
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<UUID>
    @State private var importing = false

    init(drafts: [TripsyTripDraft], onImported: @escaping (Int) -> Void) {
        self.drafts = drafts
        self.onImported = onImported
        _selected = State(initialValue: Set(drafts.map(\.id)))   // 默认全选
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("tripsy_import.preview.intro")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 16)

                    VStack(spacing: 10) {
                        ForEach(drafts) { draft in
                            tripRow(draft)
                        }
                    }
                    .padding(.horizontal, 16)

                    // 合并语义 + 不迁移项说明（诚实告知，避免误以为丢数据）。
                    VStack(alignment: .leading, spacing: 8) {
                        noteLine("checkmark.circle", "tripsy_import.note.merge")
                        noteLine("tray", "tripsy_import.note.skipped")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 22)
                    .padding(.bottom, 24)
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                importButton
            }
            .navigationTitle(Text("tripsy_import.preview.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("common.cancel") }
                }
            }
        }
    }

    // MARK: 行

    private func tripRow(_ draft: TripsyTripDraft) -> some View {
        let isOn = selected.contains(draft.id)
        return Button {
            if isOn { selected.remove(draft.id) } else { selected.insert(draft.id) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isOn ? CarryAccent.color : Color.secondary.opacity(0.5))

                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.name)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if draft.isDateless {
                            Text("tripsy_import.preview.planning")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        } else if !draft.dateRangeText.isEmpty {
                            Text(draft.dateRangeText)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    summaryChips(draft)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .carryCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 摘要用图标+数字 chip（零值不显）：语言中立、无单复数问题、跟实体图标一致。
    @ViewBuilder
    private func summaryChips(_ d: TripsyTripDraft) -> some View {
        HStack(spacing: 12) {
            if d.placeCount > 0 { countChip("mappin.and.ellipse", d.placeCount) }
            if d.transportCount > 0 { countChip("airplane", d.transportCount) }
            if d.lodgingCount > 0 { countChip("bed.double", d.lodgingCount) }
        }
    }

    private func countChip(_ icon: String, _ n: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11))
            Text("\(n)").font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.secondary)
    }

    private func noteLine(_ icon: String, _ key: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(key)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 导入按钮

    private var importButton: some View {
        let count = selected.count
        return Button {
            performImport()
        } label: {
            Text(count == 0
                 ? NSLocalizedString("tripsy_import.preview.action.none", comment: "")
                 : String.localizedStringWithFormat(NSLocalizedString("tripsy_import.preview.action", comment: ""), count))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(.systemBackground))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(count == 0 ? Color(.label).opacity(0.25) : Color(.label))
                )
        }
        .buttonStyle(.plain)
        .disabled(count == 0 || importing)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .bottomBarScrim(CarrySubtleBackground.baseColor)
    }

    private func performImport() {
        guard !importing else { return }
        importing = true
        let chosen = drafts.filter { selected.contains($0.id) }
        CarryLogger.shared.log(.tripsyImportStarted, context: "selected=\(chosen.count) total=\(drafts.count)")

        guard let backup = TripsyImporter.makeBackup(from: chosen) else {
            CarryLogger.shared.log(.tripsyImportFailed, context: "reason=build_failed")
            importing = false
            return
        }
        do {
            let result = try store.mergeBackup(backup)
            CarryLogger.shared.log(.tripsyImportSucceeded,
                                   context: "trips=\(result.trips) selected=\(chosen.count)")
            onImported(result.trips)
            dismiss()
        } catch {
            CarryLogger.shared.log(.tripsyImportFailed, context: "reason=merge error=\(error.localizedDescription)")
            importing = false
        }
    }
}

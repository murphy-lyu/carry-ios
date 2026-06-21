//
//  ImportSharedTripSheet.swift
//  Carry
//
//  同行者发来 `.carrytrip` 文件、点开后弹出的「导入行程」确认卡片。
//  展示行程名 + 日期/地点数等关键信息，确认后写库并跳进该行程。
//  首次导入 = 新建；已存在（同 UUID）= 更新该行程的行程规划（不动打包清单）。
//

import SwiftUI
import SwiftData

struct ImportSharedTripSheet: View {
    let summary: DataBackupManager.SharedTripSummary

    @EnvironmentObject var store: TripStore
    @EnvironmentObject var router: NavigationRouter
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @State private var importing = false
    /// 实测内容高度 → 卡片裹住内容、无空洞（比固定 .medium 紧凑）。
    @State private var contentHeight: CGFloat = 400

    /// 本地已有同 UUID 行程 → 走「更新」语义，否则「新建」。
    private var isUpdate: Bool {
        DataBackupManager.shared.tripExists(id: summary.tripId, in: context)
    }

    private var dateRangeText: String? {
        guard !summary.isDateless else { return nil }
        let cal = Calendar.current
        let start = cal.startOfDay(for: summary.departureDate)
        let end = cal.date(byAdding: .day, value: max(summary.totalDays - 1, 0), to: start) ?? start
        let fmt = Date.FormatStyle.dateTime.month(.abbreviated).day()
        return start == end ? start.formatted(fmt) : "\(start.formatted(fmt))–\(end.formatted(fmt))"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                Image(systemName: "map.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(CarryAccent.color)
                    .frame(width: 64, height: 64)
                    // 深色下提亮底圈，避免图标像浮空
                    .background(Circle().fill(CarryAccent.color.opacity(scheme == .dark ? 0.22 : 0.12)))

                VStack(spacing: 6) {
                    Text("itinerary.import.heading")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(summary.name)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if !summary.destinationCity.isEmpty {
                        Text(summary.destinationCity)
                            .font(.system(size: 15, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    if let range = dateRangeText { chip("calendar", range) }
                    chip("mappin.and.ellipse", "\(summary.placeCount)")
                }

                if isUpdate {
                    Text("itinerary.import.update_note")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)

            VStack(spacing: 6) {
                Button {
                    performImport()
                } label: {
                    Text(isUpdate ? LocalizedStringKey("itinerary.import.update_action")
                                  : LocalizedStringKey("itinerary.import.action"))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color(.label), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(importing)

                Button {
                    router.pendingSharedTrip = nil
                } label: {
                    Text("common.cancel")
                        .font(.system(size: 16, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 12)
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: SheetContentHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(SheetContentHeightKey.self) { contentHeight = $0 }
        .presentationDetents([.cappedContentHeight(contentHeight)])   // 钳屏高以下，长内容不触发 iOS 26 脱离（斜滚根因）
        .presentationDragIndicator(.visible)
        // 钉一致的不透明底：与 StopDetailView 统一为「Carry 浮窗 = 干净不透明卡」，不用 iOS 26 默认玻璃。
        // 「收到分享行程」的确认卡（常冷启动）聚焦决策、不透出半加载的模糊背景，更郑重。
        .presentationBackground(Color(UIColor.systemBackground))
    }

    private func chip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
            Text(text).font(.system(size: 15, weight: .medium, design: .rounded))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color(.secondarySystemBackground)))
    }

    private func performImport() {
        guard !importing else { return }
        importing = true
        do {
            let id = try DataBackupManager.shared.importSharedTrip(from: summary.data, into: context)
            store.refresh()
            CarryLogger.shared.log(.itineraryImported, context: isUpdate ? "mode=update" : "mode=new")
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            router.pendingSharedTrip = nil
            router.path = NavigationPath([id])   // 跳进导入/更新后的行程
        } catch {
            CarryLogger.shared.log(.itineraryImportFailed, context: "\(error)")
            importing = false
            router.pendingSharedTrip = nil
        }
    }
}

/// 测量卡片内容高度，驱动自适应 detent。
private struct SheetContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

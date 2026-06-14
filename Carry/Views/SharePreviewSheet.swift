//
//  SharePreviewSheet.swift
//  Carry
//
//  「分享行程」前的预览：先让用户看到那张海报（叙事/惊喜时刻，north-star §8），
//  再分享。海报渐进渲染——先出无地图版立刻可见，路线地图异步好了再合入。
//  含「是否包含路线地图」开关；Share 用原生 ShareLink（系统本地化 + 文件名 + 文本兜底）。
//

import SwiftUI

struct SharePreviewSheet: View {
    let trip: TripBundle

    @Environment(\.dismiss) private var dismiss
    @State private var mapImage: UIImage?       // 路线地图（渲染一次后缓存，供开关切换）
    @State private var posterImage: UIImage?    // 当前预览的海报（随开关变化）
    @State private var posterURL: URL?          // 当前海报的临时文件（ShareLink 用，带文件名）
    @State private var includeMap = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                preview
                controls
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(trip.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringKey("common.cancel")) { dismiss() }
                }
            }
        }
        .task { await render() }
        .onChange(of: includeMap) { _, _ in rerenderPoster() }
    }

    @ViewBuilder private var preview: some View {
        if let posterImage {
            ScrollView {
                Image(uiImage: posterImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: 14) {
            if mapImage != nil {   // 仅当有路线地图（≥2 个有坐标的地点）才给开关
                Toggle(isOn: $includeMap) {
                    Label(LocalizedStringKey("itinerary.share.include_map"), systemImage: "map")
                        .font(.system(size: 15, design: .rounded))
                }
                .tint(CarryAccent.color)
            }
            shareButton
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(.bar)
    }

    @ViewBuilder private var shareButton: some View {
        if let posterURL {
            ShareLink(item: posterURL, message: Text(TripShare.shareText(for: trip))) {
                shareLabel(enabled: true)
            }
        } else {
            shareLabel(enabled: false)   // 渲染中：禁用态占位
        }
    }

    private func shareLabel(enabled: Bool) -> some View {
        Text(LocalizedStringKey("itinerary.share"))
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(.systemBackground).opacity(enabled ? 1 : 0.5))
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Color(.label).opacity(enabled ? 1 : 0.4),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @MainActor
    private func render() async {
        rerenderPoster()                                   // ① 先出无地图版，立刻可见
        mapImage = await TripShare.renderRouteMap(for: trip)
        if includeMap { rerenderPoster() }                 // ② 地图好了再合入
    }

    @MainActor
    private func rerenderPoster() {
        guard let img = TripShare.renderPoster(for: trip, routeMapImage: includeMap ? mapImage : nil) else { return }
        posterImage = img
        posterURL = TripShare.writeTempPoster(img, for: trip)
    }
}

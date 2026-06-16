//
//  DirectionsModule.swift
//  Carry
//
//  可复用「路程 / 导航」模块（spec: itinerary-stop-travel-modes.md / itinerary-entity-detail-unify.md）。
//  交通方式选择器（驾车/公交/步行/骑行）+ 联动 Get Directions（按方式过滤地图 App）+ 可选「到下一站」直线距离。
//  从 StopDetailView 提取，地点详情与住宿详情共用——同一处导航逻辑，避免重复与漂移。
//

import SwiftUI
import CoreLocation

struct DirectionsModule: View {
    /// 目标坐标（调用方已确保有坐标才构造本视图）。
    let coordinate: CLLocationCoordinate2D
    /// 目标名称（传给地图 App 作目的地名）。
    let name: String
    /// 已安装的导航 App（按方式过滤前的全量；空则调用方不应显示本模块）。
    let navApps: [MapNavigationApp]
    /// 「到下一站」直线距离文案；nil = 不显示该行（如住宿无「下一站」概念）。
    var distanceToNext: String? = nil
    /// Get Directions 行图标的着色（地点用当天色、住宿用强调色）。
    var tint: Color = .accentColor

    @State private var navMode: MapNavigationMode = .driving

    var body: some View {
        VStack(spacing: 0) {
            modeSelector                       // 驾车 / 公交 / 步行 / 骑行（默认驾车），联动 Get Directions
            Divider()
            navAction                          // 用所选方式调起；App List 按方式过滤（骑行隐藏 Apple 地图）
            if let distanceToNext {
                Divider().padding(.leading, 34)
                HStack(spacing: 12) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
                        .accessibilityHidden(true)
                    Text(String(format: NSLocalizedString("itinerary.stop.detail.to_next", comment: ""), distanceToNext))
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    /// 交通方式选择器：4 段（驾车默认 / 公交 / 步行 / 骑行）。选中即联动 Get Directions 调起的方式，避免
    /// 「选了骑行却调起驾车」的割裂。选中=烟蓝淡填充+烟蓝字（Tier 2 可选中），未选=灰。
    private var modeSelector: some View {
        HStack(spacing: 6) {
            ForEach(MapNavigationMode.allCases) { mode in
                let selected = (mode == navMode)
                Button {
                    withAnimation(.spring(duration: 0.3, bounce: 0.2)) { navMode = mode }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.symbolName).font(.system(size: 13, weight: .semibold))
                        Text(LocalizedStringKey(mode.nameKey))
                            .font(.system(.footnote, design: .rounded).weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)   // 4 段 + 长语言（德/法/葡）窄屏防挤压
                    }
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var navAction: some View {
        let apps = navApps.filter { $0.supports(navMode) }
        if apps.isEmpty {
            // 选骑行且未装支持骑行的地图（只有 Apple 地图）→ 置灰 + 提示，不静默无反应。
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.turn.up.right.circle")
                    .font(.system(size: 18)).foregroundStyle(.tertiary).frame(width: 22)
                    .accessibilityHidden(true)
                Text("itinerary.nav.no_app_for_mode")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
        } else if apps.count > 1 {
            Menu {
                ForEach(apps) { app in
                    Button(LocalizedStringKey(app.nameKey)) { navigate(app) }
                }
            } label: { navRowLabel }
            .accessibilityLabel(Text("itinerary.nav.button.a11y"))
        } else {
            Button { navigate(apps[0]) } label: { navRowLabel }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("itinerary.nav.button.a11y"))
        }
    }

    private var navRowLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                .font(.system(size: 18)).foregroundStyle(tint).frame(width: 22)
                .accessibilityHidden(true)
            Text("itinerary.stop.detail.navigate")
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func navigate(_ app: MapNavigationApp) {
        MapNavigationService.open(app, coordinate: coordinate, name: name, mode: navMode)
        CarryLogger.shared.log(.itineraryStopNavigated, context: "\(app.rawValue)_\(navMode.rawValue)")
    }
}

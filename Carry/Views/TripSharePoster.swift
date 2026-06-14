//
//  TripSharePoster.swift
//  Carry
//
//  「分享行程」：把行程规划渲染成一张可分享的竖版海报图（ImageRenderer → UIImage），
//  封面用行程背景图、正文是按天的地点时间轴 + 低调 Carry 水印。形态对标品质旅行用户
//  在小红书/朋友圈晒行程（spec: design-north-star §8 叙事感）。纯本地、零后端。
//
//  注：海报是「独立分享物」而非 App 内 chrome，固定渲染为浅色（不随设备深浅切换），
//  以保证分享到任意背景的社交场景都清晰一致——与 App Store 截图同理。
//

import SwiftUI
import UIKit

// MARK: - 海报视图

struct TripSharePoster: View {
    let trip: TripBundle
    let days: [ItineraryDay]

    /// 海报渲染宽度（pt）。高度随内容自适应。
    static let width: CGFloat = 390
    private let headerHeight: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            header
            daysBody
            footer
        }
        .frame(width: Self.width)
        .background(Color(.systemBackground))
    }

    // MARK: 封面

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            coverBackground
                .frame(width: Self.width, height: headerHeight)
                .clipped()

            // 底部压暗，保证标题在任何封面（含很亮的照片）上都可读
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.10), .black.opacity(0.42), .black.opacity(0.72)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: headerHeight)

            VStack(alignment: .leading, spacing: 6) {
                Text(trip.name)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
            }
            // 双层阴影：稍大柔影压住亮背景，加一道紧实阴影提清晰度
            .shadow(color: .black.opacity(0.5), radius: 10, y: 2)
            .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
            .padding(20)
        }
        .frame(width: Self.width, height: headerHeight)
    }

    @ViewBuilder
    private var coverBackground: some View {
        if let name = trip.primaryBackground?.localFileName,
           let image = BackgroundImageStore.image(named: name) {
            // 复用首页卡片同款 PositionedImage：把用户设的裁剪当「焦点区域」渲染，
            // 海报封面取景 = 行程卡上看到的取景，保持一致。
            PositionedImage(image: image, crop: trip.primaryBackground?.crop)
        } else {
            // 无封面：用第一天配色做柔和渐变兜底，仍有旅行气质
            LinearGradient(
                colors: [accent.opacity(0.85), accent.opacity(0.45)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .overlay(
                Image(systemName: "map")
                    .font(.system(size: 80, weight: .light))
                    .foregroundStyle(.white.opacity(0.18))
            )
        }
    }

    // MARK: 按天正文

    private var daysBody: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(Array(plannedDays.enumerated()), id: \.element.id) { index, day in
                daySection(day, index: index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private func daySection(_ day: ItineraryDay, index: Int) -> some View {
        let color = ItineraryDayPalette.color(forDayIndex: day.sortOrder)
        let dayStops = stops(of: day)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(dayTitle(day))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            // 时间轴：地点节点串成一条当天色的淡连接线（呼应 App 内 timeline rail，
            // 让正文从「列表」变成「一段旅程」）。单点天不画线。
            ZStack(alignment: .topLeading) {
                if dayStops.count > 1 {
                    Rectangle()
                        .fill(color.opacity(0.22))
                        .frame(width: 1.5)
                        .padding(.leading, 11.25)   // 对齐节点圆心 (12 - 半线宽)
                        .padding(.vertical, 12)      // 起止落在首/末节点圆心
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(dayStops, id: \.id) { stop in
                        HStack(spacing: 10) {
                            Image(systemName: stop.category.symbolName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(color)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(color.opacity(0.13)))
                            Text(stop.name)
                                .font(.system(size: 15, weight: .regular, design: .rounded))
                                .foregroundStyle(.primary.opacity(0.9))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if let time = timeLabel(stop) {
                                Text(time)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.leading, 2)
        }
    }

    // MARK: 水印

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 12, weight: .semibold))
            Text("Carry")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: 数据

    /// 只展示「有安排」的天（有地点的），空天不进海报。
    private var plannedDays: [ItineraryDay] {
        days.filter { !stops(of: $0).isEmpty }
    }

    private func stops(of day: ItineraryDay) -> [ItineraryStop] {
        (day.stops ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }

    private var accent: Color { ItineraryDayPalette.color(forDayIndex: 0) }

    private var subtitle: String {
        var parts: [String] = []
        if !trip.destinationCity.isEmpty { parts.append(trip.destinationCity) }
        let range = trip.localizedDateRange
        if !range.isEmpty { parts.append(range) }
        return parts.joined(separator: " · ")
    }

    /// 与 App 内 Day 头一致：有日期显示真实日期，无日期退回「Day N」。
    private func dayTitle(_ day: ItineraryDay) -> String {
        if !trip.isDateless {
            let base = Calendar.current.startOfDay(for: trip.departureDate)
            let date = Calendar.current.date(byAdding: .day, value: day.sortOrder, to: base) ?? base
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return String(format: NSLocalizedString("itinerary.day.title", comment: ""), day.sortOrder + 1)
    }

    private func timeLabel(_ stop: ItineraryStop) -> String? {
        guard stop.plannedStartMinutes >= 0 else { return nil }
        let base = Calendar.current.startOfDay(for: Date())
        guard let date = Calendar.current.date(byAdding: .minute, value: stop.plannedStartMinutes, to: base) else { return nil }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - 渲染 + 分享

enum TripShare {

    /// 行程是否有可分享的内容（至少一天有地点）。无内容时入口应禁用。
    static func hasShareableItinerary(_ trip: TripBundle) -> Bool {
        trip.safeItineraryDays.contains { !($0.stops ?? []).isEmpty }
    }

    /// 把行程渲染成海报图。@MainActor + ImageRenderer（iOS 16+）。
    @MainActor
    static func renderPoster(for trip: TripBundle) -> UIImage? {
        let days = trip.safeItineraryDays
        let poster = TripSharePoster(trip: trip, days: days)
            .environment(\.colorScheme, .light)   // 固定浅色，分享物不随设备深浅
        let renderer = ImageRenderer(content: poster)
        renderer.scale = 3   // 社交分享清晰度
        renderer.proposedSize = ProposedViewSize(width: TripSharePoster.width, height: nil)
        return renderer.uiImage
    }

    /// 把海报图写成临时 PNG 文件，文件名 = 行程名（净化后）。分享文件 URL 时，
    /// 系统分享面板/存盘/隔空投送会沿用此文件名。
    static func writeTempPoster(_ image: UIImage, for trip: TripBundle) -> URL? {
        guard let data = image.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(posterFileBaseName(for: trip))
            .appendingPathExtension("png")
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }

    /// 文件名主体：`行程名_天数_出发月份_分享时间戳`，下划线分隔。
    /// 中文用「天 / 月」；其它语言退回语言中立形（数字 d + 英文月缩写），避免再引入本地化 key。
    /// 月份 = 行程出发月（这趟何时去）；时间戳 = 这张图何时导出（yyyyMMddHHmm），两者不同源。
    private static func posterFileBaseName(for trip: TripBundle) -> String {
        let isZh = Locale.current.language.languageCode == .chinese

        // 分享时间戳：无 `:`（文件系统非法）、POSIX 锁阿拉伯数字
        let stampFormatter = DateFormatter()
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.dateFormat = "yyyyMMddHHmm"
        let stamp = stampFormatter.string(from: Date())

        let nameRaw = !trip.name.isEmpty ? trip.name
            : (!trip.destinationCity.isEmpty ? trip.destinationCity : "Carry")
        var parts: [String] = [nameRaw]

        let dayCount = max(trip.spanDays, 1)
        parts.append(isZh ? "\(dayCount)天" : "\(dayCount)d")

        if !trip.isDateless {
            if isZh {
                let month = Calendar.current.component(.month, from: trip.departureDate)
                parts.append("\(month)月")
            } else {
                let mf = DateFormatter()
                mf.locale = Locale(identifier: "en_US_POSIX")
                mf.dateFormat = "MMM"
                parts.append(mf.string(from: trip.departureDate))
            }
        }

        parts.append(stamp)

        // 净化文件系统非法字符（下划线为分隔符，保留）
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let joined = parts.joined(separator: "_")
            .components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? "Carry" : joined
    }

    /// 文本兜底（有些群聊更想要可复制文字）。复用 day 标题 key，零新增文案。
    static func shareText(for trip: TripBundle) -> String {
        var lines: [String] = []
        var head = trip.name
        if !trip.destinationCity.isEmpty { head += " · \(trip.destinationCity)" }
        lines.append(head)
        let range = trip.localizedDateRange
        if !range.isEmpty { lines.append(range) }
        lines.append("")

        for day in trip.safeItineraryDays {
            let stops = (day.stops ?? []).sorted { $0.sortOrder < $1.sortOrder }
            guard !stops.isEmpty else { continue }
            let title: String
            if !trip.isDateless {
                let base = Calendar.current.startOfDay(for: trip.departureDate)
                let date = Calendar.current.date(byAdding: .day, value: day.sortOrder, to: base) ?? base
                title = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            } else {
                title = String(format: NSLocalizedString("itinerary.day.title", comment: ""), day.sortOrder + 1)
            }
            lines.append(title)
            for stop in stops { lines.append("· \(stop.name)") }
            lines.append("")
        }
        lines.append("— Carry")
        return lines.joined(separator: "\n")
    }

    /// 弹系统分享面板：图片为主 + 文本兜底。
    /// 图片以「行程名.png」临时文件分享（而非裸 UIImage），这样存到文件/隔空投送/聊天里
    /// 是有意义的文件名，而不是「PNG 图像」默认名。
    @MainActor
    static func present(for trip: TripBundle) {
        var items: [Any] = []
        if let image = renderPoster(for: trip), let url = writeTempPoster(image, for: trip) {
            items.append(url)
        }
        items.append(shareText(for: trip))
        guard !items.isEmpty,
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // iPad：锚到屏幕中心，避免无 anchor 崩溃
        if let pop = vc.popoverPresentationController {
            pop.sourceView = root.view
            pop.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        (root.presentedViewController ?? root).present(vc, animated: true)
    }
}

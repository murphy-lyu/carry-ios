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
import MapKit

// MARK: - 海报视图

struct TripSharePoster: View {
    let trip: TripBundle
    let days: [ItineraryDay]
    /// 底部路线地图带（异步预渲染好的 MapKit 快照 + 图钉/连线）。nil 则不显示该带。
    var routeMapImage: UIImage? = nil

    /// 海报渲染宽度（pt）。高度随内容自适应。
    static let width: CGFloat = 390
    static let mapBandHeight: CGFloat = 220
    private let headerHeight: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            header
            daysBody
            if let routeMapImage { routeBand(routeMapImage) }
            footer
        }
        .frame(width: Self.width)
        .background(Color(.systemBackground))
    }

    // MARK: 路线地图带（地理总览：在哪、怎么走）

    private func routeBand(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .frame(width: Self.width, height: Self.mapBandHeight)
            .overlay(alignment: .top) {
                Rectangle().fill(Color(.separator).opacity(0.5)).frame(height: 0.5)
            }
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
            // 海报头与首页卡片宽高比不同：卡片裁剪按卡片比例调，直接套到更高的海报头会过度
            // 放大、构图变怪。改用「焦点对齐 + 整图最小 cover 铺满」——只取裁剪焦点位置、不放大
            // 到裁剪区域大小，主体保持在用户框的位置，构图更自然（不同于卡片的 PositionedImage）。
            FocalCoverImage(image: image, crop: trip.primaryBackground?.crop)
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
                            Text(stop.displayName)
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

/// 整图以「最小 cover」铺满 frame，并把裁剪框中心（焦点）尽量对齐 frame 中心。
/// 与 `PositionedImage`（按裁剪「区域」大小缩放）不同——这里只用焦点、不放大到裁剪区域，
/// 适合与裁剪比例不同的画面（如海报头），避免过度放大、构图变怪。
private struct FocalCoverImage: View {
    let image: UIImage
    let crop: BackgroundCrop?

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let iw = max(image.size.width, 1), ih = max(image.size.height, 1)
            let scale = max(W / iw, H / ih)            // 整图最小 cover
            let dispW = iw * scale, dispH = ih * scale
            let c = crop ?? .full
            let fx = (c.x + c.width / 2) * dispW        // 焦点（裁剪中心）在缩放图上的位置
            let fy = (c.y + c.height / 2) * dispH
            let offX = min(0, max(W - dispW, W / 2 - fx))   // 焦点居中并钳制铺满
            let offY = min(0, max(H - dispH, H / 2 - fy))
            Image(uiImage: image)
                .resizable()
                .frame(width: dispW, height: dispH)
                .offset(x: offX, y: offY)
                .frame(width: W, height: H, alignment: .topLeading)
                .clipped()
        }
    }
}

// MARK: - 渲染 + 分享

enum TripShare {

    /// 行程是否有可分享的内容（至少一天有地点）。无内容时入口应禁用。
    static func hasShareableItinerary(_ trip: TripBundle) -> Bool {
        trip.safeItineraryDays.contains { !($0.stops ?? []).isEmpty }
    }

    /// 把行程渲染成海报图。@MainActor + ImageRenderer（iOS 16+）。
    /// `routeMapImage`：异步预渲染的底部路线地图带（可空，空则海报无地图带）。
    @MainActor
    static func renderPoster(for trip: TripBundle, routeMapImage: UIImage? = nil) -> UIImage? {
        let days = trip.safeItineraryDays
        let poster = TripSharePoster(trip: trip, days: days, routeMapImage: routeMapImage)
            .environment(\.colorScheme, .light)   // 固定浅色，分享物不随设备深浅
        let renderer = ImageRenderer(content: poster)
        renderer.scale = 3   // 社交分享清晰度
        renderer.proposedSize = ProposedViewSize(width: TripSharePoster.width, height: nil)
        return renderer.uiImage
    }

    /// 异步渲染底部「路线地图带」：MapKit 静态快照 + 按当天配色的图钉与连线（动线）。
    /// 自驾/多点行程尤其有用。无坐标的地点跳过；有效点 < 2 则返回 nil（不值得画地图）。
    /// 固定浅色底图、缩放到框住所有点；失败/超时返回 nil，海报优雅降级为无地图。
    @MainActor
    static func renderRouteMap(for trip: TripBundle) async -> UIImage? {
        struct RoutePoint { let coord: CLLocationCoordinate2D; let color: UIColor }
        var ordered: [RoutePoint] = []
        for day in trip.safeItineraryDays {
            let color = UIColor(ItineraryDayPalette.color(forDayIndex: day.sortOrder))
            for stop in day.sortedStops {
                if let c = stop.coordinate { ordered.append(RoutePoint(coord: c, color: color)) }
            }
        }
        guard ordered.count >= 2 else { return nil }

        let options = MKMapSnapshotter.Options()
        options.region = region(fitting: ordered.map(\.coord))
        options.size = CGSize(width: TripSharePoster.width, height: TripSharePoster.mapBandHeight)
        options.mapType = .mutedStandard   // 弱化 POI、更干净
        options.pointOfInterestFilter = .excludingAll
        options.traitCollection = UITraitCollection { traits in
            traits.userInterfaceStyle = .light   // 海报固定浅色
            traits.displayScale = 3
        }

        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = snapshot.image.scale
        return UIGraphicsImageRenderer(size: options.size, format: format).image { ctx in
            snapshot.image.draw(at: .zero)
            let cg = ctx.cgContext
            let pts = ordered.map { snapshot.point(for: $0.coord) }

            // 连线：按时间顺序连各点，段色 = 起点当天色（连续动线）。
            cg.setLineCap(.round); cg.setLineJoin(.round)
            // ① 先画整条路线的白色描边（casing），让线在花花的地图上「浮」起来、更清晰。
            if pts.count >= 2 {
                cg.setStrokeColor(UIColor.white.withAlphaComponent(0.95).cgColor)
                cg.setLineWidth(6)
                cg.beginPath(); cg.move(to: pts[0])
                for i in 1..<pts.count { cg.addLine(to: pts[i]) }
                cg.strokePath()
            }
            // ② 再在描边上画按天配色的彩色线段。
            cg.setLineWidth(3.5)
            for i in 1..<pts.count {
                cg.setStrokeColor(ordered[i - 1].color.cgColor)
                cg.beginPath(); cg.move(to: pts[i - 1]); cg.addLine(to: pts[i]); cg.strokePath()
            }
            // 图钉：白圈 + 当天色圆点
            for (i, p) in pts.enumerated() {
                let r: CGFloat = 5
                cg.setFillColor(UIColor.white.cgColor)
                cg.fillEllipse(in: CGRect(x: p.x - r - 1.5, y: p.y - r - 1.5, width: (r + 1.5) * 2, height: (r + 1.5) * 2))
                cg.setFillColor(ordered[i].color.cgColor)
                cg.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            }
        }
    }

    /// 框住所有坐标的地图区域：取包围盒中心，跨度乘 1.5 留边、并设最小跨度避免单点过度放大。
    private static func region(fitting coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: ((lats.min() ?? 0) + (lats.max() ?? 0)) / 2,
            longitude: ((lons.min() ?? 0) + (lons.max() ?? 0)) / 2
        )
        let latDelta = max(((lats.max() ?? 0) - (lats.min() ?? 0)) * 1.5, 0.02)
        let lonDelta = max(((lons.max() ?? 0) - (lons.min() ?? 0)) * 1.5, 0.02)
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta))
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
            for stop in stops { lines.append("· \(stop.displayName)") }
            lines.append("")
        }
        lines.append("— Carry")
        return lines.joined(separator: "\n")
    }


    /// 「发送给同行者」：把行程的「行程规划」导出为 `.carrytrip` 文件并弹系统分享面板。
    /// 对方（也用 Carry）收到后点开即可确认导入。文件名 = 行程名（如 `云南.carrytrip`）。
    @MainActor
    static func presentItineraryFile(for trip: TripBundle) {
        guard let url = DataBackupManager.shared.makeItineraryShareFile(trip: trip, baseName: fileBaseName(for: trip)) else { return }
        UIApplication.shared.presentActivitySheet(items: [url])
    }

    /// 「分享清单」（打包面）：复用混合 item source——聊天内联文本 + AirDrop/存文件给规范名 `.txt`。
    /// 文件名与行程「发送给朋友」同风格、加「打包清单」区分字段，便于在文件/隔空投送里一眼区分两类。
    @MainActor
    static func presentPackingList(text: String, for trip: TripBundle) {
        let source = PackingListShareItemSource(text: text, baseName: packingFileBaseName(for: trip))
        UIApplication.shared.presentActivitySheet(items: [source])
    }

    /// 打包清单分享文件名主体：与行程「发送给朋友」同风格，插入「打包清单」区分字段
    /// （如「云南 打包清单 (6月)」vs 行程「云南 (6月)」）。
    static func packingFileBaseName(for trip: TripBundle) -> String {
        fileBaseName(for: trip,
                     tag: NSLocalizedString("packing.share.filename_tag",
                                            comment: "Distinguishing tag in packing-list share filename"))
    }

    /// 可导入文件的文件名主体：`行程名 (出发月份)`——月份做括号补充（同地不同月攻略不同）。
    /// 行程名退回目的地/「Carry」；无日期行程省略月份；月份跟随语言（中文「6月」/ 英文「Jun」）。
    /// `tag` 非空时插在行程名与月份之间（打包清单分享用，作区分字段）。
    private static func fileBaseName(for trip: TripBundle, tag: String? = nil) -> String {
        let nameRaw = !trip.name.isEmpty ? trip.name
            : (!trip.destinationCity.isEmpty ? trip.destinationCity : "Carry")
        var base = nameRaw
        if let tag, !tag.isEmpty { base += " \(tag)" }
        if !trip.isDateless {
            let month: String
            if Locale.current.language.languageCode == .chinese {
                month = "\(Calendar.current.component(.month, from: trip.departureDate))月"
            } else {
                let mf = DateFormatter()
                mf.locale = Locale(identifier: "en_US_POSIX")
                mf.dateFormat = "MMM"
                month = mf.string(from: trip.departureDate)
            }
            base += " (\(month))"
        }
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = base.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Carry" : cleaned
    }
}


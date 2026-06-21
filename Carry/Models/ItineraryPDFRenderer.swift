//
//  ItineraryPDFRenderer.swift
//  Carry
//
//  签证行程单 PDF 渲染。A4 分页、双语（文档文案走 ItineraryDocumentText、用户数据原样）。
//  概览地图复用 TripShare.renderRouteMap。spec: itinerary-export-document.md。
//
//  诚实定位：这是「行程说明」文档（签证材料之一），不含护照号、不生成预订凭证、不声称官方效力。
//

import UIKit
import MapKit

struct ItineraryExportOptions {
    var language: DocLanguage = .en
    var applicantName: String = ""
    var purpose: String = ""
    var includeMap: Bool = true
}

enum ItineraryPDFRenderer {

    // A4 + 版心
    private static let pageSize = CGSize(width: 595, height: 842)
    private static let margin: CGFloat = 48
    private static let bottomMargin: CGFloat = 56
    private static var contentWidth: CGFloat { pageSize.width - margin * 2 }

    /// 渲染整份 PDF。含地图时先异步取地图快照。返回 PDF Data（失败返回 nil）。
    @MainActor
    static func render(trip: TripBundle, options: ItineraryExportOptions) async -> Data? {
        let mapImage: UIImage? = options.includeMap ? await TripShare.renderRouteMap(for: trip) : nil
        let T = ItineraryDocumentText(lang: options.language)

        let pageRect = CGRect(origin: .zero, size: pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let data = renderer.pdfData { ctx in
            let drawer = Drawer(ctx: ctx.cgContext, pdf: ctx, text: T)
            drawer.beginNewPage()
            drawer.drawHeader(trip: trip, options: options)
            if let mapImage { drawer.drawImage(mapImage) }
            for day in trip.safeItineraryDays {
                drawer.drawDay(day, trip: trip)
            }
            drawer.drawAccommodation(trip: trip)
        }
        return data
    }

    /// 文件名：行程名_Itinerary_yyyyMMdd.pdf（去掉文件系统不安全字符）。
    static func fileName(for trip: TripBundle, date: Date) -> String {
        // 手拼 yyyyMMdd，避免 .formatted 按 locale 重排成 MMddyyyy。
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let stamp = String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let safeName = trip.name.isEmpty ? "Trip" : trip.name
        let cleaned = safeName.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined()
        return "\(cleaned)_Itinerary_\(stamp).pdf"
    }

    // MARK: - Drawer（维护 y 游标 + 分页）

    private final class Drawer {
        let ctx: CGContext
        let pdf: UIGraphicsPDFRendererContext
        let T: ItineraryDocumentText
        var y: CGFloat = margin
        var page = 0

        init(ctx: CGContext, pdf: UIGraphicsPDFRendererContext, text: ItineraryDocumentText) {
            self.ctx = ctx; self.pdf = pdf; self.T = text
        }

        // 字体
        private let titleFont = UIFont.systemFont(ofSize: 22, weight: .bold)
        private let dayFont = UIFont.systemFont(ofSize: 15, weight: .semibold)
        private let bodyFont = UIFont.systemFont(ofSize: 11, weight: .regular)
        private let bodyBold = UIFont.systemFont(ofSize: 11, weight: .semibold)
        private let smallFont = UIFont.systemFont(ofSize: 10, weight: .regular)
        private let footerFont = UIFont.systemFont(ofSize: 9, weight: .regular)

        func beginNewPage() {
            pdf.beginPage()
            page += 1
            drawFooter()
            y = margin
        }

        private func drawFooter() {
            let s = "\(T.generatedBy) · \(T.page(page))"
            let attr = NSAttributedString(string: s, attributes: [
                .font: footerFont, .foregroundColor: UIColor.tertiaryLabel
            ])
            let size = attr.size()
            attr.draw(at: CGPoint(x: (pageSize.width - size.width) / 2, y: pageSize.height - 34))
        }

        private func ensureSpace(_ h: CGFloat) {
            if y + h > pageSize.height - bottomMargin { beginNewPage() }
        }

        private func attr(_ s: String, _ font: UIFont, _ color: UIColor = .label) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        }

        /// 绘制一段文本（自动换行 + 分页），advance y。
        private func draw(_ s: NSAttributedString, indent: CGFloat = 0, spacingAfter: CGFloat = 4) {
            let avail = contentWidth - indent
            let rect = s.boundingRect(with: CGSize(width: avail, height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            ensureSpace(rect.height)
            s.draw(with: CGRect(x: margin + indent, y: y, width: avail, height: rect.height),
                   options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            y += rect.height + spacingAfter
        }

        // MARK: 各块

        func drawHeader(trip: TripBundle, options: ItineraryExportOptions) {
            draw(attr(T.title, titleFont), spacingAfter: 8)
            if !trip.name.isEmpty {
                draw(attr(trip.name, dayFont), spacingAfter: 6)
            }
            func info(_ label: String, _ value: String) {
                guard !value.isEmpty else { return }
                let s = NSMutableAttributedString(string: "\(label):  ", attributes: [.font: bodyBold, .foregroundColor: UIColor.secondaryLabel])
                s.append(attr(value, bodyFont))
                draw(s, spacingAfter: 3)
            }
            let name = options.applicantName.trimmingCharacters(in: .whitespaces)
            info(T.applicant, name)
            info(T.purpose, options.purpose.trimmingCharacters(in: .whitespaces))
            info(T.destination, trip.destinationCity)
            if !trip.isDateless {
                let last = Calendar.current.date(byAdding: .day, value: max(0, trip.spanDays - 1),
                                                 to: Calendar.current.startOfDay(for: trip.departureDate)) ?? trip.departureDate
                info(T.dates, T.dateRange(from: trip.departureDate, to: last))
            }
            y += 6
        }

        func drawImage(_ image: UIImage) {
            let scale = contentWidth / image.size.width
            let h = image.size.height * scale
            ensureSpace(h + 8)
            image.draw(in: CGRect(x: margin, y: y, width: contentWidth, height: h))
            y += h + 12
        }

        func drawDay(_ day: ItineraryDay, trip: TripBundle) {
            let items = day.timeline
            // 空天也列出 day 标题，体现「这天无安排」对签证的完整性；但若整天空且无住宿覆盖可略过。
            // 标题与首行尽量不分页：预留标题高度 + 一行。
            ensureSpace(dayFont.lineHeight + bodyFont.lineHeight + 8)
            draw(attr(dayTitle(day, trip: trip), dayFont), spacingAfter: 5)

            for item in items {
                switch item {
                case .stop(let s):
                    let time = s.plannedStartMinutes >= 0 ? T.time(minutes: s.plannedStartMinutes) + "   " : ""
                    let head = NSMutableAttributedString(string: time, attributes: [.font: bodyBold, .foregroundColor: UIColor.secondaryLabel])
                    head.append(attr(s.name.isEmpty ? "—" : s.name, bodyBold))
                    draw(head, indent: 10, spacingAfter: 1)
                    if !s.address.isEmpty { draw(attr(s.address, smallFont, .secondaryLabel), indent: 10, spacingAfter: 4) }
                case .transport(let t):
                    draw(attr(transportLine(t), bodyBold), indent: 10, spacingAfter: 1)
                    if let route = transportRoute(t) { draw(attr(route, smallFont, .secondaryLabel), indent: 10, spacingAfter: 4) }
                }
            }
            y += 6
        }

        func drawAccommodation(trip: TripBundle) {
            let stays = trip.safeLodgingStays
            guard !stays.isEmpty else { return }
            ensureSpace(dayFont.lineHeight + bodyFont.lineHeight + 8)
            draw(attr(T.accommodation, dayFont), spacingAfter: 5)
            for stay in stays {
                let title = stay.name.isEmpty ? "—" : stay.name
                draw(attr(title, bodyBold), indent: 10, spacingAfter: 1)
                var line = "\(T.checkIn) – \(T.checkOut) · \(T.nights(stay.nights))"
                if !trip.isDateless {
                    let base = Calendar.current.startOfDay(for: trip.departureDate)
                    let ci = Calendar.current.date(byAdding: .day, value: stay.checkInDayOrder, to: base) ?? base
                    let co = Calendar.current.date(byAdding: .day, value: stay.checkOutDayOrder, to: base) ?? base
                    line = "\(T.dayDate(ci)) – \(T.dayDate(co)) · \(T.nights(stay.nights))"
                }
                draw(attr(line, smallFont, .secondaryLabel), indent: 10, spacingAfter: 1)
                if !stay.address.isEmpty { draw(attr(stay.address, smallFont, .secondaryLabel), indent: 10, spacingAfter: 4) }
            }
        }

        // MARK: 文本拼装

        private func dayTitle(_ day: ItineraryDay, trip: TripBundle) -> String {
            let base = T.dayTitle(day.sortOrder + 1)
            guard !trip.isDateless else { return base }
            let start = Calendar.current.startOfDay(for: trip.departureDate)
            let date = Calendar.current.date(byAdding: .day, value: day.sortOrder, to: start) ?? start
            return "\(base) · \(T.dayDate(date))"
        }

        private func transportLine(_ t: TransportSegment) -> String {
            // 航司名按**所选导出语言**取（航班从航班号解析，否则存的承运方原文）——与设备语言无关。
            // 机场仍显 IATA 码（语言无关），故此处只需本地化航司名。spec: itinerary-flight-name-localization.md。
            let carrier = t.carrierName(forLanguageKey: T.lang.nameLanguageKey)
            let parts = [carrier, t.number].filter { !$0.isEmpty }
            return parts.isEmpty ? T.modeName(t.mode) : parts.joined(separator: " ")
        }

        private func transportRoute(_ t: TransportSegment) -> String? {
            func ep(_ name: String, _ code: String, _ minutes: Int, _ dayOffset: Int) -> String {
                let place = !code.isEmpty ? code : name
                var s = place
                if minutes >= 0 {
                    let time = T.time(minutes: minutes)
                    s = place.isEmpty ? time : "\(place) \(time)"
                    if dayOffset > 0 { s += " +\(dayOffset)" }
                }
                return s
            }
            let from = ep(t.fromName, t.fromCode, t.departLocalMinutes, 0)
            let to = ep(t.toName, t.toCode, t.arriveLocalMinutes, t.arriveDayOrder - t.departDayOrder)
            let f = from.trimmingCharacters(in: .whitespaces)
            let tt = to.trimmingCharacters(in: .whitespaces)
            if f.isEmpty && tt.isEmpty { return nil }
            return "\(f) → \(tt)"
        }

    }
}

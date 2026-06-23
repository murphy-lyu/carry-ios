//
//  PhotoTripReconstructor.swift
//  Carry
//
//  照片回溯行程的编排器（spec: photo-trip-reconstruction.md §交互流程 步骤 4）。
//
//  隐私优先：**全程不请求相册授权、不碰 PHAsset**。用户用 PHPicker 主动挑了哪些照片，
//  就只读那几张——直接从所选图片的数据里解 EXIF（位置 + 拍摄时间 + 缩略图），
//  与系统相册同一个真相源。彻底没有「允许访问所有照片」弹窗。
//
//  串起整条链路（off-main）：
//    PhotosPickerItem.loadTransferable(Data) → CGImageSource 解 EXIF（GPS/时间）+ 生成缩略图
//      → 坐标按 storefront 归一（境内 WGS-84→GCJ-02）
//      → ItineraryPhotoClustering 聚类
//      → CLGeocoder 反向编码命名（~1 req/s 限流）
//      → 组装 PhotoItineraryDraft（内存草稿，交预览页）
//
//  无 GPS / 截图 / 日期越界的照片不进聚类，落「待整理」。iOS 专属。
//

import Foundation
import SwiftUI
import PhotosUI
import CoreLocation
import UIKit
import ImageIO

nonisolated enum PhotoTripReconstructor {

    /// 缩略图最长边像素（约 320pt@2x）。预览页与入库 StopPhoto.thumbnailData 共用此规格。
    static let thumbnailMaxPixel = 640

    /// 读所选照片（慢：载入数据、解 EXIF、生成缩略图）。**有界并发**：同时跑 N 张（N≈核数、封顶 6），
    /// I/O（进程外取字节）与多核解码并行，内存仍被 N 限住（≠ 全量载入）。串行版 50 张要 10–25s，并发后降到数秒。
    /// 每张 → PhotoDraft（缩略图 + 归一坐标 / nil），按所选顺序返回。不请求任何相册权限。
    /// `onItem(已处理数, 本张缩略图)` 每张完成后回调——驱动「真实缩略图逐张浮现」的加载态。
    /// 支持 Task 取消（用户中途退出即止）。
    static func extract(
        items: [PhotosPickerItem],
        isChinaStorefront: Bool,
        onItem: (Int, Data?) async -> Void = { _, _ in }
    ) async -> [PhotoDraft] {
        guard !items.isEmpty else { return [] }
        let maxConcurrent = min(6, max(2, ProcessInfo.processInfo.activeProcessorCount))
        var ordered = [PhotoDraft?](repeating: nil, count: items.count)   // 按所选顺序回填（待整理列表保持原序）
        var processed = 0

        await withTaskGroup(of: (index: Int, draft: PhotoDraft?, thumbnail: Data?).self) { group in
            var next = 0
            func addTask(_ idx: Int) {
                let item = items[idx]
                group.addTask {
                    if Task.isCancelled { return (idx, nil, nil) }
                    // loadTransferable 拿到所选图原始字节（HEIC/JPEG 等）；本张处理完即释放。
                    guard let data = try? await item.loadTransferable(type: Data.self) else {
                        return (idx, nil, nil)
                    }
                    let meta = exifMetadata(from: data, isChinaStorefront: isChinaStorefront)
                    let draft = PhotoDraft(
                        assetLocalIdentifier: item.itemIdentifier ?? "",   // 仅作未来「回相册看原图」的尽力引用
                        timestamp: meta.timestamp ?? .distantPast,         // 无拍摄时间 → 落「不在行程日期」
                        coordinate: meta.coordinate,
                        thumbnailData: meta.thumbnail
                    )
                    return (idx, draft, meta.thumbnail)
                }
            }
            // 预热并发窗口，之后每完成一张补一张——滑动窗口维持 N 并发、内存有界。
            while next < min(maxConcurrent, items.count) { addTask(next); next += 1 }
            for await result in group {
                ordered[result.index] = result.draft
                processed += 1
                await onItem(processed, result.thumbnail)
                if Task.isCancelled { group.cancelAll(); break }
                if next < items.count { addTask(next); next += 1 }
            }
        }
        return ordered.compactMap { $0 }
    }

    /// 组装（快：仅聚类、不命名）。从已读取的 PhotoDraft 重建草稿。
    /// 命名（反向地理编码，慢且被系统限流）已剥离到入预览后台的 `geocodeNames` 流式回填——
    /// 不再阻塞「进入可操作的预览页」（原先这几秒里 UI 卡在 100%、像死机）。
    static func assemble(
        photos: [PhotoDraft],
        tripId: UUID,
        departureDate: Date,
        returnDate: Date,
        config: PhotoClusterConfig = .medium,
        calendar: Calendar = .current
    ) async -> PhotoItineraryDraft {
        let baseline = calendar.startOfDay(for: departureDate)
        let windowEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: returnDate)) ?? returnDate

        // 分流（三类，原因互斥、可诚实告知用户）：
        // ① 有位置 且 日期在区间内 → 进聚类；② 无位置 → noLocation；③ 有位置但日期越界 → outOfRange。
        var valid: [PhotoDraft] = []
        var noLocation: [PhotoDraft] = []
        var outOfRange: [PhotoDraft] = []
        for d in photos {
            guard d.coordinate != nil else { noLocation.append(d); continue }
            if d.timestamp >= baseline, d.timestamp < windowEnd {
                valid.append(d)
            } else {
                outOfRange.append(d)
            }
        }

        guard !valid.isEmpty else {
            return PhotoItineraryDraft(tripId: tripId, departureDay: baseline, days: [],
                                       noLocation: noLocation, outOfRange: outOfRange)
        }

        // 聚类。PhotoPoint 顺序与 valid 一致，photoIndices 即 valid 的下标。
        let points = valid.map { PhotoPoint(id: $0.id, timestamp: $0.timestamp, coordinate: $0.coordinate!) }
        let dayClusters = ItineraryPhotoClustering.clusters(
            from: points, departureDay: departureDate, config: config, calendar: calendar
        )

        // 仅建结构、地点名留空（UI 退「地点 N」占位）；真实地名由 geocodeNames 入预览后台回填。
        var days: [DayDraft] = []
        for dc in dayClusters {
            let places: [PlaceDraft] = dc.places.map { cluster in
                PlaceDraft(
                    name: "",
                    address: "",
                    coordinate: cluster.centroid,
                    category: .sightseeing,
                    firstTime: cluster.firstTime,
                    lastTime: cluster.lastTime,
                    photos: cluster.photoIndices.map { valid[$0] }
                )
            }
            days.append(DayDraft(dayOrder: dc.dayOrder, places: places))
        }

        return PhotoItineraryDraft(tripId: tripId, departureDay: baseline, days: days,
                                   noLocation: noLocation, outOfRange: outOfRange)
    }

    /// 反向地理编码命名——**入预览后台跑**，逐个地点 resolve 即回调回填（≠ 阻塞进入预览）。
    /// 串行 + ~1 req/s 限流（CLGeocoder 被系统限流，并发会触发节流、查空）。
    /// `onResolved(地点 id, 名, 地址)` 每个解析后回调；上层按 id 回填（用户已改名/合并/删的不动）。
    /// 支持 Task 取消（用户中途退出预览即止）。地点不多，顺序限流即可。
    static func geocodeNames(
        for draft: PhotoItineraryDraft,
        onResolved: (UUID, String, String) async -> Void
    ) async {
        let geocoder = CLGeocoder()
        var count = 0
        for day in draft.days {
            for place in day.places {
                if Task.isCancelled { return }
                if count > 0 { try? await Task.sleep(for: .milliseconds(400)) }
                count += 1
                if Task.isCancelled { return }
                let (name, address) = await resolvePlaceName(geocoder, at: place.coordinate)
                if Task.isCancelled { return }
                await onResolved(place.id, name, address)
            }
        }
    }

    // MARK: - 坐标归一

    /// 境内 storefront 把 WGS-84 转 GCJ-02（与项目库内坐标一致）；境外/非大陆原样。
    /// CoordinateTransform 内部对中国境外坐标自动 no-op，故只需按 storefront 决定是否调用。
    static func normalizedCoordinate(_ wgs: CLLocationCoordinate2D, isChinaStorefront: Bool) -> CLLocationCoordinate2D {
        isChinaStorefront ? CoordinateTransform.wgs84ToGcj02(wgs) : wgs
    }

    // MARK: - EXIF 解析（位置 + 时间 + 缩略图，全从所选图数据里读）

    /// 从图片数据用 CGImageSource 一次性解出：GPS（归一后）、拍摄时间、降采样缩略图。
    /// 只读元数据 + 生成缩略图，不全解码原图，内存可控。
    static func exifMetadata(from data: Data, isChinaStorefront: Bool)
        -> (coordinate: CLLocationCoordinate2D?, timestamp: Date?, thumbnail: Data?) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return (nil, nil, nil) }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]

        // 位置：EXIF GPS（WGS-84）→ 按 storefront 归一。
        var coordinate: CLLocationCoordinate2D?
        if let gps = props?[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double,
           lat != 0 || lon != 0 {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String
            let wgs = CLLocationCoordinate2D(latitude: (latRef == "S") ? -lat : lat,
                                             longitude: (lonRef == "W") ? -lon : lon)
            coordinate = normalizedCoordinate(wgs, isChinaStorefront: isChinaStorefront)
        }

        // 时间：优先 EXIF DateTimeOriginal（拍摄时刻），退 TIFF DateTime。皆为本地墙钟、无时区。
        var timestamp: Date?
        if let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            timestamp = parseExifDate(s)
        } else if let tiff = props?[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
                  let s = tiff[kCGImagePropertyTIFFDateTime] as? String {
            timestamp = parseExifDate(s)
        }

        // 缩略图：从源降采样（含方向校正），不全解码原图。
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixel
        ]
        var thumbnail: Data?
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
            thumbnail = UIImage(cgImage: cg).jpegData(compressionQuality: 0.8)
        }

        return (coordinate, timestamp, thumbnail)
    }

    /// EXIF 时间格式 "yyyy:MM:dd HH:mm:ss"，按设备时区解释（与行程日期口径一致）。
    /// 每次新建 DateFormatter——extract 现在并发解码，**DateFormatter 非线程安全**，
    /// 共享单例会在并发访问下崩/读脏数据；每张一个（仅有 EXIF 时间者才走到）、开销远小于解码。
    private static func parseExifDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = .current
        return f.date(from: s)
    }

    // MARK: - 命名

    /// 反向地理编码取 POI 名 + 简短地址。失败返回空名（UI 退「地点 N」占位）。
    private static func resolvePlaceName(_ geocoder: CLGeocoder, at coordinate: CLLocationCoordinate2D) async -> (name: String, address: String) {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else {
            return ("", "")
        }
        // POI 名优先级：兴趣点名 → 地标名 → 街道 → 城市。
        let name = placemark.areasOfInterest?.first
            ?? placemark.name
            ?? placemark.thoroughfare
            ?? placemark.locality
            ?? ""
        // 简短地址：城市 + 区 + 街道（去空去重）。
        let parts = [placemark.locality, placemark.subLocality, placemark.thoroughfare]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let address = parts.filter { seen.insert($0).inserted }.joined(separator: " ")
        return (name, address)
    }
}

//
//  PhotoItineraryDraft.swift
//  Carry
//
//  照片回溯行程的「内存草稿」模型（spec: photo-trip-reconstruction.md §交互流程）。
//
//  聚类 + 命名 + 缩略图的产物先以这套**值类型**草稿渲染预览/微调页；用户在预览页
//  改名/合并/拆分/挪照片都改这份草稿，点「保存」才经 TripStore.importItineraryFromPhotos
//  落库成真正的 ItineraryDay / ItineraryStop / StopPhoto（Phase 4）。
//
//  草稿绝不直接持久化——它是「确认前的初稿」，落库才是结果。
//

import Foundation
import CoreLocation

/// 草稿里的一张照片：相册引用 + EXIF 元数据 + 缩略图字节。
/// coordinate 为 nil 表示无 GPS（截图等）→ 落在「待整理」。
nonisolated struct PhotoDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    let assetLocalIdentifier: String
    let timestamp: Date
    /// 已按 storefront 归一坐标系（境内 GCJ-02 / 境外 WGS-84）；nil = 无位置。
    let coordinate: CLLocationCoordinate2D?
    var thumbnailData: Data?

    init(id: UUID = UUID(), assetLocalIdentifier: String, timestamp: Date, coordinate: CLLocationCoordinate2D?, thumbnailData: Data? = nil) {
        self.id = id
        self.assetLocalIdentifier = assetLocalIdentifier
        self.timestamp = timestamp
        self.coordinate = coordinate
        self.thumbnailData = thumbnailData
    }

    static func == (lhs: PhotoDraft, rhs: PhotoDraft) -> Bool { lhs.id == rhs.id }
}

/// 草稿里的一个地点：聚类质心 + 命名 + 时段 + 类别 + 成员照片。预览页可编辑各字段。
nonisolated struct PlaceDraft: Identifiable, Equatable {
    let id: UUID
    var name: String            // 反向地理编码得名；空 → UI 展示「地点 N」占位
    var address: String
    var coordinate: CLLocationCoordinate2D
    var category: StopCategory  // EXIF 无类别，默认 .sightseeing，用户可改
    var firstTime: Date
    var lastTime: Date
    var photos: [PhotoDraft]

    init(id: UUID = UUID(), name: String = "", address: String = "", coordinate: CLLocationCoordinate2D, category: StopCategory = .sightseeing, firstTime: Date, lastTime: Date, photos: [PhotoDraft]) {
        self.id = id
        self.name = name
        self.address = address
        self.coordinate = coordinate
        self.category = category
        self.firstTime = firstTime
        self.lastTime = lastTime
        self.photos = photos
    }

    var photoCount: Int { photos.count }

    /// 当天计划时段起点（首张照片自本地午夜的分钟数），对齐 ItineraryStop.plannedStartMinutes。
    func plannedStartMinutes(calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: firstTime)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// 预计停留时长（分钟），对齐 ItineraryStop.stayMinutes（单张为 0）。
    var stayMinutes: Int { max(0, Int(lastTime.timeIntervalSince(firstTime) / 60)) }

    static func == (lhs: PlaceDraft, rhs: PlaceDraft) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.photos == rhs.photos
    }
}

/// 草稿里的一天：dayOrder + 按时间升序的地点。
nonisolated struct DayDraft: Identifiable, Equatable {
    let id: UUID
    var dayOrder: Int           // 0-based，对齐 ItineraryDay.sortOrder
    var places: [PlaceDraft]

    init(id: UUID = UUID(), dayOrder: Int, places: [PlaceDraft]) {
        self.id = id
        self.dayOrder = dayOrder
        self.places = places
    }
}

/// 一份完整草稿：归属行程 + 各天地点 + 待整理照片。
nonisolated struct PhotoItineraryDraft: Equatable {
    var tripId: UUID
    var departureDay: Date
    var days: [DayDraft]
    /// 文件里真没 GPS（截图 / 转存图 / 拍摄时关了定位）——系统相册同样显示无位置。
    var noLocation: [PhotoDraft]
    /// 有位置、但拍摄日不在行程「出发~返程」区间内。
    var outOfRange: [PhotoDraft]

    /// 未能落入行程的照片总数（两类合计）。
    var excludedCount: Int { noLocation.count + outOfRange.count }

    var totalPhotoCount: Int {
        days.flatMap { $0.places }.reduce(0) { $0 + $1.photoCount } + excludedCount
    }
    var placeCount: Int { days.reduce(0) { $0 + $1.places.count } }
}

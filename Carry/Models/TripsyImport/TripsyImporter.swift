//
//  TripsyImporter.swift
//  Carry
//
//  从 Tripsy 导入（spec: tripsy-import.md）。
//  读 Tripsy 导出的 zip（Core Data SQLite + Documents/ 图片）→ 转换为 Carry 的
//  CarryBackup 值对象 → 交给 DataBackupManager.mergeFromData 合并导入（复用去重 /
//  附件字节写回 / 通知·Live Activity·widget 副作用，零新增还原逻辑）。
//
//  转换的三处要害（详见 spec）：
//  1. 时间：Tripsy 存「绝对时间戳 + 每条目 IANA 时区」→ Carry 的「相对天序 + 当地分钟」。
//  2. 天数：Carry spanDays = days + 1；生成正好 span 天、days = span - 1，避免多出空尾天。
//  3. 未排期点：Carry 无暂存桶且 dated 行程不能加无日期尾天 → 按地理就近并入已排期那天。
//

import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - 对外结果类型

/// 单个待导入行程的草稿（已转换好 BackupTrip + 其附件字节）。预览页据此勾选，确认后才编码导入。
nonisolated struct TripsyTripDraft: Identifiable {
    let id: UUID
    let name: String
    let destinationCity: String
    let isDateless: Bool
    let dateRangeText: String       // 预览展示用（dated → "May 1 – May 6"；dateless → ""）
    let placeCount: Int
    let transportCount: Int
    let lodgingCount: Int
    let backupTrip: BackupTrip
    let attachmentFiles: [String: Data]
}

nonisolated struct TripsyParseResult {
    let drafts: [TripsyTripDraft]
}

nonisolated enum TripsyImportError: LocalizedError {
    case notTripsyBackup    // 不是 Tripsy 导出（找不到 sqlite / 解压失败）
    case empty              // 库里没有可导入的行程

    var errorDescription: String? {
        switch self {
        case .notTripsyBackup:
            return NSLocalizedString("tripsy_import.error.not_tripsy", comment: "")
        case .empty:
            return NSLocalizedString("tripsy_import.error.empty", comment: "")
        }
    }
}

// MARK: - 导入器

enum TripsyImporter {

    /// 解析 zip → 行程草稿列表。不写库；图片字节已读进内存，可在返回前清理临时目录。
    /// `nonisolated`：从 `Task.detached` 后台调用；整条解析链（ZipReader/SQLite/Converter）皆 nonisolated。
    /// `makeBackup` 不在此列——它从 @MainActor 的 performImport 调用、且要碰 @MainActor 的
    /// `currentBackupVersion`，故留在主 actor。
    nonisolated static func parse(zipData: Data) throws -> TripsyParseResult {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tripsy-import-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        do { try TripsyZipReader.extract(zipData: zipData, to: tmp) }
        catch { throw TripsyImportError.notTripsyBackup }

        // 定位 .sqlite（任意子路径）。-wal/-shm 与之同目录，SQLite 会自动识别。
        guard let dbURL = firstFile(in: tmp, withExtension: "sqlite") else {
            throw TripsyImportError.notTripsyBackup
        }
        let documentsDir = tmp.appendingPathComponent("Documents", isDirectory: true)

        guard let db = try? TripsySQLite(path: dbURL.path), db.tableExists("ZTRIP") else {
            throw TripsyImportError.notTripsyBackup
        }

        let drafts = Converter(db: db, documentsDir: documentsDir).buildDrafts()
        guard !drafts.isEmpty else { throw TripsyImportError.empty }
        return TripsyParseResult(drafts: drafts)
    }

    /// 把选中的草稿组装成内存中的 `CarryBackup`，直接交给 `TripStore.mergeBackup`（不经 JSON 往返）。
    static func makeBackup(from drafts: [TripsyTripDraft]) -> CarryBackup? {
        guard !drafts.isEmpty else { return nil }
        var files: [String: Data] = [:]
        for d in drafts { for (k, v) in d.attachmentFiles { files[k] = v } }
        return CarryBackup(
            version: DataBackupManager.currentBackupVersion,
            createdAt: Date(),
            trips: drafts.map(\.backupTrip),
            myItems: [],
            defaultReminderOffsets: nil,
            backgroundImages: nil,
            attachmentFiles: files.isEmpty ? nil : files
        )
    }

    nonisolated private static func firstFile(in dir: URL, withExtension ext: String) -> URL? {
        guard let it = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in it where url.pathExtension.lowercased() == ext {
            return url
        }
        return nil
    }
}

// MARK: - 转换核心

private nonisolated final class Converter {
    let db: TripsySQLite
    let documentsDir: URL
    /// 本次解析读出的附件原文件字节（文件名 → 字节），buildTrip 末尾据此收集进 draft。
    private var bytesCache: [String: Data] = [:]

    init(db: TripsySQLite, documentsDir: URL) {
        self.db = db
        self.documentsDir = documentsDir
    }

    /// Core Data 参考纪元（2001-01-01 UTC）下的午夜历法计算用 UTC 日历。
    private static let utcCal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    func buildDrafts() -> [TripsyTripDraft] {
        // 一次性把各表读进内存，按 Z_PK 建索引。
        let trips = db.query("SELECT * FROM ZTRIP;")
        let activities = indexByPK(db.query("SELECT * FROM ZACTIVITY;"))
        let transports = indexByPK(db.query("SELECT * FROM ZTRANSPORTATION;"))
        let hostings = indexByPK(db.query("SELECT * FROM ZHOSTING;"))
        let generals = db.tableExists("ZGENERALACTIVITY") ? db.query("SELECT * FROM ZGENERALACTIVITY;") : []
        let geocoded = db.tableExists("ZGEOCODEDLOCATION") ? db.query("SELECT * FROM ZGEOCODEDLOCATION;") : []
        let documents = indexByPK(db.query("SELECT * FROM ZDOCUMENT;"))
        let docLinks = db.tableExists("Z_1DOCUMENTS") ? db.query("SELECT * FROM Z_1DOCUMENTS;") : []

        // 行程归属：ZGENERALACTIVITY 是唯一真源。tripPK → [(kind, entityPK, zdate)]
        var membership: [Int: [(kind: String, pk: Int, zdate: Date?)]] = [:]
        for g in generals {
            guard let tripPK = g.int("ZTRIP"), tripPK != 0 else { continue }   // 孤儿（无所属行程）跳过
            let zdate = g.coreDataDate("ZDATE")
            if let a = g.int("ZACTIVITY"), a != 0 { membership[tripPK, default: []].append(("activity", a, zdate)) }
            else if let t = g.int("ZTRANSPORTATION"), t != 0 { membership[tripPK, default: []].append(("transport", t, zdate)) }
            else if let h = g.int("ZHOSTING"), h != 0 { membership[tripPK, default: []].append(("hosting", h, zdate)) }
        }

        // 文档归属（仅 Activity 挂文档）：activityPK → [documentPK]
        var docByActivity: [Int: [Int]] = [:]
        for l in docLinks {
            if let aPK = l.int("Z_1ACTIVITIES1"), let dPK = l.int("Z_3DOCUMENTS") {
                docByActivity[aPK, default: []].append(dPK)
            }
        }

        let geo = geocoded.compactMap { r -> (lat: Double, lng: Double, code: String)? in
            guard let la = r.double("ZLATITUDE"), let lo = r.double("ZLONGITUDE"),
                  !r.string("ZCOUNTRYCODE").isEmpty else { return nil }
            return (la, lo, r.string("ZCOUNTRYCODE"))
        }

        var drafts: [TripsyTripDraft] = []
        for trip in trips {
            // 单行程异常隔离：任一行程转换抛错 → 跳过该行程，不中断整次导入。
            guard let tripPK = trip.int("Z_PK") else { continue }
            let members = membership[tripPK] ?? []
            if members.isEmpty { continue }   // 空行程不导入
            if let draft = buildTrip(trip: trip, members: members,
                                     activities: activities, transports: transports, hostings: hostings,
                                     documents: documents, docByActivity: docByActivity, geo: geo) {
                drafts.append(draft)
            }
        }
        return drafts
    }

    // MARK: 单行程

    private func buildTrip(
        trip: TripsyRow, members: [(kind: String, pk: Int, zdate: Date?)],
        activities: [Int: TripsyRow], transports: [Int: TripsyRow], hostings: [Int: TripsyRow],
        documents: [Int: TripsyRow], docByActivity: [Int: [Int]],
        geo: [(lat: Double, lng: Double, code: String)]
    ) -> TripsyTripDraft? {
        let tripIdent = identifier(trip, table: "trip")
        let isDateless = !trip.bool("ZHASDATES")
        let defaultTZ = canonicalTZ(trip.string("ZDEFAULTTIMEZONE"))

        // day0 = 行程起始日。⚠️ Tripsy 把行程起止存为「默认时区的当地午夜」再以 UTC 表示
        //（+8 行程会落在前一天 16:00 UTC）→ 必须在默认时区里取历法日期，绝不能按 UTC 日期，
        // 否则全行程日期早一天、且真正最后一天的条目被顶出范围、天数多一天。
        var day0: (y: Int, m: Int, d: Int)? = nil
        var endDate: (y: Int, m: Int, d: Int)? = nil
        if !isDateless, let s = trip.coreDataDate("ZSTARTS") {
            day0 = localYMD(s, defaultTZ)
            if let e = trip.coreDataDate("ZENDS") { endDate = localYMD(e, defaultTZ) }
        }

        // 先把每个条目解析成中间态，拿到「排期时刻」用于算天序。
        struct StopWork { var row: TripsyRow; var pk: Int; var instant: Date?; var tz: TimeZone }
        struct SegWork { var row: TripsyRow; var pk: Int; var depInstant: Date?; var arrInstant: Date?; var depTZ: TimeZone; var arrTZ: TimeZone }
        struct StayWork { var row: TripsyRow; var pk: Int; var inInstant: Date?; var outInstant: Date?; var tz: TimeZone }

        var stopWorks: [StopWork] = []
        var segWorks: [SegWork] = []
        var stayWorks: [StayWork] = []

        for m in members {
            switch m.kind {
            case "activity":
                guard let r = activities[m.pk] else { continue }
                let tz = canonicalTZ(r.string("ZTIMEZONE"), fallback: defaultTZ)
                stopWorks.append(StopWork(row: r, pk: m.pk, instant: r.coreDataDate("ZSTARTS") ?? m.zdate, tz: tz))
            case "transport":
                guard let r = transports[m.pk] else { continue }
                let dtz = canonicalTZ(r.string("ZDEPARTURETIMEZONE"), fallback: defaultTZ)
                let atz = canonicalTZ(r.string("ZARRIVALTIMEZONE"), fallback: dtz)
                segWorks.append(SegWork(row: r, pk: m.pk,
                                        depInstant: r.coreDataDate("ZDEPARTURE") ?? m.zdate,
                                        arrInstant: r.coreDataDate("ZARRIVAL"),
                                        depTZ: dtz, arrTZ: atz))
            case "hosting":
                guard let r = hostings[m.pk] else { continue }
                let tz = canonicalTZ(r.string("ZTIMEZONE"), fallback: defaultTZ)
                stayWorks.append(StayWork(row: r, pk: m.pk,
                                          inInstant: r.coreDataDate("ZSTARTS") ?? m.zdate,
                                          outInstant: r.coreDataDate("ZENDS"),
                                          tz: tz))
            default: break
            }
        }

        // 计算天序：dateless → 全部第 0 天；dated → 按 day0 折算。
        func order(_ instant: Date?, _ tz: TimeZone) -> Int? {
            guard !isDateless, let d0 = day0, let inst = instant else { return isDateless ? 0 : nil }
            let l = localYMD(inst, tz)
            return dayDiff(from: d0, to: l)
        }

        // 已排期天序集合 → 决定 span。
        var orders: [Int] = []
        for sw in stopWorks { if let o = order(sw.instant, sw.tz) { orders.append(o) } }
        for sg in segWorks {
            if let o = order(sg.depInstant, sg.depTZ) { orders.append(o) }
            if let o = order(sg.arrInstant, sg.arrTZ) { orders.append(o) }
        }
        for st in stayWorks { if let o = order(st.inInstant, st.tz) { orders.append(o) } }

        let span: Int
        if isDateless {
            span = 1
        } else {
            var dateSpan = 1
            if let d0 = day0, let e = endDate { dateSpan = max(1, dayDiff(from: d0, to: e) + 1) }
            let maxOrder = orders.filter { $0 >= 0 }.max() ?? 0
            span = max(dateSpan, maxOrder + 1)
        }
        func clamp(_ o: Int) -> Int { max(0, min(o, span - 1)) }

        // —— 构建停靠点 ——（按天分桶）
        var stopsByDay: [Int: [BackupItineraryStop]] = [:]
        var scheduledStopCoords: [(lat: Double, lng: Double, day: Int)] = []   // 供未排期点就近归并
        var undatedStops: [(row: TripsyRow, pk: Int)] = []

        for sw in stopWorks {
            if let o = order(sw.instant, sw.tz) {
                let day = clamp(o)
                let minutes = sw.instant.map { localMinutes($0, sw.tz) } ?? -1
                let stop = makeStop(sw.row, pk: sw.pk, plannedStartMinutes: minutes, tz: sw.tz,
                                    documents: documents, docPKs: docByActivity[sw.pk] ?? [])
                stopsByDay[day, default: []].append(stop)
                if stop.latitude != 0 || stop.longitude != 0 {
                    scheduledStopCoords.append((stop.latitude, stop.longitude, day))
                }
            } else {
                undatedStops.append((sw.row, sw.pk))   // 无排期时刻 → 稍后地理归并
            }
        }
        // 未排期点：就近并入已排期那天；无锚点则放最后一天。plannedStartMinutes = -1。
        for u in undatedStops {
            let stop = makeStop(u.row, pk: u.pk, plannedStartMinutes: -1, tz: defaultTZ,
                                documents: documents, docPKs: docByActivity[u.pk] ?? [])
            let day = nearestDay(lat: stop.latitude, lng: stop.longitude,
                                 anchors: scheduledStopCoords) ?? (span - 1)
            stopsByDay[day, default: []].append(stop)
        }

        // —— 构建交通段 ——（挂出发那天）
        var segsByDay: [Int: [BackupTransportSegment]] = [:]
        for sg in segWorks {
            let depOrder = order(sg.depInstant, sg.depTZ).map(clamp) ?? 0
            let arrOrder = order(sg.arrInstant, sg.arrTZ).map(clamp) ?? depOrder
            let depMin = sg.depInstant.map { localMinutes($0, sg.depTZ) } ?? -1
            let arrMin = sg.arrInstant.map { localMinutes($0, sg.arrTZ) } ?? -1
            let seg = makeSegment(sg.row, pk: sg.pk,
                                  departDayOrder: depOrder, departLocalMinutes: depMin,
                                  arriveDayOrder: max(depOrder, arrOrder), arriveLocalMinutes: arrMin,
                                  depTZ: sg.depTZ, arrTZ: sg.arrTZ)
            segsByDay[depOrder, default: []].append(seg)
        }

        // —— 构建住宿 ——（trip 级，checkInDayOrder 锚定）
        var lodging: [BackupLodgingStay] = []
        for (i, st) in stayWorks.enumerated() {
            let checkInOrder = order(st.inInstant, st.tz).map(clamp) ?? 0
            var nights = 1
            if let ci = st.inInstant, let co = st.outInstant {
                let a = localYMD(ci, st.tz), b = localYMD(co, st.tz)
                nights = max(1, dayDiff(from: a, to: b))
            }
            let checkInMin = st.inInstant.map { localMinutes($0, st.tz) } ?? -1
            let checkOutMin = st.outInstant.map { localMinutes($0, st.tz) } ?? -1
            lodging.append(makeLodging(st.row, pk: st.pk, sortOrder: i,
                                       checkInDayOrder: checkInOrder, nights: nights,
                                       checkInMinutes: checkInMin, checkOutMinutes: checkOutMin, tz: st.tz))
        }

        // —— 组装天 ——（0..<span 全部建出，含空天，使天数对齐 spanDays）
        var days: [BackupItineraryDay] = []
        for o in 0..<span {
            var stops = stopsByDay[o] ?? []
            stops.sort { lhs, rhs in
                let lm = lhs.plannedStartMinutes, rm = rhs.plannedStartMinutes
                if (lm < 0) != (rm < 0) { return lm >= 0 }     // 有时间的排前
                if lm != rm { return lm < rm }
                return lhs.name < rhs.name
            }
            for i in stops.indices { stops[i].sortOrder = i }
            var segs = (segsByDay[o] ?? []).sorted { $0.departLocalMinutes < $1.departLocalMinutes }
            for i in segs.indices { segs[i].sortOrder = i }
            days.append(BackupItineraryDay(
                id: TripsyUUID.make("day|\(tripIdent)|\(o)"),
                sortOrder: o, title: "", note: "",
                stops: stops, segments: segs.isEmpty ? nil : segs))
        }

        // —— 行程元信息 ——
        let name = trip.string("ZNAME")
        let city = destinationCity(from: name)
        let primaryCoord = representativeCoordinate(days: days, lodging: lodging)
        let countryCode = resolveCountryCode(coord: primaryCoord, members: stopWorks.map(\.row) + stayWorks.map(\.row), geo: geo)

        var departureDate = Date()
        var dateRangeText = ""
        if !isDateless, let d0 = day0 {
            departureDate = noonUTC(d0)
            let end = endDate ?? d0
            dateRangeText = formatRange(noonUTC(d0), noonUTC(end))
        }

        let placeCount = days.reduce(0) { $0 + $1.stops.count }
        let transportCount = days.reduce(0) { $0 + ($1.segments?.count ?? 0) }

        let bt = BackupTrip(
            id: TripsyUUID.make("trip|\(tripIdent)"),
            name: name,
            destinationCity: city,
            days: span - 1,
            dateRange: dateRangeText,
            departureDate: departureDate,
            isDateless: isDateless,
            createdAt: trip.coreDataDate("ZINTERNALCREATEDAT") ?? Date(),
            selectedSceneKeys: [],
            dismissedSurpriseNames: [],
            sceneCardDismissed: false,
            remindersEnabled: false,
            reminderConfigData: Data(),
            countryCode: countryCode,
            latitude: primaryCoord?.lat ?? 0,
            longitude: primaryCoord?.lng ?? 0,
            additionalDestinationsData: nil,
            backgroundsData: nil,
            sections: [],                       // Tripsy 无打包清单概念
            itineraryDays: days.isEmpty ? nil : days,
            lodgingStays: lodging.isEmpty ? nil : lodging
        )

        // 收集该行程的附件字节
        var files: [String: Data] = [:]
        for day in days {
            for stop in day.stops {
                for att in stop.attachments ?? [] where !att.fileName.isEmpty {
                    if let bytes = bytesCache[att.fileName] { files[att.fileName] = bytes }
                }
            }
        }

        return TripsyTripDraft(
            id: bt.id, name: name, destinationCity: city, isDateless: isDateless,
            dateRangeText: dateRangeText, placeCount: placeCount,
            transportCount: transportCount, lodgingCount: lodging.count,
            backupTrip: bt, attachmentFiles: files)
    }

    // MARK: 实体映射

    private func makeStop(_ r: TripsyRow, pk: Int, plannedStartMinutes: Int, tz: TimeZone,
                          documents: [Int: TripsyRow], docPKs: [Int]) -> BackupItineraryStop {
        let starts = r.coreDataDate("ZSTARTS")
        let ends = r.coreDataDate("ZENDS")
        var stayMinutes = 0
        if let s = starts, let e = ends, e > s { stayMinutes = Int(e.timeIntervalSince(s) / 60) }

        let note = joinNotes([
            r.string("ZNOTES"), r.string("ZDESCRIPTIONTEXT"),
            labeled("tripsy_import.note.reservation", r.string("ZRESERVATIONCODE")),
            labeled("tripsy_import.note.website", r.string("ZWEBSITE")),
        ])
        let cost = r.double("ZPRICE") ?? 0
        var stop = BackupItineraryStop(
            id: TripsyUUID.make("stop|\(identifier(r, table: "activity", pk: pk))"),
            name: r.string("ZNAME"),
            latitude: r.double("ZLATITUDE") ?? 0,
            longitude: r.double("ZLONGITUDE") ?? 0,
            address: r.string("ZADDRESS"),
            categoryRaw: stopCategory(for: r.string("ZINTERNALTYPE")),
            plannedStartMinutes: plannedStartMinutes,
            stayMinutes: stayMinutes,
            note: note,
            sortOrder: 0,
            costAmount: cost > 0 ? cost : nil,
            costCurrencyCode: cost > 0 ? r.string("ZCURRENCY") : nil,
            costHomeAmount: nil,
            phone: r.string("ZPHONE"),
            timeZoneId: tz.identifier)
        let atts = makeAttachments(docPKs: docPKs, documents: documents)
        stop.attachments = atts.isEmpty ? nil : atts
        return stop
    }

    private func makeSegment(_ r: TripsyRow, pk: Int,
                             departDayOrder: Int, departLocalMinutes: Int,
                             arriveDayOrder: Int, arriveLocalMinutes: Int,
                             depTZ: TimeZone, arrTZ: TimeZone) -> BackupTransportSegment {
        let type = r.string("ZINTERNALTYPE")
        let isAir = type == "airplane"
        let fromCode = isAir ? r.string("ZDEPARTUREDESCRIPTION") : ""
        let toCode = isAir ? r.string("ZARRIVALDESCRIPTION") : ""
        let note = joinNotes([
            r.string("ZNOTES"), r.string("ZDESCRIPTIONTEXT"),
            labeled("tripsy_import.note.cabin", r.string("ZSEATCLASS")),
            labeled("tripsy_import.note.dep_gate", r.string("ZDEPARTUREGATE")),
            labeled("tripsy_import.note.arr_gate", r.string("ZARRIVALGATE")),
            labeled("tripsy_import.note.website", r.string("ZWEBSITE")),
        ])
        let cost = r.double("ZPRICE") ?? 0
        return BackupTransportSegment(
            id: TripsyUUID.make("seg|\(identifier(r, table: "transport", pk: pk))"),
            modeRaw: transportMode(for: type),
            carrier: r.string("ZCOMPANY"),
            number: r.string("ZTRANSPORTNUMBER"),
            fromName: isAir ? fromCode : r.string("ZDEPARTUREADDRESS"),    // 机场全名 Tripsy 不存，用 IATA 码占位
            fromCode: fromCode,
            fromLatitude: r.double("ZDEPARTURELATITUDE") ?? 0,
            fromLongitude: r.double("ZDEPARTURELONGITUDE") ?? 0,
            fromTimeZoneId: depTZ.identifier,
            fromTerminal: r.string("ZDEPARTURETERMINAL"),
            toName: isAir ? toCode : r.string("ZARRIVALADDRESS"),
            toCode: toCode,
            toLatitude: r.double("ZARRIVALLATITUDE") ?? 0,
            toLongitude: r.double("ZARRIVALLONGITUDE") ?? 0,
            toTimeZoneId: arrTZ.identifier,
            toTerminal: r.string("ZARRIVALTERMINAL"),
            departDayOrder: departDayOrder,
            departLocalMinutes: departLocalMinutes,
            arriveDayOrder: arriveDayOrder,
            arriveLocalMinutes: arriveLocalMinutes,
            seat: r.string("ZSEATNUMBER"),
            confirmationCode: r.string("ZRESERVATIONCODE"),
            note: note,
            sortOrder: 0,
            costAmount: cost > 0 ? cost : nil,
            costCurrencyCode: cost > 0 ? r.string("ZCURRENCY") : nil,
            costHomeAmount: nil,
            distanceMeters: (r.double("ZDISTANCEINMETERS")).flatMap { $0 > 0 ? $0 : nil },
            vehicleModel: r.string("ZVEHICLEDESCRIPTION").isEmpty ? nil : r.string("ZVEHICLEDESCRIPTION"),
            fromAddress: r.string("ZDEPARTUREADDRESS").isEmpty ? nil : r.string("ZDEPARTUREADDRESS"),
            toAddress: r.string("ZARRIVALADDRESS").isEmpty ? nil : r.string("ZARRIVALADDRESS"),
            phone: r.string("ZPHONE").isEmpty ? nil : r.string("ZPHONE"))
    }

    private func makeLodging(_ r: TripsyRow, pk: Int, sortOrder: Int,
                             checkInDayOrder: Int, nights: Int,
                             checkInMinutes: Int, checkOutMinutes: Int, tz: TimeZone) -> BackupLodgingStay {
        let note = joinNotes([
            r.string("ZNOTES"), r.string("ZDESCRIPTIONTEXT"),
            labeled("tripsy_import.note.room", [r.string("ZROOMTYPE"), r.string("ZROOMNUMBER")]
                .filter { !$0.isEmpty }.joined(separator: " ")),
            labeled("tripsy_import.note.website", r.string("ZWEBSITE")),
        ])
        let cost = r.double("ZPRICE") ?? 0
        return BackupLodgingStay(
            id: TripsyUUID.make("stay|\(identifier(r, table: "hosting", pk: pk))"),
            name: r.string("ZNAME"),
            address: r.string("ZADDRESS"),
            latitude: r.double("ZLATITUDE") ?? 0,
            longitude: r.double("ZLONGITUDE") ?? 0,
            checkInDayOrder: checkInDayOrder,
            nights: nights,
            checkInMinutes: checkInMinutes,
            checkOutMinutes: checkOutMinutes,
            confirmationCode: r.string("ZRESERVATIONCODE"),
            note: note,
            sortOrder: sortOrder,
            costAmount: cost > 0 ? cost : nil,
            costCurrencyCode: cost > 0 ? r.string("ZCURRENCY") : nil,
            costHomeAmount: nil,
            phone: r.string("ZPHONE"),
            timeZoneId: tz.identifier)
    }

    // MARK: 附件

    private func makeAttachments(docPKs: [Int], documents: [Int: TripsyRow]) -> [BackupAttachment] {
        var result: [BackupAttachment] = []
        for (i, dPK) in docPKs.enumerated() {
            guard let doc = documents[dPK] else { continue }
            let ident = identifier(doc, table: "document", pk: dPK)
            let attID = TripsyUUID.make("att|\(ident)")
            let fileType = doc.string("ZFILETYPE")
            let title = doc.string("ZTITLE")
            let urlStr = doc.string("ZURL")
            let localPath = doc.string("ZLOCALPATH")

            // 本地文件：在 Documents/ 内按 ZLOCALPATH 末段（百分号解码）匹配。
            if !localPath.isEmpty, let bytes = localFileBytes(localPath: localPath) {
                let isImage = fileType.hasPrefix("image/")
                let ext = (URL(string: localPath)?.pathExtension.lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "dat"
                let fileName = "\(attID.uuidString).\(ext)"
                bytesCache[fileName] = bytes
                let thumb = isImage ? (makeThumbnail(bytes) ?? Data()) : Data()
                result.append(BackupAttachment(
                    id: attID, kindRaw: (isImage ? AttachmentKind.photo : .file).rawValue,
                    displayName: title.isEmpty ? fileName : title,
                    fileName: fileName, utiOrExt: ext, urlString: "",
                    thumbnailData: thumb, sortOrder: i, addedAt: doc.coreDataDate("ZCREATEDAT") ?? Date()))
            } else {
                // 链接型（含 Tripsy 的过期 S3 URL）。
                let link = !urlStr.isEmpty ? urlStr : title
                guard !link.isEmpty else { continue }
                result.append(BackupAttachment(
                    id: attID, kindRaw: AttachmentKind.link.rawValue,
                    displayName: title.isEmpty ? link : title,
                    fileName: "", utiOrExt: "", urlString: link,
                    thumbnailData: Data(), sortOrder: i, addedAt: doc.coreDataDate("ZCREATEDAT") ?? Date()))
            }
        }
        return result
    }

    private func localFileBytes(localPath: String) -> Data? {
        // ZLOCALPATH 形如 file:///.../Documents/<前缀>-<名>.jpeg（百分号编码）。
        let last = (URL(string: localPath)?.lastPathComponent)
            ?? (localPath as NSString).lastPathComponent
        let decoded = last.removingPercentEncoding ?? last
        let url = documentsDir.appendingPathComponent(decoded)
        if let d = try? Data(contentsOf: url) { return d }
        // 兜底：按前缀（'-' 之前）在 Documents/ 内模糊匹配（防文件名细微差异）。
        let prefix = decoded.split(separator: "-").first.map(String.init) ?? decoded
        if let items = try? FileManager.default.contentsOfDirectory(atPath: documentsDir.path),
           let hit = items.first(where: { $0.hasPrefix(prefix) }) {
            return try? Data(contentsOf: documentsDir.appendingPathComponent(hit))
        }
        return nil
    }

    /// ImageIO 生成小缩略图（最长边 ~320px，JPEG）。失败返回 nil（UI 退化为图标）。
    private func makeThumbnail(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let dst = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(dst, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return dst as Data
    }

    // MARK: 类目映射

    private func stopCategory(for type: String) -> String {
        switch type {
        case "tour":       return StopCategory.sightseeing.rawValue
        case "museum":     return StopCategory.museum.rawValue
        case "park":       return StopCategory.park.rawValue
        case "restaurant": return StopCategory.restaurant.rawValue
        case "cafe":       return StopCategory.cafe.rawValue
        default:           return StopCategory.other.rawValue   // parking / general / 未知
        }
    }

    private func transportMode(for type: String) -> String {
        switch type {
        case "airplane": return TransportMode.flight.rawValue
        case "car": return TransportMode.carRental.rawValue
        case "train": return TransportMode.train.rawValue
        case "bus": return TransportMode.bus.rawValue
        case "ferry": return TransportMode.ferry.rawValue
        default: return TransportMode.other.rawValue   // roadtrip / 未知
        }
    }

    // MARK: 时间 / 地理 助手

    private func canonicalTZ(_ id: String, fallback: TimeZone? = nil) -> TimeZone {
        if !id.isEmpty, let tz = TimeZone(identifier: TimeZoneCanonicalizer.canonical(id)) { return tz }
        return fallback ?? TimeZone(identifier: "Asia/Shanghai")!
    }

    private func localYMD(_ date: Date, _ tz: TimeZone) -> (y: Int, m: Int, d: Int) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return (c.year!, c.month!, c.day!)
    }
    private func localMinutes(_ date: Date, _ tz: TimeZone) -> Int {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let c = cal.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    private func midnightUTC(_ ymd: (y: Int, m: Int, d: Int)) -> Date {
        Self.utcCal.date(from: DateComponents(year: ymd.y, month: ymd.m, day: ymd.d)) ?? Date(timeIntervalSinceReferenceDate: 0)
    }
    private func noonUTC(_ ymd: (y: Int, m: Int, d: Int)) -> Date {
        midnightUTC(ymd).addingTimeInterval(12 * 3600)   // 正午锚点：任何设备时区都不跨日，避免显示差一天
    }
    private func dayDiff(from a: (y: Int, m: Int, d: Int), to b: (y: Int, m: Int, d: Int)) -> Int {
        Int(round(midnightUTC(b).timeIntervalSince(midnightUTC(a)) / 86400))
    }

    private func nearestDay(lat: Double, lng: Double, anchors: [(lat: Double, lng: Double, day: Int)]) -> Int? {
        guard lat != 0 || lng != 0 else { return nil }
        var best: (d: Int, dist: Double)? = nil
        for a in anchors {
            let dist = haversine(lat, lng, a.lat, a.lng)
            if best == nil || dist < best!.dist { best = (a.day, dist) }
        }
        return best?.d
    }
    private func haversine(_ la1: Double, _ lo1: Double, _ la2: Double, _ lo2: Double) -> Double {
        let r = 6_371_000.0, p = Double.pi / 180
        let dLa = (la2 - la1) * p, dLo = (lo2 - lo1) * p
        let h = sin(dLa / 2) * sin(dLa / 2) + cos(la1 * p) * cos(la2 * p) * sin(dLo / 2) * sin(dLo / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    private func representativeCoordinate(days: [BackupItineraryDay], lodging: [BackupLodgingStay]) -> (lat: Double, lng: Double)? {
        if let l = lodging.first(where: { $0.latitude != 0 || $0.longitude != 0 }) { return (l.latitude, l.longitude) }
        for day in days {
            if let s = day.stops.first(where: { $0.latitude != 0 || $0.longitude != 0 }) { return (s.latitude, s.longitude) }
            if let g = day.segments?.first(where: { $0.toLatitude != 0 || $0.toLongitude != 0 }) { return (g.toLatitude, g.toLongitude) }
        }
        return nil
    }

    private func resolveCountryCode(coord: (lat: Double, lng: Double)?,
                                    members: [TripsyRow],
                                    geo: [(lat: Double, lng: Double, code: String)]) -> String {
        // 1) 坐标就近匹配 ZGEOCODEDLOCATION（≤80km）
        if let c = coord {
            var best: (code: String, dist: Double)? = nil
            for g in geo {
                let dist = haversine(c.lat, c.lng, g.lat, g.lng)
                if best == nil || dist < best!.dist { best = (g.code, dist) }
            }
            if let b = best, b.dist < 80_000 { return b.code.uppercased() }
        }
        // 2) 地址含「中国/中國」→ CN
        if members.contains(where: { $0.string("ZADDRESS").contains("中国") || $0.string("ZADDRESS").contains("中國") }) {
            return "CN"
        }
        return ""
    }

    // MARK: 文本 / 标识 助手

    private func destinationCity(from name: String) -> String {
        for sep in ["•", "·", "・"] where name.contains(sep) {
            if let last = name.components(separatedBy: sep).last?.trimmingCharacters(in: .whitespaces), !last.isEmpty {
                return last
            }
        }
        return name
    }

    private func formatRange(_ start: Date, _ end: Date) -> String {
        let fmt = DateFormatter()
        fmt.timeZone = TimeZone(identifier: "UTC")   // 锚点是正午 UTC → 用 UTC 格式化保持日期稳定
        fmt.dateFormat = "MMM d"
        return "\(fmt.string(from: start)) – \(fmt.string(from: end))"
    }

    private func labeled(_ key: String, _ value: String) -> String {
        guard !value.isEmpty else { return "" }
        return String(format: NSLocalizedString(key, comment: ""), value)
    }
    private func joinNotes(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 稳定标识：优先 ZINTERNALIDENTIFIER，否则用表名+PK。用于确定性 UUID，保证重复导入幂等。
    private func identifier(_ r: TripsyRow, table: String, pk: Int? = nil) -> String {
        let ident = r.string("ZINTERNALIDENTIFIER")
        if !ident.isEmpty { return ident }
        let p = pk ?? r.int("Z_PK") ?? 0
        return "\(table):\(p)"
    }

    private func indexByPK(_ rows: [TripsyRow]) -> [Int: TripsyRow] {
        var dict: [Int: TripsyRow] = [:]
        for r in rows { if let pk = r.int("Z_PK") { dict[pk] = r } }
        return dict
    }
}

// MARK: - 确定性 UUID（uuid5 / SHA-1）

nonisolated enum TripsyUUID {
    /// 固定命名空间（Carry × Tripsy 专用，与 Carry 原生 UUID 不冲突）。
    private static let namespace: [UInt8] = [
        0xE1, 0xB6, 0xF0, 0xA2, 0x3C, 0x4D, 0x5E, 0x6F,
        0x8A, 0x9B, 0x0C, 0x1D, 0x2E, 0x3F, 0x4A, 0x5B,
    ]

    static func make(_ name: String) -> UUID {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data(namespace))
        hasher.update(data: Data(name.utf8))
        var b = Array(hasher.finalize())          // 20 字节
        b[6] = (b[6] & 0x0F) | 0x50               // version 5
        b[8] = (b[8] & 0x3F) | 0x80               // RFC 4122 variant
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

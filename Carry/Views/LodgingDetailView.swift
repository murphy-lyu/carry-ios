//
//  LodgingDetailView.swift
//  Carry
//
//  住宿【只读详情】：点住宿条先看信息（半高 sheet），底部 Edit 再进编辑——与停靠点详情同一交互
//  （spec: itinerary-entity-detail-unify.md）。有值才显、空的不显；有坐标则带 Get Directions（去酒店）。
//

import SwiftUI

struct LodgingDetailView: View {
    let tripId: UUID
    let stay: LodgingStay
    let navApps: [MapNavigationApp]
    let dayColor: Color

    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false

    private var displayName: String {
        stay.name.isEmpty ? NSLocalizedString("itinerary.category.lodging", comment: "") : stay.name
    }

    /// 某天序对应的日期文案（有日期行程 → 「Sun, Jul 19」；无日期 → 「第 N 天」）。
    private func dayDateText(_ dayOrder: Int) -> String {
        if let bundle = stay.bundle, !bundle.isDateless {
            let base = Calendar.current.startOfDay(for: bundle.departureDate)
            if let d = Calendar.current.date(byAdding: .day, value: dayOrder, to: base) {
                return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            }
        }
        return String(format: NSLocalizedString("itinerary.day.title", comment: ""), dayOrder + 1)
    }

    /// 入住 / 退房各自绑定到具体哪天的「日期」（对标 Tripsy，避免两个时间分不清谁是谁）。
    /// 时刻拆成独立的右列值（checkInTime/checkOutTime），不与日期黏成一串。
    private var checkInDate: String { dayDateText(stay.checkInDayOrder) }
    private var checkOutDate: String { dayDateText(stay.checkOutDayOrder) }
    /// 右列时刻（无具体时刻 → nil，行内只剩日期）。
    private var checkInTime: String? { stay.checkInMinutes >= 0 ? timeLabel(dayMinutes: stay.checkInMinutes) : nil }
    private var checkOutTime: String? { stay.checkOutMinutes >= 0 ? timeLabel(dayMinutes: stay.checkOutMinutes) : nil }

    var body: some View {
        DetailSheetScaffold {
            header
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                scheduleCard      // 行程时间（入住/退房/晚数）
                placeInfoCard     // 地点信息（地址/电话/确认号）
                if let coord = stay.coordinate, !navApps.isEmpty {
                    DirectionsModule(coordinate: coord, name: displayName, navApps: navApps, tint: .accentColor)
                }
                costCard
                noteCard
                AttachmentDetailCard(attachments: stay.attachments ?? [])
            }
        } footer: {
            DetailActionFooter(onEdit: { editing = true }, onDelete: deleteStay)
        }
        .sheet(isPresented: $editing) {
            LodgingEditView(tripId: tripId, stayId: stay.id)
        }
    }

    private var header: some View {
        DetailSheetHeader(
            iconSystemName: "bed.double.fill",
            iconTint: dayColor,
            // 不带副标题：入住–退房完整日期已在「行程时间卡」里，副标题再放日期=重复（且叠在长名称下显拥挤）。
            // 与地点/景点不冲突——它们无行程时间卡，副标题才是其唯一 schedule 槽位（schedule 只显示一次、各在其位）。
            title: displayName,
            subtitle: nil,
            onClose: { dismiss() }
        )
    }

    private func deleteStay() {
        store.removeLodgingStay(tripId: tripId, stayId: stay.id)
        dismiss()
    }

    /// 「预订」卡（reservation 属性）：入住 / 退房（各带日期+时间）→ 晚数 → 确认号。与「地点信息」分离——
    /// 这些都是「这趟住宿的预订」属性（何时入住、住几晚、订单凭据），住宿 schedule 是两个带时刻的日期事件，
    /// 塞不进副标题，故保留成卡（地点/景点的单一时间则并进副标题，B1）。
    private var scheduleCard: some View {
        var rows: [AnyView] = [
            // 入住 / 退房：日期为主值（哪一天），时刻拆到右列（几点）。进→出→时长一个完整时间三件套，不被打断。
            AnyView(LabeledDetailRow(icon: "calendar", labelKey: "itinerary.lodging.event.checkin", value: checkInDate, trailing: checkInTime)),
            AnyView(LabeledDetailRow(icon: "calendar", labelKey: "itinerary.lodging.event.checkout", value: checkOutDate, trailing: checkOutTime)),
            // 标签单复数：1 晚用单数（Night/Nacht…），≥2 用复数；zh/ja/ko 无单复数、两者同形。
            AnyView(LabeledDetailRow(icon: "moon",
                                     labelKey: stay.nights == 1 ? "itinerary.lodging.field.nights.one" : "itinerary.lodging.field.nights",
                                     value: "\(stay.nights)")),
        ]
        // 确认号（前台入住出示的订单凭据）：属预订参照号，收尾附在时间三件套之后；可点按复制。
        if !stay.confirmationCode.isEmpty {
            rows.append(AnyView(CopyableDetailRow(icon: "ticket", labelKey: "itinerary.transport.field.confirmation", value: stay.confirmationCode)))
        }
        return DetailRowGroup(rows: rows)
    }

    /// 「地点信息」卡（place-info 属性）：地址 → 电话。裸住宿（两者皆无）→ 不显空卡。
    private var placeInfoRows: [AnyView] {
        var rows: [AnyView] = []
        if stay.hasCoordinate && !stay.address.isEmpty {
            rows.append(AnyView(CopyableDetailRow(icon: "mappin.and.ellipse", labelKey: "itinerary.lodging.field.address", value: stay.address)))
        }
        // 电话紧随地址（同属「怎么找到/联系酒店」）：点按直接拨号。
        if !stay.phone.isEmpty {
            rows.append(AnyView(CallableDetailRow(labelKey: "itinerary.transport.field.phone", phone: stay.phone)))
        }
        return rows
    }
    @ViewBuilder
    private var placeInfoCard: some View {
        let rows = placeInfoRows
        if !rows.isEmpty { DetailRowGroup(rows: rows) }
    }

    // 费用 / 备注 各自独立成卡、固定顺序（费用 → 备注 → 附件），与编辑页一致。
    @ViewBuilder
    private var costCard: some View {
        if stay.hasCost {
            DetailRowGroup(rows: [AnyView(LabeledDetailRow(icon: "creditcard", labelKey: "cost.field.total",
                                                           value: CurrencyCatalog.format(stay.costAmount, code: stay.costCurrencyCode)))])
        }
    }
    @ViewBuilder
    private var noteCard: some View {
        if !stay.note.isEmpty {
            DetailRowGroup(rows: [AnyView(NoteDetailRow(text: stay.note))])
        }
    }

    // 底部动作（编辑 + 移除 + 提醒开关）已统一收到 `DetailActionFooter`（··· 菜单）。
}

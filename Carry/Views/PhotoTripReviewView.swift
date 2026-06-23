//
//  PhotoTripReviewView.swift
//  Carry
//
//  照片回溯行程的预览/微调页（spec: photo-trip-reconstruction.md §预览/微调页）。
//
//  设计内核：自动生成的结果是「草稿」不是「结果」——90% 自动、那 10% 改起来要顺手。
//  顶部「保存」（非「完成」）暗示初稿可改；编辑跟着选中走、不堆工具栏。
//  所有编辑改的是内存草稿（值类型），点保存才落库。
//

import SwiftUI
import UIKit
import CoreLocation

struct PhotoTripReviewView: View {
    @Binding var draft: PhotoItineraryDraft
    let onSave: () -> Void

    // 编辑态
    @State private var renaming: RenameTarget?
    @State private var renameText: String = ""
    @State private var splitting: SplitTarget?

    private struct RenameTarget: Identifiable { let dayIndex: Int; let placeIndex: Int; var id: String { "\(dayIndex)-\(placeIndex)" } }
    private struct SplitTarget: Identifiable { let dayIndex: Int; let placeIndex: Int; var id: String { "\(dayIndex)-\(placeIndex)" } }

    var body: some View {
        ScrollView {
            // LazyVStack：缩略图 UIImage(data:) 在 body 内同步解码，懒加载使只有可见天的照片才解码，
            // 避免大批量导入进预览时一次性解码全部缩略图、首帧卡顿。
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(Array(draft.days.enumerated()), id: \.element.id) { dayIndex, day in
                    daySection(dayIndex: dayIndex, day: day)
                }
                if !draft.outOfRange.isEmpty { excludedSection(photos: draft.outOfRange, kind: .outOfRange) }
                if !draft.noLocation.isEmpty { excludedSection(photos: draft.noLocation, kind: .noLocation) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom) { saveBar }
        .alert("phototrip.rename.title", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("phototrip.rename.placeholder", text: $renameText)
            Button("common.cancel", role: .cancel) { renaming = nil }
            Button("phototrip.rename.confirm") { commitRename() }
        }
        .sheet(item: $splitting) { target in
            splitSheet(target)
        }
    }

    // MARK: 一天

    private func daySection(dayIndex: Int, day: DayDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(String(format: NSLocalizedString("phototrip.day.title", comment: ""), day.dayOrder + 1))
                    .font(.system(.headline, design: .rounded))
                Text(String.localizedStringWithFormat(NSLocalizedString("phototrip.day.placecount", comment: ""), day.places.count))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(day.places.enumerated()), id: \.element.id) { placeIndex, place in
                placeCard(dayIndex: dayIndex, placeIndex: placeIndex, place: place, dayCount: day.places.count)
            }
        }
    }

    // MARK: 地点卡片

    private func placeCard(dayIndex: Int, placeIndex: Int, place: PlaceDraft, dayCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(timeRange(place))
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                placeMenu(dayIndex: dayIndex, placeIndex: placeIndex, dayCount: dayCount, photoCount: place.photoCount)
            }
            Button { beginRename(dayIndex, placeIndex, place) } label: {
                HStack(spacing: 6) {
                    Text(displayName(place))
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundStyle(.primary)
                    Image(systemName: "pencil").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            Label {
                Text(LocalizedStringKey(place.category.localizationKey)).font(.caption2)
            } icon: {
                Image(systemName: "mappin.circle.fill").font(.caption2)
            }
            .foregroundStyle(.secondary)
            thumbnailStrip(dayIndex: dayIndex, placeIndex: placeIndex, photos: place.photos)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func placeMenu(dayIndex: Int, placeIndex: Int, dayCount: Int, photoCount: Int) -> some View {
        Menu {
            Button { beginRename(dayIndex, placeIndex, draft.days[dayIndex].places[placeIndex]) } label: {
                Label("phototrip.action.rename", systemImage: "pencil")
            }
            Menu {
                ForEach(StopCategory.allCases, id: \.self) { cat in
                    Button { setCategory(dayIndex, placeIndex, cat) } label: {
                        Text(LocalizedStringKey(cat.localizationKey))
                    }
                }
            } label: {
                Label("phototrip.action.category", systemImage: "tag")
            }
            if placeIndex > 0 {
                Button { merge(dayIndex, placeIndex, into: placeIndex - 1) } label: {
                    Label("phototrip.action.merge.prev", systemImage: "arrow.up.to.line")
                }
            }
            if placeIndex < dayCount - 1 {
                Button { merge(dayIndex, placeIndex, into: placeIndex + 1) } label: {
                    Label("phototrip.action.merge.next", systemImage: "arrow.down.to.line")
                }
            }
            if photoCount > 1 {
                Button { splitting = SplitTarget(dayIndex: dayIndex, placeIndex: placeIndex) } label: {
                    Label("phototrip.action.split", systemImage: "scissors")
                }
            }
            Divider()
            Button(role: .destructive) { deletePlace(dayIndex, placeIndex) } label: {
                Label("phototrip.action.delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 15)).foregroundStyle(.secondary)
                .frame(width: 32, height: 24, alignment: .trailing)
        }
    }

    private func thumbnailStrip(dayIndex: Int, placeIndex: Int, photos: [PhotoDraft]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(photos) { photo in thumb(photo.thumbnailData) }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: 未能落入行程的照片（诚实告知原因，不假装是「没位置」）

    private enum ExcludedKind {
        case outOfRange, noLocation
        var titleKey: String { self == .outOfRange ? "phototrip.excluded.outofrange.title" : "phototrip.excluded.nolocation.title" }
        var hintKey: String  { self == .outOfRange ? "phototrip.excluded.outofrange.hint"  : "phototrip.excluded.nolocation.hint" }
        var icon: String     { self == .outOfRange ? "calendar.badge.exclamationmark" : "location.slash" }
    }

    /// 越界时在缩略图下显示拍摄日期，让用户一眼明白「为什么不在行程里」。
    private func excludedSection(photos: [PhotoDraft], kind: ExcludedKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: kind.icon).font(.footnote)
                Text(String(format: NSLocalizedString(kind.titleKey, comment: ""), photos.count))
                    .font(.footnote.weight(.medium))
            }
            .foregroundStyle(Color(.systemOrange))
            Text(LocalizedStringKey(kind.hintKey))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(photos) { photo in
                        VStack(spacing: 3) {
                            thumb(photo.thumbnailData)
                            // 仅在有真实拍摄时间时显示日期（无 EXIF 时间者为 distantPast，不显乱日期）。
                            if kind == .outOfRange, photo.timestamp > .distantPast {
                                Text(shotDate(photo.timestamp)).font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(12)
        .background(Color(.systemOrange).opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: 保存条

    private var saveBar: some View {
        Button { onSave() } label: {
            Text("phototrip.save")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color(.label), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(Color(.systemBackground))
        }
        .disabled(draft.placeCount == 0)
        .opacity(draft.placeCount == 0 ? 0.5 : 1)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
    }

    // MARK: 拆分 sheet

    private func splitSheet(_ target: SplitTarget) -> some View {
        let place = draft.days[target.dayIndex].places[target.placeIndex]
        return NavigationStack {
            ScrollView {
                Text("phototrip.split.hint")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 8)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                    ForEach(Array(place.photos.enumerated()), id: \.element.id) { idx, photo in
                        VStack(spacing: 4) {
                            thumb(photo.thumbnailData, size: 72)
                            if idx > 0 {
                                Button {
                                    split(target.dayIndex, target.placeIndex, at: idx)
                                    splitting = nil
                                } label: {
                                    Text("phototrip.split.here").font(.caption2)
                                }
                            } else {
                                Text(" ").font(.caption2)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle(Text("phototrip.split.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { splitting = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: 小组件

    private func thumb(_ data: Data?, size: CGFloat = 56) -> some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").font(.system(size: size * 0.3)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.tertiarySystemFill))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func displayName(_ place: PlaceDraft) -> String {
        place.name.isEmpty ? NSLocalizedString("phototrip.place.untitled", comment: "") : place.name
    }

    // 静态复用：DateFormatter 初始化昂贵（locale/ICU 加载），逐 place 卡片新建会在大批量导入滚动时造成内存抖动。
    private static let hourMinuteFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let shotDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.setLocalizedDateFormatFromTemplate("Md"); return f
    }()

    private func timeRange(_ place: PlaceDraft) -> String {
        let f = Self.hourMinuteFormatter
        let start = f.string(from: place.firstTime)
        if place.stayMinutes <= 0 { return start }
        return "\(start) – \(f.string(from: place.lastTime))"
    }

    /// 越界照片的拍摄日（本地化短日期），让用户对照行程日期一眼看懂为什么没收进来。
    private func shotDate(_ date: Date) -> String {
        Self.shotDateFormatter.string(from: date)
    }

    // MARK: 草稿变更（值类型，直接改 @Binding）

    private func beginRename(_ d: Int, _ p: Int, _ place: PlaceDraft) {
        renameText = place.name
        renaming = RenameTarget(dayIndex: d, placeIndex: p)
    }

    private func commitRename() {
        guard let t = renaming else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.days[t.dayIndex].places[t.placeIndex].name = trimmed
        renaming = nil
    }

    private func setCategory(_ d: Int, _ p: Int, _ cat: StopCategory) {
        draft.days[d].places[p].category = cat
    }

    /// 删除地点 = 把它（连同其照片）从行程里丢弃。用户不想要这个点就删，想留就别删。
    private func deletePlace(_ d: Int, _ p: Int) {
        draft.days[d].places.remove(at: p)
    }

    private func merge(_ d: Int, _ p: Int, into target: Int) {
        var places = draft.days[d].places
        guard p >= 0, p < places.count, target >= 0, target < places.count, p != target else { return }
        let lo = min(p, target), hi = max(p, target)
        let merged = mergedPlace(places[lo], places[hi])
        places[lo] = merged
        places.remove(at: hi)
        draft.days[d].places = places
    }

    /// 合并两地点：照片按时间并集、质心/时段重算、保留靠前者的名字与类别。
    private func mergedPlace(_ a: PlaceDraft, _ b: PlaceDraft) -> PlaceDraft {
        let photos = (a.photos + b.photos).sorted { $0.timestamp < $1.timestamp }
        return rebuild(from: photos, name: a.name.isEmpty ? b.name : a.name, category: a.category, id: a.id)
    }

    private func split(_ d: Int, _ p: Int, at index: Int) {
        let place = draft.days[d].places[p]
        guard index > 0, index < place.photos.count else { return }
        let head = Array(place.photos[0..<index])
        let tail = Array(place.photos[index...])
        let first = rebuild(from: head, name: place.name, category: place.category, id: place.id)
        let second = rebuild(from: tail, name: "", category: place.category, id: UUID())
        draft.days[d].places.replaceSubrange(p...p, with: [first, second])
    }

    /// 用一组照片重算地点（质心 = 有效坐标平均；时段 = 首末拍摄时间）。
    private func rebuild(from photos: [PhotoDraft], name: String, category: StopCategory, id: UUID) -> PlaceDraft {
        let sorted = photos.sorted { $0.timestamp < $1.timestamp }
        let coords = sorted.compactMap(\.coordinate)
        let lat = coords.isEmpty ? 0 : coords.map(\.latitude).reduce(0, +) / Double(coords.count)
        let lon = coords.isEmpty ? 0 : coords.map(\.longitude).reduce(0, +) / Double(coords.count)
        return PlaceDraft(
            id: id,
            name: name,
            address: "",
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            category: category,
            firstTime: sorted.first?.timestamp ?? Date(),
            lastTime: sorted.last?.timestamp ?? Date(),
            photos: sorted
        )
    }
}

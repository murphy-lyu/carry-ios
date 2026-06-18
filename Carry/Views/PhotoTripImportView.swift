//
//  PhotoTripImportView.swift
//  Carry
//
//  照片回溯行程的入口流程（spec: photo-trip-reconstruction.md §交互流程）。
//
//  状态机：intro（引导选图）→ processing（解析所选照片+聚类+命名）→ review（预览微调）。
//  分支：empty（所选照片里没有可用于生成的）。
//  隐私优先：**不请求相册授权**，只读用户在 PHPicker 主动选中的那几张图的 EXIF（见 PhotoTripReconstructor）。
//

import SwiftUI
import PhotosUI

struct PhotoTripImportView: View {
    let tripId: UUID
    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable { case intro, processing, review, empty }
    @State private var phase: Phase = .intro
    @State private var selection: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var draft = PhotoItineraryDraft(tripId: UUID(), departureDay: Date(), days: [], noLocation: [], outOfRange: [])
    @State private var processedCount = 0
    @State private var totalCount = 0
    @State private var processedThumbnails: [Data?] = []   // 已读到的缩略图，加载态逐张浮现
    @State private var processingTask: Task<Void, Never>?

    private var bundle: TripBundle? { store.trips.first { $0.id == tripId } }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .intro:      introView
                case .processing: processingView
                case .empty:      emptyView
                case .review:
                    PhotoTripReviewView(draft: $draft, onSave: save)
                }
            }
            .navigationTitle(Text("phototrip.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { cancel() } label: { Image(systemName: "xmark") }
                        .tint(Color(.secondaryLabel))
                }
            }
            // 单次上限 50：系统选择器自身会强制并显示「已选 N」，无需我们再提示。
            // 想补更多 → 多次导入即可（落库是「追加」，不覆盖已有地点）。
            // 不传 photoLibrary：纯进程外选择，连「访问所有照片」弹窗的可能性都没有（隐私最优）。
            .photosPicker(isPresented: $showPicker, selection: $selection,
                          maxSelectionCount: 50, matching: .images)
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                process(items: items)
            }
            .onDisappear { processingTask?.cancel() }   // 下滑关闭也停掉后台解析
        }
    }

    // MARK: Intro

    private var introView: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(.tertiary)
            Text("phototrip.intro.title")
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .multilineTextAlignment(.center)
            Text("phototrip.intro.subtitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 24)
            // 隐私安心：打消「会上传/会被挪用/会撑爆存储」的顾虑——这功能的用户多半在意隐私。
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("phototrip.intro.privacy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            Spacer(minLength: 0)
            Button { startPicking() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "photo.badge.plus").font(.system(size: 15, weight: .semibold))
                    Text("phototrip.intro.cta")
                }
            }
            .buttonStyle(CarryEmptyStatePrimaryButtonStyle())
            .padding(.bottom, 28)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Processing

    private var processingView: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            // 你这趟的照片像印相纸一样一张张浮现——加载态即「Carry 正在读你的照片」的真实反馈。
            if processedThumbnails.isEmpty {
                ProgressView().controlSize(.large)
                    .frame(height: 60)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 6), count: 6), spacing: 6) {
                    ForEach(Array(processedThumbnails.enumerated()), id: \.offset) { _, data in
                        procThumb(data)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 6 * 44 + 5 * 6)   // 6 列固定，居中
            }
            VStack(spacing: 10) {
                if totalCount > 0 {
                    ProgressView(value: Double(processedCount), total: Double(totalCount))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                    Text(verbatim: "\(processedCount) / \(totalCount)")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text("phototrip.processing.label")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func procThumb(_ data: Data?) -> some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").font(.system(size: 14)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.tertiarySystemFill))
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    // MARK: Denied

    // MARK: Empty

    private var emptyView: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "mappin.slash")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.tertiary)
            Text("phototrip.empty.title")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .multilineTextAlignment(.center)
            Text("phototrip.empty.subtitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 24)
            Spacer(minLength: 0)
            Button { startPicking() } label: { Text("phototrip.empty.cta") }
                .buttonStyle(CarryEmptyStatePrimaryButtonStyle())
                .padding(.bottom, 28)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func startPicking() {
        // 无需任何相册授权——PHPicker 是系统进程外选择器，用户挑了才给我们那几张。
        selection = []
        showPicker = true
    }

    private func process(items: [PhotosPickerItem]) {
        guard let bundle else { return }
        guard !items.isEmpty else { return }
        let depart = bundle.departureDate
        let ret = Calendar.current.date(byAdding: .day, value: bundle.days, to: bundle.departureDate) ?? bundle.departureDate
        let china = isChinaStorefront
        processedCount = 0
        totalCount = items.count
        processedThumbnails = []
        phase = .processing
        CarryLogger.shared.log(.photoImportStarted, context: "selected=\(items.count)")
        processingTask = Task {
            let photos = await PhotoTripReconstructor.extract(items: items, isChinaStorefront: china) { done, thumb in
                await MainActor.run {
                    processedCount = done
                    withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                        processedThumbnails.append(thumb)
                    }
                }
            }
            if Task.isCancelled { return }   // 用户中途退出 → 不再落状态
            let d = await PhotoTripReconstructor.assemble(
                photos: photos, tripId: tripId, departureDate: depart, returnDate: ret
            )
            if Task.isCancelled { return }
            await MainActor.run {
                draft = d
                if d.days.isEmpty && d.excludedCount == 0 {
                    phase = .empty
                    CarryLogger.shared.log(.photoImportFailed, context: "reason=no_usable_photos")
                } else {
                    phase = .review
                    CarryLogger.shared.log(.photoImportGenerated,
                                           context: "days=\(d.days.count) places=\(d.placeCount) photos=\(d.totalPhotoCount)")
                }
            }
        }
    }

    private func save() {
        store.importItineraryFromPhotos(tripId: tripId, draft: draft)
        dismiss()
    }

    private func cancel() {
        processingTask?.cancel()   // 处理中退出 → 立即停掉后台解析，不浪费
        if phase == .review {
            CarryLogger.shared.log(.photoImportCancelled,
                                   context: "days=\(draft.days.count) places=\(draft.placeCount)")
        }
        dismiss()
    }
}

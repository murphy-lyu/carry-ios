//
//  AttachmentUI.swift
//  Carry
//
//  行程附件的复用 UI（spec: itinerary-attachments.md）：
//  - AttachmentEditSection：编辑页内管理（添加 拍照/照片/文件/链接 + 滑动删除）。纯渲染 + 内部按 owner 分流。
//  - .attachmentAddFlow(...)：呈现挂到**父级 Form（稳定祖先）**——挂在 Section/列表行上的 sheet 会随行回收被销毁。
//  - 新建实体（owner 为 nil）时附件先**缓冲**在 pending，保存实体拿到 id 后再入库（见各编辑页 flush）。
//  - AttachmentDetailCard：详情页内查看（点按预览/打开；链接走应用内 Safari）。
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import UIKit
import QuickLook
import SafariServices

// MARK: - 缩略图

enum AttachmentThumbnail {
    /// 由图片字节生成约 640px JPEG 缩略图（列表/详情快渲；原图存沙盒）。
    static func make(from imageData: Data, maxPixel: CGFloat = 640) -> Data? {
        guard let src = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.8)
    }
}

// MARK: - 图标 / 文案（持久化与缓冲共用）

func attachmentSymbol(kind: AttachmentKind, utiOrExt: String) -> String {
    switch kind {
    case .link: return "link"
    case .photo: return "photo"
    case .file:
        let ext = utiOrExt.lowercased()
        if ext.contains("pdf") { return "doc.richtext" }
        if ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(ext) { return "photo" }
        return "doc"
    }
}

func attachmentResolvedName(kind: AttachmentKind, displayName: String, urlString: String, fileName: String) -> String {
    if !displayName.isEmpty { return displayName }
    if kind == .link { return urlString }
    return fileName
}

extension ItineraryAttachment {
    var symbolName: String { attachmentSymbol(kind: kind, utiOrExt: utiOrExt) }
    var resolvedName: String { attachmentResolvedName(kind: kind, displayName: displayName, urlString: urlString, fileName: fileName) }
}

// MARK: - 添加请求 / 待入库数据 / 行项

enum AttachmentAddRequest: Identifiable {
    case photo, file, link, camera
    var id: Int { hashValue }
}

/// 新附件数据（沙盒/缩略图已就绪，待入库或缓冲）。
struct NewAttachmentData {
    var kind: AttachmentKind
    var displayName: String = ""
    var fileName: String = ""
    var utiOrExt: String = ""
    var urlString: String = ""
    var thumbnailData: Data = Data()
}

/// 新建实体时的缓冲附件（保存后再入库）。
struct PendingAttachment: Identifiable {
    let id = UUID()
    var data: NewAttachmentData
}

/// 列表行项（持久化 ItineraryAttachment 与 PendingAttachment 统一映射）。
private struct AttachmentRowItem: Identifiable {
    let id: UUID
    let symbol: String
    let name: String
    let thumbnailData: Data
}

// MARK: - 编辑页：管理附件

/// 编辑页内的附件 Section。`owner` 非 nil = 既有实体（直接入库）；nil = 新建（缓冲到 `pending`，保存后再 flush）。
struct AttachmentEditSection: View {
    let owner: AttachmentOwner?
    /// 既有实体的附件（owner 非 nil 时用）。
    let existing: [ItineraryAttachment]
    /// 新建实体的缓冲附件（owner 为 nil 时用）。
    @Binding var pending: [PendingAttachment]
    let tripId: UUID
    @Binding var request: AttachmentAddRequest?

    @EnvironmentObject var store: TripStore

    private var rows: [AttachmentRowItem] {
        if owner != nil {
            return existing.sorted { $0.sortOrder < $1.sortOrder }.map {
                AttachmentRowItem(id: $0.id, symbol: $0.symbolName, name: $0.resolvedName, thumbnailData: $0.thumbnailData)
            }
        } else {
            return pending.map {
                AttachmentRowItem(
                    id: $0.id,
                    symbol: attachmentSymbol(kind: $0.data.kind, utiOrExt: $0.data.utiOrExt),
                    name: attachmentResolvedName(kind: $0.data.kind, displayName: $0.data.displayName, urlString: $0.data.urlString, fileName: $0.data.fileName),
                    thumbnailData: $0.data.thumbnailData)
            }
        }
    }

    var body: some View {
        Section {
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    attachmentGlyph(symbol: row.symbol, thumbnailData: row.thumbnailData, size: 28)
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { delete(row.id) } label: {
                        Label("common.remove", systemImage: "trash")
                    }
                }
            }
            Menu {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { request = .camera } label: { Label("itinerary.attachment.take_photo", systemImage: "camera") }
                }
                Button { request = .photo } label: { Label("itinerary.attachment.choose_photo", systemImage: "photo") }
                Button { request = .file } label: { Label("itinerary.attachment.choose_file", systemImage: "doc") }
                Button { request = .link } label: { Label("itinerary.attachment.add_link", systemImage: "link") }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "paperclip")
                    Text("itinerary.attachment.add")
                }
            }
        } header: {
            Text("itinerary.attachment.section")
        }
    }

    private func delete(_ id: UUID) {
        if owner != nil {
            store.removeAttachment(tripId: tripId, attachmentId: id)
        } else if let idx = pending.firstIndex(where: { $0.id == id }) {
            let fileName = pending[idx].data.fileName
            if !fileName.isEmpty { AttachmentStore.delete(named: fileName) }
            pending.remove(at: idx)
        }
    }
}

// MARK: - 添加流程修饰器（挂到父级 Form）

extension View {
    /// 把附件添加的呈现（拍照/照片/文件/链接/超限）挂到稳定祖先。owner 非 nil → 直接入库；nil → 缓冲到 pending。
    func attachmentAddFlow(tripId: UUID, owner: AttachmentOwner?,
                           pending: Binding<[PendingAttachment]>,
                           request: Binding<AttachmentAddRequest?>) -> some View {
        modifier(AttachmentAddFlow(tripId: tripId, owner: owner, pending: pending, request: request))
    }
}

private struct AttachmentAddFlow: ViewModifier {
    let tripId: UUID
    let owner: AttachmentOwner?
    @Binding var pending: [PendingAttachment]
    @Binding var request: AttachmentAddRequest?

    @EnvironmentObject var store: TripStore
    @State private var photoItem: PhotosPickerItem?
    @State private var linkURL = ""
    @State private var linkName = ""
    @State private var showTooLarge = false

    private func bind(_ r: AttachmentAddRequest) -> Binding<Bool> {
        Binding(get: { request == r }, set: { if !$0, request == r { request = nil } })
    }

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: bind(.photo), selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, newItem in
                guard let newItem else { return }
                Task { await addPhotoItem(newItem); await MainActor.run { photoItem = nil } }
            }
            .fileImporter(isPresented: bind(.file), allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                handleFileImport(result)
            }
            .fullScreenCover(isPresented: bind(.camera)) {
                CameraPicker { data in addImageData(data, ext: "jpg") }
                    .ignoresSafeArea()
            }
            .onChange(of: request) { _, new in
                if new == .link { linkURL = ""; linkName = "" }
            }
            .sheet(isPresented: bind(.link)) {
                LinkInputSheet(url: $linkURL, name: $linkName) { addLink() }
            }
            .alert("itinerary.attachment.too_large", isPresented: $showTooLarge) {
                Button("common.ok", role: .cancel) {}
            }
    }

    /// owner 有 → 入库；无 → 缓冲。
    private func commit(_ data: NewAttachmentData) {
        if let owner {
            _ = store.addAttachment(tripId: tripId, owner: owner, kind: data.kind,
                                    displayName: data.displayName, fileName: data.fileName,
                                    utiOrExt: data.utiOrExt, urlString: data.urlString, thumbnailData: data.thumbnailData)
        } else {
            pending.append(PendingAttachment(data: data))
        }
    }

    private func addPhotoItem(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        await MainActor.run { addImageData(data, ext: "jpg") }
    }

    /// 拍照 / 选照片共用：校验大小 → 存沙盒 + 缩略图 → 提交。
    private func addImageData(_ data: Data, ext: String) {
        guard data.count <= AttachmentStore.maxBytes else { showTooLarge = true; return }
        let thumb = AttachmentThumbnail.make(from: data) ?? Data()
        guard let fileName = AttachmentStore.save(data, ext: ext) else { return }
        commit(NewAttachmentData(kind: .photo, fileName: fileName, utiOrExt: ext, thumbnailData: thumb))
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        guard data.count <= AttachmentStore.maxBytes else { showTooLarge = true; return }
        let ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension
        guard let fileName = AttachmentStore.save(data, ext: ext) else { return }
        let thumb = AttachmentThumbnail.make(from: data) ?? Data()
        commit(NewAttachmentData(kind: .file, displayName: url.lastPathComponent, fileName: fileName, utiOrExt: ext, thumbnailData: thumb))
    }

    private func addLink() {
        var raw = linkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if !raw.contains("://") { raw = "https://" + raw }
        commit(NewAttachmentData(kind: .link, displayName: linkName.trimmingCharacters(in: .whitespaces), urlString: raw))
    }
}

// MARK: - 相机拍照（UIImagePickerController 包装）

private struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage, let data = img.jpegData(compressionQuality: 0.9) {
                parent.onImage(data)
            }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

// MARK: - 链接输入 sheet

/// 添加链接的小 sheet（Form + 链接/标题两栏）。用 sheet 而非 alert+TextField，
/// 避免「sheet 内弹 alert 输入框失焦」的 SwiftUI 嵌套呈现坑。
private struct LinkInputSheet: View {
    @Binding var url: String
    @Binding var name: String
    let onAdd: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("itinerary.attachment.link_url", text: $url)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("itinerary.attachment.link_name", text: $name)
            }
            .navigationTitle("itinerary.attachment.add_link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.add") { onAdd(); dismiss() }
                        .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.height(240)])
    }
}

// MARK: - 详情页：查看附件

/// 详情页内的附件卡（点按：文件/照片走 QuickLook 预览、链接走应用内 Safari）。有才显。
struct AttachmentDetailCard: View {
    let attachments: [ItineraryAttachment]

    @State private var previewURL: URL?
    @State private var webLink: WebLink?

    private struct WebLink: Identifiable { let id = UUID(); let url: URL }

    private var sorted: [ItineraryAttachment] {
        attachments.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        if !sorted.isEmpty {
            DetailRowGroup(rows: sorted.map { att in
                AnyView(
                    Button { open(att) } label: {
                        HStack(spacing: 12) {
                            attachmentGlyph(symbol: att.symbolName, thumbnailData: att.thumbnailData, size: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("itinerary.attachment.section")
                                    .font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
                                Text(att.resolvedName)
                                    .font(.system(.subheadline, design: .rounded)).foregroundStyle(.primary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            // 三类都「在 Carry 内查看」（文件/照片预览、链接进应用内 Safari）→ 统一用 eye，
                            // 不用 arrow.up.right（外跳语义已不符）。固定边框保证各行尾标在一条竖线上。
                            Image(systemName: "eye")
                                .font(.system(size: 13)).foregroundStyle(.tertiary)
                                .frame(width: 18, alignment: .center)
                        }
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                )
            })
            .quickLookPreview($previewURL)
            .sheet(item: $webLink) { link in
                SafariView(url: link.url).ignoresSafeArea()
            }
        }
    }

    private func open(_ att: ItineraryAttachment) {
        switch att.kind {
        case .link:
            guard let url = URL(string: att.urlString) else { return }
            if url.scheme == "http" || url.scheme == "https" {
                webLink = WebLink(url: url)            // 应用内 Safari
            } else {
                UIApplication.shared.open(url)         // 其它 scheme 交系统
            }
        case .file, .photo:
            guard !att.fileName.isEmpty else { return }
            previewURL = AttachmentStore.fileURL(named: att.fileName)
        }
        CarryLogger.shared.log(.attachmentOpened, context: att.kindRaw)
    }
}

/// 应用内 Safari（SFSafariViewController 包装）：链接在 Carry 内打开，不跳出。
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

// MARK: - 共用：缩略图或图标

@ViewBuilder
private func attachmentGlyph(symbol: String, thumbnailData: Data, size: CGFloat) -> some View {
    if !thumbnailData.isEmpty, let img = UIImage(data: thumbnailData) {
        Image(uiImage: img).resizable().scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    } else {
        Image(systemName: symbol)
            .font(.system(size: size * 0.62))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
    }
}

//
//  AttachmentStore.swift
//  Carry
//
//  行程附件的沙盒文件管理（spec: itinerary-attachments.md）。
//  原始字节（文件 / 照片原图）存沙盒、model 只存文件名——大文件绝不进 SwiftData。
//  范式镜像 BackgroundImageStore：save / data / write / delete / copy / deleteOrphans。
//

import Foundation

/// 附件归属（挂到哪个实体）。
enum AttachmentOwner {
    case stop(UUID)
    case segment(UUID)
    case lodging(UUID)
}

enum AttachmentStore {
    /// 单文件大小上限（25MB）：超限不入库，防备份包膨胀。spec 已定。
    static let maxBytes = 25 * 1024 * 1024

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Attachments", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func fileURL(named name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// 写入字节，返回沙盒文件名（`<uuid>.<ext>`）。失败返回 nil。
    static func save(_ data: Data, ext: String) -> String? {
        let safeExt = ext.isEmpty ? "dat" : ext
        let name = UUID().uuidString + "." + safeExt
        do {
            try data.write(to: fileURL(named: name), options: .atomic)
            return name
        } catch {
            CarryLogger.shared.log(.attachmentSaveFailed, context: "write")
            return nil
        }
    }

    static func data(named name: String) -> Data? {
        guard !name.isEmpty else { return nil }
        return try? Data(contentsOf: fileURL(named: name))
    }

    /// 还原备份时按原文件名写回字节。
    @discardableResult
    static func write(data: Data, named name: String) -> Bool {
        do {
            try data.write(to: fileURL(named: name), options: .atomic)
            return true
        } catch {
            CarryLogger.shared.log(.attachmentSaveFailed, context: "write_restore name=\(name)")
            return false
        }
    }

    static func delete(named name: String) {
        guard !name.isEmpty else { return }
        do {
            try FileManager.default.removeItem(at: fileURL(named: name))
        } catch {
            CarryLogger.shared.log(.attachmentDeleteFailed, context: "name=\(name)")
        }
    }

    /// 复制行程时拷贝文件，返回新文件名（保持原扩展名）。
    static func copy(of name: String) -> String? {
        guard let bytes = data(named: name) else { return nil }
        let ext = (name as NSString).pathExtension
        return save(bytes, ext: ext)
    }

    private static func allStoredFileNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    /// 兜底回收：删除不再被任何 model 引用的孤儿文件。
    static func deleteOrphans(keeping referenced: Set<String>) {
        for name in allStoredFileNames() where !referenced.contains(name) {
            delete(named: name)
        }
    }
}

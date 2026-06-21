//
//  TripsyZipReader.swift
//  Carry
//
//  从 Tripsy 导入（spec: tripsy-import.md）。
//  零第三方依赖的最小 zip 读取器：解析「中央目录」定位每个条目，stored 直拷、
//  deflate 走系统 Compression 框架解压。仅用于读 Tripsy 导出的 zip（内含
//  Tripsy.sqlite[-wal/-shm] + Documents/ 图片），不追求通用 zip 的全部特性。
//

import Foundation
import Compression

nonisolated enum TripsyZipError: Error {
    case notAZip            // 找不到 EOCD 签名
    case malformed          // 结构损坏
    case zip64Unsupported   // 4GB 以上条目（Tripsy 导出不会触发）
}

nonisolated enum TripsyZipReader {

    /// 把 zip 解压到 `destDir`（须已存在）。按条目相对路径写出文件；目录条目跳过。
    /// 解压失败的单个条目跳过、不中断（健壮性优先；缺图最多丢附件、不毁整次导入）。
    static func extract(zipData data: Data, to destDir: URL) throws {
        let entries = try centralDirectoryEntries(in: data)
        for entry in entries {
            // 目录条目（以 / 结尾、无数据）跳过
            if entry.fileName.hasSuffix("/") { continue }
            guard let bytes = fileData(for: entry, in: data) else { continue }
            let outURL = destDir.appendingPathComponent(entry.fileName)
            try? FileManager.default.createDirectory(
                at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? bytes.write(to: outURL, options: .atomic)
        }
    }

    // MARK: - 中央目录解析

    private struct Entry {
        let fileName: String
        let method: UInt16          // 0 = stored, 8 = deflate
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    /// 从尾部回扫 EOCD（End Of Central Directory），再顺序读出全部中央目录条目。
    private static func centralDirectoryEntries(in data: Data) throws -> [Entry] {
        let eocdSig: UInt32 = 0x06054b50
        let n = data.count
        guard n >= 22 else { throw TripsyZipError.notAZip }
        // EOCD 最大可带 65535 字节注释 → 回扫窗口 = 22 + 65535
        let minStart = max(0, n - 22 - 0xFFFF)
        var eocd = -1
        var i = n - 22
        while i >= minStart {
            if readU32(data, i) == eocdSig { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw TripsyZipError.notAZip }

        let total = Int(readU16(data, eocd + 10))
        let cdSize = Int(readU32(data, eocd + 12))
        let cdOffset = Int(readU32(data, eocd + 16))
        // ZIP64 哨兵：Tripsy 导出体量远小于 4GB，不应出现
        if cdOffset == 0xFFFFFFFF || total == 0xFFFF || cdSize == 0xFFFFFFFF {
            throw TripsyZipError.zip64Unsupported
        }
        guard cdOffset + cdSize <= n else { throw TripsyZipError.malformed }

        var entries: [Entry] = []
        var p = cdOffset
        let cdSig: UInt32 = 0x02014b50
        for _ in 0..<total {
            guard p + 46 <= n, readU32(data, p) == cdSig else { throw TripsyZipError.malformed }
            let method = readU16(data, p + 10)
            let compSize = Int(readU32(data, p + 20))
            let uncompSize = Int(readU32(data, p + 24))
            let nameLen = Int(readU16(data, p + 28))
            let extraLen = Int(readU16(data, p + 30))
            let commentLen = Int(readU16(data, p + 32))
            let localOffset = Int(readU32(data, p + 42))
            if compSize == 0xFFFFFFFF || uncompSize == 0xFFFFFFFF || localOffset == 0xFFFFFFFF {
                throw TripsyZipError.zip64Unsupported
            }
            let nameStart = p + 46
            guard nameStart + nameLen <= n else { throw TripsyZipError.malformed }
            let name = String(decoding: data[nameStart..<(nameStart + nameLen)], as: UTF8.self)
            entries.append(Entry(
                fileName: name, method: method,
                compressedSize: compSize, uncompressedSize: uncompSize,
                localHeaderOffset: localOffset))
            p = nameStart + nameLen + extraLen + commentLen
        }
        return entries
    }

    /// 按本地文件头定位数据起点 → 取出并（必要时）解压条目字节。
    private static func fileData(for entry: Entry, in data: Data) -> Data? {
        let lfhSig: UInt32 = 0x04034b50
        let off = entry.localHeaderOffset
        guard off + 30 <= data.count, readU32(data, off) == lfhSig else { return nil }
        // 本地头的 name/extra 长度可能与中央目录不同 → 必须以本地头为准定位数据起点
        let nameLen = Int(readU16(data, off + 26))
        let extraLen = Int(readU16(data, off + 28))
        let dataStart = off + 30 + nameLen + extraLen
        guard dataStart + entry.compressedSize <= data.count else { return nil }
        let comp = data.subdata(in: dataStart..<(dataStart + entry.compressedSize))
        switch entry.method {
        case 0:  // stored
            return comp
        case 8:  // deflate
            return inflate(comp, expectedSize: entry.uncompressedSize)
        default:
            return nil
        }
    }

    /// 原始 DEFLATE（RFC 1951，无 zlib 包头）解压。Apple 的 `COMPRESSION_ZLIB` 即原始 DEFLATE，
    /// 正好对应 zip method 8。
    private static func inflate(_ src: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        var dst = Data(count: expectedSize)
        let written = dst.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) -> Int in
            src.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Int in
                guard let dstBase = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    dstBase, expectedSize, srcBase, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { return nil }
        return dst
    }

    // MARK: - 小端读取助手

    private static func readU16(_ d: Data, _ offset: Int) -> UInt16 {
        let b = d.startIndex + offset
        return UInt16(d[b]) | (UInt16(d[b + 1]) << 8)
    }

    private static func readU32(_ d: Data, _ offset: Int) -> UInt32 {
        let b = d.startIndex + offset
        return UInt32(d[b]) | (UInt32(d[b + 1]) << 8) | (UInt32(d[b + 2]) << 16) | (UInt32(d[b + 3]) << 24)
    }
}

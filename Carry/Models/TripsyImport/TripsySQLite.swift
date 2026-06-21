//
//  TripsySQLite.swift
//  Carry
//
//  从 Tripsy 导入（spec: tripsy-import.md）。
//  只读、防御式的 SQLite 读取封装（系统 SQLite3 模块，无需第三方依赖）。
//  不挂 Core Data 栈（那需要 Tripsy 的 .momd 模型、脆弱）——直接按表名/列名读裸库更稳。
//  所有列读取均按「可能缺列 / 可能为 NULL」处理，配合 columns(of:) 做存在性检查，
//  以抵御 Tripsy 改版导致的 schema 漂移。
//

import Foundation
import SQLite3

/// 一行查询结果：列名 → 值。提供带默认值的类型化取值器，永不因缺列/类型不符崩溃。
nonisolated struct TripsyRow {
    let values: [String: TripsySQLite.Value]

    func int(_ col: String) -> Int? {
        if case .int(let v)? = values[col] { return Int(v) }
        if case .double(let v)? = values[col] { return Int(v) }
        return nil
    }
    func double(_ col: String) -> Double? {
        if case .double(let v)? = values[col] { return v }
        if case .int(let v)? = values[col] { return Double(v) }
        return nil
    }
    func string(_ col: String) -> String {
        if case .text(let v)? = values[col] { return v }
        return ""
    }
    func bool(_ col: String) -> Bool { (int(col) ?? 0) != 0 }

    /// Core Data 时间戳（距 2001-01-01 UTC 的秒）→ Date。无值返回 nil。
    func coreDataDate(_ col: String) -> Date? {
        guard let secs = double(col) else { return nil }
        // 0 在 Core Data 里既可能是真 2001-01-01、也可能是「未设置」占位；调用方按业务判断。
        return Date(timeIntervalSinceReferenceDate: secs)
    }
}

nonisolated final class TripsySQLite {
    enum Value {
        case int(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
    }

    enum OpenError: Error { case cannotOpen }

    private var db: OpaquePointer?

    /// 以只读模式打开（同目录的 -wal/-shm 会被 SQLite 自动识别，读到最新已写入数据）。
    init(path: String) throws {
        let flags = SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, db != nil else {
            if let db { sqlite3_close(db) }
            throw OpenError.cannotOpen
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    /// 表是否存在。
    func tableExists(_ table: String) -> Bool {
        let rows = query("SELECT name FROM sqlite_master WHERE type='table' AND name='\(table)' LIMIT 1;")
        return !rows.isEmpty
    }

    /// 表的实际列名集合（PRAGMA table_info）——用于缺列降级，不假设 schema 固定。
    func columns(of table: String) -> Set<String> {
        Set(query("PRAGMA table_info(\(table));").compactMap { $0.string("name").isEmpty ? nil : $0.string("name") })
    }

    /// 执行只读查询，返回所有行。失败（语法错/缺表）返回空数组，不抛错（防御式）。
    func query(_ sql: String) -> [TripsyRow] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var rows: [TripsyRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let colCount = sqlite3_column_count(stmt)
            var dict: [String: Value] = [:]
            for c in 0..<colCount {
                guard let cNamePtr = sqlite3_column_name(stmt, c) else { continue }
                let name = String(cString: cNamePtr)
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER:
                    dict[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT:
                    dict[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT:
                    if let t = sqlite3_column_text(stmt, c) {
                        dict[name] = .text(String(cString: t))
                    }
                case SQLITE_BLOB:
                    if let b = sqlite3_column_blob(stmt, c) {
                        let len = Int(sqlite3_column_bytes(stmt, c))
                        dict[name] = .blob(Data(bytes: b, count: len))
                    }
                default:
                    break   // SQLITE_NULL → 不写键，取值器按缺值处理
                }
            }
            rows.append(TripsyRow(values: dict))
        }
        return rows
    }
}

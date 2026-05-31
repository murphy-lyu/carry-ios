//
//  CarrySchema.swift
//  Carry
//
//  Versioned schema + migration plan for SwiftData.
//  Adding this baseline ensures future schema changes can be applied as
//  lightweight or custom migrations without corrupting existing user data.
//

import SwiftData

// MARK: - Schema V1 (current)

enum SchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            TripBundle.self,
            PackingSection.self,
            PackingItem.self,
            MyItem.self,
        ]
    }
}

// MARK: - Migration Plan
//
// 注意：SwiftData 的 VersionedSchema 用模型类的当前结构计算 checksum。
// 若新增一个版本但其 models 仍指向同一个 live 类（如加了 isDateless 后的
// TripBundle），新旧两版 checksum 会相同 → 启动崩溃 "Duplicate version
// checksums detected"。正确的多版本写法需要为旧版本冻结一份独立的模型快照。
//
// 本项目尚未发布、无线上老数据，新增的 `isDateless` 又是「带默认值的可加字段」，
// 属 SwiftData 可自动处理的轻量变更。因此保持**单一 SchemaV1**、空 stages，
// 让 SwiftData 对本地 store 做自动轻量迁移即可——无需引入第二个版本。
// 待将来发布后若有「重命名/删除字段、改关系」等非轻量变更，再按"冻结旧快照 +
// 显式 stage"的方式补 SchemaV2。

enum CarryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}

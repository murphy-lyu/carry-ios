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

// MARK: - 如何安全地增加 SchemaV2（必读，做错会让所有老用户启动崩溃）
//
// 触发时机：对已发布版本的模型做「非轻量变更」——即重命名/删除字段、改关系类型、
// 改属性可选性等；纯加带默认值的字段仍属轻量迁移，不需要新版本。
//
// ⚠️ 最常见的致命错误：
//   enum SchemaV2: VersionedSchema {
//       static var models = [TripBundle.self, ...]  // ← 仍指向 live 类！
//   }
//   → SwiftData 用模型当前结构算 checksum，V1/V2 checksum 相同
//   → 启动崩溃 "Duplicate version checksums detected"
//   → 所有老用户无法启动 App ← 最严重升级事故
//
// ✅ 正确做法：为 V1 冻结一份独立快照（只存结构，不含业务逻辑）：
//
//   // CarrySchemaV1Frozen.swift（新建文件，只此一次，之后不再修改）
//   enum SchemaV1Frozen: VersionedSchema {
//       static var versionIdentifier = Schema.Version(1, 0, 0)
//       static var models: [any PersistentModel.Type] { [TripBundleV1.self, ...] }
//
//       @Model final class TripBundleV1 {
//           var id: UUID = UUID()
//           var name: String = ""
//           // ... 只保留 V1 时 TripBundle 真实拥有的字段，逐字复制
//           // 不要有任何计算属性、业务方法
//       }
//       // PackingSectionV1、PackingItemV1、MyItemV1 同理
//   }
//
//   // 然后让 SchemaV2 指向 live 类（没有对应冻结快照）：
//   enum SchemaV2: VersionedSchema {
//       static var versionIdentifier = Schema.Version(2, 0, 0)
//       static var models: [any PersistentModel.Type] { [TripBundle.self, ...] }
//   }
//
//   // 更新 MigrationPlan：
//   enum CarryMigrationPlan: SchemaMigrationPlan {
//       static var schemas = [SchemaV1Frozen.self, SchemaV2.self]
//       static var stages  = [
//           // 轻量迁移（字段加/删/改默认值）：
//           MigrationStage.lightweight(fromVersion: SchemaV1Frozen.self, toVersion: SchemaV2.self)
//           // 自定义迁移（需要数据转换）：
//           // MigrationStage.custom(fromVersion: SchemaV1Frozen.self, toVersion: SchemaV2.self,
//           //     willMigrate: nil, didMigrate: { ctx in /* 迁移逻辑 */ })
//       ]
//   }
//
// 升级清单（每次 schema 变更必须同步执行）：
// 1. 确认本次变更是「轻量」还是「非轻量」
// 2. 非轻量：冻结上一版快照（CarrySchemaV{N}Frozen.swift）
// 3. 新建 SchemaV{N+1} 指向 live 类
// 4. 在 stages 加对应 MigrationStage
// 5. 在 CarryApp.swift ModelContainer 确认 migrationPlan 已挂（现已挂，不会忘）
// 6. 真机用 老版本数据 → 安装新版 → 验证数据完整、App 正常启动

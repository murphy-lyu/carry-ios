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

// MARK: - Schema V2 — adds TripBundle.isDateless (无日期「规划中」行程)

enum SchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)

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

enum CarryMigrationPlan: SchemaMigrationPlan {
    /// All known schema versions in chronological order.
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self]
    }

    /// Migration stages between versions.
    /// V1 → V2 is lightweight: `isDateless` is an additive property with a
    /// default value (false), so existing trips migrate transparently as
    /// normal (dated) trips.
    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)
        ]
    }
}

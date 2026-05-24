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

enum CarryMigrationPlan: SchemaMigrationPlan {
    /// All known schema versions in chronological order.
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self]
    }

    /// Migration stages between versions.
    /// Empty for now — the V1 baseline matches the pre-versioned schema exactly,
    /// so SwiftData performs a transparent identity migration on first launch.
    static var stages: [MigrationStage] {
        []
    }
}

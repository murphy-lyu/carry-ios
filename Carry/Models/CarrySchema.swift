import SwiftData

enum CarrySchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [TripBundle.self, PackingSection.self, PackingItem.self]
    }
}

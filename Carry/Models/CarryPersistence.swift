import Foundation
import SwiftData

/// Business data and captured account intentions share one explicit save. The
/// writer must perform no network I/O and save this context only as its final step.
@MainActor
enum CarryPersistence {
    typealias Save = (ModelContext) throws -> Void
    enum Failure: Error { case invalidatedContext }
    // Context quarantine is based on object identity, not ModelContext's Swift
    // equality. The latter has no compatible Objective-C hash implementation.
    private static let invalidated = NSHashTable<AnyObject>(options: [.weakMemory, .objectPointerPersonality])

    static func commit(_ context: ModelContext, using save: Save) throws {
        guard !invalidated.contains(context) else { throw Failure.invalidatedContext }
        // All business paths save explicitly. A rejected capture must never be
        // committed later by autosave while a view still retains an old object.
        context.autosaveEnabled = false
        do { try save(context) }
        catch {
            // Retain materialized cascade objects through rollback; unresolved
            // future backing data cannot be snapshotted by SwiftData. A failed
            // context is still quarantined: its identity map can retain old edits.
            if !invalidated.contains(context) {
                let deleting = context.deletedModelsArray.flatMap(materializeCascade)
                withExtendedLifetime(deleting) { context.rollback() }
                invalidated.add(context)
            }
            throw error
        }
    }

    private static func materializeCascade(_ model: any PersistentModel) -> [any PersistentModel] {
        var children: [any PersistentModel] = []
        switch model {
        case let value as TripBundle:
            withExtendedLifetime(value.name) { }
            children = value.safeSections + value.safeItineraryDays + value.safeLodgingStays
        case let value as PackingSection:
            withExtendedLifetime(value.title) { }; children = value.items ?? []
        case let value as ItineraryDay:
            withExtendedLifetime(value.title) { }; children = value.stops ?? []; children += value.segments ?? []
        case let value as ItineraryStop:
            withExtendedLifetime(value.name) { }; children = value.photos ?? []; children += value.attachments ?? []
        case let value as TransportSegment:
            withExtendedLifetime(value.number) { }; children = value.attachments ?? []
        case let value as LodgingStay:
            withExtendedLifetime(value.name) { }; children = value.attachments ?? []
        case let value as PackingItem: withExtendedLifetime(value.name) { }
        case let value as StopPhoto: withExtendedLifetime(value.assetLocalIdentifier) { }
        case let value as ItineraryAttachment: withExtendedLifetime(value.displayName) { }
        case let value as MyItem: withExtendedLifetime(value.name) { }
        default: break
        }
        return [model] + children.flatMap(materializeCascade)
    }
}

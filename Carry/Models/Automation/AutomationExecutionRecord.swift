import Foundation
import SwiftData

/// The receipt and business mutation are committed in the same ModelContext save.
/// No credentials are stored here. CloudKit-compatible additive model, no uniqueness constraint.
@Model
final class AutomationExecutionRecord {
    var id: UUID = UUID()
    var connectionId: UUID = UUID()
    var requestId: UUID = UUID()
    var fingerprint: String = ""
    var receiptData: Data = Data()
    var createdAt: Date = Date()

    init(connectionId: UUID, requestId: UUID, fingerprint: String, receiptData: Data) {
        self.connectionId = connectionId
        self.requestId = requestId
        self.fingerprint = fingerprint
        self.receiptData = receiptData
    }
}

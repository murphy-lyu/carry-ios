import Foundation

enum CarryAccountFileAccessFailure: Error { case activeLease, inactiveLease, wrongAccount, invalidFile }

/// Only already-verified immutable files enter this registry. Parsing a token
/// alone never resolves a private path. The workspace revokes its lease after
/// awaiting transfers and before removing account navigation on sign-out.
@MainActor
final class CarryAccountFileAccess {
    struct Lease: Equatable, Sendable {
        let accountID: UUID
        fileprivate let nonce: UUID
    }
    static let shared = CarryAccountFileAccess()
    private var active: Lease?
    private var files: [String: URL] = [:]

    nonisolated static func isAccountReference(_ name: String) -> Bool { name.hasPrefix("carryasset1_") }

    func begin(accountID: UUID) throws -> Lease {
        guard active == nil else { throw CarryAccountFileAccessFailure.activeLease }
        let lease = Lease(accountID: accountID, nonce: UUID())
        active = lease
        return lease
    }

    /// Validate the entire update before publishing any file. The caller has
    /// verified content/hash/regular-file status on the cache actor beforehand.
    func publish(_ verified: [String: URL], lease: Lease) throws {
        guard active == lease else { throw CarryAccountFileAccessFailure.inactiveLease }
        for (raw, url) in verified {
            let token = try CarryAccountAssetToken(rawValue: raw)
            guard token.accountID == lease.accountID else { throw CarryAccountFileAccessFailure.wrongAccount }
            guard url.isFileURL, url.lastPathComponent == raw else { throw CarryAccountFileAccessFailure.invalidFile }
            if let existing = files[raw], existing != url { throw CarryAccountFileAccessFailure.invalidFile }
        }
        files.merge(verified) { existing, _ in existing }
    }

    func url(named name: String) -> URL? {
        guard let active else { return nil }
        do {
            let token = try CarryAccountAssetToken(rawValue: name)
            guard token.accountID == active.accountID else { return nil }
            return files[name]
        } catch { return nil }
    }

    func revoke(_ lease: Lease) {
        guard active == lease else { return }
        files = [:]; active = nil
    }
}

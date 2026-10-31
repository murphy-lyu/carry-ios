import XCTest
@testable import Carry

final class PackingTravelDocumentTests: XCTestCase {
    func testOverseasLegRetainsPassportAlongsideRegionalPermits() {
        for destinations in [["HK", "JP"], ["MO", "GB"], ["TW", "US"], ["CN", "HK", "TW", "JP"]] {
            let policy = PackingTravelDocumentPolicy(destinationCodes: destinations, chinaStorefront: true)
            XCTAssertFalse(policy.removesPassport, "Missing passport for \(destinations)")
            XCTAssertFalse(policy.additionalNames.isEmpty)
        }
        XCTAssertEqual(PackingTravelDocumentPolicy(destinationCodes: ["CN", "HK", "TW", "JP"], chinaStorefront: true).additionalNames,
            ["HK & Macao permit", "Taiwan permit"])
    }

    func testRegionalOnlyDestinationsReplacePassportWithRequiredPermits() {
        let policy = PackingTravelDocumentPolicy(destinationCodes: ["CN", "HK", "MO", "TW"], chinaStorefront: true)
        XCTAssertTrue(policy.removesPassport)
        XCTAssertEqual(policy.additionalNames, ["HK & Macao permit", "Taiwan permit"])
    }

    func testDomesticUnknownAndOverseasCasesStayDistinct() {
        XCTAssertEqual(PackingTravelDocumentPolicy(destinationCodes: ["CN"], chinaStorefront: true).additionalNames, ["ID card"])
        XCTAssertTrue(PackingTravelDocumentPolicy(destinationCodes: ["CN"], chinaStorefront: true).removesPassport)
        for destinations in [[], ["JP"], ["CN", "JP"]] {
            let policy = PackingTravelDocumentPolicy(destinationCodes: destinations, chinaStorefront: true)
            XCTAssertFalse(policy.removesPassport)
            XCTAssertTrue(policy.additionalNames.isEmpty)
        }
    }

    func testOnlyChinaStorefrontAppliesRegionalDocumentRules() {
        for destinations in [["HK"], ["TW"], ["CN"], ["HK", "JP"]] {
            let policy = PackingTravelDocumentPolicy(destinationCodes: destinations, chinaStorefront: false)
            XCTAssertFalse(policy.removesPassport)
            XCTAssertTrue(policy.additionalNames.isEmpty)
        }
    }

    func testDestinationCaseAndRepeatedLegsDoNotChangeDocuments() {
        XCTAssertEqual(PackingTravelDocumentPolicy(destinationCodes: ["cn", "hk", "HK", "tw", "jp"], chinaStorefront: true),
            PackingTravelDocumentPolicy(destinationCodes: ["CN", "HK", "TW", "JP"], chinaStorefront: true))
    }
}

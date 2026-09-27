import XCTest
@testable import PowderMeet

final class MtnPowderResortMappingTests: XCTestCase {
    func testNeighboringMountainNeverSuppliesHunterStatus() {
        XCTAssertNil(MtnPowderResortMapping.resortID(for: "Windham Mountain"))
    }

    func testObservedWhitespaceDoesNotDiscardKnownResort() {
        XCTAssertEqual(MtnPowderResortMapping.resortID(for: "Le Massif "), "le-massif")
        XCTAssertEqual(MtnPowderResortMapping.resortID(for: " Nekoma "), "nekoma")
    }

    func testSummerAndCombinedDuplicateFeedsStayExcluded() {
        XCTAssertNil(MtnPowderResortMapping.resortID(for: "Stratton Summer"))
        XCTAssertNil(MtnPowderResortMapping.resortID(for: "Bear Mountain / Snow Summit / Snow Valley"))
        XCTAssertEqual(MtnPowderResortMapping.resortID(for: "Stratton"), "stratton")
    }
}

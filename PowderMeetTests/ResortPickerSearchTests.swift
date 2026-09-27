import XCTest
@testable import PowderMeet

final class ResortPickerSearchTests: XCTestCase {
    func testAliasesCountryPassAndWhitespaceAreSearchable() {
        XCTAssertEqual(Set(ResortEntry.search("  \n ").map(\.id)), Set(ResortEntry.catalog.map(\.id)))
        XCTAssertFalse(ResortEntry.search("canada").isEmpty)
        XCTAssertTrue(ResortEntry.search("canada").allSatisfy { $0.country.lowercased().contains("canada") })
        XCTAssertFalse(ResortEntry.search("  ikon  ").isEmpty)
        XCTAssertTrue(ResortEntry.search("ikon").allSatisfy { $0.passProducts.contains(.ikon) })
        for resort in ResortEntry.catalog {
            for alias in resort.aliases where !alias.isEmpty {
                XCTAssertTrue(ResortEntry.search(alias).contains { $0.id == resort.id }, "Missing alias: \(alias)")
            }
        }
    }

    func testFullRegionNamesAndCountryAliases() {
        XCTAssertTrue(ResortEntry.search("Colorado").contains { $0.id == "vail" })
        XCTAssertTrue(ResortEntry.search("soelden").contains { $0.id == "soelden" })
        XCTAssertTrue(ResortEntry.search("Bald Mountain").contains { $0.id == "sun-valley" })
        XCTAssertTrue(ResortEntry.search("Quebec").contains { $0.id == "tremblant" })
        XCTAssertTrue(ResortEntry.search("United States").contains { $0.id == "vail" })
        for resort in ResortEntry.catalog {
            XCTAssertTrue(ResortEntry.search(ResortEntry.regionLabel(resort.region)).contains { $0.id == resort.id })
        }
    }

    func testRecoveredEmptyMountainsUseTheCorrectedSnapshot() {
        for id in ["crotched", "mount-sunapee", "rusutsu", "myoko-suginohara", "coronet-peak"] {
            XCTAssertEqual(ResortEntry.catalog.first { $0.id == id }?.effectivePinnedSnapshotDate, "2026-09-20")
        }
    }

    func testMultipleTermsAndUnknownSearch() {
        XCTAssertTrue(ResortEntry.search("whistler canada").contains { $0.id == "whistler" })
        XCTAssertTrue(ResortEntry.search("not-a-real-mountain-xyz").isEmpty)
    }
}

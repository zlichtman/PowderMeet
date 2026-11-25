import CSQLite
import CZlib
import Testing
@testable import PMLogging

@Test func packageBuilds() {
    #expect(PMLoggingPackage.name == "PMLogging")
}

@Test func systemLibrariesLink() {
    #expect(zlibVersion() != nil)
    #expect(sqlite3_libversion_number() > 0)
}

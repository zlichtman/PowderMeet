import Foundation
import MountainCore
import PowderMeetAPI
import Testing
@testable import AppCore

private func resort(
    _ id: String, _ country: String, lon: Double, lat: Double, map: Bool = true
) -> PublishedResort {
    PublishedResort(
        id: id, name: id.capitalized, timezone: "UTC", center: Coordinate(lon: lon, lat: lat),
        passProducts: ["epic"], bundleID: map ? BundleID(String(repeating: "a", count: 64)) : nil,
        region: country == "Canada" ? "BC" : country == "USA" ? "CO" : nil, country: country
    )
}

private let catalog = [
    resort("vail", "USA", lon: -106.37, lat: 39.62),
    resort("keystone", "USA", lon: -105.94, lat: 39.58, map: false),
    resort("whistler", "Canada", lon: -122.95, lat: 50.09),
    resort("niseko", "Japan", lon: 140.68, lat: 42.86, map: false),
]

@Test func pickerPutsLastUsedThenNearestThenTheClosestCountry() {
    // Standing in Whistler village; Keystone was "used" but has no map now.
    let sections = ResortDirectory.sections(
        catalog, here: Coordinate(lon: -122.96, lat: 50.11), recent: ["keystone", "vail", "gone"]
    )
    #expect(sections.map(\.id) == ["last-used", "nearest", "country:Canada", "country:USA", "country:Japan"])
    #expect(sections[0].resorts.map(\.id) == ["vail"])
    #expect(sections[1].resorts.map(\.id) == ["whistler"])
    // A resort without a map is still listed under its country.
    #expect(sections[3].resorts.map(\.id) == ["keystone", "vail"])
}

@Test func pickerWithoutAPositionListsTheBiggestCountryFirst() {
    let sections = ResortDirectory.sections(catalog)
    #expect(sections.map(\.id) == ["country:USA", "country:Canada", "country:Japan"])
}

@Test func pickerSearchMatchesNamePassAndPlaceAndPutsMapsFirst() {
    #expect(ResortDirectory.sections(catalog, query: "epic usa").first?.resorts.map(\.id) == ["vail", "keystone"])
    #expect(ResortDirectory.sections(catalog, query: "japan").first?.resorts.map(\.id) == ["niseko"])
    #expect(ResortDirectory.sections(catalog, query: "zermatt").isEmpty)
}

@Test func pickerSearchMatchesOtherNamesAndFullRegionNames() {
    var arlberg = resort("arlberg", "Austria", lon: 10.26, lat: 47.13)
    arlberg.region = "AT"
    arlberg.aliases = ["Ski Arlberg", "St. Anton"]
    var bigBear = resort("big-bear", "USA", lon: -116.87, lat: 34.24)
    bigBear.region = "CA"
    bigBear.aliases = ["Bear Mountain", "Snow Summit"]
    let all = catalog + [arlberg, bigBear]
    func ids(_ query: String) -> [String]? { ResortDirectory.sections(all, query: query).first?.resorts.map(\.id) }

    #expect(ids("st. anton") == ["arlberg"])
    #expect(ids("snow summit") == ["big-bear"])
    // A state or province by name, accents and case ignored.
    #expect(ids("Colorado") == ["vail", "keystone"])
    #expect(ids("british columbia") == ["whistler"])
    #expect(ids("california bear") == ["big-bear"])
    // A code still matches, and a name never matches another region's resorts.
    #expect(ids("bc") == ["whistler"])
    #expect(ResortDirectory.sections(all, query: "utah").isEmpty)
}

@Test func aMapsFreshnessIsSaidInDaysThenByItsDate() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Denver"))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 9)))
    func ago(_ days: Int) throws -> Date { try #require(calendar.date(byAdding: .day, value: -days, to: now)) }

    #expect(ResortDirectory.freshness(builtAt: now.addingTimeInterval(3_600), now: now, calendar: calendar) == .today)
    #expect(try ResortDirectory.freshness(builtAt: ago(1), now: now, calendar: calendar) == .yesterday)
    #expect(try ResortDirectory.freshness(builtAt: ago(6), now: now, calendar: calendar) == .thisWeek)
    #expect(try ResortDirectory.freshness(builtAt: ago(7), now: now, calendar: calendar) == .on(ago(7), showsYear: false))
    #expect(try ResortDirectory.freshness(builtAt: ago(330), now: now, calendar: calendar) == .on(ago(330), showsYear: true))
}

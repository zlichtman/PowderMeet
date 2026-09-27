import CoreLocation
import XCTest
@testable import PowderMeet

@MainActor
final class LocationSessionTests: XCTestCase {
    func testWhenInUseSessionContinuesWithIndicatorAndStopsAtEnd() {
        let driver = LocationDriver()
        let subject = LocationManager(manager: driver)
        subject.startSession()
        XCTAssertTrue(driver.allowsBackgroundLocationUpdates)
        XCTAssertTrue(driver.showsBackgroundLocationIndicator)
        XCTAssertGreaterThan(driver.starts, 0)
        XCTAssertEqual(driver.alwaysRequests, 0)
        subject.endSession()
        XCTAssertFalse(driver.allowsBackgroundLocationUpdates)
        XCTAssertFalse(driver.showsBackgroundLocationIndicator)
        XCTAssertGreaterThan(driver.stops, 0)
    }

    func testForegroundUpdatesDoNotEnableBackgroundTracking() {
        let driver = LocationDriver()
        let subject = LocationManager(manager: driver)
        subject.startUpdating()
        XCTAssertFalse(driver.allowsBackgroundLocationUpdates)
        XCTAssertFalse(driver.showsBackgroundLocationIndicator)
    }

    func testRevokingPermissionStopsUpdatesAndInvalidatesRoutingFix() {
        let driver = LocationDriver()
        let subject = LocationManager(manager: driver)
        subject.startSession()
        subject.locationManager(driver, didUpdateLocations: [CLLocation(latitude: 50.1, longitude: -122.9)])
        XCTAssertNotNil(subject.currentLocation)
        driver.status = .denied
        subject.locationManagerDidChangeAuthorization(driver)
        XCTAssertFalse(driver.allowsBackgroundLocationUpdates)
        XCTAssertFalse(driver.showsBackgroundLocationIndicator)
        XCTAssertNil(subject.currentLocation)
        XCTAssertNil(subject.currentFixTimestamp)
        subject.locationManager(driver, didUpdateLocations: [CLLocation(latitude: 50.2, longitude: -122.8)])
        XCTAssertNil(subject.currentLocation, "Queued fixes must not restore a revoked location")
        XCTAssertGreaterThan(driver.stops, 0)
        driver.status = .authorizedWhenInUse
        subject.locationManagerDidChangeAuthorization(driver)
        XCTAssertTrue(driver.allowsBackgroundLocationUpdates)
        XCTAssertEqual(driver.alwaysRequests, 0)
    }

    func testDeniedPermissionCannotStartSession() {
        let driver = LocationDriver()
        driver.status = .denied
        let subject = LocationManager(manager: driver)
        subject.startSession()
        XCTAssertFalse(subject.sessionActive)
        XCTAssertFalse(driver.allowsBackgroundLocationUpdates)
        XCTAssertEqual(driver.starts, 0)
    }
}

private final class LocationDriver: CLLocationManager {
    var status: CLAuthorizationStatus = .authorizedWhenInUse
    var starts = 0
    var stops = 0
    var alwaysRequests = 0
    private var background = false
    private var indicator = false
    override var authorizationStatus: CLAuthorizationStatus { status }
    override var allowsBackgroundLocationUpdates: Bool {
        get { background }
        set { background = newValue }
    }
    override var showsBackgroundLocationIndicator: Bool {
        get { indicator }
        set { indicator = newValue }
    }
    override func startUpdatingLocation() { starts += 1 }
    override func stopUpdatingLocation() { stops += 1 }
    override func requestAlwaysAuthorization() { alwaysRequests += 1 }
}

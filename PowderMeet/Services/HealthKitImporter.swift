//
//  HealthKitImporter.swift
//  PowderMeet
//
//  Reads downhill-skiing + snowboarding workouts from Apple Health,
//  converts each one's HKWorkoutRoute samples into the standard
//  ParsedActivity envelope, and feeds the batch into ActivityImporter.
//
//  Why HealthKit is the omnibus integration:
//    • Slopes (iOS-only, no public API) writes workouts to Health by default.
//    • Apple Watch native ski/snowboard workouts land here too.
//    • Strava + Garmin Connect mirror their workouts to Health when their
//      respective Health-write toggles are on (default for both).
//    • Trace Snow / Ski Tracks etc. similarly write to Health.
//
//  So a single HealthKit pull covers most of the third-party history a
//  user might have without having to build per-vendor OAuth integrations.
//  Strava direct OAuth is still a viable add-on for users who don't have
//  the Health write-back enabled, but it's not required for v1.
//
//  Threading note: HKHealthStore.requestAuthorization presents UI; the
//  importer is @MainActor to satisfy that. Sample queries themselves run
//  off-thread inside HealthKit's executor; we bridge with continuations.
//

import Foundation
import CoreLocation
#if canImport(HealthKit)
import HealthKit
#endif

@MainActor
final class HealthKitImporter {

    // MARK: - Singleton

    static let shared = HealthKitImporter()
    private init() {}

    // MARK: - Availability

    static var isAvailable: Bool {
        #if canImport(HealthKit)
        return HKHealthStore.isHealthDataAvailable()
        #else
        return false
        #endif
    }

    // MARK: - Errors

    enum HealthError: LocalizedError {
        case notAvailable
        case notAuthorized
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .notAvailable: return "Apple Health isn't available on this device."
            case .notAuthorized: return "Health access denied — turn it on in Settings → Privacy → Health."
            case .underlying(let err): return err.localizedDescription
            }
        }
    }

    #if canImport(HealthKit)

    private let store = HKHealthStore()

    /// Read-only types we ever request. HealthKit auth is per-type and per-app;
    /// requesting once is enough — the OS remembers. Re-requesting is cheap.
    private var readTypes: Set<HKObjectType> {
        var set: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
        ]
        if let dist = HKObjectType.quantityType(forIdentifier: .distanceDownhillSnowSports) {
            set.insert(dist)
        }
        return set
    }

    // MARK: - Authorization

    /// Bridges HKHealthStore.requestAuthorization to async/throws. The OS
    /// only shows the prompt the first time; subsequent calls return without
    /// UI. Apple deliberately doesn't tell us "did the user say yes" here
    /// (privacy — distinguishing denied vs. no-data is itself a leak), so
    /// callers must treat success as "we got past the gate" not "we have
    /// data". The actual fetch surfaces empty arrays on denial.
    func requestAuthorization() async throws {
        guard Self.isAvailable else { throw HealthError.notAvailable }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: nil, read: readTypes) { success, error in
                if let error { cont.resume(throwing: HealthError.underlying(error)); return }
                guard success else { cont.resume(throwing: HealthError.notAuthorized); return }
                cont.resume(returning: ())
            }
        }
    }

    // MARK: - Public entry — fetch + convert + import

    /// End-to-end: request auth (no-op after first call), pull every
    /// downhill-ski + snowboard workout since `since` (default: all time),
    /// convert each into a `ParsedActivity`, then run them through the
    /// shared `ActivityImporter` pipeline so dedup / matching / persistence
    /// are identical to file imports.
    func importAll(via importer: ActivityImporter, since: Date? = nil) async throws -> BatchImportResult {
        try await requestAuthorization()
        let workouts = try await fetchSkiWorkouts(since: since)
        var parsedList: [ParsedActivity] = []
        parsedList.reserveCapacity(workouts.count)
        for workout in workouts {
            if let parsed = await parsedActivity(from: workout) {
                parsedList.append(parsed)
            }
        }
        return await importer.importParsedActivities(parsedList)
    }

    // MARK: - Workout fetch

    /// Sample query for downhill skiing + snowboarding workouts. Sorted
    /// newest-first so a paginated UI could show the most recent activity
    /// at the top — currently the importer pulls the whole window.
    private func fetchSkiWorkouts(since: Date?) async throws -> [HKWorkout] {
        let activityPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            HKQuery.predicateForWorkouts(with: .downhillSkiing),
            HKQuery.predicateForWorkouts(with: .snowboarding),
        ])
        let datePredicate = since.map {
            HKQuery.predicateForSamples(withStart: $0, end: nil, options: .strictStartDate)
        }
        let predicate: NSPredicate = datePredicate
            .map { NSCompoundPredicate(andPredicateWithSubpredicates: [activityPredicate, $0]) }
            ?? activityPredicate

        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[HKWorkout], Error>) in
            let q = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error { cont.resume(throwing: HealthError.underlying(error)); return }
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
    }

    // MARK: - Workout → ParsedActivity

    /// Pulls the route samples for one workout and stitches them into a
    /// single `ParsedRunSegment`. The activity importer's downstream
    /// pipeline already handles single-segment runs by elevation-segmenting
    /// them (see `ActivityImporter.processParsed`), so we don't need to
    /// pre-split into individual runs here — we'd just be re-deriving what
    /// the importer does. Returns nil if the workout has no route data
    /// (HealthKit lets workouts exist without routes — pre-Watch ski apps,
    /// manual entry, etc.).
    private func parsedActivity(from workout: HKWorkout) async -> ParsedActivity? {
        let locations: [CLLocation]
        do {
            locations = try await fetchRouteLocations(for: workout)
        } catch {
            // Empty route is a normal case (manual workouts, pre-Watch apps).
            // Genuine HealthKit query failures used to be swallowed silently;
            // log them so an entire batch returning zero runs is debuggable.
            AppLog.importer.error("HealthKit route fetch failed for workout \(workout.uuid): \(error.localizedDescription)")
            locations = []
        }
        guard !locations.isEmpty else { return nil }

        let points = locations.map { loc in
            GPXTrackPoint(
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude,
                elevation: loc.altitude.isFinite ? loc.altitude : nil,
                timestamp: loc.timestamp,
                speed: loc.speed >= 0 ? loc.speed : nil
            )
        }

        let start = workout.startDate
        let end = workout.endDate
        let duration = workout.duration

        // HealthKit gives us workout-level totals; surface them so the
        // importer can prefer them over derived stats (matches how Slopes /
        // TCX / FIT lap data flows through).
        let nativeDistance: Double? = {
            #if canImport(HealthKit)
            if let dist = workout.statistics(for: HKQuantityType(.distanceDownhillSnowSports))?
                .sumQuantity()?
                .doubleValue(for: .meter()) {
                return dist
            }
            return workout.totalDistance?.doubleValue(for: .meter())
            #else
            return nil
            #endif
        }()

        let segment = ParsedRunSegment(
            runNumber: 1,
            startTime: start,
            endTime: end,
            durationSeconds: duration,
            topSpeedMS: nil,            // HealthKit workouts don't store peak speed natively
            avgSpeedMS: nil,            // let the importer derive from points
            distanceMeters: nativeDistance,
            verticalMeters: nil,
            points: points
        )

        // Dedup hash anchors on the workout UUID so re-importing the same
        // Health workout (e.g. user runs the importer twice) collapses to
        // a single .duplicate outcome at the importer's whole-source check.
        // Including the route sample count guards against a workout whose
        // route gets back-filled later by the source app — fresh hash, fresh
        // import.
        let hash = "healthkit:\(workout.uuid.uuidString):\(points.count)"

        return ParsedActivity(
            source: .healthKit,
            resortName: nil,            // HealthKit doesn't carry venue metadata
            sourceFileHash: hash,
            segments: [segment]
        )
    }

    /// HKWorkoutRoute → flat [CLLocation]. HealthKit streams location
    /// samples in chunks; we collect everything before returning so the
    /// caller gets a single ordered list.
    private func fetchRouteLocations(for workout: HKWorkout) async throws -> [CLLocation] {
        let routes = try await fetchRoutes(for: workout)
        var all: [CLLocation] = []
        for route in routes {
            let chunk = try await fetchLocations(in: route)
            all.append(contentsOf: chunk)
        }
        // Sort defensively — multiple routes per workout should already be
        // chronological, but HealthKit doesn't formally guarantee order.
        all.sort { $0.timestamp < $1.timestamp }
        return all
    }

    private func fetchRoutes(for workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        let predicate = HKQuery.predicateForObjects(from: workout)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[HKWorkoutRoute], Error>) in
            let q = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error { cont.resume(throwing: HealthError.underlying(error)); return }
                cont.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            store.execute(q)
        }
    }

    private func fetchLocations(in route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[CLLocation], Error>) in
            var collected: [CLLocation] = []
            let q = HKWorkoutRouteQuery(route: route) { _, locs, done, error in
                if let error { cont.resume(throwing: HealthError.underlying(error)); return }
                if let locs { collected.append(contentsOf: locs) }
                if done { cont.resume(returning: collected) }
            }
            store.execute(q)
        }
    }

    #else

    func requestAuthorization() async throws { throw HealthError.notAvailable }
    func importAll(via importer: ActivityImporter, since: Date? = nil) async throws -> BatchImportResult {
        throw HealthError.notAvailable
    }

    #endif
}

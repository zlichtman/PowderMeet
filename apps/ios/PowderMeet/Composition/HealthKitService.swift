import AppCore
import CoreLocation
import Foundation
import HealthKit
import MountainCore
import Synchronization

/// Apple Health as an activity source: downhill
/// skiing and snowboarding workouts with their GPS route. Apple Watch, Slopes,
/// Strava and Garmin Connect write these when their Health setting is on, so
/// one read covers most of a skier's history. Read only; workouts without a
/// route are skipped. The runs go through `ActivityLibrary.importRecordings`,
/// the same path as files.
///
/// HealthKit never says whether reading was refused (that would itself leak
/// data), so a refusal looks like an empty history; the screen says so.
final class HealthKitService {
    private let store = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> { [HKObjectType.workoutType(), HKSeriesType.workoutRoute()] }

    /// Shows the Health sheet the first time; afterwards returns at once.
    func requestAccess() async throws(PowderMeetError) {
        guard Self.isAvailable else { throw .permission(.health) }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
        } catch {
            throw .permission(.health)
        }
    }

    /// What one read found: the workouts with a usable route, and how many
    /// workouts' routes could not be read this time.
    struct Read {
        var recordings: [ActivityLibrary.Recording] = []
        var unreadRoutes = 0
    }

    /// Every ski or snowboard workout that ended after `since` (all of them
    /// when nil), oldest first, as recordings with their routes.
    func recordings(since: Date?) async throws(PowderMeetError) -> Read {
        let workouts: [HKWorkout]
        do {
            workouts = try await skiWorkouts(since: since)
        } catch let error as HKError where Self.isRefusal(error) {
            throw .permission(.health)
        } catch {
            throw .data(.healthUnreadable)
        }
        var read = Read()
        for workout in workouts {
            let route: [Fix]
            do {
                route = try await routeFixes(for: workout)
            } catch {
                // One workout's route failing to read leaves the others; the
                // count keeps the caller from reading past it for good.
                read.unreadRoutes += 1
                continue
            }
            guard route.count >= 2 else { continue }
            let app = workout.sourceRevision.source.name
            let day = workout.startDate.formatted(date: .abbreviated, time: .omitted)
            read.recordings.append(ActivityLibrary.Recording(
                healthWorkoutNamed: "\(app) · \(day)", sourceApp: app, route: route
            ))
        }
        return read
    }

    /// Health being off or withheld, as opposed to a read that failed this once.
    private static func isRefusal(_ error: HKError) -> Bool {
        switch error.code {
        case .errorAuthorizationDenied, .errorAuthorizationNotDetermined, .errorHealthDataUnavailable,
             .errorHealthDataRestricted:
            true
        default:
            false
        }
    }

    private func skiWorkouts(since: Date?) async throws -> [HKWorkout] {
        var predicate: NSPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            HKQuery.predicateForWorkouts(with: .downhillSkiing),
            HKQuery.predicateForWorkouts(with: .snowboarding),
        ])
        if let since {
            predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                predicate, HKQuery.predicateForSamples(withStart: since, end: nil, options: []),
            ])
        }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)], sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        return try await descriptor.result(for: store)
    }

    /// The workout's route samples, read in the batches HealthKit delivers.
    private func routeFixes(for workout: HKWorkout) async throws -> [Fix] {
        let routes = try await HKSampleQueryDescriptor(
            predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        ).result(for: store)
        var fixes: [Fix] = []
        for route in routes {
            fixes += try await Self.locations(of: route, in: store)
        }
        return fixes.sorted { $0.capturedAt < $1.capturedAt }
    }

    /// Nonisolated so the query's handler, which HealthKit calls on its own
    /// queue, is not inferred to be main-actor code.
    private nonisolated static func locations(of route: HKWorkoutRoute, in store: HKHealthStore) async throws -> [Fix] {
        let collected = Mutex<[Fix]>([])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let batch = (locations ?? []).filter { $0.horizontalAccuracy >= 0 }.map { location in
                    Fix(
                        coordinate: Coordinate(lon: location.coordinate.longitude, lat: location.coordinate.latitude),
                        accuracyM: location.horizontalAccuracy, capturedAt: location.timestamp,
                        altitudeM: location.verticalAccuracy >= 0 ? location.altitude : nil,
                        speedMS: location.speed >= 0 ? location.speed : nil
                    )
                }
                collected.withLock { $0 += batch }
                if done { continuation.resume(returning: collected.withLock { $0 }) }
            }
            store.execute(query)
        }
    }
}

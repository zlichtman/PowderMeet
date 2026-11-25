import Foundation

/// Why a file could not be imported. Every case is something the import
/// screen can say to the skier; none of them is a crash or an empty result.
public enum ActivityImportError: Error, Sendable, Equatable {
    /// Not GPX, TCX, FIT, Slopes or Ski Tracks.
    case unrecognizedFormat
    /// The right kind of file, but damaged or not what its name says.
    case unreadable(ActivityParseError)
    /// The file holds no GPS track at all (a workout with no route).
    case noTrack
    /// The track has positions but no times, as a planned route does.
    case noTimestamps
    /// The track has no altitude, so runs cannot be told from lift rides.
    case noElevation
    /// A readable, timed track with altitude in which no ski run was found.
    case noDescents(NoDescentsReason)
}

public enum NoDescentsReason: String, Sendable, Equatable {
    /// The recording never descends 15 m in one go.
    case flatTrack
    /// It descends, but only in a vehicle or on a lift.
    case onlyVehicleOrLift
    /// It descends, but too slowly or too briefly to be skiing.
    case tooSmallOrSlow
}

/// Something the skier should know about an import that succeeded.
public enum ImportWarning: Sendable, Hashable {
    /// Part of the track had no altitude and it was interpolated. `share` is
    /// the fraction of fixes affected, 0...1.
    case elevationInterpolated(share: Double)
    /// No altitude anywhere; the app's own run list was used unchecked.
    case elevationMissing
    /// Times had no zone and were read as UTC, so they may be hours off.
    /// `ImportedActivity.readingUnzonedTimes(in:)` clears it once the
    /// resort, and so the zone the logger wrote in, is known.
    case timeZoneAssumedUTC
    /// The file covers more than one day.
    case multipleDays(Int)
    /// Fixes without a time were left out.
    case untimedPointsDropped(Int)
    /// Corrupt, repeated or impossible fixes were left out. Reported only
    /// when they are more than 2 % of the file.
    case pointsDiscarded(Int)
    /// Runs in the app's own list that the track shows were a drive or a
    /// lift ridden down, and were left out.
    case listedRunsDropped(Int)
    /// Listed runs that each held several laps with a lift between them, and
    /// were split.
    case listedRunsSplit(Int)
    /// Runs the app's own list had missed.
    case unlistedRunsAdded(Int)
    /// Driving was recorded and left out.
    case vehicleTravelIgnored(Int)
    /// Lifts or gondolas ridden downhill were left out.
    case liftDescentsIgnored(Int)
}

public struct ImportedActivity: Sendable {
    /// The file format, or nil for a recording that never was a file (live
    /// recording, an Apple Health workout).
    public var format: ActivityFormat?
    /// The app or device named in the file, if any.
    public var sourceApp: String?
    public var resortName: String?
    public var descents: [Descent]
    public var warnings: [ImportWarning]
    /// The file's own totals, for display next to ours.
    public var declared: DeclaredTotals

    /// Sum of the descents' vertical, in metres.
    public var totalVerticalM: Double {
        descents.reduce(0) { $0 + ($1.stats.verticalM ?? 0) }
    }

    public init(
        format: ActivityFormat?, sourceApp: String? = nil, resortName: String? = nil,
        descents: [Descent], warnings: [ImportWarning] = [], declared: DeclaredTotals = DeclaredTotals()
    ) {
        self.format = format
        self.sourceApp = sourceApp
        self.resortName = resortName
        self.descents = descents
        self.warnings = warnings
        self.declared = declared
    }
}

/// The one call the app makes to turn a file into descents.
public enum ActivityImporter {
    public static func importActivity(
        fileName: String?, data: Data
    ) throws(ActivityImportError) -> ImportedActivity {
        guard let format = ActivityFormat.detect(fileName: fileName, data: data) else {
            throw .unrecognizedFormat
        }
        let activity: ParsedActivity
        do {
            activity = try format.parser.parse(data)
        } catch {
            // A wrong extension is common ("activity.gpx" that is really TCX);
            // the content decides before giving up.
            guard let sniffed = ActivityFormat.detect(fileName: nil, data: data), sniffed != format else {
                throw .unreadable(error)
            }
            let retried: ParsedActivity
            do {
                retried = try sniffed.parser.parse(data)
            } catch {
                throw .unreadable(error)
            }
            return try finish(retried, format: sniffed)
        }
        return try finish(activity, format: format)
    }

    /// A recording that is not a file, such as an Apple Health workout's route:
    /// the same checks and segmenter as a file, with `activity.source` kept.
    public static func importRecording(
        _ activity: ParsedActivity
    ) throws(ActivityImportError) -> ImportedActivity {
        try finish(activity, format: nil)
    }

    /// A sport named in the file that is plainly a bike ride or a run. A file
    /// that names no sport, or any other (a hike may be a ski tour), is still read.
    static func isClearlyNotSnowSport(_ sport: String) -> Bool {
        let name = sport.lowercased()
        if name.contains("ski") || name.contains("snowboard") { return false }
        // Strava's "Ride" and "VirtualRide"; not "freeride", which is skiing.
        let ride = name.hasSuffix("ride") && !name.hasSuffix("freeride")
        return ride || ["bik", "cycl", "run"].contains { name.contains($0) }
    }

    static func finish(
        _ activity: ParsedActivity, format: ActivityFormat?
    ) throws(ActivityImportError) -> ImportedActivity {
        let allPoints = activity.fullTrack.isEmpty ? activity.segments.flatMap(\.points) : activity.fullTrack
        guard allPoints.count >= 2 else { throw .noTrack }
        guard allPoints.contains(where: { $0.timestamp != nil }) else { throw .noTimestamps }
        // A downhill bike ride or a hilly run descends like a ski run, and its
        // speeds would teach the pace model bike speeds.
        if let sport = activity.declared.sport, isClearlyNotSnowSport(sport) {
            throw .noDescents(.onlyVehicleOrLift)
        }

        let outcome = DescentSegmenter.analyze(activity)
        var warnings: [ImportWarning] = []
        if outcome.elevationMissing {
            // Only a provider's run list can stand in for altitude.
            guard !outcome.descents.isEmpty else { throw .noElevation }
            warnings.append(.elevationMissing)
        }
        guard !outcome.descents.isEmpty else {
            let vehicleOrLift = (outcome.rejected[.vehicle] ?? 0) + (outcome.rejected[.liftDownhill] ?? 0)
            if vehicleOrLift > 0 { throw .noDescents(.onlyVehicleOrLift) }
            throw .noDescents(outcome.rejected.isEmpty ? .flatTrack : .tooSmallOrSlow)
        }

        if outcome.interpolatedElevationShare >= 0.05 {
            warnings.append(.elevationInterpolated(share: outcome.interpolatedElevationShare))
        }
        if activity.assumedUTC { warnings.append(.timeZoneAssumedUTC) }
        if outcome.untimedPoints > 0 { warnings.append(.untimedPointsDropped(outcome.untimedPoints)) }
        if outcome.discardedPoints * 50 > allPoints.count {
            warnings.append(.pointsDiscarded(outcome.discardedPoints))
        }
        if outcome.providerRunsDropped > 0 { warnings.append(.listedRunsDropped(outcome.providerRunsDropped)) }
        if outcome.providerRunsSplit > 0 { warnings.append(.listedRunsSplit(outcome.providerRunsSplit)) }
        if outcome.providerRunsRecovered > 0 { warnings.append(.unlistedRunsAdded(outcome.providerRunsRecovered)) }
        if let vehicles = outcome.rejected[.vehicle], vehicles > 0 { warnings.append(.vehicleTravelIgnored(vehicles)) }
        if let lifts = outcome.rejected[.liftDownhill], lifts > 0 { warnings.append(.liftDescentsIgnored(lifts)) }
        let days = dayCount(outcome.descents)
        if days > 1 { warnings.append(.multipleDays(days)) }

        return ImportedActivity(
            format: format, sourceApp: activity.sourceApp, resortName: activity.resortName,
            descents: outcome.descents, warnings: warnings, declared: activity.declared
        )
    }

    /// Ski days in the descents: a new day starts after twelve hours without
    /// a run, which needs no time zone and no calendar.
    public static func dayCount(_ descents: [Descent]) -> Int {
        var days = descents.isEmpty ? 0 : 1
        for (earlier, later) in zip(descents, descents.dropFirst())
        where later.startedAt.timeIntervalSince(earlier.endedAt) > 12 * 3_600 {
            days += 1
        }
        return days
    }
}

extension ImportedActivity {
    /// A logger that writes times with no zone writes the clock on the
    /// mountain, but the parser cannot know the mountain and reads them as
    /// UTC (`timeZoneAssumedUTC`). Once the resort is known this reads the
    /// same clock times in `zone` instead, and drops the warning. A file that
    /// gave its zone comes back unchanged.
    public func readingUnzonedTimes(in zone: TimeZone) -> ImportedActivity {
        guard warnings.contains(.timeZoneAssumedUTC) else { return self }
        var activity = self
        activity.descents = descents.map { descent in
            // One offset per run, taken at its start, so a run never gains or
            // loses time across a daylight-saving change.
            let shift = -Self.offset(of: zone, atClockTime: descent.startedAt)
            var shifted = descent
            shifted.startedAt += shift
            shifted.endedAt += shift
            shifted.points = descent.points.map { point in
                var point = point
                point.timestamp = point.timestamp.map { $0 + shift }
                return point
            }
            return shifted
        }
        activity.warnings.removeAll { $0 == .timeZoneAssumedUTC }
        return activity
    }

    /// The zone's offset from UTC when its clocks show `clock` (a time read as
    /// UTC). The offset depends on the instant, which depends on the offset,
    /// so it is found in two steps; that is exact except in the hour a
    /// daylight-saving change skips or repeats.
    static func offset(of zone: TimeZone, atClockTime clock: Date) -> TimeInterval {
        let guess = clock - TimeInterval(zone.secondsFromGMT(for: clock))
        return TimeInterval(zone.secondsFromGMT(for: guess))
    }
}

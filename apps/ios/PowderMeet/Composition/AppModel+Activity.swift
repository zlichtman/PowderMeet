import AppCore
import Foundation
import MapScene
import MapboxAdapter
import MeetSolver
import MountainCore
import Observation
import PMLogging
import PowderMeetAPI

extension AppModel {
    /// Imported runs set the speeds the solver reads (`specs/08-ACTIVITY.md`
    /// section 4). Called with every history the backend returns; writes only
    /// when the answer differs from what the profile holds.
    func recalibrate(from history: ActivityHistory) {
        guard let profile, !profile.baselineSpeeds.isEmpty else { return }
        let speeds = PaceCalibration.baselineSpeeds(
            ability: Ability(profileValue: profile.ability), evidence: history.evidence
        )
        let unchanged = speeds.count == profile.baselineSpeeds.count && speeds.allSatisfy { key, speed in
            profile.baselineSpeeds[key].map { abs($0 - speed) < 0.005 } ?? false
        }
        guard !unchanged else { return }
        deps.log.info(.activity, "pace recalibrated from \(history.calibrationRuns) runs")
        session.send(.profileEdited(ProfilePatch().baselineSpeeds(speeds)))
    }

    /// After a history load (an import, a live run stored, a sign-in): a
    /// message for each badge or tier earned since this phone last looked, in
    /// the one transient-message slot. Only once the catalog and the meets
    /// are here, as Passport, Epic and Ikon and the meet badges read them:
    /// without them those would look unearned now and newly earned later.
    func announceNewBadges() {
        guard !catalog.resorts.isEmpty, activity.hasLoaded, meetHistory != nil else { return }
        let outcome = BadgeMoments.check(badgeStandings, seen: activity.seenBadges)
        activity.rememberSeenBadges(outcome.seen)
        guard !outcome.newlyEarned.isEmpty else { return }
        let message = Wording.newBadges(outcome.newlyEarned)
        let toasts = deps.toasts
        Task { await toasts.post(message: message, kind: .badge) }
    }

    /// Reads the skier's meets for the meet badges: on sign-in, after a meet
    /// ends and on reconnecting when the last read failed. The server keeps
    /// the record, so nothing is saved; a failed read leaves the last one,
    /// and the badges wait rather than read as none reached.
    func loadMeetHistory() {
        run("meet-history") { [weak self, deps] in
            do {
                // The most the server returns in one read.
                let meets = try await deps.backend.meetHistory(limit: 200)
                guard !Task.isCancelled else { return }
                self?.meetHistory = meets
                self?.announceNewBadges()
            } catch {
                deps.log.error(.meet, "meet history read failed: \(error)")
            }
        }
    }

    /// A file opened in PowderMeet from Files, Mail or another app's share sheet.
    /// Files opened before sign-in finishes (a cold launch from Files) or while
    /// a batch runs (several files shared at once arrive one URL at a time)
    /// wait here and import as the next batch.
    func openActivityFile(_ url: URL) {
        openProfilePage(.activity)
        activity.enqueue([url])
    }
}

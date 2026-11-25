import AppCore
import Foundation
import MapScene
import MapboxAdapter
import MeetSolver
import MountainCore
import Observation
import PMLogging
import PowderMeetAPI

/// Every resort in the catalog, as the picker lists it. One with no published
/// map is shown but cannot be selected.
nonisolated struct CatalogState: Sendable, Hashable {
    var resorts: [PublishedResort] = []
    var isLoading = false
    var failure: PowderMeetError?
    /// The list is the last one saved on the phone: the server did not answer.
    var isSaved = false
}

extension AppModel {
    var selectedResort: PublishedResort? {
        guard let id = resort?.resortID else { return nil }
        return catalog.resorts.first { $0.id == id }
    }

    /// The picker's sections for what is typed in its search field. Opened
    /// because the phone is inside several resorts' boxes, it lists just those
    /// until something is typed.
    func resortSections(matching query: String, sort: ResortDirectory.Sort = .country) -> [ResortDirectory.Section] {
        // Only mountains with a map: one without cannot be opened, so it is
        // not offered.
        let mapped = catalog.resorts.filter(\.hasMap)
        if let choices = arrivalChoices, query.trimmingCharacters(in: .whitespaces).isEmpty {
            let sections = ResortDirectory.arrivalChoices(choices, in: mapped)
            if !sections.isEmpty { return sections }
        }
        return ResortDirectory.sections(
            mapped, query: query, here: lastFix?.coordinate, recent: recentResorts, sort: sort
        )
    }

    /// The badges the run history and the meets reached have earned
    /// (`Badges`), worked out each time; only which were announced is kept
    /// (`BadgeMoments`).
    var earnedBadges: [Badges.Earned] { badgeStandings.filter(\.isEarned) }

    /// Every badge with where the skier stands on it.
    var badgeStandings: [Badges.Earned] {
        let facts = Dictionary(
            catalog.resorts.map { ($0.name, Badges.ResortFacts(country: $0.country, passes: $0.passProducts)) },
            uniquingKeysWith: { first, _ in first })
        let meets = profile.flatMap { me in
            meetHistory.map {
                Badges.reached($0, me: me.id, zones: Dictionary(
                    catalog.resorts.map { ($0.id, $0.timezone) }, uniquingKeysWith: { first, _ in first }))
            }
        }
        return Badges.standings(
            activity.history, meets: meets, facts: facts, levelIsBacked: activity.history.backedAbility != nil,
            isBeta: DeveloperAccess.launchChannel != .appStore)
    }

    /// The units the badges' rules and counts are read in: Settings →
    /// Appearance → Units, read through the theme so a change redraws them.
    var badgeUnits: Badge.Units {
        let choice = ThemeManager.shared.units
        return Badge.Units(metricLengths: choice.isMetric, metricSpeed: choice.isMetricSpeed)
    }

    /// How far a resort is from this phone, when both positions are known.
    func distanceM(to resort: PublishedResort) -> Double? {
        ResortDirectory.distanceM(to: resort, from: lastFix?.coordinate)
    }

    /// Settings → Appearance → Map. The open map repaints from the new value;
    /// the maps on the phone are asked for again, as Satellite needs the
    /// photo's tiles and the drawn looks do not.
    func selectMapLook(_ look: MapLook) {
        ThemeManager.shared.selectMapLook(look)
        syncMaps()
    }

    func selectRunOverlay(_ overlay: RunOverlay) {
        ThemeManager.shared.selectRunOverlay(overlay)
        if overlay == .skied { syncSkiedRuns() }
    }

    /// The open mountain's runs by how often this skier has skied them, from
    /// the activity history: runs are matched by name within the resort.
    func syncSkiedRuns() {
        guard let resort, let name = selectedResort?.name else { return }
        resort.skiedRuns = MountainCompletion.skiedRuns(activity.history, resortName: name)
    }

    /// The open mountain's named runs skied out of its total, for the
    /// profile; nil with no map open or a map with no named runs. Read from
    /// the history directly rather than `ResortModel.skiedRuns`, which is
    /// only filled while Run Completion colours the map.
    var mountainCompletion: MountainCompletion.Count? {
        guard let bundle = resort?.bundle, let name = selectedResort?.name else { return nil }
        let count = MountainCompletion.count(bundle, history: activity.history, resortName: name)
        return count.total > 0 ? count : nil
    }

    // MARK: Resort intents

    /// Asks the server for the catalog. With no answer the last one saved on
    /// the phone stands in, so the maps kept on it can still be opened.
    func loadCatalog() {
        catalog.isLoading = true
        catalog.failure = nil
        run("catalog") { [weak self, deps] in
            let bundles = deps.bundles
            do {
                let resorts = try await deps.backend.resortCatalog()
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self?.catalog = CatalogState(resorts: resorts)
                self?.considerArrival()
                self?.announceNewBadges()
                self?.syncMaps()
                await Task.detached { bundles.save(catalog: resorts) }.value
            } catch {
                guard !Task.isCancelled, let self else { return }
                let failure = PowderMeetError(error)
                if catalog.resorts.isEmpty || catalog.isSaved,
                   let saved = await Task.detached(operation: { bundles.catalog() }).value, !saved.isEmpty
                {
                    catalog = CatalogState(resorts: saved, isSaved: true)
                    considerArrival()
                    announceNewBadges()
                    syncMaps()
                } else {
                    catalog.isLoading = false
                    catalog.failure = failure
                }
            }
        }
    }

    /// Only a resort with a published map can be opened; the picker shows the
    /// rest as not available yet.
    func selectResort(_ id: String) {
        guard catalog.resorts.first(where: { $0.id == id })?.hasMap != false else { return }
        pickedResortThisSession = true
        session.send(.resortSelected(id))
        if floatingPicker == .resortPicker { closeFloating() }
    }

    /// The resort opened goes to the top of the recent ones, whose maps the
    /// phone keeps; the one that falls off is cleared.
    func noteRecentResort(_ id: String) {
        recentResorts = ResortDirectory.noting(id, in: recentResorts)
        UserDefaults.standard.set(recentResorts, forKey: recentResortsKey)
        mapShelf.opened(id)
        saveMapShelf()
        syncMaps()
    }

    func clearResort() {
        pickedResortThisSession = true
        session.send(.resortCleared)
    }

    /// "Go to" on a run, lift or place card: a solo route there from this
    /// phone, on the user's own routing profile (no learned pace: the baseline
    /// is close enough for one route, and fetching it would delay the card).
    func goTo(_ destination: GoToDestination) {
        resort?.startGoTo(destination, profile: profile.map { SkierProfile($0) })
    }
}

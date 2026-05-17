//
//  ContentCoordinator+Conditions.swift
//  PowderMeet
//
//  Conditions (current + historical) pipeline extracted from
//  ContentCoordinator. Two cancellable tasks: `conditionsTask` for the
//  live "now" + 96h hourly merge, `historicalTask` for archive backfill
//  on long scrubs. Both write into `resortConditions`, which the rest
//  of the app reads as the source of truth for weather state.
//
//  Behaviour-equivalent to the inline implementation; this file is a
//  pure move so the orchestration concerns (resort change pipeline,
//  meetup, ghosts, navigation) read against a smaller central file.
//

import Foundation

extension ContentCoordinator {

    /// Cancellable conditions pipeline. `currentConditions` fires
    /// immediately (it's the fast path — ~200ms, drives the live weather
    /// overlay). The hourly backfill is deferred 500ms — on rapid
    /// resort-hop, the new `loadConditions` call cancels the task, so the
    /// previous hourly never hits the network. The hourly payload itself
    /// is already the minimum Open-Meteo can serve (3 past + 1 forecast
    /// days = 96 hours).
    func loadConditions(for entry: ResortEntry) {
        conditionsTask?.cancel()
        conditionsTask = Task { [weak self] in
            guard let current = await ConditionsService.shared.currentConditions(for: entry) else { return }
            guard !Task.isCancelled else { return }
            self?.resortConditions = current

            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }

            if let merged = await ConditionsService.shared.mergeHourly(for: entry) {
                guard !Task.isCancelled else { return }
                self?.resortConditions = merged
            }
        }
    }

    /// Kick off a historical archive fetch if the scrubbed time is
    /// outside the live hourly forecast window (`past_days=3`). Results
    /// are merged into `resortConditions.hourlyHistory` which `atTime`
    /// already consults, so the scrubber HUD picks up archive data
    /// automatically.
    func maybeLoadHistoricalConditions(for scrub: Date) {
        guard let entry = selectedEntry else { return }
        let ageSeconds = Date().timeIntervalSince(scrub)
        // Only fetch for times clearly outside the live 3-day window.
        // (Inside the window, `hourlyForecast` already has it.)
        guard ageSeconds > 2 * 24 * 3600 else { return }

        historicalTask?.cancel()
        historicalTask = Task { [weak self] in
            // 400 ms debounce — rapid scrubbing shouldn't each fire a fetch.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }

            // Pad the window ±7 days so nearby scrubs don't each need a
            // new fetch. Archive responses are cached per-window in the
            // service (FIFO 48-entry LRU).
            let start = scrub.addingTimeInterval(-7 * 24 * 3600)
            let end   = scrub.addingTimeInterval( 1 * 24 * 3600)
            let samples = await ConditionsService.shared.historicalConditions(
                entry: entry, startDate: start, endDate: end
            )
            guard !Task.isCancelled else { return }
            guard !samples.isEmpty else { return }
            guard var conditions = self.resortConditions else { return }
            conditions.hourlyHistory = samples
            self.resortConditions = conditions
        }
    }
}

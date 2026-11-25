import Foundation
import MountainCore

/// A weather term the solver charges on a run that steered a route off the way
/// it would have taken in plain weather. Typed so the app owns the wording, like
/// `Reason`. Declared in the order a tie is settled.
public enum WeatherFavour: Hashable, Sendable, CaseIterable {
    /// A cold day: the route keeps to slopes in the sun, off hard shaded snow.
    case sunnySide
    /// A warm day: the route keeps to slopes in the shade, out of the slush.
    case shadySide
    /// The route keeps off runs exposed to the wind.
    case outOfTheWind
    /// The route keeps out of low cloud and poor visibility.
    case clearerView
}

/// Why a route was chosen, in weather terms, read off the costs the solver
/// already charges (06-SOLVER section 3). It never changes a route or a cost.
enum WeatherFavours {
    /// Sets `weatherFavours` on one skier's routes from a single search with
    /// those terms switched off: its fastest way to each route's stop is the
    /// plain-weather way (one label per node keeps the fastest). Switching terms
    /// off only speeds runs up, so that way arrives no later than the route
    /// itself and nothing after the latest route's arrival is searched.
    static func annotate(
        _ routes: inout [Route], origin: ResolvedOrigin, model: CostModel
    ) {
        guard model.hasConditions else { return }
        let graph = model.graph
        let wanted = routes.indices.filter { routes[$0].easiestWayDown == nil && !routes[$0].legs.isEmpty }
        let targets = wanted.compactMap { routes[$0].legs.last.flatMap { graph.edge($0.edgeID)?.to } }
        guard !wanted.isEmpty, targets.count == wanted.count,
              let latest = wanted.map({ routes[$0].eta.meanS }).max() else { return }
        let plain = Search.run(
            from: origin, model: model.charging([]), maxLabels: 1, deadlineS: latest + 1
        )
        for (index, target) in zip(wanted, targets) {
            guard let label = plain.best(at: target) else { continue }
            let chosen = routes[index].legs.compactMap { graph.edge($0.edgeID) }
            routes[index].weatherFavours = favours(
                chosen: chosen, plain: plain.path(to: label, graph: graph), origin: origin, model: model
            )
        }
    }

    /// The terms that favoured `chosen` over `plain`, most material first: the
    /// plain way is slower in the real weather and loses at least
    /// `Scoring.weatherFavourMinimumS` more to the term than the chosen one.
    static func favours(
        chosen: [Edge], plain: [Edge], origin: ResolvedOrigin, model: CostModel
    ) -> [WeatherFavour] {
        guard chosen.map(\.id) != plain.map(\.id),
              let picked = price(chosen, origin: origin, model: model),
              let other = price(plain, origin: origin, model: model),
              other.totalS > picked.totalS else { return [] }
        let gains = WeatherFavour.allCases.enumerated().compactMap { offset, term in
            let gain = other.byTerm[offset] - picked.byTerm[offset]
            return gain >= Scoring.weatherFavourMinimumS ? (term: term, gain: gain, order: offset) : nil
        }
        return gains.sorted { $0.gain != $1.gain ? $0.gain > $1.gain : $0.order < $1.order }.map(\.term)
    }

    /// A path's time under `model` from the solve instant, and what each term
    /// (in `WeatherFavour.allCases` order) added to it; nil when the path cannot
    /// be taken.
    static func price(
        _ path: [Edge], origin: ResolvedOrigin, model: CostModel
    ) -> (totalS: Double, byTerm: [Double])? {
        let without = WeatherFavour.allCases.map { model.charging(model.weatherTerms.subtracting([$0])) }
        var byTerm = [Double](repeating: 0, count: without.count)
        var elapsed = 0.0
        var previous: Edge?
        for (index, edge) in path.enumerated() {
            let remaining = index == 0 && origin.approachEdge?.id == edge.id ? origin.remainingFraction : 1
            guard let seconds = model.traverseTime(
                edge, elapsedS: elapsed, remainingFraction: remaining, previous: previous
            ) else { return nil }
            if edge.kind == .run {
                for (term, plain) in without.enumerated() {
                    if let free = plain.traverseTime(
                        edge, elapsedS: elapsed, remainingFraction: remaining, previous: previous
                    ) {
                        byTerm[term] += max(0, seconds - free)
                    }
                }
            }
            elapsed += seconds
            previous = edge
        }
        return (elapsed, byTerm)
    }
}

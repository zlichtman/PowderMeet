import Foundation
import MountainCore

/// A bounded preference for routes that are easier to follow. It never changes a
/// physical ETA or an edge's eligibility.
enum RouteSimplicity {
    /// One user-visible action. Group identity keeps a trail split into several
    /// edges from looking like several decisions.
    static func actionIdentity(for edge: Edge) -> String {
        let kind = edge.kind.rawValue
        if let group = edge.group, !group.rawValue.isEmpty { return "\(kind):group:\(group)" }
        if let name = edge.name {
            let normalized = name.lowercased()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !normalized.isEmpty { return "\(kind):name:\(normalized)" }
        }
        return "\(kind):edge:\(edge.id.stored)"
    }

    static func penaltyS(forTransitionCount count: Int) -> Double {
        min(Scoring.routeSimplicityMaximumPenaltyS,
            Double(max(0, count)) * Scoring.routeActionTransitionPenaltyS)
    }
}

/// Time variance along a route. Adjacent edges of one physical trail or lift are
/// one correlated block; separate actions combine independently.
struct RouteTimeUncertainty: Hashable, Sendable {
    private(set) var varianceTime: Double
    private(set) var currentActionStdS: Double = 0
    private(set) var lastActionIdentity: String?
    private var lastTargetID: NodeID?

    init(initialVariance: Double = 0) { varianceTime = initialVariance }

    mutating func append(edge: Edge, variance: Double) {
        let identity = RouteSimplicity.actionIdentity(for: edge)
        let continues = lastActionIdentity == identity && lastTargetID == edge.from
        let priorStd = continues ? currentActionStdS : 0
        let edgeStd = variance.squareRoot()
        // (prior + edge)² − prior², written without subtracting near-equal values.
        varianceTime += variance + 2 * priorStd * edgeStd
        currentActionStdS = priorStd + edgeStd
        lastActionIdentity = identity
        lastTargetID = edge.to
    }
}

/// Whether `next` continues a ride the skier already boarded: consecutive split
/// segments of the same source way in the same direction. Names and groups are
/// not proof that two lift edges are one ride.
enum LiftRideContinuation {
    static func isContinuation(from previous: Edge?, to next: Edge) -> Bool {
        guard let previous, previous.kind == .lift, next.kind == .lift, previous.to == next.from,
              previous.id.isReverse == next.id.isReverse,
              let before = previous.id.waySegment, let after = next.id.waySegment,
              before.way == after.way else { return false }
        return next.id.isReverse
            ? after.ordinal == before.ordinal - 1
            : after.ordinal == before.ordinal + 1
    }
}

struct BinaryHeap<Element> {
    private var storage: [Element] = []
    private let precedes: (Element, Element) -> Bool

    init(precedes: @escaping (Element, Element) -> Bool) { self.precedes = precedes }

    mutating func insert(_ element: Element) {
        storage.append(element)
        var i = storage.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard precedes(storage[i], storage[parent]) else { break }
            storage.swapAt(i, parent)
            i = parent
        }
    }

    mutating func extractMin() -> Element? {
        guard !storage.isEmpty else { return nil }
        if storage.count == 1 { return storage.removeLast() }
        let minimum = storage[0]
        storage[0] = storage.removeLast()
        var i = 0
        while true {
            let left = 2 * i + 1, right = 2 * i + 2
            var smallest = i
            if left < storage.count, precedes(storage[left], storage[smallest]) { smallest = left }
            if right < storage.count, precedes(storage[right], storage[smallest]) { smallest = right }
            if smallest == i { break }
            storage.swapAt(i, smallest)
            i = smallest
        }
        return minimum
    }
}

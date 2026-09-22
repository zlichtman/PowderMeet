//
//  RouteTimeUncertainty.swift
//  PowderMeet
//
//  A storage fragment is not an independent pace observation. Treat adjacent
//  fragments of one physical trail/lift as a correlated block, then combine
//  separate actions independently. This is a conservative covariance model,
//  not a claim that empirical cross-edge correlations have been measured.
//

import Foundation

nonisolated struct RouteTimeUncertainty {
    private(set) var varianceTime: Double
    private(set) var currentActionStdSeconds: Double = 0
    private(set) var lastActionIdentity: String?
    private var lastTargetID: String?

    init(initialVariance: Double = 0) {
        varianceTime = initialVariance
    }

    mutating func append(edge: GraphEdge, variance: Double) {
        let identity = RouteSimplicity.actionIdentity(for: edge)
        let continuesAction = lastActionIdentity == identity
            && lastTargetID == edge.sourceID
        let priorStd = continuesAction ? currentActionStdSeconds : 0
        let edgeStd = variance.squareRoot()
        // (priorStd + edgeStd)^2 - priorStd^2 adds the covariance
        // without subtracting two nearly equal accumulated variances.
        varianceTime += variance + 2 * priorStd * edgeStd
        currentActionStdSeconds = priorStd + edgeStd
        lastActionIdentity = identity
        lastTargetID = edge.targetID
    }
}

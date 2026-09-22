//
//  FriendChipLayoutEngine.swift
//  PowderMeet
//
//  Pure layout math for edge-docked off-viewport friend indicators. Takes a
//  viewport rect, the friend's projected screen point, and the camera
//  bearing, and returns where to dock the chip on the viewport boundary
//  plus the arrow angle. No SwiftUI / Mapbox imports so the math is unit-
//  testable in isolation.
//

import CoreGraphics
import Foundation

struct FriendChipPlacement: Equatable {
    let screenPoint: CGPoint      // where the chip docks (inside the inset rect)
    let arrowAngleRadians: Double // rotation for the directional arrow
    let straightLineMeters: Double
}

enum FriendChipLayoutEngine {

    /// Returns nil when the friend is visible inside the inset rect.
    /// Otherwise clips the line from the viewport centre to the friend's
    /// projected point against the inset rect (Liang–Barsky) and docks the
    /// chip at that intersection.
    static func place(
        viewport: CGRect,
        inset: CGFloat,
        friendScreenPoint: CGPoint,
        straightLineMeters: Double
    ) -> FriendChipPlacement? {
        let rect = viewport.insetBy(dx: inset, dy: inset)
        if rect.contains(friendScreenPoint) { return nil }

        let centre = CGPoint(x: viewport.midX, y: viewport.midY)
        let dx = friendScreenPoint.x - centre.x
        let dy = friendScreenPoint.y - centre.y
        guard dx != 0 || dy != 0 else { return nil }

        // Liang–Barsky parametric clip: line P(t) = centre + t·(dx, dy).
        // Find largest t in [0, ∞) where P(t) is still inside the rect.
        var tMax: CGFloat = .infinity
        func update(p: CGFloat, q: CGFloat) {
            if p == 0 { return }
            let t = q / p
            if p > 0, t < tMax { tMax = t }
        }
        update(p: -dx, q: -(rect.minX - centre.x)) // left edge, for p<0 we enter; we want exit so flip
        update(p:  dx, q:  rect.maxX - centre.x)
        update(p: -dy, q: -(rect.minY - centre.y))
        update(p:  dy, q:  rect.maxY - centre.y)
        if !tMax.isFinite || tMax <= 0 { return nil }

        let docked = CGPoint(
            x: centre.x + dx * tMax,
            y: centre.y + dy * tMax
        )
        // UIKit y grows downward; atan2(dy, dx) already works in that space
        // because the arrow rotation is applied in the same coordinate system.
        let angle = atan2(Double(dy), Double(dx))
        return FriendChipPlacement(
            screenPoint: docked,
            arrowAngleRadians: angle,
            straightLineMeters: straightLineMeters
        )
    }

    /// Great-circle initial bearing from `from` to `to` (radians, 0 = east,
    /// counter-clockwise to match atan2 — callers that want compass bearing
    /// should convert). Resort-scale distances (<10 km) make flat projection
    /// almost as accurate, but the spherical formula is only a few extra
    /// trig ops and is correct under all viewport bearings.
    static func bearingRadians(
        fromLat lat1: Double, fromLon lon1: Double,
        toLat lat2: Double, toLon lon2: Double
    ) -> Double {
        let φ1 = lat1 * .pi / 180
        let φ2 = lat2 * .pi / 180
        let Δλ = (lon2 - lon1) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return atan2(y, x)
    }
}

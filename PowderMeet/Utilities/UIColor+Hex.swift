//
//  UIColor+Hex.swift
//  PowderMeet
//
//  Convenience initializer for `UIColor` from a hex string. Used by the
//  Mapbox layer config to read brand-color hex codes out of style JSON.
//  Lifted out of MountainMapView so that file is no longer the only
//  place this lives — anyone wiring up a UIColor by hex shouldn't need
//  to import the map file.
//

import UIKit

extension UIColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let r, g, b: CGFloat
        switch hex.count {
        case 6:
            r = CGFloat((int >> 16) & 0xFF) / 255
            g = CGFloat((int >> 8) & 0xFF) / 255
            b = CGFloat(int & 0xFF) / 255
        default:
            r = 1
            g = 1
            b = 1
        }

        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

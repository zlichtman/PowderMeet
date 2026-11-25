//
//  AppIcon.swift
//  PowderMeet
//
//  The Home Screen icon, chosen separately from the in-app theme: the
//  PowderMeet icon (the primary `AppIcon`); the two-tones Powder,
//  Carbon and Whiteout, Retro Flame and Retro Ice, and the five Auroras (each in
//  its dark art, like PowderMeet); and Alpenglow, which
//  `apps/ios/Tools/make_app_icons.py` paints from the PowderMeet mark. Each alternate is an `AppIcon-<Name>`
//  icon set, with the picker's 108 px `IconThumb-<Name>` that the icon maker
//  writes from the same art.
//

import UIKit

enum AppIcon: String, CaseIterable, Identifiable, Sendable {
    // Grouped: PowderMeet; the three two-tones; the two
    // Retros; the Auroras, Alpenglow among them as Aurora Glow.
    case original
    case powder, carbon, whiteout
    case retro, retroIce
    case aurora, auroraDawn, auroraEmber, alpenglow, auroraIce, auroraRose

    var id: String { rawValue }

    /// What the picker shows.
    var title: String {
        switch self {
        case .original: "PowderMeet"
        case .powder: "Powder"
        case .carbon: "Carbon"
        case .whiteout: "Whiteout"
        case .retro: "Retro Flame"
        case .retroIce: "Retro Ice"
        case .aurora: "Aurora Night"
        case .auroraDawn: "Aurora Dawn"
        case .auroraEmber: "Aurora Ember"
        case .alpenglow: "Aurora Glow"
        case .auroraIce: "Aurora Ice"
        case .auroraRose: "Aurora Rose"
        }
    }

    /// "Alpenglow" for `alpenglow`: the suffix the asset names use.
    private var assetSuffix: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// The icon set's name; nil is the primary icon.
    var alternateIconName: String? { self == .original ? nil : "AppIcon-\(assetSuffix)" }

    /// The icon at the picker's size: `IconThumb-<Name>`, which the icon
    /// maker writes in the same run, from the same art. (An alternate icon
    /// set compiles to an app icon only, with no file that `UIImage(named:)`
    /// loads.)
    var image: UIImage? { UIImage(named: "IconThumb-\(assetSuffix)") }
}

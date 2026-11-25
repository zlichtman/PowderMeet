//
//  ThemeManager.swift
//  PowderMeet
//
//  Holds the selected in-app theme and, separately, the Home Screen
//  icon. `HUDTheme` reads `theme`, so every view that reads a HUD colour
//  in its body re-renders on a theme change through Observation.
//

import MapScene
import MapboxAdapter
import SwiftUI
import UIKit

@MainActor
@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    // MARK: - Theme

    /// The theme the app is drawn in.
    private(set) var theme: AppTheme = .classic
    private(set) var customThemes: [CustomAppTheme] = []
    /// Set while the selected theme is one of `customThemes`.
    private(set) var selectedCustomID: UUID?

    var displayName: String { theme.name }

    func select(_ theme: AppTheme) {
        selectedCustomID = nil
        apply(theme)
    }

    func selectCustom(_ custom: CustomAppTheme) {
        guard customThemes.contains(where: { $0.id == custom.id }), let theme = custom.appTheme else { return }
        selectedCustomID = custom.id
        apply(theme)
    }

    func saveCustom(_ custom: CustomAppTheme) {
        guard custom.isValid, custom.appTheme != nil else { return }
        if let index = customThemes.firstIndex(where: { $0.id == custom.id }) {
            customThemes[index] = custom
        } else {
            customThemes.append(custom)
        }
        persistCustomThemes()
        selectCustom(custom)
    }

    /// Back to Classic, the PowderMeet icon and the device's units. Called on
    /// account deletion, so the next account on this device starts clean.
    func resetToDefault() {
        select(.classic)
        customThemes = []
        persistCustomThemes()
        selectIcon(.original)
        selectUnits(.device)
        selectMapLook(.satellite)
        setSkiGlow(on: true)
        setSkiGlowSource(.ski)
    }

    // MARK: - Units

    /// Settings → Appearance → Units. `HUDTheme` reads this beside `theme`, so
    /// every view that draws a HUD colour, which is every view that shows a
    /// number, redraws in the new units.
    private(set) var units: UnitChoice = UnitChoice.current

    func selectUnits(_ choice: UnitChoice) {
        UserDefaults.standard.set(choice.rawValue, forKey: UnitChoice.key)
        units = choice
    }

    // MARK: - Map look

    /// Settings → Appearance → Map: Satellite by default (owner, 21 Nov evening); the
    /// drawn looks are there to switch to.
    private(set) var mapLook: MapLook = UserDefaults.standard.string(forKey: Key.mapLook)
        .flatMap(MapLook.init(rawValue:)) ?? .satellite

    func selectMapLook(_ look: MapLook) {
        UserDefaults.standard.set(look.rawValue, forKey: Key.mapLook)
        mapLook = look
    }

    /// The lettering of the skier's own name on their profile (Settings →
    /// Account). Kept on this phone: friends see the name in the app's own.
    private(set) var nameFont: NameFont = UserDefaults.standard.string(forKey: Key.nameFont)
        .flatMap(NameFont.init(rawValue:)) ?? .standard

    func selectNameFont(_ font: NameFont) {
        UserDefaults.standard.set(font.rawValue, forKey: Key.nameFont)
        nameFont = font
    }

    /// What the runs' colours say on the map: their rating unless the skier
    /// picks another reading in the map style list.
    private(set) var runOverlay: RunOverlay = UserDefaults.standard.string(forKey: Key.runOverlay)
        .flatMap(RunOverlay.init(rawValue:)) ?? .difficulty

    func selectRunOverlay(_ overlay: RunOverlay) {
        UserDefaults.standard.set(overlay.rawValue, forKey: Key.runOverlay)
        runOverlay = overlay
    }

    /// What the map draws: the look, the theme's accent for the PowderMeet
    /// look, and what the runs' colours say.
    var mapAppearance: MapAppearance {
        MapAppearance(look: mapLook, accent: theme.mapAccent, overlay: runOverlay)
    }


    // MARK: - Icon

    private(set) var selectedIcon: AppIcon = .original
    private(set) var isChangingIcon = false
    var iconError: String?

    func selectIcon(_ icon: AppIcon) {
        guard !isChangingIcon else { return }
        let app = UIApplication.shared
        guard app.supportsAlternateIcons else {
            iconError = "This device doesn't support alternate app icons."
            return
        }
        if app.alternateIconName == icon.alternateIconName { return }
        isChangingIcon = true
        app.setAlternateIconName(icon.alternateIconName) { error in
            Task { @MainActor in
                self.isChangingIcon = false
                self.iconError = error?.localizedDescription
                if error == nil { self.selectedIcon = icon }
            }
        }
    }

    // MARK: - Ski glow

    /// What the glow takes its colour from: the chosen ski or the app's theme.
    nonisolated enum SkiGlowSource: String, Sendable, Hashable {
        case ski, theme
    }

    /// The red of the PowderMeet ski, the glow of gear with no catalog ski.
    static let houseSkiAccentHex = "D92B2B"

    /// The ski picker's glow: the light behind the skis on a profile card and
    /// on Gear. On by default, in the chosen ski's own colour
    /// (`SkiModel.accentHex`; the PowderMeet ski's red for custom gear) or
    /// the theme's accent, whichever of the two the skier picked.
    private(set) var skiGlowOn = UserDefaults.standard.object(forKey: Key.skiGlowOn) as? Bool ?? true
    private(set) var skiGlowSource = UserDefaults.standard.string(forKey: Key.skiGlowSource)
        .flatMap(SkiGlowSource.init(rawValue:)) ?? .ski

    func setSkiGlowSource(_ source: SkiGlowSource) {
        UserDefaults.standard.set(source.rawValue, forKey: Key.skiGlowSource)
        skiGlowSource = source
    }

    /// The chosen ski's accent, as the picker last saw it; nil for custom gear.
    private(set) var skiAccentHex = UserDefaults.standard.string(forKey: Key.skiAccent)

    func setSkiGlow(on: Bool) {
        UserDefaults.standard.set(on, forKey: Key.skiGlowOn)
        skiGlowOn = on
    }

    /// A ski chosen (or the picker opened on one): the glow's colour.
    func noteSkiAccent(_ hex: String?) {
        guard hex != skiAccentHex else { return }
        UserDefaults.standard.set(hex, forKey: Key.skiAccent)
        skiAccentHex = hex
    }

    /// The glow drawn: the ski's own colour, or the theme's accent.
    var skiGlowColor: Color {
        switch skiGlowSource {
        case .ski: Color(hex: skiAccentHex ?? Self.houseSkiAccentHex)
        case .theme: HUDTheme.accent
        }
    }

    // MARK: - Storage

    private enum Key {
        static let skiGlowOn = "powdermeet.skis.glowOn"
        static let skiGlowSource = "powdermeet.skis.glowSource"
        static let skiAccent = "powdermeet.skis.accent"
        static let mapLook = "powdermeet.map.look"
        static let runOverlay = "powdermeet.map.runOverlay"
        static let nameFont = "powdermeet.profile.nameFont"
        /// The selected theme's `ThemeSeed` as JSON, so launch reads no library.
        static let selection = "powdermeet.theme.selection"
        static let customThemes = "powdermeet.theme.customPalettes"
        static let customSelection = "powdermeet.theme.customSelection"
    }

    private init() {
        let defaults = UserDefaults.standard
        selectedIcon = AppIcon.allCases.first {
            $0.alternateIconName == UIApplication.shared.alternateIconName
        } ?? .original

        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: Key.customThemes) {
            do {
                customThemes = try decoder.decode([CustomAppTheme].self, from: data)
                    .filter { $0.isValid && $0.appTheme != nil }
            } catch {
                customThemes = []
            }
        }
        if let id = defaults.string(forKey: Key.customSelection).flatMap(UUID.init(uuidString:)),
           let custom = customThemes.first(where: { $0.id == id }), let theme = custom.appTheme {
            selectedCustomID = id
            self.theme = theme
        } else if let data = defaults.data(forKey: Key.selection) {
            do {
                theme = Self.theme(for: try decoder.decode(ThemeSeed.self, from: data))
            } catch {
                theme = .classic
            }
        }
        #if DEBUG
        // `-debugTheme "Tokyo Night"`: a built-in theme for this launch, so
        // screens can be checked in two themes without tapping.
        // `-debugMapLook satellite`: a map look for this launch, for
        // comparing looks (and their `MapLoadProbe` lines) without tapping.
        if let look = defaults.string(forKey: "debugMapLook").flatMap(MapLook.init(rawValue:)) {
            mapLook = look
        }
        // The bundled palettes too ("Adventure Time"), read only when named.
        if let name = defaults.string(forKey: "debugTheme"),
           let named = (AppTheme.powdermeet + AppTheme.editorial + AppTheme.editor)
            .first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            ?? ((try? ThemeLibrary.load(from: .main)) ?? [:]).values.joined()
            .first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            selectedCustomID = nil
            theme = named
        }
        #endif
    }

    /// The theme a saved seed names. Built-in families are looked up by
    /// name, so a palette we retune applies to people already using it.
    private static func theme(for seed: ThemeSeed) -> AppTheme {
        let builtIn: [AppTheme]
        switch seed.family {
        case .powdermeet: builtIn = AppTheme.powdermeet
        case .editorial: builtIn = AppTheme.editorial
        case .editor: builtIn = AppTheme.editor
        case .ghostty, .base16, .gogh, .custom: builtIn = []
        }
        // Classic was renamed PowderMeet (owner, 20 Nov); a saved Classic is it.
        let name = seed.family == .powdermeet && seed.name == "Classic" ? AppTheme.classic.name : seed.name
        return builtIn.first { $0.name == name } ?? AppTheme(seed: seed) ?? .classic
    }

    private func apply(_ theme: AppTheme) {
        self.theme = theme
        let defaults = UserDefaults.standard
        if let selectedCustomID {
            defaults.set(selectedCustomID.uuidString, forKey: Key.customSelection)
        } else {
            defaults.removeObject(forKey: Key.customSelection)
        }
        do {
            defaults.set(try JSONEncoder().encode(theme.seed), forKey: Key.selection)
        } catch {
            // The theme still applies; it just won't be remembered.
        }
    }

    private func persistCustomThemes() {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(customThemes), forKey: Key.customThemes)
        } catch {
            iconError = "Your custom theme couldn't be saved."
        }
    }
}

extension AppTheme {
    /// The accent as the map takes it (Holographic's relief and contours).
    var mapAccent: MapRGB { MapRGB(accent.r, accent.g, accent.b) }
}

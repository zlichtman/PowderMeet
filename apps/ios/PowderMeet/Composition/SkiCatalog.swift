import Foundation
import MeetSolver
import UIKit

/// The skis a skier can pick by name. The catalog only fills in the routing
/// fields (type and waist width) and names a topsheet image, so it needs no
/// server. Each key's image set has the same name in
/// `Resources/SkisTopsheets.xcassets`, the brands' artwork, kept in its own
/// catalog so it can come out in one step: `SkiCatalog.usesBrandArtwork` off,
/// or that folder deleted. Every model stays on offer either way; one without
/// its image is drawn by the app (`DrawnTopsheet`), never as a blank ski. New
/// skis are fetched by `apps/ios/Tools/fetch_topsheets.py`, which records each
/// one's page and image URL in `topsheet_sources.tsv`. A key is stored in
/// profiles: never rename one; a ski dropped here draws as the PowderMeet ski.
/// Length is the skier's own number because it varies within a model.
nonisolated struct SkiModel: Hashable, Sendable, Identifiable {
    /// `equipment.ski`, and the name of the topsheet image set.
    let key: String
    let brand: String
    let model: String
    let category: SkiCategory
    let waistMM: Int
    /// The topsheet's dominant saturated colour, measured when the image was
    /// imported. Nil for a topsheet that is mostly black, white or grey.
    var accentHex: String?

    var id: String { key }
    var displayName: String { "\(brand) \(model)" }
    var detail: String { "\(category.label) · \(waistMM) mm" }
}

nonisolated enum SkiCategory: Sendable {
    case allMountain, powder, park, race, touring

    var label: String {
        switch self {
        case .allMountain: "All-mountain"
        case .powder: "Powder"
        case .park: "Park"
        case .race: "Race"
        case .touring: "Touring"
        }
    }

    /// The routing type a catalog category stands for.
    var equipmentType: EquipmentType {
        switch self {
        case .allMountain, .touring: .allMountain
        case .powder: .freeride
        case .park: .park
        case .race: .carving
        }
    }
}

/// `equipment.skin`, as older rows stored it. The skin is not a choice: a
/// catalog ski shows its own topsheet and custom gear the PowderMeet ski, so a
/// stored skin is read and ignored, and never written.
nonisolated enum SkiSkin: String, CaseIterable, Sendable {
    case house
}

/// What a ski is drawn as.
nonisolated enum SkiLook: Hashable, Sendable {
    /// The PowderMeet ski: custom gear, or a ski this build's catalog lacks.
    case house
    /// A catalog ski: its brand's topsheet image, or the drawn topsheet when
    /// the image is switched off or missing.
    case topsheet(String)

    /// `skin` is accepted for older rows and ignored.
    init(skiKey: String?, skin: SkiSkin? = nil) {
        self = skiKey.flatMap(SkiCatalog.model(key:)).map { .topsheet($0.key) } ?? .house
    }
}

nonisolated enum SkiCatalog {
    static func model(key: String) -> SkiModel? { byKey[key] }

    /// Brands in name order, each with its models narrowest first.
    static let brands: [(brand: String, models: [SkiModel])] = {
        var order: [String] = []
        var groups: [String: [SkiModel]] = [:]
        for model in models {
            if groups[model.brand] == nil { order.append(model.brand) }
            groups[model.brand, default: []].append(model)
        }
        return order.map { (brand: $0, models: groups[$0] ?? []) }
    }()

    private static let byKey = Dictionary(models.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

    /// The one switch for the brands' artwork. On, a model whose image is in
    /// the bundle shows it; off, every model is drawn by the app, for a build
    /// without the brands' permission. Deleting `SkisTopsheets.xcassets` has
    /// the same effect and also takes the images out of the app.
    static let usesBrandArtwork = true

    /// Whether `key`'s brand image is drawn.
    static func hasArtwork(key: String) -> Bool { artworkKeys.contains(key) }

    /// Looked up once, so drawing a ski never searches the bundle.
    private static let artworkKeys: Set<String> = usesBrandArtwork
        ? Set(models.map(\.key).filter { UIImage(named: $0) != nil })
        : []

    static let models: [SkiModel] = [
        SkiModel(key: "four-frnt-msp-99", brand: "4FRNT", model: "MSP 99", category: .allMountain, waistMM: 99),
        SkiModel(key: "armada-arv-88", brand: "Armada", model: "ARV 88", category: .allMountain, waistMM: 88, accentHex: "D85C8C"),
        SkiModel(key: "armada-arv-94", brand: "Armada", model: "ARV 94", category: .park, waistMM: 94, accentHex: "7163B5"),
        SkiModel(key: "armada-arv-100", brand: "Armada", model: "ARV 100", category: .park, waistMM: 100),
        SkiModel(key: "armada-antimatter-100", brand: "Armada", model: "Antimatter 100", category: .allMountain, waistMM: 100),
        SkiModel(key: "armada-declivity-102-ti", brand: "Armada", model: "Declivity 102 Ti", category: .allMountain, waistMM: 102),
        SkiModel(key: "armada-locator-104", brand: "Armada", model: "Locator 104", category: .allMountain, waistMM: 104),
        SkiModel(key: "armada-arv-106-ti", brand: "Armada", model: "ARV 106 Ti", category: .park, waistMM: 106),
        SkiModel(key: "armada-antimatter-108", brand: "Armada", model: "Antimatter 108", category: .powder, waistMM: 108, accentHex: "D01F26"),
        SkiModel(key: "armada-arv-112", brand: "Armada", model: "ARV 112", category: .powder, waistMM: 112),
        SkiModel(key: "armada-arv-116-jj", brand: "Armada", model: "ARV 116 JJ", category: .powder, waistMM: 116, accentHex: "CA5C82"),
        SkiModel(key: "armada-whitewalker-116", brand: "Armada", model: "Whitewalker 116", category: .powder, waistMM: 116, accentHex: "AC3037"),
        SkiModel(key: "atomic-redster-g9-rvsk-s", brand: "Atomic", model: "Redster G9 RVSK S", category: .race, waistMM: 68, accentHex: "DC382B"),
        SkiModel(key: "atomic-bent-85", brand: "Atomic", model: "Bent 85", category: .allMountain, waistMM: 85, accentHex: "CD3F29"),
        SkiModel(key: "atomic-maverick-88-ti", brand: "Atomic", model: "Maverick 88 Ti", category: .allMountain, waistMM: 88),
        SkiModel(key: "atomic-bent-90", brand: "Atomic", model: "Bent 90", category: .allMountain, waistMM: 90, accentHex: "4C91B9"),
        SkiModel(key: "atomic-maverick-95-ti", brand: "Atomic", model: "Maverick 95 Ti", category: .allMountain, waistMM: 95, accentHex: "295F7A"),
        SkiModel(key: "atomic-bent-100", brand: "Atomic", model: "Bent 100", category: .allMountain, waistMM: 100, accentHex: "A15D4D"),
        SkiModel(key: "atomic-maverick-100-ti", brand: "Atomic", model: "Maverick 100 Ti", category: .allMountain, waistMM: 100),
        SkiModel(key: "atomic-bent-110", brand: "Atomic", model: "Bent 110", category: .powder, waistMM: 110, accentHex: "198DC9"),
        SkiModel(key: "atomic-bent-120", brand: "Atomic", model: "Bent 120", category: .powder, waistMM: 120, accentHex: "DABC81"),
        SkiModel(key: "black-crows-octo", brand: "Black Crows", model: "Octo", category: .allMountain, waistMM: 84, accentHex: "D8EE0E"),
        SkiModel(key: "black-crows-serpo", brand: "Black Crows", model: "Serpo", category: .allMountain, waistMM: 93, accentHex: "06157D"),
        SkiModel(key: "black-crows-camox", brand: "Black Crows", model: "Camox", category: .allMountain, waistMM: 97, accentHex: "CE0F2B"),
        SkiModel(key: "black-crows-daemon", brand: "Black Crows", model: "Daemon", category: .allMountain, waistMM: 100),
        SkiModel(key: "black-crows-atris", brand: "Black Crows", model: "Atris", category: .powder, waistMM: 108, accentHex: "64D6B5"),
        SkiModel(key: "black-crows-anima", brand: "Black Crows", model: "Anima", category: .powder, waistMM: 115, accentHex: "B9C783"),
        SkiModel(key: "black-diamond-helio-carbon-95", brand: "Black Diamond", model: "Helio Carbon 95", category: .touring, waistMM: 95, accentHex: "8E4C44"),
        SkiModel(key: "blizzard-black-pearl-88", brand: "Blizzard", model: "Black Pearl 88", category: .allMountain, waistMM: 88, accentHex: "7D94C1"),
        SkiModel(key: "blizzard-hustle-9", brand: "Blizzard", model: "Hustle 9", category: .allMountain, waistMM: 94, accentHex: "206990"),
        SkiModel(key: "blizzard-rustler-9", brand: "Blizzard", model: "Rustler 9", category: .allMountain, waistMM: 94),
        SkiModel(key: "blizzard-black-pearl-97", brand: "Blizzard", model: "Black Pearl 97", category: .allMountain, waistMM: 97, accentHex: "88393E"),
        SkiModel(key: "blizzard-bonafide-97", brand: "Blizzard", model: "Bonafide 97", category: .allMountain, waistMM: 97),
        SkiModel(key: "blizzard-hustle-10", brand: "Blizzard", model: "Hustle 10", category: .allMountain, waistMM: 102, accentHex: "D8664C"),
        SkiModel(key: "blizzard-rustler-10", brand: "Blizzard", model: "Rustler 10", category: .allMountain, waistMM: 102, accentHex: "14ADD7"),
        SkiModel(key: "dps-pagoda-100-rp", brand: "DPS", model: "Pagoda 100 RP", category: .allMountain, waistMM: 100, accentHex: "F44E00"),
        SkiModel(key: "dps-pagoda-tour-112", brand: "DPS", model: "Pagoda Tour 112", category: .touring, waistMM: 112, accentHex: "0482B4"),
        SkiModel(key: "dps-wailer-a112", brand: "DPS", model: "Wailer A112", category: .powder, waistMM: 112, accentHex: "F6E203"),
        SkiModel(key: "dynastar-m-free-99", brand: "Dynastar", model: "M-Free 99", category: .allMountain, waistMM: 99),
        SkiModel(key: "dynastar-m-pro-99", brand: "Dynastar", model: "M-Pro 99", category: .allMountain, waistMM: 99),
        SkiModel(key: "dynastar-m-free-108", brand: "Dynastar", model: "M-Free 108", category: .powder, waistMM: 108),
        SkiModel(key: "elan-wingman-78-ti", brand: "Elan", model: "Wingman 78 Ti", category: .allMountain, waistMM: 78, accentHex: "D35D43"),
        SkiModel(key: "elan-ripstick-88", brand: "Elan", model: "Ripstick 88", category: .allMountain, waistMM: 88),
        SkiModel(key: "elan-ripstick-96", brand: "Elan", model: "Ripstick 96", category: .allMountain, waistMM: 96),
        SkiModel(key: "elan-ripstick-102", brand: "Elan", model: "Ripstick 102", category: .allMountain, waistMM: 102, accentHex: "AE9266"),
        SkiModel(key: "elan-ripstick-106", brand: "Elan", model: "Ripstick 106", category: .powder, waistMM: 106),
        SkiModel(key: "elan-ripstick-108", brand: "Elan", model: "Ripstick 108", category: .powder, waistMM: 108),
        SkiModel(key: "faction-dancer-89-ti", brand: "Faction", model: "Dancer 89 Ti", category: .allMountain, waistMM: 89),
        SkiModel(key: "faction-dancer-2", brand: "Faction", model: "Dancer 2", category: .allMountain, waistMM: 90, accentHex: "7CB0D2"),
        SkiModel(key: "faction-dancer-3", brand: "Faction", model: "Dancer 3", category: .allMountain, waistMM: 96, accentHex: "F5813D"),
        SkiModel(key: "faction-prodigy-2", brand: "Faction", model: "Prodigy 2", category: .allMountain, waistMM: 96, accentHex: "E27022"),
        SkiModel(key: "faction-dancer-99-ti", brand: "Faction", model: "Dancer 99 Ti", category: .allMountain, waistMM: 99),
        SkiModel(key: "faction-prodigy-3", brand: "Faction", model: "Prodigy 3", category: .allMountain, waistMM: 100, accentHex: "E21E94"),
        SkiModel(key: "faction-dancer-106-ti", brand: "Faction", model: "Dancer 106 Ti", category: .powder, waistMM: 106),
        SkiModel(key: "faction-prodigy-4", brand: "Faction", model: "Prodigy 4", category: .powder, waistMM: 110, accentHex: "E6C717"),
        SkiModel(key: "faction-mana-4", brand: "Faction", model: "Mana 4", category: .powder, waistMM: 112),
        SkiModel(key: "faction-studio-3", brand: "Faction", model: "Studio 3", category: .powder, waistMM: 112),
        SkiModel(key: "fischer-rc4", brand: "Fischer", model: "RC4", category: .race, waistMM: 68, accentHex: "CDE107"),
        SkiModel(key: "fischer-ranger-96", brand: "Fischer", model: "Ranger 96", category: .allMountain, waistMM: 96),
        SkiModel(key: "fischer-ranger-102", brand: "Fischer", model: "Ranger 102", category: .allMountain, waistMM: 102, accentHex: "8863B7"),
        SkiModel(key: "head-supershape-e-magnum", brand: "Head", model: "Supershape e-Magnum", category: .allMountain, waistMM: 76),
        SkiModel(key: "head-kore-87", brand: "Head", model: "Kore 87", category: .allMountain, waistMM: 87),
        SkiModel(key: "head-kore-93", brand: "Head", model: "Kore 93", category: .allMountain, waistMM: 93),
        SkiModel(key: "head-kore-99", brand: "Head", model: "Kore 99", category: .allMountain, waistMM: 99, accentHex: "712D07"),
        SkiModel(key: "head-kore-105", brand: "Head", model: "Kore 105", category: .powder, waistMM: 105, accentHex: "57B9B5"),
        SkiModel(key: "icelantic-riveter-95", brand: "Icelantic", model: "Riveter 95", category: .allMountain, waistMM: 95, accentHex: "6AA7CE"),
        SkiModel(key: "icelantic-pioneer-96", brand: "Icelantic", model: "Pioneer 96", category: .allMountain, waistMM: 96, accentHex: "DC161C"),
        SkiModel(key: "icelantic-mystic-97", brand: "Icelantic", model: "Mystic 97", category: .touring, waistMM: 97),
        SkiModel(key: "icelantic-nomad-100", brand: "Icelantic", model: "Nomad 100", category: .allMountain, waistMM: 100, accentHex: "C26362"),
        SkiModel(key: "icelantic-nomad-105", brand: "Icelantic", model: "Nomad 105", category: .allMountain, waistMM: 105),
        SkiModel(key: "icelantic-pioneer-109", brand: "Icelantic", model: "Pioneer 109", category: .powder, waistMM: 109, accentHex: "1EC5B1"),
        SkiModel(key: "j-skis-masterblaster", brand: "J Skis", model: "Masterblaster", category: .allMountain, waistMM: 98, accentHex: "862C1E"),
        SkiModel(key: "j-skis-friend", brand: "J Skis", model: "Friend", category: .allMountain, waistMM: 100, accentHex: "5780C0"),
        SkiModel(key: "k2-disruption-82ti", brand: "K2", model: "Disruption 82Ti", category: .allMountain, waistMM: 82, accentHex: "9D331D"),
        SkiModel(key: "k2-mindbender-89ti", brand: "K2", model: "Mindbender 89Ti", category: .allMountain, waistMM: 89),
        SkiModel(key: "k2-mindbender-96c", brand: "K2", model: "Mindbender 96C", category: .allMountain, waistMM: 96, accentHex: "0B82C8"),
        SkiModel(key: "k2-mindbender-99ti", brand: "K2", model: "Mindbender 99Ti", category: .allMountain, waistMM: 99),
        SkiModel(key: "k2-mindbender-108ti", brand: "K2", model: "Mindbender 108Ti", category: .powder, waistMM: 108),
        SkiModel(key: "line-pandora-94", brand: "Line", model: "Pandora 94", category: .allMountain, waistMM: 94, accentHex: "B1C44E"),
        SkiModel(key: "line-blade-optic-96", brand: "Line", model: "Blade Optic 96", category: .allMountain, waistMM: 96),
        SkiModel(key: "line-pandora-99", brand: "Line", model: "Pandora 99", category: .allMountain, waistMM: 99, accentHex: "EE4C2C"),
        SkiModel(key: "line-sakana", brand: "Line", model: "Sakana", category: .allMountain, waistMM: 105, accentHex: "D6733C"),
        SkiModel(key: "moment-countach-104", brand: "Moment", model: "Countach 104", category: .allMountain, waistMM: 104, accentHex: "D0556C"),
        SkiModel(key: "moment-wildcat-108", brand: "Moment", model: "Wildcat 108", category: .powder, waistMM: 108, accentHex: "B33848"),
        SkiModel(key: "moment-deathwish", brand: "Moment", model: "Deathwish", category: .allMountain, waistMM: 112, accentHex: "27869A"),
        SkiModel(key: "moment-wildcat", brand: "Moment", model: "Wildcat", category: .powder, waistMM: 116, accentHex: "315383"),
        SkiModel(key: "nordica-santa-ana-93", brand: "Nordica", model: "Santa Ana 93", category: .allMountain, waistMM: 93, accentHex: "557499"),
        SkiModel(key: "nordica-enforcer-94", brand: "Nordica", model: "Enforcer 94", category: .allMountain, waistMM: 94),
        SkiModel(key: "nordica-santa-ana-98", brand: "Nordica", model: "Santa Ana 98", category: .allMountain, waistMM: 98, accentHex: "A2625A"),
        SkiModel(key: "nordica-enforcer-100", brand: "Nordica", model: "Enforcer 100", category: .allMountain, waistMM: 100, accentHex: "A05149"),
        SkiModel(key: "nordica-enforcer-104", brand: "Nordica", model: "Enforcer 104", category: .allMountain, waistMM: 104, accentHex: "D6D080"),
        SkiModel(key: "nordica-enforcer-110", brand: "Nordica", model: "Enforcer 110", category: .powder, waistMM: 110),
        SkiModel(key: "on3p-woodsman-100", brand: "ON3P", model: "Woodsman 100", category: .allMountain, waistMM: 100, accentHex: "B3642D"),
        SkiModel(key: "on3p-mango-102", brand: "ON3P", model: "Mango 102", category: .allMountain, waistMM: 102),
        SkiModel(key: "on3p-jeffrey-108", brand: "ON3P", model: "Jeffrey 108", category: .allMountain, waistMM: 108, accentHex: "CE1C17"),
        SkiModel(key: "on3p-woodsman-108", brand: "ON3P", model: "Woodsman 108", category: .powder, waistMM: 108, accentHex: "5BCE0B"),
        SkiModel(key: "on3p-wrenegade-108", brand: "ON3P", model: "Wrenegade 108", category: .allMountain, waistMM: 108, accentHex: "C62A17"),
        SkiModel(key: "on3p-billy-goat-118", brand: "ON3P", model: "Billy Goat 118", category: .powder, waistMM: 118, accentHex: "08336B"),
        SkiModel(key: "rossignol-experience-82-basalt", brand: "Rossignol", model: "Experience 82 Basalt", category: .allMountain, waistMM: 82),
        SkiModel(key: "rossignol-experience-86-ti", brand: "Rossignol", model: "Experience 86 Ti", category: .allMountain, waistMM: 86),
        SkiModel(key: "rossignol-sender-90-pro", brand: "Rossignol", model: "Sender 90 Pro", category: .allMountain, waistMM: 90),
        SkiModel(key: "rossignol-sender-94-ti", brand: "Rossignol", model: "Sender 94 Ti", category: .allMountain, waistMM: 94, accentHex: "B34956"),
        SkiModel(key: "rossignol-black-ops-sender", brand: "Rossignol", model: "Black Ops Sender", category: .allMountain, waistMM: 102),
        SkiModel(key: "rossignol-sender-104-ti", brand: "Rossignol", model: "Sender 104 Ti", category: .allMountain, waistMM: 104),
        SkiModel(key: "rossignol-soul-7-hd", brand: "Rossignol", model: "Soul 7 HD", category: .powder, waistMM: 106, accentHex: "CAD925"),
        SkiModel(key: "salomon-s-force-bold", brand: "Salomon", model: "S/Force Bold", category: .allMountain, waistMM: 82),
        SkiModel(key: "salomon-qst-92", brand: "Salomon", model: "QST 92", category: .allMountain, waistMM: 92),
        SkiModel(key: "salomon-stance-96", brand: "Salomon", model: "Stance 96", category: .allMountain, waistMM: 96),
        SkiModel(key: "salomon-qst-98", brand: "Salomon", model: "QST 98", category: .allMountain, waistMM: 98, accentHex: "3C2573"),
        SkiModel(key: "salomon-qst-99", brand: "Salomon", model: "QST 99", category: .allMountain, waistMM: 99, accentHex: "3D2674"),
        SkiModel(key: "salomon-stance-102", brand: "Salomon", model: "Stance 102", category: .allMountain, waistMM: 102, accentHex: "F24A6A"),
        SkiModel(key: "salomon-qst-106", brand: "Salomon", model: "QST 106", category: .powder, waistMM: 106, accentHex: "2D4F96"),
        SkiModel(key: "stockli-laser-ax", brand: "Stockli", model: "Laser AX", category: .allMountain, waistMM: 78, accentHex: "C0D021"),
        SkiModel(key: "stockli-stormrider-88", brand: "Stockli", model: "Stormrider 88", category: .allMountain, waistMM: 88),
        SkiModel(key: "stockli-stormrider-102", brand: "Stockli", model: "Stormrider 102", category: .allMountain, waistMM: 102),
        SkiModel(key: "voile-hypervector-bc", brand: "Voile", model: "HyperVector BC", category: .touring, waistMM: 103, accentHex: "1A4B70"),
        SkiModel(key: "volkl-kendo-88", brand: "Volkl", model: "Kendo 88", category: .allMountain, waistMM: 88, accentHex: "09709A"),
        SkiModel(key: "volkl-blaze-94", brand: "Volkl", model: "Blaze 94", category: .allMountain, waistMM: 94),
        SkiModel(key: "volkl-revolt-95", brand: "Volkl", model: "Revolt 95", category: .park, waistMM: 95),
        SkiModel(key: "volkl-m6-mantra", brand: "Volkl", model: "M6 Mantra", category: .allMountain, waistMM: 96, accentHex: "B01A2E"),
        SkiModel(key: "volkl-blaze-106", brand: "Volkl", model: "Blaze 106", category: .powder, waistMM: 106, accentHex: "4CB1C0"),
    ]
}

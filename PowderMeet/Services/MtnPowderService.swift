//
//  MtnPowderService.swift
//  PowderMeet
//
//  Fetches live trail and lift data from the MtnPowder.com JSON feed.
//  Covers ~100+ Alterra / Ikon resorts (Deer Valley, Steamboat,
//  Mammoth, Palisades Tahoe, Crystal Mountain, etc.).
//
//  The feed URL is: https://mtnpowder.com/feed/
//  Returns a JSON object with a "Resorts" array, each containing
//  "MountainAreas" with nested "Trails" and "Lifts".
//

import Foundation

// MARK: - MtnPowder Data Models

struct MtnPowderData: Sendable {
    let resortName: String
    let fetchDate: Date
    let trails: [MtnPowderTrail]
    let lifts: [MtnPowderLift]
}

struct MtnPowderTrail: Sendable {
    let id: Int
    let name: String
    let areaName: String
    let isOpen: Bool
    let difficulty: RunDifficulty
    let isGroomed: Bool
    let hasMoguls: Bool
    let isGladed: Bool
    let hasSnowMaking: Bool
    let isNightSkiing: Bool
    let isTerrainPark: Bool
}

struct MtnPowderLift: Sendable {
    let id: Int
    let name: String
    let areaName: String
    let isOpen: Bool
    let liftType: LiftType
    let waitTimeMinutes: Int?
}

// MARK: - Difficulty Mapping

private extension MtnPowderTrail {
    nonisolated static func parseDifficulty(icon: String?, text: String?) -> RunDifficulty {
        // TrailIcon is more reliable than Difficulty text
        switch icon?.lowercased() {
        case "greencircle":       return .green
        case "bluesquare":        return .blue
        case "blackdiamond":      return .black
        case "doubleblackdiamond": return .doubleBlack
        case "park":              return .terrainPark
        default: break
        }
        // Fallback to text
        switch text?.lowercased() {
        case "easy":              return .green
        case "intermediate":      return .blue
        case "expert":            return .black
        case "extreme terrain":   return .doubleBlack
        case "terrain park":      return .terrainPark
        default:                  return .blue
        }
    }
}

// MARK: - Lift Type Mapping

private extension MtnPowderLift {
    nonisolated static func parseLiftType(_ raw: String?) -> LiftType {
        guard let t = raw?.lowercased() else { return .unknown }
        switch t {
        case "gondola":                        return .gondola
        case "tram":                           return .cableCar
        case "cabriolet", "funitel":           return .gondola
        case "high-speed quad", "quad chair":  return .chairLift
        case "high-speed 6 chair", "6 chair":  return .chairLift
        case "triple chair":                   return .chairLift
        case "double":                         return .chairLift
        case "t-bar":                          return .tBar
        case "magic carpet":                   return .magicCarpet
        case "rope tow":                       return .ropeTow
        default:                               return .unknown
        }
    }

    nonisolated static func parseWaitTime(_ raw: Any?) -> Int? {
        if let s = raw as? String, let mins = Int(s) { return mins }
        if let n = raw as? Int { return n }
        return nil
    }
}

// MARK: - Resort Name → Catalog ID Mapping

enum MtnPowderResortMapping: Sendable {
    /// Maps MtnPowder feed resort names to our ResortCatalog IDs.
    /// Only winter entries with actual trail data are mapped.
    nonisolated static let nameToResortId: [String: String] = [
        // Ikon — Colorado
        "Steamboat":                    "steamboat",
        "Winter Park":                  "winter-park",
        "Copper Mountain":              "copper-mountain",
        "Arapahoe Basin":               "arapahoe-basin",
        "Eldora":                       "eldora",
        "Aspen Highlands":              "aspen-highlands",
        "Aspen Mountain":               "aspen-mountain",
        "Buttermilk":                   "buttermilk",
        "Snowmass":                     "snowmass",

        // Ikon — Utah
        "Deer Valley":                  "deer-valley",
        "Solitude":                     "solitude",
        "Alta":                         "alta",
        "Snowbird":                     "snowbird",
        "Brighton":                     "brighton",
        "Snowbasin Resort":             "snowbasin",

        // Ikon — California
        "Mammoth Mountain":             "mammoth",
        "June Mountain":                "june-mountain",
        "Palisades Tahoe":              "palisades-tahoe",
        "Sierra at Tahoe":              "sierra-at-tahoe",
        "Bear Mountain":                "big-bear",
        "Snow Summit":                  "big-bear",
        "Bear Mountain / Snow Summit":  "big-bear",
        "Snow Valley":                  "snow-valley",

        // Ikon — Pacific Northwest
        "Crystal Mountain":             "crystal-mountain",
        "Summit at Snoqualmie":         "summit-at-snoqualmie",
        "Alpental":                     "summit-at-snoqualmie",

        // Ikon — Other USA
        "Schweitzer":                   "schweitzer",
        "Big Sky":                      "big-sky",
        "Jackson Hole":                 "jackson-hole",
        "Sun Valley":                   "sun-valley",
        "Sun Valley Ski Area":          "sun-valley",
        "Alyeska":                      "alyeska",
        "Taos":                         "taos",
        "Snowshoe":                     "snowshoe",

        // Ikon — Vermont
        "Stratton":                     "stratton",
        "Killington":                   "killington",
        "Pico Mountain":                "pico",
        "Sugarbush":                    "sugarbush",

        // Ikon — New Hampshire / Maine / Massachusetts
        "Loon Mountain":                "loon",
        "Sugarloaf":                    "sugarloaf",
        "Sunday River":                 "sunday-river",

        // Ikon — Michigan / Minnesota
        "Boyne Mountain":               "boyne-mountain",
        "Boyne Highlands":              "the-highlands",

        // Ikon — Pennsylvania
        "Blue Mountain (PA)":           "blue-mountain-pa",
        "Camelback":                    "camelback",

        // Ikon — Canada
        "Tremblant":                    "tremblant",
        "Blue":                         "blue-mountain-on",
        "Lake Louise":                  "lake-louise",
        "Sunshine Village":             "banff-sunshine",
        "Mt Norquay":                   "norquay",
        "Revelstoke":                   "revelstoke",
        "RED Mountain":                 "red-mountain",
        "Cypress Mountain":             "cypress",
        "Panorama Mountain Resort":     "panorama",
        "Sun Peaks":                    "sun-peaks",
        "Le Massif":                    "le-massif",

        // Ikon — Japan
        "Niseko Annupuri":              "niseko",
        "Niseko Grand Hirafu":          "niseko",
        "Niseko Hanazano":              "niseko",
        "Niseko Village":               "niseko",
        "Lotte Arai":                   "lotte-arai",
        "Appi Kogen Resort":            "appi",
        "Zao Onsen Ski Resort":         "zao-onsen",
        "Furano Ski Resort":            "furano",
        "Myoko Suginohara":             "myoko-suginohara",

        // Shiga Kogen sub-areas → single resort
        "Yakebitaiyama Ski Area":       "shiga-kogen",
        "Okushiga Kogen Ski Area":      "shiga-kogen",
        "Kumanoyu Ski Area":            "shiga-kogen",
        "Yokoteyama Ski Area":          "shiga-kogen",
        "Maruike Ski Area":             "shiga-kogen",
        "Hasuike Ski Area":             "shiga-kogen",
        "Giant Ski Area":               "shiga-kogen",
        "Nishidateyama Ski Area":       "shiga-kogen",
        "Higashidateyama Ski Area":     "shiga-kogen",
        "Hoppo Bunadaira Ski Area":     "shiga-kogen",
        "Terakoya Ski Area":            "shiga-kogen",
        "Takamagahara Mommoth Ski Area": "shiga-kogen",
        "Tannenomori Okojo Ski Area":   "shiga-kogen",
        "Ichinose Family Ski Area":     "shiga-kogen",
        "Ichinose Diamond Ski Area":    "shiga-kogen",
        "Ichinose Yamanokami Ski Area":  "shiga-kogen",
        "Shibutoge Ski Area":           "shiga-kogen",

        // Ikon — Southern Hemisphere
        "Thredbo":                      "thredbo",
        "Mt Bueller":                   "mt-buller",
        "Coronet Peak":                 "coronet-peak",
        "The Remarkables":              "the-remarkables",
        "Mt Hutt":                      "mt-hutt",
        "Valle Nevado":                 "valle-nevado",

        // Ikon — Europe
        "Chamonix":                     "chamonix",
        "Megeve":                       "megeve",
        "Kitzbühel":                    "kitzbuehel",
        "St Moritz":                    "st-moritz",
        "Zermatt Matterhorn":           "zermatt",
        "Ischgl":                       "ischgl",
        "Grandvilara":                  "grandvalira",

        // Ikon — Italy (Dolomiti Superski sub-areas)
        "Cortina d'Ampezzo":            "dolomiti-superski",
        "Kronplatz/Plan de Corones":    "dolomiti-superski",
        "Alta Badia":                   "dolomiti-superski",
        "Val Gardena/Alpe de Siusi":    "dolomiti-superski",
        "Val di Fassa/Carezza":         "dolomiti-superski",
        "Arabba/Marmolada":             "dolomiti-superski",
        "3 Peaks Dolomites":            "dolomiti-superski",
        "Val di Fiemme/Obereggen":      "dolomiti-superski",
        "San Martino di Castrozza/Rolle Pass": "dolomiti-superski",
        "Civetta":                      "dolomiti-superski",
        "Rio Pusteria - Bressanone":    "dolomiti-superski",
        "Alpe Lusia - San Pellegrino":  "dolomiti-superski",

        // Ikon — Italy (Aosta Valley)
        "Cervino Ski Paradise":         "cervino",
        "Courmayeur Mont Blanc":        "courmayeur",
        "Espace San Bernardo":          "la-thuile",
        "Monterosa Ski":                "monterosa",
        "Pila":                         "pila",

        // Ikon — Other
        "Mt. T":                        "mt-t",
        "Nekoma":                       "nekoma",
        "Yunding Snow Park":            "yunding",
        "Mona Yongpyong":              "mona-yongpyong",
        "Windham Mountain":             "hunter",  // nearby, same pass
        "Mt Bachelor":                  "mt-bachelor",
    ]

    /// Skip these feed entries — summer operations, cross-country, or duplicates.
    nonisolated static let skipNames: Set<String> = [
        "Stratton Summer", "Snowshoe Summer", "Blue Summer",
        "Tremblant Summer", "Winter Park Summer", "Steamboat Summer",
        "Deer Valley Summer", "Bear Mountain Summer", "Snow Summit Summer",
        "Mammoth Mountain Summer", "June Mountain Summer", "Solitude Summer",
        "Schweitzer Summer", "Snow Valley Summer",
        "Bear Mountain Summer / Snow Summit Summer",
        "Bear Mountain Summer / Snow Summit Summer / Snow Valley Summer",
        "Bear Mountain / Snow Summit / Snow Valley",
        "Palisades Tahoe - Alpine Meadows Legacy",
        "Tamarack Cross Country Ski Center",
    ]
}

// MARK: - Service

actor MtnPowderService {
    static let shared = MtnPowderService()

    private static let feedURL = URL(string: "https://mtnpowder.com/feed/")!
    private var cache: [String: MtnPowderData] = [:]
    private var feedCache: [[String: Any]]? = nil
    private var feedCacheDate: Date? = nil
    private let cacheDuration: TimeInterval = 15 * 60  // 15 minutes

    /// Fetch trail/lift data for a specific resort from the MtnPowder feed.
    func fetchData(resortId: String) async -> MtnPowderData? {
        // Check per-resort cache
        if let cached = cache[resortId], Date().timeIntervalSince(cached.fetchDate) < cacheDuration {
            return cached
        }

        // Load the full feed (cached for all resorts)
        guard let feedResorts = await loadFeed() else { return nil }

        // Find matching feed entries for this resort
        let matchingEntries = feedResorts.filter { entry in
            guard let name = entry["Name"] as? String else { return false }
            if MtnPowderResortMapping.skipNames.contains(name) { return false }
            return MtnPowderResortMapping.nameToResortId[name] == resortId
        }

        guard !matchingEntries.isEmpty else {
            return nil
        }

        // Merge trails/lifts from all matching entries (e.g. Niseko has 4 sub-resorts)
        var allTrails: [MtnPowderTrail] = []
        var allLifts: [MtnPowderLift] = []
        var resortName = resortId

        for entry in matchingEntries {
            if let name = entry["Name"] as? String, resortName == resortId {
                resortName = name
            }
            let (trails, lifts) = parseResortEntry(entry)
            allTrails.append(contentsOf: trails)
            allLifts.append(contentsOf: lifts)
        }

        // Deduplicate by name (sub-areas may share lifts)
        var seenTrailNames = Set<String>()
        allTrails = allTrails.filter { seenTrailNames.insert($0.name).inserted }
        var seenLiftNames = Set<String>()
        allLifts = allLifts.filter { seenLiftNames.insert($0.name).inserted }

        let data = MtnPowderData(
            resortName: resortName,
            fetchDate: Date(),
            trails: allTrails,
            lifts: allLifts
        )

        cache[resortId] = data
        print("[MtnPowder] Loaded \(allTrails.count) trails, \(allLifts.count) lifts for \(resortId)")
        return data
    }

    // MARK: - Feed Loading

    private func loadFeed() async -> [[String: Any]]? {
        // Check feed-level cache
        if let cached = feedCache, let date = feedCacheDate,
           Date().timeIntervalSince(date) < cacheDuration {
            return cached
        }

        do {
            var request = URLRequest(url: Self.feedURL)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("[MtnPowder] HTTP error fetching feed")
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resorts = json["Resorts"] as? [[String: Any]] else {
                print("[MtnPowder] Failed to parse feed JSON")
                return nil
            }

            feedCache = resorts
            feedCacheDate = Date()
            print("[MtnPowder] Feed loaded: \(resorts.count) resort entries")
            return resorts
        } catch {
            print("[MtnPowder] Feed fetch error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Parsing

    private func parseResortEntry(_ entry: [String: Any]) -> ([MtnPowderTrail], [MtnPowderLift]) {
        var trails: [MtnPowderTrail] = []
        var lifts: [MtnPowderLift] = []

        guard let areas = entry["MountainAreas"] as? [[String: Any]] else { return ([], []) }

        for area in areas {
            let areaName = area["Name"] as? String ?? "Unknown"

            if let rawTrails = area["Trails"] as? [[String: Any]] {
                for t in rawTrails {
                    let name = t["Name"] as? String ?? ""
                    guard !name.isEmpty else { continue }

                    let trail = MtnPowderTrail(
                        id: t["Id"] as? Int ?? 0,
                        name: name,
                        areaName: areaName,
                        isOpen: (t["StatusEnglish"] as? String)?.lowercased() == "open",
                        difficulty: MtnPowderTrail.parseDifficulty(
                            icon: t["TrailIcon"] as? String,
                            text: t["Difficulty"] as? String
                        ),
                        isGroomed: (t["Grooming"] as? String)?.lowercased() == "yes",
                        hasMoguls: (t["Moguls"] as? String)?.lowercased() == "yes",
                        isGladed: (t["Glades"] as? String)?.lowercased() == "yes",
                        hasSnowMaking: (t["SnowMaking"] as? String)?.lowercased() == "yes",
                        isNightSkiing: (t["NightSkiing"] as? String)?.lowercased() == "yes",
                        isTerrainPark: (t["TrailIcon"] as? String) == "Park"
                    )
                    trails.append(trail)
                }
            }

            if let rawLifts = area["Lifts"] as? [[String: Any]] {
                for l in rawLifts {
                    let name = l["Name"] as? String ?? ""
                    guard !name.isEmpty else { continue }

                    let lift = MtnPowderLift(
                        id: l["Id"] as? Int ?? 0,
                        name: name,
                        areaName: areaName,
                        isOpen: (l["StatusEnglish"] as? String)?.lowercased() == "open",
                        liftType: MtnPowderLift.parseLiftType(l["LiftType"] as? String),
                        waitTimeMinutes: MtnPowderLift.parseWaitTime(l["WaitTime"])
                    )
                    lifts.append(lift)
                }
            }
        }

        return (trails, lifts)
    }
}

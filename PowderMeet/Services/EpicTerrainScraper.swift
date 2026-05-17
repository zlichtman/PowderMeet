//
//  EpicTerrainScraper.swift
//  PowderMeet
//
//  Scrapes Vail Resorts / Epic terrain status pages to extract official
//  trail and lift data. The pages embed a `FR.TerrainStatusFeed` JSON
//  variable with every trail name, difficulty, grooming, lift name,
//  type, wait time, capacity, and open/closed status.
//
//  Coverage: ~40 Epic resorts (Whistler, Vail, Park City, etc.)
//

import Foundation

// MARK: - Epic Terrain Data Models

struct EpicTerrainData: Codable, Sendable {
    let resortSlug: String
    let fetchDate: Date
    let areas: [EpicArea]

    nonisolated var allTrails: [EpicTrail] {
        areas.flatMap { $0.trails }
    }

    nonisolated var allLifts: [EpicLift] {
        areas.flatMap { $0.lifts }
    }
}

struct EpicArea: Codable, Sendable {
    let id: Int
    let name: String
    let trails: [EpicTrail]
    let lifts: [EpicLift]
}

struct EpicTrail: Codable, Sendable {
    let id: Int
    let name: String
    let difficulty: Int          // 1=green, 2=blue, 3=black, 4=doubleBlack, 5=terrainPark
    let isOpen: Bool
    let isGroomed: Bool
    let trailInfo: String?
    let trailLength: String?
    let trailType: Int?
    let isTrailWork: Bool?
    let areaName: String         // parent area name for context
}

struct EpicLift: Codable, Sendable {
    let name: String
    let status: Int              // 3 = operating
    let type: String?            // "gondola", "quad", "six", "triple", "t-bar", "conveyor"
    let mountain: String?
    let waitTimeInMinutes: Int?
    let capacity: Int?
    let openTime: String?        // "HH:MM"
    let closeTime: String?
    let areaName: String

    var isOpen: Bool { status == 3 }

    var liftType: LiftType? {
        guard let t = type?.lowercased() else { return nil }
        switch t {
        case "gondola":   return .gondola
        case "quad":      return .chairLift
        case "six":       return .chairLift
        case "triple":    return .chairLift
        case "double":    return .chairLift
        case "t-bar":     return .tBar
        case "conveyor":  return .magicCarpet
        case "cable car": return .cableCar
        default:          return .chairLift
        }
    }
}

// MARK: - Epic Difficulty Mapping

extension EpicTrail {
    var runDifficulty: RunDifficulty {
        switch difficulty {
        case 1:  return .green
        case 2:  return .blue
        case 3:  return .black
        case 4:  return .doubleBlack
        case 5:  return .terrainPark
        default: return .blue
        }
    }
}

// MARK: - Resort URL Mapping

enum EpicResortURLs {
    static func terrainURL(for resortId: String) -> URL? {
        guard let domain = resortDomains[resortId] else { return nil }
        return URL(string: "https://\(domain)/the-mountain/mountain-conditions/terrain-and-lift-status.aspx")
    }

    static func epicSlug(for resortId: String) -> String? {
        if resortDomains[resortId] != nil { return resortId }
        let aliases: [String: String] = [
            "whistler": "whistler-blackcomb",
            "parkcity": "park-city",
            "beavercreek": "beaver-creek",
            "crestedbutte": "crested-butte",
            "stevenspass": "stevens-pass",
            "mountsnow": "mount-snow",
        ]
        return aliases[resortId]
    }

    private static let resortDomains: [String: String] = [
        "whistler-blackcomb": "www.whistlerblackcomb.com",
        "vail":               "www.vail.com",
        "park-city":          "www.parkcity.com",
        "breckenridge":       "www.breckenridge.com",
        "keystone":           "www.keystoneresort.com",
        "beaver-creek":       "www.beavercreek.com",
        "stowe":              "www.stowe.com",
        "heavenly":           "www.skiheavenly.com",
        "northstar":          "www.northstarcalifornia.com",
        "kirkwood":           "www.kirkwood.com",
        "crested-butte":      "www.skicb.com",
        "stevens-pass":       "www.stevenspass.com",
        "liberty":            "www.libertymountainresort.com",
        "roundtop":           "www.skiroundtop.com",
        "whitetail":          "www.skiwhitetail.com",
        "jack-frost":         "www.jfbb.com",
        "big-boulder":        "www.jfbb.com",
        "mount-brighton":     "www.mtbrighton.com",
        "afton-alps":         "www.aftonalps.com",
        "mt-brighton":        "www.mtbrighton.com",
        "wilmot":             "www.wilmotmountain.com",
        "perisher":           "www.perisher.com.au",
        "falls-creek":        "www.fallscreek.com.au",
        "hotham":             "www.mthotham.com.au",
        "okemo":              "www.okemo.com",
        "mount-sunapee":      "www.mountsunapee.com",
        "hunter":             "www.huntermtn.com",
        "attitash":           "www.attitash.com",
        "wildcat":            "www.skiwildcat.com",
        "crotched":           "www.crotchedmtn.com",
        "mount-snow":         "www.mountsnow.com",
    ]
}

// MARK: - Scraper

actor EpicTerrainScraper {
    static let shared = EpicTerrainScraper()

    private var cache: [String: EpicTerrainData] = [:]
    private let cacheDuration: TimeInterval = 15 * 60  // 15 minutes

    func fetchTerrainData(resortId: String) async -> EpicTerrainData? {
        let slug = await EpicResortURLs.epicSlug(for: resortId) ?? resortId

        // Check cache
        if let cached = cache[slug], Date().timeIntervalSince(cached.fetchDate) < cacheDuration {
            return cached
        }

        guard let url = await EpicResortURLs.terrainURL(for: slug) else {
            print("[EpicTerrainScraper] No URL mapping for \(slug)")
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("[EpicTerrainScraper] HTTP error for \(slug)")
                return nil
            }

            guard let html = String(data: data, encoding: .utf8) else { return nil }
            guard let terrainData = parseTerrainFeed(html: html, slug: slug) else {
                print("[EpicTerrainScraper] Failed to parse terrain feed for \(slug)")
                return nil
            }

            cache[slug] = terrainData
            print("[EpicTerrainScraper] Loaded \(terrainData.allTrails.count) trails, \(terrainData.allLifts.count) lifts for \(slug)")
            return terrainData
        } catch {
            print("[EpicTerrainScraper] Error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - HTML Parsing

    private func parseTerrainFeed(html: String, slug: String) -> EpicTerrainData? {
        // Find FR.TerrainStatusFeed = {...} in the HTML
        guard let feedStart = html.range(of: "FR.TerrainStatusFeed") else { return nil }

        // Find the opening brace after the assignment
        let afterFeed = html[feedStart.upperBound...]
        guard let braceStart = afterFeed.firstIndex(of: "{") else { return nil }

        // Find matching closing brace
        var depth = 0
        var braceEnd: String.Index?
        for idx in html.indices[braceStart...] {
            if html[idx] == "{" { depth += 1 }
            else if html[idx] == "}" {
                depth -= 1
                if depth == 0 {
                    braceEnd = html.index(after: idx)
                    break
                }
            }
        }
        guard let endIdx = braceEnd else { return nil }

        let jsonString = String(html[braceStart..<endIdx])

        // Parse the JSON
        guard let jsonData = jsonString.data(using: .utf8) else { return nil }
        guard let rawJSON = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return nil }
        guard let groomingAreas = rawJSON["GroomingAreas"] as? [[String: Any]] else { return nil }

        var areas: [EpicArea] = []

        for area in groomingAreas {
            let areaId = area["Id"] as? Int ?? 0
            let areaName = area["Name"] as? String ?? "Unknown"
            var trails: [EpicTrail] = []
            var lifts: [EpicLift] = []

            if let rawTrails = area["Trails"] as? [[String: Any]] {
                for t in rawTrails {
                    let trail = EpicTrail(
                        id: t["Id"] as? Int ?? 0,
                        name: t["Name"] as? String ?? "",
                        difficulty: t["Difficulty"] as? Int ?? 2,
                        isOpen: t["IsOpen"] as? Bool ?? false,
                        isGroomed: t["IsGroomed"] as? Bool ?? false,
                        trailInfo: t["TrailInfo"] as? String,
                        trailLength: t["TrailLength"] as? String,
                        trailType: t["TrailType"] as? Int,
                        isTrailWork: t["IsTrailWork"] as? Bool,
                        areaName: areaName
                    )
                    if !trail.name.isEmpty {
                        trails.append(trail)
                    }
                }
            }

            if let rawLifts = area["Lifts"] as? [[String: Any]] {
                for l in rawLifts {
                    let lift = EpicLift(
                        name: l["Name"] as? String ?? "",
                        status: l["Status"] as? Int ?? 0,
                        type: l["Type"] as? String,
                        mountain: l["Mountain"] as? String,
                        waitTimeInMinutes: l["WaitTimeInMinutes"] as? Int,
                        capacity: l["Capacity"] as? Int,
                        openTime: l["OpenTime"] as? String,
                        closeTime: l["CloseTime"] as? String,
                        areaName: areaName
                    )
                    if !lift.name.isEmpty {
                        lifts.append(lift)
                    }
                }
            }

            areas.append(EpicArea(id: areaId, name: areaName, trails: trails, lifts: lifts))
        }

        return EpicTerrainData(
            resortSlug: slug,
            fetchDate: Date(),
            areas: areas
        )
    }
}

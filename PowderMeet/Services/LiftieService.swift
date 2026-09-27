//
//  LiftieService.swift
//  PowderMeet
//
//  Free API client for liftie.info — returns real-time lift names and
//  open/closed/hold status for ~100 ski resorts worldwide. No API key needed.
//
//  Attribution: "Lift status provided by Liftie"
//

import Foundation

// MARK: - Liftie Data Models

struct LiftieResponse: Codable, Sendable {
    let id: String
    let name: String
    let lifts: LiftieLifts
    let weather: LiftieWeather?

    // Explicit nonisolated Decodable conformance so this works inside actors.
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        lifts = try container.decode(LiftieLifts.self, forKey: .lifts)
        weather = try container.decodeIfPresent(LiftieWeather.self, forKey: .weather)
    }

    struct LiftieLifts: Codable, Sendable {
        let status: [String: String]   // lift name → "open"|"closed"|"hold"|"scheduled"
        let stats: LiftieStats?
    }

    struct LiftieStats: Codable, Sendable {
        let open: Int?
        let closed: Int?
        let hold: Int?
        let scheduled: Int?
        let percentage: LiftiePercentage?
    }

    struct LiftiePercentage: Codable, Sendable {
        let open: Int?
        let closed: Int?
        let hold: Int?
        let scheduled: Int?
    }

    struct LiftieWeather: Codable, Sendable {
        let temperature: Int?
        let forecast: String?
        let wind: String?
    }
}

// MARK: - Resort Slug Mapping

enum LiftieResortSlugs {
    static func slug(for resortId: String) -> String? {
        slugMap[resortId] ?? slugMap[resortId.lowercased()]
    }

    private static let slugMap: [String: String] = [
        "whistler-blackcomb": "whistler-blackcomb",
        "whistler": "whistler-blackcomb",
        "vail": "vail",
        "park-city": "park-city",
        "parkcity": "park-city",
        "breckenridge": "breckenridge",
        "keystone": "keystone",
        "beaver-creek": "beaver-creek",
        "beavercreek": "beaver-creek",
        "stowe": "stowe",
        "heavenly": "heavenly",
        "northstar": "northstar-at-tahoe",
        "kirkwood": "kirkwood",
        "mammoth": "mammoth-mountain",
        "squaw": "palisades-tahoe",
        "palisades-tahoe": "palisades-tahoe",
        "aspen": "aspen-snowmass",
        "snowbird": "snowbird",
        "alta": "alta",
        "jackson-hole": "jackson-hole",
        "big-sky": "big-sky",
        "telluride": "telluride",
        "steamboat": "steamboat",
        "winter-park": "winter-park",
        "copper": "copper-mountain",
        "arapahoe-basin": "arapahoe-basin",
        "deer-valley": "deer-valley",
        "brighton": "brighton",
        "solitude": "solitude-mountain",
        "killington": "killington",
        "sugarbush": "sugarbush",
        "stratton": "stratton",
        "loon": "loon-mountain",
        "sunday-river": "sunday-river",
        "sugarloaf": "sugarloaf",
        "mount-snow": "mount-snow",
        "okemo": "okemo",
        "jay-peak": "jay-peak",
        "tremblant": "mont-tremblant",
        "revelstoke": "revelstoke",
        "sun-peaks": "sun-peaks",
        "lake-louise": "lake-louise",
        "sunshine-village": "sunshine-village",
        "mont-tremblant": "mont-tremblant",
    ]
}

// MARK: - Liftie Service

actor LiftieService {
    static let shared = LiftieService()

    private var cache: [String: (response: LiftieResponse, date: Date)] = [:]
    private let cacheDuration: TimeInterval = 5 * 60  // 5 minutes
    /// Slugs that returned a permanent failure (403, 404). Logged once,
    /// short-circuited on every subsequent call so we don't retry forever
    /// or spam the console with the same error each refresh.
    private var deadSlugs: Set<String> = []

    func fetchLiftStatus(resortId: String) async -> LiftieResponse? {
        guard let slug = await LiftieResortSlugs.slug(for: resortId) else {
            print("[LiftieService] No slug mapping for \(resortId)")
            return nil
        }

        // Check cache
        if let cached = cache[slug], Date().timeIntervalSince(cached.date) < cacheDuration {
            return cached.response
        }
        if deadSlugs.contains(slug) { return nil }

        guard let url = URL(string: "https://liftie.info/api/resort/\(slug)") else { return nil }

        // Retry once on network error after a 2s delay
        for attempt in 0...1 {
            do {
                var request = URLRequest(url: url)
                request.setValue("PowderMeet/1.0", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 10

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else { return nil }

                // Liftie sometimes returns HTML error pages — verify status + content-type
                guard httpResponse.statusCode == 200 else {
                    // Permanent failures (403/404) — remember and stop pestering.
                    if httpResponse.statusCode == 403 || httpResponse.statusCode == 404 {
                        deadSlugs.insert(slug)
                        print("[LiftieService] HTTP \(httpResponse.statusCode) for \(slug) — disabling for this session")
                    } else {
                        print("[LiftieService] HTTP \(httpResponse.statusCode) for \(slug)")
                    }
                    return nil
                }
                let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
                guard contentType.contains("json") else {
                    let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>"
                    print("[LiftieService] Non-JSON response for \(slug) (Content-Type: \(contentType)): \(preview)")
                    return nil
                }

                let liftieResponse = try JSONDecoder().decode(LiftieResponse.self, from: data)
                cache[slug] = (liftieResponse, Date())
                print("[LiftieService] Loaded \(liftieResponse.lifts.status.count) lifts for \(slug)")
                return liftieResponse
            } catch {
                print("[LiftieService] Error (attempt \(attempt + 1)): \(error.localizedDescription)")
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s before retry
                    continue
                }
                return nil
            }
        }
        return nil
    }
}

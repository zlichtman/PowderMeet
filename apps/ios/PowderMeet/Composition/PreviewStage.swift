#if DEBUG
import AppCore
import CoreGraphics
import Foundation
import MountainCore
import PowderMeetAPI

/// `-previewData YES -previewResort <id>` (Debug only, never a user-facing
/// mode): the app signed in as the made-up preview profile on a private
/// `FakeBackend` on this phone, listing the whole live catalog with the chosen
/// mountain open, so a meet with the pretend friend can be staged signed out
/// for screenshots and the demo storyboard's checks. Any other mountain opens
/// too: its map, status and forecast are read from production on first use.
/// Only anon-readable public reads (catalog, bundle, status, conditions) touch
/// production; every write,
/// the account, friends, presence and meets stay in the fake. Add
/// `-previewSnow YES` for the forecast to say it is snowing all day, or
/// `-previewWeather script` for the demo's scripted day. The demo's people
/// (`DemoCast`): `-demoName`, `-demoPhoto <path>`, `-demoSki <catalog key>`,
/// `-demoLevel`, `-demoFriendName`, `-demoFriendPhoto <path>`; the photos are read from
/// disk at launch and never copied into the app. `-previewLiftsOpen YES`
/// reports every lift and run open; `-previewPlaceName "A=B|C=D"` shows the
/// mountain's places A and C as B and D (`StagedPlaceNames`).
nonisolated enum PreviewStage {
    static var resortID: String? {
        guard DebugLaunch.previewData else { return nil }
        return UserDefaults.standard.string(forKey: "previewResort")
    }

    static var snows: Bool { UserDefaults.standard.bool(forKey: "previewSnow") }

    /// Capture labels and sunlight share a morning clock. Runtime timestamps
    /// stay real so presence, request expiry and movement keep working normally.
    /// `now` is the instant shown as 9:41: the moment of reading while the
    /// timeline is Live, and the moment it left Live while scrubbed. Reading a
    /// held scrub against the moment of drawing would slide it back a minute
    /// every minute the still is held.
    static func presentationDate(_ instant: Date, in timeZone: TimeZone, now: Date = Date()) -> Date {
        guard DebugLaunch.previewData, DebugLaunch.demoCapture else { return instant }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // The half-minute margin keeps separate live Date() reads from displaying 9:40.
        let morning = calendar.startOfDay(for: now).addingTimeInterval(9 * 3_600 + 41 * 60 + 30)
        return morning.addingTimeInterval(instant.timeIntervalSince(now))
    }

    /// Captures use the displayed 9:41 morning. Other previews may override
    /// sunlight with `-previewSunHour 12` without changing their displayed clock.
    static func sunShifted(_ instant: Date, in timeZone: TimeZone, now: Date = Date()) -> Date {
        if DebugLaunch.previewData, DebugLaunch.demoCapture {
            return presentationDate(instant, in: timeZone, now: now)
        }
        let hour = UserDefaults.standard.double(forKey: "previewSunHour")
        guard DebugLaunch.previewData, hour > 0 else { return instant }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let midnight = calendar.startOfDay(for: now)
        return instant.addingTimeInterval(hour * 3_600 - now.timeIntervalSince(midnight))
    }

    /// The stage's own cache folder next to the app's, emptied of everything
    /// but downloaded maps.
    static func freshCache(beside cache: URL) -> URL {
        let folder = cache.deletingLastPathComponent().appendingPathComponent("PowderMeet-preview", isDirectory: true)
        let files = FileManager.default
        do {
            for item in try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where item.lastPathComponent != "bundles" {
                try files.removeItem(at: item)
            }
        } catch {
            // A first run has no folder yet.
        }
        return folder
    }

    /// `-previewWeather script`: the demo's scripted forecast.
    static var scripted: Bool { UserDefaults.standard.string(forKey: "previewWeather") == "script" }

    /// The fake server, the client signed in as the preview profile, and the
    /// seeding that must finish before the session starts.
    static func make(live: any BackendClient, resortID: String) -> (client: FakeBackendClient, seed: @Sendable () async -> Void) {
        let profile = DebugLaunch.previewProfile
        let server = FakeBackend(now: Date())
        let client = server.client(signedInAs: profile.id)
        let snows = snows
        let scripted = scripted
        let cast = DemoCast.fromLaunch
        let liftsOpen = UserDefaults.standard.bool(forKey: "previewLiftsOpen")
        let weather: @Sendable (Conditions) -> Conditions = { conditions in
            if scripted { return scriptedDay(conditions) }
            return snows ? snowing(conditions) : conditions
        }
        let seed: @Sendable () async -> Void = {
            await server.addUser(id: profile.id, displayName: cast.name ?? "PowderMeet")
            if let friendName = cast.friendName {
                // The demo's friend is a friend on the stage too, so Friends lists them.
                await server.addUser(id: DeveloperSandbox.pretendFriendID, displayName: friendName)
                await server.makeFriends(profile.id, DeveloperSandbox.pretendFriendID)
            }
            do {
                var equipment = profile.equipment
                if let ski = cast.ski {
                    // Type and waist come from the catalog model, as when the
                    // ski is picked in the app (`GearDraft.choose`), so the
                    // stage's Gear matches its ski picker.
                    let model = SkiCatalog.model(key: ski)
                    equipment = ProfileEquipment(
                        discipline: "ski",
                        type: model?.category.equipmentType.rawValue ?? equipment?.type ?? "all_mountain",
                        lengthCM: 180, waistMM: model?.waistMM ?? 110, ski: ski)
                }
                _ = try await client.profileUpdate(ProfilePatch()
                    .ability(cast.level ?? profile.ability)
                    .maxDifficulty(profile.maxDifficulty)
                    .equipment(equipment)
                    .heightCM(profile.heightCM).weightKG(profile.weightKG))
                if let photo = cast.photo {
                    let path = AvatarPath.new(for: profile.id)
                    await server.storeAvatar(photo, at: path)
                    _ = try await client.profileUpdate(ProfilePatch().avatarURL(path))
                }
                if let photo = cast.friendPhoto {
                    await server.storeAvatar(photo, at: DemoCast.friendPhotoPath)
                }
                let catalog = try await live.resortCatalog()
                await server.setResortSource(FakeBackend.ResortSource(
                    bundle: { id, bundleID in
                        let data = try await live.bundleData(resortID: id, bundleID: bundleID)
                        let bundle = try BundleLoader.load(data: data, expectedID: bundleID)
                        return (data, bundle.rendezvous.map(\.id))
                    },
                    status: { try await live.resortStatus(resortID: $0) },
                    conditions: { id in
                        try await live.resortConditions(resortID: id).map(weather)
                    }))
                for other in catalog where other.id != resortID {
                    if other.hasMap {
                        await server.listResort(other)
                    } else {
                        await server.addResort(other, published: false)
                    }
                }
                guard let listed = catalog.first(where: { $0.id == resortID }),
                      let listedID = listed.bundleID else { return }
                var data = try await live.bundleData(resortID: resortID, bundleID: listedID)
                var row = listed, bundleID = listedID
                if let staged = StagedPlaceNames.fromLaunch?.apply(to: data) {
                    (data, bundleID) = staged
                    row.bundleID = staged.id
                }
                let bundle = try BundleLoader.load(data: data, expectedID: bundleID)
                await server.addResort(row)
                await server.publishBundle(
                    resortID: resortID, bundleID: bundleID, data: data, rendezvousIDs: bundle.rendezvous.map(\.id))
                // Opened on sign-in, as a returning user's last resort is.
                _ = try await client.profileUpdate(ProfilePatch().currentResortID(resortID))
                if liftsOpen {
                    // Every lift and run reported open, fresh for the session.
                    await server.publishStatus(ResortStatus(
                        resortID: resortID, observedAt: Date(), expiresAt: Date().addingTimeInterval(12 * 3_600),
                        source: .epic, groups: Dictionary(uniqueKeysWithValues: bundle.groups.map { ($0.id, .open) })))
                } else if let status = try await live.resortStatus(resortID: resortID) {
                    await server.publishStatus(status)
                }
                if let conditions = try await live.resortConditions(resortID: resortID) {
                    await server.setConditions(weather(conditions))
                }
            } catch {
                print("preview stage: \(error)")
            }
        }
        return (client, seed)
    }

    /// The demo's day (owner, 21 Nov: "a bunch of fake weather changes"),
    /// in hours from now so it plays whenever it is recorded: clear until
    /// now, clouds building over the next two hours, heavy snow from +3 h to
    /// +5 h (the map's snow falls), then wind, then clearing from +8 h into
    /// the evening. Scrubbing the timeline walks through all of it.
    private static func scriptedDay(_ conditions: Conditions) -> Conditions {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        func sample(_ offset: Int) -> ConditionsSample {
            let at = hour.addingTimeInterval(Double(offset) * 3_600)
            switch offset {
            case ...0:
                // Clear, a cold morning warming toward now.
                return ConditionsSample(
                    at: at, tempC: -9 + Double(offset + 12) * 0.4, windMS: 2, gustMS: 4, visibilityM: 40_000,
                    cloudPct: 5, snow24hCM: 0, precipMMH: 0, weatherCode: 0)
            case 1:
                return ConditionsSample(
                    at: at, tempC: -4, windMS: 3, gustMS: 6, visibilityM: 24_000,
                    cloudPct: 55, snow24hCM: 0, precipMMH: 0, weatherCode: 2)
            case 2:
                return ConditionsSample(
                    at: at, tempC: -4, windMS: 4, gustMS: 8, visibilityM: 9_000,
                    cloudPct: 95, snow24hCM: 0, precipMMH: 0, weatherCode: 3)
            case 3...5:
                // Heavy snow: the map's snowfall turns on.
                let fallen = Double(offset - 2) * 9
                return ConditionsSample(
                    at: at, tempC: -6, windMS: 6, gustMS: 11, visibilityM: 350,
                    cloudPct: 100, snow24hCM: fallen, precipMMH: 3.5, weatherCode: 75)
            case 6...7:
                // The storm's tail: wind, blowing snow, the sky still grey.
                return ConditionsSample(
                    at: at, tempC: -9, windMS: 15, gustMS: 24, visibilityM: 2_500,
                    cloudPct: 80, snow24hCM: 29, precipMMH: 0, weatherCode: 3)
            case 8:
                return ConditionsSample(
                    at: at, tempC: -10, windMS: 6, gustMS: 10, visibilityM: 25_000,
                    cloudPct: 30, snow24hCM: 29, precipMMH: 0, weatherCode: 1)
            default:
                // Clear into the evening, 29 cm of new snow down.
                return ConditionsSample(
                    at: at, tempC: -11, windMS: 2, gustMS: 4, visibilityM: 45_000,
                    cloudPct: 0, snow24hCM: 29, precipMMH: 0, weatherCode: 0)
            }
        }
        var copy = conditions
        copy.hourly = (-13...15).map(sample)
        copy.current = sample(0)
        copy.observedAt = now
        copy.expiresAt = now.addingTimeInterval(12 * 3_600)
        return copy
    }

    /// The same forecast, snowing steadily: moderate snow, 18 cm new, a
    /// little wind and poor visibility, a few degrees below freezing.
    private static func snowing(_ conditions: Conditions) -> Conditions {
        func snow(_ sample: ConditionsSample) -> ConditionsSample {
            var sample = sample
            sample.weatherCode = 73
            sample.snow24hCM = max(sample.snow24hCM, 18)
            sample.precipMMH = max(sample.precipMMH, 1.4)
            sample.tempC = min(sample.tempC, -4)
            sample.visibilityM = min(sample.visibilityM, 1_400)
            sample.cloudPct = 100
            sample.windMS = max(sample.windMS, 4.5)
            return sample
        }
        var copy = conditions
        copy.current = snow(conditions.current)
        copy.hourly = conditions.hourly.map(snow)
        // The fake serves it as fresh for the whole session.
        copy.observedAt = Date()
        copy.expiresAt = Date().addingTimeInterval(12 * 3_600)
        return copy
    }
}

/// The demo's two people, from launch arguments (Debug only): the signed-in
/// skier's name, photo and skis, and the pretend friend's name and photo.
/// Photos are read from the paths given, so personal pictures stay outside
/// the repository and the app bundle.
nonisolated struct DemoCast: Sendable {
    var name: String?
    var photo: Data?
    var ski: String?
    /// `-demoLevel expert`: the skier's level.
    var level: String?
    var friendName: String?
    var friendPhoto: Data?

    /// Where the friend's photo sits in the fake's avatar bucket.
    static let friendPhotoPath = AvatarPath.folder(of: DeveloperSandbox.pretendFriendID) + "/demo-friend.jpg"

    static var fromLaunch: DemoCast {
        let defaults = UserDefaults.standard
        return DemoCast(
            name: defaults.string(forKey: "demoName"),
            photo: defaults.string(forKey: "demoPhoto").flatMap(avatar(at:)),
            ski: defaults.string(forKey: "demoSki"),
            level: defaults.string(forKey: "demoLevel"),
            friendName: defaults.string(forKey: "demoFriendName"),
            friendPhoto: defaults.string(forKey: "demoFriendPhoto").flatMap(avatar(at:)))
    }

    /// The pretend friend's name, when the demo gives one.
    static var friendName: String? {
        guard DebugLaunch.previewData else { return nil }
        return UserDefaults.standard.string(forKey: "demoFriendName")
    }

    /// The pretend friend's photo path, when the demo gives one.
    static var friendAvatarPath: String? {
        guard DebugLaunch.previewData, UserDefaults.standard.string(forKey: "demoFriendPhoto") != nil else {
            return nil
        }
        return friendPhotoPath
    }

    /// A photo file as the app's avatar: the centred square, 512 px, JPEG.
    private static func avatar(at path: String) -> Data? {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            print("demo cast: no photo at \(path): \(error)")
            return nil
        }
        guard let image = AvatarImageProcessor.workingImage(from: data) else { return nil }
        let side = min(image.width, image.height)
        let crop = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        return AvatarImageProcessor.avatarJPEG(from: data, crop: crop)
    }
}

/// `-previewPlaceName "Creekside Gondola top=Cross Roads"` (Debug only): the
/// stage's copy of the mountain shows a place under another name, such as
/// the run it sits on, so a demo's meeting point reads as the story tells
/// it. The bundle is rewritten and re-hashed before the fake publishes it;
/// the graph, and so every route, is unchanged.
nonisolated struct StagedPlaceNames {
    let names: [String: String]

    static var fromLaunch: StagedPlaceNames? {
        guard DebugLaunch.previewData, let spec = UserDefaults.standard.string(forKey: "previewPlaceName") else {
            return nil
        }
        var names: [String: String] = [:]
        for pair in spec.split(separator: "|") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { names[parts[0]] = parts[1] }
        }
        return names.isEmpty ? nil : StagedPlaceNames(names: names)
    }

    /// The bundle with its places renamed, gzipped again, and its new id.
    func apply(to data: Data) -> (data: Data, id: BundleID)? {
        do {
            guard let json = Self.gunzip(data),
                  var document = try JSONSerialization.jsonObject(with: json) as? [String: Any],
                  var places = document["rendezvous"] as? [[String: Any]] else { return nil }
            for index in places.indices {
                if let name = places[index]["name"] as? String, let new = names[name] { places[index]["name"] = new }
            }
            document["rendezvous"] = places
            let out = try JSONSerialization.data(withJSONObject: document)
            guard let zipped = Self.gzip(out), let id = BundleID(rawValue: SHA256.hex(zipped)) else { return nil }
            return (zipped, id)
        } catch {
            print("staged place names: \(error)")
            return nil
        }
    }

    /// The gzip wrapper's raw DEFLATE body, inflated.
    private static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b else { return nil }
        let flags = bytes[3]
        var offset = 10
        if flags & 4 != 0 { offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8 }
        if flags & 8 != 0 { while bytes[offset] != 0 { offset += 1 }; offset += 1 }
        if flags & 16 != 0 { while bytes[offset] != 0 { offset += 1 }; offset += 1 }
        if flags & 2 != 0 { offset += 2 }
        let body = Data(bytes[offset..<(bytes.count - 8)])
        do { return try (body as NSData).decompressed(using: .zlib) as Data } catch {
            print("staged place names: \(error)")
            return nil
        }
    }

    /// Raw DEFLATE in the gzip wrapper: header, body, CRC-32 and length.
    private static func gzip(_ data: Data) -> Data? {
        let body: Data
        do { body = try (data as NSData).compressed(using: .zlib) as Data } catch {
            print("staged place names: \(error)")
            return nil
        }
        var out = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255])
        out.append(body)
        var crc = crc32(data), size = UInt32(truncatingIfNeeded: data.count)
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
            table[index] = value
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
#endif

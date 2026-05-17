//
//  SkiPairView.swift
//  PowderMeet
//
//  Reusable horizontal-ski-pair primitive. Used in three surfaces:
//   • Friend rows (FriendsSheet) — top: name, bottom: skill level
//   • On-mountain status card (ProfileView) — top: resort, bottom: trail,
//     highlight = .onMountain (green) / .offMountain (red).
//   • SkiPickerSheet preview — live preview of the draft selection.
//
//  Topsheet rendering policy:
//    Each PNG in `SkisTopsheets.xcassets` is a 1280×200 canvas with a
//    real product photo of THAT ski cut out via rembg. The actual ski
//    occupies only a portion of the canvas; the rest is transparent.
//    A naive aspect-fit of the canvas leaves the ski floating inside a
//    transparent box that doesn't match the row, so we trim each image
//    to its true alpha bbox once at first sight (cached in
//    `TopsheetCache`) and render that trimmed bitmap aspect-fit into
//    the row's available space. Result: each ski's displayed shape is
//    its real shape, sized to fit cleanly.
//
//  Label legibility:
//    White text with a strong dark drop-shadow over the ski body.
//    Simple, no plate, no badge — relies on the topsheet PNG being
//    busy enough that the shadowed white text reads cleanly.
//
//  Fallback (no bundled topsheet): a clean horizontal pill, no fake
//  artwork, no procedural patterns. Same label treatment.
//
//  All skis render at the same row HEIGHT regardless of caller — true
//  aspect ratio drives WIDTH within the row, so a row of SkiPairViews
//  lines up vertically while letting per-ski geometry vary horizontally.
//

import SwiftUI
import UIKit

struct SkiPairView: View {
    let topLabel: String
    let bottomLabel: String
    var highlight: Highlight = .none
    /// The picked catalog row. Resolves to a bundled topsheet image when
    /// one exists. Nil → see `showFallback`.
    var entry: SkiCatalogEntry? = nil
    /// When true (default), `entry == nil` falls through to a dark
    /// horizontal pill — used in the picker preview where "no ski
    /// chosen yet" deserves a visible placeholder. Friend rows pass
    /// `false` so a friend whose ski catalog row hasn't hydrated yet
    /// (or who simply hasn't picked one) just shows labels in empty
    /// space rather than flickering against a fake default.
    var showFallback: Bool = true

    enum Highlight {
        case none
        case onMountain
        case offMountain
    }

    /// Single ski body height. Pair height = 2 * skiHeight + spacing.
    private let skiHeight: CGFloat = 36
    private let spacing: CGFloat = 8

    /// Total vertical extent of the pair, exposed so callers that
    /// place an avatar circle alongside (FriendsSheet friend rows,
    /// ProfileView live-status card) can size the avatar to match —
    /// the round avatar + pill ski-pair read as one visual unit only
    /// when their heights line up.
    static let defaultPairHeight: CGFloat = 36 * 2 + 8

    private var assetKey: String? { entry?.topsheetAssetKey }

    var body: some View {
        VStack(spacing: spacing) {
            HorizontalSkiView(
                label: topLabel,
                weight: .bold,
                height: skiHeight,
                assetKey: assetKey,
                highlight: highlight,
                showFallback: showFallback
            )
            HorizontalSkiView(
                label: bottomLabel,
                weight: .medium,
                height: skiHeight,
                assetKey: assetKey,
                highlight: highlight,
                showFallback: showFallback
            )
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - One ski

/// Single topsheet view. Renders the alpha-trimmed PNG aspect-fit into
/// the row's available space, then overlays a label plate centered on
/// the ski body.
private struct HorizontalSkiView: View {
    let label: String
    let weight: Font.Weight
    let height: CGFloat
    let assetKey: String?
    var highlight: SkiPairView.Highlight = .none
    var showFallback: Bool = true

    /// Resolved topsheet for `assetKey`. Seeded synchronously from
    /// `TopsheetCache.peek` (non-blocking) so prewarmed assets paint
    /// on the first frame, and faulted in via `.task(id: assetKey)`
    /// when the cache misses — keeps the 5–50ms alpha-trim scan off
    /// the main thread. Previous behavior was a computed property
    /// that called the synchronous `load`, which blocked the first
    /// render of any friend's never-seen ski (the "preview glitches
    /// out" symptom on scroll / accept-friend transitions).
    @State private var trimmed: TopsheetCache.Entry?

    var body: some View {
        GeometryReader { proxy in
            let availableW = proxy.size.width
            let availableH = proxy.size.height
            let dims = computeDims(
                availableW: availableW,
                availableH: availableH,
                aspect: trimmed?.aspectRatio
            )

            ZStack {
                if let trimmed {
                    Image(uiImage: trimmed.image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: dims.width, height: dims.height)
                        // Subtle dark halo gives the alpha edge definition
                        // against any parent background.
                        .shadow(color: Color.black.opacity(0.55), radius: 1.5, x: 0, y: 0)
                        // Cross-fade between cached and freshly-faulted
                        // topsheets so the post-async swap doesn't read
                        // as a hard pop. ~120ms is fast enough to feel
                        // instant when prewarmed (the .onAppear branch
                        // below seeds .peek synchronously so prewarmed
                        // assets skip the fade entirely).
                        .transition(.opacity.animation(.easeOut(duration: 0.12)))
                } else if showFallback {
                    // No ski chosen → the PowderMeet house ski (a real
                    // branded topsheet), not a flat empty pill. Reads
                    // as a product, not a broken state. Picker preview
                    // ("PICK A SKI") and any owner-without-a-ski use it.
                    Image("powdermeet-default")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: dims.width, height: dims.height)
                        .shadow(color: Color.black.opacity(0.55), radius: 1.5, x: 0, y: 0)
                }
                // No-fallback case: just the labels float over empty
                // space. Friend rows use this to avoid flickering
                // against a fake "default" pill while their catalog
                // entry hydrates.

                // Label centered over the body. White fill with a 1px
                // black outline (four cardinal shadows at radius 0).
                // White-on-outline reads cleanly against any topsheet
                // artwork regardless of the active theme — the ski
                // text intentionally stays neutral, not accent-tinted.
                Text(label.uppercased())
                    .font(.system(size: 12, weight: weight, design: .monospaced))
                    .foregroundColor(.white)
                    .tracking(1.0)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .shadow(color: .black, radius: 0, x: 1, y: 0)
                    .shadow(color: .black, radius: 0, x: -1, y: 0)
                    .shadow(color: .black, radius: 0, x: 0, y: 1)
                    .shadow(color: .black, radius: 0, x: 0, y: -1)
                    .padding(.horizontal, height * 0.6)
            }
            .frame(width: availableW, height: availableH, alignment: .center)
        }
        .frame(height: height)
        // Synchronous fast path: if prewarm already seeded the cache,
        // paint the topsheet on the first frame with no animation
        // (peek is a dictionary lookup, doesn't block). If not, leave
        // `trimmed` nil and let `.task` fault it in below.
        .onAppear {
            if let key = assetKey, trimmed == nil {
                trimmed = TopsheetCache.peek(key)
            }
        }
        // Async fallback: fault the topsheet off-thread when the
        // cache missed. `.task(id:)` cancels the old task when the
        // assetKey flips (friend re-skis, list re-orders) so we never
        // assign a stale image into a recycled view.
        .task(id: assetKey) {
            guard let key = assetKey else {
                trimmed = nil
                return
            }
            // Re-peek under task in case prewarm landed between view
            // construction and task fire (common when the picker
            // selection lands a few ms before the row appears).
            if let hit = TopsheetCache.peek(key) {
                if trimmed?.aspectRatio != hit.aspectRatio { trimmed = hit }
                return
            }
            if TopsheetCache.isKnownMiss(key) {
                if trimmed != nil { trimmed = nil }
                return
            }
            let entry = await TopsheetCache.loadAsync(key)
            if Task.isCancelled { return }
            // Animate the swap so a cache-miss fault doesn't pop.
            withAnimation(.easeOut(duration: 0.12)) {
                trimmed = entry
            }
        }
    }

    /// Aspect-fit a known ratio into the row. When the asset's true
    /// ratio is missing (no bundled topsheet), use a 9:1 pill — close
    /// to the proportions of a real ski profile so the placeholder
    /// reads as "ski-shaped."
    private func computeDims(
        availableW: CGFloat,
        availableH: CGFloat,
        aspect: CGFloat?
    ) -> (width: CGFloat, height: CGFloat) {
        let ratio = aspect ?? 9.0
        let widthIfHeightFills = availableH * ratio
        if widthIfHeightFills <= availableW {
            return (widthIfHeightFills, availableH)
        }
        // Width is the binding constraint; shrink height to match.
        return (availableW, availableW / ratio)
    }
}

// MARK: - Topsheet alpha-trim cache

/// Trims each topsheet PNG to its alpha bbox once at first sight, then
/// returns the trimmed UIImage + its true aspect ratio. Without this,
/// every ski renders inside the 1280×200 canvas (a uniform "standard
/// silhouette" feel) regardless of the actual ski geometry inside.
///
/// Lookups happen on the main thread during view construction, so
/// trimming is synchronous. PNG scan is ~256k pixels per asset → low
/// single-digit ms on modern iPhone; cached after first hit.
enum TopsheetCache {
    struct Entry {
        let image: UIImage
        /// width / height of the trimmed bitmap.
        let aspectRatio: CGFloat
    }

    @MainActor private static var cache: [String: Entry] = [:]
    @MainActor private static var negative: Set<String> = []

    /// Non-blocking lookup. Returns hit if cached (or known-miss),
    /// `nil` if the key hasn't been processed yet. Safe to call from
    /// a SwiftUI body — never does the alpha-trim work itself.
    /// Pairs with `loadAsync(_:)` for the missing-key path.
    @MainActor
    static func peek(_ key: String) -> Entry? {
        cache[key]
    }

    /// True iff `peek` will never return non-nil — either because the
    /// PNG isn't in the bundle or the alpha-trim returned an empty
    /// bbox. Used by views to fall through to the fallback pill
    /// immediately instead of holding empty space waiting on a load
    /// that will never resolve.
    @MainActor
    static func isKnownMiss(_ key: String) -> Bool {
        negative.contains(key)
    }

    @MainActor
    static func load(_ key: String) -> Entry? {
        if let hit = cache[key] { return hit }
        if negative.contains(key) { return nil }

        guard let raw = UIImage(named: key), let cg = raw.cgImage else {
            negative.insert(key)
            return nil
        }
        guard let trimmed = trimmedToAlpha(cg) else {
            negative.insert(key)
            return nil
        }
        let entry = Entry(
            image: UIImage(cgImage: trimmed, scale: raw.scale, orientation: raw.imageOrientation),
            aspectRatio: CGFloat(trimmed.width) / max(CGFloat(trimmed.height), 1)
        )
        cache[key] = entry
        return entry
    }

    /// Async variant that runs the alpha-trim on a utility task,
    /// then writes the result on the main actor. Used by views to
    /// fault in a topsheet that wasn't covered by `prewarm` without
    /// blocking the main thread for the scan. Idempotent — re-calls
    /// for the same key after a hit short-circuit on the cache check.
    @MainActor
    static func loadAsync(_ key: String) async -> Entry? {
        if let hit = cache[key] { return hit }
        if negative.contains(key) { return nil }

        let result = await Task.detached(priority: .userInitiated) {
            () -> (key: String, entry: Entry?) in
            guard let raw = UIImage(named: key), let cg = raw.cgImage else {
                return (key, nil)
            }
            guard let trimmed = trimmedToAlpha(cg) else {
                return (key, nil)
            }
            return (key, Entry(
                image: UIImage(cgImage: trimmed, scale: raw.scale, orientation: raw.imageOrientation),
                aspectRatio: CGFloat(trimmed.width) / max(CGFloat(trimmed.height), 1)
            ))
        }.value

        if let entry = result.entry {
            cache[result.key] = entry
            return entry
        } else {
            negative.insert(result.key)
            return nil
        }
    }

    /// Background-scan a batch of asset keys and seed the cache so
    /// subsequent `load(_:)` calls hit instantly. Without this,
    /// the first time a friend's ski renders blocks the main thread
    /// for ~5–50ms while the alpha-bbox scan runs synchronously
    /// inside the view body — perceptible as a delay on accept-
    /// friend-request transitions when the new friend's ski has
    /// never been seen before. Each scan runs on a detached utility
    /// task; the cache write hops back to the main actor.
    static func prewarm(keys: [String]) async {
        for key in keys {
            // Cheap dedup against already-seen keys (cache hit or
            // negative-cached miss). Skipping these keeps prewarm
            // idempotent across multiple catalog refreshes.
            let alreadyKnown = await MainActor.run { cache[key] != nil || negative.contains(key) }
            if alreadyKnown { continue }

            let result = await Task.detached(priority: .utility) {
                () -> (key: String, entry: Entry?) in
                guard let raw = UIImage(named: key), let cg = raw.cgImage else {
                    return (key, nil)
                }
                guard let trimmed = trimmedToAlpha(cg) else {
                    return (key, nil)
                }
                return (key, Entry(
                    image: UIImage(cgImage: trimmed, scale: raw.scale, orientation: raw.imageOrientation),
                    aspectRatio: CGFloat(trimmed.width) / max(CGFloat(trimmed.height), 1)
                ))
            }.value

            await MainActor.run {
                if let entry = result.entry {
                    cache[result.key] = entry
                } else {
                    negative.insert(result.key)
                }
            }
        }
    }

    /// Scan the alpha channel, find the tight bounding box of opaque
    /// pixels, return the cropped CGImage. `threshold` ignores
    /// near-zero alpha noise from the rembg cut. Pure function —
    /// safe to call from any actor context.
    nonisolated static func trimmedToAlpha(_ image: CGImage) -> CGImage? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }

        var alpha = [UInt8](repeating: 0, count: w * h)
        let space = CGColorSpaceCreateDeviceGray()
        let info = CGImageAlphaInfo.alphaOnly.rawValue
        guard let ctx = alpha.withUnsafeMutableBytes({ buffer -> CGContext? in
            guard let base = buffer.baseAddress else { return nil }
            return CGContext(
                data: base,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w,
                space: space,
                bitmapInfo: info
            )
        }) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let threshold: UInt8 = 16
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where alpha[row + x] > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let bbox = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return image.cropping(to: bbox)
    }
}

#if DEBUG
#Preview("Silhouette categories") {
    let entries: [(brand: String, model: String, cat: String?, waist: Int?, key: String?)] = [
        ("Atomic", "Bent 110", "powder", 110, "atomic-bent-110"),
        ("Atomic", "Redster G9", "race", 68, "atomic-redster-g9-rvsk-s"),
        ("Black Crows", "Atris", "powder", 108, "black-crows-atris"),
        ("Salomon", "QST 106", "all-mountain", 106, "salomon-qst-106"),
        ("Volkl", "Kendo 88", "all-mountain", 88, "volkl-kendo-88"),
        ("DPS", "Pagoda Tour 112", "touring", 112, "dps-pagoda-tour-112"),
        ("(no asset)", "Fallback", nil, nil, nil),
    ]
    return ScrollView {
        VStack(spacing: 16) {
            SkiPairView(topLabel: "PowderMeet", bottomLabel: "House Default")
            ForEach(entries.indices, id: \.self) { i in
                let e = entries[i]
                let entry = SkiCatalogEntry(
                    id: UUID(),
                    brand: e.brand,
                    model: e.model,
                    category: e.cat,
                    waistWidthMm: e.waist,
                    topsheetAssetKey: e.key
                )
                SkiPairView(
                    topLabel: e.brand + " " + e.model,
                    bottomLabel: (e.cat ?? "all-mountain").uppercased(),
                    entry: entry
                )
            }
            SkiPairView(
                topLabel: "Highlight: ON MOUNTAIN",
                bottomLabel: "BLUE GROOMER",
                highlight: .onMountain,
                entry: SkiCatalogEntry(
                    id: UUID(),
                    brand: "Atomic",
                    model: "Bent 110",
                    category: "powder",
                    waistWidthMm: 110,
                    topsheetAssetKey: "atomic-bent-110"
                )
            )
        }
        .padding()
    }
    .background(HUDTheme.mapBackground)
}
#endif

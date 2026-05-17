//
//  CachedAvatarView.swift
//  PowderMeet
//
//  Drop-in replacement for `AsyncImage` for avatar URLs. SwiftUI's
//  AsyncImage doesn't cache decoded UIImages across view re-mounts,
//  so a friend row that scrolls off and back on inside a LazyVStack
//  flashes its placeholder while the fetch resolves again — even if
//  the URLCache hit is "instant," AsyncImage's internal phase
//  machine still walks .empty → .success asynchronously.
//
//  This view holds a process-wide `[String: UIImage]` cache. Subsequent
//  loads of the same URL return immediately, so rows that re-mount
//  during scroll come back fully painted with no flicker.
//
//  Used by FriendsSheet (friend rows + pending requests + search
//  results) where row churn during scroll + presence updates was
//  reading as a visual "bug out." Other surfaces (ProfileView's
//  own-avatar) keep their AsyncImage — single static view, no
//  re-mount churn there.
//

import SwiftUI
import UIKit

struct CachedAvatarView<Placeholder: View>: View {
    let urlString: String?
    let size: CGFloat
    let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var loadedURL: String?

    init(
        urlString: String?,
        size: CGFloat,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.urlString = urlString
        self.size = size
        self.placeholder = placeholder
        // Synchronous cache lookup at init time so the FIRST paint
        // already shows the avatar — without this, a row that just
        // re-mounted (LazyVStack virtualization, snapshot apply,
        // tab switch) would flash the placeholder for one frame
        // before the .task closure ran the cache hit. Fresh @State
        // initialized from cache = no placeholder flash.
        if let urlString, let cached = AvatarCache.shared.image(for: urlString) {
            self._image = State(initialValue: cached)
            self._loadedURL = State(initialValue: urlString)
        } else {
            self._image = State(initialValue: nil)
            self._loadedURL = State(initialValue: nil)
        }
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder()
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: urlString) {
            guard let urlString, let url = URL(string: urlString) else {
                image = nil
                loadedURL = nil
                return
            }
            // Init seeded `image` from cache when possible. Re-check
            // here so url-change events that hit a cache that filled
            // since init still paint instantly without re-fetching.
            if loadedURL == urlString, image != nil { return }
            if let cached = AvatarCache.shared.image(for: urlString) {
                image = cached
                loadedURL = urlString
                return
            }
            // Cache miss — fetch, decode, cache, paint.
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let ui = UIImage(data: data) else { return }
                AvatarCache.shared.set(ui, for: urlString)
                if !Task.isCancelled {
                    image = ui
                    loadedURL = urlString
                }
            } catch {
                // Network failure leaves the placeholder showing.
                // No retry here — re-renders will retry naturally.
            }
        }
    }
}

/// Process-wide avatar cache. NSCache evicts under memory pressure
/// so we never accumulate unbounded UIImages.
@MainActor
final class AvatarCache {
    static let shared = AvatarCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 200
    }

    func image(for url: String) -> UIImage? {
        cache.object(forKey: url as NSString)
    }

    func set(_ image: UIImage, for url: String) {
        cache.setObject(image, forKey: url as NSString)
    }
}

import AppCore
import PowderMeetAPI
import SwiftUI
import UIKit

/// A person's profile photo in a circle, or their initials until there is one.
/// The one avatar view of the app: profile card, friend rows, requests, blocked
/// list, contact matches, the friend card and the PowderMeet tab's friends.
///
/// `path` is the object path in the `avatars` bucket (`Profile.avatarURL`,
/// `SocialSnapshot.Person.avatarURL`, `UserMatch.avatarURL`). For the signed-in
/// user the profile's own path is used whatever is passed, so a new photo shows
/// everywhere at once. Photos come from `AppModel.avatarImages` (memory, then
/// disk, then one download per path), so a row that scrolls back in paints at
/// once.
struct AvatarView: View {
    @Environment(AppModel.self) private var model

    let userID: UUID
    let path: String?
    let name: String
    var size: CGFloat = 36

    @State private var loaded: UIImage?
    @State private var loadedPath: String?

    init(userID: UUID, path: String?, name: String, size: CGFloat = 36) {
        self.userID = userID
        self.path = path
        self.name = name
        self.size = size
    }

    private var currentPath: String? {
        if let me = model.photoOwner, me.id == userID { return me.avatarURL }
        #if DEBUG
        // The demo's pretend friend has a photo (`-demoFriendPhoto`).
        if userID == DeveloperSandbox.pretendFriendID, let demo = DemoCast.friendAvatarPath { return demo }
        #endif
        return path
    }

    var body: some View {
        let path = currentPath
        // A cache hit paints on the first frame; a miss shows the initials until
        // the task below has the photo.
        let image = path.flatMap { model.avatarImages.cached($0) } ?? (loadedPath == path ? loaded : nil)
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(HUDTheme.cardBorder, lineWidth: 1))
            } else {
                InitialsAvatar(name: name, size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: path) {
            guard let path else {
                loaded = nil
                loadedPath = nil
                return
            }
            if model.avatarImages.cached(path) != nil { return }
            let image = await model.avatarImages.image(for: path)
            guard !Task.isCancelled, let image else { return }
            loaded = image
            loadedPath = path
        }
    }
}

/// Decoded profile photos in memory, over `AvatarStore` on disk. Owned by
/// `AppModel` (no singleton) and emptied at sign-out with the disk store.
@MainActor
final class AvatarImages {
    private let store: AvatarStore
    private let backend: any BackendClient
    private let memory = NSCache<NSString, UIImage>()

    init(store: AvatarStore, backend: any BackendClient) {
        self.store = store
        self.backend = backend
        memory.countLimit = 150
    }

    func cached(_ path: String) -> UIImage? {
        memory.object(forKey: path as NSString)
    }

    /// The photo at `path`, or nil when it cannot be had now. A 512 px JPEG
    /// decodes in a millisecond or two, so it is done here.
    func image(for path: String) async -> UIImage? {
        if let hit = cached(path) { return hit }
        guard let data = await store.data(for: path, from: backend), let image = UIImage(data: data) else {
            return nil
        }
        memory.setObject(image, forKey: path as NSString)
        return image
    }

    /// The user's own new photo, shown before any download.
    func keep(_ image: UIImage, for path: String) {
        memory.setObject(image, forKey: path as NSString)
    }

    func clear() {
        memory.removeAllObjects()
    }
}

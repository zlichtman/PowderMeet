import AppCore
import MapScene
import MapboxAdapter
import MountainCore
import PowderMeetAPI
import SwiftUI

/// The map itself, with its loading gate and load-error card over it. It fills
/// whatever it is given (the whole tab, under the bars); `obscured` says how much
/// of that the floating controls cover.
struct MapSurface: View {
    let resort: ResortModel
    let resortName: String?
    var obscured = MapObscuredArea()
    /// Settings → Maps → Fly in: the long orbit onto a newly opened mountain.
    var flyIn = false
    /// The weather at the timeline's hour (`ResortModel.weatherAtDisplayTime`),
    /// and whether its snow may move (the map is in view).
    var weather = WeatherEffect.clear
    var weatherMoves = false

    @Environment(AppModel.self) private var model
    /// The people markers' photos (`MapPhotos`), loaded from the avatar cache.
    @State private var photos = MapPhotos()

    /// Whose photo the map should show, and from where: you, and each friend
    /// on the mountain who has one.
    private var photoPaths: [String: String] {
        var paths: [String: String] = [:]
        if let me = model.profile?.avatarURL { paths[MapPhotos.me] = me }
        for id in resort.friends.keys {
            var path = model.person(id)?.avatarURL
            #if DEBUG
            if id == DeveloperSandbox.pretendFriendID { path = DemoCast.friendAvatarPath ?? path }
            #endif
            if let path { paths[id.uuidString] = path }
        }
        return paths
    }

    var body: some View {
        ZStack {
            HUDTheme.mapBackground

            switch resort.state {
            case .loadingBundle:
                MapLoadingView(resortName: resortName)
                    .transition(.opacity)
            case .ready(let ready):
                ResortMap(
                    scene: resort.scene, bundle: ready.bundle, obscured: obscured,
                    flyIn: flyIn,
                    weather: weather, weatherMoves: weatherMoves,
                    photos: photos
                ) { event in
                    resort.handleMap(event)
                }
                // One map per bundle: its streams are consumed when it is made.
                .id(ready.bundle.id)
                if resort.scene.styleFailed {
                    errorCard(
                        message: "The map imagery couldn't be loaded. Trails and routing still work.",
                        retry: { resort.reloadMapStyle() }
                    )
                    .padding(.horizontal, GlassLayout.inset)
                }
            case .failed(let failure):
                errorCard(
                    message: PowderMeetError.data(failure).userMessage, retry: { resort.retry() }
                )
                .padding(.horizontal, GlassLayout.inset)
            }
        }
        .animation(.easeOut(duration: 0.25), value: resort.state)
        .task(id: photoPaths) {
            var images: [String: UIImage] = [:]
            for (key, path) in photoPaths {
                if let image = await model.avatarImages.image(for: path) { images[key] = image }
            }
            guard !Task.isCancelled else { return }
            photos = MapPhotos(images)
        }
    }

    private func errorCard(message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("The map didn't load")
                    .textRole(.bodyEmph)
                    .foregroundColor(HUDTheme.primaryText)

                Text(message)
                    .textRole(.label)
                    .foregroundColor(HUDTheme.secondaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PrimaryButton(title: "Retry", systemImage: "arrow.clockwise", action: retry)
        }
        .glassCard()
    }
}

/// The resort name over one line that says what is happening. It names no
/// step, since the screen cannot tell which one is under way.
private struct MapLoadingView: View {
    let resortName: String?

    var body: some View {
        ZStack {
            HUDTheme.mapBackground.ignoresSafeArea()

            VStack(spacing: 14) {
                if let resortName, !resortName.isEmpty {
                    Text(resortName)
                        .textRole(.title)
                        .foregroundColor(HUDTheme.primaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 32)
                }
                Text("Loading the map")
                    .textRole(.label)
                    .foregroundColor(HUDTheme.secondaryText)
            }
        }
    }
}

/// Hosts the Mapbox view. It reads nothing observable but the map look; new
/// scenes reach the map through the stream, and only the covered area and the
/// look arrive as values.
private struct ResortMap: View {
    let scene: MapSceneCoordinator
    let bundle: ResortBundle
    let obscured: MapObscuredArea
    let flyIn: Bool
    let weather: WeatherEffect
    let weatherMoves: Bool
    let photos: MapPhotos
    let onEvent: @MainActor (MapEvent) -> Void
    /// The body runs again whenever `obscured` changes; the streams are asked
    /// for once, because each request registers a new one with the coordinator.
    @State private var streams = MapStreams()

    var body: some View {
        let pair = streams.of(scene)
        PowderMeetMapView(
            models: pair.models, commands: pair.commands,
            initialFrame: SceneFrame(bundle: bundle), obscured: obscured,
            flyIn: flyIn, weather: weather, weatherMoves: weatherMoves,
            // The one observable read here: a new look or theme repaints
            // the map in place (`MapboxMapController.setAppearance`).
            appearance: ThemeManager.shared.mapAppearance, photos: photos,
            attributionHidden: DebugLaunch.demoCapture, log: scene.log,
            onEvent: onEvent
        )
        .accessibilityLabel("Mountain map")
    }
}

/// The one pair of streams a map view is made with.
@MainActor
private final class MapStreams {
    private var made: (models: AsyncStream<RenderModel>, commands: AsyncStream<MapCommand>)?

    func of(_ scene: MapSceneCoordinator) -> (models: AsyncStream<RenderModel>, commands: AsyncStream<MapCommand>) {
        if let made { return made }
        let new = (models: scene.models(), commands: scene.commands())
        made = new
        return new
    }
}

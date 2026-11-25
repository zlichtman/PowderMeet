import MapScene
@preconcurrency import MapboxMaps
import PMLogging
import SwiftUI

/// The map, for SwiftUI. Give it the stream of `RenderModel`s the resort session's
/// scene coordinator produces and a stream of camera commands; it reports taps and
/// camera rest through `onEvent`. Keep its identity stable (do not rebuild it on
/// state changes): the streams are consumed once, when the view is made.
public struct PowderMeetMapView: UIViewRepresentable {
    private let models: AsyncStream<RenderModel>
    private let commands: AsyncStream<MapCommand>
    private let initialFrame: SceneFrame?
    private let obscured: MapObscuredArea
    private let flyIn: Bool
    private let weather: WeatherEffect
    private let weatherMoves: Bool
    private let appearance: MapAppearance
    private let photos: MapPhotos
    private let attributionHidden: Bool
    private let log: PMLog
    private let onEvent: @MainActor (MapEvent) -> Void

    public init(
        models: AsyncStream<RenderModel>,
        commands: AsyncStream<MapCommand> = AsyncStream { $0.finish() },
        initialFrame: SceneFrame? = nil,
        obscured: MapObscuredArea = MapObscuredArea(),
        flyIn: Bool = false,
        weather: WeatherEffect = .clear,
        weatherMoves: Bool = false,
        appearance: MapAppearance = .standard,
        photos: MapPhotos = MapPhotos(),
        attributionHidden: Bool = false,
        log: PMLog = PMLog(),
        onEvent: @escaping @MainActor (MapEvent) -> Void
    ) {
        self.models = models
        self.commands = commands
        self.initialFrame = initialFrame
        self.obscured = obscured
        self.flyIn = flyIn
        self.weather = weather
        self.weatherMoves = weatherMoves
        self.appearance = appearance
        self.photos = photos
        self.attributionHidden = attributionHidden
        self.log = log
        self.onEvent = onEvent
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            controller: MapboxMapController(initialFrame: initialFrame, log: log), onEvent: onEvent)
    }

    public func makeUIView(context: Context) -> MapView {
        context.coordinator.controller.setObscured(obscured)
        context.coordinator.controller.setFlyIn(flyIn)
        context.coordinator.controller.setWeather(weather, moves: weatherMoves)
        context.coordinator.controller.setAppearance(appearance)
        context.coordinator.controller.setPhotos(photos)
        context.coordinator.controller.setAttributionHidden(attributionHidden)
        context.coordinator.start(models: models, commands: commands)
        return context.coordinator.controller.mapView
    }

    public func updateUIView(_ mapView: MapView, context: Context) {
        context.coordinator.onEvent = onEvent
        context.coordinator.controller.setObscured(obscured)
        context.coordinator.controller.setFlyIn(flyIn)
        context.coordinator.controller.setWeather(weather, moves: weatherMoves)
        context.coordinator.controller.setAppearance(appearance)
        context.coordinator.controller.setPhotos(photos)
        context.coordinator.controller.setAttributionHidden(attributionHidden)
    }

    public static func dismantleUIView(_ mapView: MapView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    public final class Coordinator {
        /// For a caller that needs the live camera.
        public let controller: MapboxMapController
        var onEvent: @MainActor (MapEvent) -> Void
        private var tasks: [Task<Void, Never>] = []

        init(controller: MapboxMapController, onEvent: @escaping @MainActor (MapEvent) -> Void) {
            self.controller = controller
            self.onEvent = onEvent
        }

        func start(models: AsyncStream<RenderModel>, commands: AsyncStream<MapCommand>) {
            let controller = controller
            tasks = [
                Task { for await model in models { controller.apply(model) } },
                Task { for await command in commands { controller.send(command) } },
                Task { [weak self] in
                    for await event in controller.events { self?.onEvent(event) }
                },
            ]
        }

        func stop() {
            tasks.forEach { $0.cancel() }
            tasks = []
            controller.shutdown()
        }
    }
}

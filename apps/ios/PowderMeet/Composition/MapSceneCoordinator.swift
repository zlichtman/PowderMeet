import Foundation
import MapScene
import MapboxAdapter
import Observation
import PMLogging

/// Builds scenes one at a time off the main actor, reusing the last model's static
/// geometry so a status or position change rebuilds nothing heavy.
private actor SceneWorker {
    private var previous: RenderModel?

    func build(_ input: RenderInput) -> RenderModel {
        let model = SceneBuilder.build(input, reusing: previous)
        previous = model
        return model
    }
}

/// Turns the resort and meet projections into `RenderModel`s for the map
/// (`specs/07-CLIENT.md` section 3). The spec places this inside `ResortSession`;
/// `AppCore` does not have it yet, so it lives in the composition layer and is
/// owned by `ResortModel`. Views hand its streams to the map and never build a
/// scene themselves.
@Observable
final class MapSceneCoordinator {
    /// The scene on the map, for readers that need closure truth (the trail card).
    private(set) var model: RenderModel?
    /// The map style could not be loaded after the adapter's own retries.
    private(set) var styleFailed = false

    let log: PMLog

    @ObservationIgnored private let worker = SceneWorker()
    @ObservationIgnored private var pending: RenderInput?
    @ObservationIgnored private var building: Task<Void, Never>?
    @ObservationIgnored private var modelSinks: [UUID: AsyncStream<RenderModel>.Continuation] = [:]
    @ObservationIgnored private var commandSinks: [UUID: AsyncStream<MapCommand>.Continuation] = [:]
    /// Commands that act on a scene still being built (framing a new route).
    @ObservationIgnored private var afterNextScene: [MapCommand] = []

    init(log: PMLog) {
        self.log = log
    }

    /// Asks for a new scene. Inputs that arrive while one is being built replace
    /// each other; only the newest is built next.
    func show(_ input: RenderInput) {
        pending = input
        guard building == nil else { return }
        building = Task { [weak self, worker] in
            while !Task.isCancelled {
                guard let next = self?.takePending() else { break }
                let started = ContinuousClock.now
                let built = await worker.build(next)
                guard !Task.isCancelled else { return }
                self?.noteFirstBuild(since: started)
                self?.publish(built)
            }
            self?.building = nil
        }
    }

    /// One line per map for the launch timeline: the first scene is the only
    /// build that makes geometry.
    private func noteFirstBuild(since started: ContinuousClock.Instant) {
        guard model == nil else { return }
        let elapsed = ContinuousClock.now - started
        let ms = Int(elapsed.components.seconds) * 1_000
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        log.info(.map, "first scene built in \(ms) ms")
    }

    private func takePending() -> RenderInput? {
        defer { pending = nil }
        return pending
    }

    private func publish(_ built: RenderModel) {
        model = built
        for sink in modelSinks.values { sink.yield(built) }
        // Only once no newer input is waiting: that one is the scene meant.
        guard pending == nil, !afterNextScene.isEmpty else { return }
        let commands = afterNextScene
        afterNextScene = []
        for command in commands { send(command) }
    }

    /// Sends a command once the scene for the latest input is published, for a
    /// command that reads that scene (`showRoute` frames its routes).
    func sendAfterNextScene(_ command: MapCommand) {
        if building == nil, pending == nil {
            send(command)
        } else {
            afterNextScene.append(command)
        }
    }

    /// Scenes for one map view: the current one first, then each new one. A map
    /// that falls behind gets the newest only.
    func models() -> AsyncStream<RenderModel> {
        let id = UUID()
        let (stream, sink) = AsyncStream.makeStream(of: RenderModel.self, bufferingPolicy: .bufferingNewest(1))
        if let model { sink.yield(model) }
        modelSinks[id] = sink
        sink.onTermination = { [weak self] _ in
            Task { @MainActor in self?.modelSinks[id] = nil }
        }
        return stream
    }

    func commands() -> AsyncStream<MapCommand> {
        let id = UUID()
        let (stream, sink) = AsyncStream.makeStream(of: MapCommand.self, bufferingPolicy: .bufferingNewest(8))
        commandSinks[id] = sink
        sink.onTermination = { [weak self] _ in
            Task { @MainActor in self?.commandSinks[id] = nil }
        }
        return stream
    }

    func send(_ command: MapCommand) {
        if command == .reloadStyle { styleFailed = false }
        for sink in commandSinks.values { sink.yield(command) }
    }

    func styleLoaded() { styleFailed = false }
    func styleDidFail() { styleFailed = true }

    func stop() {
        building?.cancel()
        building = nil
        pending = nil
        afterNextScene = []
        for sink in modelSinks.values { sink.finish() }
        for sink in commandSinks.values { sink.finish() }
        modelSinks = [:]
        commandSinks = [:]
    }
}

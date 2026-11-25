import Foundation
import Synchronization

/// A bounded LRU of solve results keyed by `SolveInput`. Owned by the caller;
/// the solver itself keeps no cache.
public final class SolveCache: Sendable {
    private struct State {
        var order: [SolveInput] = []
        var store: [SolveInput: Result<MeetOptions, SolveFailure>] = [:]
    }

    private let capacity: Int
    private let state = Mutex(State())

    public init(capacity: Int = 128) {
        self.capacity = max(1, capacity)
    }

    /// The cached result for `input`, computing and storing it on a miss. The
    /// lock is not held while computing, so two concurrent misses may both solve;
    /// the results are identical by construction.
    public func value(
        for input: SolveInput, compute: () -> Result<MeetOptions, SolveFailure>
    ) -> Result<MeetOptions, SolveFailure> {
        // The key is the input as the solver sees it, so solves in the same
        // 60 s bucket share an entry.
        var key = input
        key.at = Quantize.time(input.at)
        let cached = state.withLock { state -> Result<MeetOptions, SolveFailure>? in
            guard let hit = state.store[key] else { return nil }
            if let index = state.order.firstIndex(of: key) { state.order.remove(at: index) }
            state.order.append(key)
            return hit
        }
        if let cached { return cached }

        let result = compute()
        state.withLock { state in
            if state.store.updateValue(result, forKey: key) == nil { state.order.append(key) }
            while state.order.count > capacity {
                state.store.removeValue(forKey: state.order.removeFirst())
            }
        }
        return result
    }

    public func removeAll() {
        state.withLock { $0 = State() }
    }
}

//
//  BinaryHeap.swift
//  PowderMeet
//
//  Generic min-heap for O(log n) insert / extractMin.
//  Used by MeetingPointSolver for Dijkstra's priority queue.
//

import Foundation

// `nonisolated` — used as Dijkstra's priority queue inside the solver's
// detached compute task. Pure value type.
nonisolated struct BinaryHeap<Element> {
    private var storage: [Element] = []
    private let comparator: (Element, Element) -> Bool

    var isEmpty: Bool { storage.isEmpty }
    var count: Int { storage.count }

    init(comparator: @escaping (Element, Element) -> Bool) {
        self.comparator = comparator
    }

    // MARK: - Insert O(log n)

    mutating func insert(_ element: Element) {
        storage.append(element)
        siftUp(from: storage.count - 1)
    }

    // MARK: - Extract Min O(log n)

    mutating func extractMin() -> Element? {
        guard !storage.isEmpty else { return nil }
        if storage.count == 1 { return storage.removeLast() }
        let min = storage[0]
        storage[0] = storage.removeLast()
        siftDown(from: 0)
        return min
    }

    // MARK: - Peek O(1)

    func peek() -> Element? { storage.first }

    // MARK: - Heap Operations

    private mutating func siftUp(from index: Int) {
        var i = index
        while i > 0 {
            let parent = (i - 1) / 2
            guard comparator(storage[i], storage[parent]) else { break }
            storage.swapAt(i, parent)
            i = parent
        }
    }

    private mutating func siftDown(from index: Int) {
        var i = index
        let count = storage.count
        while true {
            let left = 2 * i + 1
            let right = 2 * i + 2
            var smallest = i

            if left < count && comparator(storage[left], storage[smallest]) {
                smallest = left
            }
            if right < count && comparator(storage[right], storage[smallest]) {
                smallest = right
            }
            if smallest == i { break }
            storage.swapAt(i, smallest)
            i = smallest
        }
    }
}

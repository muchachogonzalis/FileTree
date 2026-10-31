import Foundation
import Testing
@testable import FileTreeCore

@Suite("ParallelWalker")
struct ParallelWalkerTests {
    /// Per-thread tally.
    final class Tally {
        var processed = 0
        var produced = 0
    }

    /// Item n leads to 2n+1 and 2n+2, up to `limit` items in all.
    static func children(of item: Int, limit: Int) -> [Int] {
        [2 * item + 1, 2 * item + 2].filter { $0 < limit }
    }

    @Test(arguments: [1, 2, 4, 8])
    func processesEveryItemExactlyOnce(threads: Int) {
        let seen = Collected()
        let walker = ParallelWalker<Int, Tally>(threadCount: threads, makeContext: { Tally() }) { item, tally in
            tally.processed += 1
            seen.add(item)
            return Self.children(of: item, limit: 20_000)
        }

        let (tallies, unprocessed) = walker.run([0])

        #expect(tallies.count == threads)
        #expect(tallies.reduce(0) { $0 + $1.processed } == 20_000)
        #expect(seen.items.sorted() == Array(0..<20_000))
        #expect(unprocessed.isEmpty)
    }

    @Test func cancellingReturnsEveryItemNotProcessed() {
        let walker = ParallelWalker<Int, Tally>(threadCount: 4, makeContext: { Tally() }) { item, tally in
            usleep(500)
            tally.processed += 1
            let next = Self.children(of: item, limit: 1_000_000)
            tally.produced += next.count
            return next
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { walker.cancel() }

        let (tallies, unprocessed) = walker.run([0])

        let processed = tallies.reduce(0) { $0 + $1.processed }
        let produced = tallies.reduce(0) { $0 + $1.produced }
        #expect(processed > 0)
        #expect(processed < 1_000_000)
        // Every item that was created is either processed or handed back.
        #expect(processed + unprocessed.count == 1 + produced)
    }

    @Test func handlesAnEmptyStart() {
        let walker = ParallelWalker<Int, Tally>(threadCount: 3, makeContext: { Tally() }) { _, _ in [] }

        let (tallies, unprocessed) = walker.run([])

        #expect(tallies.count == 3)
        #expect(unprocessed.isEmpty)
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    func add(_ item: Int) {
        lock.withLock { storage.append(item) }
    }

    var items: [Int] {
        lock.withLock { storage }
    }
}

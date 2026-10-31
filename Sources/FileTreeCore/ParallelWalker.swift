import Foundation

/// Runs a tree-shaped job on several threads: processing an item may produce more items.
///
/// Each thread works depth-first through its own part of the tree and hands part of its
/// pending work to a shared pool only when another thread has nothing to do. Threads thus
/// mostly stay in different branches, which matters because the kernel serializes much of the
/// work on one folder (several threads opening siblings of the same folder slow each other down).
final class ParallelWalker<Item: Sendable, Context: AnyObject>: @unchecked Sendable {
    private let condition = NSCondition()
    private var shared: [Item] = []
    private var idleWorkers = 0
    private var isCancelled = false
    private var unprocessed: [Item] = []

    private let threadCount: Int
    private let makeContext: @Sendable () -> Context
    private let process: @Sendable (Item, Context) -> [Item]

    /// - Parameters:
    ///   - makeContext: creates per-thread state, called on each worker thread.
    ///   - process: handles one item and returns the items it leads to.
    init(threadCount: Int,
         makeContext: @escaping @Sendable () -> Context,
         process: @escaping @Sendable (Item, Context) -> [Item]) {
        self.threadCount = max(1, threadCount)
        self.makeContext = makeContext
        self.process = process
    }

    /// Processes `initial` and everything it leads to, and blocks until all work is done or
    /// `cancel()` is called. Returns each thread's context and, after a cancellation, the items
    /// that were never processed.
    func run(_ initial: [Item]) -> (contexts: [Context], unprocessed: [Item]) {
        condition.withLock {
            shared = initial
            idleWorkers = 0
            unprocessed = []
        }
        let contexts = Collector<Context>()
        let group = DispatchGroup()
        for _ in 0..<threadCount {
            group.enter()
            let thread = Thread { [self] in
                let context = makeContext()
                work(with: context)
                contexts.append(context)
                group.leave()
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        group.wait()
        let leftovers = condition.withLock {
            defer {
                shared = []
                unprocessed = []
            }
            return unprocessed + shared
        }
        return (contexts.items, leftovers)
    }

    func cancel() {
        condition.withLock {
            isCancelled = true
            condition.broadcast()
        }
    }

    private func work(with context: Context) {
        var local: [Item] = []
        while true {
            if local.isEmpty {
                guard let item = takeShared() else { break }
                local.append(item)
            }
            let item = local.removeLast()
            local.append(contentsOf: process(item, context))
            if !shareIfNeeded(&local) { break }
        }
        if !local.isEmpty {
            condition.withLock { unprocessed.append(contentsOf: local) }
        }
    }

    /// Waits for work in the shared pool. Returns nil when the job is finished or cancelled.
    private func takeShared() -> Item? {
        condition.lock()
        defer { condition.unlock() }
        idleWorkers += 1
        while shared.isEmpty && !isCancelled {
            // Everyone idle and nothing pooled: nothing more can appear.
            if idleWorkers == threadCount {
                condition.broadcast()
                return nil
            }
            condition.wait()
        }
        idleWorkers -= 1
        return isCancelled ? nil : shared.removeLast()
    }

    /// Moves the oldest half of `local` (the biggest unexplored branches) to the shared pool
    /// when some thread is idle. Returns false once the job is cancelled.
    private func shareIfNeeded(_ local: inout [Item]) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if isCancelled { return false }
        if idleWorkers > 0 && shared.isEmpty && local.count > 1 {
            let count = local.count / 2
            shared.append(contentsOf: local[..<count].reversed())
            local.removeFirst(count)
            condition.broadcast()
        }
        return true
    }
}

/// Thread-safe append-only array.
private final class Collector<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ element: Element) {
        lock.withLock { storage.append(element) }
    }

    var items: [Element] {
        lock.withLock { storage }
    }
}

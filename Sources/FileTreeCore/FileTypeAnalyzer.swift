import Foundation

/// Space taken by the files of one type (extension) inside a folder tree.
public struct FileTypeStats: Sendable, Equatable {
    /// Lowercased extension without the dot; empty for files without one.
    public let fileExtension: String
    public internal(set) var fileCount = 0
    public internal(set) var logicalSize: Int64 = 0
    public internal(set) var allocatedSize: Int64 = 0
    public internal(set) var largestFilePath = ""
    /// On-disk size of the largest file.
    public internal(set) var largestFileSize: Int64 = -1

    public var averageAllocatedSize: Int64 {
        fileCount > 0 ? allocatedSize / Int64(fileCount) : 0
    }

    mutating func merge(_ other: FileTypeStats) {
        fileCount += other.fileCount
        logicalSize = logicalSize.addingSaturated(other.logicalSize)
        allocatedSize = allocatedSize.addingSaturated(other.allocatedSize)
        if other.largestFileSize > largestFileSize {
            largestFileSize = other.largestFileSize
            largestFilePath = other.largestFilePath
        }
    }
}

public struct FileTypeReport: Sendable {
    /// Sorted by on-disk size, largest first.
    public let types: [FileTypeStats]
    public let fileCount: Int
    public let wasCancelled: Bool
}

/// Groups all files below a folder by extension. The folder tree keeps no per-file data, so
/// this walks the folder again, with the same rules as the scan that produced the tree.
///
/// Data shared by several entries (hard links, full clones) is counted once. Given a snapshot
/// of the scan's shared data, it is counted only where the scan counted it, so the totals agree
/// with the tree.
public final class FileTypeAnalyzer: @unchecked Sendable {
    public let path: String
    private let boundary: ScanBoundary
    private let threadCount: Int
    private let sharedData: SharedDataSnapshot?

    private let lock = NSLock()
    private var walker: ParallelWalker<FolderItem, Accumulator>?
    private var cancelRequested = false
    private var filesCounted = 0
    private var seenSharedData = Set<SharedDataKey>()

    /// - Parameter sharedData: `snapshot(countedInside:)` of the scan's registry for the
    ///   scanned folder at `path`, taken on the main thread.
    public init(path: String, boundary: ScanBoundary, sharedData: SharedDataSnapshot? = nil,
                threadCount: Int = FolderScanner.defaultThreadCount) {
        self.path = path
        self.boundary = boundary
        self.sharedData = sharedData
        self.threadCount = threadCount
    }

    /// Files looked at so far.
    public var progress: Int {
        lock.withLock { filesCounted }
    }

    public func cancel() {
        let walker = lock.withLock {
            cancelRequested = true
            return self.walker
        }
        walker?.cancel()
    }

    /// Blocks until the folder has been analyzed or the analysis is cancelled.
    public func run() -> FileTypeReport {
        // The scan does not open such a folder, so none of its files are counted.
        if boundary.showsDiskImageContents(path) {
            return FileTypeReport(types: [], fileCount: 0, wasCancelled: false)
        }
        let walker = ParallelWalker<FolderItem, Accumulator>(
            threadCount: threadCount,
            makeContext: { Accumulator() },
            process: { [self] folder, accumulator in analyze(folder, into: accumulator) }
        )
        let cancelledBeforeStart = lock.withLock {
            self.walker = walker
            return cancelRequested
        }
        if cancelledBeforeStart {
            walker.cancel()
        }
        let (accumulators, unprocessed) = walker.run([FolderItem(path: path, name: "", rawName: nil, parent: nil)])
        lock.withLock { self.walker = nil }

        var merged: [String: FileTypeStats] = [:]
        var fileCount = 0
        for accumulator in accumulators {
            fileCount += accumulator.fileCount
            for (fileExtension, stats) in accumulator.types {
                merged[fileExtension, default: FileTypeStats(fileExtension: fileExtension)].merge(stats)
            }
        }
        let types = merged.values.sorted {
            $0.allocatedSize != $1.allocatedSize ? $0.allocatedSize > $1.allocatedSize : $0.fileExtension < $1.fileExtension
        }
        return FileTypeReport(types: types, fileCount: fileCount, wasCancelled: !unprocessed.isEmpty)
    }

    private func analyze(_ folder: FolderItem, into accumulator: Accumulator) -> [FolderItem] {
        let descriptor = FileSystem.openDirectory(named: folder.name, rawName: folder.rawName, in: folder.parent,
                                                  path: folder.path)
        guard descriptor >= 0 else { return [] }
        let directory = DirectoryHandle(descriptor)

        var subfolders: [FolderItem] = []
        var files = 0
        _ = accumulator.reader.forEachEntry(in: directory.descriptor) { entry in
            if entry.kind == .directory {
                let name = entry.name
                let childPath = FolderTree.join(folder.path, name)
                guard !boundary.skips(childPath), !boundary.showsDiskImageContents(childPath), !entry.isMountTrigger,
                      !entry.isDataless else { return }
                if entry.isMountPoint && !boundary.includesVolume(mountedAt: childPath) { return }
                subfolders.append(FolderItem(path: childPath, name: name,
                                             rawName: entry.isExactlyNamed(name) ? nil : entry.rawName, parent: directory))
                return
            }
            files += 1
            let isFile = entry.kind == .file
            if isFile, entry.linkCount > 1 {
                guard isCounted(.file(device: entry.device, fileID: entry.fileID)) else { return }
            }
            let countsBlocks = !(isFile && entry.sharesAllBlocks)
                || isCounted(.clone(device: entry.device, cloneID: entry.cloneID))
            let fileExtension = Self.fileExtension(of: entry.namePointer)
            accumulator.types[fileExtension, default: FileTypeStats(fileExtension: fileExtension)]
                .add(entry, countingBlocks: countsBlocks, path: { FolderTree.join(folder.path, entry.name) })
        }
        accumulator.fileCount += files
        lock.withLock { filesCounted += files }
        return subfolders
    }

    /// Whether to count shared data here: only where the scan counted it, and only once.
    private func isCounted(_ key: SharedDataKey) -> Bool {
        guard sharedData?.isCountedInside(key) ?? true else { return false }
        return lock.withLock { seenSharedData.insert(key).inserted }
    }

    /// "Movie.MOV" → "mov", "archive.tar.gz" → "gz"; "README", ".zshrc" and "file." have none.
    static func fileExtension(of name: UnsafePointer<CChar>) -> String {
        let length = strlen(name)
        var dot = -1
        var index = length - 1
        while index > 0 {
            if name[index] == 0x2E {
                dot = index
                break
            }
            index -= 1
        }
        guard dot > 0, dot < length - 1 else { return "" }
        return String(cString: name + dot + 1).lowercased()
    }
}

private struct FolderItem: Sendable {
    let path: String
    let name: String
    let rawName: [CChar]?
    let parent: DirectoryHandle?
}

/// Per-thread totals, merged when the walk is over.
private final class Accumulator {
    let reader = DirectoryReader()
    var types: [String: FileTypeStats] = [:]
    var fileCount = 0
}

private extension FileTypeStats {
    /// - Parameter countingBlocks: false for a clone whose data blocks were already counted.
    mutating func add(_ entry: RawDirectoryEntry, countingBlocks: Bool, path: () -> String) {
        fileCount += 1
        logicalSize = logicalSize.addingSaturated(entry.logicalSize)
        let blocks = countingBlocks ? entry.allocatedSize : 0
        allocatedSize = allocatedSize.addingSaturated(blocks)
        if blocks > largestFileSize {
            largestFileSize = blocks
            largestFilePath = path()
        }
    }
}

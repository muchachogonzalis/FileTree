import Foundation

public struct ScanProgress: Sendable {
    public var foldersScanned = 0
    public var filesFound = 0
    public var allocatedSize: Int64 = 0
    public var currentPath = ""
}

/// The outcome of scanning one folder.
public final class ScanResult: @unchecked Sendable {
    public let root: FolderNode
    public let rootPath: String
    public let boundary: ScanBoundary
    /// Needed to rescan part of the tree without counting shared data twice.
    public let sharedData: SharedDataRegistry
    /// The scan was stopped early; folders it did not reach have status `.notScanned`.
    public let wasCancelled: Bool
    public let duration: TimeInterval

    init(root: FolderNode, rootPath: String, boundary: ScanBoundary, sharedData: SharedDataRegistry,
         wasCancelled: Bool, duration: TimeInterval) {
        self.root = root
        self.rootPath = rootPath
        self.boundary = boundary
        self.sharedData = sharedData
        self.wasCancelled = wasCancelled
        self.duration = duration
    }
}

/// Measures a folder and everything below it, listing folders on several threads.
///
/// Sizes are what the files take on disk (allocated blocks, all forks) and their logical
/// sizes. Symlinks are not followed, files with several hard links are counted once, the
/// blocks of full APFS clones are counted once, evicted iCloud files and folders count as the
/// little space they take locally (and are not downloaded), and other volumes and folders that
/// only show the contents of disk images are left out as decided by `ScanBoundary`.
public final class FolderScanner: @unchecked Sendable {
    /// Listing folders is nearly all kernel work, and the kernel serializes much of it: on APFS
    /// four threads are about three times as fast as one, while more threads only wait for
    /// each other (measured on macOS 26, Apple silicon).
    public static var defaultThreadCount: Int {
        min(4, max(2, ProcessInfo.processInfo.activeProcessorCount))
    }

    public let path: String
    public let boundary: ScanBoundary
    public let sharedData: SharedDataRegistry
    private let rootName: String
    private let threadCount: Int

    private let lock = NSLock()
    private var currentProgress = ScanProgress()
    private var walker: ParallelWalker<WorkItem, DirectoryReader>?
    private var cancelRequested = false

    /// - Parameters:
    ///   - path: canonical absolute path of the folder to scan.
    ///   - rootName: name shown for the scanned folder; defaults to its last path component.
    ///   - boundary: what to leave out; pass the original scan's boundary when rescanning a
    ///     folder inside an earlier result.
    public init(path: String, rootName: String? = nil, boundary: ScanBoundary? = nil,
                sharedData: SharedDataRegistry = SharedDataRegistry(), threadCount: Int = FolderScanner.defaultThreadCount) {
        self.path = path
        self.rootName = rootName ?? (path == "/" ? "/" : String(path.split(separator: "/").last ?? Substring(path)))
        self.boundary = boundary ?? ScanBoundary(rootPath: path)
        self.sharedData = sharedData
        self.threadCount = threadCount
    }

    public var progress: ScanProgress {
        lock.withLock { currentProgress }
    }

    /// Stops the scan soon; `run()` then returns what was measured so far. Thread-safe.
    public func cancel() {
        let walker = lock.withLock {
            cancelRequested = true
            return self.walker
        }
        walker?.cancel()
    }

    /// Scans, blocking the calling thread until done or cancelled.
    public func run() -> ScanResult {
        let start = Date()
        let root = FolderNode(name: rootName, parent: nil)
        root.rootPath = path
        var info = stat()
        let statError = lstat(path, &info) == 0 ? 0 : errno
        if statError == 0 {
            root.ownLatestModification = Int64(info.st_mtimespec.tv_sec)
        }
        if boundary.showsDiskImageContents(path) {
            // A rescan of such a folder leaves it unopened, as the scan it belongs to did.
            root.status = statError == 0 ? .diskImageContents : FolderStatus(errno: statError)
            FolderTree.computeTotals(of: root)
            return ScanResult(root: root, rootPath: path, boundary: boundary, sharedData: sharedData,
                              wasCancelled: false, duration: Date().timeIntervalSince(start))
        }

        let walker = ParallelWalker<WorkItem, DirectoryReader>(
            threadCount: threadCount,
            makeContext: { DirectoryReader() },
            process: { [self] item, reader in scan(item, with: reader) }
        )
        let cancelledBeforeStart = lock.withLock {
            self.walker = walker
            return cancelRequested
        }
        if cancelledBeforeStart {
            walker.cancel()
        }

        let unprocessed = walker.run([WorkItem(node: root, path: path, rawName: nil, parent: nil)]).unprocessed
        lock.withLock { self.walker = nil }
        for item in unprocessed {
            item.node.status = .notScanned
        }
        FolderTree.computeTotals(of: root)

        return ScanResult(root: root, rootPath: path, boundary: boundary, sharedData: sharedData,
                          wasCancelled: !unprocessed.isEmpty, duration: Date().timeIntervalSince(start))
    }

    /// Lists one folder: sums up its files and returns its subfolders to be scanned next.
    private func scan(_ item: WorkItem, with reader: DirectoryReader) -> [WorkItem] {
        let folder = item.node
        let descriptor = FileSystem.openDirectory(named: folder.name, rawName: item.rawName, in: item.parent,
                                                  path: item.path)
        guard descriptor >= 0 else {
            folder.status = FolderStatus(errno: errno)
            report(folders: 1, files: 0, allocated: 0, path: item.path)
            return []
        }
        // Stays open while the subfolders still have to be opened relative to it.
        let directory = DirectoryHandle(descriptor)

        var subfolders: [WorkItem] = []
        var children: [FolderNode] = []
        var fileCount = 0
        var logicalSize: Int64 = 0
        var allocatedSize: Int64 = 0
        var latest = folder.ownLatestModification

        let error = reader.forEachEntry(in: directory.descriptor) { entry in
            if entry.kind == .directory {
                let name = entry.name
                let childPath = FolderTree.join(item.path, name)
                if boundary.skips(childPath) { return }
                let child = FolderNode(name: name, parent: folder)
                child.ownLatestModification = entry.modificationTime
                children.append(child)
                if entry.isDataless {
                    child.status = .inCloud
                } else if entry.isMountTrigger || (entry.isMountPoint && !boundary.includesVolume(mountedAt: childPath)) {
                    child.status = .otherVolume
                } else if boundary.showsDiskImageContents(childPath) {
                    child.status = .diskImageContents
                } else {
                    subfolders.append(WorkItem(node: child, path: childPath,
                                               rawName: entry.isExactlyNamed(name) ? nil : entry.rawName, parent: directory))
                }
            } else {
                fileCount += 1
                latest = max(latest, entry.modificationTime)
                guard entry.kind == .file else {
                    logicalSize = logicalSize.addingSaturated(entry.logicalSize)
                    allocatedSize = allocatedSize.addingSaturated(entry.allocatedSize)
                    return
                }
                let isClone = entry.sharesAllBlocks
                // Another name of a file already counted: nothing new on disk. (The blocks of a
                // hard-linked clone are accounted for under its clone below.)
                if entry.linkCount > 1,
                   !sharedData.claim(.file(device: entry.device, fileID: entry.fileID), in: folder,
                                     logicalSize: entry.logicalSize, allocatedSize: isClone ? 0 : entry.allocatedSize) {
                    return
                }
                logicalSize = logicalSize.addingSaturated(entry.logicalSize)
                // A full clone of data already counted takes no extra blocks.
                if isClone,
                   !sharedData.claim(.clone(device: entry.device, cloneID: entry.cloneID), in: folder,
                                     logicalSize: 0, allocatedSize: entry.allocatedSize) {
                    return
                }
                allocatedSize = allocatedSize.addingSaturated(entry.allocatedSize)
            }
        }

        if error != 0 {
            folder.status = FolderStatus(errno: error)
            if folder.status == .vanished {
                folder.status = .unreadable(errno: error)
            }
        }
        folder.children = children
        folder.ownFileCount = fileCount
        folder.ownLogicalSize = logicalSize
        folder.ownAllocatedSize = allocatedSize
        folder.ownLatestModification = latest
        report(folders: 1, files: fileCount, allocated: allocatedSize, path: item.path)
        return subfolders
    }

    private func report(folders: Int, files: Int, allocated: Int64, path: String) {
        lock.withLock {
            currentProgress.foldersScanned += folders
            currentProgress.filesFound += files
            currentProgress.allocatedSize = currentProgress.allocatedSize.addingSaturated(allocated)
            currentProgress.currentPath = path
        }
    }
}

struct WorkItem: Sendable {
    let node: FolderNode
    let path: String
    /// The name's exact bytes, when `node.name` cannot hold them.
    let rawName: [CChar]?
    /// The open parent folder; nil for the folder the scan starts at.
    let parent: DirectoryHandle?
}

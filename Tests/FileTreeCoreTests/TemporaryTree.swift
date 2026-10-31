import Foundation
@testable import FileTreeCore

/// A folder tree in the temporary directory for one test; deleted when released.
final class TemporaryTree {
    let root: String

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileTreeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = FileSystem.canonicalPath(base.path)
    }

    deinit {
        if (try? FileManager.default.removeItem(atPath: root)) == nil {
            // Paths longer than PATH_MAX need rm, which walks the tree by descriptors.
            let rm = Process()
            rm.executableURL = URL(fileURLWithPath: "/bin/rm")
            rm.arguments = ["-rf", root]
            try? rm.run()
            rm.waitUntilExit()
        }
    }

    func path(_ relative: String) -> String {
        relative.isEmpty ? root : root + "/" + relative
    }

    @discardableResult
    func makeFolder(_ relative: String) throws -> String {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
        return path(relative)
    }

    /// Writes `size` bytes of non-zero data, so the file really takes space on disk.
    @discardableResult
    func makeFile(_ relative: String, size: Int) throws -> String {
        let fullPath = path(relative)
        try FileManager.default.createDirectory(atPath: (fullPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: URL(fileURLWithPath: fullPath))
        return fullPath
    }

    /// A file whose logical size is `logicalSize` but which allocates (almost) nothing.
    func makeSparseFile(_ relative: String, logicalSize: Int64) throws {
        let descriptor = open(path(relative), O_CREAT | O_WRONLY, 0o644)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno)!) }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(logicalSize)) == 0 else { throw POSIXError(.init(rawValue: errno)!) }
    }

    func makeHardLink(from existing: String, to new: String) throws {
        guard link(path(existing), path(new)) == 0 else { throw POSIXError(.init(rawValue: errno)!) }
    }

    func makeSymlink(_ relative: String, pointingTo destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path(relative), withDestinationPath: destination)
    }

    func setModificationTime(_ relative: String, to seconds: Int) throws {
        var times = [timespec(tv_sec: seconds, tv_nsec: 0), timespec(tv_sec: seconds, tv_nsec: 0)]
        guard utimensat(AT_FDCWD, path(relative), &times, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
    }

    func allocatedSize(_ relative: String) -> Int64 {
        var info = stat()
        lstat(path(relative), &info)
        return Int64(info.st_blocks) * 512
    }

    func logicalSize(_ relative: String) -> Int64 {
        var info = stat()
        lstat(path(relative), &info)
        return Int64(info.st_size)
    }
}

extension FolderNode {
    func child(_ name: String) -> FolderNode? {
        children.first { $0.name == name }
    }

    /// Checks that every folder's totals equal its own files plus its children's totals.
    var totalsAreConsistent: Bool {
        var stack = [self]
        while let node = stack.popLast() {
            let logical = node.children.reduce(node.ownLogicalSize) { $0 + $1.logicalSize }
            let allocated = node.children.reduce(node.ownAllocatedSize) { $0 + $1.allocatedSize }
            let files = node.children.reduce(node.ownFileCount) { $0 + $1.fileCount }
            guard logical == node.logicalSize, allocated == node.allocatedSize, files == node.fileCount else { return false }
            stack.append(contentsOf: node.children)
        }
        return true
    }
}

extension ScanResult {
    /// Rescans `folder` the way the app does and puts the result into the tree.
    @discardableResult
    func rescan(_ folder: FolderNode, stoppedAtOnce: Bool = false) -> FolderTree.RescanOutcome {
        let released = sharedData.release(inside: folder)
        let scanner = FolderScanner(path: folder.path, rootName: folder.name, boundary: boundary, sharedData: sharedData)
        if stoppedAtOnce {
            scanner.cancel()
        }
        return FolderTree.finishRescan(of: folder, with: scanner.run(), released: released, sharedData: sharedData)
    }
}

import Foundation
import Testing
@testable import FileTreeCore

@Suite("FolderScanner")
struct FolderScannerTests {
    @Test func sumsTheFilesOfAllNestedFolders() throws {
        let tree = try TemporaryTree()
        try tree.makeFile("a.bin", size: 10_000)
        try tree.makeFile("sub/b.bin", size: 200_000)
        try tree.makeFile("sub/deeper/c.bin", size: 3_000_000)
        try tree.makeFolder("empty")

        let result = FolderScanner(path: tree.root).run()
        let root = result.root

        #expect(!result.wasCancelled)
        #expect(root.status == .ok)
        #expect(root.problemCount == 0)
        #expect(root.fileCount == 3)
        #expect(root.folderCount == 3)
        #expect(root.logicalSize == 3_210_000)
        #expect(root.allocatedSize == tree.allocatedSize("a.bin") + tree.allocatedSize("sub/b.bin")
            + tree.allocatedSize("sub/deeper/c.bin"))
        let sub = try #require(root.child("sub"))
        #expect(sub.fileCount == 2)
        #expect(sub.folderCount == 1)
        #expect(sub.logicalSize == 3_200_000)
        #expect(sub.path == tree.path("sub"))
        #expect(try #require(sub.child("deeper")).path == tree.path("sub/deeper"))
        #expect(try #require(root.child("empty")).allocatedSize == 0)
        #expect(root.totalsAreConsistent)
    }

    @Test func countsAFileWithSeveralHardLinksOnce() throws {
        let tree = try TemporaryTree()
        try tree.makeFile("one/original.bin", size: 500_000)
        try tree.makeFolder("two")
        try tree.makeHardLink(from: "one/original.bin", to: "two/link.bin")

        let root = FolderScanner(path: tree.root).run().root

        #expect(root.fileCount == 2)
        #expect(root.logicalSize == 500_000)
        #expect(root.allocatedSize == tree.allocatedSize("one/original.bin"))
        let one = try #require(root.child("one")), two = try #require(root.child("two"))
        #expect(one.logicalSize + two.logicalSize == 500_000)
    }

    @Test func doesNotFollowSymlinks() throws {
        let outside = try TemporaryTree()
        try outside.makeFile("big.bin", size: 2_000_000)
        let tree = try TemporaryTree()
        try tree.makeFile("small.bin", size: 1_000)
        try tree.makeSymlink("link-to-folder", pointingTo: outside.root)
        try tree.makeSymlink("link-to-file", pointingTo: outside.path("big.bin"))

        let root = FolderScanner(path: tree.root).run().root

        #expect(root.children.isEmpty)
        #expect(root.fileCount == 3)
        #expect(root.logicalSize == 1_000 + tree.logicalSize("link-to-folder") + tree.logicalSize("link-to-file"))
        #expect(root.allocatedSize < 1_000_000)
    }

    @Test func reportsFoldersItCannotOpen() throws {
        let tree = try TemporaryTree()
        try tree.makeFile("open/visible.bin", size: 4_000)
        try tree.makeFile("locked/hidden.bin", size: 4_000)
        chmod(tree.path("locked"), 0)
        defer { chmod(tree.path("locked"), 0o755) }

        let root = FolderScanner(path: tree.root).run().root

        let locked = try #require(root.child("locked"))
        #expect(locked.status == .accessDenied)
        #expect(locked.fileCount == 0)
        #expect(root.child("open")?.status == .ok)
        #expect(root.problemCount == 1)
        #expect(root.fileCount == 1)
    }

    @Test func measuresSparseFilesByTheBlocksTheyUse() throws {
        let tree = try TemporaryTree()
        try tree.makeSparseFile("disk.img", logicalSize: 1 << 30)

        let root = FolderScanner(path: tree.root).run().root

        #expect(root.logicalSize == 1 << 30)
        #expect(root.allocatedSize == tree.allocatedSize("disk.img"))
        #expect(root.allocatedSize < 1 << 20)
    }

    @Test func scansPathsLongerThanPathMax() throws {
        let tree = try TemporaryTree()
        // Six levels of 200-character names make a path of about 1,300 characters; PATH_MAX is 1,024.
        let name = String(repeating: "d", count: 200)
        var folder = open(tree.root, O_RDONLY | O_DIRECTORY)
        for _ in 0..<6 {
            #expect(mkdirat(folder, name, 0o755) == 0)
            let next = openat(folder, name, O_RDONLY | O_DIRECTORY)
            close(folder)
            folder = next
        }
        let file = openat(folder, "deep.bin", O_CREAT | O_WRONLY, 0o644)
        let written = [UInt8](repeating: 7, count: 12_345).withUnsafeBytes { write(file, $0.baseAddress, $0.count) }
        close(file)
        close(folder)
        #expect(written == 12_345)

        let root = FolderScanner(path: tree.root).run().root

        #expect(root.problemCount == 0)
        #expect(root.folderCount == 6)
        #expect(root.fileCount == 1)
        #expect(root.logicalSize == 12_345)
    }

    @Test func leavesOutExcludedFolders() throws {
        let tree = try TemporaryTree()
        try tree.makeFile("keep/a.bin", size: 1_000)
        try tree.makeFile("skip/b.bin", size: 1_000)
        let boundary = ScanBoundary(rootPath: tree.root, excludedPaths: [tree.path("skip")])

        let root = FolderScanner(path: tree.root, boundary: boundary).run().root

        #expect(root.child("skip") == nil)
        #expect(root.fileCount == 1)
    }

    @Test func latestModificationIsTheNewestInsideAFolder() throws {
        let tree = try TemporaryTree()
        try tree.makeFile("old/a.bin", size: 10)
        try tree.makeFile("new/deep/b.bin", size: 10)
        try tree.setModificationTime("old/a.bin", to: 1_000_000_000)
        try tree.setModificationTime("old", to: 1_000_000_000)
        try tree.setModificationTime("new/deep/b.bin", to: 1_700_000_000)
        try tree.setModificationTime("new/deep", to: 1_600_000_000)
        try tree.setModificationTime("new", to: 1_600_000_000)

        let root = FolderScanner(path: tree.root).run().root

        #expect(root.child("old")?.latestModification == 1_000_000_000)
        #expect(root.child("new")?.latestModification == 1_700_000_000)
    }

    @Test func cancellingBeforeRunningLeavesTheFolderUnscanned() throws {
        let tree = try TemporaryTree()
        try tree.makeFile("a.bin", size: 100)
        let scanner = FolderScanner(path: tree.root)
        scanner.cancel()

        let result = scanner.run()

        #expect(result.wasCancelled)
        #expect(result.root.status == .notScanned)
        #expect(result.root.fileCount == 0)
    }

    @Test func cancellingMidwayKeepsTheTreeConsistent() async throws {
        let tree = try TemporaryTree()
        for folder in 0..<200 {
            for file in 0..<5 {
                try tree.makeFile("f\(folder)/g/h/x\(file).bin", size: 64)
            }
        }
        let complete = FolderScanner(path: tree.root).run().root
        let scanner = FolderScanner(path: tree.root, threadCount: 2)

        let scan = Task.detached { scanner.run() }
        try await Task.sleep(for: .milliseconds(3))
        scanner.cancel()
        let partial = await scan.value

        #expect(partial.root.totalsAreConsistent)
        if partial.wasCancelled {
            #expect(partial.root.fileCount < complete.fileCount)
            #expect(partial.root.containsUnscannedFolder)
        } else {
            #expect(partial.root.fileCount == complete.fileCount)
        }
    }

    @Test func rescanningAFolderUpdatesEveryFolderAboveIt() throws {
        let tree = try TemporaryTree()
        try tree.makeFile("a/b/c/one.bin", size: 10_000)
        try tree.makeFile("a/other.bin", size: 5_000)
        let result = FolderScanner(path: tree.root).run()
        let c = try #require(result.root.child("a")?.child("b")?.child("c"))
        try tree.makeFile("a/b/c/two.bin", size: 70_000)
        try tree.makeFile("a/b/c/new/three.bin", size: 1_000)

        let outcome = result.rescan(c)

        let expected = FolderScanner(path: tree.root).run().root
        #expect(result.root.logicalSize == expected.logicalSize)
        #expect(result.root.allocatedSize == expected.allocatedSize)
        #expect(result.root.fileCount == expected.fileCount)
        #expect(result.root.folderCount == expected.folderCount)
        #expect(result.root.totalsAreConsistent)
        let newC = try #require(result.root.child("a")?.child("b")?.child("c"))
        guard case .replaced(let fresh) = outcome else {
            Issue.record("expected the folder to be replaced, got \(outcome)")
            return
        }
        #expect(newC === fresh)
        #expect(newC.path == tree.path("a/b/c"))
        #expect(c.parent == nil)
        #expect(c.path == tree.path("a/b/c"), "a replaced folder keeps its path")
    }

    @Test func rescanningKeepsHardLinksCountedOnce() throws {
        let tree = try TemporaryTree()
        try tree.makeFile("one/file.bin", size: 300_000)
        try tree.makeFolder("two")
        try tree.makeHardLink(from: "one/file.bin", to: "two/link.bin")
        let result = FolderScanner(path: tree.root).run()
        let total = result.root.allocatedSize

        for name in ["one", "two", "one"] {
            result.rescan(try #require(result.root.child(name)))
            #expect(result.root.allocatedSize == total)
        }
    }

    @Test func rescanningADeletedFolderLetsItBeRemoved() throws {
        let tree = try TemporaryTree()
        try tree.makeFile("gone/a.bin", size: 50_000)
        try tree.makeFile("stays/b.bin", size: 1_000)
        let result = FolderScanner(path: tree.root).run()
        let gone = try #require(result.root.child("gone"))
        try FileManager.default.removeItem(atPath: tree.path("gone"))

        guard case .removed = result.rescan(gone) else {
            Issue.record("expected the folder to be removed")
            return
        }

        #expect(result.root.child("gone") == nil)
        #expect(result.root.fileCount == 1)
        #expect(result.root.logicalSize == 1_000)
        #expect(result.root.folderCount == 1)
    }

    @Test func agreesWithDuOnASystemFolder() throws {
        let folder = "/usr/share"
        let result = FolderScanner(path: folder).run()

        let du = Process()
        du.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        du.arguments = ["-sk", folder]
        let output = Pipe()
        du.standardOutput = output
        du.standardError = FileHandle.nullDevice
        try du.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        du.waitUntilExit()
        let kilobytes = try #require(Int64(text.split(separator: "\t").first ?? ""))

        #expect(abs(result.root.allocatedSize / 1024 - kilobytes) <= max(64, kilobytes / 500))
    }

    /// The Preboot volume of the Mac running the tests. macOS 13 and later show the contents of
    /// the cryptex images stored on it in Preboot/Cryptexes, which must not be counted again
    /// (du does count them, so here the volume's own figure is the reference).
    @Test(.enabled(if: FileManager.default.fileExists(atPath: ScanBoundary.prebootMountPoint + "/Cryptexes")))
    func measuresPrebootAsTheSpaceItTakes() throws {
        let preboot = ScanBoundary.prebootMountPoint
        let root = FolderScanner(path: preboot).run().root
        let used = try #require(spaceUsed(byVolumeAt: preboot))

        #expect(try #require(root.child("Cryptexes")).status == .diskImageContents)
        #expect(root.allocatedSize <= used + used / 50, "more than the volume holds: something is counted twice")
        #expect(root.allocatedSize >= used / 2)
    }
}

private extension FolderNode {
    var containsUnscannedFolder: Bool {
        status == .notScanned || children.contains { $0.containsUnscannedFolder }
    }
}

/// Bytes taken by the volume mounted at `path` itself, as df and diskutil report it. (statfs
/// cannot tell: for an APFS volume it counts what all volumes of the container use.)
private func spaceUsed(byVolumeAt path: String) -> Int64? {
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
    var buffer = [UInt8](repeating: 0, count: 32)
    guard getattrlist(path, &request, &buffer, buffer.count, 0) == 0 else { return nil }
    return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: MemoryLayout<UInt32>.size, as: Int64.self) }
}

@Suite("APFS clones")
struct CloneTests {
    @Test func countsTheBlocksOfFullClonesOnce() throws {
        let tree = try TemporaryTree()
        try tree.makeFile("original/big.bin", size: 2_000_000)
        try tree.makeFolder("copies")
        #expect(clonefile(tree.path("original/big.bin"), tree.path("copies/one.bin"), 0) == 0)
        #expect(clonefile(tree.path("original/big.bin"), tree.path("copies/two.bin"), 0) == 0)

        let root = FolderScanner(path: tree.root).run().root

        #expect(root.fileCount == 3)
        #expect(root.logicalSize == 6_000_000)
        #expect(root.allocatedSize == tree.allocatedSize("original/big.bin"))
        #expect(root.totalsAreConsistent)
    }

    @Test func countsAClonePartlyRewrittenAsSeparateData() throws {
        let tree = try TemporaryTree()
        try tree.makeFile("original.bin", size: 1_000_000)
        #expect(clonefile(tree.path("original.bin"), tree.path("changed.bin"), 0) == 0)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: tree.path("changed.bin")))
        try handle.write(contentsOf: Data(repeating: 1, count: 8_192))
        try handle.close()

        let root = FolderScanner(path: tree.root).run().root

        // The two files no longer share all their blocks: each is counted with what it has.
        #expect(root.allocatedSize == tree.allocatedSize("original.bin") + tree.allocatedSize("changed.bin"))
    }

    @Test func rescanningKeepsClonesCountedOnce() throws {
        let tree = try TemporaryTree()
        try tree.makeFile("one/file.bin", size: 400_000)
        try tree.makeFolder("two")
        #expect(clonefile(tree.path("one/file.bin"), tree.path("two/clone.bin"), 0) == 0)
        let result = FolderScanner(path: tree.root).run()
        let total = result.root.allocatedSize
        #expect(total == tree.allocatedSize("one/file.bin"))

        for name in ["two", "one", "two"] {
            result.rescan(try #require(result.root.child(name)))
            #expect(result.root.allocatedSize == total)
        }
    }

    @Test func listingAndFileTypesKnowAboutClones() throws {
        let tree = try TemporaryTree()
        try tree.makeFile("movie.mov", size: 3_000_000)
        try tree.makeFile("plain.txt", size: 100)
        #expect(clonefile(tree.path("movie.mov"), tree.path("copy.mov"), 0) == 0)

        let items = DirectoryListing.items(in: tree.root).items
        #expect(items.first { $0.name == "copy.mov" }?.isClone == true)
        #expect(items.first { $0.name == "movie.mov" }?.isClone == true)
        #expect(items.first { $0.name == "plain.txt" }?.isClone == false)

        let report = FileTypeAnalyzer(path: tree.root, boundary: ScanBoundary(rootPath: tree.root)).run()
        let movies = try #require(report.types.first { $0.fileExtension == "mov" })
        #expect(movies.fileCount == 2)
        #expect(movies.logicalSize == 6_000_000)
        #expect(movies.allocatedSize == tree.allocatedSize("movie.mov"))
    }
}

@Suite("Shared data attribution")
struct SharedDataAttributionTests {
    /// a/movie.mov with a full clone in b/, and a/disk.dmg with a hard link in c/.
    static func makeTree() throws -> TemporaryTree {
        let tree = try TemporaryTree()
        try tree.makeFile("a/movie.mov", size: 1_000_000)
        try tree.makeFile("a/disk.dmg", size: 500_000)
        try tree.makeFolder("b")
        try tree.makeFolder("c")
        #expect(clonefile(tree.path("a/movie.mov"), tree.path("b/movie copy.mov"), 0) == 0)
        try tree.makeHardLink(from: "a/disk.dmg", to: "c/disk link.dmg")
        return tree
    }

    @Test func fileTypesOfAFolderAddUpToItsSizeInTheTree() throws {
        let tree = try Self.makeTree()
        let result = FolderScanner(path: tree.root).run()
        #expect(result.root.allocatedSize == tree.allocatedSize("a/movie.mov") + tree.allocatedSize("a/disk.dmg"))

        for folder in [result.root] + result.root.children {
            let report = FileTypeAnalyzer(path: folder.path, boundary: result.boundary,
                                          sharedData: result.sharedData.snapshot(countedInside: folder)).run()
            let total = report.types.reduce(Int64(0)) { $0 + $1.allocatedSize }
            #expect(total == folder.allocatedSize, "file types of \(folder.name)")
            #expect(report.fileCount == folder.fileCount, "files in \(folder.name)")
        }
    }

    @Test func listingTellsWhereSharedDataIsCounted() throws {
        let tree = try Self.makeTree()
        let result = FolderScanner(path: tree.root).run()
        let a = try #require(result.root.child("a"))
        let b = try #require(result.root.child("b"))
        let c = try #require(result.root.child("c"))

        func elsewhere(_ name: String, in folder: FolderNode) throws -> FolderNode? {
            let item = try #require(DirectoryListing.items(in: folder.path).items.first { $0.name == name })
            return item.dataCountedElsewhere(than: folder, in: result.sharedData)
        }
        // Of two copies, exactly one is counted where it lies; the other points at its folder.
        let original = try elsewhere("movie.mov", in: a), copy = try elsewhere("movie copy.mov", in: b)
        #expect((original == nil) != (copy == nil))
        #expect(original === b || copy === a)

        let firstName = try elsewhere("disk.dmg", in: a), secondName = try elsewhere("disk link.dmg", in: c)
        #expect((firstName == nil) != (secondName == nil))
        #expect(firstName === c || secondName === a)

        try tree.makeFile("a/plain.txt", size: 10)
        #expect(try elsewhere("plain.txt", in: a) == nil)
    }
}

@Suite("Rescans and shared data")
struct RescanSharedDataTests {
    /// a/movie.mov with a full clone in b/, a/disk.dmg with a hard link in c/.
    static func makeTree() throws -> TemporaryTree {
        try SharedDataAttributionTests.makeTree()
    }

    /// The folder (a or b) whose totals include the clone's blocks.
    static func cloneOwner(in result: ScanResult) throws -> FolderNode {
        let b = try #require(result.root.child("b"))
        let item = try #require(DirectoryListing.items(in: b.path).items.first { $0.name == "movie copy.mov" })
        return item.dataCountedElsewhere(than: b, in: result.sharedData) ?? b
    }

    @Test func deletingTheCountedCopyOfACloneHandsTheCountToTheOtherCopy() throws {
        let tree = try Self.makeTree()
        let result = FolderScanner(path: tree.root).run()
        let owner = try Self.cloneOwner(in: result)
        let counted = owner.name == "a" ? "a/movie.mov" : "b/movie copy.mov"
        try FileManager.default.removeItem(atPath: tree.path(counted))

        result.rescan(owner)

        let expected = FolderScanner(path: tree.root).run().root
        #expect(result.root.allocatedSize == expected.allocatedSize)
        #expect(result.root.logicalSize == expected.logicalSize)
        #expect(result.root.fileCount == expected.fileCount)
        #expect(result.root.totalsAreConsistent)
        let survivor = owner.name == "a" ? "b" : "a"
        #expect(try #require(result.root.child(survivor)).allocatedSize >= tree.allocatedSize(survivor == "a" ? "a/movie.mov" : "b/movie copy.mov"))
    }

    @Test func deletingTheCountedNameOfAHardLinkedFileHandsTheCountToTheOtherName() throws {
        let tree = try Self.makeTree()
        let result = FolderScanner(path: tree.root).run()
        let c = try #require(result.root.child("c"))
        let a = try #require(result.root.child("a"))
        let cItem = try #require(DirectoryListing.items(in: c.path).items.first { $0.name == "disk link.dmg" })
        let owner = cItem.dataCountedElsewhere(than: c, in: result.sharedData) ?? c
        try FileManager.default.removeItem(atPath: tree.path(owner === a ? "a/disk.dmg" : "c/disk link.dmg"))

        result.rescan(owner)

        let expected = FolderScanner(path: tree.root).run().root
        #expect(result.root.allocatedSize == expected.allocatedSize)
        #expect(result.root.logicalSize == expected.logicalSize)
        #expect(result.root.totalsAreConsistent)
    }

    @Test func deletingTheWholeCountingFolderHandsTheCountOver() throws {
        let tree = try Self.makeTree()
        let result = FolderScanner(path: tree.root).run()
        let owner = try Self.cloneOwner(in: result)
        try FileManager.default.removeItem(atPath: owner.path)

        guard case .removed = result.rescan(owner) else {
            Issue.record("expected the folder to be removed")
            return
        }

        let expected = FolderScanner(path: tree.root).run().root
        #expect(result.root.allocatedSize == expected.allocatedSize)
        #expect(result.root.logicalSize == expected.logicalSize)
        #expect(result.root.totalsAreConsistent)
    }

    @Test func stoppingARescanKeepsTheEarlierResults() throws {
        let tree = try Self.makeTree()
        let result = FolderScanner(path: tree.root).run()
        let total = result.root.allocatedSize
        let owner = try Self.cloneOwner(in: result)

        guard case .kept = result.rescan(owner, stoppedAtOnce: true) else {
            Issue.record("expected the earlier results to stay")
            return
        }

        #expect(result.root.allocatedSize == total)
        #expect(result.root.children.contains { $0 === owner })
        #expect(try Self.cloneOwner(in: result) === owner, "the registry is restored")
        // Rescanning the other copy's folder afterwards still counts the clone once.
        for folder in result.root.children where folder !== owner {
            result.rescan(folder)
        }
        #expect(result.root.allocatedSize == total)
    }
}

@Suite("Status and sums")
struct StatusAndSumTests {
    @Test func errorsMapToStatuses() {
        #expect(FolderStatus(errno: EACCES) == .accessDenied)
        #expect(FolderStatus(errno: EPERM) == .privacyProtected)
        #expect(FolderStatus(errno: EDEADLK) == .inCloud)
        #expect(FolderStatus(errno: ENOENT) == .vanished)
        #expect(FolderStatus(errno: EIO) == .unreadable(errno: EIO))
        #expect(FolderStatus.privacyProtected.isProblem)
        #expect(!FolderStatus.inCloud.isProblem)
    }

    @Test func sumsSaturateInsteadOfOverflowing() {
        #expect(Int64.max.addingSaturated(1) == .max)
        #expect((Int64.max - 5).addingSaturated(10) == .max)
        #expect(Int64(5).addingSaturated(-3) == 2)
    }

    @Test func survivesSparseFilesWhoseSizesOverflow() throws {
        let tree = try TemporaryTree()
        // Just under the APFS limit of 2^55 bytes per file; 300 of them add up past Int64.max.
        for index in 0..<300 {
            try tree.makeSparseFile("huge-\(index).img", logicalSize: (1 << 55) - (1 << 20))
        }

        let root = FolderScanner(path: tree.root).run().root

        #expect(root.fileCount == 300)
        #expect(root.logicalSize == .max)
        #expect(root.allocatedSize < 100 << 20)
    }
}

/// Folders that only show the contents of disk images stored elsewhere in the scan, the way
/// Preboot/Cryptexes shows the cryptex images kept in Preboot/<UUID>/cryptex1.
@Suite("Disk image views")
struct DiskImageViewTests {
    static func makeTree() throws -> TemporaryTree {
        let tree = try TemporaryTree()
        try tree.makeFile("volume/images/os.dmg", size: 300_000)
        try tree.makeFile("volume/views/OS/System/cache.bin", size: 250_000)
        try tree.makeFile("volume/views/OS/usr/lib.dylib", size: 40_000)
        try tree.makeFile("volume/views/App/app.bin", size: 10_000)
        return tree
    }

    static func boundary(for tree: TemporaryTree, scanning root: String) -> ScanBoundary {
        ScanBoundary(rootPath: root, excludedPaths: [], firmlinks: [], mountSources: [:],
                     imageViews: [.init(viewsPath: tree.path("volume/views"), imagesFolder: tree.path("volume"))])
    }

    @Test func listsTheViewsFolderWithoutCountingWhatItShows() throws {
        let tree = try Self.makeTree()

        let root = FolderScanner(path: tree.root, boundary: Self.boundary(for: tree, scanning: tree.root)).run().root

        let views = try #require(root.child("volume")?.child("views"))
        #expect(views.status == .diskImageContents)
        #expect(!views.isMeasured)
        #expect(views.children.isEmpty)
        #expect(views.fileCount == 0)
        #expect(views.allocatedSize == 0)
        #expect(root.fileCount == 1)
        #expect(root.allocatedSize == tree.allocatedSize("volume/images/os.dmg"))
        #expect(root.folderCount == 3, "volume, images and views, nothing inside views")
        #expect(root.problemCount == 0)
        #expect(root.totalsAreConsistent)
    }

    @Test func rescanningTheViewsFolderLeavesItUnopened() throws {
        let tree = try Self.makeTree()
        let result = FolderScanner(path: tree.root, boundary: Self.boundary(for: tree, scanning: tree.root)).run()
        let total = result.root.allocatedSize

        let outcome = result.rescan(try #require(result.root.child("volume")?.child("views")))

        guard case .replaced(let fresh) = outcome else {
            Issue.record("expected the folder to be replaced, got \(outcome)")
            return
        }
        #expect(fresh.status == .diskImageContents)
        #expect(fresh.children.isEmpty)
        #expect(result.root.allocatedSize == total)
        #expect(result.root.totalsAreConsistent)
    }

    @Test func rescanningTheFolderAboveLeavesTheViewsUnopened() throws {
        let tree = try Self.makeTree()
        let result = FolderScanner(path: tree.root, boundary: Self.boundary(for: tree, scanning: tree.root)).run()
        let total = result.root.allocatedSize

        result.rescan(try #require(result.root.child("volume")))

        #expect(result.root.child("volume")?.child("views")?.status == .diskImageContents)
        #expect(result.root.allocatedSize == total)
    }

    @Test func fileTypesLeaveTheShownContentsOut() throws {
        let tree = try Self.makeTree()
        let boundary = Self.boundary(for: tree, scanning: tree.root)

        let report = FileTypeAnalyzer(path: tree.root, boundary: boundary).run()
        let viewsReport = FileTypeAnalyzer(path: tree.path("volume/views"), boundary: boundary).run()

        #expect(report.fileCount == 1)
        #expect(report.types.map(\.fileExtension) == ["dmg"])
        #expect(viewsReport.fileCount == 0)
        #expect(viewsReport.types.isEmpty)
    }

    @Test func scanningOnlyTheViewsFolderMeasuresWhatItShows() throws {
        let tree = try Self.makeTree()
        let views = tree.path("volume/views")

        let root = FolderScanner(path: views, boundary: Self.boundary(for: tree, scanning: views)).run().root

        #expect(root.status == .ok)
        #expect(root.fileCount == 3)
        #expect(root.logicalSize == 300_000)
    }
}

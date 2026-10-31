import Foundation
import Testing
@testable import FileTreeCore

@Suite("DirectoryListing")
struct DirectoryListingTests {
    @Test func listsEveryKindOfEntry() throws {
        let tree = try TemporaryTree()
        try tree.makeFile("file.txt", size: 1_234)
        try tree.makeFolder("folder")
        try tree.makeSymlink("link", pointingTo: "file.txt")
        #expect(mkfifo(tree.path("pipe"), 0o644) == 0)

        let (items, error) = DirectoryListing.items(in: tree.root)

        #expect(error == 0)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        #expect(byName.count == 4)
        #expect(byName["file.txt"]?.kind == .file)
        #expect(byName["file.txt"]?.logicalSize == 1_234)
        #expect(byName["file.txt"]?.allocatedSize == tree.allocatedSize("file.txt"))
        #expect(byName["file.txt"]?.linkCount == 1)
        #expect(byName["folder"]?.kind == .directory)
        #expect(byName["link"]?.kind == .symlink)
        #expect(byName["pipe"]?.kind == .other)
    }

    @Test func readsLargeFoldersAndUnicodeNames() throws {
        let tree = try TemporaryTree()
        let longSuffix = String(repeating: "x", count: 100)
        for index in 0..<3_000 {
            #expect(FileManager.default.createFile(atPath: tree.path("file-\(index)-\(longSuffix)"), contents: nil))
        }
        try tree.makeFile("Привет, мир 🌍.txt", size: 10)

        let (items, error) = DirectoryListing.items(in: tree.root)

        #expect(error == 0)
        #expect(items.count == 3_001)
        #expect(items.contains { $0.name == "Привет, мир 🌍.txt" && $0.logicalSize == 10 })
    }

    @Test func reportsWhyAFolderCannotBeListed() {
        let (items, error) = DirectoryListing.items(in: "/no/such/folder-\(UUID().uuidString)")

        #expect(items.isEmpty)
        #expect(error == ENOENT)
    }
}

@Suite("FileTypeAnalyzer")
struct FileTypeAnalyzerTests {
    @Test func groupsFilesByExtensionIgnoringCase() throws {
        let tree = try TemporaryTree()
        try tree.makeFile("a.TXT", size: 100)
        try tree.makeFile("sub/b.txt", size: 20_000)
        try tree.makeFile("sub/deeper/archive.tar.gz", size: 300)
        try tree.makeFile("README", size: 50)
        try tree.makeFile(".zshrc", size: 10)
        try tree.makeFolder("empty")
        try tree.makeHardLink(from: "sub/b.txt", to: "b-link.txt")

        let report = FileTypeAnalyzer(path: tree.root, boundary: ScanBoundary(rootPath: tree.root)).run()

        #expect(!report.wasCancelled)
        #expect(report.fileCount == 6)
        let byExtension = Dictionary(uniqueKeysWithValues: report.types.map { ($0.fileExtension, $0) })
        #expect(Set(byExtension.keys) == ["txt", "gz", ""])
        let text = try #require(byExtension["txt"])
        #expect(text.fileCount == 2)
        #expect(text.logicalSize == 20_100)
        #expect(text.allocatedSize == tree.allocatedSize("a.TXT") + tree.allocatedSize("sub/b.txt"))
        #expect(text.largestFileSize == tree.allocatedSize("sub/b.txt"))
        #expect([tree.path("sub/b.txt"), tree.path("b-link.txt")].contains(text.largestFilePath))
        #expect(byExtension[""]?.fileCount == 2)
        #expect(byExtension["gz"]?.logicalSize == 300)
        #expect(report.types.first?.fileExtension == "txt")
    }

    @Test func cancellingBeforeRunningReportsNothing() throws {
        let tree = try TemporaryTree()
        try tree.makeFile("a.txt", size: 10)
        let analyzer = FileTypeAnalyzer(path: tree.root, boundary: ScanBoundary(rootPath: tree.root))
        analyzer.cancel()

        let report = analyzer.run()

        #expect(report.wasCancelled)
        #expect(report.types.isEmpty)
    }

    @Test(arguments: zip(
        ["Movie.MOV", "archive.tar.gz", "README", ".zshrc", "file.", "a.b", "x", ".", "..", "photo.HEIC"],
        ["mov", "gz", "", "", "", "b", "", "", "", "heic"]
    ))
    func extensionOfAFileName(name: String, expected: String) {
        #expect(name.withCString(FileTypeAnalyzer.fileExtension(of:)) == expected)
    }
}

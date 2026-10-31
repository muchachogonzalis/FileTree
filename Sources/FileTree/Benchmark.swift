import FileTreeCore
import Foundation

/// `FileTree --benchmark <path>`: measures a folder without UI and prints the biggest folders.
enum Benchmark {
    static func run(path: String, options: LaunchOptions) -> Never {
        let rootPath = FileSystem.canonicalPath(path)
        let boundary = ScanBoundary(rootPath: rootPath, excludedPaths: Set(options.excludedPaths.map(FileSystem.canonicalPath)))
        let scanner = FolderScanner(path: rootPath, boundary: boundary,
                                    threadCount: options.threadCount ?? FolderScanner.defaultThreadCount)
        let result = scanner.run()
        let root = result.root

        print("Scanned \(rootPath) in \(String(format: "%.2f", result.duration)) s"
            + " with \(options.threadCount ?? FolderScanner.defaultThreadCount) threads")
        print("On disk \(bytes(root.allocatedSize)) (\(root.allocatedSize) bytes), size \(bytes(root.logicalSize))")
        print("\(root.fileCount) files, \(root.folderCount) folders, \(root.problemCount) unreadable,"
            + " shared files and clones counted once: \(result.sharedData.count)")
        print("APFS container: \(boundary.rootContainer ?? "none"), skipped firmlink copies: \(boundary.duplicateSources.count),"
            + " disk image views left unopened: \(boundary.diskImageViews.count)")
        printChildren(of: root, depth: options.depth, indent: "  ")
        exit(0)
    }

    private static func printChildren(of folder: FolderNode, depth: Int, indent: String) {
        guard depth > 0 else { return }
        for child in folder.children.sorted(by: { $0.allocatedSize > $1.allocatedSize }) {
            let share = folder.allocatedSize > 0 ? Double(child.allocatedSize) / Double(folder.allocatedSize) * 100 : 0
            var line = indent + String(format: "%5.1f%%  %10@  ", share, bytes(child.allocatedSize)) + child.name
            if child.status != .ok { line += "  [\(child.status)]" }
            if child.problemCount > 0, !child.status.isProblem { line += "  (\(child.problemCount) unreadable inside)" }
            print(line)
            printChildren(of: child, depth: depth - 1, indent: indent + "    ")
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

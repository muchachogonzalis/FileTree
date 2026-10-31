import AppKit
import FileTreeCore

/// `FileTree <folder> --snapshot <dir>`: drives the window through a scan and saves PNG images
/// of it, to check the interface without a person at the screen. The window stays invisible.
@MainActor
final class SnapshotAutomation {
    private let directory: URL
    private let controller: MainWindowController
    private let stopAfter: Double?
    private let selectPath: String?

    init(directory: String, controller: MainWindowController, stopAfter: Double?, selectPath: String?) {
        self.directory = URL(fileURLWithPath: directory, isDirectory: true)
        self.controller = controller
        self.stopAfter = stopAfter
        self.selectPath = selectPath
    }

    func run(scanPath: String?) {
        guard let window = controller.window else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        controller.showWindow(nil)
        Task { @MainActor in
            await perform(scanPath: scanPath)
            NSApp.terminate(nil)
        }
    }

    private func perform(scanPath: String?) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await pause(0.8)
        save("1-start")
        guard let scanPath else { return }

        controller.scan(URL(fileURLWithPath: scanPath))
        await pause(0.4)
        if controller.isScanning {
            save("2-progress")
        }
        if let stopAfter {
            await pause(max(0, stopAfter - 0.4))
            controller.stopScan(nil)
        }
        await waitUntil(seconds: 900) { !self.controller.isScanning }
        await pause(0.6)
        save("3-results")

        let results = controller.results
        guard let root = results.tree.root else { return }
        let biggest = Ordering.sortFolders(root.children, by: nil)
        if let selectPath, let folder = folder(at: FileSystem.canonicalPath(selectPath), in: root) {
            results.tree.select(folder)
        } else if let folder = biggest.first(where: { !$0.children.isEmpty }) ?? biggest.first {
            results.tree.select(folder)
            results.tree.outlineView.expandItem(folder)
        }
        await waitUntil(seconds: 60) { results.details.contents.isLoaded }
        await pause(1.0)
        save("4-folder")

        results.details.selectTab(1)
        await waitUntil(seconds: 900) { results.details.fileTypes.isLoaded }
        await pause(0.5)
        save("5-file-types")
        results.details.selectTab(0)

        if let folder = results.selectedFolder {
            controller.rescanFolder(folder)
            await waitUntil(seconds: 900) { !self.controller.isBusy }
            await waitUntil(seconds: 60) { results.details.contents.isLoaded }
            await pause(0.5)
            save("6-after-rescan")
        }

        results.tree.outlineView.sortDescriptors = [NSSortDescriptor(key: SortKey.name, ascending: true)]
        await pause(1.0)
        save("7-sorted-by-name")
        results.tree.outlineView.sortDescriptors = [NSSortDescriptor(key: SortKey.allocated, ascending: false)]
    }

    private func folder(at path: String, in root: FolderNode) -> FolderNode? {
        var node = root
        let relative = path.dropFirst(root.path.count).split(separator: "/")
        for name in relative {
            guard let child = node.children.first(where: { $0.name == name }) else { return nil }
            node = child
        }
        return node
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func waitUntil(seconds: Double, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            await pause(0.1)
        }
    }

    private func save(_ name: String) {
        guard let frame = controller.window?.contentView?.superview else { return }
        frame.layoutSubtreeIfNeeded()
        guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        let url = directory.appendingPathComponent(name + ".png")
        do {
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
            print("snapshot \(url.path)")
        } catch {
            print("could not save \(url.path): \(error)")
        }
    }
}

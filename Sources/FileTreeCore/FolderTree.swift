/// Operations on a tree of `FolderNode`s.
public enum FolderTree {
    /// What `finishRescan` did with the folder.
    public enum RescanOutcome {
        /// The fresh scan took the folder's place.
        case replaced(by: FolderNode)
        /// The folder no longer exists and was taken out of the tree.
        case removed
        /// The rescan was stopped; the earlier results stay.
        case kept
    }

    public static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// Computes the totals of `root` and of every folder below it.
    public static func computeTotals(of root: FolderNode) {
        // Iterative post-order walk: deep trees must not overflow the stack.
        var stack: [(node: FolderNode, childrenDone: Bool)] = [(root, false)]
        while let (node, childrenDone) = stack.popLast() {
            if childrenDone {
                node.recalculateTotals()
            } else {
                stack.append((node, true))
                for child in node.children {
                    stack.append((child, false))
                }
            }
        }
    }

    /// Puts the result of rescanning `old` into the tree.
    ///
    /// Before the rescan started, `sharedData.release(inside: old)` returned `released`. A
    /// stopped rescan is discarded and the registry restored. Otherwise the fresh tree replaces
    /// `old` (or `old` is removed if the folder is gone), and data that only `old` counted but
    /// that other folders still hold is counted in one of those folders from now on.
    public static func finishRescan(of old: FolderNode, with fresh: ScanResult,
                                    released: SharedDataRegistry.ReleasedClaims,
                                    sharedData: SharedDataRegistry) -> RescanOutcome {
        if fresh.wasCancelled {
            sharedData.restore(released, abandoning: fresh.root)
            return .kept
        }
        let outcome: RescanOutcome
        if fresh.root.status == .vanished {
            remove(old)
            outcome = .removed
        } else {
            replace(old, with: fresh.root)
            outcome = .replaced(by: fresh.root)
        }
        for heir in sharedData.reassignUnclaimed() {
            heir.folder.ownLogicalSize = heir.folder.ownLogicalSize.addingSaturated(heir.logicalSize)
            heir.folder.ownAllocatedSize = heir.folder.ownAllocatedSize.addingSaturated(heir.allocatedSize)
            recalculateAncestors(startingAt: heir.folder)
        }
        return outcome
    }

    /// Puts `new`, the root of a fresh scan of the same folder, in place of `old` and updates
    /// the totals of every folder above it.
    public static func replace(_ old: FolderNode, with new: FolderNode) {
        guard let parent = old.parent, let index = parent.children.firstIndex(where: { $0 === old }) else { return }
        new.rootPath = nil
        new.parent = parent
        parent.children[index] = new
        detach(old)
        recalculateAncestors(startingAt: parent)
    }

    /// Takes `node` out of its tree and updates the totals of every folder above it.
    public static func remove(_ node: FolderNode) {
        guard let parent = node.parent else { return }
        parent.children.removeAll { $0 === node }
        detach(node)
        recalculateAncestors(startingAt: parent)
    }

    /// Cuts a node loose, keeping its path: menus and other code may still hold it.
    private static func detach(_ node: FolderNode) {
        node.rootPath = node.path
        node.parent = nil
    }

    static func recalculateAncestors(startingAt folder: FolderNode) {
        var current: FolderNode? = folder
        while let node = current {
            node.recalculateTotals()
            current = node.parent
        }
    }

    /// Counts the folders at and below `root` for which `predicate` holds.
    public static func countFolders(in root: FolderNode, where predicate: (FolderNode) -> Bool) -> Int {
        var count = 0
        var stack = [root]
        while let node = stack.popLast() {
            if predicate(node) { count += 1 }
            stack.append(contentsOf: node.children)
        }
        return count
    }
}

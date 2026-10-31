import Darwin

/// One entry directly inside a folder, as it is on disk right now.
public struct DirectoryItem: Sendable {
    public let name: String
    public let kind: EntryKind
    public let logicalSize: Int64
    public let allocatedSize: Int64
    public let modificationTime: Int64
    public let linkCount: UInt32
    /// An APFS clone: shares some or all of its data blocks with other files.
    public let isClone: Bool
    /// A full APFS clone: shares all its data blocks with another file.
    public let sharesAllBlocks: Bool
    public let device: Int32
    public let fileID: UInt64
    public let cloneID: UInt64
    public let isMountPoint: Bool

    /// For a file in `folder` whose data it shares with other entries (other names of a
    /// hard-linked file, full clones): the folder where the scan counted that data, when it is
    /// not `folder`. Nil when the data is counted in `folder` or not shared.
    public func dataCountedElsewhere(than folder: FolderNode, in sharedData: SharedDataRegistry) -> FolderNode? {
        guard kind == .file else { return nil }
        if linkCount > 1, let owner = sharedData.owner(ofFileOn: device, fileID: fileID), owner !== folder {
            return owner
        }
        if sharesAllBlocks, let owner = sharedData.owner(ofCloneOn: device, cloneID: cloneID), owner !== folder {
            return owner
        }
        return nil
    }
}

public enum DirectoryListing {
    /// Lists the entries directly inside `path`. `error` is 0, or the errno that prevented
    /// listing the folder (completely).
    public static func items(in path: String) -> (items: [DirectoryItem], error: Int32) {
        let descriptor = FileSystem.openDirectory(path)
        guard descriptor >= 0 else { return ([], errno) }
        defer { close(descriptor) }

        var items: [DirectoryItem] = []
        let error = DirectoryReader().forEachEntry(in: descriptor) { entry in
            items.append(DirectoryItem(
                name: entry.name,
                kind: entry.kind,
                logicalSize: entry.logicalSize,
                allocatedSize: entry.allocatedSize,
                modificationTime: entry.modificationTime,
                linkCount: entry.linkCount,
                isClone: entry.kind == .file && entry.mayShareBlocks,
                sharesAllBlocks: entry.kind == .file && entry.sharesAllBlocks,
                device: entry.device,
                fileID: entry.fileID,
                cloneID: entry.cloneID,
                isMountPoint: entry.isMountPoint || entry.isMountTrigger
            ))
        }
        return (items, error)
    }
}

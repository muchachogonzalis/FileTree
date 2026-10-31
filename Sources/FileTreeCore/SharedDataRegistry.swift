import Foundation

/// Data that several directory entries can share.
enum SharedDataKey: Hashable, Sendable {
    /// A file with several hard links: one file under several names.
    case file(device: Int32, fileID: UInt64)
    /// The data of full APFS clones: separate files that share all their data blocks.
    case clone(device: Int32, cloneID: UInt64)
}

/// Where shared data is counted and which other folders hold it.
fileprivate struct SharedDataEntry: Sendable {
    /// The folder whose totals include the data; nil while that folder is being rescanned.
    var owner: FolderNode?
    /// Other folders holding the same data; there it counts as nothing.
    var sightings: [FolderNode]
    /// What the owner's totals include for the data.
    var logicalSize: Int64
    var allocatedSize: Int64
}

/// Data shared by several directory entries — files with several hard links, and full APFS
/// clones such as copies made in the Finder — is counted once, in the folder where the scan met
/// it first. The registry remembers that folder and every other folder holding the same data, so
/// that a rescan can hand the count over when the counted copy is gone.
///
/// Scans claim data from their worker threads. Everything that looks at the tree (`release`,
/// `restore`, `reassignUnclaimed`, `snapshot`) runs on the main thread, which owns the tree.
public final class SharedDataRegistry: @unchecked Sendable {
    /// What `release(inside:)` changed, so that a stopped rescan can be undone.
    public struct ReleasedClaims: Sendable {
        fileprivate let previous: [SharedDataKey: SharedDataEntry]
    }

    private let lock = NSLock()
    private var entries: [SharedDataKey: SharedDataEntry] = [:]

    public init() {}

    /// Records a sighting of shared data in `folder`. Returns true when `folder` is to count it
    /// (the first sighting, or the first since its counting folder was released for a rescan),
    /// false when it is counted elsewhere.
    func claim(_ key: SharedDataKey, in folder: FolderNode, logicalSize: Int64, allocatedSize: Int64) -> Bool {
        lock.withLock {
            guard entries[key] != nil else {
                entries[key] = SharedDataEntry(owner: folder, sightings: [], logicalSize: logicalSize,
                                               allocatedSize: allocatedSize)
                return true
            }
            guard entries[key]!.owner == nil else {
                entries[key]!.sightings.append(folder)
                return false
            }
            entries[key]!.owner = folder
            entries[key]!.logicalSize = logicalSize
            entries[key]!.allocatedSize = allocatedSize
            return true
        }
    }

    func owner(of key: SharedDataKey) -> FolderNode? {
        lock.withLock { entries[key]?.owner }
    }

    /// The folder counting a hard-linked file, if the scan met it.
    public func owner(ofFileOn device: Int32, fileID: UInt64) -> FolderNode? {
        owner(of: .file(device: device, fileID: fileID))
    }

    /// The folder counting the data of a full clone, if the scan met it.
    public func owner(ofCloneOn device: Int32, cloneID: UInt64) -> FolderNode? {
        owner(of: .clone(device: device, cloneID: cloneID))
    }

    /// Prepares a rescan of `folder`: forgets the sightings in it and below it, and leaves the
    /// data counted there without a counting folder until the rescan claims it again.
    public func release(inside folder: FolderNode) -> ReleasedClaims {
        lock.withLock {
            var previous: [SharedDataKey: SharedDataEntry] = [:]
            for (key, entry) in entries {
                let ownerInside = entry.owner?.isInside(folder) ?? false
                guard ownerInside || entry.sightings.contains(where: { $0.isInside(folder) }) else { continue }
                previous[key] = entry
                entries[key]!.sightings.removeAll { $0.isInside(folder) }
                if ownerInside {
                    entries[key]!.owner = nil
                }
            }
            return ReleasedClaims(previous: previous)
        }
    }

    /// Undoes `release(inside:)` when the rescan is stopped: forgets what the partial rescan,
    /// rooted at `abandoned`, claimed or saw, and puts `claims` back.
    public func restore(_ claims: ReleasedClaims, abandoning abandoned: FolderNode) {
        lock.withLock {
            for key in Array(entries.keys) {
                guard var entry = entries[key] else { continue }
                entry.sightings.removeAll { $0.isInside(abandoned) }
                if entry.owner?.isInside(abandoned) == true {
                    entry.owner = nil
                }
                entries[key] = entry.owner == nil && entry.sightings.isEmpty ? nil : entry
            }
            for (key, entry) in claims.previous {
                entries[key] = entry
            }
        }
    }

    /// Ends a rescan: data whose counting folder was rescanned and no longer holds it is now
    /// counted in another folder that still does. Returns those folders and what they take over.
    func reassignUnclaimed() -> [(folder: FolderNode, logicalSize: Int64, allocatedSize: Int64)] {
        lock.withLock {
            var heirs: [(folder: FolderNode, logicalSize: Int64, allocatedSize: Int64)] = []
            for key in Array(entries.keys) where entries[key]?.owner == nil {
                guard let entry = entries[key], let heir = entry.sightings.first else {
                    entries[key] = nil
                    continue
                }
                entries[key]!.owner = heir
                entries[key]!.sightings.removeFirst()
                heirs.append((heir, entry.logicalSize, entry.allocatedSize))
            }
            return heirs
        }
    }

    /// Which shared data the scan counted inside `folder`, for deciding on other threads how a
    /// new walk of that folder should count it.
    public func snapshot(countedInside folder: FolderNode) -> SharedDataSnapshot {
        lock.withLock {
            var countedInside = Set<SharedDataKey>()
            for (key, entry) in entries where entry.owner?.isInside(folder) == true {
                countedInside.insert(key)
            }
            return SharedDataSnapshot(countedInside: countedInside, known: Set(entries.keys))
        }
    }

    /// Number of shared files and clones remembered.
    public var count: Int {
        lock.withLock { entries.count }
    }
}

/// See `SharedDataRegistry.snapshot(countedInside:)`.
public struct SharedDataSnapshot: Sendable {
    let countedInside: Set<SharedDataKey>
    let known: Set<SharedDataKey>

    /// True if the scan counted this data inside the folder, or never met it.
    func isCountedInside(_ key: SharedDataKey) -> Bool {
        countedInside.contains(key) || !known.contains(key)
    }
}

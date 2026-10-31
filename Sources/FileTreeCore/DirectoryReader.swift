import Darwin

/// What kind of file system object a directory entry is.
public enum EntryKind: Sendable {
    case directory
    case file
    case symlink
    case other
}

/// One entry of a directory listing. `namePointer` points into the reader's buffer and is only
/// valid inside the `DirectoryReader.forEachEntry` callback.
struct RawDirectoryEntry {
    let namePointer: UnsafePointer<CChar>
    let kind: EntryKind
    /// Logical size of all forks, in bytes.
    let logicalSize: Int64
    /// Bytes actually allocated on disk for all forks.
    let allocatedSize: Int64
    let modificationTime: Int64
    let fileID: UInt64
    /// Device of the volume that really holds the entry, even inside an APFS volume group.
    let device: Int32
    let linkCount: UInt32
    /// BSD flags (st_flags).
    let flags: UInt32
    /// Identifies the file's data; full APFS clones of one another share it.
    let cloneID: UInt64
    /// EF_* flags from <sys/stat.h>.
    let extendedFlags: UInt64
    let isMountPoint: Bool
    /// An automounter trigger: looking inside it would mount something, possibly over the network.
    let isMountTrigger: Bool

    var name: String { String(cString: namePointer) }

    /// The name's bytes, NUL included. Needed to open entries whose names are not valid UTF-8,
    /// which `name` cannot represent exactly (possible on network and foreign file systems).
    var rawName: [CChar] {
        Array(UnsafeBufferPointer(start: namePointer, count: strlen(namePointer) + 1))
    }

    /// True if `name` (made from this entry) holds the exact bytes of the name.
    func isExactlyNamed(_ name: String) -> Bool {
        name.utf8.elementsEqual(UnsafeRawBufferPointer(start: namePointer, count: strlen(namePointer)))
    }

    /// Stored in iCloud (or another file provider) without local data.
    var isDataless: Bool { flags & UInt32(SF_DATALESS) != 0 }

    /// A full APFS clone: all its data blocks are shared with another file.
    var sharesAllBlocks: Bool { extendedFlags & UInt64(EF_SHARES_ALL_BLOCKS) != 0 }
    /// Possibly an APFS clone: some data blocks may be shared with another file.
    var mayShareBlocks: Bool { extendedFlags & UInt64(EF_MAY_SHARE_BLOCKS) != 0 }
}

/// Lists directories with getattrlistbulk(2), which returns names and sizes of many entries per
/// system call. A reader reuses one buffer, so every thread needs its own reader.
final class DirectoryReader {
    private static let bufferSize = 256 * 1024
    // Object types from <sys/vnode.h>.
    private static let regularFileType: UInt32 = 1
    private static let directoryType: UInt32 = 2
    private static let symlinkType: UInt32 = 5

    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: DirectoryReader.bufferSize, alignment: 16)
    private var request = attrlist()

    init() {
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_ERROR | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE
                | ATTR_CMN_MODTIME | ATTR_CMN_FLAGS | ATTR_CMN_FILEID)
        request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE)
        // With FSOPT_ATTR_CMN_EXTENDED the fork attributes are extended common attributes.
        request.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS)
    }

    deinit {
        buffer.deallocate()
    }

    /// Calls `body` for every entry of the directory open at `directory`.
    /// Returns 0 when the whole directory was read, otherwise the errno that stopped the listing;
    /// the entries delivered before the error are still valid.
    func forEachEntry(in directory: Int32, _ body: (RawDirectoryEntry) -> Void) -> Int32 {
        let options = UInt64(FSOPT_RETURN_REALDEV | FSOPT_ATTR_CMN_EXTENDED)
        while true {
            let count = getattrlistbulk(directory, &request, buffer, Self.bufferSize, options)
            if count < 0 { return errno }
            if count == 0 { return 0 }
            let end = UnsafeRawPointer(buffer) + Self.bufferSize
            var record = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(record.loadUnaligned(as: UInt32.self))
                guard length > 0, record + length <= end else { return EIO }
                if let entry = Self.parse(record, end: record + length) {
                    body(entry)
                }
                record += length
            }
        }
    }

    /// Decodes one record. Attributes come in a fixed order (see getattrlist(2)) and only the
    /// ones flagged in the leading attribute_set_t are present.
    private static func parse(_ record: UnsafeRawPointer, end: UnsafeRawPointer) -> RawDirectoryEntry? {
        var cursor = Cursor(position: record + MemoryLayout<UInt32>.size, end: end)
        guard let returned = cursor.read(attribute_set_t.self) else { return nil }
        let common = returned.commonattr

        if common & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            // A per-entry error. Whatever attributes did come back are still usable.
            _ = cursor.read(UInt32.self)
        }

        guard common & attrgroup_t(ATTR_CMN_NAME) != 0, let nameField = cursor.skip(MemoryLayout<attrreference_t>.size)
        else { return nil }
        let reference = nameField.loadUnaligned(as: attrreference_t.self)
        let name = nameField + Int(reference.attr_dataoffset)
        let nameLength = Int(reference.attr_length)
        guard nameLength > 1, name >= record, name + nameLength <= end,
              name.load(fromByteOffset: nameLength - 1, as: UInt8.self) == 0
        else { return nil }

        let device = common & attrgroup_t(ATTR_CMN_DEVID) != 0 ? cursor.read(Int32.self) ?? 0 : 0
        let type = common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 ? cursor.read(UInt32.self) ?? 0 : 0
        var modificationTime: Int64 = 0
        if common & attrgroup_t(ATTR_CMN_MODTIME) != 0, let time = cursor.read(timespec.self) {
            modificationTime = Int64(time.tv_sec)
        }
        let flags = common & attrgroup_t(ATTR_CMN_FLAGS) != 0 ? cursor.read(UInt32.self) ?? 0 : 0
        let fileID = common & attrgroup_t(ATTR_CMN_FILEID) != 0 ? cursor.read(UInt64.self) ?? 0 : 0

        var mountStatus: UInt32 = 0
        if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
            mountStatus = cursor.read(UInt32.self) ?? 0
        }

        let fileAttributes = returned.fileattr
        let linkCount = fileAttributes & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 ? cursor.read(UInt32.self) ?? 1 : 1
        let logicalSize = fileAttributes & attrgroup_t(ATTR_FILE_TOTALSIZE) != 0 ? cursor.read(Int64.self) ?? 0 : 0
        let allocatedSize = fileAttributes & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 ? cursor.read(Int64.self) ?? 0 : 0

        let extended = returned.forkattr
        let cloneID = extended & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0 ? cursor.read(UInt64.self) ?? 0 : 0
        let extendedFlags = extended & attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) != 0 ? cursor.read(UInt64.self) ?? 0 : 0

        let kind: EntryKind
        switch type {
        case directoryType: kind = .directory
        case regularFileType: kind = .file
        case symlinkType: kind = .symlink
        default: kind = .other
        }

        return RawDirectoryEntry(
            namePointer: name.assumingMemoryBound(to: CChar.self),
            kind: kind,
            logicalSize: max(0, logicalSize),
            allocatedSize: max(0, allocatedSize),
            modificationTime: modificationTime,
            fileID: fileID,
            device: device,
            linkCount: linkCount,
            flags: flags,
            cloneID: cloneID,
            extendedFlags: extendedFlags,
            isMountPoint: mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0,
            isMountTrigger: mountStatus & UInt32(DIR_MNTSTATUS_TRIGGER) != 0
        )
    }
}

/// Reads consecutive values from an attribute record without running past its end.
private struct Cursor {
    var position: UnsafeRawPointer
    let end: UnsafeRawPointer

    mutating func read<T: BitwiseCopyable>(_ type: T.Type) -> T? {
        guard let start = skip(MemoryLayout<T>.size) else { return nil }
        return start.loadUnaligned(as: T.self)
    }

    /// Advances past `size` bytes and returns where they start.
    mutating func skip(_ size: Int) -> UnsafeRawPointer? {
        guard position + size <= end else { return nil }
        defer { position += size }
        return position
    }
}

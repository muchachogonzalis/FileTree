import Darwin

public enum FileSystem {
    /// Opens a directory for listing without following a symlink in its last component.
    /// Paths longer than PATH_MAX are opened one component at a time.
    /// Returns the descriptor, or -1 with `errno` set.
    static func openDirectory(_ path: String) -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let descriptor = open(path, flags)
        if descriptor >= 0 || errno != ENAMETOOLONG { return descriptor }
        return openByComponents(path, flags: flags)
    }

    /// Opens the subfolder `name` of the open folder `parent`; without a parent, opens `path`.
    /// Opening relative to the parent skips resolving the whole path again, which matters when
    /// several threads open thousands of folders below the same parents.
    /// - Parameter rawName: the name's exact bytes when `name` cannot hold them (invalid UTF-8).
    static func openDirectory(named name: String, rawName: [CChar]? = nil, in parent: DirectoryHandle?,
                              path: String) -> Int32 {
        guard let parent else { return openDirectory(path) }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        guard let rawName else { return openat(parent.descriptor, name, flags) }
        return rawName.withUnsafeBufferPointer { openat(parent.descriptor, $0.baseAddress!, flags) }
    }

    /// A scan keeps a folder open until its subfolders are opened; allow more open files than
    /// the default 256 so that deep and wide trees do not run out.
    public static func raiseOpenFileLimit(to wanted: rlim_t = 10_240) {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < wanted else { return }
        limit.rlim_cur = min(wanted, limit.rlim_max)
        setrlimit(RLIMIT_NOFILE, &limit)
    }

    private static func openByComponents(_ path: String, flags: Int32) -> Int32 {
        let components = path.split(separator: "/")
        var current = open("/", O_SEARCH | O_CLOEXEC)
        guard current >= 0 else { return -1 }
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            let next = openat(current, String(component), isLast ? flags : O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
            let error = errno
            close(current)
            guard next >= 0 else {
                errno = error
                return -1
            }
            current = next
        }
        return current
    }

    /// The canonical absolute path: symlinks resolved, no "." or "..", no trailing slash.
    public static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// An open folder, closed when the last work item that refers to it is gone.
final class DirectoryHandle: @unchecked Sendable {
    let descriptor: Int32

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }
}

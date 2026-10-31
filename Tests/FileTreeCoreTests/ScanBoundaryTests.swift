import Foundation
import Testing
@testable import FileTreeCore

@Suite("ScanBoundary")
struct ScanBoundaryTests {
    static let firmlinks = ScanBoundary.parseFirmlinks("""
        /AppleInternal\tAppleInternal
        /Applications\tApplications
        /Library\tLibrary
        /System/Library/Caches\tSystem/Library/Caches
        /Users\tUsers
        /Volumes\tVolumes
        /private\tprivate
        /usr/local\tusr/local/

        not a firmlink
        relative\tpath
        """)

    static let mounts = [
        "/": "/dev/disk3s1s1",
        "/System/Volumes/Data": "/dev/disk3s5",
        "/System/Volumes/VM": "/dev/disk3s6",
        "/System/Volumes/Data/home": "map auto_home",
        "/dev": "devfs",
        "/Volumes/USB": "/dev/disk5s1",
        "/Volumes/share": "//user@nas/share",
    ]

    @Test func findsTheVolumeHoldingAPath() {
        #expect(ScanBoundary.mountSource(of: "/Users/someone", in: Self.mounts) == "/dev/disk3s1s1")
        #expect(ScanBoundary.mountSource(of: "/", in: Self.mounts) == "/dev/disk3s1s1")
        #expect(ScanBoundary.mountSource(of: "/System/Volumes/Data/private", in: Self.mounts) == "/dev/disk3s5")
        #expect(ScanBoundary.mountSource(of: "/Volumes/USB/Photos", in: Self.mounts) == "/dev/disk5s1")
        #expect(ScanBoundary.mountSource(of: "/x", in: [:]) == nil)
    }

    @Test func includesOnlyVolumesOfTheSameContainer() {
        let boundary = ScanBoundary(rootPath: "/", excludedPaths: [], firmlinks: [], mountSources: Self.mounts)

        #expect(boundary.rootContainer == "disk3")
        #expect(boundary.includesVolume(mountedAt: "/System/Volumes/VM"))
        #expect(boundary.includesVolume(mountedAt: "/System/Volumes/Data"))
        #expect(!boundary.includesVolume(mountedAt: "/Volumes/USB"))
        #expect(!boundary.includesVolume(mountedAt: "/Volumes/share"))
        #expect(!boundary.includesVolume(mountedAt: "/System/Volumes/Data/home"))
        #expect(!boundary.includesVolume(mountedAt: "/dev"))
        #expect(!boundary.includesVolume(mountedAt: "/Volumes/mounted-later"))
    }

    @Test func aNetworkShareHasNoContainer() {
        let boundary = ScanBoundary(rootPath: "/Volumes/share/docs", excludedPaths: [], firmlinks: [], mountSources: Self.mounts)

        #expect(boundary.rootContainer == nil)
        #expect(!boundary.includesVolume(mountedAt: "/Volumes/USB"))
    }

    @Test func parsesTheFirmlinksFile() {
        #expect(Self.firmlinks.count == 8)
        #expect(Self.firmlinks.contains(.init(source: "/usr/local", target: "usr/local")))
        #expect(Self.firmlinks.contains(.init(source: "/System/Library/Caches", target: "System/Library/Caches")))
    }

    @Test func scanningTheStartupDiskSkipsTheDataVolumeCopies() {
        let boundary = ScanBoundary(rootPath: "/", excludedPaths: [], firmlinks: Self.firmlinks, mountSources: Self.mounts)

        #expect(boundary.duplicateSources.count == 8)
        #expect(boundary.duplicateSources["/System/Volumes/Data/Users"] == "/Users")
        #expect(boundary.skips("/System/Volumes/Data/usr/local"))
        #expect(boundary.skips("/System/Volumes/Data/System/Library/Caches"))
        #expect(!boundary.skips("/Users"))
        #expect(!boundary.skips("/System/Volumes/Data"))
        #expect(!boundary.skips("/System/Volumes/Data/usr"))
        #expect(!boundary.skips("/System/Volumes/Data/.Spotlight-V100"))
    }

    @Test func scanningASystemFolderSkipsOnlyTheCopiesInsideIt() {
        let boundary = ScanBoundary(rootPath: "/System", excludedPaths: [], firmlinks: Self.firmlinks, mountSources: Self.mounts)

        #expect(boundary.duplicateSources == ["/System/Volumes/Data/System/Library/Caches": "/System/Library/Caches"])
    }

    @Test(arguments: ["/System/Volumes/Data", "/System/Volumes/Data/Users", "/Users/someone", "/Volumes/External", "/Library"])
    func foldersHoldingOnlyOneCopySkipNothing(root: String) {
        let boundary = ScanBoundary(rootPath: root, excludedPaths: [], firmlinks: Self.firmlinks, mountSources: [:])

        #expect(boundary.duplicateSources.isEmpty)
    }

    @Test(arguments: ["/", "/System", "/System/Volumes", "/System/Volumes/Preboot"])
    func scansHoldingAllOfPrebootLeaveTheCryptexContentsUnopened(root: String) {
        let boundary = ScanBoundary(rootPath: root, excludedPaths: [], firmlinks: [], mountSources: Self.mounts)

        #expect(boundary.diskImageViews == ["/System/Volumes/Preboot/Cryptexes"])
        #expect(boundary.showsDiskImageContents("/System/Volumes/Preboot/Cryptexes"))
        #expect(!boundary.showsDiskImageContents("/System/Volumes/Preboot"))
        #expect(!boundary.showsDiskImageContents("/System/Volumes/Preboot/Cryptexes/OS"))
        #expect(!boundary.skips("/System/Volumes/Preboot/Cryptexes"), "listed, only not opened")
    }

    @Test(arguments: ["/System/Volumes/Preboot/Cryptexes", "/System/Volumes/Preboot/Cryptexes/OS",
                      "/System/Volumes/Preboot/72AA39C8-3EE7-4FE1-85F9-B3A76E6D354A", "/System/Volumes/Data",
                      "/Users/someone"])
    func scansWithoutTheCryptexImagesMeasureWhatTheyFind(root: String) {
        let boundary = ScanBoundary(rootPath: root, excludedPaths: [], firmlinks: [], mountSources: Self.mounts)

        #expect(boundary.diskImageViews.isEmpty)
    }

    @Test func excludedFoldersAreSkipped() {
        let boundary = ScanBoundary(rootPath: "/Users/a", excludedPaths: ["/Users/a/b"], firmlinks: [], mountSources: [:])

        #expect(boundary.skips("/Users/a/b"))
        #expect(!boundary.skips("/Users/a/c"))
    }

    @Test func findsTheContainerOfAMountSource() {
        #expect(ScanBoundary.container(ofMountSource: "/dev/disk3s1s1") == "disk3")
        #expect(ScanBoundary.container(ofMountSource: "/dev/disk3s5") == "disk3")
        #expect(ScanBoundary.container(ofMountSource: "/dev/disk12s2") == "disk12")
        #expect(ScanBoundary.container(ofMountSource: "/dev/disk4") == "disk4")
        #expect(ScanBoundary.container(ofMountSource: "/dev/diskX") == nil)
        #expect(ScanBoundary.container(ofMountSource: "devfs") == nil)
        #expect(ScanBoundary.container(ofMountSource: "map auto_home") == nil)
        #expect(ScanBoundary.container(ofMountSource: "//user@server/share") == nil)
    }

    @Test func pathContainment() {
        #expect(ScanBoundary.isPath("/a/b", inside: "/"))
        #expect(ScanBoundary.isPath("/a/b", inside: "/a"))
        #expect(ScanBoundary.isPath("/a", inside: "/a"))
        #expect(!ScanBoundary.isPath("/ab", inside: "/a"))
        #expect(!ScanBoundary.isPath("/", inside: "/a"))
    }

    /// The startup disk of the Mac running the tests (macOS 10.15 or later layout).
    @Test func startupDiskOfThisMac() {
        let boundary = ScanBoundary(rootPath: "/")

        #expect(boundary.rootContainer != nil)
        #expect(boundary.duplicateSources["/System/Volumes/Data/Users"] == "/Users")
        #expect(boundary.duplicateSources["/System/Volumes/Data/Applications"] == "/Applications")
        #expect(boundary.includesVolume(mountedAt: "/System/Volumes/Data"))
        #expect(boundary.includesVolume(mountedAt: "/System/Volumes/VM"))
        #expect(!boundary.includesVolume(mountedAt: "/dev"))
        #expect(!boundary.includesVolume(mountedAt: "/Users"))
        if !FileManager.default.fileExists(atPath: "/pkg") {
            // Listed in /usr/share/firmlinks, but without the firmlink the copy is the only one.
            #expect(boundary.duplicateSources["/System/Volumes/Data/pkg"] == nil)
        }
    }
}

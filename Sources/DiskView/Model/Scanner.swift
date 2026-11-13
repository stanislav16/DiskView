import Foundation
import Synchronization

/// Live counters the UI polls while a scan runs.
final class ScanProgress: @unchecked Sendable {
    let files = Atomic<Int>(0)
    let folders = Atomic<Int>(0)
    let bytes = Atomic<Int64>(0)
    let denied = Atomic<Int>(0)
    let cancelled = Atomic<Bool>(false)
    let currentPath = Mutex<String>("")
}

/// Fast parallel scanner built on getattrlistbulk(2): one syscall returns
/// name, type, inode and allocated size for many directory entries at once.
final class DiskScanner: @unchecked Sendable {
    let progress = ScanProgress()

    private static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "photoslibrary", "musiclibrary",
        "tvlibrary", "fcpbundle", "logicx", "band", "xcarchive", "xcodeproj", "xcworkspace",
        "pkg", "mpkg", "rtfd", "pages", "numbers", "key", "sparsebundle", "imovielibrary",
        "playground", "appex", "prefPane", "saver", "qlgenerator", "mdimporter",
    ]

    // Work queue shared by the worker threads.
    private let cond = NSCondition()
    private var stack: [(FileNode, String)] = []
    private var pending = 0
    private let seenInodes = Mutex<Set<UInt64>>([])

    /// Scans `path` and returns a finalized tree. Blocks the calling thread.
    func scan(path: String, displayName: String) -> FileNode {
        let root = FileNode(name: displayName, kind: .directory)
        root.rootPath = path
        stack = [(root, path)]
        pending = 1

        let workerCount = min(16, max(4, ProcessInfo.processInfo.activeProcessorCount * 2))
        let group = DispatchGroup()
        for i in 0..<workerCount {
            group.enter()
            let t = Thread { [self] in
                self.workerLoop()
                group.leave()
            }
            t.name = "DiskView.scan.\(i)"
            t.qualityOfService = .userInitiated
            t.start()
        }
        group.wait()
        root.finalize()
        return root
    }

    private func workerLoop() {
        // Never download iCloud / File Provider items just to look at them. Without this,
        // listing a cloud-only folder blocks until macOS has fetched it from the network.
        // Cloud-only items take no local space, so skipping them keeps the totals honest.
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                           IOPOL_MATERIALIZE_DATALESS_FILES_OFF)

        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }

        while true {
            cond.lock()
            while stack.isEmpty && pending > 0 { cond.wait() }
            guard let job = stack.popLast() else {
                cond.unlock()
                return // pending == 0: everything is done
            }
            cond.unlock()

            let subdirs = progress.cancelled.load(ordering: .relaxed)
                ? [] : scanDirectory(job.0, path: job.1, buf: buf, bufSize: bufSize)

            cond.lock()
            stack.append(contentsOf: subdirs)
            pending += subdirs.count - 1
            if pending == 0 || !subdirs.isEmpty { cond.broadcast() }
            cond.unlock()
        }
    }

    private func scanDirectory(_ node: FileNode, path: String,
                               buf: UnsafeMutableRawPointer, bufSize: Int) -> [(FileNode, String)] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            // EDEADLK = a cloud-only folder we chose not to download; that's not an access problem.
            if errno != EDEADLK { progress.denied.add(1, ordering: .relaxed) }
            return []
        }
        defer { close(fd) }
        progress.folders.add(1, ordering: .relaxed)
        if progress.folders.load(ordering: .relaxed) & 63 == 0 {
            progress.currentPath.withLock { $0 = path }
        }

        let cmnReturned: UInt32 = 0x8000_0000, cmnError: UInt32 = 0x2000_0000
        let cmnName: UInt32 = 0x1, cmnObjType: UInt32 = 0x8, cmnFileID: UInt32 = 0x0200_0000
        let dirMountStatus: UInt32 = 0x4
        let fileLinkCount: UInt32 = 0x1, fileAllocSize: UInt32 = 0x4

        var attrs = attrlist()
        attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = cmnReturned | cmnError | cmnName | cmnObjType | cmnFileID
        attrs.dirattr = dirMountStatus
        attrs.fileattr = fileLinkCount | fileAllocSize

        var subdirs: [(FileNode, String)] = []
        var children: [FileNode] = []
        var localFiles = 0
        var localBytes: Int64 = 0
        let prefix = path.hasSuffix("/") ? path : path + "/"

        while true {
            if progress.cancelled.load(ordering: .relaxed) { break }
            let count = getattrlistbulk(fd, &attrs, buf, bufSize, 0)
            if count < 0 && errno != EDEADLK { progress.denied.add(1, ordering: .relaxed) }
            if count <= 0 { break }
            var entry = buf
            for _ in 0..<Int(count) {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var field = entry + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                if returned.commonattr & cmnError != 0 {
                    let err = field.loadUnaligned(as: UInt32.self)
                    field += 4
                    if err != 0 { progress.denied.add(1, ordering: .relaxed); continue }
                }
                guard returned.commonattr & cmnName != 0 else { continue }
                let nameOffset = Int(field.loadUnaligned(as: Int32.self))
                let name = String(cString: (field + nameOffset).assumingMemoryBound(to: CChar.self))
                field += 8

                var objType: UInt32 = 0
                if returned.commonattr & cmnObjType != 0 {
                    objType = field.loadUnaligned(as: UInt32.self); field += 4
                }
                var fileID: UInt64 = 0
                if returned.commonattr & cmnFileID != 0 {
                    fileID = field.loadUnaligned(as: UInt64.self); field += 8
                }

                if objType == 2 { // VDIR
                    var mount: UInt32 = 0
                    if returned.dirattr & dirMountStatus != 0 {
                        mount = field.loadUnaligned(as: UInt32.self); field += 4
                    }
                    if mount & 0x1 != 0 { continue } // another volume mounted here
                    let ext = (name as NSString).pathExtension.lowercased()
                    let kind: FileNode.Kind = !ext.isEmpty && Self.packageExtensions.contains(ext) ? .package : .directory
                    let child = FileNode(name: name, kind: kind, parent: node)
                    children.append(child)
                    subdirs.append((child, prefix + name))
                } else {
                    var links: UInt32 = 1
                    if returned.fileattr & fileLinkCount != 0 {
                        links = field.loadUnaligned(as: UInt32.self); field += 4
                    }
                    var alloc: Int64 = 0
                    if returned.fileattr & fileAllocSize != 0 {
                        alloc = field.loadUnaligned(as: Int64.self); field += 8
                    }
                    if links > 1 {
                        let firstTime = seenInodes.withLock { $0.insert(fileID).inserted }
                        if !firstTime { alloc = 0 } // count each hard-linked file once
                    }
                    children.append(FileNode(name: name, kind: .file, size: alloc, parent: node))
                    localFiles += 1
                    localBytes += alloc
                }
            }
        }

        node.children = children
        progress.files.add(localFiles, ordering: .relaxed)
        progress.bytes.add(localBytes, ordering: .relaxed)
        return subdirs
    }
}

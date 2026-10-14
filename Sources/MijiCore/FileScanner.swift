import Foundation
import Darwin

public struct ScanOptions: Sendable {
    public var includeHidden = true
    public var excludeDevelopmentCaches = false
    public init(includeHidden: Bool = true, excludeDevelopmentCaches: Bool = false) { self.includeHidden=includeHidden; self.excludeDevelopmentCaches=excludeDevelopmentCaches }
}
public struct ScanResult: Sendable {
    public var count: Int
    public var complete: Bool
    public var errors: [String]
    public var preservingPaths: [String] = []
}

public enum VolumeIdentity {
    public static func root(for url: URL) throws -> IndexedRoot {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .volumeUUIDStringKey, .volumeURLKey, .volumeIsInternalKey, .volumeIsRemovableKey])
        guard values.isDirectory == true else { throw NSError(domain: "Miji", code: 1, userInfo: [NSLocalizedDescriptionKey:"请选择文件夹或磁盘。"] ) }
        let volumePath = (values.allValues[.volumeURLKey] as? URL)?.path ?? "/"
        let relative = url.path == volumePath ? "" : String(url.path.dropFirst(volumePath == "/" ? 1 : volumePath.count + 1))
        return IndexedRoot(path: url.path, volumeUUID: values.volumeUUIDString, volumeRelativePath: relative, isExternal: values.volumeIsInternal == false || values.volumeIsRemovable == true || url.path.hasPrefix("/Volumes/"))
    }
    public static func refreshed(_ root: IndexedRoot) -> IndexedRoot {
        var root = root
        let manager = FileManager.default
        var candidate = URL(fileURLWithPath: root.path).standardizedFileURL.resolvingSymlinksInPath()
        root.path = candidate.path
        if root.isExternal, let uuid = root.volumeUUID {
            let mounts = manager.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []) ?? []
            if let mount = mounts.first(where: { (try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == uuid }) {
                candidate = root.volumeRelativePath.isEmpty ? mount : mount.appendingPathComponent(root.volumeRelativePath)
                root.path = candidate.path
            } else { root.isOnline = false; return root }
        }
        var directory: ObjCBool = false
        root.isOnline = manager.fileExists(atPath: candidate.path, isDirectory: &directory) && directory.boolValue
        if root.isOnline, let expected = root.volumeUUID, let actual = try? candidate.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString, expected != actual { root.isOnline = false }
        return root
    }
    public static func externalVolumes() -> [URL] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsInternalKey,.volumeIsRemovableKey,.volumeIsBrowsableKey], options: [.skipHiddenVolumes]) ?? []).filter {
            let v = try? $0.resourceValues(forKeys: [.volumeIsInternalKey,.volumeIsRemovableKey,.volumeIsBrowsableKey])
            return $0.path.hasPrefix("/Volumes/") && v?.volumeIsBrowsable != false && (v?.volumeIsInternal == false || v?.volumeIsRemovable == true)
        }
    }
}

// The boot volume's logical tree includes Data firmlinks. Other roots retain
// their volume boundary; physical mount aliases are never followed from /.
struct ScanVolumePolicy {
    let root: IndexedRoot
    let dataVolumeUUID: String?
    init(root: IndexedRoot, dataVolumeUUID: String? = nil) {
        self.root = root
        self.dataVolumeUUID = dataVolumeUUID ?? (try? URL(fileURLWithPath: "/System/Volumes/Data").resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
    }
    func skipsDirectory(path: String, volumeUUID: String?) -> Bool {
        if root.path == "/" {
            if path == "/System/Volumes" || path.hasPrefix("/System/Volumes/") || path == "/Volumes" || path.hasPrefix("/Volumes/") { return true }
            if let volumeUUID, volumeUUID == dataVolumeUUID { return false }
        }
        if let expected = root.volumeUUID, let actual = volumeUUID { return expected != actual }
        return false
    }
}

public final class FileScanner {
    private let database: SearchDatabase
    private let pathFilter: IndexPathFilter
    public init(database: SearchDatabase, ignoredPaths: [String] = []) {
        self.database = database
        self.pathFilter = IndexPathFilter(ignoredPaths: ignoredPaths)
    }
    public func scan(root: IndexedRoot, options: ScanOptions = ScanOptions(), cancelled: () -> Bool = {false}, progress: (Int) -> Void = {_ in}) throws -> ScanResult {
        try scan(root:root,relativePath:"",options:options,cancelled:cancelled,progress:progress)
    }

    /// Reconcile just this file/subtree; all paths and pruning remain relative
    /// to the original root so offline history and row identities are retained.
    public func scan(root: IndexedRoot, relativePath: String, options: ScanOptions = ScanOptions(), cancelled: () -> Bool = {false}, progress: (Int) -> Void = {_ in}) throws -> ScanResult {
        guard IndexRelativePath.validated(relativePath) else { throw CocoaError(.fileReadInvalidFileName) }
        var root = VolumeIdentity.refreshed(root)
        try database.saveRoot(root)
        guard root.enabled, root.isOnline else { return ScanResult(count:0,complete:false,errors:["索引位置未连接或已停用"]) }
        let fm=FileManager.default
        let base=URL(fileURLWithPath:root.path)
        let scope=IndexRelativePath.packageScope(relativePath)
        let target=scope.isEmpty ? base : base.appendingPathComponent(scope)
        let volumePolicy=ScanVolumePolicy(root:root)
        let generation=Int64(Date().timeIntervalSince1970 * 1_000_000)
        let keys:Set<URLResourceKey>=[.isDirectoryKey,.isSymbolicLinkKey,.isRegularFileKey,.isUbiquitousItemKey,.ubiquitousItemDownloadingStatusKey,.isPackageKey,.volumeUUIDStringKey]
        let excluded:Set<String>=["node_modules",".git",".svn",".build",".venv","venv","__pycache__","DerivedData","Pods","Carthage",".Trash",".Trashes",".Spotlight-V100",".fseventsd"]
        let userLibrary=fm.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        var errors:[String]=[],preservingPaths=Set<String>()
        var batch:[FileRecord]=[],count=0
        func recordFailure(_ url:URL,_ error:Error) {
            preservingPaths.insert(IndexRelativePath.from(url.path,root:root.path) ?? "")
            if errors.count < 8 { errors.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        func excludedPath(_ url:URL) -> Bool {
            if pathFilter.ignores(url.path) { return true }
            guard let relative=IndexRelativePath.from(url.path,root:root.path) else { return true }
            let parts=relative.split(separator:"/").map(String.init)
            if !options.includeHidden && parts.contains(where:{$0.hasPrefix(".")}) { return true }
            if options.excludeDevelopmentCaches && (parts.contains(where:excluded.contains) || url.path == userLibrary || url.path.hasPrefix(userLibrary + "/")) { return true }
            return false
        }
        // Returns whether a directory should be descended into. Both the
        // enumerator and resource lookups live inside per-item pools.
        func visit(_ url:URL) throws -> Bool {
            if excludedPath(url) { return false }
            let v=try url.resourceValues(forKeys:keys)
            if v.isSymbolicLink == true { return false }
            if v.isDirectory == true, volumePolicy.skipsDirectory(path:url.path,volumeUUID:v.volumeUUIDString) { return false }
            guard let relative=IndexRelativePath.from(url.path,root:root.path), !relative.isEmpty else { throw CocoaError(.fileReadInvalidFileName) }
            let kind=FileKind.classify(extension:url.pathExtension,isDirectory:v.isDirectory == true)
            let isContent=kind == .image || kind == .document || kind == .code
            let available=v.isUbiquitousItem != true || v.ubiquitousItemDownloadingStatus == .current || v.ubiquitousItemDownloadingStatus == .downloaded
            let signature=try FileSignature.read(url)
            batch.append(FileRecord(rootID:root.id,relativePath:relative,name:url.lastPathComponent,fileExtension:url.pathExtension.lowercased(),kind:kind,size:signature.size,modified:signature.modified,inode:signature.inode,contentState:isContent ? (available ? "pending" : "deferred") : "skipped",contentError:available ? nil : "文件尚未下载到本机"))
            count += 1
            if batch.count >= 300 { try database.upsertFiles(batch,generation:generation); batch.removeAll(keepingCapacity:true); progress(count) }
            return v.isDirectory == true && v.isPackage != true
        }
        var shouldEnumerate=scope.isEmpty
        var info=stat()
        let exists=lstat(target.path,&info) == 0
        let lookupError=errno
        if !exists && lookupError != ENOENT && lookupError != ENOTDIR {
            recordFailure(target,NSError(domain:NSPOSIXErrorDomain,code:Int(lookupError)))
        } else if exists && !scope.isEmpty && !cancelled() {
            autoreleasepool {
                do { shouldEnumerate=try visit(target) } catch { recordFailure(target,error) }
            }
        }
        if exists && shouldEnumerate && !cancelled() {
            let enumerationOptions:FileManager.DirectoryEnumerationOptions=options.includeHidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles,.skipsPackageDescendants]
            if let enumerator=fm.enumerator(at:target,includingPropertiesForKeys:Array(keys),options:enumerationOptions,errorHandler:{url,error in recordFailure(url,error);return true}) {
                var hasNext=true
                while hasNext && !cancelled() {
                    autoreleasepool {
                        guard let url=enumerator.nextObject() as? URL else { hasNext=false;return }
                        do {
                            if try !visit(url), (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true {
                                enumerator.skipDescendants()
                            }
                        } catch {
                            recordFailure(url,error)
                            if (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                        }
                    }
                }
            } else { recordFailure(target,CocoaError(.fileReadNoPermission)) }
        }
        if !batch.isEmpty { try database.upsertFiles(batch,generation:generation) }
        root=VolumeIdentity.refreshed(root)
        let reachedEnd = !cancelled() && root.isOnline
        let complete = reachedEnd && errors.isEmpty
        if scope.isEmpty {
            try database.finishScan(rootID:root.id,generation:generation,prune:reachedEnd,preservingPaths:Array(preservingPaths))
            if complete { root.lastScan=Date() }
        } else {
            try database.finishIncrementalScan(rootID:root.id,relativePath:scope,generation:generation,prune:reachedEnd,preservingPaths:Array(preservingPaths))
        }
        root.lastError=errors.isEmpty ? nil : errors.joined(separator:"\n")
        try database.saveRoot(root)
        autoreleasepool { progress(count) }
        return ScanResult(count:count,complete:complete,errors:errors,preservingPaths:Array(preservingPaths))
    }
}

import Foundation
import CryptoKit
import OilFindCore
import Darwin

/// A disposable cache of name metadata. Bodies remain solely in SQLite.
/// The database identity prevents reuse after replacement; its bounded change
/// journal supplies commits made after this snapshot was saved.
///
/// Version 2 (written now) stores every column page-aligned, including the
/// lookup table and name order, and restores by mapping the columns in place.
/// Version 1 streamed blocks that were decoded into memory; it is still read.
enum NameSnapshotCache {
    private static let magic=Data("MJNAME01".utf8)
    private static let mappedMagic=Data("MJNAME02".utf8)
    /// A multiple of every supported VM page size, so offsets map on any Mac.
    private static let alignment=16_384
    private struct Header:Codable {
        let inode:UInt64, device:UInt64, created:Double
        let revision:Int64, baseCount:Int, liveCount:Int
        let roots:[String:UInt32], extensions:[String:UInt32], kinds:[String:UInt32]
    }
    private struct Section:Codable { let name:String, offset:Int, count:Int, stride:Int }
    private struct MappedHeader:Codable {
        let inode:UInt64, device:UInt64, created:Double
        let revision:Int64, baseCount:Int, liveCount:Int
        let roots:[String:UInt32], extensions:[String:UInt32], kinds:[String:UInt32]
        let sections:[Section]
    }
    static func url(for database:URL)->URL {database.appendingPathExtension("names.cache")}
    private static func identity(_ url:URL)throws->(UInt64,UInt64,Double) {
        let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        guard let inode=attributes[.systemFileNumber] as? NSNumber,
              let device=attributes[.systemNumber] as? NSNumber,
              let created=attributes[.creationDate] as? Date else {throw InvalidCache()}
        return (inode.uint64Value,device.uint64Value,created.timeIntervalSince1970)
    }
    static func load(database:URL,revision:Int64)throws->NameSnapshot {
        removeAbandonedTemporaries(database:database)
        let path=url(for:database).path
        let descriptor=open(path,O_RDONLY|O_CLOEXEC)
        guard descriptor >= 0 else {throw InvalidCache()}
        defer {close(descriptor)}
        var leading=[UInt8](repeating:0,count:8)
        guard pread(descriptor,&leading,8,0) == 8 else {throw InvalidCache()}
        if Data(leading) == mappedMagic {return try loadMapped(descriptor:descriptor,database:database,revision:revision)}
        return try loadStreamed(database:database,revision:revision)
    }

    /// Writes version 2 through a temporary file and an atomic rename, so a
    /// snapshot still mapped from the previous file keeps its pages.
    static func save(_ snapshot:NameSnapshot,database:URL)throws {
        guard let revision=snapshot.changeRevision else {return}
        // Version 2 would keep the zero tiers of an unfinished version 1 restore.
        guard !snapshot.needsTiers else {throw InvalidCache()}
        // Rank names added since publication, so a restore sorts nothing.
        try snapshot.core.completeNameOrder()
        let id=try identity(database)
        let columns:[(String,RawColumn)]=[("ids",snapshot.ids),("sizes",snapshot.sizes),("modified",snapshot.modified),
                                          ("roots",snapshot.roots),("extensions",snapshot.extensions),("kinds",snapshot.kinds),
                                          ("live",snapshot.live),("tiers",snapshot.tiers)]+snapshot.core.columns().map {("core."+$0.0,$0.1)}
        func padded(_ bytes:Int)->Int {(bytes+alignment-1)/alignment*alignment}
        var headerSize=alignment,header=Data(),sections:[Section]=[]
        while true {
            var offset=headerSize
            sections=columns.map { name,column in
                defer {offset+=padded(column.count*column.elementStride)}
                return Section(name:name,offset:offset,count:column.count,stride:column.elementStride)
            }
            header=try JSONEncoder().encode(MappedHeader(inode:id.0,device:id.1,created:id.2,revision:revision,
                                                         baseCount:snapshot.baseCount,liveCount:snapshot.liveCount,
                                                         roots:snapshot.rootKeys,extensions:snapshot.extensionKeys,kinds:snapshot.kindKeys,
                                                         sections:sections))
            if 16+header.count <= headerSize {break}
            headerSize=padded(16+header.count)
        }
        try write(database:database) { write in
            var length=UInt64(header.count).littleEndian
            try write(mappedMagic)
            try withUnsafeBytes(of:&length) {try write(Data($0))}
            try write(header)
            try write(Data(count:headerSize-16-header.count))
            for (index,(_,column)) in columns.enumerated() {
                let bytes=try column.withUnsafeRawBytes { raw -> Int in
                    if raw.count>0 {try write(Data(bytesNoCopy:UnsafeMutableRawPointer(mutating:raw.baseAddress!),count:raw.count,deallocator:.none))}
                    return raw.count
                }
                precondition(sections[index].count*sections[index].stride == bytes)
                if padded(bytes)>bytes {try write(Data(count:padded(bytes)-bytes))}
            }
        }
    }

    private struct MappedColumns:ColumnSource {
        let descriptor:Int32, fileSize:Int, prefix:String
        let sections:[String:Section]
        func column<T>(_ name:String,as type:T.Type)throws->MappedColumn<T> {
            guard let section=sections[prefix+name],section.stride == MemoryLayout<T>.stride else {throw InvalidCache()}
            return try MappedColumn<T>(mapping:descriptor,offset:section.offset,count:section.count,fileSize:fileSize)
        }
    }
    private static func loadMapped(descriptor:Int32,database:URL,revision:Int64)throws->NameSnapshot {
        var info=stat()
        guard fstat(descriptor,&info) == 0 else {throw InvalidCache()}
        let size=Int(info.st_size)
        guard size>16+32 else {throw InvalidCache()}
        // Verify once over a temporary read-only view. The columns map the same
        // file pages afterwards, so checking does not leave a second copy.
        guard let view=mmap(nil,size,PROT_READ,MAP_PRIVATE,descriptor,0),view != MAP_FAILED else {throw InvalidCache()}
        defer {munmap(view,size)}
        let file=UnsafeRawBufferPointer(start:view,count:size)
        let payloadEnd=size-32
        guard Data(SHA256.hash(data:UnsafeRawBufferPointer(rebasing:file[0..<payloadEnd]))) == Data(file[payloadEnd...]) else {throw InvalidCache()}
        let length=file.loadUnaligned(fromByteOffset:8,as:UInt64.self).littleEndian
        guard length <= UInt64(payloadEnd-16) else {throw InvalidCache()}
        let header=try JSONDecoder().decode(MappedHeader.self,from:Data(file[16..<(16+Int(length))]))
        let id=try identity(database)
        guard header.inode==id.0,header.device==id.1,header.created==id.2,
              header.revision<=revision,revision-header.revision<=100_000,
              Set(header.sections.map(\.name)).count == header.sections.count,
              header.sections.allSatisfy({$0.offset >= 16+Int(length) && $0.count >= 0}) else {throw InvalidCache()}
        let sections=Dictionary(uniqueKeysWithValues:header.sections.map {($0.name,$0)})
        let source=MappedColumns(descriptor:descriptor,fileSize:payloadEnd,prefix:"",sections:sections)
        let snapshot=NameSnapshot()
        snapshot.ids=try source.column("ids",as:Int64.self)
        snapshot.sizes=try source.column("sizes",as:Int64.self)
        snapshot.modified=try source.column("modified",as:Double.self)
        snapshot.roots=try source.column("roots",as:UInt32.self)
        snapshot.extensions=try source.column("extensions",as:UInt32.self)
        snapshot.kinds=try source.column("kinds",as:UInt32.self)
        snapshot.live=try source.column("live",as:UInt8.self)
        snapshot.tiers=try source.column("tiers",as:UInt8.self)
        snapshot.core=try DeduplicatedNameIndex(columns:MappedColumns(descriptor:descriptor,fileSize:payloadEnd,prefix:"core.",sections:sections))
        try finish(snapshot,baseCount:header.baseCount,liveCount:header.liveCount,revision:header.revision,
                   roots:header.roots,extensions:header.extensions,kinds:header.kinds)
        snapshot.isMapped=true
        return snapshot
    }

    /// Checks shared by both versions, then the header's keys and counters.
    private static func finish(_ snapshot:NameSnapshot,baseCount:Int,liveCount:Int,revision:Int64,
                               roots:[String:UInt32],extensions:[String:UInt32],kinds:[String:UInt32])throws {
        let count=snapshot.ids.count
        guard count<=Int(UInt32.max),snapshot.core.count==count,
              snapshot.sizes.count==count,snapshot.modified.count==count,snapshot.roots.count==count,
              snapshot.extensions.count==count,snapshot.kinds.count==count,snapshot.live.count==count,snapshot.tiers.count==count,
              baseCount>=0,baseCount<=count,
              valid(roots),valid(extensions),valid(kinds) else {throw InvalidCache()}
        let liveRows=snapshot.live.withUnsafeBufferPointer { live -> Int? in
            var total=0
            for value in live {guard value<=1 else {return nil};total+=Int(value)}
            return total
        }
        func bounded(_ column:MappedColumn<UInt32>,_ limit:Int)->Bool {column.withUnsafeBufferPointer {$0.allSatisfy {Int($0)<limit}}}
        guard liveRows == liveCount,bounded(snapshot.roots,roots.count),
              bounded(snapshot.extensions,extensions.count),bounded(snapshot.kinds,kinds.count) else {throw InvalidCache()}
        let ascending=snapshot.ids.withUnsafeBufferPointer { ids in
            baseCount<2 || (1..<baseCount).allSatisfy {ids[$0-1]<ids[$0]}
        }
        guard ascending else {throw InvalidCache()}
        snapshot.rootKeys=roots;snapshot.extensionKeys=extensions;snapshot.kindKeys=kinds
        snapshot.baseCount=baseCount;snapshot.liveCount=liveCount;snapshot.changeRevision=revision
        for i in baseCount..<count {snapshot.changedIDs[snapshot.ids[i]]=UInt32(i)}
    }

    private static func loadStreamed(database:URL,revision:Int64)throws->NameSnapshot {
        let handle=try FileHandle(forReadingFrom:url(for:database))
        defer {try? handle.close()}
        let length=try handle.seekToEnd()
        guard length>UInt64(magic.count+40),length<=UInt64(Int.max) else {throw InvalidCache()}
        let payloadEnd=Int(length)-32
        try handle.seek(toOffset:0)
        guard try read(handle,count:magic.count)==magic else {throw InvalidCache()}
        try handle.seek(toOffset:0)
        var digest=SHA256(),remaining=payloadEnd
        while remaining>0 {
            let count=min(1_048_576,remaining)
            try autoreleasepool {digest.update(data:try read(handle,count:count))}
            remaining-=count
        }
        guard try Data(digest.finalize())==read(handle,count:32) else {throw InvalidCache()}
        try handle.seek(toOffset:UInt64(magic.count))
        var decoder=Decoder(handle:handle,end:payloadEnd,offset:magic.count)
        let header=try JSONDecoder().decode(Header.self,from:decoder.block())
        let id=try identity(database)
        guard header.inode==id.0,header.device==id.1,header.created==id.2,
              header.revision<=revision,revision-header.revision<=100_000 else {throw InvalidCache()}
        let snapshot=NameSnapshot()
        snapshot.ids=try decoder.array(Int64.self)
        snapshot.sizes=try decoder.array(Int64.self)
        snapshot.modified=try decoder.array(Double.self)
        snapshot.roots=try decoder.array(UInt32.self)
        snapshot.extensions=try decoder.array(UInt32.self)
        snapshot.kinds=try decoder.array(UInt32.self)
        snapshot.live=try decoder.array(UInt8.self)
        snapshot.core=try autoreleasepool {try DeduplicatedNameIndex(serialized:decoder.block())}
        guard decoder.offset==payloadEnd else {throw InvalidCache()}
        // Version 1 predates tiers; the engine fills them before publishing.
        snapshot.tiers=MappedColumn(repeating:0,count:snapshot.ids.count)
        snapshot.needsTiers=true
        try finish(snapshot,baseCount:header.baseCount,liveCount:header.liveCount,revision:header.revision,
                   roots:header.roots,extensions:header.extensions,kinds:header.kinds)
        return snapshot
    }
    /// The version 1 writer, kept so tests can produce caches of earlier releases.
    static func saveStreamed(_ snapshot:NameSnapshot,database:URL)throws {
        guard let revision=snapshot.changeRevision else {return}
        let id=try identity(database)
        let header=Header(inode:id.0,device:id.1,created:id.2,revision:revision,baseCount:snapshot.baseCount,liveCount:snapshot.liveCount,
                          roots:snapshot.rootKeys,extensions:snapshot.extensionKeys,kinds:snapshot.kindKeys)
        try write(database:database) { write in
            func append(_ block:Data)throws {
                var size=UInt64(block.count).littleEndian
                try withUnsafeBytes(of:&size) {try write(Data($0))}
                try write(block)
            }
            func array(_ values:RawColumn)throws {
                try values.withUnsafeRawBytes { bytes in
                    let data=bytes.isEmpty ? Data() : Data(bytesNoCopy:UnsafeMutableRawPointer(mutating:bytes.baseAddress!),count:bytes.count,deallocator:.none)
                    try append(data)
                }
            }
            try write(magic);try append(JSONEncoder().encode(header))
            try array(snapshot.ids);try array(snapshot.sizes);try array(snapshot.modified)
            try array(snapshot.roots);try array(snapshot.extensions);try array(snapshot.kinds);try array(snapshot.live)
            try autoreleasepool {try append(snapshot.core.serialized())}
        }
    }
    /// Temporary file, running SHA-256 of everything written, digest, rename.
    private static func write(database:URL,_ body:((Data)throws->Void)throws->Void)throws {
        let destination=url(for:database)
        let temporary=destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath:temporary.path,contents:nil,attributes:[.posixPermissions:0o600]) else {throw InvalidCache()}
        defer {try? FileManager.default.removeItem(at:temporary)}
        let handle=try FileHandle(forWritingTo:temporary)
        defer {try? handle.close()}
        var digest=SHA256()
        try body { bytes in digest.update(data:bytes);try handle.write(contentsOf:bytes) }
        try handle.write(contentsOf:Data(digest.finalize()))
        try handle.close()
        guard rename(temporary.path,destination.path)==0 else {throw CocoaError(.fileWriteUnknown)}
    }
    /// A save interrupted by a crash or forced quit leaves its temporary file.
    /// Saves only run inside the app, so an hour-old one is abandoned.
    private static func removeAbandonedTemporaries(database:URL) {
        let destination=url(for:database),directory=destination.deletingLastPathComponent()
        let prefix=".\(destination.lastPathComponent)."
        guard let names=try? FileManager.default.contentsOfDirectory(atPath:directory.path) else {return}
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".tmp") {
            let path=directory.appendingPathComponent(name).path
            if let modified=(try? FileManager.default.attributesOfItem(atPath:path))?[.modificationDate] as? Date,
               modified.timeIntervalSinceNow < -3600 {try? FileManager.default.removeItem(atPath:path)}
        }
    }
    private static func valid(_ map:[String:UInt32])->Bool {
        Set(map.values)==Set((0..<map.count).map {UInt32($0)})
    }
    private struct InvalidCache:Error {}
    private static func read(_ handle:FileHandle,count:Int)throws->Data {
        guard count>0 else {return Data()}
        var data=try handle.read(upToCount:count) ?? Data()
        while data.count<count {
            guard let next=try handle.read(upToCount:count-data.count),!next.isEmpty else {throw InvalidCache()}
            data.append(next)
        }
        return data
    }
    private struct Decoder {
        let handle:FileHandle,end:Int
        var offset:Int
        mutating func block()throws->Data {
            guard offset<=end-8 else {throw InvalidCache()}
            let length=try read(handle,count:8).withUnsafeBytes {$0.loadUnaligned(as:UInt64.self).littleEndian}
            offset+=8
            guard length<=UInt64(end-offset) else {throw InvalidCache()}
            offset+=Int(length)
            return try read(handle,count:Int(length))
        }
        mutating func array<T>(_ type:T.Type)throws->MappedColumn<T> {
            // Only the primitive numeric columns above use this decoder. Read
            // into their final storage instead of retaining a full Data copy.
            guard offset<=end-8 else {throw InvalidCache()}
            let length=try read(handle,count:8).withUnsafeBytes {$0.loadUnaligned(as:UInt64.self).littleEndian}
            offset+=8
            let stride=MemoryLayout<T>.stride
            guard length<=UInt64(end-offset),length%UInt64(stride)==0 else {throw InvalidCache()}
            let bytes=Int(length),count=bytes/stride
            let result=try MappedColumn<T>(unsafeUninitializedCount:count) {destination in
                var received=0
                while received<bytes {
                    let size=Darwin.read(handle.fileDescriptor,destination.baseAddress!.advanced(by:received),min(1_048_576,bytes-received))
                    if size<0 && errno==EINTR {continue}
                    guard size>0 else {throw InvalidCache()}
                    received+=size
                }
            }
            offset+=bytes
            return result
        }
    }
}

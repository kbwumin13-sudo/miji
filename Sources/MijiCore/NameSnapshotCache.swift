import Foundation
import CryptoKit
import OilFindCore
import Darwin

/// A disposable cache of name metadata. Bodies remain solely in SQLite.
/// The database identity prevents reuse after replacement; its bounded change
/// journal supplies commits made after this snapshot was saved.
enum NameSnapshotCache {
    private static let magic=Data("MJNAME01".utf8)
    private struct Header:Codable {
        let inode:UInt64, device:UInt64, created:Double
        let revision:Int64, baseCount:Int, liveCount:Int
        let roots:[String:UInt32], extensions:[String:UInt32], kinds:[String:UInt32]
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
        snapshot.core=try autoreleasepool {try CompactNameIndex(serialized:decoder.block())}
        let count=snapshot.ids.count
        guard decoder.offset==payloadEnd,count<=Int(UInt32.max),snapshot.core.count==count,
              snapshot.sizes.count==count,snapshot.modified.count==count,snapshot.roots.count==count,
              snapshot.extensions.count==count,snapshot.kinds.count==count,snapshot.live.count==count,
              header.baseCount>=0,header.baseCount<=count,
              snapshot.live.allSatisfy({$0<=1}),snapshot.live.reduce(0,{$0+Int($1)})==header.liveCount,
              valid(header.roots),valid(header.extensions),valid(header.kinds),
              snapshot.roots.allSatisfy({$0<UInt32(header.roots.count)}),
              snapshot.extensions.allSatisfy({$0<UInt32(header.extensions.count)}),
              snapshot.kinds.allSatisfy({$0<UInt32(header.kinds.count)}) else {throw InvalidCache()}
        if header.baseCount>1 {
            for i in 1..<header.baseCount where snapshot.ids[i-1]>=snapshot.ids[i] {throw InvalidCache()}
        }
        snapshot.rootKeys=header.roots;snapshot.extensionKeys=header.extensions;snapshot.kindKeys=header.kinds
        snapshot.baseCount=header.baseCount;snapshot.liveCount=header.liveCount;snapshot.changeRevision=header.revision
        for i in header.baseCount..<count {snapshot.changedIDs[snapshot.ids[i]]=UInt32(i)}
        return snapshot
    }
    static func save(_ snapshot:NameSnapshot,database:URL)throws {
        guard let revision=snapshot.changeRevision else {return}
        let id=try identity(database)
        let header=Header(inode:id.0,device:id.1,created:id.2,revision:revision,baseCount:snapshot.baseCount,liveCount:snapshot.liveCount,
                          roots:snapshot.rootKeys,extensions:snapshot.extensionKeys,kinds:snapshot.kindKeys)
        let destination=url(for:database)
        let temporary=destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath:temporary.path,contents:nil,attributes:[.posixPermissions:0o600]) else {throw InvalidCache()}
        defer {try? FileManager.default.removeItem(at:temporary)}
        let handle=try FileHandle(forWritingTo:temporary)
        defer {try? handle.close()}
        var digest=SHA256()
        func write(_ bytes:Data)throws {digest.update(data:bytes);try handle.write(contentsOf:bytes)}
        func append(_ block:Data)throws {
            var size=UInt64(block.count).littleEndian
            try withUnsafeBytes(of:&size) {try write(Data($0))}
            try write(block)
        }
        func array<T>(_ values:[T])throws {
            try values.withUnsafeBytes {bytes in
                let data=bytes.isEmpty ? Data() : Data(bytesNoCopy:UnsafeMutableRawPointer(mutating:bytes.baseAddress!),count:bytes.count,deallocator:.none)
                try append(data)
            }
        }
        try write(magic);try append(JSONEncoder().encode(header))
        try array(snapshot.ids);try array(snapshot.sizes);try array(snapshot.modified)
        try array(snapshot.roots);try array(snapshot.extensions);try array(snapshot.kinds);try array(snapshot.live)
        try autoreleasepool {try append(snapshot.core.serialized())}
        try handle.write(contentsOf:Data(digest.finalize()))
        try handle.close()
        guard rename(temporary.path,destination.path)==0 else {throw CocoaError(.fileWriteUnknown)}
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
        mutating func array<T>(_ type:T.Type)throws->[T] {
            try autoreleasepool {
                let bytes=try block(),stride=MemoryLayout<T>.stride
                guard bytes.count%stride==0 else {throw InvalidCache()}
                let count=bytes.count/stride
                return [T](unsafeUninitializedCapacity:count) {buffer,initialized in
                    bytes.withUnsafeBytes {source in
                        if !source.isEmpty {UnsafeMutableRawBufferPointer(buffer).copyMemory(from:source)}
                    }
                    initialized=count
                }
            }
        }
    }
}

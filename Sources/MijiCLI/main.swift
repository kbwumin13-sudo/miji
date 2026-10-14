import Foundation
import MijiCore

func emit(_ value: Any) throws { let data=try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys,.fragmentsAllowed]); print(String(decoding:data,as:UTF8.self)) }
func encoded<T:Encodable>(_ value:T) throws -> Any { try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) }
let args=Array(CommandLine.arguments.dropFirst())
func option(_ name:String) -> String? { guard let index=args.firstIndex(of:name),args.count>index+1 else{return nil};return args[index+1] }
do {
    let command=args.first ?? "help"
    if command == "benchmark-content" {
        guard let path=option("--database") else {throw NSError(domain:"MijiCLI",code:1,userInfo:[NSLocalizedDescriptionKey:"缺少 --database"])}
        let database=try SearchDatabase(url:URL(fileURLWithPath:path),readOnly:true)
        let queries=option("--queries")?.components(separatedBy:"|") ?? ["数学","数学分析","OCR","README"]
        let rounds=max(1,Int(option("--rounds") ?? "3") ?? 3)
        let timeout=max(1,Double(option("--timeout") ?? "10") ?? 10)
        for query in queries {
            for round in 0..<rounds {
                let start=DispatchTime.now().uptimeNanoseconds
                let deadline=start+UInt64(timeout*1_000_000_000)
                var firstMS:Double?
                do {
                    let hits=try database.searchSupplementary(query,options:SearchOptions(scope:.content,limit:500),cancelled:{DispatchTime.now().uptimeNanoseconds>=deadline},onPartial:{_ in if firstMS==nil {firstMS=Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000}})
                    let value:[String:Any]=["query":query,"round":round,"count":hits.count,"first_ms":firstMS.map{$0 as Any} ?? NSNull(),"ms":Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000]
                    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:value,options:.sortedKeys));FileHandle.standardOutput.write(Data([10]))
                } catch is CancellationError {
                    let value:[String:Any]=["query":query,"round":round,"first_ms":firstMS.map{$0 as Any} ?? NSNull(),"timeout_seconds":timeout]
                    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:value,options:.sortedKeys));FileHandle.standardOutput.write(Data([10]))
                    break
                }
            }
        }
    } else if command == "benchmark" {
        guard let path=option("--database") else { throw NSError(domain:"MijiCLI",code:1,userInfo:[NSLocalizedDescriptionKey:"缺少 --database"]) }
        let url=URL(fileURLWithPath:path),immutable=args.contains("--immutable")
        let database=try SearchDatabase(url:url,readOnly:true,immutable:immutable)
        let engine=try NameSearchEngine(databaseURL:url,immutable:immutable)
        let started=DispatchTime.now().uptimeNanoseconds
        try engine.load()
        let loadMS=Double(DispatchTime.now().uptimeNanoseconds-started)/1_000_000
        let queries=option("--queries")?.components(separatedBy:"|") ?? ["数学","数学分析","Miji","README","pdf","shuxue","sx","不存在的文件-zz981"]
        let rounds=max(1,Int(option("--rounds") ?? "20") ?? 20)
        var results:[[String:Any]]=[]
        for query in queries {
            var core:[Double]=[],hydration:[Double]=[];var count=0
            for _ in 0..<rounds {
                let start=DispatchTime.now().uptimeNanoseconds
                let ids=try engine.search(query,options:SearchOptions(scope:.name,limit:500))
                let found=DispatchTime.now().uptimeNanoseconds
                let hits=try database.nameHits(ids:ids,query:query)
                let end=DispatchTime.now().uptimeNanoseconds
                core.append(Double(found-start)/1_000_000);hydration.append(Double(end-found)/1_000_000);count=hits.count
            }
            let sorted=core.sorted()
            results.append(["query":query,"count":count,"core_ms":core,"hydrate_ms":hydration,"core_p50_ms":sorted[sorted.count/2],"core_p95_ms":sorted[min(sorted.count-1,Int(Double(sorted.count)*0.95))]])
        }
        let cacheStart=DispatchTime.now().uptimeNanoseconds
        try engine.saveCache()
        try emit(["load_ms":loadMS,"cache_write_ms":Double(DispatchTime.now().uptimeNanoseconds-cacheStart)/1_000_000,"rounds":rounds,"results":results])
    } else if command == "migrate" {
        guard let source=option("--source"),let destination=option("--destination") else { throw NSError(domain:"MijiCLI",code:1,userInfo:[NSLocalizedDescriptionKey:"缺少 --source / --destination"]) }
        try SearchDatabase.migrateLegacy(from:URL(fileURLWithPath:source),to:URL(fileURLWithPath:destination)) { value in
            if let data=try? JSONEncoder().encode(value) { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10])) }
        }
    } else if command == "extract" {
        guard let path=option("--file") else {throw NSError(domain:"MijiCLI",code:1,userInfo:[NSLocalizedDescriptionKey:"缺少 --file"])}
        let result=try ContentExtractor.extract(url:URL(fileURLWithPath:path))
        try emit(try encoded(result))
    } else if ["index","search","roots","refresh","offline","online","stats"].contains(command) {
        guard let path=option("--database") else {throw NSError(domain:"MijiCLI",code:1,userInfo:[NSLocalizedDescriptionKey:"缺少 --database"])}
        let database=try SearchDatabase(url:URL(fileURLWithPath:path),readOnly:["search","roots","stats"].contains(command))
        switch command {
        case "index":
            guard let rootPath=option("--root") else {throw NSError(domain:"MijiCLI",code:1,userInfo:[NSLocalizedDescriptionKey:"缺少 --root"])}
            let url=URL(fileURLWithPath:rootPath).standardizedFileURL
            let old=try database.roots().first {$0.path==url.path}
            var root=try VolumeIdentity.root(for:url);if let old {root.id=old.id};try database.saveRoot(root)
            let scan=try FileScanner(database:database).scan(root:root)
            var complete=0;var failed=0
            if !args.contains("--names-only") {
                while true {
                    let files=try database.pendingFiles(rootID:root.id,limit:50)
                    if files.isEmpty {break}
                    for file in files {
                        do {
                            let content=try autoreleasepool {try ContentExtractor.extract(url:url.appendingPathComponent(file.relativePath))}
                            if try database.completeContent(file:file,content:content) {complete += 1}
                        } catch {failed += 1;try database.failContent(file:file,message:error.localizedDescription)}
                    }
                }
            }
            try emit(["rootID":root.id,"files":scan.count,"scanComplete":scan.complete,"scanErrors":scan.errors,"contentCompleted":complete,"contentFailed":failed])
        case "search":
            let query=option("--query") ?? ""
            let options=SearchOptions(kind:option("--kind").flatMap(FileKind.init(rawValue:)),scope:option("--scope").flatMap(SearchScope.init(rawValue:)) ?? .all,onlineOnly:args.contains("--online-only"),limit:Int(option("--limit") ?? "100") ?? 100)
            let hits=try database.search(query,options:options)
            try emit(hits.map { ["name":$0.file.name,"path":$0.path,"rootID":$0.root.id,"online":$0.root.isOnline,"kind":$0.file.kind.rawValue,"matchedIn":$0.matchedIn,"snippet":$0.snippet,"labels":$0.labels,"contentState":$0.file.contentState] as [String:Any] })
        case "refresh":
            for root in try database.roots() {try database.saveRoot(VolumeIdentity.refreshed(root))}
            try emit(try encoded(database.roots()))
        case "roots": try emit(try encoded(database.roots()))
        case "offline","online":
            guard let id=option("--root-id"),var root=try database.roots().first(where:{$0.id==id}) else {throw NSError(domain:"MijiCLI",code:1,userInfo:[NSLocalizedDescriptionKey:"未知 --root-id"])}
            root.isOnline=command=="online";try database.saveRoot(root);try emit(try encoded(root))
        default:
            let s=try database.statistics();try emit(["files":s.files,"documents":s.documents,"images":s.images,"pending":s.pending,"errors":s.errors,"indexedContent":s.indexedContent])
        }
    } else {
        print("""
        觅迹命令行诊断工具
          miji-cli migrate --source OLD_INDEX --destination NEW_INDEX
          miji-cli benchmark --database FILE [--immutable] [--rounds 20] [--queries '数学|README']
          miji-cli benchmark-content --database FILE [--rounds 3] [--timeout 10] [--queries '数学|OCR']
          miji-cli index --database FILE --root DIRECTORY [--names-only]
          miji-cli search --database FILE --query TEXT [--kind document|image|folder] [--scope all|name|content] [--online-only]
          miji-cli extract --file FILE
          miji-cli roots|stats|refresh --database FILE
          miji-cli offline|online --database FILE --root-id ID
        """)
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8));exit(1)
}

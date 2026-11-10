import Foundation

/// The final list shared by the GUI and quality evaluation. The initial interface
/// preserves the GUI's existing order; candidate/ranking policy lives here.
public enum SearchResultMerger {
    public static func merge(nameResults: [SearchHit], contentResults: [SearchHit],
                             scope: SearchScope, sort: SearchSort, limit: Int,
                             query: String = "") -> [SearchHit] {
        let names = scope == .content ? [] : nameResults
        let extra = scope == .name ? [] : contentResults
        let decorated = Dictionary(uniqueKeysWithValues: extra.map { ($0.id, $0) })
        var ids = Set(names.map(\.id))
        var merged = names.map { decorated[$0.id] ?? $0 } + extra.filter { ids.insert($0.id).inserted }
        if sort != .relevance {
            merged.sort {
                if sort == .modified && $0.file.modified != $1.file.modified { return $0.file.modified > $1.file.modified }
                if sort == .size && $0.file.size != $1.file.size { return $0.file.size > $1.file.size }
                let a = $0.file.name.precomposedStringWithCanonicalMapping.lowercased().precomposedStringWithCanonicalMapping
                let b = $1.file.name.precomposedStringWithCanonicalMapping.lowercased().precomposedStringWithCanonicalMapping
                return a == b ? $0.id < $1.id : a < b
            }
        }
        return Array(merged.prefix(max(0, limit)))
    }
}

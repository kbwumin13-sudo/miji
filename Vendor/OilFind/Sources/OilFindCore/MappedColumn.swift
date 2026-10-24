import Darwin

/// Byte access to a column of trivial values, for writing page-aligned caches.
public protocol RawColumn: AnyObject {
    var count: Int { get }
    var elementStride: Int { get }
    func withUnsafeRawBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R
}

/// Typed columns of a page-aligned cache, by stable name.
public protocol ColumnSource {
    func column<T>(_ name: String, as type: T.Type) throws -> MappedColumn<T>
}

/// Contiguous, growable storage for trivial values, in one of two backings:
/// anonymous memory, or a private map of a page-aligned cache file region.
///
/// Mapped pages stay clean until written: they are not part of the process
/// footprint, and under memory pressure the system drops and later rereads
/// them. A write copies only its page. Appends continue in anonymous pages
/// reserved directly after the mapped region, so the column stays contiguous
/// for the C matcher; a column outgrowing its reservation moves to a larger
/// anonymous one.
public final class MappedColumn<Element>: RandomAccessCollection, MutableCollection, RawColumn {
    public typealias Index = Int
    private var storage: UnsafeMutableRawPointer
    private var reserved: Int
    /// Array-like capacity for storage accounting; the reservation may be larger.
    private var logicalCapacity: Int
    public private(set) var count = 0

    public static var pageSize: Int { Int(getpagesize()) }
    private static func rounded(_ bytes: Int) -> Int {
        let page = pageSize
        return (Swift.max(bytes, 1) + page - 1) / page * page
    }
    private static func reserve(_ bytes: Int) -> UnsafeMutableRawPointer {
        // Untouched anonymous pages cost nothing until first written.
        let pointer = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        guard let pointer, pointer != MAP_FAILED else { fatalError("MappedColumn: cannot reserve \(bytes) bytes") }
        return pointer
    }

    public init(capacity: Int = 0) {
        precondition(_isPOD(Element.self), "MappedColumn holds trivial values only")
        reserved = Self.rounded(Swift.max(capacity, 1) * MemoryLayout<Element>.stride)
        storage = Self.reserve(reserved)
        logicalCapacity = capacity
    }
    public convenience init<S: Sequence>(_ elements: S) where S.Element == Element {
        self.init(capacity: elements.underestimatedCount)
        append(contentsOf: elements)
    }
    public convenience init(repeating value: Element, count: Int) {
        self.init(capacity: count)
        let typed = storage.bindMemory(to: Element.self, capacity: count)
        typed.initialize(repeating: value, count: count)
        self.count = count
        logicalCapacity = count
    }

    /// `count` elements whose bytes `body` writes, as Array's uninitialized init.
    public convenience init(unsafeUninitializedCount count: Int, initializingWith body: (UnsafeMutableRawBufferPointer) throws -> Void) rethrows {
        self.init(capacity: count)
        try body(UnsafeMutableRawBufferPointer(start: storage, count: count * MemoryLayout<Element>.stride))
        self.count = count
    }

    public enum MappingError: Error { case outOfBounds, mapFailed(Int32) }

    /// Maps `count` elements stored at the page-aligned `offset` of `descriptor`.
    /// The file must extend to the end of the region's last page.
    public init(mapping descriptor: Int32, offset: Int, count: Int, fileSize: Int) throws {
        precondition(_isPOD(Element.self), "MappedColumn holds trivial values only")
        let stride = MemoryLayout<Element>.stride
        let (bytes, overflow) = count.multipliedReportingOverflow(by: stride)
        // Bound by the file before rounding up, so rounding cannot overflow.
        guard count >= 0, !overflow, bytes <= fileSize, offset >= 0, offset % Self.pageSize == 0 else { throw MappingError.outOfBounds }
        let mapped = bytes == 0 ? 0 : Self.rounded(bytes)
        guard mapped <= fileSize, offset <= fileSize - mapped else { throw MappingError.outOfBounds }
        // Map into locals first: no stored property is set when this throws,
        // so deinit cannot unmap the reservation a second time.
        let size = Self.rounded(mapped + Swift.max(mapped / 2, 4 << 20))
        let region = Self.reserve(size)
        if count > 0 {
            let result = mmap(region, mapped, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_FIXED, descriptor, off_t(offset))
            guard result == region else {
                let code = errno
                munmap(region, size)
                throw MappingError.mapFailed(code)
            }
        }
        reserved = size
        storage = region
        logicalCapacity = count
        self.count = count
    }

    deinit { munmap(storage, reserved) }

    private var base: UnsafeMutablePointer<Element> { storage.assumingMemoryBound(to: Element.self) }
    public var startIndex: Int { 0 }
    public var endIndex: Int { count }
    public var capacity: Int { logicalCapacity }
    public var elementStride: Int { MemoryLayout<Element>.stride }

    public subscript(position: Int) -> Element {
        get {
            precondition(position >= 0 && position < count, "MappedColumn index out of range")
            return base[position]
        }
        set {
            precondition(position >= 0 && position < count, "MappedColumn index out of range")
            base[position] = newValue
        }
    }

    public func reserveCapacity(_ minimum: Int) {
        logicalCapacity = Swift.max(logicalCapacity, minimum)
        let needed = minimum * MemoryLayout<Element>.stride
        guard needed > reserved else { return }
        let larger = Self.rounded(Swift.max(needed, reserved * 2))
        let moved = Self.reserve(larger)
        moved.copyMemory(from: storage, byteCount: count * MemoryLayout<Element>.stride)
        munmap(storage, reserved)
        storage = moved; reserved = larger
    }
    /// Grows within the reservation first: a mapped column keeps its file
    /// pages and appends into the anonymous pages reserved after them.
    private func grow(to minimum: Int) {
        if minimum > logicalCapacity { logicalCapacity = Swift.max(minimum, logicalCapacity * 2) }
        if minimum * MemoryLayout<Element>.stride > reserved { reserveCapacity(minimum) }
    }
    public func append(_ value: Element) {
        grow(to: count + 1)
        base[count] = value
        count += 1
    }
    public func append<S: Sequence>(contentsOf elements: S) where S.Element == Element {
        let added = elements.withContiguousStorageIfAvailable { buffer -> Bool in
            grow(to: count + buffer.count)
            if let source = buffer.baseAddress { (base + count).update(from: source, count: buffer.count) }
            count += buffer.count
            return true
        }
        if added == nil { for value in elements { append(value) } }
    }

    public func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<Element>) throws -> R) rethrows -> R {
        try body(UnsafeBufferPointer(start: base, count: count))
    }
    public func withUnsafeMutableBufferPointer<R>(_ body: (UnsafeMutableBufferPointer<Element>) throws -> R) rethrows -> R {
        try body(UnsafeMutableBufferPointer(start: base, count: count))
    }
    public func withUnsafeRawBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: storage, count: count * MemoryLayout<Element>.stride))
    }
    public func withContiguousStorageIfAvailable<R>(_ body: (UnsafeBufferPointer<Element>) throws -> R) rethrows -> R? {
        try body(UnsafeBufferPointer(start: base, count: count))
    }
}

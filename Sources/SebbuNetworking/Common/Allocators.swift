public protocol Allocator {
    func allocate(_ size: Int) -> (Int, UnsafeMutablePointer<UInt8>)
    func deallocate(_ ptr: UnsafeMutablePointer<UInt8>)
}

public extension Allocator {
    func allocate(_ size: Int) -> (Int, UnsafeMutablePointer<UInt8>) {
        (size, .allocate(capacity: size))
    }

    func deallocate(_ ptr: UnsafeMutablePointer<UInt8>) {
        ptr.deallocate()
    }
}

public struct MallocAllocator: Allocator {
    public init() {}
}

public final class FixedSizeAllocator: Allocator {
    //TODO: Do we need a lock or a bounded lockfree queue here?
    @usableFromInline
    internal var cache: [UnsafeMutablePointer<UInt8>] = []

    public let allocationSize: Int
    public let cacheSize: Int

    public init(allocationSize: Int, cacheSize: Int = 1024) {
        self.allocationSize = allocationSize
        self.cacheSize = cacheSize
    }
 
    public func allocate(_ size: Int) -> (Int, UnsafeMutablePointer<UInt8>) {
        (allocationSize, cache.popLast() ?? .allocate(capacity: allocationSize))
    }

    public func deallocate(_ ptr: UnsafeMutablePointer<UInt8>) {
        guard cache.count < cacheSize else {
            ptr.deallocate()
            return
        }
        cache.append(ptr)
    }

    deinit {
        for ptr in cache {
            ptr.deallocate()
        }
    }
}

@usableFromInline
internal final class CachedPointerAllocator<T> {
    @usableFromInline
    internal var cache: [UnsafeMutablePointer<T>]

    @usableFromInline
    internal let cacheSize: Int

    //TODO: Use Mutex from stdlib
    @usableFromInline
    internal let lock: Lock

    @usableFromInline
    internal let locked: Bool

    @usableFromInline
    init(cacheSize: Int = 256, locked: Bool = false) {
        self.cache = []
        self.cacheSize = cacheSize
        self.cache.reserveCapacity(cacheSize)
        self.lock = Lock()
        self.locked = locked
    }

    @inline(__always)
    @inlinable
    func allocate() -> UnsafeMutablePointer<T> {
        if locked {
            lock.lock(); defer { lock.unlock() }
            return _allocate()
        }
        return _allocate()
    }

    @inline(__always)
    @inlinable
    func _allocate() -> UnsafeMutablePointer<T> {
        if let ptr = cache.popLast() { return ptr }
        return .allocate(capacity: 1)
    }

    @inline(__always)
    @inlinable
    func deallocate(_ ptr: UnsafeMutablePointer<T>) {
        if locked {
            lock.lock(); defer { lock.unlock() }
            _deallocate(ptr)
        } else {
            _deallocate(ptr)
        }
    }

    @inline(__always)
    @inlinable
    func _deallocate(_ ptr: UnsafeMutablePointer<T>) {
        ptr.deinitialize(count: 1)
        if cache.count < cacheSize { 
            cache.append(ptr)
        } else { 
            ptr.deallocate()
        }
    }

    deinit {
        while let ptr = cache.popLast() {
            ptr.deinitialize(count: 1)
            ptr.deallocate()
        }
    }
}
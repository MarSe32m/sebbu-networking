import SebbuCLibUV

//TODO: Consider removing when Mutex<> is available
public struct Lock: ~Copyable {
    @usableFromInline
    internal let handle: UnsafeMutablePointer<uv_mutex_t> = .allocate(capacity: 1)

    public init() {
        let err = uv_mutex_init(handle)
        precondition(err == 0)
    }

    @inline(__always)
    public func lock() {
        uv_mutex_lock(handle)
    }

    @inline(__always)
    public func unlock() {
        uv_mutex_unlock(handle)
    }

    @inline(__always)
    public func tryLock() -> Bool {
        uv_mutex_trylock(handle) == 0
    }

    deinit {
        uv_mutex_destroy(handle)
        handle.deallocate()
    }
}
import SebbuCLibUV

@usableFromInline
internal struct TCPClientChannelContext {
    @usableFromInline
    internal let loop: EventLoop

    @usableFromInline
    internal let onReceive: (([UInt8]) -> Void)

    @usableFromInline
    internal var asyncOnReceive: (([UInt8]) -> Void)?

    @usableFromInline
    internal let onConnect: () -> Void

    @usableFromInline
    internal var asyncOnConnect: ((Result<Void, Error>) -> Void)?

    @usableFromInline
    internal var onClose: (() -> Void)?

    @usableFromInline
    internal let writeRequestAllocator: CachedPointerAllocator<uv_write_t> = .init(cacheSize: 32, locked: false)

    @usableFromInline
    internal let writeRequestDataAllocator: TCPClientChannelWriteRequestAllocator = .init(cacheSize: 32)

    @usableFromInline
    internal var state: TCPClientChannelState = .disconnected

    @inlinable
    @inline(__always)
    mutating func triggerOnClose() {
        onClose?()
        onClose = nil
    }
}

@usableFromInline
internal struct TCPClientWriteRequestData {
    @usableFromInline
    internal let context: UnsafeMutablePointer<TCPClientChannelContext>

    @usableFromInline
    internal var data: UnsafeMutableBufferPointer<Int8>

    @usableFromInline
    init(context: UnsafeMutablePointer<TCPClientChannelContext>, data: UnsafeMutableBufferPointer<Int8>) {
        self.context = context
        self.data = data
    }
}

@usableFromInline
internal final class TCPClientChannelWriteRequestAllocator {
    @usableFromInline
    internal var cache: [UnsafeMutablePointer<TCPClientWriteRequestData>] = []

    @usableFromInline
    internal let cacheSize: Int

    init(cacheSize: Int) {
        self.cacheSize = cacheSize
        cache.reserveCapacity(cacheSize)
    }

    @inlinable
    func allocate(context: UnsafeMutablePointer<TCPClientChannelContext>, dataCount: Int) -> UnsafeMutablePointer<TCPClientWriteRequestData> {
        if let entry = cache.popLast() {
            if entry.pointee.data.count < dataCount {
                entry.pointee.data.deallocate()
                entry.pointee.data = .allocate(capacity: dataCount)
            }
            return entry
        }
        let entry = UnsafeMutablePointer<TCPClientWriteRequestData>.allocate(capacity: 1)
        let data = UnsafeMutableBufferPointer<Int8>.allocate(capacity: dataCount)
        entry.initialize(to: .init(context: context, data: data))
        return entry
    }

    @inlinable
    internal func deallocate(_ ptr: UnsafeMutablePointer<TCPClientWriteRequestData>) {
        guard cache.count < cacheSize else {
            ptr.pointee.data.deallocate()
            ptr.deinitialize(count: 1)
            ptr.deallocate()
            return
        }
        cache.append(ptr)
    }

    deinit {
        for entry in cache {
            entry.pointee.data.deallocate()
            entry.deinitialize(count: 1)
            entry.deallocate()
        }
    }
}

@usableFromInline
internal struct TCPServerChannelContext {
    @usableFromInline
    internal let loop: EventLoop

    @usableFromInline
    internal let onConnection: ((TCPClientChannel) -> Void)

    @usableFromInline
    internal var asyncOnConnection: ((TCPClientChannel) -> Void)?

    @usableFromInline
    internal var onClose: (() -> Void)?

    @usableFromInline
    internal var state: TCPServerChannelState = .unbound

    mutating func triggerOnClose() {
        onClose?()
        onClose = nil
    }
}
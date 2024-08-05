import SebbuCLibUV

@usableFromInline
internal struct UDPChannelContext {
    @usableFromInline
    internal let allocator: Allocator

    @usableFromInline
    internal let onReceive: (([UInt8], IPAddress) -> Void)

    @usableFromInline
    internal var onReceiveForAsync: (([UInt8], IPAddress) -> Void)?

    @usableFromInline
    internal var onClose: (() -> Void)?

    @usableFromInline
    internal let sendRequestAllocator: CachedPointerAllocator<uv_udp_send_t> = .init(cacheSize: 256, locked: false)

    @usableFromInline
    internal let sendRequestDataAllocator: UDPSendRequestDataAllocator = .init(cacheSize: 256)

    mutating func triggerOnClose() {
        onClose?()
        onClose = nil
    }
}

@usableFromInline
internal struct UDPSendRequestData {
    @usableFromInline
    internal let context: UnsafeMutablePointer<UDPChannelContext>

    @usableFromInline
    internal var data: UnsafeMutableBufferPointer<Int8>

    @usableFromInline
    init(context: UnsafeMutablePointer<UDPChannelContext>, data: UnsafeMutableBufferPointer<Int8>) {
        self.context = context
        self.data = data
    }
}

@usableFromInline
internal final class UDPSendRequestDataAllocator {
    @usableFromInline
    internal var cache: [UnsafeMutablePointer<UDPSendRequestData>] = []

    @usableFromInline
    internal let cacheSize: Int

    init(cacheSize: Int) {
        self.cacheSize = cacheSize
        cache.reserveCapacity(cacheSize)
    }

    @inlinable
    internal func allocate(context: UnsafeMutablePointer<UDPChannelContext>, dataCount: Int) -> UnsafeMutablePointer<UDPSendRequestData> {
        if let entry = cache.popLast() {
            if entry.pointee.data.count < dataCount {
                entry.pointee.data.deallocate()
                entry.pointee.data = .allocate(capacity: dataCount)
            }
            return entry
        }
        let entry = UnsafeMutablePointer<UDPSendRequestData>.allocate(capacity: 1)
        let data = UnsafeMutableBufferPointer<Int8>.allocate(capacity: dataCount)
        entry.initialize(to: .init(context: context, data: data))
        return entry
    }

    @inlinable
    internal func deallocate(_ ptr: UnsafeMutablePointer<UDPSendRequestData>) {
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
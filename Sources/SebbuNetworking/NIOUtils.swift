//
//  NIOUtils.swift
//  
//
//  Created by Sebastian Toivonen on 21.7.2022.
//

#if canImport(NIO) && canImport(Atomics)
import NIOCore
import SebbuTSDS
public final class CachedFixedSizeRecvByteBufferAllocator: RecvByteBufferAllocator {
    public let capacity: Int

    internal let cache: MPSCQueue<ByteBuffer>

    public init(capacity: Int, cacheSize: Int) {
        precondition(capacity > 0)
        precondition(cacheSize > 0)
        self.capacity = capacity
        self.cache = MPSCQueue(cacheSize: cacheSize)
    }

    public func record(actualReadBytes: Int) -> Bool {
        return false
    }

    public func buffer(allocator: ByteBufferAllocator) -> ByteBuffer {
        if var buffer = cache.dequeue() {
            // We assume here that the programmer cached a uniquely referenced ByteBuffer
            // If not, this will make a copy and defeats the purpose of the cached buffers...
            buffer.clear()
            return buffer
        }
        return allocator.buffer(capacity: capacity)
    }

    public func cache(_ buffer: ByteBuffer) {
        cache.enqueue(buffer)
    }
}
#endif

//
//  AsyncTCPClient.swift
//  
//
//  Created by Sebastian Toivonen on 3.12.2021.
//

#if canImport(NIO) && canImport(SebbuTSDS) && canImport(Atomics)
import NIO
import SebbuTSDS
import Atomics

/// An async TCPClient
/// - Note: Only one task can receive messages and one task can send messages.
/// To have multiple readers / writers, you have to manage that yourself.
public final class AsyncTCPClient: @unchecked Sendable {
    public struct Configuration {
        public var readBufferSizeHint: Int
        public var maxBytesPerRead: Int
        
        public init(readBufferSizeHint: Int = 2048, maxBytesPerRead: Int = 1024) {
            precondition(readBufferSizeHint >= 2048, "The read buffer size hint must be atleast 2048 bytes.")
            precondition(readBufferSizeHint >= maxBytesPerRead, "The read buffer size must be more than the allowed max bytes per read.")
            self.readBufferSizeHint = readBufferSizeHint
            self.maxBytesPerRead = maxBytesPerRead
        }
    }
    
    @usableFromInline
    internal let config: Configuration
    
    @usableFromInline
    internal let handler: AsyncTCPHandler
    
    @usableFromInline
    internal var channel: Channel
    
    @usableFromInline
    internal var sendBuffer: ByteBuffer = ByteBufferAllocator().buffer(capacity: 128)

    @usableFromInline
    internal var overflow: [UInt8] = []
    
    @usableFromInline
    internal init(channel: Channel, handler: AsyncTCPHandler, config: Configuration = .init()) {
        self.channel = channel
        self.handler = handler
        self.config = config
    }
    
    /// Connect to a server
    public static func connect(host: String, port: Int, configuration: Configuration = .init(), on: EventLoopGroup) async throws -> AsyncTCPClient {
        let handler = AsyncTCPHandler(maxBytes: configuration.readBufferSizeHint)
        //TODO: NIOTS support
        let channel = try await ClientBootstrap(group: on)
            .connectTimeout(.seconds(10))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .channelOption(ChannelOptions.maxMessagesPerRead, value: 2)
            .channelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator(minimum: 64, initial: configuration.maxBytesPerRead, maximum: configuration.maxBytesPerRead))
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }.connect(host: host, port: port).get()
        return AsyncTCPClient(channel: channel, handler: handler, config: configuration)
    }
    
    //TODO: func reconnect(host: String, port: Int,...)?
    
    /// Disconnect from a server
    @inline(__always)
    public final func disconnect() async throws {
        try await channel.close()
    }
    
    @inlinable
    public final func receive() async -> [UInt8] {
        channel.read()
        let data = await handler.receive()
        return data
    }
    
    //TODO: This is quite inefficient... See if we can make this better...
    // Maybe a circular buffer of some sorts? Or a deque?
    @inlinable
    public final func receive(count: Int) async -> [UInt8] {
        // Fill it with the overflow
        var accumulatedData = overflow
        overflow = []
        // Read as long as we have less the desired amount of data
        while accumulatedData.count < count {
            await accumulatedData.append(contentsOf: receive())
            // If the data was empty after the read, then receive() returned
            // empty data which means that the channel is closed
            if accumulatedData.isEmpty {
                return []
            }
        }
        
        // If we have the desired count, let's return it!
        if accumulatedData.count == count {
            return accumulatedData
        }
        
        // At this point we know that we have too much data,
        // so cut of the end and store it in the overflow buffer
        // and return the beginning of the accumulated data
        overflow = Array(accumulatedData[count...])
        return Array(accumulatedData[0..<count])
    }
    
    @inlinable
    public final func tryReceive() -> [UInt8] {
        channel.read()
        let data = handler.tryReceive()
        return data
    }
    
    /// Send data to the peer. This means that we write the data and flush it
    @inline(__always)
    public final func send(_ data: [UInt8]) {
        write(data)
        flush()
    }
    
    /// Write data to the peer but don't flush i.e. send it on the wire yet
    @inlinable
    public final func write(_ data: [UInt8]) {
        sendBuffer.clear()
        sendBuffer.reserveCapacity(data.count)
        sendBuffer.writeBytes(data)
        channel.write(sendBuffer, promise: nil)
    }
    
    /// Flush the previously written data to the wire
    @inline(__always)
    public final func flush() {
        channel.flush()
    }
}

/// This is fundamentally a Single Writer Single Reader TCPHandler with asynchronous waiting
/// capabilities
@usableFromInline
internal final class AsyncTCPHandler: ChannelDuplexHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    
    /// Underlying queue to store the read data.
    @usableFromInline
    let buffer: SPSCQueue<[UInt8]> = SPSCQueue(cacheSize: 1024)

    @usableFromInline
    let byteCount = ManagedAtomic<Int>(0)
    
    /// - 0: No continuation, might have data
    /// - 1: Continuation set
    /// - 2...UInt64.max: Undetermined / Highly likely that data is available
    @usableFromInline
    let continuationState: ManagedAtomic<UInt64> = ManagedAtomic(0)

    @usableFromInline
    var continuation: UnsafeContinuation<[UInt8], Error>?
    
    @usableFromInline
    let maxBytes: Int
    
    /// The sequence number of the current read
    /// This is used to distinguish from subsequent reads
    /// to compare to the continuationState. We start from 3
    /// so that we can wrap around at UInt64.max back to 3 so that we never
    /// accidentally wrap to 0 or 1. See channelRead(context:, data:).
    @usableFromInline
    var readSequence: UInt64 = 3

    public init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }
    
    //MARK: ChannelHandler methods
    public func read(context: ChannelHandlerContext) {
        if byteCount.load(ordering: .relaxed) >= maxBytes { return }
        context.read()
    }
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = unwrapInboundIn(data)
        if let readBytes = bytes.getBytes(at: 0, length: bytes.readableBytes) {
            // Enqueue the data. While the read method above had made sure we are under the
            // buffer size threshold, we might still overshoot and have buffered more data.
            // The over buffered data is only a maximum of twice the size of the
            // AdaptiveRecvByteBufferAllocator.maximum. We need to twiddle with it to get a
            // good estimate for the maximum size.
            buffer.enqueue(readBytes)

            // Increment the byteCount so that next read knows whether to read more or just wait
            // for the receiver to dequeue and ask for more
            byteCount.wrappingIncrement(by: readBytes.count, ordering: .acquiringAndReleasing)

            // Try to change the continuationState to current readSequence
            let (exchanged, state) = continuationState.compareExchange(expected: 0, desired: readSequence, successOrdering: .relaxed, failureOrdering: .acquiring)
            // By adding 4 we will wrap around to 3 when we read UInt64.max since 2^64 - 1 = (2^2)^32 - 1 = 4^32 - 1 cong -1 cong 3 mod 4
            // In other words, UInt64.max % 4 == 3, so UInt64.max = q * 4 + 3 for some q. If we start from 3 and add 4 to it q times,
            // then we will reach UInt64.max. At that point adding an additional 4 will wrap us back to 3 and thus we avoid accidentally
            // making the readSequence 0 or 1.
            // Why so complicated? So that we avoid an if statement :) I know, over engineering at it's finest...
            readSequence &+= 4
            if exchanged { return }
            // If the receiver is waiting for more data, then try to dequeue a block
            // If the buffer is empty, it means that from the last enqueue, the receiver
            // has already dequeued it and now wants more data. In that case we have to wait
            // for more data, i.e. we can't do anything more right now
            if state == 1, let bytes = buffer.dequeue() {
                let continuation = continuation
                self.continuation = nil
                byteCount.wrappingDecrement(by: bytes.count, ordering: .relaxed)
                continuationState.store(0, ordering: .releasing)
                continuation?.resume(returning: bytes)
                context.read()
            }
        }
    }

    @inlinable
    internal func receive() async -> [UInt8] {
        //TODO: Do this inside a cancellation handler? How do we handle it without locks?

        // Try to dequeue some bytes, if successful, decrement the byteCount and return the data.
        // If no data is present, we will need to wait for some
        if let bytes = buffer.dequeue() {
            byteCount.wrappingDecrement(by: bytes.count, ordering: .relaxed)
            return bytes
        }
        
        do {
            return try await withUnsafeThrowingContinuation { continuation in
                self.continuation = continuation
                var currentContinuationState: UInt64 = 0
                var exchanged = false
                // This while loop will loop at max twice.
                // If there really isn't any data, then the compareExchange will
                // succeed and we will wait for data. If the continuation state
                // says that there might be data (i.e. the compareExchange fails)
                // then let's see if we can get it since it can happen that we already took
                // it above on another call to this method. If it has, great, we will return that
                // if not, then we try again, and if it fails again then we can be sure
                // that there is data since no other people are allowed to receive at the same time
                // otherwise the precondition would be hit.
                while true {
                    // Try to set the state as 1, i.e. we have a receiver waiting for data
                    (exchanged, currentContinuationState) = continuationState.compareExchange(expected: currentContinuationState, desired: 1, successOrdering: .relaxed, failureOrdering: .acquiring)
                    // If success, just wait for the data
                    if exchanged { return }
                    // If we failed to exchange, the state should be 3 or above since only one receiver is allowed at once
                    precondition(currentContinuationState > 2, "Only one receiver allowed!")

                    // Check that there are bytes to read
                    // If not, it means that we yoinked them above by some other call to receive
                    // and in that case, we will try again to change the state to 1, i.e. we have a receive waiting for data.
                    // If the above exchange fails again, we know (from the precondition) that there must be data now, so the
                    // while loop actually runs a maximum of two times, i.e. only two compareExchanges
                    if let bytes = buffer.dequeue() {
                        byteCount.wrappingDecrement(by: bytes.count, ordering: .relaxed)
                        self.continuation = nil
                        continuationState.store(0, ordering: .releasing)
                        continuation.resume(returning: bytes)
                        return
                    }
                }
            }
        } catch let error {
            print("TODO: Handle error:", error)
            //TODO: How do we handle error?
            return []
        }
    }
    

    @inlinable
    internal func tryReceive() -> [UInt8] {
        if let bytes = buffer.dequeue() {
            byteCount.wrappingDecrement(by: bytes.count, ordering: .relaxed)
            return bytes
        }
        return []
    }
}
#endif

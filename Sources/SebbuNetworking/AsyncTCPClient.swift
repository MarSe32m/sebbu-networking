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
import Dispatch

/// An async TCPClient
/// - Note: Only one task can receive messages and one task can send messages.
/// To have multiple readers / writers, you have to manage that yourself.
public final class AsyncTCPClient: @unchecked Sendable {
    public struct Configuration {
        public var readBufferSizeHint: Int
        public var maxBytesPerRead: Int
        
        public init(readBufferSizeHint: Int = 1024 * 1024, maxBytesPerRead: Int = 65536) {
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
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
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
    public final func receive() async throws -> [UInt8] {
        handler.requestRead(channel: channel)
        let data = try await handler.receive()
        return data
    }
    
    //TODO: This is quite inefficient... See if we can make this better...
    // Maybe a circular buffer of some sorts? Or a deque?
    @inlinable
    public final func receive(count: Int) async throws -> [UInt8] {
        // Fill it with the overflow
        var accumulatedData = overflow
        overflow = []
        // Read as long as we have less the desired amount of data
        while accumulatedData.count < count {
            try await accumulatedData.append(contentsOf: receive())
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
        handler.requestRead(channel: channel)
        let data = handler.tryReceive()
        return data
    }
    
    /// Send data to the peer. This means that we write the data and flush it
    @inline(__always)
    public final func send(_ data: [UInt8]) {
        write(data)
        flush()
    }
    
    /// Send data to the peer and for it to be flushed {
    @inline(__always)
    public final func reliableSend(_ data: [UInt8]) async throws {
        sendBuffer.clear()
        sendBuffer.reserveCapacity(data.count)
        sendBuffer.writeBytes(data)
        try await channel.writeAndFlush(sendBuffer)
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
    /// - 2: Error has occurred
    /// - 3: Channel is closed
    /// - 14...UInt64.max: Undetermined / Highly likely that data is available
    @usableFromInline
    let continuationState: ManagedAtomic<UInt64> = ManagedAtomic(0)

    @usableFromInline
    var continuation: UnsafeContinuation<[UInt8], Error>?
    
    @usableFromInline
    let maxBytes: Int
    
    /// The sequence number of the current read
    /// This is used to distinguish from subsequent reads
    /// to compare to the continuationState. We start from 15
    /// so that by increments of 16, we can wrap around at UInt64.max back to 15 so that we never
    /// accidentally wrap to 0...14. See channelRead(context:, data:).
    @usableFromInline
    var readSequence: UInt64 = 15

    @usableFromInline
    var error: Error?
    
    @usableFromInline
    enum ContinuationState: UInt64, AtomicValue {
        case noContinuation = 0
        case continuationSet = 1
        case errorHasOccurred = 2
        case channelClosed = 3
        case _reserved4 = 4
        case _reserved5 = 5
        case _reserved6 = 6
        case _reserved7 = 7
        case _reserved8 = 8
        case _reserved9 = 9
        case _reserved10 = 10
        case _reserved11 = 11
        case _reserved12 = 12
        case _reserved13 = 13
        case _reserved14 = 14
        case dataAvailable = 15
        
        @inline(__always)
        @inlinable
        static func construct(_ value: UInt64) -> ContinuationState {
            if value >= 15 { return .dataAvailable }
            else { return .init(rawValue: value)! }
        }
    }
    
    public init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }
    
    //MARK: ChannelHandler methods
    public func read(context: ChannelHandlerContext) {
        if byteCount.load(ordering: .relaxed) >= maxBytes { return }
        context.read()
    }
    
    public func channelReadComplete(context: ChannelHandlerContext) {
        if byteCount.load(ordering: .relaxed) < maxBytes {
            context.read()
        }
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
            let (exchanged, state) = continuationState.compareExchange(expected: ContinuationState.noContinuation.rawValue,
                                                                       desired: readSequence,
                                                                       successOrdering: .relaxed,
                                                                       failureOrdering: .acquiring)
            // By adding 16 we will wrap around to 15 when we read UInt64.max since 2^64 - 1 = (2^4)^16 - 1 = 16^16 - 1 cong -1 cong 15 mod 16
            // In other words, UInt64.max % 16 == 15, so UInt64.max = q * 16 + 15 for some q. If we start from 15 and add 16 to it q times,
            // then we will reach UInt64.max. At that point adding an additional 16 will wrap us back to 15 and thus we avoid accidentally
            // making the readSequence 0...14
            // Why so complicated? So that we avoid an if statement :) I know, over engineering at it's finest...
            readSequence &+= 16
            if exchanged { return }
            
            let _continuationState = ContinuationState.construct(state)
            
            // Check if the channel is closed
            if _continuationState == .channelClosed {
                return
            }
            
            // If the receiver is waiting for more data, then try to dequeue a block
            // If the buffer is empty, it means that from the last enqueue, the receiver
            // has already dequeued it and now wants more data. In that case we have to wait
            // for more data, i.e. we can't do anything more right now
            if _continuationState == .continuationSet, let bytes = buffer.dequeue() {
                let continuation = continuation
                self.continuation = nil
                byteCount.wrappingDecrement(by: bytes.count, ordering: .relaxed)
                continuationState.store(0, ordering: .releasing)
                continuation?.resume(returning: bytes)
            }
        }
    }
    
    public func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
    }
    
    public func channelInactive(context: ChannelHandlerContext) {
        let (exchanged, _state) = continuationState.compareExchange(expected: ContinuationState.noContinuation.rawValue,
                                                                    desired: ContinuationState.channelClosed.rawValue,
                                                                    ordering: .relaxed)
        if exchanged { return }
        let state = ContinuationState.construct(_state)
        if state == .continuationSet {
            let continuation = continuation
            self.continuation = nil
            continuationState.store(3, ordering: .relaxed)
            continuation?.resume(throwing: NIOCore.ChannelError.alreadyClosed)
        } else if state == .dataAvailable {
            continuationState.store(ContinuationState.channelClosed.rawValue, ordering: .relaxed)
        }
        context.fireChannelInactive()
    }
    
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.error = error
        let (exchaged, _state) = continuationState.compareExchange(expected: ContinuationState.noContinuation.rawValue,
                                                                   desired: ContinuationState.errorHasOccurred.rawValue,
                                                                   ordering: .relaxed)
        if exchaged { return }
        let state = ContinuationState.construct(_state)
        if state == .continuationSet {
            let continuation = continuation
            self.continuation = nil
            continuationState.store(2, ordering: .relaxed)
            continuation?.resume(throwing: error)
        } else if state == .dataAvailable {
            continuationState.store(2, ordering: .relaxed)
        }
    }
    
    @inlinable
    internal func requestRead(channel: Channel) {
        if byteCount.load(ordering: .relaxed) < maxBytes {
            channel.read()
        }
    }
    
    @inlinable
    internal func receive() async throws -> [UInt8] {
        //TODO: Do this inside a cancellation handler? How do we handle it without locks?
        // Try to dequeue some bytes, if successful, decrement the byteCount and return the data.
        // If no data is present, we will need to wait for some
        if let bytes = buffer.dequeue() {
            byteCount.wrappingDecrement(by: bytes.count, ordering: .relaxed)
            return bytes
        }
        
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
                (exchanged, currentContinuationState) = continuationState.compareExchange(expected: currentContinuationState,
                                                                                          desired: ContinuationState.continuationSet.rawValue,
                                                                                          successOrdering: .relaxed,
                                                                                          failureOrdering: .acquiring)
                // If success, just wait for the data
                if exchanged { return }
                // If we failed to exchange, the state should be 14 or above since only one receiver is allowed at once
                precondition(currentContinuationState != 1, "Only one receiver allowed!")
                let state = ContinuationState.construct(currentContinuationState)
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
                } else if state == .errorHasOccurred {
                    self.continuation = nil
                    guard let error = self.error else {
                        fatalError("Error was nil while the state was in error state (i.e. 2)")
                    }
                    continuation.resume(throwing: error)
                    return
                } else if state == .channelClosed {
                    self.continuation = nil
                    continuation.resume(throwing: NIOCore.ChannelError.alreadyClosed)
                    return
                }
            }
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

extension AsyncTCPClient: AsyncSequence {
    public typealias Element = [UInt8]
    
    public struct AsyncIterator: AsyncIteratorProtocol {
        let tcpClient: AsyncTCPClient
        
        public func next() async throws -> [UInt8]? {
            try await tcpClient.receive()
        }
    }
    
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(tcpClient: self)
    }
}
#endif

//
//  AsyncUDPServer.swift
//  
//
//  Created by Sebastian Toivonen on 19.7.2022.
//

#if canImport(NIO)
import NIO
import SebbuTSDS
import Atomics

public final class AsyncUDPServer: @unchecked Sendable {
    public struct Configuration {
        public var maxDatagrams: Int
        /// The internal buffer cache in datagrams! Not bytes!
        public var bufferCacheSize: Int
        
        public var maxMessagesPerRead: Int
        
        public init(maxDatagrams: Int = .max, bufferedCacheSize: Int = 2048, maxMessagesPerRead: Int = 16) {
            self.maxDatagrams = maxDatagrams
            self.bufferCacheSize = bufferedCacheSize
            self.maxMessagesPerRead = maxMessagesPerRead
        }
    }
    
    /// The remote address of this client (should be nil)
    public var remoteAddress: SocketAddress? {
        channel.remoteAddress
    }
    
    /// The local address of this client
    public var localAddress: SocketAddress? {
        channel.localAddress
    }
    
    @usableFromInline
    internal let channel: Channel
    
    @usableFromInline
    internal let handler: AsyncUDPServerHandler
    
    internal init(channel: Channel, handler: AsyncUDPServerHandler) {
        self.channel = channel
        self.handler = handler
    }
    
    public static func create(host: String = "::", port: Int = 0, configuration: Configuration = .init(), on: EventLoopGroup) async throws -> AsyncUDPServer {
        let handler = AsyncUDPServerHandler(maxDatagrams: configuration.maxDatagrams,
                                      bufferCacheSize: configuration.bufferCacheSize)
        let channel = try await DatagramBootstrap(group: on)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        //TODO: rcv and snd buffers configurable?
            //.channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_RCVBUF), value: .init(25 * 1024 * 1024))
            //.channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_SNDBUF), value: .init(sendBufferSize))
            .channelOption(ChannelOptions.maxMessagesPerRead, value: numericCast(configuration.maxMessagesPerRead))
        // Only Linux and eventually Windows support vectored reads
        #if os(Linux) || os(Windows)
        //TODO: Tweak the read message count value, maybe it should be configurable?
            .channelOption(ChannelOptions.datagramVectorReadMessageCount, value: 64)
            .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 64 * 2048))
        #endif
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }.bind(host: host, port: port).get()
        return AsyncUDPServer(channel: channel, handler: handler)
    }
    
    @inline(__always)
    @inlinable
    public final func close() async throws {
        try await channel.close()
    }
    
    @inlinable
    public final func receive() async throws -> AddressedEnvelope<ByteBuffer> {
        handler.requestRead(channel: channel)
        return try await handler.receive()
    }
        
    @inlinable
    public final func tryReceive() -> AddressedEnvelope<ByteBuffer>? {
        handler.requestRead(channel: channel)
        return handler.tryReceive()
    }
    
    @inline(__always)
    @inlinable
    public final func send(_ envelope: AddressedEnvelope<ByteBuffer>) {
        write(envelope)
        flush()
    }
    
    @inline(__always)
    @inlinable
    public final func sendBlocking(_ envelope: AddressedEnvelope<ByteBuffer>) async throws {
        try await channel.writeAndFlush(envelope)
    }
    
    @inline(__always)
    @inlinable
    public final func write(_ envelope: AddressedEnvelope<ByteBuffer>) {
        channel.write(envelope, promise: nil)
    }
    
    @inline(__always)
    @inlinable
    public final func flush() {
        channel.flush()
    }
}

extension AsyncUDPServer: AsyncSequence {
    public typealias Element = AddressedEnvelope<ByteBuffer>
    
    public struct AsyncIterator: AsyncIteratorProtocol {
        let udpServer: AsyncUDPServer
        
        public func next() async throws -> AddressedEnvelope<ByteBuffer>? {
            try await udpServer.receive()
        }
    }
    
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(udpServer: self)
    }
}

@usableFromInline
internal final class AsyncUDPServerHandler: ChannelDuplexHandler {
    @usableFromInline
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    @usableFromInline
    typealias OutboundIn = AddressedEnvelope<ByteBuffer>
    
    @usableFromInline
    let buffer: SPSCQueue<AddressedEnvelope<ByteBuffer>>
    
    @usableFromInline
    let bufferedDatagrams: ManagedAtomic<Int> = ManagedAtomic<Int>(0)
    
    @usableFromInline
    let maxDatagrams: Int
    
    /// - 0: No continuation, might have data
    /// - 1: Continuation set
    /// - 2: Error has occurred
    /// - 3: Channel is closed
    /// - 14...UInt64.max: Undetermined / Highly likely that data is available
    @usableFromInline
    let continuationState: ManagedAtomic<UInt64> = ManagedAtomic(0)
    
    
    @usableFromInline
    var continuation: UnsafeContinuation<AddressedEnvelope<ByteBuffer>, Error>?
    
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
    
    public init(maxDatagrams: Int, bufferCacheSize: Int) {
        self.buffer = SPSCQueue(cacheSize: bufferCacheSize)
        self.maxDatagrams = maxDatagrams
    }
    
    //MARK: ChannelHandler methods
    public func read(context: ChannelHandlerContext) {
        if bufferedDatagrams.load(ordering: .relaxed) >= maxDatagrams { return }
        context.read()
    }
    
    public func channelReadComplete(context: ChannelHandlerContext) {
        if bufferedDatagrams.load(ordering: .relaxed) >= maxDatagrams { return }
        context.read()
    }
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        
        // Enqueue the envelope.
        buffer.enqueue(envelope)

        // Increment the buffered datagram count
        bufferedDatagrams.wrappingIncrement(ordering: .acquiringAndReleasing)
        
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
            bufferedDatagrams.wrappingDecrement(ordering: .relaxed)
            continuationState.store(0, ordering: .releasing)
            continuation?.resume(returning: bytes)
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
    internal final func requestRead(channel: Channel) {
        // If the upper bound is "unbounded" then we don't really need to manually call read since NIO will do it for us
        if maxDatagrams != .max && bufferedDatagrams.load(ordering: .relaxed) < maxDatagrams  {
            channel.read()
        }
    }
    
    @inlinable
    internal final func receive() async throws -> AddressedEnvelope<ByteBuffer> {
        //TODO: Do this inside a cancellation handler? How do we handle it without locks?
        // Try to dequeue a datagram, if successful, decrement the buffered datagram count and return the datagram.
        if let envelope = buffer.dequeue() {
            bufferedDatagrams.wrappingDecrement(ordering: .relaxed)
            return envelope
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
                    bufferedDatagrams.wrappingDecrement(ordering: .relaxed)
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
    
    @inline(__always)
    @inlinable
    internal final func tryReceive() -> AddressedEnvelope<ByteBuffer>? {
        if let envelope = buffer.dequeue() {
            bufferedDatagrams.wrappingDecrement(ordering: .relaxed)
            return envelope
        }
        return nil
    }
}
#endif


//
//  LegacyAsyncHandlers.swift
//  
//
//  Created by Sebastian Toivonen on 24.7.2022.
//

#if canImport(NIO)
import NIO
import SebbuTSDS
import Atomics

@usableFromInline
internal final class AsyncTCPHandler: ChannelDuplexHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    
    @usableFromInline
    internal struct TaskCancelEvent {
        @inlinable
        init() {}
    }
    
    @usableFromInline
    internal struct TimeoutEvent {
        @usableFromInline
        let receiveId: Int
        
        @inlinable
        init(receiveId: Int) {
            self.receiveId = receiveId
        }
    }
    
    /// Underlying queue to store the read data.
    @usableFromInline
    let buffer: SPSCQueue<ByteBuffer> = SPSCQueue(cacheSize: 1024)

    @usableFromInline
    let bufferedMessages = ManagedAtomic<Int>(0)
    
    @usableFromInline
    let maxBufferSize: Int
    
    /// - 0: No continuation, might have data
    /// - 1: Continuation set
    /// - 2: Error has occurred
    /// - 3: Channel is closed
    /// - 4: Receive task cancelled
    /// - 5: Receive timed out
    /// - 14...UInt64.max: Undetermined / Highly likely that data is available
    @usableFromInline
    let continuationState: ManagedAtomic<UInt64> = ManagedAtomic(0)

    @usableFromInline
    var continuation: UnsafeContinuation<ByteBuffer, Error>?
    
    @usableFromInline
    let receiveCount: ManagedAtomic<Int> = ManagedAtomic(0)
    
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
        case receiveTaskCancelled = 4
        case receiveTimeout = 5
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
    
    public init(bufferSize: Int) {
        self.maxBufferSize = bufferSize
    }
    
    //MARK: ChannelHandler methods
    @inlinable
    public func read(context: ChannelHandlerContext) {
        if bufferedMessages.load(ordering: .relaxed) >= maxBufferSize { return }
        context.read()
    }
    
    @inlinable
    public func channelReadComplete(context: ChannelHandlerContext) {
        if bufferedMessages.load(ordering: .relaxed) < maxBufferSize {
            context.read()
        }
    }
    
    @inlinable
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = unwrapInboundIn(data)
        // Enqueue the data. While the read method above had made sure we are under the
        // buffer size threshold, we might still overshoot and have buffered more data.
        // The over buffered data is only a maximum of twice the size of the
        // AdaptiveRecvByteBufferAllocator.maximum. We need to twiddle with it to get a
        // good estimate for the maximum size.
        buffer.enqueue(bytes)

        // Increment the byteCount so that next read knows whether to read more or just wait
        // for the receiver to dequeue and ask for more
        bufferedMessages.wrappingIncrement(ordering: .acquiringAndReleasing)

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
            bufferedMessages.wrappingDecrement(ordering: .relaxed)
            continuationState.store(ContinuationState.noContinuation.rawValue, ordering: .releasing)
            continuation?.resume(returning: bytes)
        }
    }
    
    @inlinable
    public func channelInactive(context: ChannelHandlerContext) {
        let (exchanged, _state) = continuationState.compareExchange(expected: ContinuationState.noContinuation.rawValue,
                                                                    desired: ContinuationState.channelClosed.rawValue,
                                                                    ordering: .relaxed)
        if exchanged { return }
        let state = ContinuationState.construct(_state)
        if state == .continuationSet {
            let continuation = continuation
            self.continuation = nil
            continuationState.store(ContinuationState.channelClosed.rawValue, ordering: .relaxed)
            continuation?.resume(throwing: NIOCore.ChannelError.alreadyClosed)
        } else if state == .dataAvailable {
            continuationState.store(ContinuationState.channelClosed.rawValue, ordering: .relaxed)
        }
        context.fireChannelInactive()
    }
    
    @inlinable
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
            continuationState.store(ContinuationState.errorHasOccurred.rawValue, ordering: .relaxed)
            continuation?.resume(throwing: error)
        } else if state == .dataAvailable {
            continuationState.store(ContinuationState.errorHasOccurred.rawValue, ordering: .relaxed)
        }
    }
    
    @inlinable
    public func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        if event is TaskCancelEvent {
            let (exchanged, _state) = continuationState.compareExchange(expected: ContinuationState.noContinuation.rawValue,
                                                                        desired: ContinuationState.receiveTaskCancelled.rawValue,
                                                                        ordering: .relaxed)
            if exchanged { return }
            let state = ContinuationState.construct(_state)
            if state == .continuationSet {
                let continuation = continuation
                self.continuation = nil
                continuationState.store(ContinuationState.noContinuation.rawValue, ordering: .relaxed)
                continuation?.resume(throwing: CancellationError())
            }
        } else if let event = event as? TimeoutEvent {
            if event.receiveId != receiveCount.load(ordering: .relaxed) { return }
            let (exchanged, _state) = continuationState.compareExchange(expected: ContinuationState.noContinuation.rawValue,
                                                                        desired: ContinuationState.receiveTimeout.rawValue,
                                                                        ordering: .relaxed)
            if exchanged { return }
            let state = ContinuationState.construct(_state)
            if state == .continuationSet {
                let continuation = continuation
                self.continuation = nil
                continuationState.store(ContinuationState.noContinuation.rawValue, ordering: .relaxed)
                continuation?.resume(throwing: ReceiveTimeoutError())
            }
        }
        context.triggerUserOutboundEvent(event, promise: promise)
    }
    
    @inlinable
    internal func requestRead(channel: Channel) {
        if bufferedMessages.load(ordering: .relaxed) < maxBufferSize {
            channel.read()
        }
    }
    
    @inlinable
    internal func receive(channel: Channel, timeout: UInt64 = .max) async throws -> ByteBuffer {
        // Try to dequeue some bytes, if successful, decrement the byteCount and return the data.
        // If no data is present, we will need to wait for some
        if let bytes = buffer.dequeue() {
            bufferedMessages.wrappingDecrement(ordering: .relaxed)
            return bytes
        }
        
        let currentReceiveId = receiveCount.wrappingIncrementThenLoad(ordering: .acquiringAndReleasing)
        
        let timeoutTask: Scheduled<Void>? = {
            if timeout != .max {
                return channel.eventLoop.scheduleTask(in: .nanoseconds(Int64(timeout))) {
                    channel.triggerUserOutboundEvent(TimeoutEvent(receiveId: currentReceiveId), promise: nil)
                }
            }
            return nil
        }()
        
        return try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation { continuation in
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
                        bufferedMessages.wrappingDecrement(ordering: .relaxed)
                        self.continuation = nil
                        continuationState.store(ContinuationState.noContinuation.rawValue, ordering: .releasing)
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
                    } else if state == .receiveTaskCancelled {
                        self.continuation = nil
                        continuationState.store(ContinuationState.noContinuation.rawValue, ordering: .releasing)
                        continuation.resume(throwing: CancellationError())
                        return
                    } else if state == .receiveTimeout {
                        print("häh?")
                        precondition(timeout < .max)
                        self.continuation = nil
                        continuationState.store(ContinuationState.noContinuation.rawValue, ordering: .releasing)
                        continuation.resume(throwing: ReceiveTimeoutError())
                        return
                    }
                }
            }
        } onCancel: {
            timeoutTask?.cancel()
            channel.triggerUserOutboundEvent(TaskCancelEvent(), promise: nil)
        }
    }
    

    @inlinable
    internal func tryReceive() -> ByteBuffer? {
        if let bytes = buffer.dequeue() {
            bufferedMessages.wrappingDecrement(ordering: .relaxed)
            return bytes
        }
        return nil
    }
}

extension AsyncTCPClient: AsyncSequence {
    public typealias Element = ByteBuffer
    
    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline
        let tcpClient: AsyncTCPClient
        
        @inlinable
        init(tcpClient: AsyncTCPClient) {
            self.tcpClient = tcpClient
        }
        
        @inlinable
        public func next() async throws -> ByteBuffer? {
            try await tcpClient.receive()
        }
    }
    
    @inlinable
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(tcpClient: self)
    }
}

extension AsyncUDPClient: AsyncSequence {
    public typealias Element = AddressedEnvelope<ByteBuffer>
    
    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline
        let udpClient: AsyncUDPClient
        
        @inlinable
        init(udpClient: AsyncUDPClient) {
            self.udpClient = udpClient
        }
        
        @inlinable
        public func next() async throws -> AddressedEnvelope<ByteBuffer>? {
            try await udpClient.receive()
        }
    }
    
    @inlinable
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(udpClient: self)
    }
}

@usableFromInline
internal final class AsyncUDPHandler: ChannelDuplexHandler {
    @usableFromInline
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    @usableFromInline
    typealias OutboundIn = AddressedEnvelope<ByteBuffer>
    
    @usableFromInline
    internal struct TaskCancelEvent {
        @inlinable
        init() {}
    }
    
    @usableFromInline
    internal struct TimeoutEvent {
        @usableFromInline
        let receiveId: Int
        
        @inlinable
        init(receiveId: Int) {
            self.receiveId = receiveId
        }
    }
    
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
    /// - 4: Receive task cancelled
    /// - 5: Receive timed out
    /// - 14...UInt64.max: Undetermined / Highly likely that data is available
    @usableFromInline
    let continuationState: ManagedAtomic<UInt64> = ManagedAtomic(0)
    
    @usableFromInline
    var continuation: UnsafeContinuation<AddressedEnvelope<ByteBuffer>, Error>?
    
    @usableFromInline
    let receiveCount: ManagedAtomic<Int> = ManagedAtomic(0)
    
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
        case receiveTaskCancelled = 4
        case receiveTimeout = 5
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
    @inlinable
    public func read(context: ChannelHandlerContext) {
        if maxDatagrams != .max && bufferedDatagrams.load(ordering: .relaxed) >= maxDatagrams { return }
        context.read()
    }
    
    @inlinable
    public func channelReadComplete(context: ChannelHandlerContext) {
        if maxDatagrams == .max { return }
        if bufferedDatagrams.load(ordering: .relaxed) >= maxDatagrams { return }
        context.read()
    }
    
    @inlinable
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
            continuationState.store(ContinuationState.noContinuation.rawValue, ordering: .releasing)
            continuation?.resume(returning: bytes)
        }
    }
    
    @inlinable
    public func channelInactive(context: ChannelHandlerContext) {
        let (exchanged, _state) = continuationState.compareExchange(expected: ContinuationState.noContinuation.rawValue,
                                                                    desired: ContinuationState.channelClosed.rawValue,
                                                                    ordering: .relaxed)
        if exchanged { return }
        let state = ContinuationState.construct(_state)
        if state == .continuationSet {
            let continuation = continuation
            self.continuation = nil
            continuationState.store(ContinuationState.channelClosed.rawValue, ordering: .relaxed)
            continuation?.resume(throwing: NIOCore.ChannelError.alreadyClosed)
        } else if state == .dataAvailable {
            continuationState.store(ContinuationState.channelClosed.rawValue, ordering: .relaxed)
        }
        context.fireChannelInactive()
    }
    
    @inlinable
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
            continuationState.store(ContinuationState.errorHasOccurred.rawValue, ordering: .relaxed)
            continuation?.resume(throwing: error)
        } else if state == .dataAvailable {
            continuationState.store(ContinuationState.errorHasOccurred.rawValue, ordering: .relaxed)
        }
    }
    
    @inlinable
    public func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        if event is TaskCancelEvent {
            let (exchanged, _state) = continuationState.compareExchange(expected: ContinuationState.noContinuation.rawValue,
                                                                        desired: ContinuationState.receiveTaskCancelled.rawValue,
                                                                        ordering: .relaxed)
            if exchanged { return }
            let state = ContinuationState.construct(_state)
            if state == .continuationSet {
                let continuation = continuation
                self.continuation = nil
                continuationState.store(ContinuationState.noContinuation.rawValue, ordering: .relaxed)
                continuation?.resume(throwing: CancellationError())
            }
        } else if let event = event as? TimeoutEvent {
            if event.receiveId != receiveCount.load(ordering: .relaxed) { return }
            let (exchanged, _state) = continuationState.compareExchange(expected: ContinuationState.noContinuation.rawValue,
                                                                        desired: ContinuationState.receiveTimeout.rawValue,
                                                                        ordering: .relaxed)
            if exchanged || event.receiveId != receiveCount.load(ordering: .relaxed) { return }
            let state = ContinuationState.construct(_state)
            if state == .continuationSet {
                let continuation = continuation
                self.continuation = nil
                continuationState.store(ContinuationState.noContinuation.rawValue, ordering: .relaxed)
                continuation?.resume(throwing: ReceiveTimeoutError())
            }
        }
        context.triggerUserOutboundEvent(event, promise: promise)
    }
    
    @inlinable
    internal final func requestRead(channel: Channel) {
        // If the upper bound is "unbounded" then we don't really need to manually call read since NIO will do it for us
        if maxDatagrams != .max && bufferedDatagrams.load(ordering: .relaxed) < maxDatagrams {
            channel.read()
        }
    }
    
    @inlinable
    internal final func receive(channel: Channel, timeout: UInt64 = .max) async throws -> AddressedEnvelope<ByteBuffer> {
        // Try to dequeue a datagram, if successful, decrement the buffered datagram count and return the datagram.
        if let envelope = buffer.dequeue() {
            bufferedDatagrams.wrappingDecrement(ordering: .relaxed)
            return envelope
        }
        
        let currentReceiveId = receiveCount.wrappingIncrementThenLoad(ordering: .acquiringAndReleasing)
        
        let timeoutTask: Scheduled<Void>? = {
            if timeout != .max {
                return channel.eventLoop.scheduleTask(in: .nanoseconds(Int64(timeout))) {
                    channel.triggerUserOutboundEvent(TimeoutEvent(receiveId: currentReceiveId), promise: nil)
                }
            }
            return nil
        }()
        
        return try await withTaskCancellationHandler {
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
                    precondition(currentContinuationState != ContinuationState.continuationSet.rawValue, "Only one receiver allowed!")
                    let state = ContinuationState.construct(currentContinuationState)
                    // Check that there are bytes to read
                    // If not, it means that we yoinked them above by some other call to receive
                    // and in that case, we will try again to change the state to 1, i.e. we have a receive waiting for data.
                    // If the above exchange fails again, we know (from the precondition) that there must be data now, so the
                    // while loop actually runs a maximum of two times, i.e. only two compareExchanges
                    if let bytes = buffer.dequeue() {
                        bufferedDatagrams.wrappingDecrement(ordering: .relaxed)
                        self.continuation = nil
                        continuationState.store(ContinuationState.noContinuation.rawValue, ordering: .releasing)
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
                    } else if state == .receiveTaskCancelled {
                        self.continuation = nil
                        continuationState.store(ContinuationState.noContinuation.rawValue, ordering: .releasing)
                        continuation.resume(throwing: CancellationError())
                        return
                    } else if state == .receiveTimeout {
                        precondition(timeout < .max)
                        self.continuation = nil
                        continuationState.store(ContinuationState.noContinuation.rawValue, ordering: .releasing)
                        continuation.resume(throwing: ReceiveTimeoutError())
                        return
                    }
                }
            }
        } onCancel: {
            timeoutTask?.cancel()
            channel.triggerUserOutboundEvent(TaskCancelEvent(), promise: nil)
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

@usableFromInline
internal final class AsyncUDPServerHandler: ChannelDuplexHandler {
    @usableFromInline
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    @usableFromInline
    typealias OutboundIn = AddressedEnvelope<ByteBuffer>
    
    @usableFromInline
    internal struct TaskCancelEvent {
        @inlinable
        init() {}
    }
    
    @usableFromInline
    internal struct TimeoutEvent {
        @usableFromInline
        let receiveId: Int
        
        @inlinable
        init(receiveId: Int) {
            self.receiveId = receiveId
        }
    }
    
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
    /// - 4: Receive task cancelled
    /// - 14...UInt64.max: Undetermined / Highly likely that data is available
    @usableFromInline
    let continuationState: ManagedAtomic<UInt64> = ManagedAtomic(0)
    
    @usableFromInline
    var continuation: UnsafeContinuation<AddressedEnvelope<ByteBuffer>, Error>?
    
    @usableFromInline
    let receiveCount: ManagedAtomic<Int> = ManagedAtomic(0)
    
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
        case receiveTaskCancelled = 4
        case receiveTimeout = 5
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
    @inlinable
    public func read(context: ChannelHandlerContext) {
        if maxDatagrams != .max && bufferedDatagrams.load(ordering: .relaxed) >= maxDatagrams { return }
        context.read()
    }
    
    @inlinable
    public func channelReadComplete(context: ChannelHandlerContext) {
        // We are autoReading if the datagram buffering is unbounded
        if maxDatagrams == .max { return }
        if bufferedDatagrams.load(ordering: .relaxed) >= maxDatagrams { return }
        context.read()
    }
    
    @inlinable
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
            continuationState.store(ContinuationState.noContinuation.rawValue, ordering: .releasing)
            continuation?.resume(returning: bytes)
        }
    }
    
    @inlinable
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
    
    @inlinable
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
            continuationState.store(ContinuationState.errorHasOccurred.rawValue, ordering: .relaxed)
            continuation?.resume(throwing: error)
        } else if state == .dataAvailable {
            continuationState.store(ContinuationState.errorHasOccurred.rawValue, ordering: .relaxed)
        }
    }
    
    @inlinable
    public func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        if event is TaskCancelEvent {
            let (exchanged, _state) = continuationState.compareExchange(expected: ContinuationState.noContinuation.rawValue,
                                                                        desired: ContinuationState.receiveTaskCancelled.rawValue,
                                                                        ordering: .relaxed)
            if exchanged { return }
            let state = ContinuationState.construct(_state)
            if state == .continuationSet {
                let continuation = continuation
                self.continuation = nil
                continuationState.store(ContinuationState.noContinuation.rawValue, ordering: .relaxed)
                continuation?.resume(throwing: CancellationError())
            }
        } else if let event = event as? TimeoutEvent {
            if event.receiveId != receiveCount.load(ordering: .relaxed) { return }
            let (exchanged, _state) = continuationState.compareExchange(expected: ContinuationState.noContinuation.rawValue,
                                                                        desired: ContinuationState.receiveTimeout.rawValue,
                                                                        ordering: .relaxed)
            if exchanged { return }
            let state = ContinuationState.construct(_state)
            if state == .continuationSet {
                let continuation = continuation
                self.continuation = nil
                continuationState.store(ContinuationState.noContinuation.rawValue, ordering: .relaxed)
                continuation?.resume(throwing: ReceiveTimeoutError())
            }
        }
        context.triggerUserOutboundEvent(event, promise: promise)
    }
    
    @inlinable
    internal final func requestRead(channel: Channel) {
        // If the upper bound is "unbounded" then we don't really need to manually call read since NIO will do it for us
        if maxDatagrams != .max && bufferedDatagrams.load(ordering: .relaxed) < maxDatagrams  {
            channel.read()
        }
    }
    
    @inlinable
    internal final func receive(channel: Channel, timeout: UInt64 = .max) async throws -> AddressedEnvelope<ByteBuffer> {
        // Try to dequeue a datagram, if successful, decrement the buffered datagram count and return the datagram.
        if let envelope = buffer.dequeue() {
            bufferedDatagrams.wrappingDecrement(ordering: .relaxed)
            return envelope
        }
        
        let currentReceiveId = receiveCount.wrappingIncrementThenLoad(ordering: .acquiringAndReleasing)
        
        let timeoutTask: Scheduled<Void>? = {
            if timeout != .max {
                return channel.eventLoop.scheduleTask(in: .nanoseconds(Int64(timeout))) {
                    channel.triggerUserOutboundEvent(TimeoutEvent(receiveId: currentReceiveId), promise: nil)
                }
            }
            return nil
        }()
        
        return try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation { continuation in
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
                        continuationState.store(ContinuationState.noContinuation.rawValue, ordering: .releasing)
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
                    } else if state == .receiveTaskCancelled {
                        self.continuation = nil
                        continuationState.store(ContinuationState.noContinuation.rawValue, ordering: .releasing)
                        continuation.resume(throwing: CancellationError())
                        return
                    } else if state == .receiveTimeout {
                        precondition(timeout < .max)
                        self.continuation = nil
                        continuationState.store(ContinuationState.noContinuation.rawValue, ordering: .releasing)
                        continuation.resume(throwing: ReceiveTimeoutError())
                        return
                    }
                }
            }
        } onCancel: {
            timeoutTask?.cancel()
            channel.triggerUserOutboundEvent(TaskCancelEvent(), promise: nil)
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

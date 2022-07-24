//
//  AsyncDuplexHandler.swift
//  
//
//  Created by Sebastian Toivonen on 24.7.2022.
//

#if canImport(NIO)
import NIO
import SebbuTSDS
import Atomics

public struct ReceiveTimeoutError: Error {
    @inlinable
    init() {}
}

@usableFromInline
internal final class AsyncDuplexHandler<Element>: ChannelDuplexHandler {
    @usableFromInline
    typealias InboundIn = Element
    @usableFromInline
    typealias OutboundIn = Element
    
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
    let buffer: SPSCQueue<Element>
    
    @usableFromInline
    let bufferedMessages: ManagedAtomic<Int> = ManagedAtomic<Int>(0)
    
    @usableFromInline
    let maxMessages: Int
    
    /// - 0: No continuation, might have data
    /// - 1: Continuation set
    /// - 2: Error has occurred
    /// - 3: Channel is closed
    /// - 4: Receive task cancelled
    /// - 14...UInt64.max: Undetermined / Highly likely that data is available
    @usableFromInline
    let continuationState: ManagedAtomic<UInt64> = ManagedAtomic(0)
    
    @usableFromInline
    let receiveCount: ManagedAtomic<Int> = ManagedAtomic(0)
    
    @usableFromInline
    var continuation: UnsafeContinuation<Element, Error>?
    
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
    
    public init(maxMessages: Int, bufferCacheSize: Int) {
        self.buffer = SPSCQueue(cacheSize: bufferCacheSize)
        self.maxMessages = maxMessages
    }
    
    //MARK: ChannelHandler methods
    @inlinable
    public func read(context: ChannelHandlerContext) {
        if maxMessages != .max && bufferedMessages.load(ordering: .relaxed) >= maxMessages { return }
        context.read()
    }
    
    @inlinable
    public func channelReadComplete(context: ChannelHandlerContext) {
        // We are autoReading if the datagram buffering is unbounded
        if maxMessages == .max { return }
        if bufferedMessages.load(ordering: .relaxed) >= maxMessages { return }
        context.read()
    }
    
    @inlinable
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let element = unwrapInboundIn(data)
        
        // Enqueue the envelope.
        buffer.enqueue(element)

        // Increment the buffered datagram count
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
        if _continuationState == .continuationSet, let element = buffer.dequeue() {
            let continuation = continuation
            self.continuation = nil
            bufferedMessages.wrappingDecrement(ordering: .relaxed)
            continuationState.store(ContinuationState.noContinuation.rawValue, ordering: .releasing)
            continuation?.resume(returning: element)
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
        if maxMessages != .max && bufferedMessages.load(ordering: .relaxed) < maxMessages  {
            channel.read()
        }
    }
    
    @inlinable
    internal final func receive(channel: Channel, timeout: UInt64 = .max) async throws -> Element {
        // Try to dequeue a datagram, if successful, decrement the buffered datagram count and return the datagram.
        if let envelope = buffer.dequeue() {
            bufferedMessages.wrappingDecrement(ordering: .relaxed)
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
    internal final func tryReceive() -> Element? {
        if let envelope = buffer.dequeue() {
            bufferedMessages.wrappingDecrement(ordering: .relaxed)
            return envelope
        }
        return nil
    }
}
#endif

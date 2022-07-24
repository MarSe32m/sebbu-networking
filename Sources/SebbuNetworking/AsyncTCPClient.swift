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
        /// The number of read messages to be buffered
        public var maxMessages: Int
        
        /// The number of messages read per event loop read call
        public var maxMessagesPerRead: Int
        
        public init(maxMessages: Int = 16, maxMessagesPerRead: Int = 16) {
            precondition(maxMessages > 0, "The buffer must be more than zero")
            precondition(maxMessagesPerRead > 0, "The maximum messages per read must be more than zero")
            self.maxMessages = maxMessages
            self.maxMessagesPerRead = maxMessagesPerRead
        }
    }
    
    @usableFromInline
    internal let config: Configuration
    
    @usableFromInline
    internal let handler: AsyncDuplexHandler<ByteBuffer>
    
    @usableFromInline
    internal var channel: Channel
    
    @usableFromInline
    internal var sendBuffer: ByteBuffer

    @usableFromInline
    internal var overflow: ByteBuffer
    
    /// The remote address of this client
    public var remoteAddress: SocketAddress? {
        channel.remoteAddress
    }
    
    /// The local address of this client
    public var localAddress: SocketAddress? {
        channel.localAddress
    }
    
    @usableFromInline
    internal init(channel: Channel, handler: AsyncDuplexHandler<ByteBuffer>/*handler: AsyncTCPHandler*/, config: Configuration = .init()) {
        self.channel = channel
        self.handler = handler
        self.config = config
        self.sendBuffer = channel.allocator.buffer(capacity: 128)
        self.overflow = channel.allocator.buffer(capacity: 128)
    }
    
    /// Connect to a server
    public static func connect(host: String, port: Int, configuration: Configuration = .init(), on: EventLoopGroup) async throws -> AsyncTCPClient {
        let handler = AsyncDuplexHandler<ByteBuffer>(maxMessages: configuration.maxMessages, bufferCacheSize: configuration.maxMessages)
        //TODO: NIOTS support
        let channel = try await ClientBootstrap(group: on)
            .connectTimeout(.seconds(10))
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .channelOption(ChannelOptions.maxMessagesPerRead, value: numericCast(configuration.maxMessagesPerRead))
            .channelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
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
    public final func receive() async throws -> ByteBuffer {
        handler.requestRead(channel: channel)
        return try await handler.receive(channel: channel)
    }
    
    //TODO: Update this to use Swift.Duration
    /// Receive data with a timeout, in nanoseconds. If the timeout is reached
    /// this method will throw an AsyncTCPClient.ReceiveTimeoutError
    @inlinable
    public final func receive(timeout: UInt64) async throws -> ByteBuffer {
        handler.requestRead(channel: channel)
        return try await handler.receive(channel: channel, timeout: timeout)
    }
    
    //TODO: This is quite inefficient... See if we can make this better...
    // Maybe a circular buffer of some sorts? Or a deque?
    @inlinable
    public final func receive(count: Int, timeout: UInt64 = .max) async throws -> ByteBuffer {
        // Fill it with the overflow
        var accumulatedBytes = overflow
        overflow.clear()
        accumulatedBytes.reserveCapacity(count)
        // Read as long as we have less the desired amount of data
        while accumulatedBytes.readableBytes < count {
            var bytes = try await receive(timeout: timeout)
            accumulatedBytes.writeBuffer(&bytes)
            
            // We shouldn't get zero bytes from a read right?
            assert(accumulatedBytes.readableBytes > 0)
        }
        
        // If we have the desired count, let's return it!
        if accumulatedBytes.readableBytes == count {
            return accumulatedBytes
        }
        
        // At this point we know that we have too much data,
        // so cut of the end and store it in the overflow buffer
        // and return the beginning of the accumulated data
        overflow = accumulatedBytes.getSlice(at: count, length: accumulatedBytes.readableBytes - count)!
        return accumulatedBytes.getSlice(at: 0, length: count)!
    }
    
    @inlinable
    public final func tryReceive() -> ByteBuffer? {
        handler.requestRead(channel: channel)
        let data = handler.tryReceive()
        return data
    }
    
    /// Send bytes to the peer. This means that we write the data and flush it
    @inline(__always)
    public final func send(_ bytes: ByteBuffer) {
        write(bytes)
        flush()
    }
    
    /// Send bytes to the peer and wait for it to be flushed
    @inline(__always)
    public final func sendBlocking(_ bytes: ByteBuffer) async throws {
        try await channel.writeAndFlush(bytes)
    }
    
    /// Write data to the peer but don't flush i.e. send it on the wire yet
    @inline(__always)
    public final func write(_ bytes: ByteBuffer) {
        channel.write(bytes, promise: nil)
    }
    
    /// Send data to the peer. This means that we write the data and flush it
    @inline(__always)
    public final func send(_ data: [UInt8]) {
        write(data)
        flush()
    }
    
    /// Send data to the peer and wait for it to be flushed
    @inlinable
    public final func sendBlocking(_ data: [UInt8]) async throws {
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
    
    deinit {
        if channel.isActive {
            print("AsyncTCPClient deinitialized but not closed...", remoteAddress ?? "No address")
            channel.close(mode: .all, promise: nil)
        }
    }
}
#endif

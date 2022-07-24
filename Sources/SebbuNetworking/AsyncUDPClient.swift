//
//  AsyncUDPClient.swift
//  
//
//  Created by Sebastian Toivonen on 27.12.2021.
//

#if canImport(NIO)
import NIO
import SebbuTSDS
import Atomics

public final class AsyncUDPClient: @unchecked Sendable {
    public struct Configuration {
        public var maxDatagrams: Int
        /// The internal buffer cache in datagrams! Not bytes!
        public var bufferCacheSize: Int
        
        //TODO: Buffering strategy? i.e. unbounded, dropNewest or dropOldest
        
        public init(maxDatagrams: Int = .max, bufferedCacheSize: Int = 2048) {
            self.maxDatagrams = maxDatagrams
            self.bufferCacheSize = bufferedCacheSize
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
    internal let handler: AsyncDuplexHandler<AddressedEnvelope<ByteBuffer>>
    
    internal init(channel: Channel, handler: AsyncDuplexHandler<AddressedEnvelope<ByteBuffer>>/*handler: AsyncUDPHandler*/) {
        self.channel = channel
        self.handler = handler
    }
    
    public static func create(host: String = "::", port: Int = 0, configuration: Configuration = .init(), on: EventLoopGroup) async throws -> AsyncUDPClient {
        let handler = AsyncDuplexHandler<AddressedEnvelope<ByteBuffer>>(maxMessages: configuration.maxDatagrams,
                                                                        bufferCacheSize: configuration.bufferCacheSize)
        let channel = try await DatagramBootstrap(group: on)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        //TODO: rcv and snd buffers configurable?
            //.channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_RCVBUF), value: .init(25 * 1024 * 1024))
            //.channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_SNDBUF), value: .init(sendBufferSize))
            .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 2048))
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }.bind(host: host, port: port).get()
        return AsyncUDPClient(channel: channel, handler: handler)
    }
    
    @inline(__always)
    @inlinable
    public final func close() async throws {
        try await channel.close()
    }
    
    //TODO: Update this to use Swift.Duration
    /// Receive data with a timeout, in nanoseconds
    @inlinable
    public final func receive(timeout: UInt64) async throws -> AddressedEnvelope<ByteBuffer> {
        handler.requestRead(channel: channel)
        return try await handler.receive(channel: channel, timeout: timeout)
    }
    
    @inlinable
    public final func receive() async throws -> AddressedEnvelope<ByteBuffer> {
        handler.requestRead(channel: channel)
        return try await handler.receive(channel: channel)
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
    
    deinit {
        if channel.isActive {
            print("AsyncUDPClient deinitialized but not closed...")
            channel.close(mode: .all, promise: nil)
        }
    }
}
#endif

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
    internal let handler: AsyncDuplexHandler<AddressedEnvelope<ByteBuffer>>
    
    internal init(channel: Channel, handler: AsyncDuplexHandler<AddressedEnvelope<ByteBuffer>>/*handler: AsyncUDPServerHandler*/) {
        self.channel = channel
        self.handler = handler
    }
    
    public static func create(host: String = "::", port: Int = 0, configuration: Configuration = .init(), on: EventLoopGroup) async throws -> AsyncUDPServer {
        let handler = AsyncDuplexHandler<AddressedEnvelope<ByteBuffer>>(maxMessages: configuration.maxDatagrams,
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
    
    //TODO: Update this to use Swift.Duration
    /// Receive data with a timeout, in nanoseconds. If timeout is reached,
    /// this will throw a ReceiveTimeoutError.
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
            print("AsyncUDPServer deinitialized but not closed...")
            channel.close(mode: .all, promise: nil)
        }
    }
}

extension AsyncUDPServer: AsyncSequence {
    public typealias Element = AddressedEnvelope<ByteBuffer>
    
    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline
        let udpServer: AsyncUDPServer
        
        @inlinable
        init(udpServer: AsyncUDPServer) {
            self.udpServer = udpServer
        }
        
        @inlinable
        public func next() async throws -> AddressedEnvelope<ByteBuffer>? {
            try await udpServer.receive()
        }
    }
    
    @inlinable
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(udpServer: self)
    }
}
#endif


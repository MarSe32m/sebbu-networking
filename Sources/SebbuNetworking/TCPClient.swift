//
//  TCPClient.swift
//  
//
//  Created by Sebastian Toivonen on 16.6.2021.
//
#if canImport(NIO)
import NIO
#if canImport(NIOTransportServices) && canImport(Network)
import NIOTransportServices
#endif

public protocol TCPClientProtocol: AnyObject {
    func received(_ data: [UInt8])
    func connected()
    func disconnected()
}

public final class TCPClient {
    internal var receiveHandler: TCPReceiveHandler
    
    public weak var delegate: TCPClientProtocol? {
        didSet {
            receiveHandler.delegate = delegate
        }
    }
    
    public var port: Int? {
        channel?.localAddress?.port
    }
    
    @usableFromInline
    internal var channel: Channel!
    
    public let eventLoopGroup: EventLoopGroup
    
    private var isSharedEventLoopGroup = false
    
    public init() {
        #if canImport(NIOTransportServices) && canImport(Network)
        self.eventLoopGroup = NIOTSEventLoopGroup()
        #else
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        #endif
        self.receiveHandler = TCPReceiveHandler()
    }
    
    public init(eventLoopGroup: EventLoopGroup) {
        #if canImport(NIOTransportServices) && canImport(Network)
        assert(eventLoopGroup is NIOTSEventLoopGroup, "On Apple platforms, the event loop group should be a NIOTSEventLoopGroup")
        #endif
        self.eventLoopGroup = eventLoopGroup
        self.receiveHandler = TCPReceiveHandler()
        self.isSharedEventLoopGroup = true
    }
    
    internal init(channel: Channel, receiveHandler: TCPReceiveHandler) {
        eventLoopGroup = channel.eventLoop
        self.channel = channel
        self.receiveHandler = receiveHandler
        self.isSharedEventLoopGroup = true
    }
    
    @inline(__always)
    public final func send(_ bytes: [UInt8]) {
        let buffer = channel.allocator.buffer(bytes: bytes)
        channel.writeAndFlush(buffer, promise: nil)
    }
    
    @inline(__always)
    public final func write(_ bytes: [UInt8]) {
        let buffer = channel.allocator.buffer(bytes: bytes)
        channel.write(buffer, promise: nil)
    }
    
    @inline(__always)
    public final func flush() {
        channel.flush()
    }
    
    public final func connect(address: SocketAddress) throws {
        if channel != nil { return }
        channel = try bootstrap.connect(to: address).wait()
    }
    
    public final func connect(address: SocketAddress) async throws {
        if channel != nil { return }
        channel = try await bootstrap.connect(to: address).get()
    }
    
    public final func connect(host: String, port: Int) throws {
        if channel != nil { return }
        channel = try bootstrap.connect(host: host, port: port).wait()
    }
    
    public final func connect(host: String, port: Int) async throws {
        if channel != nil { return }
        channel = try await bootstrap.connect(host: host, port: port).get()
    }
    
    public final func disconnect() throws {
        try channel.close().wait()
        if !isSharedEventLoopGroup {
            try eventLoopGroup.syncShutdownGracefully()
        }
        channel = nil
    }
    
    public final func disconnect() async throws {
        try await channel.close()
        if !isSharedEventLoopGroup {
            try await eventLoopGroup.shutdownGracefully()
        }
        channel = nil
    }
    
    #if canImport(NIOTransportServices) && canImport(Network)
    private var bootstrap: NIOTSConnectionBootstrap {
        NIOTSConnectionBootstrap(group: eventLoopGroup)
        .connectTimeout(.seconds(10))
        .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
        .channelInitializer { channel in
            channel.pipeline.addHandler(self.receiveHandler)
        }
    }
    #else
    private var  bootstrap: ClientBootstrap {
        ClientBootstrap(group: eventLoopGroup)
        .connectTimeout(.seconds(10))
        .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
        .channelInitializer { channel in
            channel.pipeline.addHandler(self.receiveHandler)
        }
    }
    #endif
}

internal final class TCPReceiveHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    weak var delegate: TCPClientProtocol?

    func channelRegistered(context: ChannelHandlerContext) {
        delegate?.connected()
    }
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        if let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes) {
            delegate?.received(bytes)
        }
    }
    
    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
        context.fireChannelReadComplete()
    }
    
    func channelUnregistered(context: ChannelHandlerContext) {
        delegate?.disconnected()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("Error caught in \(#file) \(#line): ", error)
        context.close(promise: nil)
    }
}
#endif

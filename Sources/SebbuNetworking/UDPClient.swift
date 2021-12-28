//
//  UDPClient.swift
//  
//
//  Created by Sebastian Toivonen on 16.6.2021.
//

//TODO: Remove #if when NIO is available on Windows
#if canImport(NIO)
import NIO

public protocol UDPClientProtocol: AnyObject {
    func received(data: [UInt8], address: SocketAddress)
}

public final class UDPClient {
    public let group: EventLoopGroup
    
    @usableFromInline
    internal var channelv4: Channel!
    
    @usableFromInline
    internal var channelv6: Channel!
    
    public var ipv4Port: Int? {
        channelv4.localAddress?.port
    }
    
    public var ipv6Port: Int? {
        channelv6.localAddress?.port
    }
    
    private let isSharedEventLoopGroup: Bool
    
    public weak var delegate: UDPClientProtocol? {
        didSet {
            inboundHandler.udpClientProtocol = delegate
        }
    }
    
    private let inboundHandler = UDPInboundHandler()
    
    public var recvBufferSize = 1024 * 1024 {
        didSet {
            _ = channelv4.setOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_RCVBUF), value: .init(recvBufferSize))
            _ = channelv6.setOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_RCVBUF), value: .init(recvBufferSize))
        }
    }
    
    public var sendBufferSize = 1024 * 1024 {
        didSet {
            _ = channelv4.setOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_SNDBUF), value: .init(sendBufferSize))
            _ = channelv6.setOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_SNDBUF), value: .init(sendBufferSize))
        }
    }
    
    public init() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.isSharedEventLoopGroup = false
    }

    public init(eventLoopGroup: EventLoopGroup) {
        self.group = eventLoopGroup
        self.isSharedEventLoopGroup = true
    }
    
    public func start() throws {
        let _bootstrap = bootstrap
        channelv4 = try _bootstrap.bind(host: "0", port: 0).wait()
        channelv6 = try _bootstrap.bind(host: "::", port: 0).wait()
    }
    
    public func shutdown() throws {
        try channelv4.close().wait()
        try channelv6.close().wait()
        if !isSharedEventLoopGroup {
            try group.syncShutdownGracefully()
        }
    }
    
    /// Writes the data to the buffer but doesn't send the data to the peer yet
    /// To send the written data, call the flush function
    @inline(__always)
    public final func write(data: [UInt8], address: SocketAddress) {
        switch address.protocol {
        case .inet:
            writeIPv4(data: data, address: address)
        case .inet6:
            writeIPv6(data: data, address: address)
        default:
            break
        }
    }
    
    @inline(__always)
    internal final func writeIPv4(data: [UInt8], address: SocketAddress) {
        assert(address.protocol == .inet)
        guard let buffer = channelv4?.allocator.buffer(bytes: data) else {
            return
        }
        let envelope = AddressedEnvelope<ByteBuffer>(remoteAddress: address, data: buffer)
        channelv4.write(envelope, promise: nil)
    }
    
    @inline(__always)
    internal final func writeIPv6(data: [UInt8], address: SocketAddress) {
        assert(address.protocol == .inet6)
        guard let buffer = channelv6?.allocator.buffer(bytes: data) else {
            return
        }
        let envelope = AddressedEnvelope<ByteBuffer>(remoteAddress: address, data: buffer)
        channelv6.write(envelope, promise: nil)
    }
    
    /// Sends data to a remote peer. In other words writes and flushes the data immediately to the remote peer
    @inline(__always)
    public final func send(data: [UInt8], address: SocketAddress) {
        switch address.protocol {
        case .inet:
            sendIPv4(data: data, address: address)
        case .inet6:
            sendIPv6(data: data, address: address)
        default:
            break
        }
    }
    
    @inline(__always)
    internal final func sendIPv4(data: [UInt8], address: SocketAddress) {
        assert(address.protocol == .inet)
        writeIPv4(data: data, address: address)
        channelv4.flush()
    }
    
    @inline(__always)
    internal final func sendIPv6(data: [UInt8], address: SocketAddress) {
        assert(address.protocol == .inet6)
        writeIPv6(data: data, address: address)
        channelv6.flush()
    }
    
    /// Flushes the previously written data to the given addresses
    @inline(__always)
    public final func flush() {
        channelv4.flush()
        channelv6.flush()
    }
    
    private var bootstrap: DatagramBootstrap {
        DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_RCVBUF), value: .init(recvBufferSize))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_SNDBUF), value: .init(sendBufferSize))
            .channelInitializer { channel in
                channel.pipeline.addHandler(self.inboundHandler)
            }
    }
    
    deinit {
        if let channel = channelv4 {
            if channel.isActive {
                try? shutdown()
            }
        }
        
        if let channel = channelv6 {
            if channel.isActive {
                try? shutdown()
            }
        }
    }
}

private final class UDPInboundHandler: ChannelInboundHandler {
    public typealias InboundIn = AddressedEnvelope<ByteBuffer>

    fileprivate weak var udpClientProtocol: UDPClientProtocol?
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = self.unwrapInboundIn(data)
        if let data = envelope.data.getBytes(at: 0, length: envelope.data.readableBytes) {
            udpClientProtocol?.received(data: data, address: envelope.remoteAddress)
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("UDPInboundHandler: Error in \(#file):\(#function):\(#line): ", error)
        context.close(promise: nil)
    }
}
#endif

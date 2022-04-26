//
//  TCPServer.swift
//  
//
//  Created by Sebastian Toivonen on 16.6.2021.
//
#if canImport(NIO)
import NIO
#if canImport(NIOTransportServices) && canImport(Network)
import NIOTransportServices
import Network
#endif

public protocol TCPServerProtocol: AnyObject {
    func connected(_ client: TCPClient)
}

public final class TCPServer {
    internal var ipv4channel: Channel?
    internal var ipv6channel: Channel?
    
    public var ipv4Port: Int? {
        ipv4channel?.localAddress?.port
    }
    
    public var ipv6Port: Int? {
        ipv6channel?.localAddress?.port
    }
    
    public let eventLoopGroup: EventLoopGroup
    
    public weak var delegate: TCPServerProtocol?
    
    private var isSharedEventLoopGroup = false
    
    //TODO: TLS Support
    public init(eventLoopGroup: EventLoopGroup) {
        #if canImport(NIOTransportServices) && canImport(Network)
        assert(eventLoopGroup is NIOTSEventLoopGroup, "On Apple platforms, the event loop group should be a NIOTSEventLoopGroup")
        #endif
        self.eventLoopGroup = eventLoopGroup
        self.isSharedEventLoopGroup = true
    }
    
    public init() {
        #if canImport(NIOTransportServices) && canImport(Network)
        self.eventLoopGroup = NIOTSEventLoopGroup()
        #else
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        #endif
    }
    
    public init(numberOfThreads: Int) {
        #if canImport(NIOTransportServices) && canImport(Network)
        self.eventLoopGroup = NIOTSEventLoopGroup(loopCount: numberOfThreads)
        #else
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: numberOfThreads)
        #endif
    }
    
    public final func startIPv4(port: Int) throws {
        ipv4channel = try bootstrap.bind(host: "0", port: port).wait()
    }
    
    public final func startIPv4(port: Int) async throws {
        ipv4channel = try await bootstrap.bind(host: "0", port: port).get()
    }
    
    public final func startIPv6(port: Int) throws {
        ipv6channel = try bootstrap.bind(host: "::", port: port).wait()
    }
    
    public final func startIPv6(port: Int) async throws {
        ipv6channel = try await bootstrap.bind(host: "::", port: port).get()
    }
    
    public final func shutdown() throws {
        try? ipv4channel?.close().wait()
        try? ipv6channel?.close().wait()
        if !isSharedEventLoopGroup {
            try eventLoopGroup.syncShutdownGracefully()
        }
    }
    
    public final func shutdown() async throws {
        try await ipv4channel?.close()
        try await ipv6channel?.close()
        if !isSharedEventLoopGroup {
            try await eventLoopGroup.shutdownGracefully()
        }
    }
    
    #if canImport(Network) && canImport(NIOTransportServices)
    private var bootstrap: NIOTSListenerBootstrap {
        NIOTSListenerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(BackPressureHandler()).flatMap { v in
                    let receiveHandler = TCPReceiveHandler()
                    let tcpClient = TCPClient(channel: channel, receiveHandler: receiveHandler)
                    self.delegate?.connected(tcpClient)
                    return channel.pipeline.addHandler(receiveHandler)
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
    }
    #else
    private var bootstrap: ServerBootstrap {
        ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(BackPressureHandler()).flatMap { v in
                    let receiveHandler = TCPReceiveHandler()
                    let tcpClient = TCPClient(channel: channel, receiveHandler: receiveHandler)
                    self.delegate?.connected(tcpClient)
                    return channel.pipeline.addHandler(receiveHandler)
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
    }
    #endif
}
#endif

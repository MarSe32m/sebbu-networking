//
//  WebSocketServer.swift
//  
//
//  Created by Sebastian Toivonen on 7.2.2020.
//  Copyright © 2021 Sebastian Toivonen. All rights reserved.
//

//TODO: Implement on Windows
#if canImport(NIO)
import WebSocketKit
import NIOWebSocket
import NIO
import NIOSSL
import NIOHTTP1

public protocol WebSocketServerProtocol: AnyObject {
    func shouldUpgrade(requestHead: HTTPRequestHead) -> Bool
    func onConnection(requestHead: HTTPRequestHead, webSocket: WebSocket, channel: Channel)
}

public extension WebSocketServerProtocol {
    func shouldUpgrade(requestHead: HTTPRequestHead) -> Bool { true }
}

public class WebSocketServer {
    public let eventLoopGroup: EventLoopGroup
    public weak var delegate: WebSocketServerProtocol?
    
    private var serverChannelv4: Channel?
    private var serverChannelv6: Channel?
    
    public var ipv4Port: Int? {
        serverChannelv4?.localAddress?.port
    }
    public var ipv6Port: Int? {
        serverChannelv6?.localAddress?.port
    }
    
    private var sslContext: NIOSSLContext?
    private var isSharedEventLoopGroup: Bool
    
    public init(tls: TLSConfiguration? = nil, numberOfThreads: Int) throws {
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: numberOfThreads)
        self.isSharedEventLoopGroup = false
        if let tls = tls {
            //let configuration = TLSConfiguration.forServer(certificateChain: try NIOSSLCertificate.fromPEMFile("cert.pem").map { .certificate($0) }, privateKey: .file("key.pem"))
            self.sslContext = try NIOSSLContext(configuration: tls)
        }
    }
    
    public init(tls: TLSConfiguration? = nil, eventLoopGroup: EventLoopGroup) throws {
        self.eventLoopGroup = eventLoopGroup
        self.isSharedEventLoopGroup = true
        
        if let tls = tls {
            //let configuration = TLSConfiguration.forServer(certificateChain: try NIOSSLCertificate.fromPEMFile("cert.pem").map { .certificate($0) }, privateKey: .file("key.pem"))
            self.sslContext = try NIOSSLContext(configuration: tls)
        }
    }
    
    public func startIPv4(port: Int) throws {
        serverChannelv4 = try bootstrap.bind(host: "0", port: port).wait()
    }
    
    public func startIPv4(port: Int) async throws {
        serverChannelv4 = try await bootstrap.bind(host: "0", port: port).get()
    }
    
    public func startIPv6(port: Int) throws {
        serverChannelv6 = try bootstrap.bind(host: "::", port: port).wait()
    }
    
    public func startIPv6(port: Int) async throws {
        serverChannelv6 = try await bootstrap.bind(host: "::", port: port).get()
    }
    
    public func shutdown() throws {
        try serverChannelv4?.close(mode: .all).wait()
        try serverChannelv6?.close(mode: .all).wait()
        if !isSharedEventLoopGroup {
            try eventLoopGroup.syncShutdownGracefully()
        }
    }
    
    public func shutdown() async throws {
        try await serverChannelv4?.close()
        try await serverChannelv6?.close()
        if !isSharedEventLoopGroup {
            try await eventLoopGroup.shutdownGracefully()
        }
    }
    
    private var bootstrap: ServerBootstrap {
        ServerBootstrap
            .webSocket(on: eventLoopGroup, ssl: sslContext, shouldUpgrade: { [weak self] (head) in
                self?.delegate?.shouldUpgrade(requestHead: head) ?? true
            }, onUpgrade: { [weak self] request, webSocket, channel in
                self?.delegate?.onConnection(requestHead: request, webSocket: webSocket, channel: channel)
            })
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
    }
}

extension ServerBootstrap {
    static func webSocket(
        on eventLoopGroup: EventLoopGroup,
        ssl sslContext: NIOSSLContext? = nil,
        shouldUpgrade: @escaping (HTTPRequestHead) -> Bool,
        onUpgrade: @escaping (HTTPRequestHead, WebSocket, Channel) -> ()
    ) -> ServerBootstrap {
        ServerBootstrap(group: eventLoopGroup).childChannelInitializer { channel in
            let webSocket = NIOWebSocketServerUpgrader(
                shouldUpgrade: { channel, req in
                    return channel.eventLoop.makeSucceededFuture([:])
                },
                upgradePipelineHandler: { channel, req in
                    return WebSocket.server(on: channel) { ws in
                        if shouldUpgrade(req) {
                            onUpgrade(req, ws, channel)
                        } else {
                            ws.close(code: .policyViolation, promise: nil)
                        }
                    }
                }
            )
            if let sslContext = sslContext {
                let handler = NIOSSLServerHandler(context: sslContext)
                _ = channel.pipeline.addHandler(handler)
            }
            return channel.pipeline.configureHTTPServerPipeline(
                withServerUpgrade: (
                    upgraders: [webSocket],
                    completionHandler: { ctx in
                        // complete
                    }
                )
            )
        }
    }
}

#endif

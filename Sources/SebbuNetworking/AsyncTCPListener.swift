//
//  AsyncTCPListener.swift
//  
//
//  Created by Sebastian Toivonen on 3.12.2021.
//
#if canImport(NIO)
import NIOCore

public final class AsyncTCPListener {
    let tcpServer: TCPServer
    
    private var tcpClientIterator: AsyncStream<AsyncTCPClient>.AsyncIterator
    private let tcpClientContinuation: AsyncStream<AsyncTCPClient>.Continuation
    
    public init(eventLoopGroup: EventLoopGroup) {
        tcpServer = TCPServer(eventLoopGroup: eventLoopGroup)
        var continuation: AsyncStream<AsyncTCPClient>.Continuation!
        tcpClientIterator = AsyncStream<AsyncTCPClient> { streamContinuation in
            continuation = streamContinuation
        }.makeAsyncIterator()
        tcpClientContinuation = continuation
        tcpServer.delegate = self
    }
    
    public init(numberOfThreads: Int) {
        tcpServer = TCPServer(numberOfThreads: numberOfThreads)
        var continuation: AsyncStream<AsyncTCPClient>.Continuation!
        tcpClientIterator = AsyncStream<AsyncTCPClient> { streamContinuation in
            continuation = streamContinuation
        }.makeAsyncIterator()
        tcpClientContinuation = continuation
        tcpServer.delegate = self
    }
    
    public final func startIPv4(port: Int) async throws {
        try await tcpServer.startIPv4(port: port)
    }
    
    public final func startIPv6(port: Int) async throws {
        try await tcpServer.startIPv6(port: port)
    }
    
    public final func shutdown() async throws {
        try await tcpServer.shutdown()
        tcpClientContinuation.finish()
    }
    
    public final func listen() async -> AsyncTCPClient? {
        await tcpClientIterator.next()
    }
}

extension AsyncTCPListener: TCPServerProtocol {
    public func connected(_ client: TCPClient) {
        Task {
            try await client.channel.setOption(ChannelOptions.autoRead, value: .init(false)).get()
            tcpClientContinuation.yield(AsyncTCPClient(client))
        }
    }
}
#endif

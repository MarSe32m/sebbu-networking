//
//  AsyncTCPServer.swift
//  
//
//  Created by Sebastian Toivonen on 15.7.2022.
//
#if canImport(NIO)
import NIO
import SebbuTSDS
import Atomics

public final class AsyncTCPServer: @unchecked Sendable {
    internal let listenerChannel: Channel
    
    internal var clientStream: AsyncThrowingStream<AsyncTCPClient, Error>
    
    internal init(channel: Channel, clientStream: AsyncThrowingStream<AsyncTCPClient, Error>) {
        self.listenerChannel = channel
        self.clientStream = clientStream
    }
    
    //TODO: Pass in the config for the accepted clients
    public static func bind(host: String, port: Int, on: EventLoopGroup) async throws -> AsyncTCPServer {
        var tcpClientContinuation: AsyncThrowingStream<AsyncTCPClient, Error>.Continuation!
        let stream = AsyncThrowingStream<AsyncTCPClient, Error>(bufferingPolicy: .unbounded) { continuation in
            tcpClientContinuation = continuation
        }
        //TODO: NIOTS bootstrapping
        let listenerChannel = try await ServerBootstrap(group: on)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
            .childChannelInitializer { channel in
                //TODO: Pass in the config...
                let asyncTCPHandler = AsyncTCPHandler(maxBytes: 16 * 1024)
                let asyncTCPClient = AsyncTCPClient(channel: channel, handler: asyncTCPHandler, config: .init())
                let asyncTCPClientServerHandler = AsyncTCPServerClientHandler(client: asyncTCPClient, stream: tcpClientContinuation)
                _ = channel.pipeline.addHandler(asyncTCPHandler)
                return channel.pipeline.addHandler(asyncTCPClientServerHandler, name: "sebbu.nio.server-client-handler", position: .first)
                    
            }
            .bind(host: host, port: port).get()
        
        return AsyncTCPServer(channel: listenerChannel, clientStream: stream)
    }
    
    public final func close() async throws {
        try await listenerChannel.close()
    }
}

extension AsyncTCPServer: AsyncSequence {
    public typealias AsyncIterator = AsyncThrowingStream<AsyncTCPClient, Error>.Iterator
    public typealias Element = AsyncTCPClient
    
    public func makeAsyncIterator() -> AsyncIterator {
        clientStream.makeAsyncIterator()
    }
}

final class AsyncTCPServerClientHandler: ChannelInboundHandler {
    typealias InboundIn = NIOAny
    
    let client: AsyncTCPClient
    let stream: AsyncThrowingStream<AsyncTCPClient, Error>.Continuation
    
    init(client: AsyncTCPClient, stream: AsyncThrowingStream<AsyncTCPClient, Error>.Continuation) {
        self.client = client
        self.stream = stream
    }
    
    func channelActive(context: ChannelHandlerContext) {
        stream.yield(client)
        context.pipeline.removeHandler(name: "sebbu.nio.server-client-handler", promise: nil)
    }
}
#endif

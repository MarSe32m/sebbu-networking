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
    
    public static func create(on: EventLoopGroup) async throws -> AsyncUDPClient {
        let channel = try await DatagramBootstrap(group: on)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            //.channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_RCVBUF), value: .init(recvBufferSize))
            //.channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_SNDBUF), value: .init(sendBufferSize))
            .channelInitializer { channel in
                channel.pipeline.addHandler(AsyncUDPHandler())
            }.bind(host: "::", port: 0).get()
        try await print("Recv buf:", channel.getOption(ChannelOptions.socketOption(.so_rcvbuf)).get())
        try await print("Send buf:", channel.getOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_SNDBUF)).get())
        try await channel.close()
        return AsyncUDPClient()
    }
    
    public final func receive() async throws -> AddressedEnvelope<ByteBuffer> {
        fatalError("NOT IMPLEMENTED!")
    }
        
    public final func tryReceive() -> AddressedEnvelope<ByteBuffer>? {
        fatalError("NOT IMPLEMENTED")
    }
    
    public final func send(_ data: [UInt8]) {
        fatalError("NOT IMPLEMENTED!")
    }
    
    public final func write(_ data: [UInt8]) {
        fatalError("NOT IMPLEMENTED!")
    }
    
    public final func flush() {
        fatalError("NOT IMPLEMENTED!")
    }
}

@usableFromInline
internal final class AsyncUDPHandler: ChannelInboundHandler {
    @usableFromInline
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    //TODO: Implement this type
}
#endif

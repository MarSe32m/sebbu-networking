//
//  SebbuNetworkingAsyncNetworkingTests.swift
//
//
//  Created by Sebastian Toivonen on 28.12.2021.
//
#if canImport(NIO)
import XCTest
import NIO
import SebbuNetworking
import Atomics

final class SebbuKitAsyncNetworkingTests: XCTestCase {
    private let testData = (0..<1024 * 16).map { _ in UInt8.random(in: .min ... .max) }
    private let testCount = 50
    
    func testAsyncTCPServerConnectionAndDisconnection() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let server = try await AsyncTCPServer.bind(host: "localhost", port: 7777, on: eventLoopGroup)
        var asyncTCPClient = try await AsyncTCPClient.connect(host: "localhost", port: 7777, on: eventLoopGroup)
        var serverClient: AsyncTCPClient!
        for try await client in server {
            serverClient = client
            break
        }
        serverClient.send([1,2,3,4,5])
        var data = try await asyncTCPClient.receive()
        XCTAssertFalse(data.readableBytes == 0)
        
        asyncTCPClient.send([1,2,3,4])
        var otherData = try await serverClient.receive()
        XCTAssertFalse(otherData.readableBytes == 0)
        
        for _ in 0..<1_000 {
            try await asyncTCPClient.disconnect()
            serverClient = nil
            asyncTCPClient = try await AsyncTCPClient.connect(host: "localhost", port: 7777, on: eventLoopGroup)
            for try await client in server {
                serverClient = client
                break
            }
            
            serverClient.send([1,2,3,2,3])
            data = try await asyncTCPClient.receive()
            XCTAssertFalse(data.readableBytes == 0)
            
            asyncTCPClient.send([1,2,3,4,5,6])
            otherData = try await serverClient.receive()
            XCTAssertFalse(otherData.readableBytes == 0)
        }
        
        try await asyncTCPClient.disconnect()
        try await server.close()
        try await eventLoopGroup.shutdownGracefully()
    }
    
    func testAsyncTCPMultipleClientServerConnection() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let server = try await AsyncTCPServer.bind(host: "localhost", port: 8888, on: eventLoopGroup)
        var clientTasks = [Task<Int, Error>]()

        var totalSum = 0
        var clients = [AsyncTCPClient]()
        
        for i in 0..<testCount {
            let client = try await AsyncTCPClient.connect(host: "localhost", port: 8888, on: eventLoopGroup)
            clients.append(client)
            totalSum += i
        }
        
        for (i, client) in clients.enumerated() {
            clientTasks.append(Task {
                for _ in 0..<testCount {
                    client.send(testData)
                    let data = try await client.receive()
                    
                    XCTAssert(data.readableBytes != 0, "Failed to receive data from server...")
                }
                try await client.disconnect()
                return i
            })
        }

        for _ in 0..<testCount {
            var client: AsyncTCPClient!
            for try await _client in server {
                client = _client
                break
            }
            XCTAssertNotNil(client)
            Task { [client] in
                var totalDataReceived = 0
                while true {
                    let data = try await client!.receive(count: testData.count)
                    client!.send([1,2,3,4,5,6])
                    totalDataReceived += data.readableBytes
                }
                XCTAssert(totalDataReceived == testCount * testData.count)
            }
        }

        for task in clientTasks {
            totalSum -= try await task.value
        }
        
        try await server.close()
        XCTAssert(totalSum == 0)
        try await eventLoopGroup.shutdownGracefully()
    }
    
    func testAsyncTCPClientServerConnectionChunkedReads() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let server = try await AsyncTCPServer.bind(host: "localhost", port: 8889, on: eventLoopGroup)
        var clientTasks = [Task<Int, Error>]()

        var totalSum = 0

        var clients: [AsyncTCPClient] = []
        for i in 0..<testCount {
            let client = try await AsyncTCPClient.connect(host: "localhost", port: 8889, on: eventLoopGroup)
            clients.append(client)
            totalSum += i
        }
        
        for (i, client) in clients.enumerated() {
            clientTasks.append(Task {
                for _ in 0..<testCount {
                    client.send(testData)
                }
                
                for _ in 0..<testCount {
                    var data = try await client.receive(count: testData.count)
                    XCTAssert((data.readBytes(length: testData.count) ?? []) == testData)
                }
                
                try await client.disconnect()
                return i
                
            })
        }

        for _ in 0..<testCount {
            var client: AsyncTCPClient!
            for try await _client in server {
                client = _client
                break
            }
            XCTAssertNotNil(client)
            Task { [client] in
                for _ in 0..<testCount {
                    let data = try await client!.receive(count: testData.count)
                    client!.send(data)
                }
            }
        }
        
        for task in clientTasks {
            totalSum -= try await task.value
        }
        try await server.close()
        XCTAssert(totalSum == 0)
        try await eventLoopGroup.shutdownGracefully()
    }
    
    func testAsyncTCPConnection() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let server = try await AsyncTCPServer.bind(host: "localhost", port: 8890, on: eventLoopGroup)
        let client1 = try await AsyncTCPClient.connect(host: "localhost", port: 8890, on: eventLoopGroup)
        var client2: AsyncTCPClient!
        for try await _client in server {
            client2 = _client
            break
        }
        XCTAssertNotNil(client2)
        
        client1.send([1,2,3,4,5,6])
        var recvData = try await client2.receive(count: 6)
        XCTAssert(recvData.readableBytes == 6)
        
        Task.detached { [client2] in
            for _ in 0..<1024 * 128 {
                client2!.send([UInt8](repeating: 0, count: 1024))
            }
        }
        
        for _ in 0..<1024 {
            recvData = try await client1.receive(count: 1024 * 128)
            XCTAssert(recvData.readableBytes == 1024 * 128)
        }
        
        Task.detached { [client2] in
            for _ in 0..<1023 {
                client2!.send([UInt8](repeating: 0, count: 1024))
            }
            try await client2!.sendBlocking([UInt8](repeating: 0, count: 1024))
            try await client2!.disconnect()
        }
        
        var totalData = 1024 * 1024
        
        do {
            for try await data in client1 {
                totalData -= data.readableBytes
            }
        } catch {
            XCTAssert(totalData == 0)
        }
        
        let lastData = client1.tryReceive()
        XCTAssertNil(lastData)
        
        // No need to disconnect since the server client already did
        //try await client1.disconnect()
        try await server.close()
        try await eventLoopGroup.shutdownGracefully()
    }
    
    func testAsyncUDPEchoServer() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let client = try await AsyncUDPClient.create(host: "0", port: 0, configuration: .init(), on: eventLoopGroup)
        let server = try await AsyncUDPServer.create(host: "0", port: 25565, configuration: .init(), on: eventLoopGroup)
        
        let messagesReceived = ManagedAtomic<Int>(0)
        
        Task.detached { [client] in
            let data = ByteBufferAllocator().buffer(bytes: [UInt8](repeating: 0, count: 1400))
            let address = try SocketAddress(ipAddress: "127.0.0.1", port: 25565)
            let envelope = AddressedEnvelope<ByteBuffer>(remoteAddress: address, data: data)
            while messagesReceived.load(ordering: .relaxed) < 20_000 {
                client.send(envelope)
            }
        }
        
        var totalData = 0
        for try await envelope in server {
            let msgRecvd = messagesReceived.wrappingIncrementThenLoad(ordering: .relaxed)
            totalData += envelope.data.readableBytes
            if msgRecvd == 20_000 { break }
        }
        
        XCTAssert(totalData == messagesReceived.load(ordering: .relaxed) * 1400)
        
        try await client.close()
        try await server.close()
        try await eventLoopGroup.shutdownGracefully()
    }
}
#endif

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

final class SebbuKitAsyncNetworkingTests: XCTestCase {
    private let testData = (0..<1024 * 16).map { _ in UInt8.random(in: .min ... .max) }
    private let testCount = 100
    
    func testAsyncTCPServerConnectionAndDisconnection() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let server = try await AsyncTCPServer.bind(host: "::", port: 7777, on: eventLoopGroup)
        var asyncTCPClient = try await AsyncTCPClient.connect(host: "localhost", port: 7777, on: eventLoopGroup)
        var serverClient: AsyncTCPClient!
        for try await client in server {
            serverClient = client
            break
        }
        serverClient.send([1,2,3,4,5])
        var data = await asyncTCPClient.receive()
        XCTAssertFalse(data.isEmpty)
        
        asyncTCPClient.send([1,2,3,4])
        var otherData = await serverClient.receive()
        XCTAssertFalse(otherData.isEmpty)
        
        for _ in 0..<1_000 {
            try await asyncTCPClient.disconnect()
            serverClient = nil
            asyncTCPClient = try await AsyncTCPClient.connect(host: "localhost", port: 7777, on: eventLoopGroup)
            for try await client in server {
                serverClient = client
                break
            }
            
            serverClient.send([1,2,3,2,3])
            data = await asyncTCPClient.receive()
            XCTAssertFalse(data.isEmpty)
            
            asyncTCPClient.send([1,2,3,4,5,6])
            otherData = await serverClient.receive()
            XCTAssertFalse(otherData.isEmpty)
        }
        
        try await asyncTCPClient.disconnect()
        try await server.close()
        try await eventLoopGroup.shutdownGracefully()
    }
    
    func testAsyncTCPMultipleClientServerConnection() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let server = try await AsyncTCPServer.bind(host: "::", port: 8888, on: eventLoopGroup)
        var clientTasks = [Task<Int, Error>]()

        var totalSum = 0
        for i in 0..<testCount {
            clientTasks.append(Task {
                let client = try await AsyncTCPClient.connect(host: "localhost", port: 8888, on: eventLoopGroup)
                for _ in 0..<testCount {
                    client.send(testData)
                    let data = await client.receive()
                    
                    XCTAssert(data.count != 0, "Failed to receive data from server...")
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                try await client.disconnect()
                return i
            })
            totalSum += i
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
                    let data = await client!.receive(count: testData.count)
                    client!.send([1,2,3,4,5,6])
                    totalDataReceived += data.count
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
        let server = try await AsyncTCPServer.bind(host: "::", port: 8889, on: eventLoopGroup)
        var clientTasks = [Task<Int, Error>]()

        var totalSum = 0

        for i in 0..<testCount {
            clientTasks.append(Task {
                let client = try await AsyncTCPClient.connect(host: "localhost", port: 8889, on: eventLoopGroup)
                for _ in 0..<testCount {
                    client.send(testData)
                }
                
                for _ in 0..<testCount {
                    let data = await client.receive(count: testData.count)
                    XCTAssert(data == testData)
                }
                
                try await client.disconnect()
                return i
            })
            totalSum += i
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
                    let data = await client!.receive(count: testData.count)
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
        let server = try await AsyncTCPServer.bind(host: "::", port: 8890, on: eventLoopGroup)
        let client1 = try await AsyncTCPClient.connect(host: "localhost", port: 8890, on: eventLoopGroup)
        var client2: AsyncTCPClient!
        for try await _client in server {
            client2 = _client
            break
        }
        XCTAssertNotNil(client2)
        
        client1.send([1,2,3,4,5,6])
        var recvData = await client2.receive(count: 6)
        XCTAssert(recvData.count == 6)
        
        Task.detached { [client2] in
            for _ in 0..<1024 * 128 {
                client2!.send([UInt8](repeating: 0, count: 1024))
            }
        }
        
        for _ in 0..<1024 {
            recvData = await client1.receive(count: 1024 * 128)
            XCTAssert(recvData.count == 1024 * 128)
        }
        
        try await client1.disconnect()
        //try await client2.disconnect()
        try await server.close()
        try await eventLoopGroup.shutdownGracefully()
    }
    
    func testAsyncUDPEchoServer() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let asyncUDPClient = try await AsyncUDPClient.create(on: eventLoopGroup)
        let _ = asyncUDPClient
        try await eventLoopGroup.shutdownGracefully()
    }
}
#endif

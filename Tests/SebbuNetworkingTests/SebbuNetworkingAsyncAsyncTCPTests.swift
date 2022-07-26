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

fileprivate extension Array where Element == UInt8 {
    static func random(count: Int) -> Self {
        var result: Self = Self()
        for _ in 0..<count {
            result.append(UInt8.random(in: .min ... .max))
        }
        return result
    }
}

final class SebbuKitAsyncTCPTests: XCTestCase {
    private let testData = (0..<1024 * 16).map { _ in UInt8.random(in: .min ... .max) }
    private let testCount = 50
    
    private var eventLoopGroup: MultiThreadedEventLoopGroup! = nil
    
    override func setUp() {
        super.setUp()
        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }
    
    override func tearDown() async throws {
        try await super.tearDown()
        try await eventLoopGroup.shutdownGracefully()
    }
    
    
    func testAsyncTCPClientServerConnection() async throws {
        let server = try await AsyncTCPServer.bind(host: "localhost", port: 6000, on: eventLoopGroup)
        let client = try await AsyncTCPClient.connect(host: "localhost", port: 6000, on: eventLoopGroup)
        let sendCount = Int.random(in: 100...200)
        
        var serverClientTask: Task<Void,Error>?
        for try await serverClient in server {
            serverClientTask = Task.detached {
                for _ in 0..<sendCount {
                    let data = try await serverClient.receive(count: 1024, timeout: 120_000_000_000)
                    serverClient.send(data)
                }
                let _ = try await serverClient.receive()
            }
            break
        }
        
        XCTAssertNotNil(serverClientTask)
        
        for _ in 0..<sendCount {
            let data = [UInt8].random(count: 1024)
            client.send(data)
            guard let receivedData = try await client.receive(count: 1024, timeout: 120_000_000_000).getBytes(at: 0, length: 1024) else {
                XCTFail("Failed to read bytes from received byte buffer")
                return
            }
            XCTAssertEqual(data, receivedData)
        }
        
        try await client.disconnect()
        try await server.close()
        
        do {
            try await serverClientTask?.value
        } catch {
            XCTAssertTrue(error is ChannelError)
            XCTAssertTrue(error as! ChannelError == .alreadyClosed)
        }
        do {
            for try await _ in server {}
        } catch {
            XCTAssertTrue(error is ChannelError)
            XCTAssertTrue(error as! ChannelError == .alreadyClosed)
        }
    }
    
    func testAsyncTCPEchoServerMultipleClients() async throws {
        let clientCount = Int.random(in: 10...100)
        let sendCount = Int.random(in: 100...200)
        let server = try await AsyncTCPServer.bind(host: "0", port: 6001, on: eventLoopGroup)
        var clientTasks: [Task<Void, Error>] = []
        for _ in 0..<clientCount {
            let client = try await AsyncTCPClient.connect(host: "localhost", port: 6001, on: eventLoopGroup)
            let clientTask = Task.detached {
                for _ in 0..<sendCount {
                    let data = [UInt8].random(count: 1024)
                    try await client.sendBlocking(data)
                    guard let receivedData = try await client.receive(count: 1024, timeout: 10_000_000_000).getBytes(at: 0, length: 1024) else {
                        XCTFail("Failed to read all of the bytes from the byte buffer")
                        return
                    }
                    XCTAssertEqual(data, receivedData)
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                try await client.disconnect()
            }
            clientTasks.append(clientTask)
        }
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            for try await client in server.prefix(clientCount) {
                group.addTask {
                    for _ in 0..<sendCount {
                        let data = try await client.receive(count: 1024, timeout: 10_000_000_000)
                        try await client.sendBlocking(data)
                    }
                    try await client.disconnect()
                }
            }
            try await group.waitForAll()
        }
        
        for clientTask in clientTasks {
            do {
                try await clientTask.value
            } catch {
                XCTAssertTrue(error is ChannelError)
                XCTAssertTrue(error as! ChannelError == .alreadyClosed)
            }
        }
        try await server.close()
    }
    
    func testAsyncTCPClientServerAddresses() async throws {
        let server = try await AsyncTCPServer.bind(host: "0", port: 6002, on: eventLoopGroup)
        let client = try await AsyncTCPClient.connect(host: "localhost", port: 6002, on: eventLoopGroup)
        
        XCTAssertNil(server.remoteAddress)
        XCTAssertNotNil(server.localAddress)
        
        XCTAssertNotNil(client.remoteAddress)
        XCTAssertNotNil(client.localAddress)
        
        for try await serverClient in server {
            XCTAssertNotNil(serverClient.remoteAddress)
            XCTAssertNotNil(serverClient.localAddress)
            try await serverClient.disconnect()
            break
        }
        
        var clientDidThrow = false
        do {
            try await client.disconnect()
        } catch {
            XCTAssertTrue(error is ChannelError)
            XCTAssertTrue(error as! ChannelError == .alreadyClosed)
            clientDidThrow = true
        }
        XCTAssertTrue(clientDidThrow)
        try await server.close()
    }
    
    func testAsyncTCPClientServerSlowReadingAndWriting() async throws {
        let server = try await AsyncTCPServer.bind(host: "0", port: 6003, clientConfiguration: .init(maxMessages: 1024, maxMessagesPerRead: 1), on: eventLoopGroup)
        
        // Slow reading
        do {
            let client = try await AsyncTCPClient.connect(host: "localhost", port: 6003, on: eventLoopGroup)
            let sentData = ManagedAtomic<Int>(0)
            Task.detached {
                for _ in 0..<100 {
                    let data = [UInt8].random(count: 1024 * 16)
                    try await client.sendBlocking(data)
                    sentData.wrappingIncrement(by: 1024 * 16, ordering: .relaxed)
                }
                try await client.disconnect()
            }
            for try await serverClient in server.prefix(1) {
                while sentData.load(ordering: .relaxed) < 0 {
                    let data = try await serverClient.receive()
                    sentData.wrappingDecrement(by: data.readableBytes, ordering: .relaxed)
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                try await serverClient.disconnect()
                break
            }
        } catch {
            XCTFail("Slow reading test threw an error \(error)")
            return
        }
        
        // Slow writing
        do {
            let client = try await AsyncTCPClient.connect(host: "localhost", port: 6003, on: eventLoopGroup)
            let dataToSend = 1024 * 1024
            let dataSent = ManagedAtomic<Int>(0)
            let dataReceived = ManagedAtomic<Int>(0)
            Task.detached {
                while dataSent.load(ordering: .relaxed) < dataToSend {
                    try await Task.sleep(nanoseconds: 10_000_000)
                    let data = [UInt8].random(count: 1024 * 16)
                    try await client.sendBlocking(data)
                    dataSent.wrappingIncrement(by: data.count, ordering: .relaxed)
                }
                try await client.disconnect()
            }
            for try await serverClient in server.prefix(1) {
                while dataReceived.load(ordering: .relaxed) != dataSent.load(ordering: .relaxed) {
                    let data = try await serverClient.receive()
                    dataReceived.wrappingIncrement(by: data.readableBytes, ordering: .relaxed)
                }
                try await serverClient.disconnect()
                break
            }
        } catch {
            XCTFail("Slow writing test threw an error \(error)")
            return
        }
        try await server.close()
    }
    
    func testAsyncTCPClientServerErrors() async throws {
        let server = try await AsyncTCPServer.bind(host: "0", port: 6005, on: eventLoopGroup)
        let client1 = try await AsyncTCPClient.connect(host: "localhost", port: 6005, on: eventLoopGroup)
        let client2 = try await AsyncTCPClient.connect(host: "localhost", port: 6005, on: eventLoopGroup)
        
        var serverTask = Task.detached {
            for try await serverClient in server {
                do {
                    let _ = try await serverClient.receive()
                } catch {
                    try await serverClient.disconnect()
                    throw error
                }
            }
        }
        
        var clientTask = Task.detached {
            let _ = try await client1.receive()
        }
        
        try await Task.sleep(nanoseconds: 100_000_000)
        serverTask.cancel()
        clientTask.cancel()
        
        // Task cancellation error
        var serverDidThrow = false
        do {
            let _ = try await serverTask.value
        } catch {
            XCTAssertTrue(error is CancellationError)
            serverDidThrow = true
        }
        XCTAssertTrue(serverDidThrow)
        
        var clientDidThrow = false
        do {
            let _ = try await clientTask.value
        } catch {
            XCTAssert(error is CancellationError)
            clientDidThrow = true
        }
        XCTAssertTrue(clientDidThrow)
        
        // Timeout error
        clientDidThrow = false
        do {
            let _ = try await client2.receive(timeout: 1_000_000_000)
        } catch {
            XCTAssertTrue(error is ReceiveTimeoutError)
            clientDidThrow = true
        }
        XCTAssertTrue(clientDidThrow)
        
        // Closed error
        serverTask = Task.detached {
            for try await serverClient in server {
                let _ = try await serverClient.receive()
            }
        }
        
        clientTask = Task.detached {
            let _ = try await client2.receive()
        }
        
        try await server.close()
        try await client2.disconnect()
        
        serverDidThrow = false
        do {
            let _ = try await serverTask.value
        } catch {
            XCTAssertTrue(error is ChannelError)
            XCTAssertTrue(error as! ChannelError == .alreadyClosed)
            serverDidThrow = true
        }
        XCTAssertTrue(serverDidThrow)
        
        serverDidThrow = false
        do {
            for try await _ in server {}
        } catch {
            XCTAssertTrue(error is ChannelError)
            XCTAssertTrue(error as! ChannelError == .alreadyClosed)
            serverDidThrow = true
        }
        XCTAssertTrue(serverDidThrow)
        
        clientDidThrow = false
        do {
            let _ = try await clientTask.value
        } catch {
            XCTAssert(error is ChannelError)
            XCTAssertTrue(error as! ChannelError == .alreadyClosed)
            clientDidThrow = true
        }
        XCTAssertTrue(clientDidThrow)
    }
    
    func testAsyncTCPMultipleClientServerConnection() async throws {
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
            for try await _client in server.prefix(1) {
                client = _client
                break //This break is unnecessary
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
                do {
                    try await client?.disconnect()
                } catch {}
            }
        }

        for task in clientTasks {
            totalSum -= try await task.value
        }
        
        try await server.close()
        XCTAssert(totalSum == 0)
    }
    
    func testAsyncTCPConnection() async throws {
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
        do { try await client1.disconnect() } catch {}
        try await server.close()
    }
}
#endif
